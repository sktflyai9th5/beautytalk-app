"""아바타에 입힐 사진을 **보정한다** — 피부는 고르게, 이목구비는 그대로.

    <venv>\\Scripts\\python.exe tools/hologram/retouch_face.py ^
        --mesh face_mesh.json --texture face_mesh_texture.jpg --out retouched.jpg

카톡으로 옮긴 사무실 스냅은 화질이 거칠고 조명이 얼룩진다. 그 사진을 그대로
얼굴에 입히면 잡티와 노이즈가 3D 로 확대되어 더 도드라진다.

**세 가지만 한다.**

  · 피부를 고르게 — 양방향 필터(bilateral)로 결만 눌러 준다. 가우시안으로
    뭉개면 밀랍 인형이 되므로, 경계를 지키는 필터로 눌러 놓고 원본과 섞는다.
  · 살짝 밝게, 살짝 따뜻하게 — 형광등 아래 사무실 스냅은 푸르게 뜬다.
  · 그늘을 들어 준다 — 눈 밑과 목 그림자가 진하면 피곤해 보인다.

**이목구비는 건드리지 않는다.** 눈·눈썹·입술·홍채는 원본을 그대로 되돌린다.
여기까지 뭉개면 사람이 흐릿해져서 "그 사람" 이 아니게 된다.

형태는 손대지 않는다 — 눈을 키우거나 턱을 깎는 식의 변형은 하지 않는다.
격자·하이라이트가 얼굴 위에 얹히는 화면이라 형태를 만지면 그 점들이
제자리를 벗어난다.
"""

import argparse
import json
import os

import cv2
import numpy as np
from PIL import Image

from mediapipe.tasks.python import vision

parser = argparse.ArgumentParser()
parser.add_argument("--mesh", required=True, help="face_to_mesh.py 가 낸 JSON")
parser.add_argument("--texture", required=True, help="보정할 원본 사진")
parser.add_argument("--out", required=True, help="쓸 경로")
parser.add_argument("--smooth", type=float, default=0.72,
                    help="피부를 얼마나 고르게 할지 0~1. 1 이면 필터 결과 그대로")
parser.add_argument("--brighten", type=float, default=0.07,
                    help="전체를 얼마나 밝힐지 0~1")
parser.add_argument("--warm", type=float, default=0.5,
                    help="푸른 형광등 기를 얼마나 걷을지 0~1")
parser.add_argument("--under-eye", type=float, default=0.0,
                    help="**다크써클을 지운다** (0~1). 눈 바로 아래 띠에서 주변 "
                         "피부보다 어두운·푸른 픽셀을 피부색 쪽으로 당긴다. "
                         "역광 스냅은 눈 밑 그늘이 실제보다 훨씬 짙게 찍힌다")
parser.add_argument("--edge-inpaint", type=float, default=0.0,
                    help="**얼굴에 걸친 머리카락을 지운다.** 얼굴 영역 안(이목구비 "
                         "제외)에서 피부라고 보기 어려운 어두운 픽셀을 주변 "
                         "피부색으로 메운다. 값은 어둡기 문턱(피부 중앙 밝기 대비 "
                         "이 비율보다 어두우면 머리카락으로 친다). 0.55 쯤")
parser.add_argument("--lift", type=float, default=0.35,
                    help="그늘을 얼마나 들어 올릴지 0~1")
args = parser.parse_args()


def polygon_mask(shape, points, indices, grow=0):
    """랜드마크 몇 개를 감싸는 볼록 다각형 마스크."""
    mask = np.zeros(shape[:2], dtype=np.uint8)
    picked = np.array([points[i] for i in indices if i < len(points)],
                      dtype=np.int32)
    if len(picked) < 3:
        return mask
    cv2.fillConvexPoly(mask, cv2.convexHull(picked), 255)
    if grow:
        k = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (grow * 2 + 1,) * 2)
        mask = cv2.dilate(mask, k)
    return mask


def feature_indices():
    """눈·눈썹·입술·홍채 정점 번호. 여기는 보정하지 않는다."""
    c = vision.FaceLandmarksConnections
    groups = (c.FACE_LANDMARKS_LEFT_EYE, c.FACE_LANDMARKS_RIGHT_EYE,
              c.FACE_LANDMARKS_LEFT_EYEBROW, c.FACE_LANDMARKS_RIGHT_EYEBROW,
              c.FACE_LANDMARKS_LIPS, c.FACE_LANDMARKS_LEFT_IRIS,
              c.FACE_LANDMARKS_RIGHT_IRIS)
    out = []
    for group in groups:
        out.append(sorted({i for conn in group for i in (conn.start, conn.end)}))
    return out


def main():
    with open(args.mesh, "r", encoding="utf-8") as fp:
        mesh = json.load(fp)
    flat = mesh.get("points_2d")
    if not flat:
        raise SystemExit("격자에 points_2d 가 없다 — 사진 위 좌표가 있어야 한다")

    image = np.asarray(Image.open(args.texture).convert("RGB"), dtype=np.float32)
    h, w = image.shape[:2]
    points = [(p[0] * w, p[1] * h) for p in flat]

    face = polygon_mask(image.shape, points, range(len(points)))
    # 가장자리는 부드럽게 넘어가야 한다. 딱 잘리면 보정한 자리가 테두리로 보인다.
    face = cv2.GaussianBlur(face, (0, 0), max(w, h) * 0.01)

    protect = np.zeros((h, w), dtype=np.uint8)
    for indices in feature_indices():
        protect = np.maximum(protect, polygon_mask(image.shape, points, indices,
                                                   grow=int(max(w, h) * 0.004)))
    protect = cv2.GaussianBlur(protect, (0, 0), max(w, h) * 0.004)

    weight = (face.astype(np.float32) / 255.0) * (1.0 - protect.astype(np.float32) / 255.0)
    weight = weight[:, :, None]

    # 피부 결만 누른다. 반지름은 얼굴 크기에 맞춰 잡아야 얼굴이 커도 작아도
    # 같은 정도로 보정된다.
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    face_w = max(xs) - min(xs)
    radius = max(int(face_w * 0.035), 3)
    smoothed = cv2.bilateralFilter(image, d=radius * 2 + 1,
                                   sigmaColor=36.0, sigmaSpace=radius)
    out = image * (1.0 - args.smooth * weight) + smoothed * (args.smooth * weight)

    # 그늘을 든다. 어두운 쪽만 올려서 얼굴이 납작해지지 않게 한다.
    if args.lift > 0:
        luma = out @ np.array([0.299, 0.587, 0.114], dtype=np.float32)
        shadow = np.clip(1.0 - luma / 140.0, 0.0, 1.0)[:, :, None]
        out = out + shadow * weight * (args.lift * 42.0)

    if args.brighten > 0:
        out = out + weight * (args.brighten * 255.0 * 0.35)

    # 얼굴 위에 걸친 머리카락: 얼굴 폴리곤 안에서 피부 밝기보다 한참 어두운
    # 픽셀을 골라 주변 피부로 메운다. 이목구비(protect)는 원래 어두우니 뺀다.
    if args.edge_inpaint > 0:
        luma_now = out @ np.array([0.299, 0.587, 0.114], dtype=np.float32)
        core = (weight[:, :, 0] > 0.55)
        skin_luma = float(np.median(luma_now[core])) if core.any() else 150.0
        # **얼굴 가장자리 테두리에서만 지운다.** 얼굴 전체를 대상으로 하면
        # 문턱을 올렸을 때 콧구멍·입가 그림자까지 머리카락으로 판정되어 코가
        # 지워진다 (실제로 코끝이 유령처럼 됐다). 머리카락은 얼굴 가장자리에만
        # 걸치므로 테두리 링이면 충분하다.
        hard_face = (face > 128).astype(np.uint8)
        ek = cv2.getStructuringElement(
            cv2.MORPH_ELLIPSE, (int(face_w * 0.22) | 1,) * 2)
        ring = hard_face & ~cv2.erode(hard_face, ek)
        dark = ((luma_now < skin_luma * args.edge_inpaint)
                & (ring > 0) & (protect < 40)).astype(np.uint8) * 255
        # **눈썹보다 위는 지우지 않는다.** 거기 어두운 건 앞머리다 — 지워서
        # 피부로 메우면 앞머리 위에 살구색 패치가 생긴다 (실제로 생겼다).
        # 이마 위 앞머리는 아래의 '어둡게 잇기'가 맡는다.
        c2 = vision.FaceLandmarksConnections
        brow_idx = {i for conn in (list(c2.FACE_LANDMARKS_LEFT_EYEBROW)
                                   + list(c2.FACE_LANDMARKS_RIGHT_EYEBROW))
                    for i in (conn.start, conn.end)}
        brow_top = int(min(points[i][1] for i in brow_idx))
        dark[:brow_top, :] = 0
        k = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (9, 9))
        dark = cv2.dilate(dark, k)
        if dark.any():
            # **주변 평균(TELEA)으로만 메우면 뿌연 회색 띠가 된다.** 얼굴은
            # 대체로 대칭이니, 지울 자리를 반대쪽 얼굴의 같은 자리에서 미러
            # 복사하면 진짜 피부결이 들어온다. 미러 자리도 어둡거나 얼굴
            # 밖이면 그 픽셀만 TELEA 로 메운다.
            cx = float(np.median([p[0] for p in points]))
            ys_d, xs_d = np.where(dark > 0)
            xs_m = np.clip((2 * cx - xs_d).astype(int), 0, w - 1)
            ok_m = (hard_face[ys_d, xs_m] > 0)                 & (luma_now[ys_d, xs_m] >= skin_luma * args.edge_inpaint)                 & (protect[ys_d, xs_m] < 40)
            out[ys_d[ok_m], xs_d[ok_m]] = out[ys_d[ok_m], xs_m[ok_m]]
            rest = np.zeros_like(dark)
            rest[ys_d[~ok_m], xs_d[~ok_m]] = 255
            if rest.any():
                out = cv2.inpaint(np.clip(out, 0, 255).astype(np.uint8), rest,
                                  inpaintRadius=max(int(face_w * 0.02), 3),
                                  flags=cv2.INPAINT_TELEA).astype(np.float32)
            # 미러로 붙인 자리를 살짝만 문질러 이음매를 없앤다.
            soft = cv2.GaussianBlur(out, (0, 0), 1.2)
            seam = cv2.GaussianBlur(dark.astype(np.float32) / 255.0, (0, 0),
                                    2.0)[:, :, None]
            out = out * (1 - seam * 0.7) + soft * (seam * 0.7)
            print(f"[retouch] 얼굴에 걸친 어두운 픽셀 {int((dark > 0).sum())}개: "
                  f"미러 복사 {int(ok_m.sum())} / 메움 {int((~ok_m).sum())}")

        # 이마에 걸친 앞머리의 **반그림자**(회색 — 밝기는 피부급인데 붉은기가
        # 없다)는 지우면 안 된다. 지우니 앞머리 위에 살구색 패치가 생겼다.
        # 원래 머리카락이 있던 자리니 **어둡게** 해서 3D 머리 색과 잇는다.
        redness = out[:, :, 0] - out[:, :, 2]
        skin_red = float(np.median(redness[core])) if core.any() else 30.0
        grayish = ((redness < skin_red * 0.45)
                   & (ring > 0) & (protect < 40) & (dark == 0))
        # 이마 위 앞머리(어두운 픽셀)도 여기 합친다 — 지우는 대신 어둡게.
        grayish |= ((luma_now < skin_luma * 0.8) & (ring > 0)
                    & (protect < 40))
        grayish[brow_top:, :] &= (redness < skin_red * 0.45)[brow_top:, :]
        if grayish.any():
            g = cv2.GaussianBlur(grayish.astype(np.float32), (0, 0),
                                 2.0)[:, :, None]
            out = out * (1.0 - g * 0.65) + (out * 0.22) * (g * 0.65)
            print(f"[retouch] 앞머리 반그림자 {int(grayish.sum())}픽셀을 "
                  f"어둡게 이었다")

    # 다크써클: 눈 폴리곤을 아래로 늘린 띠에서, 피부 중앙보다 어두운 만큼을
    # 피부색 쪽으로 당긴다. 세게 하면 밀랍처럼 되니 어두운 정도에 비례시킨다.
    if args.under_eye > 0:
        c = vision.FaceLandmarksConnections
        eyes = (c.FACE_LANDMARKS_LEFT_EYE, c.FACE_LANDMARKS_RIGHT_EYE)
        eye_band = np.zeros((h, w), dtype=np.uint8)
        for group in eyes:
            idx = sorted({i for conn in group
                          for i in (conn.start, conn.end)})
            m = polygon_mask(image.shape, points, idx,
                             grow=int(face_w * 0.11))
            # 눈 위쪽(눈썹 방향)이 아니라 **아래쪽만** 남긴다.
            ys_g = [points[i][1] for i in idx]
            m[:int(min(ys_g)), :] = 0
            eye_band = np.maximum(eye_band, m)
        eye_band = cv2.GaussianBlur(eye_band, (0, 0), face_w * 0.02)
        band_w = (eye_band.astype(np.float32) / 255.0
                  * (1.0 - protect.astype(np.float32) / 255.0)
                  * (face.astype(np.float32) / 255.0))
        luma_now = out @ np.array([0.299, 0.587, 0.114], dtype=np.float32)
        core = (weight[:, :, 0] > 0.55)
        skin_luma = float(np.median(luma_now[core])) if core.any() else 150.0
        skin_color = np.median(out[core], axis=0) if core.any() else np.full(3, 180.0)
        darkness = np.clip((skin_luma - luma_now) / max(skin_luma, 1.0), 0.0, 1.0)
        pull = (band_w * darkness * args.under_eye)[:, :, None]
        out = out * (1.0 - pull) + skin_color[None, None, :] * pull
        print(f"[retouch] 눈 밑 그늘을 들었다 (세기 {args.under_eye})")

    # 형광등 아래 스냅은 푸르게 뜬다. 파랑을 조금 내리고 빨강을 올린다.
    if args.warm > 0:
        tint = np.array([1.0 + 0.035 * args.warm, 1.0,
                         1.0 - 0.045 * args.warm], dtype=np.float32)
        out = out * (1.0 - weight) + out * tint * weight

    out = np.clip(out, 0, 255).astype(np.uint8)
    Image.fromarray(out).save(args.out, quality=94)
    covered = float((weight > 0.01).mean() * 100.0)
    print(f"[retouch] 얼굴 {covered:.1f}% 영역 보정 (결 {args.smooth}, "
          f"밝기 {args.brighten}, 그늘 {args.lift}, 온도 {args.warm}) -> {args.out}")


main()
