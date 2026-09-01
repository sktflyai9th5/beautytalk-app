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

from PIL import Image, ImageFilter

parser = argparse.ArgumentParser()
parser.add_argument("frames", help="frame_*.png 와 lines_*.png 가 있는 폴더")
parser.add_argument("--line-halo", type=float, default=0.0,
                    help="선 뒤에 까는 후광의 진하기 0~1. "
                         "선이 얼굴 위에서 떠 보이게 한다")
parser.add_argument("--halo-color", default="FFFFFF",
                    help="후광 색 (hex). 어두운 선에는 흰 후광, **흰 선에는 "
                         "어두운 후광**이어야 얼굴 위에서 읽힌다")
parser.add_argument("--line-alpha", type=float, default=1.0,
                    help="선 레이어를 얼마나 옅게 얹을지 0~1. "
                         "선이 얼굴 위에 **얹혀 있다** 로 보여야지, 덮으면 안 된다")
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
        top = b.convert("RGBA")
        under = a.convert("RGBA")

        if args.line_halo > 0:
            # 선의 알파를 부풀리고 흐려서 흰 후광을 만든다. 밝은 테두리 +
            # 어두운 심지라 **금속을 새긴 것처럼** 읽히고, 무엇보다 멀리서도
            # 선이 살아 있다 — 얇고 어두운 선만으로는 배경에 묻힌다.
            spread = top.getchannel("A").filter(ImageFilter.MaxFilter(3))
            spread = spread.filter(ImageFilter.GaussianBlur(1.8))
            tint = args.halo_color.lstrip("#")
            rgb = tuple(int(tint[i:i + 2], 16) for i in (0, 2, 4))
            glow = Image.new("RGBA", top.size, rgb + (0,))
            glow.putalpha(spread.point(
                lambda v: int(v * args.line_halo)))
            under = Image.alpha_composite(under, glow)
        if args.line_alpha < 1.0:
            # **색이 아니라 알파를 낮춘다.** 색 자체를 흐리게 구우면 얇은 선이
            # 회색으로 보인다 — 진한 색을 옅게 얹어야 코랄로 읽힌다.
            alpha = top.getchannel("A").point(
                lambda v: int(v * args.line_alpha))
            top.putalpha(alpha)
        merged = Image.alpha_composite(under, top)
        merged.save(base)
    os.remove(over)

print(f"[compose] {len(pairs)}장에 선 레이어를 얹었다")
