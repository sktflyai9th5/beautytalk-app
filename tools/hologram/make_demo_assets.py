"""스캔 연출 미리보기에 쓸 데모 사진과 특징점을 만든다.

    python tools/hologram/make_demo_assets.py --mesh <face_mesh.json> --frames <프레임 폴더>

face_to_mesh.py 가 고른 프레임을 얼굴 중심으로 세로로 잘라내고(촬영본은
가로 1920x1080 이라 그대로 쓰면 얼굴이 화면 구석에 박힌다), 특징점 좌표를
잘라낸 기준으로 다시 계산해서 assets/hologram/ 에 넣는다.

실제 앱에서는 사용자가 방금 찍은 사진을 쓰고 특징점은 없다. 이건 기기 없이
연출을 확인하기 위한 자료다.
"""

import argparse
import json
import os

from PIL import Image

parser = argparse.ArgumentParser()
parser.add_argument("--mesh", required=True, help="face_to_mesh.py 가 만든 json")
parser.add_argument("--frames", required=True, help="프레임 폴더")
parser.add_argument("--out-dir", default=None, help="기본값: assets/hologram")
parser.add_argument("--every", type=int, default=6,
                    help="특징점을 몇 개마다 하나씩 쓸지. 478개를 다 찍으면 뭉갠다")
parser.add_argument("--aspect", type=float, default=3 / 4, help="잘라낼 가로/세로 비")
parser.add_argument("--margin", type=float, default=0.75,
                    help="얼굴 크기 대비 여백 배율")
args = parser.parse_args()

out_dir = args.out_dir or os.path.normpath(
    os.path.join(os.path.dirname(__file__), "..", "..", "assets", "hologram"))
os.makedirs(out_dir, exist_ok=True)

with open(args.mesh, "r", encoding="utf-8") as fp:
    payload = json.load(fp)

points = payload["points_2d"]
src = Image.open(os.path.join(args.frames, payload["source_frame"])).convert("RGB")
width, height = src.size

xs = [p[0] * width for p in points]
ys = [p[1] * height for p in points]
face_w = max(xs) - min(xs)
face_h = max(ys) - min(ys)
cx = (max(xs) + min(xs)) / 2
cy = (max(ys) + min(ys)) / 2

# 얼굴을 담되 여백을 준다. 세로를 먼저 정하고 비율로 가로를 맞춘다.
crop_h = face_h * (1 + 2 * args.margin)
crop_w = crop_h * args.aspect
if crop_w < face_w * (1 + args.margin):
    crop_w = face_w * (1 + args.margin)
    crop_h = crop_w / args.aspect

# 원본을 벗어나면 **비율을 유지한 채로** 줄인다. 가로세로를 따로 자르면
# 3:4 가 깨지고, 그러면 격자 좌표(사진 기준)와 화면 좌표가 어긋나서
# 사진 위 격자가 3D 로 떠오를 때 자리가 안 맞는다.
shrink = min(1.0, width / crop_w, height / crop_h)
crop_w *= shrink
crop_h *= shrink
left = min(max(cx - crop_w / 2, 0), width - crop_w)
top = min(max(cy - crop_h / 2, 0), height - crop_h)

cropped = src.crop((int(left), int(top), int(left + crop_w), int(top + crop_h)))
target_h = 1024
cropped = cropped.resize(
    (int(target_h * cropped.width / cropped.height), target_h), Image.LANCZOS)

photo_path = os.path.join(out_dir, "demo_face.jpg")
cropped.save(photo_path, quality=88, optimize=True)

def to_crop(p):
    return [round((p[0] * width - left) / crop_w, 5),
            round((p[1] * height - top) / crop_h, 5)]


# 격자 전체. 사진 위에 얼굴을 따라 붙는 그물을 그리는 데 쓴다.
# 선 목록은 face_to_mesh.py 가 이미 성글게 솎아 둔 것을 그대로 쓴다 —
# 사진 위 격자와 3D 홀로그램이 같은 밀도여야 떠오르는 게 같은 격자로 보인다.
mesh = [to_crop(p) for p in points]
edges = payload["edges"]
contours = payload.get("contours", [])

# 하이라이트로 찍을 점. face_to_mesh.py 가 고른 목록을 그대로 쓴다 —
# 3D 아바타에도 같은 정점에 하이라이트가 박히므로, 여기서 따로 고르면
# 사진에서 반짝이던 자리와 아바타에서 반짝이는 자리가 달라진다.
picked = payload.get("highlights") or list(range(0, len(mesh), args.every))
kept = [mesh[i] for i in picked
        if i < len(mesh) and 0.0 <= mesh[i][0] <= 1.0 and 0.0 <= mesh[i][1] <= 1.0]

points_path = os.path.join(out_dir, "demo_face_points.json")
with open(points_path, "w", encoding="utf-8") as fp:
    json.dump({"points": kept, "mesh": mesh, "edges": edges,
               "contours": contours}, fp)

print(f"[demo] 사진 {cropped.size[0]}x{cropped.size[1]} "
      f"({os.path.getsize(photo_path) / 1024:.0f}KB) -> {photo_path}")
print(f"[demo] 특징점 {len(kept)}개 / 격자 {len(edges)}선 / 윤곽 {len(contours)}선 "
      f"({os.path.getsize(points_path) / 1024:.0f}KB) -> {points_path}")
