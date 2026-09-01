"""얼굴이 덮는 자리의 머리 표면을 **사진 얼굴 뒤로 민다** (OBJ 의 UV 를 지킨 채).

    python tools/hologram/push_face.py --mesh head.obj --face-mesh face_mesh.json ^
        --out head_pushed.obj --push 0.06

도려내지 않는다. 도려내면 잘린 경계가 얼굴 격자 테두리와 조금만 어긋나도 그
사이가 뚫린다 — 귀 옆이 비고, 메우려고 더 자르면 다른 데가 또 빈다. 미는 쪽은
표면이 이어진 채로 남아서 뚫릴 자리가 아예 없다.

OBJ 의 `v` 줄만 고치고 나머지(UV·면·법선)는 글자 그대로 옮긴다. 다시 내보내면
Smart UV Project 로 편 UV 가 흐트러지기 때문이다.
"""

import argparse
import json

import numpy as np

parser = argparse.ArgumentParser()
parser.add_argument("--mesh", required=True, help="UV 가 있는 OBJ")
parser.add_argument("--face-mesh", required=True, help="face_to_mesh.py 의 JSON")
parser.add_argument("--out", required=True)
parser.add_argument("--push", type=float, default=0.06,
                    help="사진 얼굴보다 이만큼 뒤에 있게 한다")
parser.add_argument("--grid", type=int, default=224, help="얼굴 깊이를 재는 격자")
parser.add_argument("--feather", type=int, default=14,
                    help="경계에서 미는 양을 0 으로 줄이는 폭. 없으면 단이 진다")
args = parser.parse_args()


def face_depth_map(path, n):
    """얼굴 앞면의 깊이를 (X, Z) 격자에 굽는다. 얼굴은 -Y 를 본다."""
    with open(path, "r", encoding="utf-8") as fp:
        payload = json.load(fp)
    verts = np.array(payload["vertices"], dtype=np.float64)
    tris = [f for f in payload.get("faces", []) if len(f) == 3]
    lo = verts[:, [0, 2]].min(axis=0)
    span = np.maximum(verts[:, [0, 2]].max(axis=0) - lo, 1e-9)
    depth = np.full((n, n), np.nan)
    for tri in tris:
        p = verts[tri]
        cell = (p[:, [0, 2]] - lo) / span * (n - 1)
        x0, z0 = np.floor(cell.min(axis=0)).astype(int)
        x1, z1 = np.ceil(cell.max(axis=0)).astype(int)
        x0, z0, x1, z1 = max(x0, 0), max(z0, 0), min(x1, n - 1), min(z1, n - 1)
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
        cur = depth[ix, iz]
        better = np.isnan(cur) | (yy < cur)
        depth[ix[better], iz[better]] = yy[better]
    return depth, lo, span


def main():
    n = args.grid
    depth, lo, span = face_depth_map(args.face_mesh, n)
    covered = ~np.isnan(depth)

    weight = np.zeros((n, n))
    mask = covered.copy()
    for step in range(args.feather):
        shrunk = mask.copy()
        shrunk[1:, :] &= mask[:-1, :]
        shrunk[:-1, :] &= mask[1:, :]
        shrunk[:, 1:] &= mask[:, :-1]
        shrunk[:, :-1] &= mask[:, 1:]
        weight[shrunk] = (step + 1) / args.feather
        mask = shrunk

    lines = open(args.mesh, "r", encoding="utf-8").read().splitlines()
    order = [i for i, l in enumerate(lines) if l.startswith("v ")]
    verts = np.array([[float(x) for x in lines[i].split()[1:4]] for i in order])

    cell = (verts[:, [0, 2]] - lo) / span * (n - 1)
    ix = np.rint(cell[:, 0]).astype(int)
    iz = np.rint(cell[:, 1]).astype(int)
    inside = (ix >= 0) & (ix < n) & (iz >= 0) & (iz < n)
    idx = np.where(inside)[0]
    face_y = depth[ix[idx], iz[idx]]
    w = weight[ix[idx], iz[idx]]
    hit = ~np.isnan(face_y) & (w > 0)
    idx, face_y, w = idx[hit], face_y[hit], w[hit]

    before = verts[idx, 1].copy()
    pushed = np.maximum(before, face_y + args.push)
    verts[idx, 1] = before * (1.0 - w) + pushed * w
    moved = int((verts[idx, 1] > before + 1e-6).sum())
    gain = float(np.max(verts[idx, 1] - before)) if len(idx) else 0.0
    print(f"[push] 얼굴 자리 정점 {len(idx)}개 중 {moved}개를 뒤로 밀었다 "
          f"(최대 {gain:.3f})")

    for k, i in enumerate(order):
        x, y, z = verts[k]
        lines[i] = f"v {x:.6f} {y:.6f} {z:.6f}"
    with open(args.out, "w", encoding="utf-8") as fp:
        fp.write("\n".join(lines) + "\n")
    print(f"[push] -> {args.out}")


main()
