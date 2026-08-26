"""선 레이어를 얼굴 위에 겹친다.

`render_hologram.py --lines-front` 가 한 장을 두 장으로 뽑아 놓는다
(`frame_XXXX.png` = 얼굴·머리·스캔면, `lines_XXXX.png` = 격자·윤곽·하이라이트).
여기서 두 번째를 첫 번째 위에 얹고 `lines_` 는 지운다.

**왜 겹치나.** 선을 표면에서 조금 띄우는 것(`--line-lift`, `--line-swell`)만으로는
볼·턱처럼 표면이 옆으로 휘는 데서 선이 계속 살에 잠긴다. 더 띄우면 이번엔
얼굴 옆으로 삐져나온다. 깊이를 아예 겨루지 않게 따로 그려서 위에 얹는 게
"선을 다 앞으로" 의 정확한 뜻이다.

    python tools/hologram/compose.py <프레임 폴더>
"""

import argparse
import os
import sys

from PIL import Image

parser = argparse.ArgumentParser()
parser.add_argument("frames", help="frame_*.png 와 lines_*.png 가 있는 폴더")
args = parser.parse_args()

pairs = sorted(f for f in os.listdir(args.frames) if f.startswith("lines_"))
if not pairs:
    sys.exit("[compose] lines_*.png 가 없다 — --lines-front 로 렌더했는지 봐라")

for name in pairs:
    base = os.path.join(args.frames, name.replace("lines_", "frame_"))
    over = os.path.join(args.frames, name)
    if not os.path.exists(base):
        sys.exit(f"[compose] 짝이 없다: {base}")

    # 둘 다 알파가 있는 RGBA 다. alpha_composite 는 곱해지지 않은 알파를
    # 제대로 다뤄서, 반투명한 스캔선 위에 선을 얹어도 색이 탁해지지 않는다.
    with Image.open(base) as a, Image.open(over) as b:
        merged = Image.alpha_composite(a.convert("RGBA"), b.convert("RGBA"))
        merged.save(base)
    os.remove(over)

print(f"[compose] {len(pairs)}장에 선 레이어를 얹었다")
