"""펴 둔 UV 위에 촬영본을 **텍스처로 굽는다** — 머리카락이 픽셀 단위로 들어간다.

    python tools/hologram/bake_head_texture.py --mesh head_uv.obj ^
        --points face_points.json --sparse <sparse_txt> --frames <정합 프레임> ^
        --masks <마스크> --out head_texture.png

정점마다 색 하나를 물리는 방식(`color_head.py`)은 면을 수천 개로 줄이고 나면
색도 그만큼밖에 안 남아서 머리카락이 얼룩으로 뭉갠다. 여기서는 텍스처의
**텍셀마다** 색을 구한다 — 1024x1024 면 백만 점이라 결이 살아난다.

  1. UV 삼각형을 텍셀 격자에 래스터화해서, 텍셀마다 3D 위치와 법선을 구한다.
  2. 그 점을 촬영본으로 되돌린다 (`face_points.json` 의 닮음변환을 거꾸로).
  3. 화면마다: 앞을 향했는지, 가려지지 않았는지, 실루엣 안인지 보고
     통과한 것들의 색을 각도로 가중 평균한다.
  4. 어느 화면에서도 못 본 텍셀은 이웃 색으로 메운다. UV 조각 경계도 같이
     번지게 해야 렌더에서 조각 사이에 실선이 보이지 않는다.
"""

import argparse
import math
import os

import numpy as np
from PIL import Image

parser = argparse.ArgumentParser()
parser.add_argument("--mesh", required=True, help="prep_head.py 가 낸 OBJ (UV 포함)")
parser.add_argument("--points", required=True, help="face_points.py 가 낸 JSON")
parser.add_argument("--sparse", required=True, help="TXT 로 변환한 sparse 모델 폴더")
parser.add_argument("--frames", required=True, help="정합된 프레임 폴더")
parser.add_argument("--masks", required=True, help="머리 마스크 폴더")
parser.add_argument("--out", required=True, help="쓸 PNG 경로")
parser.add_argument("--size", type=int, default=1024, help="텍스처 한 변 크기")
parser.add_argument("--facing", type=float, default=0.2,
                    help="법선과 시선이 이보다 잘 맞아야 그 화면의 색을 쓴다")
parser.add_argument("--depth-scale", type=float, default=0.3,
                    help="가림 판정용 깊이 버퍼 해상도 (화면 대비)")
parser.add_argument("--depth-slack", type=float, default=0.02,
                    help="깊이가 이 비율만큼 더 멀어도 보이는 것으로 친다")
parser.add_argument("--extra", nargs=4, action="append", default=[],
                    metavar=("SPARSE", "FRAMES", "MASKS", "POINTS"),
                    help="다른 촬영본을 **같은 텍스처에 겹쳐** 굽는다. 촬영본마다 "
                         "COLMAP 좌표계가 다르므로 그 촬영본의 face_points.json 을 "
                         "같이 준다 — 얼굴 격자 좌표계를 다리 삼아 만난다. "
                         "여러 번 줄 수 있다")
parser.add_argument("--mask-erode", type=int, default=6,
                    help="마스크를 이 픽셀만큼 안쪽으로 깎고 색을 읽는다. "
                         "가장자리 픽셀은 머리와 배경이 섞여 있어서 그대로 쓰면 "
                         "머리카락에 밝은 얼룩이 박힌다")
parser.add_argument("--best-view", type=float, default=0.0,
                    help="**텍셀마다 가장 잘 보이는 화면 하나를 골라 쓴다** (0 이면 "
                         "지금처럼 여러 화면을 각도로 가중 평균한다). 평균을 내면 "
                         "화면끼리 반 화소만 어긋나도 머리카락 결이 뭉개져서 "
                         "얼룩덜룩한 조각이 된다. 한 화면만 쓰면 그 화면의 결이 "
                         "그대로 들어온다. **다만 진희님 촬영본에서는 오히려 더 "
                         "나빴다** — 화면마다 노출이 달라서 텍스처가 조각보가 됐다. "
                         "쓰려면 화면 사이 밝기를 먼저 맞춰야 한다(이음매 평탄화). "
                         "그래서 기본은 평균이다. 값은 2등과 얼마나 차이 나야 "
                         "갈아탈지를 정한다",)
parser.add_argument("--grow", type=int, default=12,
                    help="빈 텍셀을 이웃 색으로 몇 겹 번지게 할지")
args = parser.parse_args()


def read_obj(path):
    """OBJ 에서 (정점, UV, 삼각형(정점번호, UV번호)) 를 읽는다."""
    verts, uvs, faces = [], [], []
    with open(path, "r", encoding="utf-8") as fp:
        for line in fp:
            if line.startswith("v "):
                verts.append([float(v) for v in line.split()[1:4]])
            elif line.startswith("vt "):
                uvs.append([float(v) for v in line.split()[1:3]])
            elif line.startswith("f "):
                corners = []
                for chunk in line.split()[1:]:
                    parts = chunk.split("/")
                    vi = int(parts[0]) - 1
                    ti = int(parts[1]) - 1 if len(parts) > 1 and parts[1] else -1
                    corners.append((vi, ti))
                for i in range(1, len(corners) - 1):
                    faces.append((corners[0], corners[i], corners[i + 1]))
    return (np.array(verts, dtype=np.float64), np.array(uvs, dtype=np.float64),
            faces)


def quat_to_matrix(qw, qx, qy, qz):
    n = math.sqrt(qw * qw + qx * qx + qy * qy + qz * qz)
    qw, qx, qy, qz = qw / n, qx / n, qy / n, qz / n
    return np.array([
        [1 - 2 * (qy * qy + qz * qz), 2 * (qx * qy - qz * qw), 2 * (qx * qz + qy * qw)],
        [2 * (qx * qy + qz * qw), 1 - 2 * (qx * qx + qz * qz), 2 * (qy * qz - qx * qw)],
        [2 * (qx * qz - qy * qw), 2 * (qy * qz + qx * qw), 1 - 2 * (qx * qx + qy * qy)],
    ], dtype=np.float64)


def read_cameras(path):
    cams = {}
    with open(path, "r", encoding="utf-8") as fp:
        for line in fp:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            p = line.split()
            cams[int(p[0])] = (p[1], int(p[2]), int(p[3]),
                               [float(v) for v in p[4:]])
    return cams


def read_images(path):
    poses = {}
    with open(path, "r", encoding="utf-8") as fp:
        lines = [l.strip() for l in fp if l.strip() and not l.startswith("#")]
    for i in range(0, len(lines), 2):
        p = lines[i].split()
        if len(p) < 10:
            continue
        R = quat_to_matrix(*(float(v) for v in p[1:5]))
        t = np.array([float(v) for v in p[5:8]])
        poses[p[9]] = (R, -R.T @ t, int(p[8]))
    return poses


def project(points, model, params, R, C):
    cam = (points - C) @ R.T
    z = cam[:, 2]
    front = z > 1e-6
    safe = np.where(front, z, 1.0)
    x, y = cam[:, 0] / safe, cam[:, 1] / safe
    if model in ("SIMPLE_RADIAL", "RADIAL"):
        f, cx, cy, k1 = params[0], params[1], params[2], params[3]
        k2 = params[4] if model == "RADIAL" else 0.0
        r2 = x * x + y * y
        scale = 1.0 + k1 * r2 + k2 * r2 * r2
        x, y = x * scale, y * scale
        u, v = f * x + cx, f * y + cy
    elif model == "SIMPLE_PINHOLE":
        f, cx, cy = params[0], params[1], params[2]
        u, v = f * x + cx, f * y + cy
    elif model == "PINHOLE":
        fx, fy, cx, cy = params[0], params[1], params[2], params[3]
        u, v = fx * x + cx, fy * y + cy
    else:
        raise SystemExit(f"모르는 카메라 모델이다: {model}")
    return u, v, z, front


def rasterize(verts, uvs, faces, size):
    """UV 삼각형을 텍셀 격자에 채워 (위치, 법선, 유효 마스크) 를 만든다."""
    position = np.zeros((size, size, 3), dtype=np.float64)
    normal = np.zeros((size, size, 3), dtype=np.float64)
    filled = np.zeros((size, size), dtype=bool)

    for tri in faces:
        vi = [c[0] for c in tri]
        ti = [c[1] for c in tri]
        if min(ti) < 0:
            continue
        p = verts[vi]
        # UV 의 v 는 아래에서 위로 센다. 그림 좌표로 뒤집는다.
        uv = uvs[ti] * (size - 1)
        uv = np.stack([uv[:, 0], (size - 1) - uv[:, 1]], axis=1)

        x0, y0 = np.floor(uv.min(axis=0)).astype(int)
        x1, y1 = np.ceil(uv.max(axis=0)).astype(int)
        x0, y0 = max(x0 - 1, 0), max(y0 - 1, 0)
        x1, y1 = min(x1 + 1, size - 1), min(y1 + 1, size - 1)
        if x1 < x0 or y1 < y0:
            continue

        gx, gy = np.meshgrid(np.arange(x0, x1 + 1), np.arange(y0, y1 + 1),
                             indexing="xy")
        px, py = gx.ravel() + 0.5, gy.ravel() + 0.5
        (ax, ay), (bx, by), (cx, cy) = uv
        det = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
        if abs(det) < 1e-12:
            continue
        w0 = ((by - cy) * (px - cx) + (cx - bx) * (py - cy)) / det
        w1 = ((cy - ay) * (px - cx) + (ax - cx) * (py - cy)) / det
        w2 = 1.0 - w0 - w1
        # 조각 경계 한 겹까지 넉넉히 채운다 — 렌더에서 이음매가 실선으로 보인다.
        inside = (w0 >= -0.06) & (w1 >= -0.06) & (w2 >= -0.06)
        if not inside.any():
            continue

        ix, iy = gx.ravel()[inside], gy.ravel()[inside]
        bary = np.stack([w0[inside], w1[inside], w2[inside]], axis=1)
        position[iy, ix] = bary @ p
        face_n = np.cross(p[1] - p[0], p[2] - p[0])
        length = np.linalg.norm(face_n)
        if length > 1e-12:
            normal[iy, ix] = face_n / length
        filled[iy, ix] = True

    return position, normal, filled


def main():
    import json

    verts, uvs, faces = read_obj(args.mesh)
    print(f"[texture] 정점 {len(verts)} / 삼각형 {len(faces)} / UV {len(uvs)}")
    if not len(uvs):
        raise SystemExit("OBJ 에 UV 가 없다 — prep_head.py 를 먼저 돌려라")

    size = args.size
    position, normal, filled = rasterize(verts, uvs, faces, size)
    print(f"[texture] 텍셀 {int(filled.sum())} / {size * size} 채움")
    flat = position[filled]
    flat_n = normal[filled]

    total = np.zeros((len(flat), 3), dtype=np.float64)
    weight = np.zeros(len(flat), dtype=np.float64)
    # 한 화면만 고를 때 쓴다: 지금까지의 최고 점수와 그때의 색.
    best_score = np.zeros(len(flat), dtype=np.float64)
    best_color = np.zeros((len(flat), 3), dtype=np.float64)
    used = 0

    # 촬영본마다 COLMAP 좌표계가 다르다. **얼굴 격자 좌표계를 다리로** 각
    # 촬영본으로 되돌려 색을 읽고, 결과는 같은 텍스처에 쌓는다.
    sources = [(args.sparse, args.frames, args.masks, args.points)]
    sources += [tuple(extra) for extra in args.extra]

    for sparse_dir, frames_dir, masks_dir, points_path in sources:
        with open(points_path, "r", encoding="utf-8") as fp:
            fit = json.load(fp)["fit"]
        R_fit = np.array(fit["rotation"], dtype=np.float64)
        scale = float(fit["scale"])
        t_fit = np.array(fit["translation"], dtype=np.float64)

        world = (R_fit.T @ ((flat - t_fit) / scale).T).T
        world_n = (R_fit.T @ flat_n.T).T

        cams = read_cameras(os.path.join(sparse_dir, "cameras.txt"))
        poses = read_images(os.path.join(sparse_dir, "images.txt"))
        print(f"[texture] 촬영본 {os.path.basename(os.path.dirname(sparse_dir))} "
              f"— 화면 {len(poses)}장")
        args_frames, args_masks = frames_dir, masks_dir

        for name in sorted(poses):
            frame = os.path.join(frames_dir, name)
            mask_path = os.path.join(masks_dir, os.path.splitext(name)[0] + ".png")
            if not (os.path.exists(frame) and os.path.exists(mask_path)):
                continue
            R, C, cam_id = poses[name]
            model, width, height, params = cams[cam_id]

            image = Image.open(frame).convert("RGB")
            if image.size != (width, height):
                image = image.resize((width, height), Image.BILINEAR)
            pixels = np.asarray(image, dtype=np.float64)
            mask = Image.open(mask_path).convert("L")
            if mask.size != (width, height):
                mask = mask.resize((width, height), Image.NEAREST)
            head = np.asarray(mask, dtype=np.uint8) > 127
            # 실루엣 가장자리는 머리와 배경이 한 픽셀 안에서 섞인다. 그 색을 그대로
            # 읽으면 머리카락에 흰 얼룩이 박히므로 안쪽으로 깎아 쓴다.
            for _ in range(args.mask_erode):
                head[1:, :] &= head[:-1, :]
                head[:-1, :] &= head[1:, :]
                head[:, 1:] &= head[:, :-1]
                head[:, :-1] &= head[:, 1:]

            u, v, depth, front = project(world, model, params, R, C)
            ui = np.rint(u).astype(np.int64)
            vi = np.rint(v).astype(np.int64)
            inside = front & (ui >= 0) & (ui < width) & (vi >= 0) & (vi < height)

            view = world - C
            view /= np.maximum(np.linalg.norm(view, axis=1, keepdims=True), 1e-12)
            facing = -np.sum(view * world_n, axis=1)
            ok = inside & (facing > args.facing)
            if not ok.any():
                continue

            dw = max(int(width * args.depth_scale), 16)
            dh = max(int(height * args.depth_scale), 16)
            zbuf = np.full((dh, dw), np.inf)
            idx = np.where(inside)[0]
            dx = np.clip((u[idx] * dw / width).astype(np.int64), 0, dw - 1)
            dy = np.clip((v[idx] * dh / height).astype(np.int64), 0, dh - 1)
            np.minimum.at(zbuf, (dy, dx), depth[idx])

            cand = np.where(ok)[0]
            cx_ = np.clip((u[cand] * dw / width).astype(np.int64), 0, dw - 1)
            cy_ = np.clip((v[cand] * dh / height).astype(np.int64), 0, dh - 1)
            cand = cand[depth[cand] <= zbuf[cy_, cx_] * (1.0 + args.depth_slack)]
            if not len(cand):
                continue
            cand = cand[head[vi[cand], ui[cand]]]
            if not len(cand):
                continue

            w = facing[cand] ** 2
            sampled = pixels[vi[cand], ui[cand]]
            if args.best_view > 0:
                # 아직 빈 텍셀은 무조건 받고, 이미 색이 있으면 **확실히** 나을
                # 때만 갈아탄다. 조금 나은 정도로 바꾸면 텍셀마다 화면이 달라져
                # 이음매가 생긴다.
                prev = best_score[cand]
                better = (prev <= 0) | (w > prev + args.best_view)
                take = cand[better]
                best_score[take] = w[better]
                best_color[take] = sampled[better]
                weight[cand] = np.maximum(weight[cand], w)
            else:
                total[cand] += sampled * w[:, None]
                weight[cand] += w
            used += 1
            if used % 20 == 0:
                print(f"[texture] {used}장 처리")

    if used == 0:
        raise SystemExit("쓸 화면이 없다 — 프레임·마스크 이름을 봐라")

    got = weight > 0
    color = np.zeros((len(flat), 3), dtype=np.float64)
    if args.best_view > 0:
        color[got] = best_color[got]
    else:
        color[got] = total[got] / weight[got, None]

    texture = np.zeros((size, size, 3), dtype=np.float64)
    known = np.zeros((size, size), dtype=bool)
    ys, xs = np.where(filled)
    texture[ys[got], xs[got]] = color[got]
    known[ys[got], xs[got]] = True
    print(f"[texture] {used}장으로 구웠다 / 색을 얻은 텍셀 {int(known.sum())}")

    # **카메라가 아예 못 본 넓은 자리**(눈높이 궤도에서는 정수리가 그렇다)는
    # 이웃에서 번져 오게 두면 안 된다 — 얼굴·배경 색이 위까지 끌려 올라와
    # 얼룩덜룩해진다. 그런 자리는 **머리카락 대표색**으로 먼저 덮는다.
    seen = known.copy()
    hole = filled & ~seen  # 표면이지만 색을 못 얻은 자리
    if hole.any():
        ys_k, xs_k = np.where(seen)
        upper = ys_k < size * 0.5          # UV 위쪽 = 머리 위쪽
        source = seen if not upper.any() else np.zeros_like(seen)
        if upper.any():
            source[ys_k[upper], xs_k[upper]] = True
        hair = np.median(texture[source], axis=0)
        texture[hole] = hair
        known = known | hole
        print(f"[texture] 못 본 텍셀 {int(hole.sum())}개를 머리카락 색 "
              f"{np.round(hair).astype(int).tolist()} 으로 덮었다")

    # 남은 빈 자리와 조각 경계는 이웃 색으로 번지게 한다. 안 하면 렌더에서
    # 조각 사이가 검은 실선으로 보인다.
    for _ in range(args.grow):
        holes = ~known
        if not holes.any():
            break
        acc = np.zeros_like(texture)
        count = np.zeros((size, size), dtype=np.float64)
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            shifted = np.roll(texture, (dy, dx), axis=(0, 1))
            valid = np.roll(known, (dy, dx), axis=(0, 1))
            acc += shifted * valid[:, :, None]
            count += valid
        grow = holes & (count > 0)
        texture[grow] = acc[grow] / count[grow, None]
        known = known | grow

    Image.fromarray(np.clip(texture, 0, 255).astype(np.uint8)).save(args.out)
    print(f"[texture] -> {args.out}")


main()
