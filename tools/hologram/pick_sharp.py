"""흔들린 프레임을 걸러 낸다.

    python tools/hologram/pick_sharp.py --src frames --out sharp --keep 0.7

밀집 스테레오는 픽셀을 직접 맞춰서 깊이를 재기 때문에 **흔들린 프레임 하나가
그 주변 깊이를 통째로 망친다.** 손으로 돌려 찍은 영상에는 반드시 섞여 있으니
먼저 덜어 내는 편이 빠르고 결과도 낫다.

선명도는 라플라시안 분산으로 잰다 — 초점이 맞으면 밝기가 급하게 바뀌는 자리가
많고, 흔들리면 뭉개져서 분산이 떨어진다. 영상마다 밝기·대비가 다르므로
**영상별로** 순위를 매겨 상위 몇 %만 남긴다 (전체를 한 줄로 세우면 어두운
영상이 통째로 탈락한다).
"""

import argparse
import os
import shutil

import cv2
import numpy as np

parser = argparse.ArgumentParser()
parser.add_argument("--src", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--keep", type=float, default=0.7, help="영상마다 남길 비율")
parser.add_argument("--min-gap", type=int, default=1,
                    help="남긴 프레임 사이 최소 간격 (연속 중복을 줄인다)")
args = parser.parse_args()

os.makedirs(args.out, exist_ok=True)
names = sorted(f for f in os.listdir(args.src)
               if f.lower().endswith((".jpg", ".png")))
clips = {}
for name in names:
    clips.setdefault(name.rsplit("_", 1)[0], []).append(name)

kept_total = 0
for clip, frames in sorted(clips.items()):
    scores = []
    for name in frames:
        img = cv2.imread(os.path.join(args.src, name), cv2.IMREAD_GRAYSCALE)
        if img is None:
            continue
        small = cv2.resize(img, (img.shape[1] // 2, img.shape[0] // 2))
        scores.append((float(cv2.Laplacian(small, cv2.CV_64F).var()), name))
    if not scores:
        continue
    scores.sort(reverse=True)
    want = max(int(len(scores) * args.keep), 1)

    # 점수 순으로 뽑되, 이미 뽑은 프레임과 너무 붙어 있으면 건너뛴다.
    taken, kept = [], []
    for score, name in scores:
        idx = int(name.rsplit("_", 1)[1].split(".")[0])
        if any(abs(idx - t) < args.min_gap for t in taken):
            continue
        taken.append(idx)
        kept.append(name)
        if len(kept) >= want:
            break
    for name in sorted(kept):
        shutil.copy2(os.path.join(args.src, name), os.path.join(args.out, name))
    lo = min(s for s, _ in scores)
    hi = max(s for s, _ in scores)
    print(f"[sharp] {clip}: {len(kept)}/{len(frames)} 장 "
          f"(선명도 {lo:.0f}~{hi:.0f})")
    kept_total += len(kept)

print(f"[sharp] 모두 {kept_total} 장 -> {args.out}")
