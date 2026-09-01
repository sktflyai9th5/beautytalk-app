"""프레임마다 **머리만** 흰색인 마스크를 만든다 (실루엣 깎기의 재료).

    <venv>\\Scripts\\python.exe tools/hologram/head_masks.py ^
        --frames <프레임 폴더> --model <selfie_multiclass_256x256.tflite> --out <마스크 폴더>

mediapipe 의 다중 분할이 머리카락·얼굴피부·몸피부·옷·배경을 따로 준다.
**머리카락 + 얼굴피부**만 남기면 어느 각도에서든 머리가 잘린다 — 뒤통수만
보이는 컷에서는 머리카락 하나로, 정면에서는 둘이 합쳐져서 나온다. 사람 전체를
따는 모델(selfie_segmenter)로는 목과 어깨를 어디서 끊을지가 임의가 된다.

**목은 잘라야 한다.** 얼굴피부는 목까지 이어져서 그냥 두면 기둥이 하나 붙는다.
머리 덩어리의 아래쪽 일정 비율을 잘라내는 건 실루엣 깎기에서 위험하다(잘린
만큼 영구히 파인다). 대신 **가장 큰 덩어리만 남기고** 아래 끝을 조금만
다듬는다 — 어깨·옷이 붙은 컷을 걸러내는 게 목적이다.

카메라가 도는 동안 사람 뒤로 다른 사람이 지나가면 그쪽에도 머리가 잡힌다.
그래서 **한 덩어리만** 남긴다 (화면 가운데에 가장 가까운 것).
"""

import argparse
import os

import cv2
import numpy as np
from PIL import Image

import mediapipe as mp
from mediapipe.tasks.python import BaseOptions
from mediapipe.tasks.python import vision

# selfie_multiclass 의 클래스 번호.
BACKGROUND, HAIR, BODY_SKIN, FACE_SKIN, CLOTHES, OTHERS = range(6)

parser = argparse.ArgumentParser()
parser.add_argument("--frames", required=True, help="jpg 프레임 폴더")
parser.add_argument("--model", required=True, help="selfie_multiclass tflite 경로")
parser.add_argument("--out", required=True, help="마스크를 쓸 폴더")
parser.add_argument("--preview", default=None,
                    help="확인용 겹친 그림을 쓸 폴더 (선택)")
parser.add_argument("--whole-person", action="store_true",
                    help="머리+얼굴 대신 **사람 실루엣 전체**를 마스크로 쓴다")
parser.add_argument("--min-area", type=float, default=0.004,
                    help="이 비율보다 작은 덩어리만 나오면 그 프레임은 버린다")
args = parser.parse_args()


def largest_blob(mask):
    """가장 큰 연결 덩어리만 남긴다. 뒤로 지나가는 사람을 떼어내려는 것이다."""
    count, labels, stats, _ = cv2.connectedComponentsWithStats(
        mask.astype(np.uint8), connectivity=8)
    if count <= 1:
        return np.zeros_like(mask), 0
    # 0 번은 배경이다.
    biggest = 1 + int(np.argmax(stats[1:, cv2.CC_STAT_AREA]))
    return labels == biggest, int(stats[biggest, cv2.CC_STAT_AREA])


def main():
    os.makedirs(args.out, exist_ok=True)
    if args.preview:
        os.makedirs(args.preview, exist_ok=True)

    options = vision.ImageSegmenterOptions(
        base_options=BaseOptions(model_asset_path=args.model),
        running_mode=vision.RunningMode.IMAGE,
        output_category_mask=True)

    names = sorted(f for f in os.listdir(args.frames)
                   if f.lower().endswith((".jpg", ".jpeg", ".png")))
    if not names:
        raise SystemExit(f"프레임이 없다: {args.frames}")

    written = skipped = 0
    with vision.ImageSegmenter.create_from_options(options) as segmenter:
        for name in names:
            path = os.path.join(args.frames, name)
            pil = Image.open(path).convert("RGB")
            rgb = np.asarray(pil, dtype=np.uint8)
            image = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)

            result = segmenter.segment(image)
            # 카테고리 마스크는 (h, w, 1) 로 나온다.
            categories = np.squeeze(result.category_mask.numpy_view())
            if args.whole_person:
                # **실루엣 깎기용은 사람 전체를 잡는 편이 안전하다.** 어두운 긴
                # 머리는 hair 클래스가 프레임에 따라 통째로 빠지는데, 그 프레임이
                # 실루엣 깎기에 들어가면 머리를 깎아 먹는다 (수지님 재촬영에서
                # 머리 절반이 날아갔다). 사람 실루엣(배경이 아닌 전부)은 머리를
                # 절대 놓치지 않고, 같이 남는 옷·몸은 나중에 좌표로 잘라낸다.
                head = categories != 0
            else:
                head = (categories == HAIR) | (categories == FACE_SKIN)

            head, size = largest_blob(head)
            if size < args.min_area * head.size:
                skipped += 1
                continue

            out = os.path.join(args.out, os.path.splitext(name)[0] + ".png")
            Image.fromarray((head * 255).astype(np.uint8)).save(out)
            written += 1

            if args.preview:
                tint = rgb.copy()
                tint[head] = (0.45 * tint[head] + 0.55 *
                              np.array([255, 90, 120])).astype(np.uint8)
                Image.fromarray(tint).save(
                    os.path.join(args.preview, name), quality=85)

            if written % 20 == 0:
                print(f"[mask] {written}장")

    print(f"[mask] {written}장 저장, {skipped}장 버림 -> {args.out}")


main()
