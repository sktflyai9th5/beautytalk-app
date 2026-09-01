"""밀집 복원과 실루엣 깎기를 **서로의 빈 곳을 메우게** 합친다.

    python tools/hologram/merge_head.py --dense head_cloud.ply ^
        --carve head_raw.ply --face-mesh face_mesh.json --out merged.ply

두 방법은 못하는 게 정확히 반대다.

  · **밀집 스테레오**는 화소를 맞춰 깊이를 재니 귀·눈두덩 같은 **오목한 데가
    나온다.** 대신 무늬가 없으면 대응이 안 잡힌다 — 어두운 뒷머리가 통째로
    비어 있다 (진희님은 뒤쪽 방향의 점이 다른 방향의 1/40 이었다).
  · **실루엣 깎기**는 윤곽선만 보므로 무늬가 없어도 **어디든 채운다.** 대신
    윤곽선 안쪽은 볼 수가 없어서 오목한 데가 원리상 안 파인다.

그래서 **밀집이 있는 방향은 밀집을, 없는 방향은 실루엣을** 쓴다. 경계에서는
둘을 겹쳐 둬야 포아송이 이어 붙인다.

한 가지 더 한다. 실루엣 깎기는 **부풀어 있다** — 흔들리는 머리카락이 서로를
못 깎아서 뒤통수가 실제보다 멀리 나온다 (진희님은 깊이가 폭의 1.44배, 사람
머리는 1.2배쯤이다). 두 방법이 **겹치는 방향에서 반지름 비를 재서**, 그 비를
빈 방향까지 펴 바른 뒤 실루엣 점을 끌어당긴다. 어림짐작이 아니라 잰 값이다.
"""

import argparse
import json
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ply_io import read_ply, write_ply  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--dense", required=True, help="밀집 복원 점구름 (얼굴 격자 좌표)")
parser.add_argument("--carve", required=True, help="실루엣으로 깎은 점구름 (같은 좌표)")
parser.add_argument("--out", required=True)
parser.add_argument("--center", type=float, nargs=3, default=[0.0, 0.55, 0.15],
                    help="방향을 세는 기준점 (두상 한가운데)")
parser.add_argument("--az", type=int, default=72, help="가로 방향 칸 수")
parser.add_argument("--el", type=int, default=36, help="세로 방향 칸 수")
parser.add_argument("--min-dense", type=int, default=60,
                    help="한 방향에 밀집 점이 이만큼은 있어야 '밀집이 봤다'로 친다")
parser.add_argument("--blend", type=int, default=3,
                    help="경계에서 이 칸만큼은 둘 다 넣는다 (포아송이 이어 붙이게)")
parser.add_argument("--percentile", type=float, default=60.0,
                    help="반지름 비를 잴 때 쓰는 백분위")
parser.add_argument("--smooth", type=int, default=6, help="반지름 비를 펴는 횟수")
parser.add_argument("--carve-below", type=float, default=None,
                    help="**이 높이(Z) 아래는 실루엣 쪽만 쓴다.** 턱 아래에서 밀집 "
                         "스테레오가 되살리는 건 머리카락이 아니라 목과 옷깃이다 "
                         "(가는 잔머리는 화소 대응이 안 잡혀서 못 잡는다). 그걸 "
                         "남기면 아바타 밑에 살색·옷 덩어리가 붙고, 잘라내면 그 "
                         "단면이 널빤지로 보인다. 실루엣 쪽은 **머리+얼굴피부 "
                         "마스크로만** 깎았으므로 거기 남은 건 머리카락이다")
parser.add_argument("--no-scale", action="store_true",
                    help="실루엣 점을 끌어당기지 않는다 (비교용)")
args = parser.parse_args()


def bins_of(points, center, az, el):
    """점마다 (가로칸, 세로칸, 반지름) 을 준다."""
    v = points - center
    r = np.linalg.norm(v, axis=1)
    safe = np.maximum(r, 1e-9)
    theta = np.arctan2(v[:, 0], v[:, 1])                 # 0 = 뒤(+Y)
    phi = np.arcsin(np.clip(v[:, 2] / safe, -1.0, 1.0))
    ia = np.clip(((theta + math.pi) / (2 * math.pi) * az).astype(int), 0, az - 1)
    ie = np.clip(((phi + math.pi / 2) / math.pi * el).astype(int), 0, el - 1)
    return ia, ie, r


def wrap_blur(grid, times, weight=None):
    """가로는 한 바퀴 돌므로 감아서 섞는다. weight 가 있으면 가중 평균."""
    value = grid.copy()
    mass = np.ones_like(grid) if weight is None else weight.copy()
    value = value * mass
    for _ in range(max(times, 0)):
        v = (value
             + np.roll(value, 1, 0) + np.roll(value, -1, 0)
             + np.pad(value, ((0, 0), (1, 0)), mode="edge")[:, :-1]
             + np.pad(value, ((0, 0), (0, 1)), mode="edge")[:, 1:])
        m = (mass
             + np.roll(mass, 1, 0) + np.roll(mass, -1, 0)
             + np.pad(mass, ((0, 0), (1, 0)), mode="edge")[:, :-1]
             + np.pad(mass, ((0, 0), (0, 1)), mode="edge")[:, 1:])
        value, mass = v, m
    return value / np.maximum(mass, 1e-9)


def grow(mask, steps):
    """참인 칸을 사방으로 steps 칸 넓힌다 (가로는 감아서)."""
    out = mask.copy()
    for _ in range(max(steps, 0)):
        out = (out
               | np.roll(out, 1, 0) | np.roll(out, -1, 0)
               | np.pad(out, ((0, 0), (1, 0)), mode="edge")[:, :-1]
               | np.pad(out, ((0, 0), (0, 1)), mode="edge")[:, 1:])
    return out


def main():
    center = np.array(args.center, dtype=np.float64)
    az, el = args.az, args.el

    dense, _, dcol, dnrm = read_ply(args.dense, want_normals=True)
    carve, _, ccol, cnrm = read_ply(args.carve, want_normals=True)
    print(f"[merge] 밀집 {len(dense)}점 / 실루엣 {len(carve)}점")

    da, de, dr = bins_of(dense, center, az, el)
    ca, ce, cr = bins_of(carve, center, az, el)

    count = np.zeros((az, el), dtype=np.int64)
    np.add.at(count, (da, de), 1)
    seen = count >= args.min_dense
    print(f"[merge] 밀집이 본 방향 {int(seen.sum())} / {az * el} "
          f"({seen.mean() * 100:.0f}%)")

    # 겹치는 방향에서 반지름 비를 잰다. 실루엣이 얼마나 부풀었는지가 나온다.
    ratio = np.ones((az, el))
    weight = np.zeros((az, el))
    if not args.no_scale:
        d_order = np.lexsort((dr, de, da))
        c_order = np.lexsort((cr, ce, ca))
        d_key, c_key = (da * el + de)[d_order], (ca * el + ce)[c_order]
        d_start = np.searchsorted(d_key, np.arange(az * el + 1))
        c_start = np.searchsorted(c_key, np.arange(az * el + 1))
        for key in range(az * el):
            i, j = divmod(key, el)
            if not seen[i, j]:
                continue
            dvals = dr[d_order[d_start[key]:d_start[key + 1]]]
            cvals = cr[c_order[c_start[key]:c_start[key + 1]]]
            if len(dvals) < args.min_dense or len(cvals) < 20:
                continue
            d_r = np.percentile(dvals, args.percentile)
            c_r = np.percentile(cvals, args.percentile)
            if c_r > 1e-6:
                ratio[i, j] = d_r / c_r
                weight[i, j] = 1.0
        measured = ratio[weight > 0]
        print(f"[merge] 반지름 비를 잰 방향 {int(weight.sum())}개, "
              f"중앙값 {np.median(measured):.3f} "
              f"(1보다 작으면 실루엣이 부푼 것이다)")
        ratio = wrap_blur(ratio, args.smooth, weight)

    # 밀집이 못 본 방향에만 실루엣을 쓴다. 경계는 겹쳐 둔다.
    use_carve = ~grow(seen, 0)
    overlap = grow(seen, args.blend) & ~seen
    take = use_carve | overlap
    pick = take[ca, ce]
    if args.carve_below is not None:
        # 턱 아래에서는 방향 판정과 무관하게 실루엣을 쓴다.
        pick = pick | (carve[:, 2] < args.carve_below)
    scale = ratio[ca, ce]
    moved = carve.copy()
    if not args.no_scale:
        moved = center + (carve - center) * scale[:, None]
    moved = moved[pick]
    print(f"[merge] 실루엣에서 가져온 점 {int(pick.sum())} "
          f"(빈 방향 {int(use_carve.sum())}칸 + 겹침 {int(overlap.sum())}칸)")

    # 법선. 실루엣 쪽은 없을 수 있으니 중심에서 뻗는 방향으로 대신한다 —
    # 별 모양 껍데기라 그 근사가 맞다.
    if cnrm is None:
        v = moved - center
        cnrm_used = v / np.maximum(np.linalg.norm(v, axis=1, keepdims=True), 1e-9)
    else:
        cnrm_used = cnrm[pick]
    if dnrm is None:
        raise SystemExit("밀집 점구름에 법선이 없다 — 포아송이 못 돈다")

    keep_dense = np.ones(len(dense), dtype=bool)
    if args.carve_below is not None:
        keep_dense = dense[:, 2] >= args.carve_below
        low_carve = moved[:, 2] < args.carve_below
        print(f"[merge] Z {args.carve_below} 아래: 밀집 {int((~keep_dense).sum())}점을 "
              f"버리고 실루엣 {int(low_carve.sum())}점을 남겼다")

    verts = np.vstack([dense[keep_dense], moved])
    normals = np.vstack([dnrm[keep_dense], cnrm_used])
    if dcol is not None and ccol is not None:
        colors = np.vstack([dcol[keep_dense], ccol[pick]])
    else:
        colors = None

    write_ply(args.out, verts, [], colors=colors, normals=normals)
    print(f"[merge] 합쳐서 {len(verts)}점 -> {args.out}")


main()
