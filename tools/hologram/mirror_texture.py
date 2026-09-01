"""한쪽만 허옇게 뜬 자리를 **반대쪽 색으로 메운다.**

    python tools/hologram/mirror_texture.py --mesh head.obj --texture head.png ^
        --out head_fixed.png --side 0.35

머리는 좌우가 거의 대칭인데, 촬영이 한쪽으로 치우치면 **한쪽 머리만 색을 제대로
못 얻는다.** 되투영이 실패한 자리는 이웃 색으로 번지면서 허옇게 뜨고, 화면에서는
그 자리가 '비어 보인다'. 형상은 멀쩡한데 색만 빈 것이다.

그래서 텍셀마다 **거울 위치(x → -x)의 색**을 찾아, 자기가 거울보다 뚜렷하게
밝으면 거울 색으로 바꾼다. 밝은 쪽만 고치므로 원래 잘 나온 자리는 안 건드리고,
머리카락처럼 어두워야 할 자리만 채워진다.

거울 위치의 색은 **복셀 격자**로 찾는다. 텍셀을 칸에 나눠 담아 칸마다 평균색을
구해 두고, 거울 위치가 속한 칸을 조회한다 (수백만 텍셀을 하나씩 뒤지면 느리다).

얼굴은 건드리지 않는다 — `--side` 안쪽(정중선 근처)은 얼굴이라 사진이 덮는다.
"""

import argparse

import numpy as np
from PIL import Image


parser = argparse.ArgumentParser()
parser.add_argument("--mesh", required=True, help="UV 가 있는 머리 OBJ")
parser.add_argument("--texture", required=True, help="고칠 텍스처 PNG")
parser.add_argument("--out", required=True)
parser.add_argument("--side", type=float, default=0.35,
                    help="정중선에서 이 거리(|X|) 바깥만 고친다. 안쪽은 얼굴이다")
parser.add_argument("--ratio", type=float, default=1.22,
                    help="거울보다 이 배 넘게 밝으면 '떴다'고 보고 바꾼다")
parser.add_argument("--cell", type=float, default=0.03,
                    help="거울 색을 찾을 때 쓰는 복셀 칸 크기")
parser.add_argument("--strength", type=float, default=1.0,
                    help="얼마나 바꿀지 (0~1)")
args = parser.parse_args()


def read_obj(path):
    verts, uvs, faces = [], [], []
    for line in open(path, "r", encoding="utf-8"):
        if line.startswith("v "):
            verts.append([float(v) for v in line.split()[1:4]])
        elif line.startswith("vt "):
            uvs.append([float(v) for v in line.split()[1:3]])
        elif line.startswith("f "):
            corner = []
            for chunk in line.split()[1:]:
                part = chunk.split("/")
                corner.append((int(part[0]) - 1,
                               int(part[1]) - 1 if len(part) > 1 and part[1]
                               else -1))
            for i in range(1, len(corner) - 1):
                faces.append((corner[0], corner[i], corner[i + 1]))
    return np.array(verts), np.array(uvs), faces


def rasterize(verts, uvs, faces, size):
    """UV 삼각형을 텍셀 격자에 채워 (3D 위치, 유효 마스크) 를 만든다."""
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


def main():
    verts, uvs, faces = read_obj(args.mesh)
    tex = np.asarray(Image.open(args.texture).convert("RGB"), dtype=np.float64)
    size = tex.shape[0]
    position, filled = rasterize(verts, uvs, faces, size)
    ys, xs = np.where(filled)
    pos = position[filled]
    col = tex[ys, xs]
    print(f"[mirror] 텍셀 {len(pos)} / {size}x{size}")

    # 칸마다 평균색을 구해 둔다 (거울 위치 조회용).
    cell = args.cell
    lo = pos.min(axis=0) - cell
    dims = np.maximum(((pos.max(axis=0) + cell - lo) / cell).astype(int) + 2, 3)

    def cell_index(p):
        c = np.clip(((p - lo) / cell).astype(int), 0, dims - 1)
        return (c[:, 0] * dims[1] + c[:, 1]) * dims[2] + c[:, 2]

    own = cell_index(pos)
    total = np.zeros((int(dims.prod()), 3))
    count = np.zeros(int(dims.prod()))
    np.add.at(total, own, col)
    np.add.at(count, own, 1.0)

    # 거울 위치. 정중선이 X=0 이므로 x 부호만 뒤집는다.
    flipped = pos.copy()
    flipped[:, 0] *= -1.0
    other = cell_index(flipped)
    has = count[other] > 0
    mirror = np.zeros_like(col)
    mirror[has] = total[other[has]] / count[other[has], None]

    grey = np.array([0.299, 0.587, 0.114])
    own_luma = col @ grey
    mirror_luma = mirror @ grey

    # 옆머리만, 그리고 거울보다 뚜렷하게 밝은 텍셀만 바꾼다.
    side = np.abs(pos[:, 0]) > args.side
    bright = own_luma > mirror_luma * args.ratio
    fix = has & side & bright & (mirror_luma > 1.0)

    out = tex.copy()
    if fix.any():
        blend = args.strength
        out[ys[fix], xs[fix]] = (col[fix] * (1 - blend) + mirror[fix] * blend)
        print(f"[mirror] 한쪽만 뜬 텍셀 {int(fix.sum())}개를 반대쪽 색으로 "
              f"바꿨다 (밝기 {own_luma[fix].mean():.0f} -> "
              f"{mirror_luma[fix].mean():.0f})")
    else:
        print("[mirror] 바꿀 텍셀이 없다")

    Image.fromarray(np.clip(out, 0, 255).astype(np.uint8)).save(args.out)
    print(f"[mirror] -> {args.out}")


main()
