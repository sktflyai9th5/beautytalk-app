"""이미 UV·텍스처가 붙은 머리에서 **아래를 평평하게 잘라내고 뚜껑을 덮는다.**

    python tools/hologram/trim_bottom.py --mesh head.obj --out head_cut.obj --z -1.25

`clean_dense.py` 로 다시 자르면 UV 가 새로 펴져서 **텍스처를 20분 다시 구워야
한다.** 여기서는 면만 지우고 남은 정점의 UV 를 그대로 두므로 텍스처를 그대로
쓴다. 길이만 조금 손보고 싶을 때 쓴다.

**바닥은 평평하게 잘라라.** 곡선으로 자르면 그 구멍을 메운 뚜껑이 비스듬히
서서 정면에서 판때기로 보인다 (실제로 얼굴 옆에 갈색 널빤지가 붙었다).
수평으로 자르면 뚜껑이 아래를 향해 카메라와 나란해져서 안 보인다.

뚜껑은 테두리를 한 점으로 모으는 부채꼴로 덮는다. 그 점의 UV 는 테두리
UV 의 평균으로 둔다 — 아래를 보고 있어서 무슨 색이든 거의 안 보인다.
"""

import argparse
import math

import numpy as np

parser = argparse.ArgumentParser()
parser.add_argument("--mesh", required=True, help="UV 가 있는 OBJ")
parser.add_argument("--out", required=True)
parser.add_argument("--z", type=float, required=True, help="이 높이 아래를 자른다")
parser.add_argument("--dome", type=float, default=0.9,
                    help="마감을 아래로 얼마나 볼록하게 할지 (테두리 반지름 대비). "
                         "0 이면 평평한 뚜껑이 되는데, 그러면 널빤지로 보인다")
parser.add_argument("--dome-rings", type=int, default=3,
                    help="돔을 몇 겹으로 나눌지. 많을수록 매끈하다")
parser.add_argument("--no-cap", action="store_true", help="뚜껑을 안 덮는다")
args = parser.parse_args()


def main():
    verts, uvs, faces, others = [], [], [], []
    for line in open(args.mesh, "r", encoding="utf-8"):
        line = line.rstrip("\n")
        if line.startswith("v "):
            verts.append([float(x) for x in line.split()[1:4]])
        elif line.startswith("vt "):
            uvs.append([float(x) for x in line.split()[1:3]])
        elif line.startswith("f "):
            corners = []
            for chunk in line.split()[1:]:
                part = chunk.split("/")
                corners.append((int(part[0]) - 1,
                                int(part[1]) - 1 if len(part) > 1 and part[1]
                                else -1))
            faces.append(corners)
        elif not line.startswith(("vn ", "s ", "o ", "g ", "usemtl", "mtllib")):
            others.append(line)

    V = np.array(verts, dtype=np.float64)
    UV = np.array(uvs, dtype=np.float64)
    keep_vert = V[:, 2] >= args.z
    kept = [f for f in faces if all(keep_vert[c[0]] for c in f)]
    print(f"[trim] 면 {len(faces)} -> {len(kept)} "
          f"(정점 {len(V)} 중 {int((~keep_vert).sum())}개가 {args.z} 아래)")

    # 테두리 = 남은 면에서 한 번만 쓰인 변.
    edges = {}
    for f in kept:
        n = len(f)
        for i in range(n):
            a, b = f[i][0], f[(i + 1) % n][0]
            key = (min(a, b), max(a, b))
            edges[key] = edges.get(key, 0) + 1
    border = [e for e, n in edges.items() if n == 1]
    print(f"[trim] 테두리 변 {len(border)}개")

    if border and not args.no_cap:
        ring = sorted({v for e in border for v in e})
        centre = V[ring].mean(axis=0)
        radius = float(np.mean(np.linalg.norm(V[ring][:, :2] - centre[:2], axis=1)))

        uv_of = {}
        for f in kept:
            for vi, ti in f:
                if ti >= 0:
                    uv_of.setdefault(vi, ti)

        # **평평한 뚜껑을 덮지 마라.** 카메라가 머리 중심 높이에 있으면 그보다
        # 아래에 있는 수평면을 위에서 내려다보게 되어, 뚜껑의 안쪽이 통째로
        # 보인다 — 얼굴 옆에 널빤지가 붙은 것처럼 보였다. 아래로 볼록한 돔으로
        # 마감하면 테두리 쪽 표면이 거의 수직이라 바깥면이 보이고, 머리카락
        # 끝이 둥글게 모인 것처럼 읽힌다.
        rings = max(args.dome_rings, 1)
        new_index = {}
        prev = {v: v for v in ring}
        for k in range(1, rings + 1):
            theta = (math.pi / 2) * k / (rings + 1)
            shrink = math.cos(theta)
            drop = math.sin(theta) * radius * args.dome
            layer = {}
            for v in ring:
                p = centre + (V[v] - centre) * shrink
                p[2] = V[v][2] * shrink + centre[2] * (1 - shrink) - drop
                V = np.vstack([V, p])
                layer[v] = len(V) - 1
                new_index[len(V) - 1] = uv_of.get(v, 0)
            for a, b in border:
                pa, pb = prev[a], prev[b]
                qa, qb = layer[a], layer[b]
                ua = new_index.get(pa, uv_of.get(a, 0))
                ub = new_index.get(pb, uv_of.get(b, 0))
                kept.append([(pa, ua), (pb, ub), (qb, new_index[qb]),
                             (qa, new_index[qa])])
            prev = layer

        apex = centre.copy()
        apex[2] = centre[2] - radius * args.dome
        V = np.vstack([V, apex])
        ai = len(V) - 1
        new_index[ai] = uv_of.get(ring[0], 0)
        for a, b in border:
            pa, pb = prev[a], prev[b]
            kept.append([(pa, new_index.get(pa, uv_of.get(a, 0))),
                         (pb, new_index.get(pb, uv_of.get(b, 0))),
                         (ai, new_index[ai])])
        print(f"[trim] 아래로 볼록한 돔으로 마감했다 "
              f"(테두리 {len(border)}변 / 고리 {rings}겹 / 깊이 "
              f"{radius * args.dome:.3f})")

    with open(args.out, "w", encoding="utf-8") as fp:
        for line in others:
            fp.write(line + "\n")
        for x, y, z in V:
            fp.write(f"v {x:.6f} {y:.6f} {z:.6f}\n")
        for u, v in UV:
            fp.write(f"vt {u:.6f} {v:.6f}\n")
        for f in kept:
            parts = " ".join(f"{vi + 1}/{ti + 1}" if ti >= 0 else f"{vi + 1}"
                             for vi, ti in f)
            fp.write(f"f {parts}\n")
    print(f"[trim] -> {args.out}")


main()
