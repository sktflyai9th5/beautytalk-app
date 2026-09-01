"""점구름에서 **튀는 점을 걷어낸다.**

    python tools/hologram/denoise_cloud.py --cloud merged.ply --out clean.ply ^
        --cell 0.05 --min-neighbors 25

밀집 스테레오는 머리카락 언저리에서 허공에 점을 몇 개씩 흘린다. 그 점 하나가
포아송에서는 **혹 하나**가 되고, 실루엣에 잔가시처럼 삐져나온다. 머리가
'뜯어진' 것처럼 보이는 게 이것이다. 표면을 나중에 문질러도 이미 생긴 가시는
잘 안 없어진다 — **면을 뜨기 전에** 점에서 걷어내야 한다.

두 가지를 본다.

  · **이웃 수.** 진짜 표면 위의 점은 둘레에 점이 수십 개 있고, 허공에 뜬 점은
    몇 개뿐이다.
  · **표면에서 벗어난 정도.** 이웃들의 평균 자리에서 지나치게 멀면 (전체
    표준편차의 몇 배) 그 점은 표면 위가 아니라 그 옆에 떠 있는 것이다.

점 하나하나를 돌면 수백만 점에서 너무 느리다. **칸 단위로 세어 두고 27칸을
더한다** — 반복문 없이 배열 연산만으로 끝난다.
"""

import argparse
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ply_io import read_ply, write_ply  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--cloud", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--cell", type=float, default=0.05,
                    help="칸 크기. 이 칸과 둘레 26칸을 이웃으로 친다")
parser.add_argument("--min-neighbors", type=int, default=25,
                    help="이웃이 이보다 적으면 버린다")
parser.add_argument("--std-ratio", type=float, default=2.0,
                    help="이웃 평균에서 표준편차의 이 배보다 멀면 버린다. "
                         "0 이면 이 검사를 안 한다")
args = parser.parse_args()


def neighbourhood(dims, cells, values=None):
    """칸마다의 합을 구하고, 그것을 27칸으로 더해 준다.

    values 가 없으면 개수를 센다. 있으면 그 값(Nx3 도 된다)을 더한다.
    """
    shape = tuple(dims)
    if values is None:
        grid = np.zeros(shape, dtype=np.float64)
        np.add.at(grid, (cells[:, 0], cells[:, 1], cells[:, 2]), 1.0)
        grids = [grid]
    else:
        grids = []
        for c in range(values.shape[1]):
            grid = np.zeros(shape, dtype=np.float64)
            np.add.at(grid, (cells[:, 0], cells[:, 1], cells[:, 2]), values[:, c])
            grids.append(grid)

    out = []
    for grid in grids:
        # 축마다 한 번씩만 훑으면 27칸 합이 된다 (분리 가능한 상자 필터).
        acc = grid
        for axis in (0, 1, 2):
            acc = (acc
                   + np.roll(acc, 1, axis=axis)
                   + np.roll(acc, -1, axis=axis))
        out.append(acc)
    return out


def main():
    verts, faces, colors, normals = read_ply(args.cloud, want_normals=True)
    print(f"[denoise] 받은 점 {len(verts)}")

    cell = args.cell
    lo = verts.min(axis=0) - cell
    dims = np.maximum(((verts.max(axis=0) + cell - lo) / cell).astype(int) + 2, 3)
    cells = np.clip(((verts - lo) / cell).astype(int), 0, dims - 1)

    (count_grid,) = neighbourhood(dims, cells)
    sum_grids = neighbourhood(dims, cells, verts)

    count = count_grid[cells[:, 0], cells[:, 1], cells[:, 2]]
    mean = np.stack([g[cells[:, 0], cells[:, 1], cells[:, 2]] for g in sum_grids],
                    axis=1) / np.maximum(count, 1.0)[:, None]
    drift = np.linalg.norm(mean - verts, axis=1)

    alive = count >= args.min_neighbors
    print(f"[denoise] 이웃이 적어 버린 점 {int((~alive).sum())} "
          f"({(~alive).mean() * 100:.1f}%)")

    if args.std_ratio > 0 and alive.any():
        good = drift[alive]
        limit = float(good.mean() + args.std_ratio * good.std())
        far = alive & (drift > limit)
        alive = alive & ~far
        print(f"[denoise] 표면에서 벗어나 버린 점 {int(far.sum())} "
              f"(기준 {limit:.4f})")

    print(f"[denoise] 남은 점 {int(alive.sum())} ({alive.mean() * 100:.1f}%)")
    write_ply(args.out, verts[alive], [],
              colors=None if colors is None else colors[alive],
              normals=None if normals is None else normals[alive])
    print(f"[denoise] -> {args.out}")


main()
