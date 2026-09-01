"""정합된 프레임들에서 얼굴 랜드마크를 **삼각측량**해 머리의 실제 자리를 잡는다.

    <venv>\\Scripts\\python.exe tools/hologram/face_points.py ^
        --sparse <sparse_txt> --frames <정합된 프레임 폴더> --model <face_landmarker.task> ^
        --face-mesh <face_mesh.json> --out face_points.json

**왜 필요한가.** 실루엣을 깎으려면 머리를 감싸는 상자를 먼저 정해야 하는데,
카메라 궤도의 한가운데를 머리로 치면 빗나간다 — 실제로 그렇게 잡았더니
56장 중 4장에서만 그 점이 머리 위에 떨어졌다. 손으로 도는 촬영은 궤도가
찌그러지고 중심도 사람이 아니라 방 한가운데 쪽으로 쏠린다.

mediapipe 랜드마크는 **번호가 곧 대응점**이다. 여러 화면에서 같은 번호를
모아 삼각측량하면 그 점의 COLMAP 좌표가 나온다. 이걸로 두 가지를 한 번에 푼다.

  · 머리 상자 — 얼굴 점들의 중심과 반지름
  · 좌표 맞추기 — 얼굴 격자(정면으로 세워 -1~1 로 줄인 것)로 보내는 닮음변환

랜드마크는 특징점이 아니라 모델이 맞춘 값이라 화면마다 흔들린다. 재투영
오차를 재서 큰 점은 버린다.
"""

import argparse
import json
import math
import os

import numpy as np
from PIL import Image

import mediapipe as mp
from mediapipe.tasks.python import BaseOptions
from mediapipe.tasks.python import vision

parser = argparse.ArgumentParser()
parser.add_argument("--sparse", required=True, help="TXT 로 변환한 sparse 모델 폴더")
parser.add_argument("--frames", required=True, help="정합된 프레임 폴더")
parser.add_argument("--model", required=True, help="face_landmarker.task 경로")
parser.add_argument("--face-mesh", default=None,
                    help="face_to_mesh.py 가 낸 JSON. 주면 닮음변환까지 푼다")
parser.add_argument("--out", required=True, help="쓸 JSON 경로")
parser.add_argument("--min-views", type=int, default=5,
                    help="한 점을 이만큼은 봐야 삼각측량한다")
parser.add_argument("--max-error", type=float, default=8.0,
                    help="재투영 오차(px) 중앙값이 이보다 크면 그 점은 버린다")
args = parser.parse_args()


def quat_to_matrix(qw, qx, qy, qz):
    n = math.sqrt(qw * qw + qx * qx + qy * qy + qz * qz)
    qw, qx, qy, qz = qw / n, qx / n, qy / n, qz / n
    return np.array([
        [1 - 2 * (qy * qy + qz * qz), 2 * (qx * qy - qz * qw), 2 * (qx * qz + qy * qw)],
        [2 * (qx * qy + qz * qw), 1 - 2 * (qx * qx + qz * qz), 2 * (qy * qz - qx * qw)],
        [2 * (qx * qz - qy * qw), 2 * (qy * qz + qx * qw), 1 - 2 * (qx * qx + qy * qy)],
    ], dtype=np.float64)


def read_cameras(path):
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


def read_images(path):
    """이름 -> (세계->카메라 회전, 이동, 카메라 id)."""
    poses = {}
    with open(path, "r", encoding="utf-8") as fp:
        lines = [l.strip() for l in fp if l.strip() and not l.startswith("#")]
    for i in range(0, len(lines), 2):
        parts = lines[i].split()
        if len(parts) < 10:
            continue
        rotation = quat_to_matrix(*(float(v) for v in parts[1:5]))
        t = np.array([float(v) for v in parts[5:8]])
        poses[parts[9]] = (rotation, t, int(parts[8]))
    return poses


def undistort(model, params, u, v):
    """픽셀 좌표를 왜곡을 푼 정규 좌표로. 닫힌 식이 없어 몇 번 되풀이한다."""
    if model in ("SIMPLE_RADIAL", "RADIAL"):
        f, cx, cy = params[0], params[1], params[2]
        k1 = params[3]
        k2 = params[4] if model == "RADIAL" else 0.0
        x, y = (u - cx) / f, (v - cy) / f
        for _ in range(5):
            r2 = x * x + y * y
            scale = 1.0 + k1 * r2 + k2 * r2 * r2
            x = (u - cx) / f / scale
            y = (v - cy) / f / scale
        return x, y
    if model == "SIMPLE_PINHOLE":
        f, cx, cy = params[0], params[1], params[2]
        return (u - cx) / f, (v - cy) / f
    if model == "PINHOLE":
        fx, fy, cx, cy = params[0], params[1], params[2], params[3]
        return (u - cx) / fx, (v - cy) / fy
    raise SystemExit(f"모르는 카메라 모델이다: {model}")


def triangulate(rays):
    """(P, x, y) 목록에서 한 점을 최소제곱으로 푼다 (선형 DLT)."""
    rows = []
    for P, x, y in rays:
        rows.append(x * P[2] - P[0])
        rows.append(y * P[2] - P[1])
    _, _, vt = np.linalg.svd(np.array(rows))
    point = vt[-1]
    if abs(point[3]) < 1e-12:
        return None
    return point[:3] / point[3]


def umeyama(src, dst):
    """src 를 dst 로 보내는 닮음변환. 거울상은 막는다 — 뒤집히면 좌우가 바뀐다."""
    src_mean, dst_mean = src.mean(axis=0), dst.mean(axis=0)
    src_c, dst_c = src - src_mean, dst - dst_mean
    u, d, vt = np.linalg.svd(dst_c.T @ src_c / len(src))
    s = np.eye(3)
    if np.linalg.det(u) * np.linalg.det(vt) < 0:
        s[2, 2] = -1.0
    R = u @ s @ vt
    scale = float((d * np.diag(s)).sum() / ((src_c ** 2).sum() / len(src)))
    return R, scale, dst_mean - scale * R @ src_mean


def main():
    cams = read_cameras(os.path.join(args.sparse, "cameras.txt"))
    poses = read_images(os.path.join(args.sparse, "images.txt"))

    options = vision.FaceLandmarkerOptions(
        base_options=BaseOptions(model_asset_path=args.model),
        running_mode=vision.RunningMode.IMAGE,
        num_faces=1)

    observations = {}
    seen_frames = 0
    with vision.FaceLandmarker.create_from_options(options) as landmarker:
        for name in sorted(poses):
            path = os.path.join(args.frames, name)
            if not os.path.exists(path):
                continue
            rgb = np.asarray(Image.open(path).convert("RGB"), dtype=np.uint8)
            found = landmarker.detect(
                mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb))
            if not found.face_landmarks:
                continue
            R, t, cam_id = poses[name]
            model, width, height, params = cams[cam_id]
            P = np.hstack([R, t.reshape(3, 1)])
            for i, lm in enumerate(found.face_landmarks[0]):
                x, y = undistort(model, params, lm.x * width, lm.y * height)
                observations.setdefault(i, []).append((P, x, y, params[0]))
            seen_frames += 1

    print(f"[points] 얼굴이 잡힌 프레임 {seen_frames}장")
    if seen_frames < 4:
        raise SystemExit("얼굴이 잡힌 프레임이 너무 적다 — 한 바퀴가 맞는지 봐라")

    points = {}
    for i, rays in observations.items():
        if len(rays) < args.min_views:
            continue
        point = triangulate([(r[0], r[1], r[2]) for r in rays])
        if point is None:
            continue
        errors = []
        for P, x, y, f in rays:
            cam = P[:, :3] @ point + P[:, 3]
            if cam[2] > 1e-6:
                errors.append(f * math.hypot(cam[0] / cam[2] - x,
                                             cam[1] / cam[2] - y))
        if errors and np.median(errors) <= args.max_error:
            points[i] = point

    print(f"[points] 삼각측량된 정점 {len(points)}개 / 478")
    if len(points) < 50:
        raise SystemExit("삼각측량된 점이 너무 적다")

    coords = np.array(list(points.values()))
    center = coords.mean(axis=0)
    radius = float(np.linalg.norm(coords - center, axis=1).max())
    print(f"[points] 얼굴 중심 {np.round(center, 3).tolist()} / 반지름 {radius:.3f}")

    payload = {
        "indices": sorted(points),
        "points": [points[i].tolist() for i in sorted(points)],
        "center": center.tolist(),
        "radius": radius,
        "frames": seen_frames,
    }

    if args.face_mesh:
        with open(args.face_mesh, "r", encoding="utf-8") as fp:
            face_verts = np.array(json.load(fp)["vertices"], dtype=np.float64)
        idx = [i for i in sorted(points) if i < len(face_verts)]
        src = np.array([points[i] for i in idx])
        dst = face_verts[idx]
        R, scale, t = umeyama(src, dst)
        residual = np.linalg.norm((scale * (R @ src.T).T + t) - dst, axis=1)
        print(f"[points] 닮음변환 크기 {scale:.4f} / 남은 오차 중앙값 "
              f"{np.median(residual):.4f} (얼굴 반지름 1 기준)")
        payload["fit"] = {
            "rotation": R.tolist(),
            "scale": scale,
            "translation": t.tolist(),
            "residual_median": float(np.median(residual)),
        }

    with open(args.out, "w", encoding="utf-8") as fp:
        json.dump(payload, fp, indent=2)
    print(f"[points] -> {args.out}")


main()
