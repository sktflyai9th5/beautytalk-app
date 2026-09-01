"""깎아낸 머리를 **중심에서 본 껍질 하나**로 새로 짓는다.

    python tools/hologram/envelope_head.py --hull head_fitted.ply ^
        --face-mesh face_mesh.json --out head_uv.obj

**왜 다시 짓나.** 실루엣으로 깎은 표면을 그대로 쓰면 얇은 머리카락 조각이
남는다. 3D 로는 뒤에서 이어져 있어도 화면에서는 얼굴에 가려져 **허공에 뜬
조각**으로 보인다. 잘라 내면 그 자리가 뚫리고, 메우면 다른 데가 또 뜬다 —
표면을 손보는 한 끝이 없다.

그래서 표면을 버리고 **점만 남긴다.** 머리 중심에서 사방으로 방향을 나눠,
그 방향에서 가장 먼 점까지의 거리를 재고(반지름 지도), 그 지도를 부드럽게
편 뒤 구면 격자로 껍질을 짓는다. 결과는:

  · **하나로 이어진 닫힌 껍질** — 뜬 조각이 생길 수 없다.
  · **구멍이 없다** — 격자를 통째로 만들기 때문에 뚫릴 자리가 없다.
  · **UV 가 공짜다** — 구면 좌표가 곧 UV 라, 따로 펴지 않아도 텍스처가 붙는다.

대가는 오목한 곳이다. 방향마다 가장 먼 점을 쓰므로 귀 뒤처럼 파인 자리는
메워진다. 홀로그램 아바타에는 이 편이 낫다 — 파인 자리를 살리려다 조각이
뜨는 것보다, 매끈한 두상이 사람으로 읽힌다.
"""

import argparse
import json
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ply_io import read_ply  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--hull", required=True, help="fit_head.py 가 낸 PLY")
parser.add_argument("--out", required=True, help="쓸 OBJ 경로 (UV 포함)")
parser.add_argument("--face-mesh", default=None,
                    help="주면 얼굴이 덮는 자리를 사진 얼굴 뒤로 민다")
parser.add_argument("--push", type=float, default=0.06,
                    help="사진 얼굴보다 이만큼 뒤로 민다")
parser.add_argument("--floor", type=float, default=None,
                    help="껍질이 이 높이(Z) 아래로 못 내려가게 **반지름에 상한**을 "
                         "건다. 점을 빼면 그 방향에 점이 하나도 없어져서 그 자리가 "
                         "엉뚱하게 채워진다 — 뿔이 서거나 안쪽이 뒤집힌다")
parser.add_argument("--back", type=float, default=None,
                    help="껍질이 이 깊이(Y) 뒤로 못 가게 반지름에 상한을 건다")
parser.add_argument("--az", type=int, default=192, help="가로(방위) 칸 수")
parser.add_argument("--el", type=int, default=96, help="세로(고도) 칸 수")
parser.add_argument("--smooth", type=int, default=6,
                    help="반지름 지도를 몇 번 문지를지. 클수록 매끈하다")
parser.add_argument("--bound-center", type=float, nargs=3, default=None,
                    help="**두상 타원체의 중심** (얼굴 격자 좌표). 얼굴 한가운데가 "
                         "원점, 얼굴이 -Y, 위가 +Z, 얼굴 반지름이 1 이다")
parser.add_argument("--bound-axes", type=float, nargs=3, default=None,
                    help="**두상 타원체의 반지름 세 개** (좌우, 앞뒤, 위아래). 어느 "
                         "방향도 이 타원체 밖으로 못 나가게 반지름에 상한을 건다. "
                         "묶은 머리처럼 한쪽으로만 길게 뻗은 덩어리가 두상 표면을 "
                         "따라가게 되어 사라진다. 평면으로 자르는 것과 달리 모서리가 "
                         "안 생기고, 점을 빼지 않으니 어디도 비지 않는다")
parser.add_argument("--cap-ratio", type=float, default=None,
                    help="**튀어나온 덩어리를 두상 안으로 눌러 넣는다.** 반지름 "
                         "지도를 아주 넓게 문질러 두상의 평균 반지름을 얻고, 어느 "
                         "방향도 그 평균의 이 배를 못 넘게 막는다. 묶은 머리처럼 "
                         "한쪽만 불룩한 자리가 두상에 흡수된다. 평면으로 자르면 "
                         "벽과 선반이 생겨 돌 때 그 모서리가 뜬 조각처럼 보이는데, "
                         "이건 방향마다 눌러서 모서리가 안 생긴다. 1.1~1.25 쯤")
parser.add_argument("--cap-smooth", type=int, default=40,
                    help="평균 반지름을 얻을 때 문지르는 횟수. 클수록 '두상 전체의 "
                         "평균'에 가까워서 덩어리를 잘 잡아낸다")
parser.add_argument("--percentile", type=float, default=99.0,
                    help="한 방향에서 몇 번째로 먼 점을 껍질로 삼을지. 100 이면 "
                         "가장 먼 점 — 튀는 점 하나에 껍질이 끌려간다")
args = parser.parse_args()


def wrap_blur(grid, times):
    """반지름 지도를 부드럽게 편다. 방위는 한 바퀴 돌므로 감아서 섞는다."""
    out = grid.copy()
    for _ in range(times):
        left = np.roll(out, 1, axis=0)
        right = np.roll(out, -1, axis=0)
        up = np.vstack([out[:, :1].T, out[:, :-1].T]).T
        down = np.vstack([out[:, 1:].T, out[:, -1:].T]).T
        out = (out * 2 + left + right + up + down) / 6.0
    return out


def build_radius_map(points, center, az, el, percentile):
    """방향마다 '그 방향에서 가장 먼 점까지의 거리' 를 잰다."""
    rel = points - center
    radius = np.linalg.norm(rel, axis=1)
    good = radius > 1e-9
    rel, radius = rel[good], radius[good]
    unit = rel / radius[:, None]

    theta = np.arctan2(unit[:, 0], unit[:, 1])
    phi = np.arcsin(np.clip(unit[:, 2], -1.0, 1.0))

    ai = np.clip(((theta + math.pi) / (2 * math.pi) * az).astype(int), 0, az - 1)
    ei = np.clip(((phi + math.pi / 2) / math.pi * el).astype(int), 0, el - 1)

    grid = np.zeros((az, el))
    counts = np.zeros((az, el), dtype=np.int64)
    flat = ai * el + ei
    order = np.argsort(flat)
    flat_sorted, radius_sorted = flat[order], radius[order]
    edges = np.searchsorted(flat_sorted, np.arange(az * el + 1))
    for cell in range(az * el):
        lo, hi = edges[cell], edges[cell + 1]
        if hi > lo:
            grid[cell // el, cell % el] = np.percentile(
                radius_sorted[lo:hi], percentile)
            counts[cell // el, cell % el] = hi - lo

    # 빈 칸은 이웃에서 채운다. 방향을 촘촘히 나누면 점이 없는 칸이 생긴다.
    empty = counts == 0
    for _ in range(60):
        if not empty.any():
            break
        acc = np.zeros_like(grid)
        num = np.zeros_like(grid)
        for shifted, valid in (
                (np.roll(grid, 1, 0), np.roll(~empty, 1, 0)),
                (np.roll(grid, -1, 0), np.roll(~empty, -1, 0)),
                (np.roll(grid, 1, 1), np.roll(~empty, 1, 1)),
                (np.roll(grid, -1, 1), np.roll(~empty, -1, 1))):
            acc += shifted * valid
            num += valid
        fill = empty & (num > 0)
        grid[fill] = acc[fill] / num[fill]
        empty = empty & ~fill
    return grid


def face_depth_map(face_json, n=224):
    with open(face_json, "r", encoding="utf-8") as fp:
        payload = json.load(fp)
    verts = np.array(payload["vertices"], dtype=np.float64)
    tris = [f for f in payload.get("faces", []) if len(f) == 3]
    lo = verts[:, [0, 2]].min(axis=0)
    hi = verts[:, [0, 2]].max(axis=0)
    span = np.maximum(hi - lo, 1e-9)
    depth = np.full((n, n), np.nan)
    for tri in tris:
        p = verts[tri]
        cell = (p[:, [0, 2]] - lo) / span * (n - 1)
        x0, z0 = np.floor(cell.min(axis=0)).astype(int)
        x1, z1 = np.ceil(cell.max(axis=0)).astype(int)
        x0, z0 = max(x0, 0), max(z0, 0)
        x1, z1 = min(x1, n - 1), min(z1, n - 1)
        if x1 < x0 or z1 < z0:
            continue
        gx, gz = np.meshgrid(np.arange(x0, x1 + 1), np.arange(z0, z1 + 1),
                             indexing="ij")
        px, pz = gx.ravel(), gz.ravel()
        (ax, az_), (bx, bz), (cx, cz) = cell
        det = (bz - cz) * (ax - cx) + (cx - bx) * (az_ - cz)
        if abs(det) < 1e-12:
            continue
        w0 = ((bz - cz) * (px - cx) + (cx - bx) * (pz - cz)) / det
        w1 = ((cz - az_) * (px - cx) + (ax - cx) * (pz - cz)) / det
        w2 = 1.0 - w0 - w1
        inside = (w0 >= -0.02) & (w1 >= -0.02) & (w2 >= -0.02)
        if not inside.any():
            continue
        y = w0 * p[0, 1] + w1 * p[1, 1] + w2 * p[2, 1]
        ix, iz, yy = px[inside], pz[inside], y[inside]
        current = depth[ix, iz]
        better = np.isnan(current) | (yy < current)
        depth[ix[better], iz[better]] = yy[better]
    return depth, lo, span


def push_behind_face(verts, face_json, margin, feather=14, n=224):
    """얼굴이 덮는 자리를 사진 얼굴 뒤로 민다 (경계는 서서히)."""
    depth, lo, span = face_depth_map(face_json, n)
    covered = ~np.isnan(depth)
    weight = np.zeros((n, n))
    mask = covered.copy()
    for step in range(feather):
        shrunk = mask.copy()
        shrunk[1:, :] &= mask[:-1, :]
        shrunk[:-1, :] &= mask[1:, :]
        shrunk[:, 1:] &= mask[:, :-1]
        shrunk[:, :-1] &= mask[:, 1:]
        weight[shrunk] = (step + 1) / feather
        mask = shrunk

    cell = (verts[:, [0, 2]] - lo) / span * (n - 1)
    ix = np.rint(cell[:, 0]).astype(int)
    iz = np.rint(cell[:, 1]).astype(int)
    inside = (ix >= 0) & (ix < n) & (iz >= 0) & (iz < n)
    idx = np.where(inside)[0]
    face_y = depth[ix[idx], iz[idx]]
    w = weight[ix[idx], iz[idx]]
    hit = ~np.isnan(face_y) & (w > 0)
    idx, face_y, w = idx[hit], face_y[hit], w[hit]

    pushed = np.maximum(verts[idx, 1], face_y + margin)
    verts[idx, 1] = verts[idx, 1] * (1 - w) + pushed * w
    print(f"[envelope] 얼굴 자리 {len(idx)}개 정점을 뒤로 밀었다")
    return verts


def directions(az, el):
    """구면 격자의 방향 벡터. 반지름 지도와 같은 순서다."""
    thetas = -math.pi + 2 * math.pi * (np.arange(az) + 0.0) / az
    phis = -math.pi / 2 + math.pi * (np.arange(el) + 0.5) / el
    t, p = np.meshgrid(thetas, phis, indexing="ij")
    return np.stack([np.sin(t) * np.cos(p), np.cos(t) * np.cos(p), np.sin(p)],
                    axis=-1)


def main():
    points, faces, _ = read_ply(args.hull)
    center = points.mean(axis=0)
    print(f"[envelope] 점 {len(points)} / 중심 {np.round(center, 2).tolist()}")

    grid = build_radius_map(points, center, args.az, args.el, args.percentile)

    # **점을 빼지 않는다.** 대신 껍질이 그 선을 못 넘게 반지름을 눌러 준다.
    # 점을 빼면 그 방향에 잴 점이 없어져서 이웃에서 아무 값이나 끌어오고,
    # 그 자리가 뿔로 튀거나 안쪽이 뒤집힌다 (실제로 뒷머리가 비었다).
    dirs = directions(args.az, args.el)
    if args.back is not None:
        toward = dirs[:, :, 1]
        limit = np.where(toward > 1e-6, (args.back - center[1]) / np.maximum(toward, 1e-6),
                         np.inf)
        grid = np.minimum(grid, np.where(limit > 0, limit, np.inf))
    if args.floor is not None:
        down = dirs[:, :, 2]
        limit = np.where(down < -1e-6, (args.floor - center[2]) / np.minimum(down, -1e-6),
                         np.inf)
        grid = np.minimum(grid, np.where(limit > 0, limit, np.inf))

    if args.bound_axes is not None:
        # 방향마다 타원체 표면까지의 거리를 구해 상한으로 쓴다. 중심이 타원체
        # 중심과 다르므로 (중심 + t·방향) 이 타원체 위에 놓이는 t 를 푼다 —
        # 2차식이라 근의 공식이면 된다.
        bc = np.array(args.bound_center if args.bound_center is not None
                      else [0.0, 0.6, 0.2], dtype=np.float64)
        ax = np.array(args.bound_axes, dtype=np.float64)
        offset = (center - bc) / ax
        unit = dirs / ax
        a = np.sum(unit * unit, axis=-1)
        b = 2.0 * np.sum(unit * offset, axis=-1)
        c = float(np.dot(offset, offset)) - 1.0
        disc = np.maximum(b * b - 4 * a * c, 0.0)
        limit = (-b + np.sqrt(disc)) / (2 * a)
        limit = np.where(disc > 0, limit, np.inf)
        pulled = int((limit < grid - 1e-9).sum())
        print(f"[envelope] 두상 타원체 {ax.tolist()} 안으로 눌러 넣은 방향 "
              f"{pulled}개 / {grid.size} (최대 {np.max(grid - np.minimum(grid, limit)):.2f})")
        grid = np.minimum(grid, limit)

    if args.cap_ratio is not None:
        average = wrap_blur(grid, args.cap_smooth)
        capped = np.minimum(grid, average * args.cap_ratio)
        pulled = int((capped < grid - 1e-9).sum())
        print(f"[envelope] 두상 평균의 {args.cap_ratio}배로 눌러 넣은 방향 "
              f"{pulled}개 / {grid.size} (최대 {np.max(grid - capped):.2f})")
        grid = capped

    grid = wrap_blur(grid, args.smooth)

    # 구면 격자로 껍질을 짓는다. 방위는 한 바퀴 돌므로 마지막 줄을 한 번 더
    # 두어 UV 이음매를 만든다 (같은 자리, u 만 1).
    az, el = args.az, args.el
    verts, uvs = [], []
    for i in range(az + 1):
        theta = -math.pi + 2 * math.pi * (i % az) / az
        for j in range(el):
            phi = -math.pi / 2 + math.pi * (j + 0.5) / el
            r = grid[i % az, j]
            direction = np.array([math.sin(theta) * math.cos(phi),
                                  math.cos(theta) * math.cos(phi),
                                  math.sin(phi)])
            verts.append(center + r * direction)
            uvs.append((i / az, (j + 0.5) / el))
    verts = np.array(verts)

    if args.face_mesh:
        verts = push_behind_face(verts, args.face_mesh, args.push)

    quads = []
    for i in range(az):
        for j in range(el - 1):
            a = i * el + j
            b = (i + 1) * el + j
            quads.append((a, b, b + 1, a + 1))

    with open(args.out, "w", encoding="utf-8") as fp:
        fp.write("# envelope_head.py\n")
        for v in verts:
            fp.write(f"v {v[0]:.6f} {v[1]:.6f} {v[2]:.6f}\n")
        for u, v in uvs:
            fp.write(f"vt {u:.6f} {v:.6f}\n")
        for q in quads:
            idx = " ".join(f"{i + 1}/{i + 1}" for i in q)
            fp.write(f"f {idx}\n")
    print(f"[envelope] 정점 {len(verts)} / 면 {len(quads)} -> {args.out}")


main()
