"""깎아낸 머리 덩어리를 **얼굴 격자와 같은 좌표계**로 옮긴다.

    python tools/hologram/fit_head.py --points face_points.json ^
        --hull head_mesh.ply --out head_fitted.ply

닮음변환(회전·크기·이동)은 `face_points.py` 가 이미 풀어서 JSON 에 넣어 뒀다.
여기서는 그걸 메시에 발라 주기만 한다 — mediapipe 가 없는 일반 파이썬에서
돌게 하려고 갈라 놓았다.

옮기고 나면 덩어리는 얼굴 격자와 같은 규칙을 따른다: 원점이 얼굴 한가운데,
얼굴이 -Y(카메라) 쪽, 위가 +Z, 크기는 얼굴 반지름이 대략 1.
"""

import argparse
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ply_io import read_ply, write_ply  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--points", required=True, help="face_points.py 가 낸 JSON")
parser.add_argument("--hull", required=True, help="깎아낸 머리 메시 (PLY)")
parser.add_argument("--out", required=True, help="옮겨 쓸 PLY 경로")
parser.add_argument("--face-mesh", default=None,
                    help="주면 얼굴이 덮는 앞면을 도려낸다 (face_to_mesh.py 의 JSON)")
parser.add_argument("--front-margin", type=float, default=0.04,
                    help="얼굴 표면보다 이만큼 뒤까지 도려낸다. 겹쳐서 깜빡이는 "
                         "것(z-fighting)을 막는 여유다")
parser.add_argument("--depth-grid", type=int, default=224,
                    help="얼굴 깊이를 재는 격자 해상도")
parser.add_argument("--cut-inset", type=int, default=10,
                    help="얼굴 자리를 이 칸만큼 **안쪽으로 줄여서** 도려낸다. "
                         "테두리까지 잘라내면 얼굴 격자와 머리 사이가 뚫린다")
parser.add_argument("--push", type=float, default=0.0,
                    help="얼굴이 덮는 자리의 머리 표면을 **뒤로 민다** (도려내지 "
                         "않는다). 이 값만큼 사진 얼굴보다 뒤에 있게 한다. "
                         "도려내면 경계가 어긋날 때 구멍이 나지만, 밀면 표면이 "
                         "이어진 채로 남아서 뚫릴 자리가 없다")
parser.add_argument("--no-cut", action="store_true",
                    help="앞면을 도려내지 않고 **머리를 통째로** 남긴다. 사진 얼굴은 "
                         "그 앞에 얹힌다 — 경계가 어긋날 일이 없어서 구멍이 안 생긴다")
parser.add_argument("--shrink", type=float, default=0.985,
                    help="머리를 제 중심으로 이만큼 줄인다. 사진 얼굴이 항상 "
                         "머리보다 앞에 있게 하는 여유다 (z-fighting 방지)")
args = parser.parse_args()


def face_depth_map(face_json, n):
    """얼굴 앞면의 깊이를 (X, Z) 격자에 굽는다.

    얼굴은 -Y 를 보므로 **가장 작은 Y** 가 앞면이다. 삼각형마다 덮는 칸을
    무게중심 좌표로 찾아 Y 를 채운다. 없는 칸은 nan 으로 남는다 — 얼굴이
    없는 자리라는 뜻이고, 거기 덩어리는 건드리지 않는다.
    """
    with open(face_json, "r", encoding="utf-8") as fp:
        payload = json.load(fp)
    verts = np.array(payload["vertices"], dtype=np.float64)
    tris = [f for f in payload.get("faces", []) if len(f) == 3]
    if not tris:
        raise SystemExit("얼굴 격자에 삼각형이 없다")

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

        (ax, az), (bx, bz), (cx, cz) = cell
        det = (bz - cz) * (ax - cx) + (cx - bx) * (az - cz)
        if abs(det) < 1e-12:
            continue
        w0 = ((bz - cz) * (px - cx) + (cx - bx) * (pz - cz)) / det
        w1 = ((cz - az) * (px - cx) + (ax - cx) * (pz - cz)) / det
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


def erode(mask, steps):
    """참인 영역을 가장자리에서 steps 칸 깎는다 (4방향)."""
    out = mask.copy()
    for _ in range(max(steps, 0)):
        shrunk = out.copy()
        shrunk[1:, :] &= out[:-1, :]
        shrunk[:-1, :] &= out[1:, :]
        shrunk[:, 1:] &= out[:, :-1]
        shrunk[:, :-1] &= out[:, 1:]
        out = shrunk
    return out


def push_front(verts, face_json, margin, n, feather=14):
    """얼굴이 덮는 자리의 머리 표면을 뒤로 민다.

    도려내기(cut_front)의 대안이다. 도려내면 잘린 경계가 얼굴 격자의 테두리와
    조금만 어긋나도 그 사이가 **뚫린다** — 귀 옆이 비고, 메우려고 더 자르면
    다른 데가 또 비었다. 미는 방식은 표면이 이어진 채로 남아서 뚫릴 자리가
    아예 없다. 사진 얼굴은 늘 앞에 있고, 그 뒤에 머리가 붙어 있다.

    경계에서는 미는 양을 서서히 0 으로 줄인다(feather). 안 그러면 밀린 자리와
    안 밀린 자리 사이에 단이 진다.
    """
    depth, lo, span = face_depth_map(face_json, n)
    covered = ~np.isnan(depth)

    # 경계에서 0, 안쪽에서 1 로 올라가는 가중치. 침식을 거듭해 거리를 흉내낸다.
    weight = np.zeros((n, n), dtype=np.float64)
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

    moved = verts.copy()
    idx = np.where(inside)[0]
    face_y = depth[ix[idx], iz[idx]]
    w = weight[ix[idx], iz[idx]]
    hit = ~np.isnan(face_y) & (w > 0)
    idx, face_y, w = idx[hit], face_y[hit], w[hit]

    want = face_y + margin
    pushed = np.maximum(moved[idx, 1], want)
    moved[idx, 1] = moved[idx, 1] * (1.0 - w) + pushed * w
    print(f"[fit] 얼굴 자리 {len(idx)}개 정점을 뒤로 밀었다 "
          f"(최대 {np.max(pushed - verts[idx, 1]):.3f})")
    return moved


def cut_front(verts, faces, colors, face_json, margin, n, inset=0):
    """얼굴이 덮는 앞면 폴리곤을 지운다.

    평면으로 뭉텅 자르면 안 된다 — 자른 자리가 얼굴 윤곽보다 넓어서 테두리에
    구멍이 둘러진다. **얼굴 표면보다 앞에 있는 면만** 지우면 잘린 자리가 곧
    얼굴 격자의 테두리라 사진이 그 구멍을 정확히 메운다.
    """
    depth, lo, span = face_depth_map(face_json, n)

    # **얼굴 자리를 안쪽으로 줄인다.** 테두리까지 도려내면 얼굴 격자가 못 덮는
    # 자리(귀 옆, 턱 바깥)가 뚫린 채로 남아서 배경이 비쳐 보인다. 얼굴 격자는
    # 3D 로 보면 머리보다 좁아서, 딱 맞춰 자르면 그 차이만큼이 구멍이 된다.
    if inset > 0:
        keep_cell = erode(~np.isnan(depth), inset)
        depth = np.where(keep_cell, depth, np.nan)

    centers = np.array([verts[f].mean(axis=0) for f in faces])
    cell = (centers[:, [0, 2]] - lo) / span * (n - 1)
    ix = np.rint(cell[:, 0]).astype(int)
    iz = np.rint(cell[:, 1]).astype(int)
    within = (ix >= 0) & (ix < n) & (iz >= 0) & (iz < n)

    front = np.zeros(len(faces), dtype=bool)
    idx = np.where(within)[0]
    face_y = depth[ix[idx], iz[idx]]
    covered = ~np.isnan(face_y) & (centers[idx, 1] < face_y + margin)
    front[idx[covered]] = True

    keep = [f for f, drop in zip(faces, front) if not drop]
    print(f"[fit] 앞면 {int(front.sum())}면을 도려냈다 (남은 {len(keep)}면)")

    # 남은 면이 쓰는 정점만 추린다.
    used = sorted({i for f in keep for i in f})
    remap = {old: new for new, old in enumerate(used)}
    trimmed = None if colors is None else colors[used]
    return verts[used], [[remap[i] for i in f] for f in keep], trimmed


def main():
    with open(args.points, "r", encoding="utf-8") as fp:
        payload = json.load(fp)
    if "fit" not in payload:
        raise SystemExit("face_points.json 에 닮음변환이 없다 "
                         "— face_points.py 에 --face-mesh 를 줘라")

    fit = payload["fit"]
    R = np.array(fit["rotation"], dtype=np.float64)
    scale = float(fit["scale"])
    t = np.array(fit["translation"], dtype=np.float64)

    verts, faces, colors = read_ply(args.hull)
    moved = scale * (R @ verts.T).T + t

    # 머리를 살짝 줄인다. 사진 얼굴과 머리의 얼굴 부분은 거의 같은 자리라
    # 그대로 두면 서로 파고들며 깜빡인다(z-fighting). 조금 안쪽으로 넣으면
    # 사진이 항상 이긴다.
    if args.shrink and args.shrink != 1.0:
        center = moved.mean(axis=0)
        moved = center + (moved - center) * args.shrink

    if args.face_mesh and args.push > 0:
        moved = push_front(moved, args.face_mesh, args.push, args.depth_grid)
    elif args.face_mesh and not args.no_cut:
        moved, faces, colors = cut_front(moved, faces, colors, args.face_mesh,
                                         args.front_margin, args.depth_grid,
                                         args.cut_inset)
    write_ply(args.out, moved, faces, colors=colors)

    lo, hi = moved.min(axis=0), moved.max(axis=0)
    print(f"[fit] 정점 {len(verts)} / 면 {len(faces)}")
    print(f"[fit] 상자 {np.round(lo, 2).tolist()} ~ {np.round(hi, 2).tolist()} "
          f"(얼굴 반지름 1 기준)")
    print(f"[fit] -> {args.out}")


main()
