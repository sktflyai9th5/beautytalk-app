"""사진측량 결과에서 머리의 위치와 방향을 카메라 궤도로 계산한다.

    python tools/hologram/head_bounds.py --sparse <sparse/0_txt> --front-frame f_030.jpg

COLMAP 이 만드는 좌표계는 방향이 정해져 있지 않다. 그대로 렌더하면 머리가
비스듬히 누워 아무 데나 보고 있다. 다행히 촬영이 머리 주위를 도는 궤도라
카메라 위치만으로 세 가지를 다 구할 수 있다.

  · 머리 위치   = 카메라들의 중심 (궤도의 한가운데가 곧 피사체다)
  · 위쪽        = 카메라 Y축들의 평균을 뒤집은 것
                  (COLMAP 카메라 Y 는 화면 아래쪽을 가리킨다)
  · 정면        = 가장 정면으로 찍힌 컷의 카메라가 있던 방향

결과는 JSON 으로 나가고 render_hologram.py 가 받아서 자르고 세운다.
"""

import argparse
import json
import math
import os

import numpy as np

parser = argparse.ArgumentParser()
parser.add_argument("--sparse", required=True, help="TXT 로 변환한 sparse 모델 폴더")
parser.add_argument("--front-frame", required=True, help="가장 정면인 프레임 파일 이름")
parser.add_argument("--out", required=True, help="쓸 JSON 경로")
parser.add_argument("--radius-scale", type=float, default=0.42,
                    help="궤도 반지름 대비 머리를 자를 반지름")
args = parser.parse_args()


def quat_to_matrix(qw, qx, qy, qz):
    """COLMAP 의 (w,x,y,z) 쿼터니언을 회전 행렬로."""
    n = math.sqrt(qw * qw + qx * qx + qy * qy + qz * qz)
    qw, qx, qy, qz = qw / n, qx / n, qy / n, qz / n
    return np.array([
        [1 - 2 * (qy * qy + qz * qz), 2 * (qx * qy - qz * qw), 2 * (qx * qz + qy * qw)],
        [2 * (qx * qy + qz * qw), 1 - 2 * (qx * qx + qz * qz), 2 * (qy * qz - qx * qw)],
        [2 * (qx * qz - qy * qw), 2 * (qy * qz + qx * qw), 1 - 2 * (qx * qx + qy * qy)],
    ], dtype=np.float64)


def read_images(path):
    """images.txt 를 읽어 이름 -> (회전, 카메라 위치) 로 돌려준다.

    한 이미지가 두 줄을 쓴다. 첫 줄이 자세, 둘째 줄이 관측점 목록이라 건너뛴다.
    """
    poses = {}
    with open(path, "r", encoding="utf-8") as fp:
        lines = [l.strip() for l in fp if l.strip() and not l.startswith("#")]

    for i in range(0, len(lines), 2):
        parts = lines[i].split()
        if len(parts) < 10:
            continue
        qw, qx, qy, qz = (float(v) for v in parts[1:5])
        tx, ty, tz = (float(v) for v in parts[5:8])
        name = parts[9]

        rotation = quat_to_matrix(qw, qx, qy, qz)
        # COLMAP 은 월드->카메라를 저장한다. 카메라의 월드 좌표는 -R^T t 다.
        center = -rotation.T @ np.array([tx, ty, tz])
        poses[name] = (rotation, center)
    return poses


def main():
    poses = read_images(os.path.join(args.sparse, "images.txt"))
    if not poses:
        raise SystemExit("images.txt 에서 자세를 못 읽었다")

    names = sorted(poses)
    centers = np.array([poses[n][1] for n in names])

    head = centers.mean(axis=0)
    orbit_radius = float(np.linalg.norm(centers - head, axis=1).mean())

    # 카메라 Y축(화면 아래쪽)들의 평균을 뒤집으면 월드의 위쪽이다.
    down = np.array([poses[n][0][1] for n in names]).mean(axis=0)
    up = -down / np.linalg.norm(down)

    if args.front_frame not in poses:
        raise SystemExit(
            f"{args.front_frame} 는 정합된 프레임이 아니다. "
            f"정합된 것 중에서 골라라 (예: {names[0]})")

    forward = poses[args.front_frame][1] - head
    # 위쪽 성분을 빼서 수평으로 눕힌다 — 카메라가 조금 높거나 낮았어도 된다.
    forward = forward - up * float(forward @ up)
    forward /= np.linalg.norm(forward)

    payload = {
        "head": head.tolist(),
        "up": up.tolist(),
        "forward": forward.tolist(),
        "orbit_radius": orbit_radius,
        "crop_radius": orbit_radius * args.radius_scale,
        "registered": len(names),
        "front_frame": args.front_frame,
    }
    with open(args.out, "w", encoding="utf-8") as fp:
        json.dump(payload, fp, indent=2)

    print(f"[bounds] 정합 {len(names)}장, 궤도 반지름 {orbit_radius:.3f}")
    print(f"[bounds] 자를 반지름 {payload['crop_radius']:.3f} -> {args.out}")


main()
