"""연출 영상에 입힐 소리를 타임라인에 맞춰 한 트랙으로 섞는다.

    python tools/hologram/make_soundtrack.py --out build/scan_film/track.wav

`HologramScan` 이 실제로 소리를 내는 시점과 같은 값을 쓴다. 위젯 쪽 구간
상수를 바꿨으면 여기도 같이 바꿔야 영상과 소리가 어긋나지 않는다.
"""

import argparse
import os
import struct
import wave

import numpy as np

RATE = 44100
SFX = os.path.join(os.path.dirname(__file__), "..", "..",
                   "assets", "hologram", "sfx")

# HologramScan 의 `_short` 구간(컨트롤러 5.6초 기준)과 같은 값.
# 사진 구간이 빠졌으므로 빔 소리는 시작에 한 번뿐이다.
INTRO = 5.6
SWEEP_AT = 0.0
RISE_AT = 0.14
ANALYSIS = 0.38
# 조준틀이 부위에 물리는 시점 (_AnalysisPainter.zoneAt + zoneLock).
ZONES = [0.05 + i * 0.125 + 0.13 * 0.55 for i in range(7)]

parser = argparse.ArgumentParser()
parser.add_argument("--out", required=True)
parser.add_argument("--seconds", type=float, default=11.0, help="영상 길이")
args = parser.parse_args()


def load(name):
    path = os.path.normpath(os.path.join(SFX, name))
    with wave.open(path, "rb") as fp:
        raw = fp.readframes(fp.getnframes())
    return np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0


def main():
    length = int(RATE * args.seconds)
    track = np.zeros(length, dtype=np.float32)

    def place(sig, at_seconds, gain):
        start = int(RATE * at_seconds)
        if start >= length:
            return
        end = min(start + len(sig), length)
        track[start:end] += sig[: end - start] * gain

    # 분석 내내 도는 소리(저음 + 0.8초마다 삐빅). 완료음 직전에 끊는다.
    hum = load("hum_loop.wav")
    hum_until = int(RATE * (args.seconds - 0.35))
    tiled = np.tile(hum, int(np.ceil(hum_until / len(hum))))[:hum_until]
    track[:hum_until] += tiled * 0.5
    # 끝을 눕혀서 뚝 끊기지 않게 한다.
    tail = int(RATE * 0.3)
    track[hum_until - tail:hum_until] *= np.linspace(1.0, 0.0, tail)

    place(load("scan_sweep.wav"), INTRO * SWEEP_AT, 0.5)

    place(load("hologram_rise.wav"), INTRO * RISE_AT, 0.55)

    # 특징점마다 따로 울리지 않는다 — 도는 삐빅이 이미 박자를 잡고 있어서
    # 여기서 또 울리면 박자가 엉킨다. 부위가 물리는 순간에만 악센트를 얹는다.
    blip = load("lock_blip.wav")
    span = 1.0 - ANALYSIS
    for z in ZONES:
        place(blip, INTRO * (ANALYSIS + span * z), 0.28)
    place(load("analysis_done.wav"), args.seconds - 0.55, 0.5)

    peak = np.abs(track).max()
    if peak > 0.99:
        track *= 0.99 / peak

    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    data = (np.clip(track, -1.0, 1.0) * 32767.0).astype(np.int16)
    with wave.open(args.out, "wb") as fp:
        fp.setnchannels(1)
        fp.setsampwidth(2)
        fp.setframerate(RATE)
        fp.writeframes(struct.pack(f"<{len(data)}h", *data))

    print(f"[track] {args.seconds:.1f}초 -> {args.out}")


main()
