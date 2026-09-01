"""밀집 복원 결과에서 **머리만** 오려 내고 얼굴 격자 좌표로 옮긴다.

    python tools/hologram/crop_head.py --cloud fused.ply --points face_points.json ^
        --out head.ply

COLMAP 이 되살리는 건 사람이 아니라 **방 전체**다. 벽·책상·의자가 같이 나오고,
사람은 그 안에 있는 덩어리 하나일 뿐이다. 여기서 머리만 남긴다.

기준은 `face_points.py` 가 삼각측량해 둔 얼굴 랜드마크다. 그게 COLMAP 좌표에서
얼굴이 실제로 어디 있는지 알려 주는 유일한 단서다. 닮음변환까지 풀려 있으므로
**먼저 얼굴 격자 좌표로 옮기고** 나서 자른다 — 그 좌표에서는 원점이 얼굴
한가운데, 얼굴이 -Y, 위가 +Z, 얼굴 반지름이 1 이라 자를 범위를 사람 말로 쓸 수
있다 (턱 아래 -1.3, 뒤통수 +2.2 하는 식).
"""

import argparse
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ply_io import read_ply, write_ply  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--cloud", required=True, help="fused.ply 또는 mesh.ply")
parser.add_argument("--points", required=True, help="face_points.py 가 낸 JSON")
parser.add_argument("--out", required=True)
parser.add_argument("--x", type=float, nargs=2, default=[-1.6, 1.6])
parser.add_argument("--y", type=float, nargs=2, default=[-1.4, 2.6],
                    help="-Y 가 얼굴 앞. 뒤통수까지 남긴다")
parser.add_argument("--z", type=float, nargs=2, default=[-1.6, 2.2],
                    help="아래는 목/어깨, 위는 정수리")
parser.add_argument("--radius", type=float, default=None,
                    help="주면 원점에서 이 거리 밖도 버린다 (상자 모서리 정리)")
args = parser.parse_args()


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

    verts, faces, colors, normals = read_ply(args.cloud, want_normals=True)
    moved = scale * (R @ verts.T).T + t
    if normals is not None:
        # 법선은 방향이라 크기·이동을 받지 않는다. 회전만 먹인다.
        normals = (R @ normals.T).T
    print(f"[crop] 옮긴 점 {len(moved)} / 면 {len(faces)}")

    keep = ((moved[:, 0] >= args.x[0]) & (moved[:, 0] <= args.x[1]) &
            (moved[:, 1] >= args.y[0]) & (moved[:, 1] <= args.y[1]) &
            (moved[:, 2] >= args.z[0]) & (moved[:, 2] <= args.z[1]))
    if args.radius is not None:
        keep &= np.linalg.norm(moved, axis=1) <= args.radius
    print(f"[crop] 머리 범위 안 {int(keep.sum())} 점 "
          f"({keep.mean() * 100:.1f}%)")

    index = -np.ones(len(moved), dtype=np.int64)
    index[keep] = np.arange(int(keep.sum()))
    kept_faces = []
    for f in faces:
        mapped = index[list(f)]
        if (mapped >= 0).all():
            kept_faces.append(mapped.tolist())
    if faces:
        print(f"[crop] 남은 면 {len(kept_faces)}")

    write_ply(args.out, moved[keep], kept_faces,
              colors=None if colors is None else colors[keep],
              normals=None if normals is None else normals[keep])
    if normals is not None:
        print("[crop] 법선도 같이 옮겼다 (포아송 메시에 필요하다)")
    lo, hi = moved[keep].min(axis=0), moved[keep].max(axis=0)
    print(f"[crop] 상자 {np.round(lo, 2).tolist()} ~ {np.round(hi, 2).tolist()}")
    print(f"[crop] -> {args.out}")


main()
