"""껍질(UV 있는 OBJ)에 **점구름의 색**을 옮겨 텍스처로 굽는다.

    python tools/hologram/texture_from_cloud.py --mesh head_uv.obj ^
        --cloud head_raw.ply --out head_texture.png

`bake_head_texture.py` 는 텍셀을 촬영본에 되투영해 색을 읽는다. 껍질
(`envelope_head.py`)처럼 실제 표면보다 부푼 메시에서는 그 되투영이 머리 밖으로
나가 색을 못 얻는다 — 뒷머리가 통째로 단색이 됐다.

여기서는 되투영을 하지 않는다. **깎아낸 점구름은 이미 사진에서 색을 받아 뒀고**
(`color_head.py`), 껍질은 그 점들을 감싸고 있으니, 텍셀마다 가장 가까운 점의
색을 가져오면 된다. 부풀어 있어도 상관없다 — 거리로 찾기 때문이다.

가장 가까운 점은 격자로 찾는다. 점을 칸에 나눠 담아 두고 텍셀이 속한 칸과 그
이웃만 뒤진다 (scipy 없이 돌리려고 이렇게 했다).
"""

import argparse
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ply_io import read_ply  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--mesh", required=True, help="UV 가 있는 OBJ (껍질)")
parser.add_argument("--cloud", required=True, help="색이 있는 PLY (같은 좌표계)")
parser.add_argument("--out", required=True, help="쓸 PNG")
parser.add_argument("--size", type=int, default=1024, help="텍스처 한 변")
parser.add_argument("--cell", type=float, default=0.05,
                    help="가장 가까운 점을 찾을 때 쓰는 칸 크기")
parser.add_argument("--grow", type=int, default=40, help="빈 텍셀 번짐 횟수")
parser.add_argument("--facing", type=float, default=0.35,
                    help="**방향이 다른 표면의 색을 가져오지 못하게 막는다.** 텍셀이 "
                         "바라보는 쪽과 점의 법선이 이만큼은 맞아야 그 점을 쓴다. "
                         "귀처럼 오목한 자리는 껍질이 메워 버리는데, 거기서 그냥 "
                         "가장 가까운 점을 집으면 **옆을 보는 표면이 앞을 보는 뺨의 "
                         "살색을 끌어온다** — 귀 자리가 살색으로 번져 구멍처럼 보였다. "
                         "0 이면 검사하지 않는다")
args = parser.parse_args()


def read_obj(path):
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
                    part = chunk.split("/")
                    vi = int(part[0]) - 1
                    ti = int(part[1]) - 1 if len(part) > 1 and part[1] else -1
                    corners.append((vi, ti))
                for i in range(1, len(corners) - 1):
                    faces.append((corners[0], corners[i], corners[i + 1]))
    return (np.array(verts, dtype=np.float64), np.array(uvs, dtype=np.float64),
            faces)


def rasterize(verts, uvs, faces, size):
    """UV 삼각형을 텍셀 격자에 채워 (위치, 유효 마스크) 를 만든다."""
    position = np.zeros((size, size, 3), dtype=np.float64)
    filled = np.zeros((size, size), dtype=bool)
    for tri in faces:
        vi = [c[0] for c in tri]
        ti = [c[1] for c in tri]
        if min(ti) < 0:
            continue
        p = verts[vi]
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
        inside = (w0 >= -0.06) & (w1 >= -0.06) & (w2 >= -0.06)
        if not inside.any():
            continue
        ix, iy = gx.ravel()[inside], gy.ravel()[inside]
        bary = np.stack([w0[inside], w1[inside], w2[inside]], axis=1)
        position[iy, ix] = bary @ p
        filled[iy, ix] = True
    return position, filled


def surface_normals(verts, faces):
    """정점마다 둘러싼 면의 법선을 더해 평균 낸다."""
    normal = np.zeros_like(verts)
    for tri in faces:
        a, b, c = (verts[t[0]] for t in tri)
        n = np.cross(b - a, c - a)
        for corner in tri:
            normal[corner[0]] += n
    length = np.linalg.norm(normal, axis=1, keepdims=True)
    return normal / np.maximum(length, 1e-12)


def main():
    verts, uvs, faces = read_obj(args.mesh)
    points, _, colors, cloud_n = read_ply(args.cloud, want_normals=True)
    if colors is None:
        raise SystemExit("점구름에 색이 없다 — color_head.py 를 먼저 돌려라")
    print(f"[cloud] 껍질 정점 {len(verts)} / 점구름 {len(points)}")

    size = args.size
    position, filled = rasterize(verts, uvs, faces, size)
    targets = position[filled]

    # 텍셀이 바라보는 쪽. 껍질은 중심에서 사방으로 뻗은 모양이라 중심에서
    # 텍셀로 가는 방향이 곧 그 자리의 바깥쪽이다.
    facing = None
    if args.facing > 0 and cloud_n is not None:
        normal_map = np.zeros((size, size, 3))
        vn = surface_normals(verts, faces)
        nrm, _ = rasterize(vn, uvs, faces, size)
        normal_map = nrm
        facing = normal_map[filled]
        length = np.linalg.norm(facing, axis=1, keepdims=True)
        facing = facing / np.maximum(length, 1e-12)
        cloud_len = np.linalg.norm(cloud_n, axis=1, keepdims=True)
        cloud_n = cloud_n / np.maximum(cloud_len, 1e-12)
        print(f"[cloud] 법선 검사 켬 (기준 {args.facing})")
    print(f"[cloud] 텍셀 {len(targets)} / {size * size}")

    # 점을 칸에 나눠 담는다. 칸 하나에 몇 개가 들었는지 세어 두고 정렬해서,
    # 칸마다 그 안의 점 번호를 이어 붙인 배열로 만든다 (scipy 없이 쓰는 방법).
    lo = points.min(axis=0) - args.cell
    dims = np.maximum(((points.max(axis=0) + args.cell - lo) / args.cell)
                      .astype(int) + 1, 1)
    def cell_of(p):
        return np.clip(((p - lo) / args.cell).astype(int), 0, dims - 1)

    pc = cell_of(points)
    flat = (pc[:, 0] * dims[1] + pc[:, 1]) * dims[2] + pc[:, 2]
    order = np.argsort(flat)
    flat_sorted = flat[order]
    starts = np.searchsorted(flat_sorted, np.arange(dims.prod() + 1))

    tc = cell_of(targets)
    out = np.zeros((len(targets), 3), dtype=np.float64)
    got = np.zeros(len(targets), dtype=bool)

    # 이웃 칸까지 뒤진다. 한 겹으로 못 찾으면 두 겹으로 넓힌다.
    for radius in (1, 2, 3):
        todo = np.where(~got)[0]
        if not len(todo):
            break
        offsets = [(dx, dy, dz)
                   for dx in range(-radius, radius + 1)
                   for dy in range(-radius, radius + 1)
                   for dz in range(-radius, radius + 1)
                   if max(abs(dx), abs(dy), abs(dz)) == radius or radius == 1]
        for n, i in enumerate(todo):
            best, best_d = -1, np.inf
            for dx, dy, dz in offsets:
                cx, cy, cz = tc[i] + (dx, dy, dz)
                if not (0 <= cx < dims[0] and 0 <= cy < dims[1]
                        and 0 <= cz < dims[2]):
                    continue
                key = (cx * dims[1] + cy) * dims[2] + cz
                lo_i, hi_i = starts[key], starts[key + 1]
                if hi_i <= lo_i:
                    continue
                idx = order[lo_i:hi_i]
                if facing is not None:
                    agree = cloud_n[idx] @ facing[i]
                    idx = idx[np.abs(agree) >= args.facing]
                    if not len(idx):
                        continue
                d = np.sum((points[idx] - targets[i]) ** 2, axis=1)
                k = int(np.argmin(d))
                if d[k] < best_d:
                    best_d, best = d[k], idx[k]
            if best >= 0:
                out[i] = colors[best]
                got[i] = True
            if n % 50000 == 0 and n:
                print(f"[cloud] {n}/{len(todo)} (반경 {radius})")
        print(f"[cloud] 반경 {radius} 까지: 색을 얻은 텍셀 {int(got.sum())}")

    texture = np.zeros((size, size, 3), dtype=np.float64)
    known = np.zeros((size, size), dtype=bool)
    ys, xs = np.where(filled)
    texture[ys[got], xs[got]] = out[got]
    known[ys[got], xs[got]] = True

    # **정수리는 어느 영상에도 안 찍혔다.** 눈높이로 도는 촬영이라 그렇다.
    # 이웃 사방에서 번지게 하면 색은 맞아도 결이 뭉개진다. 구면 UV 에서는
    # 세로줄이 곧 머리 한 가닥이 흐르는 방향이라, **같은 세로줄의 바로 아래
    # 색을 위로 이어 붙이면** 머리카락이 정수리까지 흐르는 것처럼 보인다.
    for _ in range(size):
        holes = ~known
        if not holes.any():
            break
        below = np.roll(texture, -1, axis=0)
        below_known = np.roll(known, -1, axis=0)
        pull = holes & below_known
        if not pull.any():
            break
        texture[pull] = below[pull]
        known = known | pull

    for _ in range(args.grow):
        holes = ~known
        if not holes.any():
            break
        acc = np.zeros_like(texture)
        count = np.zeros((size, size))
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            acc += np.roll(texture, (dy, dx), axis=(0, 1)) * np.roll(
                known, (dy, dx), axis=(0, 1))[:, :, None]
            count += np.roll(known, (dy, dx), axis=(0, 1))
        grow = holes & (count > 0)
        texture[grow] = acc[grow] / count[grow, None]
        known = known | grow

    Image.fromarray(np.clip(texture, 0, 255).astype(np.uint8)).save(args.out)
    print(f"[cloud] -> {args.out}")


main()
