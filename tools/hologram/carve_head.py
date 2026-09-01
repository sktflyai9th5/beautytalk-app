"""머리 실루엣들의 교집합으로 머리 덩어리를 깎아낸다 (visual hull).

    python tools/hologram/carve_head.py --sparse <sparse_txt> --masks <마스크 폴더> ^
        --points face_points.json --out head_points.ply

**왜 사진측량(조밀 복원)이 아니라 이건가.** 조밀 복원은 화면 사이에서 같은
점을 찾아 깊이를 재는데, 매끈한 피부와 검은 머리에는 찾을 점이 없다. 실제로
한 번 해봤더니 머리 자리에 조밀점이 **0개**였다(사무실만 복원됐다). 실루엣
깎기는 윤곽만 쓰기 때문에 질감이 없어도, 머리가 새까매도 형태가 나온다.

**한계는 오목한 곳이다.** 실루엣의 교집합이라 귀 뒤나 머리카락 사이처럼 어느
방향에서도 윤곽으로 드러나지 않는 곳은 메워진 채로 남는다. 결과는 늘 실제보다
조금 통통하다. 뒤통수 실루엣이 목적이라 그래도 쓸 만하다.

카메라 자세는 COLMAP sparse 를 그대로 쓴다 — **거기는 잘 된다.** 배경(책상·
창틀·바닥 타일)에 특징이 넘쳐서 자세가 0.93px 로 풀렸었다. 사람이 아니라
방을 복원하던 그 성질을 여기서는 이득으로 쓴다.

내보내는 건 **점구름**이다. 표면 복셀만 남기고 머리 중심에서 바깥으로
법선을 준다. 메시는 COLMAP `poisson_mesher` 가 만든다 — 새 패키지를 깔지
않으려고 이렇게 나눴다.
"""

import argparse
import math
import os

import numpy as np
from PIL import Image

parser = argparse.ArgumentParser()
parser.add_argument("--sparse", required=True, help="TXT 로 변환한 sparse 모델 폴더")
parser.add_argument("--masks", required=True,
                    help="프레임과 같은 이름의 마스크 PNG 폴더 (머리=흰색)")
parser.add_argument("--points", required=True,
                    help="face_points.py 가 낸 JSON (머리 상자를 여기서 잡는다)")
parser.add_argument("--out", required=True, help="쓸 PLY 경로")
parser.add_argument("--grid", type=int, default=192,
                    help="한 변의 복셀 수. 192 면 머리 하나에 1mm 안팎이다")
parser.add_argument("--box-scale", type=float, default=2.4,
                    help="자를 상자를 **얼굴** 반지름의 몇 배로 잡을지. 얼굴 점의 "
                         "중심은 코 언저리라 뒤통수와 묶은 머리까지 담으려면 넉넉해야 한다")
parser.add_argument("--miss", type=int, default=2,
                    help="몇 장까지 실루엣 밖이어도 남길지. 마스크가 한두 장 "
                         "튀어도 덩어리가 파이지 않게 하는 여유다")
parser.add_argument("--min-view-ratio", type=float, default=0.6,
                    help="쓴 장수의 이 비율만큼은 화면 안에 들어와야 판정한다")

# 인자는 main() 에서 읽는다. 모듈 바닥에서 파싱하면 이 파일을 import 해서
# 함수만 빌려 쓰려는 쪽(진단 스크립트 등)이 인자를 내놓으라며 죽는다.
args = None


def quat_to_matrix(qw, qx, qy, qz):
    """COLMAP 의 (w,x,y,z) 쿼터니언을 회전 행렬로. head_bounds.py 와 같은 식이다.

    (그 파일은 불러오는 순간 인자를 파싱하고 실행돼서 import 할 수가 없다.)
    """
    n = math.sqrt(qw * qw + qx * qx + qy * qy + qz * qz)
    qw, qx, qy, qz = qw / n, qx / n, qy / n, qz / n
    return np.array([
        [1 - 2 * (qy * qy + qz * qz), 2 * (qx * qy - qz * qw), 2 * (qx * qz + qy * qw)],
        [2 * (qx * qy + qz * qw), 1 - 2 * (qx * qx + qz * qz), 2 * (qy * qz - qx * qw)],
        [2 * (qx * qz - qy * qw), 2 * (qy * qz + qx * qw), 1 - 2 * (qx * qx + qy * qy)],
    ], dtype=np.float64)


def read_images(path):
    """images.txt → 이름 -> (회전, 카메라 위치, 카메라 id).

    한 이미지가 두 줄을 쓴다. 둘째 줄은 관측점 목록이라 건너뛴다.
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
        cam_id = int(parts[8])
        name = parts[9]
        rotation = quat_to_matrix(qw, qx, qy, qz)
        poses[name] = (rotation, -rotation.T @ np.array([tx, ty, tz]), cam_id)
    return poses


def read_cameras(path):
    """cameras.txt → id -> (모델, 너비, 높이, 파라미터들)."""
    cams = {}
    with open(path, "r", encoding="utf-8") as fp:
        for line in fp:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            cams[int(parts[0])] = (parts[1], int(parts[2]), int(parts[3]),
                                   [float(v) for v in parts[4:]])
    return cams


def project(points, model, params, R, C):
    """세계 좌표 점들을 한 카메라의 픽셀 좌표로. (u, v, 앞에 있나) 를 준다.

    COLMAP 의 images.txt 는 세계->카메라 자세를 담는다. head_bounds.read_images
    가 이미 카메라 위치 C 로 바꿔 주므로 여기서는 다시 R(X - C) 로 돌린다.
    """
    cam = (points - C) @ R.T
    z = cam[:, 2]
    front = z > 1e-6
    z = np.where(front, z, 1.0)
    x = cam[:, 0] / z
    y = cam[:, 1] / z

    if model in ("SIMPLE_RADIAL", "RADIAL"):
        f, cx, cy = params[0], params[1], params[2]
        k1 = params[3]
        k2 = params[4] if model == "RADIAL" else 0.0
        r2 = x * x + y * y
        scale = 1.0 + k1 * r2 + k2 * r2 * r2
        x, y = x * scale, y * scale
        u, v = f * x + cx, f * y + cy
    elif model == "SIMPLE_PINHOLE":
        f, cx, cy = params[0], params[1], params[2]
        u, v = f * x + cx, f * y + cy
    elif model == "PINHOLE":
        fx, fy, cx, cy = params[0], params[1], params[2], params[3]
        u, v = fx * x + cx, fy * y + cy
    else:
        raise SystemExit(f"모르는 카메라 모델이다: {model}")
    return u, v, front


def main():
    import json

    global args
    args = parser.parse_args()

    cams = read_cameras(os.path.join(args.sparse, "cameras.txt"))
    poses = read_images(os.path.join(args.sparse, "images.txt"))
    with open(args.points, "r", encoding="utf-8") as fp:
        face = json.load(fp)

    # 상자는 **삼각측량한 얼굴 점**에 맞춘다. 카메라 궤도의 한가운데를 머리로
    # 치면 빗나간다 — 손으로 도는 촬영은 궤도가 찌그러져서, 실제로 그렇게
    # 잡았더니 56장 중 4장에서만 그 점이 머리 위에 떨어졌다.
    center = np.array(face["center"], dtype=np.float64)
    radius = float(face["radius"]) * args.box_scale

    # 머리를 감싸는 정육면체를 복셀로 채운다. 세계 좌표축 그대로 잡는다 —
    # 어차피 상자를 넉넉히 잡으므로 세워 놓을 필요가 없고, 나중에 렌더러가
    # bounds 의 방향(up/front)으로 돌려 세운다.
    n = args.grid
    lin = np.linspace(-radius, radius, n)
    gx, gy, gz = np.meshgrid(lin, lin, lin, indexing="ij")
    voxels = np.stack([gx.ravel(), gy.ravel(), gz.ravel()], axis=1) + center

    miss = np.zeros(len(voxels), dtype=np.int32)
    seen = np.zeros(len(voxels), dtype=np.int32)
    used = 0

    names = sorted(poses)
    for name in names:
        mask_path = os.path.join(args.masks, os.path.splitext(name)[0] + ".png")
        if not os.path.exists(mask_path):
            continue
        R, C, cam_id = poses[name]
        model, width, height, params = cams[cam_id]

        mask = Image.open(mask_path).convert("L")
        if mask.size != (width, height):
            mask = mask.resize((width, height), Image.NEAREST)
        m = np.asarray(mask, dtype=np.uint8) > 127

        u, v, front = project(voxels, model, params, R, C)
        ui = np.rint(u).astype(np.int64)
        vi = np.rint(v).astype(np.int64)
        inside = front & (ui >= 0) & (ui < width) & (vi >= 0) & (vi < height)

        idx = np.where(inside)[0]
        hit = m[vi[idx], ui[idx]]
        seen[idx] += 1
        miss[idx[~hit]] += 1
        used += 1
        if used % 10 == 0:
            print(f"[carve] {used}장 처리")

    if used == 0:
        raise SystemExit("쓸 마스크가 하나도 없다 — 이름이 프레임과 같은지 봐라")

    need = max(4, int(round(args.min_view_ratio * used)))
    keep = (miss <= args.miss) & (seen >= need)
    print(f"[carve] {used}장으로 깎았다 (판정에 {need}장 이상) / "
          f"남은 복셀 {int(keep.sum())} ({100.0 * keep.mean():.2f}%)")
    if not keep.any():
        raise SystemExit("남은 복셀이 없다 — 마스크나 bounds 를 의심해라")

    solid = keep.reshape(n, n, n)

    # 표면만 남긴다. 속을 채운 채 poisson 에 넘기면 안쪽 점이 법선을 흐린다.
    inner = np.zeros_like(solid)
    inner[1:-1, 1:-1, 1:-1] = (
        solid[:-2, 1:-1, 1:-1] & solid[2:, 1:-1, 1:-1] &
        solid[1:-1, :-2, 1:-1] & solid[1:-1, 2:, 1:-1] &
        solid[1:-1, 1:-1, :-2] & solid[1:-1, 1:-1, 2:])
    surface = solid & ~inner
    pts = voxels.reshape(n, n, n, 3)[surface]
    print(f"[carve] 표면 점 {len(pts)}")

    # 법선은 머리 중심에서 바깥으로. 머리는 대체로 볼록해서 이걸로 충분하고,
    # poisson 이 방향 있는 점구름을 요구한다.
    normals = pts - center
    length = np.linalg.norm(normals, axis=1, keepdims=True)
    normals = normals / np.maximum(length, 1e-9)

    with open(args.out, "w", encoding="utf-8") as fp:
        fp.write("ply\nformat ascii 1.0\n")
        fp.write(f"element vertex {len(pts)}\n")
        fp.write("property float x\nproperty float y\nproperty float z\n")
        fp.write("property float nx\nproperty float ny\nproperty float nz\n")
        fp.write("end_header\n")
        for p, nvec in zip(pts, normals):
            fp.write(f"{p[0]:.6f} {p[1]:.6f} {p[2]:.6f} "
                     f"{nvec[0]:.6f} {nvec[1]:.6f} {nvec[2]:.6f}\n")
    print(f"[carve] -> {args.out}")


if __name__ == "__main__":
    main()
