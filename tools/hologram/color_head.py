"""깎아낸 머리에 **촬영본의 색**을 입힌다 (정점마다 한 색).

    python tools/hologram/color_head.py --sparse <sparse_txt> --frames <정합 프레임> ^
        --masks <마스크> --hull head_mesh.ply --out head_colored.ply

**왜 필요한가.** 형태만 있는 머리는 하얀 껍데기로 렌더되어 수영모를 쓴 것처럼
보인다. 얼굴에는 사진을 입혀 두었으니 그 위가 백색이면 더 튄다. 카메라 자세를
이미 알고 있으므로, 정점을 화면에 도로 투영해 그 자리의 색을 읽어 오면
머리카락은 머리카락 색이 된다.

**어느 화면의 색을 쓸지**가 전부다. 세 가지로 고른다.

  · 그 화면에서 **앞을 향한** 면인가 (법선과 시선의 각도)
  · **가려지지 않았는가** — 같은 방향에서 더 가까운 표면이 있으면 그건
    뒤통수 너머다. 정점을 흩뿌려 만든 성긴 깊이 버퍼로 가려낸다.
  · **머리 실루엣 안**인가 — 마스크 밖이면 배경을 읽게 된다.

통과한 화면들의 색을 각도로 가중해 평균한다. 한 장만 쓰면 그 장의 노출과
그림자가 그대로 박혀서 이어붙인 자국이 생긴다.
"""

import argparse
import math
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ply_io import read_ply, write_ply  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--sparse", required=True, help="TXT 로 변환한 sparse 모델 폴더")
parser.add_argument("--frames", required=True, help="정합된 프레임 폴더")
parser.add_argument("--masks", required=True, help="머리 마스크 폴더")
parser.add_argument("--hull", required=True, help="깎아낸 머리 (PLY, COLMAP 좌표)")
parser.add_argument("--out", required=True, help="색을 입혀 쓸 PLY")
parser.add_argument("--facing", type=float, default=0.25,
                    help="법선과 시선이 이보다 잘 맞아야 그 화면의 색을 쓴다")
parser.add_argument("--depth-scale", type=float, default=0.25,
                    help="가림 판정용 깊이 버퍼 해상도 (화면 대비)")
parser.add_argument("--depth-slack", type=float, default=0.02,
                    help="깊이가 이 비율만큼 더 멀어도 보이는 것으로 친다")
args = parser.parse_args()


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
            parts = line.split()
            cams[int(parts[0])] = (parts[1], int(parts[2]), int(parts[3]),
                                   [float(v) for v in parts[4:]])
    return cams


def read_images(path):
    poses = {}
    with open(path, "r", encoding="utf-8") as fp:
        lines = [l.strip() for l in fp if l.strip() and not l.startswith("#")]
    for i in range(0, len(lines), 2):
        parts = lines[i].split()
        if len(parts) < 10:
            continue
        R = quat_to_matrix(*(float(v) for v in parts[1:5]))
        t = np.array([float(v) for v in parts[5:8]])
        poses[parts[9]] = (R, -R.T @ t, int(parts[8]))
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


def vertex_normals(verts, faces):
    """면 법선을 정점에 모아 평균한다."""
    normals = np.zeros_like(verts)
    tris = np.array([f[:3] for f in faces if len(f) >= 3], dtype=np.int64)
    a, b, c = verts[tris[:, 0]], verts[tris[:, 1]], verts[tris[:, 2]]
    face_n = np.cross(b - a, c - a)
    for k in range(3):
        np.add.at(normals, tris[:, k], face_n)
    length = np.linalg.norm(normals, axis=1, keepdims=True)
    return normals / np.maximum(length, 1e-12)


def main():
    cams = read_cameras(os.path.join(args.sparse, "cameras.txt"))
    poses = read_images(os.path.join(args.sparse, "images.txt"))
    verts, faces, _ = read_ply(args.hull)
    normals = vertex_normals(verts, faces)
    print(f"[color] 정점 {len(verts)} / 면 {len(faces)}")

    total = np.zeros((len(verts), 3), dtype=np.float64)
    weight = np.zeros(len(verts), dtype=np.float64)
    used = 0

    for name in sorted(poses):
        frame = os.path.join(args.frames, name)
        mask_path = os.path.join(args.masks, os.path.splitext(name)[0] + ".png")
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

        u, v, depth, front = project(verts, model, params, R, C)
        ui = np.rint(u).astype(np.int64)
        vi = np.rint(v).astype(np.int64)
        inside = front & (ui >= 0) & (ui < width) & (vi >= 0) & (vi < height)

        # 카메라를 향한 면인가.
        view = verts - C
        view /= np.maximum(np.linalg.norm(view, axis=1, keepdims=True), 1e-12)
        facing = -np.sum(view * normals, axis=1)
        ok = inside & (facing > args.facing)
        if not ok.any():
            continue

        # 성긴 깊이 버퍼로 가림을 걸러낸다. 정점만 흩뿌리므로 완벽하지 않지만,
        # 뒤통수 너머의 면이 앞면 색을 훔쳐 가는 것은 이걸로 거의 다 막힌다.
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
        visible = depth[cand] <= zbuf[cy_, cx_] * (1.0 + args.depth_slack)
        cand = cand[visible]
        if not len(cand):
            continue

        # 머리 실루엣 안쪽만. 밖이면 배경색을 읽는다.
        inmask = head[vi[cand], ui[cand]]
        cand = cand[inmask]
        if not len(cand):
            continue

        w = facing[cand] ** 2
        total[cand] += pixels[vi[cand], ui[cand]] * w[:, None]
        weight[cand] += w
        used += 1
        if used % 10 == 0:
            print(f"[color] {used}장 처리")

    if used == 0:
        raise SystemExit("쓸 화면이 없다 — 프레임·마스크 이름을 봐라")

    got = weight > 0
    colors = np.zeros((len(verts), 3), dtype=np.uint8)
    colors[got] = np.clip(total[got] / weight[got, None], 0, 255).astype(np.uint8)

    # 어느 화면에서도 안 보인 정점(대개 목 밑이나 오목한 자리)은 이웃 색으로
    # 메운다. 검은 구멍이 남으면 그게 더 눈에 띈다.
    if (~got).any():
        missing = np.where(~got)[0]
        known = np.where(got)[0]
        print(f"[color] 색을 못 얻은 정점 {len(missing)}개 — 가까운 색으로 메운다")
        # 조각을 작게 끊는다 — 한 번에 다 재면 거리 행렬이 기가바이트가 된다.
        for start in range(0, len(missing), 256):
            chunk = missing[start:start + 256]
            d = np.linalg.norm(verts[chunk][:, None, :] - verts[known][None, :, :],
                               axis=2)
            colors[chunk] = colors[known[np.argmin(d, axis=1)]]

    write_ply(args.out, verts, faces, colors=colors)
    print(f"[color] {used}장으로 색을 입혔다 -> {args.out}")


main()
