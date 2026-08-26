# -*- coding: utf-8 -*-
"""분석 연출용 소리를 합성해 assets/hologram/sfx/ 에 쓴다.

    python tools/hologram/make_sounds.py

받아온 음원을 쓰지 않는 이유는 라이선스가 걸리고, 무엇보다 이 앱에서는 소리
크기와 길이를 우리가 쥐고 있어야 하기 때문이다.

**전자음(삐빅 삐빅)으로 만든다.** 대역 잡음으로 만든 '공기' 소리를 쓰던 때가
있었는데, 조용해서 좋기는 해도 기계가 일하는 소리로는 안 들렸다. 지금은
두 음이 붙은 **한 쌍(삐빅)** 을 기본 단위로 쓰고, 그 쌍을 되풀이한다 —
계기가 값을 하나씩 물고 확정하는 소리다. 간격이 일정하면 "삐삐삐삐" 로 뭉개지므로
쌍 안은 좁게(18~22ms), 쌍 사이는 넓게(74~78ms) 벌린다.

사각파를 그대로 쓰면 고음이 접혀서(에일리어싱) 싸구려로 들린다. 홀수 배음을
나이퀴스트 아래까지만 더해 만든다.

BeautyTalk 은 눈이 보이지 않는 사용자가 쓴다. TTS 가 주 채널이고 이 소리는
장식이다. **삐 소리는 말소리와 같은 대역에 있어서 길거나 크면 바로 안내를
덮는다.** 그래서 전부 40ms 안팎이고, 자주 울리는 것일수록 더 낮춰 잡았다.
유일하게 계속 나는 bed 는 -32 dBFS 다.
"""

import math
import os
import struct
import wave

import numpy as np

RATE = 44100
OUT = os.path.join(os.path.dirname(__file__), "..", "..",
                   "assets", "hologram", "sfx")
RNG = np.random.default_rng(11)

# 삐 소리의 음높이. 예전엔 1.5~2.3kHz 였는데 **너무 날카롭고**, 하필 자음이
# 사는 대역(2~4kHz)이라 안내를 가장 잘 덮는 자리였다. 한 옥타브 넘게 내렸다.
_LOW, _HIGH, _TOP = 466.0, 622.0, 831.0   # A#4 / D#5 / G#5


def seconds(n):
    return np.arange(int(RATE * n)) / RATE


def fade(sig, attack=0.005, release=0.05):
    """양 끝을 눕힌다. 안 하면 딸깍 소리가 난다."""
    n = len(sig)
    a = min(int(RATE * attack), n // 2)
    r = min(int(RATE * release), n // 2)
    env = np.ones(n, dtype=np.float32)
    if a:
        env[:a] = np.linspace(0.0, 1.0, a)
    if r:
        env[-r:] = np.linspace(1.0, 0.0, r)
    return sig * env


def lowpass(sig, cutoff_hz):
    """차단 주파수가 시간에 따라 움직이는 1차 저역 통과.

    cutoff_hz 는 스칼라 또는 sig 와 같은 길이의 배열.
    """
    cutoff = np.broadcast_to(np.asarray(cutoff_hz, dtype=np.float64), sig.shape)
    out = np.zeros_like(sig)
    prev = 0.0
    k = 2.0 * math.pi / RATE
    for i in range(len(sig)):
        a = k * cutoff[i]
        a = a / (a + 1.0)
        prev += a * (sig[i] - prev)
        out[i] = prev
    return out


def bandpass(sig, low_hz, high_hz):
    """저역 통과 두 개의 차. 계측기 소리의 '결' 은 대역을 좁히는 데서 나온다."""
    return lowpass(sig, high_hz) - lowpass(sig, low_hz)


def beep(hz, ms, harmonics=6):
    """삐 소리 한 번. 사각파를 대역 안에서만 쌓아 만든다.

    사각파를 그대로 쓰면 배음이 나이퀴스트를 넘어 접히면서 지저분해진다.
    홀수 배음을 1/n 로 더하되 18kHz 아래까지만 쓴다.
    """
    t = seconds(ms / 1000.0)
    sig = np.zeros(len(t), dtype=np.float32)
    for k in range(1, harmonics * 2, 2):
        if hz * k > 18000.0:
            break
        sig += np.sin(2 * np.pi * hz * k * t) / k

    # 짧게 눕힌다. 세우면 딸깍하고, 길게 눕히면 삐가 아니라 '뿅' 이 된다.
    return fade(sig, attack=0.0015, release=0.006)


def sequence(notes, gaps):
    """삐 소리를 사이를 두고 이어 붙인다.

    notes = [(hz, ms, gain), ...], gaps = 음 사이 간격(ms) 목록 또는 스칼라.
    쌍 안은 좁고 쌍 사이는 넓어야 "삐빅  삐빅" 으로 들린다 — 간격이 일정하면
    그냥 "삐삐삐삐" 다.
    """
    if not isinstance(gaps, (list, tuple)):
        gaps = [gaps] * (len(notes) - 1)
    parts = []
    for i, (hz, ms, gain) in enumerate(notes):
        if i:
            parts.append(np.zeros(int(RATE * gaps[i - 1] / 1000.0),
                                  dtype=np.float32))
        parts.append(beep(hz, ms) * gain)
    return np.concatenate(parts)


def normalize(sig, peak_dbfs):
    peak = np.abs(sig).max()
    if peak < 1e-9:
        return sig
    return sig * (10.0 ** (peak_dbfs / 20.0) / peak)


def write(name, sig):
    os.makedirs(OUT, exist_ok=True)
    path = os.path.normpath(os.path.join(OUT, name))
    data = (np.clip(sig, -1.0, 1.0) * 32767.0).astype(np.int16)
    with wave.open(path, "wb") as fp:
        fp.setnchannels(1)
        fp.setsampwidth(2)
        fp.setframerate(RATE)
        fp.writeframes(struct.pack(f"<{len(data)}h", *data))
    print(f"[sfx] {name}  {int(len(data) / RATE * 1000)}ms  "
          f"{os.path.getsize(path) / 1024:.0f}KB")


# ---------------------------------------------------------------- 소리들

def scan_sweep():
    """훑기 시작 — 삐빅 삐빅. 두 쌍. 320ms.

    두 음이 붙은 한 쌍이 계측기의 기본 단위다. 셋을 나란히 올리면 알림음처럼
    들리는데, 쌍을 반복하면 **같은 일을 계속 하고 있는** 소리가 된다.
    """
    return normalize(sequence(
        [(_LOW, 28, 0.95), (_HIGH, 30, 1.0),
         (_LOW, 28, 0.95), (_HIGH, 34, 1.0)],
        [20, 78, 20]), -19.0)


def lock_blip():
    """값이 걸릴 때 — 삐빅 한 쌍. 76ms.

    연출 내내 이 소리가 되풀이된다 ("삐빅 … 삐빅 … 삐빅"). 그래서 가장 짧고
    가장 작다 — 이것만 키우면 안내 문장이 통째로 씹힌다.
    """
    return normalize(sequence([(_LOW, 24, 0.9), (_HIGH, 26, 1.0)], [18]), -27.0)


def hologram_rise():
    """형태가 떠오를 때 — 같은 쌍을 한 음 올려 두 번. 360ms."""
    return normalize(sequence(
        [(_LOW, 28, 0.8), (_HIGH, 28, 0.85),
         (_HIGH, 28, 0.9), (_TOP, 44, 1.0)],
        [18, 74, 18]), -19.0)


def analysis_done():
    """분석이 끝났다는 두 음. 150ms.

    바로 뒤에 TTS 가 결과를 읽으므로 짧게 끊는다. 올려서 끝내야 '끝났다' 로
    들린다 — 내리면 '실패' 로 들린다.
    """
    return normalize(sequence([(_HIGH, 34, 0.9), (_TOP, 62, 1.0)], [22]), -17.0)


def hum_loop():
    """분석 중 **계속** 깔리는 소리. 2.4초, 이음매 없이 반복된다.

    낮은 hum 위에 삐빅 한 쌍을 0.8초마다 얹는다 — 그래서 분석이 20초를 끌든
    화면이 멈춰 있든 "삐빅 … 삐빅 … 삐빅" 이 계속 난다. 악센트를 그때그때
    울리는 방식으로는 이걸 못 만든다. 울릴 일이 없는 구간에서 뚝 끊긴다.

    주기가 2.4초에 정확히 떨어지는 주파수만 써야 이어 붙일 때 딸깍하지 않고,
    박자도 2.4 = 0.8 x 3 이라 루프 경계에서 어긋나지 않는다.
    """
    length = 2.4
    beat = 0.8
    t = seconds(length)
    sig = np.zeros(len(t), dtype=np.float32)
    for hz, gain in ((98.0, 0.6), (196.0, 0.16), (392.0, 0.05)):
        hz = round(hz * length) / length
        sig += np.sin(2 * np.pi * hz * t) * gain

    # 아주 느린 숨. 완전히 고정된 음은 기계가 멈춘 것처럼 들린다.
    sig *= 1.0 + 0.05 * np.sin(2 * np.pi * (round(0.5 * length) / length) * t)
    sig *= 0.45

    pair = sequence([(_LOW, 24, 0.9), (_HIGH, 26, 1.0)], [18])
    # round 여야 한다. 2.4/0.8 은 부동소수로 2.9999… 라 int() 면 한 박자를
    # 통째로 잃는다 (실제로 세 번 중 두 번만 들어갔다).
    for i in range(round(length / beat)):
        at = int(RATE * beat * i)
        sig[at:at + len(pair)] += pair[:len(sig) - at]

    # 양 끝을 눕히지 않는다 — 눕히면 반복될 때마다 소리가 꺼진다.
    # 삐빅이 피크를 잡으므로 hum 은 이보다 한참 아래에 깔린다.
    return normalize(sig, -22.0)


def main():
    write("scan_sweep.wav", scan_sweep())
    write("lock_blip.wav", lock_blip())
    write("hologram_rise.wav", hologram_rise())
    write("analysis_done.wav", analysis_done())
    write("hum_loop.wav", hum_loop())
    print(f"[sfx] -> {os.path.normpath(OUT)}")


main()
