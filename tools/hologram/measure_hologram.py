"""구운 홀로그램의 첫 프레임이 화면에서 차지하는 영역을 재서 남긴다.

    python tools/hologram/measure_hologram.py --frames <glow 폴더> --out face_hologram.json

사진 위 격자가 **그대로** 3D 아바타로 떠오르는 것처럼 보이려면, 아바타의 첫
프레임(정면)이 2D 격자와 같은 자리·같은 크기에 있어야 한다. 그렇지 않으면
크로스페이드 순간에 크기가 튀면서 "바뀌었다" 가 아니라 "잘렸다" 로 보인다.

렌더 결과에서 알파가 있는 부분의 바깥 사각형을 재서 0~1 비율로 적어 둔다.
앱은 이 값으로 아바타를 2D 격자 자리에 맞춰 놓는다.
"""

import argparse
import json
import os

import numpy as np
from PIL import Image

parser = argparse.ArgumentParser()
parser.add_argument("--frames", required=True, help="알파가 들어간 PNG 폴더")
parser.add_argument("--align", default=None,
                    help="정렬 전용 프레임. 스캔면 같은 장식이 빠진 그림이어야 한다")
parser.add_argument("--out", required=True)
parser.add_argument("--threshold", type=float, default=0.05,
                    help="이 알파 위쪽만 내용으로 친다")
args = parser.parse_args()


def main():
    # 스캔면처럼 머리보다 넓은 장식이 있으면 바깥 사각형이 화면 전체가 된다.
    # 그런 게 빠진 전용 프레임이 있으면 그걸로 잰다.
    if args.align and os.path.exists(args.align):
        source = args.align
    else:
        names = sorted(f for f in os.listdir(args.frames) if f.lower().endswith(".png"))
        if not names:
            raise SystemExit(f"PNG 가 없다: {args.frames}")
        # 첫 프레임이 정면이다 (스윕이 sin 이라 0 에서 시작한다).
        source = os.path.join(args.frames, names[0])

    first = np.asarray(Image.open(source).convert("RGBA"))
    alpha = first[:, :, 3].astype(np.float32) / 255.0
    rows = np.where(alpha.max(axis=1) > args.threshold)[0]
    cols = np.where(alpha.max(axis=0) > args.threshold)[0]
    if rows.size == 0 or cols.size == 0:
        raise SystemExit("첫 프레임이 비어 있다")

    h, w = alpha.shape
    content = [
        round(float(cols[0]) / w, 5),
        round(float(rows[0]) / h, 5),
        round(float(cols[-1] + 1) / w, 5),
        round(float(rows[-1] + 1) / h, 5),
    ]

    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fp:
        json.dump({"content": content, "source_frame": os.path.basename(source)}, fp)

    print(f"[measure] 첫 프레임 내용 영역 {content} -> {args.out}")


main()
