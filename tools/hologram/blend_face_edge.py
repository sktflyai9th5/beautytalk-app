"""사진 얼굴이 끝나는 자리에서 **머리 텍스처를 사진 색으로 이어 칠한다.**

    python tools/hologram/blend_face_edge.py --mesh head.obj --texture head_tex.png ^
        --face face_retouched.jpg --face-mesh face_mesh.json --out head_blend.png

사진 얼굴은 mediapipe 격자 위에 얹히는데, 그 격자의 바깥 테두리는 랜드마크를
이은 **들쭉날쭉한 다각형**이다. 사진이 거기서 뚝 끊기고 그 너머는 머리 텍스처라,
두 출처의 노출·화이트밸런스가 다르면 그 턱이 **테두리 모양 그대로** 드러난다.
무언가 덧대어 놓은 것처럼 보이는 게 이것이다. 머리를 뒤로 밀어도 안 없어진다 —
형상 문제가 아니라 색 문제이기 때문이다 (밀기를 0.5까지 키워도 그대로였다).

여기서는 머리 텍스처의 텍셀 중 **얼굴 격자가 덮는 자리**를 골라 그 자리의 사진
색을 그대로 칠하고, 경계 바깥으로는 서서히 원래 색으로 돌아가게 한다. 경계
양쪽이 같은 사진에서 온 같은 색이 되므로 턱이 생길 수가 없다.

얼굴 격자는 자기 화면 좌표(`points_2d`)를 들고 있다. 그게 곧 사진 안에서의
자리라, 격자를 (X, Z) 평면에 굽고 칸마다 사진 UV 를 적어 두면 조회가 된다.
"""

import argparse
import json

import numpy as np
from PIL import Image

parser = argparse.ArgumentParser()
parser.add_argument("--mesh", required=True, help="UV 가 있는 머리 OBJ")
parser.add_argument("--texture", required=True, help="구워 둔 머리 텍스처 PNG")
parser.add_argument("--face", required=True, help="사진 얼굴 이미지")
parser.add_argument("--face-mesh", required=True, help="face_to_mesh.py 의 JSON")
parser.add_argument("--out", required=True)
parser.add_argument("--grid", type=int, default=256, help="얼굴을 굽는 (X,Z) 격자")
parser.add_argument("--margin", type=int, default=26,
                    help="얼굴 바깥으로 이 칸만큼 번지며 원래 색으로 돌아간다")
parser.add_argument("--depth", type=float, default=0.45,
                    help="얼굴 표면에서 이보다 뒤에 있는 텍셀은 건드리지 않는다. "
                         "뒤통수까지 사진 색이 묻으면 안 된다")
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


def bake_face_plane(mesh_path, n):
    """얼굴 격자를 (X, Z) 칸에 굽는다: 칸마다 깊이(Y)와 사진 UV."""
    payload = json.load(open(mesh_path, "r", encoding="utf-8"))
    verts = np.array(payload["vertices"], dtype=np.float64)
    uv = np.array(payload["points_2d"], dtype=np.float64)
    tris = [f for f in payload.get("faces", []) if len(f) == 3]

    lo = verts[:, [0, 2]].min(axis=0)
    span = np.maximum(verts[:, [0, 2]].max(axis=0) - lo, 1e-9)
    # 얼굴 상자보다 넓게 잡는다. 딱 맞게 잡으면 경계 바깥으로 번질 칸이 없다.
    pad = span * 0.35
    lo = lo - pad
    span = span + 2 * pad
    depth = np.full((n, n), np.nan)
    tex_u = np.full((n, n), np.nan)
    tex_v = np.full((n, n), np.nan)

    for tri in tris:
        p = verts[tri]
        t = uv[tri]
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
        u = w0 * t[0, 0] + w1 * t[1, 0] + w2 * t[2, 0]
        v = w0 * t[0, 1] + w1 * t[1, 1] + w2 * t[2, 1]
        ix, iz = px[inside], pz[inside]
        cur = depth[ix, iz]
        better = np.isnan(cur) | (y[inside] < cur)
        sel = (ix[better], iz[better])
        depth[sel] = y[inside][better]
        tex_u[sel] = u[inside][better]
        tex_v[sel] = v[inside][better]
    return depth, tex_u, tex_v, lo, span


def spread(grid, times):
    """빈 칸(nan)을 이웃 값으로 채운다. 경계 바깥까지 조회할 수 있게 한다."""
    out = grid.copy()
    for _ in range(times):
        hole = np.isnan(out)
        if not hole.any():
            break
        for nb in (np.roll(out, 1, 0), np.roll(out, -1, 0),
                   np.roll(out, 1, 1), np.roll(out, -1, 1)):
            take = hole & ~np.isnan(nb)
            out[take] = nb[take]
            hole = hole & ~take
    return out


def rasterize(values, uvs, faces, size):
    """UV 삼각형을 텍셀 격자에 채워 값과 유효 마스크를 만든다."""
    out = np.zeros((size, size, values.shape[1]))
    filled = np.zeros((size, size), dtype=bool)
    for tri in faces:
        vi = [c[0] for c in tri]
        ti = [c[1] for c in tri]
        if min(ti) < 0:
            continue
        p = values[vi]
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
        out[iy, ix] = bary @ p
        filled[iy, ix] = True
    return out, filled


def main():
    verts, uvs, faces = read_obj(args.mesh)
    tex = np.asarray(Image.open(args.texture).convert("RGB"), dtype=np.float64)
    photo = np.asarray(Image.open(args.face).convert("RGB"), dtype=np.float64)
    size = tex.shape[0]

    n = args.grid
    depth, tex_u, tex_v, lo, span = bake_face_plane(args.face_mesh, n)
    covered = ~np.isnan(depth)

    # 얼굴 자리에서 1, 바깥으로 margin 칸에 걸쳐 0 으로 떨어지는 가중치.
    weight = covered.astype(np.float64)
    edge = covered.copy()
    for step in range(args.margin):
        wider = edge.copy()
        wider[1:, :] |= edge[:-1, :]
        wider[:-1, :] |= edge[1:, :]
        wider[:, 1:] |= edge[:, :-1]
        wider[:, :-1] |= edge[:, 1:]
        fresh = wider & ~edge
        weight[fresh] = 1.0 - (step + 1) / (args.margin + 1)
        edge = wider

    # 넓힌 칸에는 깊이·UV 가 없으니 가장 가까운 얼굴 칸에서 끌어온다.
    depth = spread(depth, args.margin + 2)
    tex_u = spread(tex_u, args.margin + 2)
    tex_v = spread(tex_v, args.margin + 2)

    pos, filled = rasterize(verts, uvs, faces, size)
    ys, xs = np.where(filled)
    p = pos[filled]

    cell = (p[:, [0, 2]] - lo) / span * (n - 1)
    raw_x = np.rint(cell[:, 0]).astype(int)
    raw_z = np.rint(cell[:, 1]).astype(int)
    # **격자 밖을 잘라 넣지 마라.** clip 을 쓰면 얼굴보다 위에 있는 정수리
    # 텍셀이 격자 맨 윗줄로 끌려가서 앞머리 색을 그대로 받는다 — 머리 위로
    # 세로 줄무늬가 죽 늘어섰다. 밖은 그냥 안 칠한다.
    within = ((raw_x >= 0) & (raw_x < n) & (raw_z >= 0) & (raw_z < n))
    ix = np.clip(raw_x, 0, n - 1)
    iz = np.clip(raw_z, 0, n - 1)
    w = weight[ix, iz]
    fy = depth[ix, iz]
    behind = p[:, 1] - fy
    ok = within & (w > 0) & ~np.isnan(fy) & (behind < args.depth)
    w = np.where(ok, w, 0.0)

    ph, pw = photo.shape[:2]
    su = np.clip((np.nan_to_num(tex_u[ix, iz]) * (pw - 1)).astype(int), 0, pw - 1)
    sv = np.clip((np.nan_to_num(tex_v[ix, iz]) * (ph - 1)).astype(int), 0, ph - 1)
    sampled = photo[sv, su]

    out = tex.copy()
    out[ys, xs] = out[ys, xs] * (1 - w[:, None]) + sampled * w[:, None]
    print(f"[blend] 텍셀 {len(p)} 중 {int((w > 0).sum())}개를 사진 색으로 이었다 "
          f"(완전히 덮은 것 {int((w >= 0.999).sum())})")

    Image.fromarray(np.clip(out, 0, 255).astype(np.uint8)).save(args.out)
    print(f"[blend] -> {args.out}")


main()
