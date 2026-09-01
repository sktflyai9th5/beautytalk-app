# -*- coding: utf-8 -*-
"""구운 홀로그램을 **네모 블록**으로 뭉개고, 훑는 자리에만 **주사선**을 긋는다.

한때 이 계단이 버그로 나왔다 — 앱에서 `FilterQuality.high` 가 Impeller 에서
제대로 안 먹어 늘릴 때 거친 단계로 떨어진 것이었다. 그 모습이 오히려
"스캔한 홀로그램" 처럼 보여서, 우연히 나오게 두지 않고 **여기서 굽는다.**
기기·드라이버가 어떻게 늘리든 같은 그림이 나와야 하므로 블록은 판에 새긴다.
앱은 `FilterQuality.none` 으로 그려야 블록 모서리가 살아 있다.

주사선은 **막대가 지나가는 자리에만** 깐다. 판 전체에 깔았더니 격자무늬가
처음부터 끝까지 붙박이로 있어서, 스캔하는 중이 아니라 그냥 그렇게 생긴
그림이 됐다. 훑고 지나갈 때만 결이 스쳤다 사라져야 훑는 것으로 읽힌다.

막대 자리는 프레임마다 **재서** 쓴다. 굽는 설정(`--scan-cycles`, 카메라
거리·기울기)이 바뀌면 자리도 바뀌는데 그걸 여기에 적어 두면 조용히 어긋난다.
막대는 얼굴 실루엣 밖까지 뻗으므로 가장자리 몇 칸의 알파만 보면 찾을 수 있다.
화면 밖으로 나간 프레임도 있어서, 찾은 것들로 직선을 맞춰 전체에 쓴다.

    python tools/hologram/pixelate.py <webp> [블록=8] [fps=24] [주사선간격=3]
                                       [색단계=0] [알파단계=4]
"""
import sys

import numpy as np
from PIL import Image

src = sys.argv[1]
block = int(sys.argv[2]) if len(sys.argv) > 2 else 8
fps = int(sys.argv[3]) if len(sys.argv) > 3 else 24
scan_every = int(sys.argv[4]) if len(sys.argv) > 4 else 3
tones = int(sys.argv[5]) if len(sys.argv) > 5 else 0
a_steps = int(sys.argv[6]) if len(sys.argv) > 6 else 4

# 주사선이 스치는 띠의 두께 (판 높이 대비) 와 가장 진할 때의 세기.
BAND = 0.20
DEPTH = 0.55


def flatten(v, steps):
    """0~255 를 `steps` 단계로 내린다 (양 끝은 그대로 0 과 255)."""
    if steps <= 1:
        return v
    k = steps - 1
    return min(255, max(0, int(round(v * k / 255.0)) * 255 // k))


_TONE = [flatten(v, tones) for v in range(256)] if tones > 0 else None
_ALPHA = [flatten(v, a_steps) for v in range(256)] if a_steps > 0 else None

im = Image.open(src)
n = getattr(im, "n_frames", 1)
w, h = im.size
small = (max(w // block, 1), max(h // block, 1))


def bar_row(frame):
    """이 프레임에서 훑는 막대가 있는 줄. 못 찾으면 None.

    실루엣 **밖**(좌우 가장자리)에서 알파가 있는 줄이 막대다 — 얼굴은
    가운데에만 있으므로 가장자리에 뭐가 있으면 그건 막대뿐이다.
    """
    a = np.asarray(frame.getchannel("A"), dtype=np.float32) / 255.0
    edge = int(a.shape[1] * 0.08)
    rows = np.concatenate([a[:, :edge], a[:, -edge:]], axis=1).mean(axis=1)
    if rows.max() < 0.02:
        return None
    return float(rows.argmax())


originals = []
found = []
for i in range(n):
    im.seek(i)
    f = im.convert("RGBA")
    originals.append(f)
    row = bar_row(f)
    if row is not None:
        found.append((i, row))

# 잰 값으로 직선을 맞춘다 (막대는 한 바퀴에 위에서 아래로 고르게 내려간다).
line = None
if scan_every > 0 and len(found) >= 4:
    xs = np.array([i for i, _ in found], dtype=np.float64)
    ys = np.array([r for _, r in found], dtype=np.float64)
    line = np.polyfit(xs, ys, 1)
    print("[pixelate] 막대 %d장에서 잼 -> 줄 = %.2f x 프레임 %+.1f"
          % (len(found), line[0], line[1]))
elif scan_every > 0:
    print("[pixelate] 훑는 막대가 없다 - 주사선은 넣지 않는다")

band = max(small[1] * BAND, 1.0)
frames = []
for i, f in enumerate(originals):
    tiny = f.resize(small, Image.BOX)
    if _TONE is not None:
        r, g, b, a = tiny.split()
        tiny = Image.merge("RGBA", (r.point(_TONE), g.point(_TONE),
                                    b.point(_TONE), a))
    if _ALPHA is not None:
        # 알파도 깎아야 실루엣이 부드럽게 번지지 않고 칸으로 끊긴다.
        tiny.putalpha(tiny.getchannel("A").point(_ALPHA))

    if line is not None:
        centre = (line[0] * i + line[1]) / block
        alpha = np.asarray(tiny.getchannel("A"), dtype=np.float32)
        for y in range(0, small[1], scan_every):
            near = 1.0 - abs(y - centre) / band
            if near <= 0:
                continue
            alpha[y] *= 1.0 - DEPTH * near
        tiny.putalpha(Image.fromarray(alpha.astype(np.uint8), mode="L"))

    frames.append(tiny.resize((w, h), Image.NEAREST))

frames[0].save(src, save_all=True, append_images=frames[1:],
               duration=int(round(1000 / fps)), loop=0,
               quality=90, method=4, lossless=False)
print("%s: %d장을 %dpx 블록으로 (%d x %d)" % (src, n, block, small[0], small[1]))
