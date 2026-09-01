"""검은 배경에 렌더된 홀로그램 프레임에 빛 번짐을 얹고 알파를 만든다.

    python glow.py --src <png들> --out <png들>

Blender 컴포지터를 쓰지 않는 이유는 두 가지다. 5.x 에서 컴포지터가 노드 그룹
방식으로 갈아엎어지면서 Math·MixRGB 노드까지 사라져 버전을 심하게 타고,
여기서 처리하면 다시 렌더하지 않고도 번짐 세기를 고칠 수 있다.

알파는 밝기에서 뽑는다. 투명 배경에 직접 글로우를 그리면 번짐이 실루엣
경계에서 잘려나가는데, 밝기를 알파로 삼으면 번짐이 알파째로 옅어져서
잘리지 않는다.

색은 알파로 나눠서 되돌려 놓는다(un-premultiply). 이걸 빼먹으면 앱에서
일반 합성할 때 어두워지기가 두 번 적용돼서 번짐이 눈에 띄게 죽는다.
"""

import argparse
import os

import numpy as np
from PIL import Image

LUMA = np.array([0.2126, 0.7152, 0.0722], dtype=np.float32)

parser = argparse.ArgumentParser()
parser.add_argument("--src", required=True, help="검은 배경 PNG 들이 있는 디렉터리")
parser.add_argument("--out", required=True, help="RGBA PNG 를 쓸 디렉터리")
parser.add_argument("--radii", default="2,7,20", help="번짐 반경들 (px, 쉼표 구분)")
parser.add_argument("--weights", default="0.55,0.35,0.22", help="반경별 세기")
parser.add_argument("--threshold", type=float, default=0.22, help="이 밝기 위쪽만 번진다")
parser.add_argument("--gain", type=float, default=1.35, help="알파 전체 세기")
parser.add_argument("--alpha-floor", type=float, default=0.016,
                    help="이 아래 알파는 0 으로 눌러 완전 투명으로 만든다")
parser.add_argument("--alpha-steps", type=int, default=32,
                    help="알파를 몇 단계로 양자화할지. 0 이면 안 한다")
parser.add_argument("--ink", default=None,
                    help="밝은 배경용. 흰 바탕에 렌더한 선을 이 색(hex) 잉크로 뽑는다")
parser.add_argument("--close-holes", type=int, default=0,
                    help="**실루엣 안쪽의 자잘한 구멍을 메운다** (이 반경까지). "
                         "머리카락 가닥 사이가 벌어진 자리가 밝은 카드 위에서는 "
                         "뚫린 것처럼 보인다. 알파를 닫고(팽창 후 수축) 그 자리의 "
                         "색은 이웃에서 끌어온다. 실루엣 바깥 테두리는 건드리지 "
                         "않는다 — 머리 모양이 부풀면 안 된다")
parser.add_argument("--keep-color", action="store_true",
                    help="이미 알파가 있는 렌더를 색 그대로 통과시킨다 (사진 텍스처용)")
args = parser.parse_args()

RADII = [float(x) for x in args.radii.split(",")]
WEIGHTS = [float(x) for x in args.weights.split(",")]
if len(RADII) != len(WEIGHTS):
    raise SystemExit("--radii 와 --weights 개수가 달라야 하지 않는다")


def _box_blur_1d(arr, radius, axis):
    """누적합으로 한 축 박스 블러. 반경이 커져도 비용이 늘지 않는다."""
    if radius < 1:
        return arr
    n = arr.shape[axis]
    width = 2 * radius + 1

    pad = [(0, 0)] * arr.ndim
    pad[axis] = (radius, radius)
    # 화면 밖은 검은 배경이라 0 으로 채우는 게 맞다.
    padded = np.pad(arr, pad, mode="constant")

    head_shape = list(padded.shape)
    head_shape[axis] = 1
    cumulative = np.concatenate(
        [np.zeros(head_shape, dtype=np.float32), np.cumsum(padded, axis=axis, dtype=np.float32)],
        axis=axis,
    )

    hi = [slice(None)] * arr.ndim
    lo = [slice(None)] * arr.ndim
    hi[axis] = slice(width, width + n)
    lo[axis] = slice(0, n)
    return (cumulative[tuple(hi)] - cumulative[tuple(lo)]) / width


def blur_f32(arr, sigma):
    """박스 블러 3패스로 가우시안을 근사한다.

    PIL 의 GaussianBlur 는 float 이미지를 받지 않고, uint8 로 내렸다 올리면
    번짐 꼬리처럼 값이 작은 구간에서 계단이 생긴다. 박스 3패스면 눈으로는
    가우시안과 구분되지 않으면서 float 인 채로 처리된다.
    """
    radius = max(1, int(round(sigma * 1.2)))
    out = arr
    for _ in range(3):
        out = _box_blur_1d(out, radius, axis=0)
        out = _box_blur_1d(out, radius, axis=1)
    return out


def close_holes(rgb, alpha, radius):
    """실루엣 안쪽의 구멍만 메운다.

    가로·세로 양쪽에서 '맨 처음 채워진 화소와 맨 끝 사이'를 안쪽으로 본다.
    둘 다 안쪽인데 비어 있으면 구멍이다 — 실루엣 바깥은 이 판정에 안 걸리므로
    머리 모양이 부푸는 일이 없다. 메운 자리의 색은 이웃에서 번지게 한다.
    """
    solid = alpha > 0.16
    if not solid.any():
        return rgb, alpha
    inside_h = np.zeros_like(solid)
    for y in range(solid.shape[0]):
        xs = np.flatnonzero(solid[y])
        if len(xs) > 1:
            inside_h[y, xs[0]:xs[-1] + 1] = True
    inside_v = np.zeros_like(solid)
    for x in range(solid.shape[1]):
        ys = np.flatnonzero(solid[:, x])
        if len(ys) > 1:
            inside_v[ys[0]:ys[-1] + 1, x] = True
    holes = inside_h & inside_v & ~solid
    if not holes.any():
        return rgb, alpha

    filled_rgb, filled_a = rgb.copy(), alpha.copy()
    known = solid.copy()
    todo = holes.copy()
    for _ in range(max(radius, 1)):
        if not todo.any():
            break
        acc = np.zeros_like(filled_rgb)
        acc_a = np.zeros_like(filled_a)
        count = np.zeros_like(filled_a)
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1),
                       (1, 1), (1, -1), (-1, 1), (-1, -1)):
            k = np.roll(known, (dy, dx), axis=(0, 1))
            acc += np.roll(filled_rgb, (dy, dx), axis=(0, 1)) * k[:, :, None]
            acc_a += np.roll(filled_a, (dy, dx), axis=(0, 1)) * k
            count += k
        grow = todo & (count > 0)
        if not grow.any():
            break
        filled_rgb[grow] = acc[grow] / count[grow, None]
        filled_a[grow] = np.maximum(acc_a[grow] / count[grow], 0.85)
        known |= grow
        todo &= ~grow
    return filled_rgb, filled_a


def process_keep_color(path_in, path_out):
    """투명 배경으로 렌더된 그림을 색 그대로 통과시킨다.

    사진을 입힌 아바타는 색이 곧 내용이라 밝기를 알파로 바꾸면 안 된다
    (그러면 얼굴이 한 가지 색으로 뭉개진다). 알파는 렌더가 이미 제대로
    들고 있으니 용량만 줄인다 — WebP 는 알파를 무손실로 저장해서
    값의 가짓수가 그대로 파일 크기가 된다.
    """
    rgba = np.asarray(Image.open(path_in).convert("RGBA"), dtype=np.float32) / 255.0
    rgb, alpha = rgba[:, :, :3].copy(), rgba[:, :, 3].copy()
    if args.close_holes > 0:
        rgb, alpha = close_holes(rgb, alpha, args.close_holes)
    rgba = np.concatenate([rgb, alpha[:, :, None]], axis=2)
    alpha = np.where(alpha < args.alpha_floor, 0.0, alpha)
    if args.alpha_steps > 0:
        alpha = np.round(alpha * args.alpha_steps) / args.alpha_steps

    out = np.concatenate([rgba[:, :, :3], alpha[:, :, None]], axis=2)
    Image.fromarray((out * 255.0 + 0.5).astype(np.uint8), mode="RGBA").save(path_out)


def process_ink(path_in, path_out, ink):
    """흰 바탕에 그려진 선을 잉크 색 + 알파로 바꾼다.

    밝은 배경에 얹을 때는 빛나는 선이 아니라 **그려진 선**이어야 한다. 밝기를
    알파로 쓰던 방식(어두운 배경용)을 그대로 쓰면 흰 배경에서 번짐이 뿌연
    안개로 보인다. 여기서는 어두운 만큼을 알파로 쓰고 색은 한 가지로 고정한다.
    색이 상수라 알파로 나눠 되돌리는 계산도 필요 없다.
    """
    rgb = np.asarray(Image.open(path_in).convert("RGB"), dtype=np.float32) / 255.0
    darkness = 1.0 - (rgb @ LUMA)

    # 아주 살짝만 번지게 한다. 넓게 번지면 선이 흐려져서 정밀해 보이지 않는다.
    softened = np.maximum(darkness, blur_f32(darkness[:, :, None], RADII[0])[:, :, 0] * 0.8)

    alpha = np.clip(softened * args.gain, 0.0, 1.0)
    alpha[alpha < args.alpha_floor] = 0.0
    if args.alpha_steps > 0:
        alpha = np.round(alpha * args.alpha_steps) / args.alpha_steps

    flat = np.empty(rgb.shape, dtype=np.float32)
    flat[:] = ink
    rgba = np.concatenate([flat, alpha[:, :, None]], axis=2)
    Image.fromarray((rgba * 255.0 + 0.5).astype(np.uint8), mode="RGBA").save(path_out)


def process(path_in, path_out):
    rgb = np.asarray(Image.open(path_in).convert("RGB"), dtype=np.float32) / 255.0

    # 밝은 데만 번지게 한다. 전체를 흐리면 형태가 뿌예진다.
    lum = rgb @ LUMA
    mask = np.clip((lum - args.threshold) / max(1.0 - args.threshold, 1e-4), 0.0, 1.0)
    highlights = rgb * mask[:, :, None]

    glow = np.zeros_like(rgb)
    for radius, weight in zip(RADII, WEIGHTS):
        glow += blur_f32(highlights, radius) * weight

    lit = np.clip(rgb + glow, 0.0, 1.0)

    lit_lum = lit @ LUMA
    alpha = np.clip(lit_lum * args.gain, 0.0, 1.0)

    # 눈에 안 보이는 알파를 0 으로 눌러 화면 대부분을 완전 투명으로 만든다.
    # WebP 는 알파를 무손실로 저장해서 -quality 를 낮춰도 크기가 안 준다.
    # 번짐 꼬리에 깔린 옅은 알파 노이즈가 파일 크기를 지배하는데,
    # 이걸 지우면 같은 그림에 용량만 3 분의 1 이 된다.
    faint = alpha < args.alpha_floor
    alpha[faint] = 0.0

    # 알파를 몇 단계로 뭉갠다. 무손실로 저장되는 채널이라 값의 가짓수가
    # 그대로 용량이 된다. 번짐 그라데이션은 단계가 줄어도 색이 가려줘서
    # 눈에 띄지 않는데 용량은 절반 아래로 떨어진다.
    if args.alpha_steps > 0:
        alpha = np.round(alpha * args.alpha_steps) / args.alpha_steps

    # 알파로 나눠 색을 원래 밝기로 되돌린다. 안 하면 합성 때 두 번 어두워진다.
    straight = np.clip(lit / np.maximum(lit_lum, 1e-4)[:, :, None], 0.0, 1.0)
    # 투명한 데의 색은 아무 의미가 없다. 0 으로 눕혀야 균일 영역이 커진다.
    straight[faint] = 0.0

    rgba = np.concatenate([straight, alpha[:, :, None]], axis=2)
    Image.fromarray((rgba * 255.0 + 0.5).astype(np.uint8), mode="RGBA").save(path_out)


def main():
    os.makedirs(args.out, exist_ok=True)
    frames = sorted(f for f in os.listdir(args.src) if f.lower().endswith(".png"))
    if not frames:
        raise SystemExit(f"PNG 가 없다: {args.src}")

    ink = None
    if args.ink:
        h = args.ink.lstrip("#")
        ink = np.array([int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4)], dtype=np.float32)

    for i, name in enumerate(frames):
        src, dst = os.path.join(args.src, name), os.path.join(args.out, name)
        if args.keep_color:
            process_keep_color(src, dst)
        elif ink is not None:
            process_ink(src, dst, ink)
        else:
            process(src, dst)
        if i % 12 == 0:
            print(f"[glow] {i + 1}/{len(frames)}")
    print(f"[glow] {len(frames)}장 완료 -> {args.out}")


main()
