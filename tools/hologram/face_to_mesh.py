"""촬영한 프레임에서 얼굴 격자(정점 + 엣지)를 뽑아 JSON 으로 저장한다.

전용 venv 에서 돌린다. 메인 파이썬 환경에 mediapipe 를 깔면 protobuf 와
numpy 를 끌어내려서 onnx2tf / TensorFlow 쪽이 통째로 깨진다.

    C:\\Users\\012\\.venvs\\holoface\\Scripts\\python.exe face_to_mesh.py ^
        --frames <프레임 폴더> --out face_mesh.json

사진측량 대신 이 방법을 쓰는 이유:
홀로그램은 텍스처 없이 형태만 필요하다. 사진측량은 텍스처가 강점인데 여기선
쓸모가 없고, 대신 역광·압축·머리카락에 약하다. 무엇보다 촬영본이 세 번에
나눠 찍혀서 그 사이 고개 각도와 표정이 달라졌는데, 사진측량은 세 바퀴 내내
피사체가 굳어 있어야 합쳐진다. 얼굴 격자는 한 컷만으로 형태를 뽑고
격자 구조가 처음부터 반듯해서 와이어프레임으로 쓰기에도 더 낫다.
"""

import argparse
import json
import os

import numpy as np
from PIL import Image

import mediapipe as mp
from mediapipe.tasks.python import BaseOptions
from mediapipe.tasks.python import vision

# 홍채 랜드마크가 시작되는 번호. 여기부터는 얼굴 표면이 아니라 눈동자다.
FIRST_IRIS = 468

# 얼굴이 어디를 보는지 재는 데 쓰는 랜드마크.
CHEEK_LEFT = 234
CHEEK_RIGHT = 454
FOREHEAD = 10
CHIN = 152

parser = argparse.ArgumentParser()
parser.add_argument("--frames", required=True, help="jpg/png 프레임이 있는 폴더")
parser.add_argument("--model", required=True, help="face_landmarker.task 경로")
parser.add_argument("--out", required=True, help="쓸 JSON 경로")
parser.add_argument("--depth-scale", type=float, default=1.0, help="깊이(z) 과장 배율")
parser.add_argument("--top", type=int, default=5, help="상위 몇 개를 보여줄지")
parser.add_argument("--save-frame", default=None,
                    help="채택한 프레임을 이 경로로 복사한다 (연출 미리보기용)")
parser.add_argument("--mesh-spacing", type=float, default=0.058,
                    help="**그리는 선** 의 간격 (얼굴 너비 대비). 클수록 성글다")
parser.add_argument("--highlight-spacing", type=float, default=0.11,
                    help="하이라이트 사이 최소 간격 (얼굴 너비 대비). 클수록 적다")
parser.add_argument("--contour-step", type=int, default=2,
                    help="윤곽선을 몇 점마다 하나씩 남길지. 1 이면 원본 그대로")
args = parser.parse_args()


def laplacian_variance(gray):
    """초점이 맞았는지 재는 값. 흔들린 컷은 이 값이 낮다."""
    k = np.array([[0, 1, 0], [1, -4, 1], [0, 1, 0]], dtype=np.float32)
    h, w = gray.shape
    if h < 3 or w < 3:
        return 0.0
    windows = np.lib.stride_tricks.sliding_window_view(gray, (3, 3))
    return float((windows * k).sum(axis=(2, 3)).var())


def score_frame(landmarks, width, height, gray):
    xs = np.array([p.x for p in landmarks]) * width
    ys = np.array([p.y for p in landmarks]) * height
    zs = np.array([p.z for p in landmarks]) * width
    pts = np.stack([xs, ys, zs], axis=1)

    face_w = xs.max() - xs.min()
    face_h = ys.max() - ys.min()
    if face_w <= 0 or face_h <= 0:
        return None

    # 얼굴 평면의 법선이 카메라를 얼마나 정면으로 보는지 잰다.
    # 코끝-양볼 거리 비교 같은 좌우 대칭만으로는 위아래로 젖혀진 각도를
    # 못 잡아낸다. 실제로 그렇게 재면 위에서 내려다본 눈 감은 컷이
    # "완벽한 정면"으로 뽑힌다.
    horizontal = pts[CHEEK_RIGHT] - pts[CHEEK_LEFT]
    vertical = pts[FOREHEAD] - pts[CHIN]
    normal = np.cross(horizontal, vertical)
    norm = np.linalg.norm(normal)
    if norm < 1e-6:
        return None
    frontality = abs(normal[2] / norm)

    # 얼굴 부분만 잘라서 선명도를 잰다. 배경이 선명해도 소용없다.
    x0, x1 = int(max(xs.min(), 0)), int(min(xs.max(), width))
    y0, y1 = int(max(ys.min(), 0)), int(min(ys.max(), height))
    sharpness = laplacian_variance(gray[y0:y1, x0:x1]) if (x1 > x0 + 3 and y1 > y0 + 3) else 0.0

    size = (face_w * face_h) / (width * height)
    # 정면도를 세제곱해 크게 반영한다. 비스듬히 잡힌 격자는 깊이가 엉망이다.
    return {
        "score": size * (frontality ** 3) * np.log1p(sharpness) * 1000.0,
        "size": size,
        "frontality": frontality,
        "sharpness": sharpness,
        "width": width,
        "height": height,
    }


def thin_points(pts, spacing):
    """가까운 점들을 솎아 고르게 남긴다.

    mediapipe 격자는 눈·입 주변이 촘촘하고 볼은 성글다. 그대로 선을 이으면
    그물처럼 보여서 정밀한 느낌이 안 난다. 최소 간격을 두고 앞에서부터
    받아들이면 얼굴 전체에 고르게 퍼진다.
    """
    kept = []
    kept_xy = np.empty((0, 2), dtype=np.float64)
    for i, p in enumerate(pts):
        if kept_xy.size and np.min(np.linalg.norm(kept_xy - p, axis=1)) < spacing:
            continue
        kept.append(i)
        kept_xy = np.vstack([kept_xy, p])
    return kept, kept_xy


def sparse_mesh(pts, spacing):
    """솎아 낸 점으로 다시 삼각분할한다. (엣지, 삼각형) 을 돌려준다.

    원래 삼각망에서 선을 골라 빼면 조각조각 끊긴다. 남긴 점으로 새로
    삼각분할해야 고르고 이어진 격자가 나온다.

    삼각형도 같이 내보낸다 — 면이 있어야 Blender 에서 표면을 입힐 수 있고,
    선만 있는 뼈대는 아바타가 아니라 철사 덩어리로 보인다.
    """
    from scipy.spatial import Delaunay

    kept, xy = thin_points(pts, spacing)
    if len(kept) < 4:
        return [], []

    tri = Delaunay(xy)
    # 얼굴 바깥을 가로지르는 긴 변은 버린다 — 턱 밑이나 관자놀이 바깥을
    # 잇는 삼각형이 생기면 형태가 뭉개져 보인다.
    limit = spacing * 2.6
    edges, faces = set(), []
    for simplex in tri.simplices:
        sides = ((0, 1), (1, 2), (2, 0))
        if any(np.linalg.norm(xy[simplex[a]] - xy[simplex[b]]) > limit
               for a, b in sides):
            continue
        faces.append([int(kept[i]) for i in simplex])
        for a, b in sides:
            i, j = simplex[a], simplex[b]
            edges.add((min(kept[i], kept[j]), max(kept[i], kept[j])))
    return sorted(edges), faces


def tesselation_faces(pairs):
    """mediapipe 삼각망의 변 목록에서 삼각형을 복원한다.

    표면은 **직접 다시 삼각분할하지 않는다.** 점을 솎아 새로 나누면 경계에서
    삼각형이 버려져 얼굴에 구멍이 뚫린다(이마·볼이 뜯겨 나간 것처럼 보인다).
    mediapipe 가 주는 삼각망은 빈틈이 없으므로 그걸 그대로 표면으로 쓴다.
    그리는 선만 따로 성글게 만든다.
    """
    adjacent = {}
    for a, b in pairs:
        adjacent.setdefault(a, set()).add(b)
        adjacent.setdefault(b, set()).add(a)

    # 홍채 랜드마크(468~)는 눈동자 위에 따로 떠 있다. 삼각망에 섞어 두면
    # 눈 위로 볼록한 덩어리가 생겨 흰자가 뭉개진 것처럼 보인다.
    tris = set()
    for a, b in pairs:
        for c in adjacent[a] & adjacent[b]:
            if max(a, b, c) >= FIRST_IRIS:
                continue
            tris.add(tuple(sorted((a, b, c))))
    return [list(t) for t in sorted(tris)]


def fill_loop(pairs):
    """닫힌 고리를 부채꼴로 메운다.

    mediapipe 삼각망은 **눈 구멍을 비워 둔다** — 원래 눈알이 들어갈 자리라서다.
    그대로 두면 그 구멍으로 뒤통수 안쪽이 비쳐 눈에 흰 덩어리가 앉는다.
    눈꺼풀 고리를 따라가며 삼각형으로 덮는다.
    """
    adjacent = {}
    for a, b in pairs:
        adjacent.setdefault(a, []).append(b)
        adjacent.setdefault(b, []).append(a)
    if not adjacent:
        return []

    start = min(adjacent)
    loop, prev, cur = [start], None, start
    while True:
        nxt = [n for n in adjacent[cur] if n != prev]
        if not nxt or nxt[0] == start:
            break
        prev, cur = cur, nxt[0]
        loop.append(cur)

    return [[loop[0], loop[i], loop[i + 1]] for i in range(1, len(loop) - 1)]


def simplify_contours(pairs, step):
    """윤곽선을 사슬로 이은 뒤 몇 점마다 하나씩만 남긴다.

    선을 무작정 빼면 눈·입이 끊긴 조각이 된다. 사슬을 따라가며 솎아야
    모양은 그대로 두고 선 개수만 준다. mediapipe 윤곽은 눈·입술이 아주
    촘촘해서 2D 화면에서는 이 선들이 격자보다 훨씬 많다.
    """
    if step <= 1:
        return sorted({(min(a, b), max(a, b)) for a, b in pairs})

    adjacent = {}
    for a, b in pairs:
        adjacent.setdefault(a, []).append(b)
        adjacent.setdefault(b, []).append(a)

    used, out = set(), []

    def key(a, b):
        return (min(a, b), max(a, b))

    def walk(first, second):
        chain = [first, second]
        prev, cur = first, second
        while True:
            nxt = [n for n in adjacent[cur]
                   if n != prev and key(cur, n) not in used]
            if not nxt:
                break
            n = nxt[0]
            used.add(key(cur, n))
            chain.append(n)
            prev, cur = cur, n
            if n == first:
                break
        return chain

    # 끝이 있는 선(차수 1)부터 훑고, 남은 고리는 아무 데서나 시작한다.
    order = ([v for v in adjacent if len(adjacent[v]) == 1]
             + sorted(adjacent))
    for v in order:
        for n in list(adjacent[v]):
            if key(v, n) in used:
                continue
            used.add(key(v, n))
            chain = walk(v, n)
            kept = chain[::step]
            if kept[-1] != chain[-1]:
                kept.append(chain[-1])
            out += [key(a, b) for a, b in zip(kept, kept[1:]) if a != b]
    return sorted(set(out))


def pick_highlights(xy, contour_pairs, spacing):
    """이목구비 위에 고르게 뿌린 하이라이트 정점.

    번호를 일정 간격으로 세면 안 된다 — mediapipe 인덱스는 부위별로 뭉쳐 있어서
    눈 주변에만 몰리고 볼은 텅 빈다. 윤곽선에 쓰이는 정점(눈·눈썹·코·입·얼굴선)
    만 후보로 두고, 화면에서 일정 거리 이상 떨어진 것만 남긴다.
    """
    candidates = sorted({i for e in contour_pairs for i in e})
    kept, kept_xy = [], np.empty((0, 2), dtype=np.float64)
    for i in candidates:
        if i >= len(xy):
            continue
        p = xy[i]
        if kept_xy.size and np.min(np.linalg.norm(kept_xy - p, axis=1)) < spacing:
            continue
        kept.append(int(i))
        kept_xy = np.vstack([kept_xy, p])
    return kept


def to_blender_coords(landmarks, width, height, depth_scale):
    """mediapipe 좌표를 Blender 축으로 옮긴다.

    mediapipe: x 오른쪽, y 아래, z 카메라 쪽이 음수. x·y 는 이미지 크기로
    나뉘어 있어 그대로 쓰면 화면 비율만큼 찌그러진다. 픽셀로 되돌려야 한다.
    z 는 x 와 같은 스케일이라 width 를 곱한다.
    """
    xs = np.array([p.x for p in landmarks]) * width
    ys = np.array([p.y for p in landmarks]) * height
    zs = np.array([p.z for p in landmarks]) * width * depth_scale

    # Blender: x 오른쪽, y 화면 안쪽, z 위
    verts = np.stack([xs, zs, -ys], axis=1)
    verts -= verts.mean(axis=0)
    verts /= np.abs(verts).max()
    return verts


def main():
    options = vision.FaceLandmarkerOptions(
        base_options=BaseOptions(model_asset_path=args.model),
        running_mode=vision.RunningMode.IMAGE,
        num_faces=1,
    )

    names = sorted(
        f for f in os.listdir(args.frames)
        if f.lower().endswith((".jpg", ".jpeg", ".png"))
    )
    if not names:
        raise SystemExit(f"프레임이 없다: {args.frames}")

    results = []
    with vision.FaceLandmarker.create_from_options(options) as landmarker:
        for name in names:
            path = os.path.join(args.frames, name)
            pil = Image.open(path).convert("RGB")
            rgb = np.asarray(pil, dtype=np.uint8)
            gray = np.asarray(pil.convert("L"), dtype=np.float32) / 255.0

            image = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
            detection = landmarker.detect(image)
            if not detection.face_landmarks:
                continue

            landmarks = detection.face_landmarks[0]
            scored = score_frame(landmarks, rgb.shape[1], rgb.shape[0], gray)
            if scored is None:
                continue
            scored["name"] = name
            scored["landmarks"] = landmarks
            results.append(scored)

    if not results:
        raise SystemExit("어느 프레임에서도 얼굴을 못 찾았다")

    results.sort(key=lambda r: r["score"], reverse=True)
    print(f"[face] {len(results)}/{len(names)} 장에서 얼굴 검출")
    for r in results[:args.top]:
        print(f"[face]   {r['name']}  점수 {r['score']:.4f}  "
              f"크기 {r['size']:.3f}  정면도 {r['frontality']:.3f}  선명도 {r['sharpness']:.5f}")

    best = results[0]
    verts = to_blender_coords(best["landmarks"], best["width"], best["height"],
                              args.depth_scale)

    # 화면 위 좌표(0~1). 스캔 연출에서 특징점을 사진 위 제자리에 찍으려면
    # 3D 가 아니라 이 값이 필요하다.
    points_2d = [[float(p.x), float(p.y)] for p in best["landmarks"]]

    # 격자는 화면에서 보이는 모양 기준으로 솎아야 한다. 3D 좌표로 간격을 재면
    # 옆으로 눕은 부분이 화면에서는 촘촘한데 실제 간격은 멀어서 안 솎인다.
    xy = np.array(points_2d, dtype=np.float64)
    xy = (xy - xy.min(axis=0)) / max((xy.max(axis=0) - xy.min(axis=0)).max(), 1e-6)
    # 선과 표면을 따로 만든다. 선을 줄이려고 표면까지 성글게 하면 삼각형이
    # 얼굴을 못 덮어서 아바타에 구멍이 뚫린다 — 사진이 뜯겨 나간 것처럼 보인다.
    edges, _ = sparse_mesh(xy, args.mesh_spacing)
    connections = vision.FaceLandmarksConnections
    faces = tesselation_faces(
        [(c.start, c.end) for c in connections.FACE_LANDMARKS_TESSELATION])
    # 눈 구멍을 덮는다. 안 그러면 그 자리로 뒤통수가 비쳐 보인다.
    for ring in (connections.FACE_LANDMARKS_LEFT_EYE,
                 connections.FACE_LANDMARKS_RIGHT_EYE):
        faces += fill_loop([(c.start, c.end) for c in ring])

    # 이목구비 윤곽은 따로 살린다. 격자를 성글게 하면 눈·입 모양이 사라지는데,
    # 얼굴을 알아보게 하는 건 결국 이 선들이다.
    contours = simplify_contours(
        [(c.start, c.end)
         for c in vision.FaceLandmarksConnections.FACE_LANDMARKS_CONTOURS],
        args.contour_step)

    payload = {
        "source_frame": best["name"],
        "source_size": [best["width"], best["height"]],
        "vertices": verts.tolist(),
        "edges": [list(e) for e in edges],
        "faces": faces,
        "contours": [list(e) for e in contours],
        # 하이라이트로 찍을 정점. **2D 오버레이와 3D 아바타가 같은 목록을 쓴다** —
        # 사진 위에서 반짝이던 점이 그대로 아바타 위에 남아야 이어져 보인다.
        "highlights": pick_highlights(xy, contours, args.highlight_spacing),
        "points_2d": points_2d,
    }
    with open(args.out, "w", encoding="utf-8") as fp:
        json.dump(payload, fp)

    print(f"[face] 채택: {best['name']}")
    print(f"[face] 정점 {len(verts)}개 / 격자 {len(edges)}선 {len(faces)}면 "
          f"/ 윤곽 {len(contours)}선 -> {args.out}")

    # 텍스처용 원본 프레임. 사진을 3D 얼굴에 입히려면 UV(=points_2d)와
    # **같은 좌표계의 이미지**가 있어야 한다 — 잘라낸 사진을 쓰면 어긋난다.
    texture = os.path.splitext(args.out)[0] + "_texture.jpg"
    Image.open(os.path.join(args.frames, best["name"])).convert("RGB") \
         .save(texture, quality=92)
    print(f"[face] 텍스처 -> {texture}")

    if args.save_frame:
        os.makedirs(os.path.dirname(args.save_frame) or ".", exist_ok=True)
        Image.open(os.path.join(args.frames, best["name"])).convert("RGB") \
             .save(args.save_frame, quality=90)
        print(f"[face] 채택 프레임 복사 -> {args.save_frame}")


main()
