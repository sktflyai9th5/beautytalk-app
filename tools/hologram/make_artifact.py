"""연출을 브라우저에서 바로 볼 수 있는 단일 HTML 로 굽는다.

    python tools/hologram/make_artifact.py --out build/scan_viewer.html

사진·격자·홀로그램·소리를 전부 data URI 로 박아 넣어서 파일 하나로 돈다.
서버도 빌드도 필요 없이 열기만 하면 된다.

앱 화면(`AnalyzingPreview` + `HologramScan`)을 HTML 로 옮긴 것이라 원본이
바뀌면 여기도 같이 손봐야 한다. 구간 값과 색은 `hologram_scan.dart` 와 같은
숫자를 쓴다 — 한쪽만 바꾸면 어긋난다.
"""

import argparse
import base64
import json
import mimetypes
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.normpath(os.path.join(HERE, "..", "..", "assets", "hologram"))

parser = argparse.ArgumentParser()
parser.add_argument("--out", required=True)
parser.add_argument("--standalone", action="store_true",
                    help="브라우저로 바로 열 수 있는 완전한 html 로 굽는다. "
                         "아티팩트로 올릴 게 아니라 파일로 건넬 때 쓴다")
parser.add_argument("--assets", default=ASSETS)
args = parser.parse_args()


# 파이썬 기본 표에 webp 가 없는 환경이 있다. 없으면 octet-stream 으로 나가는데,
# <img> 는 내용을 보고 알아서 틀지만 ImageDecoder 는 type 을 곧이곧대로 믿는다.
mimetypes.add_type("image/webp", ".webp")


def data_uri(path):
    mime = mimetypes.guess_type(path)[0] or "application/octet-stream"
    with open(path, "rb") as fp:
        return f"data:{mime};base64," + base64.b64encode(fp.read()).decode()


def asset(name):
    return data_uri(os.path.join(args.assets, name))


with open(os.path.join(args.assets, "demo_face_points.json"), "r", encoding="utf-8") as fp:
    overlay = json.load(fp)

# 아바타 첫 프레임이 이미지 안에서 차지하는 영역. 이게 있어야 사진 위 격자
# 자리에 정확히 겹쳐 놓을 수 있다 (measure_hologram.py 가 재 둔 값).
fit_path = os.path.join(args.assets, "face_hologram.json")
fit = json.load(open(fit_path, encoding="utf-8")) if os.path.exists(fit_path) else None

# 부위별 **프레임마다의** 화면 위치. 얼굴이 좌우로 훑는데 짚는 점이 고정돼
# 있으면 이마를 짚던 점이 관자놀이로 밀려난다 (render_hologram.py --zones).
zones_path = os.path.join(args.assets, "face_hologram_zones.json")
track = (json.load(open(zones_path, encoding="utf-8"))
         if os.path.exists(zones_path) else None)

# 결과 화면용 판. **스캔 바가 없다** — 결과인데 막대가 계속 지나가면 아직
# 분석 중인 것으로 보인다. 얼굴이 좌우로 도는 건 그대로 둔다.
rzones_path = os.path.join(args.assets, "face_hologram_result_zones.json")
rtrack = (json.load(open(rzones_path, encoding="utf-8"))
          if os.path.exists(rzones_path) else None)

sfx = {
    key: asset(f"sfx/{name}")
    for key, name in (
        ("sweep", "scan_sweep.wav"),
        ("blip", "lock_blip.wav"),
        ("rise", "hologram_rise.wav"),
        ("done", "analysis_done.wav"),
        ("hum", "hum_loop.wav"),
    )
}

HTML = """<title>BeautyTalk 얼굴 스캔</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Playfair+Display:wght@700&family=Noto+Sans+KR:wght@400;500;700&display=swap">
<style>
  /* 색은 앱의 app_theme.dart · hologram_scan.dart 값을 그대로 옮겼다.
     이 화면을 앱 안에서 보이는 그대로 판단하려면 바탕색까지 같아야 한다. */
  :root {
    --canvas-top: #FFFDFC;
    --canvas-bottom: #FEF2F0;
    --surface: #FFFFFF;
    --ink: #301A1C;
    --ink-body: #6B5254;
    --brand: #B02426;
    --outline: #E1ABB8;
    --border: #E7D8D8;
    /* 분석 화면은 무채색이다. 앱 본체(코랄)와 일부러 계열을 달리해서
       계측 도구처럼 보이게 하고, 결과의 흰빛이 도드라지게 한다.
       여기 값은 **글자용**이다 — 캔버스에 그리는 색은 JS 쪽에 따로 있다. */
    --mist: #E3E6EA;
    --line: #23292F;
    --strong: #14181C;
    --mark: #FFFFFF;
    --label: #8B949C;
    --hair: #E1E5E9;
    --shadow: rgba(43, 51, 59, 0.13);
  }
  :root:not([data-theme="light"]) {
    @media (prefers-color-scheme: dark) {
      --canvas-top: #1A0A0E;
      --canvas-bottom: #120609;
      --surface: #241014;
      --ink: #FBEDEC;
      --ink-body: #C6A9AC;
      --brand: #FF8A8C;
      --border: #40252A;
      --outline: #6B3A44;
      --shadow: rgba(0, 0, 0, 0.5);
    }
  }
  :root[data-theme="dark"] {
    --canvas-top: #1A0A0E;
    --canvas-bottom: #120609;
    --surface: #241014;
    --ink: #FBEDEC;
    --ink-body: #C6A9AC;
    --brand: #FF8A8C;
    --border: #40252A;
    --outline: #6B3A44;
    --shadow: rgba(0, 0, 0, 0.5);
  }

  * { box-sizing: border-box; }
  body {
    margin: 0;
    min-height: 100vh;
    background: linear-gradient(180deg, var(--canvas-top), var(--canvas-bottom));
    color: var(--ink);
    font-family: "Noto Sans KR", system-ui, sans-serif;
    display: flex;
    justify-content: center;
    padding: 44px 20px 72px;
  }
  main { width: 100%; max-width: 420px; display: flex; flex-direction: column; gap: 24px; }

  header { display: flex; flex-direction: column; gap: 7px; }
  .eyebrow {
    font-size: 10px; font-weight: 700; letter-spacing: 0.18em;
    text-transform: uppercase; color: var(--line);
  }
  h1 {
    margin: 0; font-family: "Playfair Display", Georgia, serif;
    font-size: 31px; line-height: 1.14; text-wrap: balance; letter-spacing: -0.01em;
  }
  .lede { margin: 0; font-size: 13.5px; line-height: 1.7; color: var(--ink-body); }

  /* ---- 폰 목업. 앱 화면 그대로다. */
  .phone {
    position: relative; width: 100%; aspect-ratio: 393 / 720;
    border-radius: 30px; overflow: hidden;
    background: linear-gradient(180deg, #FFFFFF, #FFF9F7 55%, #FEF1EF);
    box-shadow: 0 26px 64px var(--shadow), 0 0 0 1px var(--border);
    display: flex; flex-direction: column; padding: 14px 0 12px;
  }
  .appbar { display: flex; align-items: center; padding: 0 20px; height: 44px; }
  .back {
    width: 44px; height: 44px; display: grid; place-items: center;
    font-size: 26px; font-weight: 700; color: #301A1C; opacity: 0.7;
  }
  .steps { display: flex; align-items: flex-start; padding: 8px 20px 0; }
  .step { flex: 1; display: flex; flex-direction: column; align-items: center; gap: 5px; }
  .dot {
    width: 26px; height: 26px; border-radius: 999px;
    border: 1.5px solid rgba(191, 115, 112, 0.35);
    display: grid; place-items: center;
    font-size: 12px; font-weight: 700; color: #7A6062;
  }
  .step.on .dot {
    border: none; color: #fff;
    background: linear-gradient(135deg, #8E1A22, #C93034);
  }
  .step span { font-size: 11px; color: #755E61; }
  .step.on span { color: #A32226; font-weight: 700; }
  .rule { flex: 0 0 14px; height: 1px; background: var(--border); margin-top: 13px; }

  /* 분석 면. 흰 바탕 — 사진은 카드로 서고 글자는 그 아래로 내린다. */
  .card {
    position: relative; flex: 1; margin: 10px 16px 0;
    border-radius: 26px; overflow: hidden;
    background: linear-gradient(180deg, #FFFFFF, #FCFCFD 55%, #F6F7F8);
    display: flex; flex-direction: column; padding: 16px 16px 14px;
  }
  .stage { flex: 1; display: grid; place-items: center; min-height: 0; }
  /* 높이를 채우되 카드 폭을 넘지 않게. max-width 가 없으면 화면이 좁을 때
     사진이 카드 밖으로 밀려 나간다. */
  .plate {
    position: relative; height: 100%; aspect-ratio: 3 / 4;
    max-width: 100%; max-height: 100%;
  }
  .plate canvas, .plate img.holo { position: absolute; inset: 0; width: 100%; height: 100%; }
  .plate img.holo, .plate canvas.holo {
    object-fit: contain; opacity: 0; pointer-events: none;
  }
  /* 프레임을 직접 넘기는 쪽(canvas)이 되면 img 는 숨긴다. 둘 다 보이면 겹친다. */
  .plate.decoded img#holo { display: none; }
  /* 부위를 짚는 표시는 아바타 **위**에 얹혀야 한다. */
  .plate canvas#hud { pointer-events: none; }
  .halo {
    position: absolute; inset: 12%; border-radius: 50%; opacity: 0; pointer-events: none;
    background: radial-gradient(circle, rgba(227,230,234,0.34) 0%, rgba(227,230,234,0.12) 60%, transparent 100%);
  }

  .telemetry {
    height: 22px; display: flex; align-items: center; gap: 10px; margin-top: 18px;
    font-size: 9.5px; font-variant-numeric: tabular-nums; opacity: 0;
  }
  .telemetry b { letter-spacing: 0.13em; color: var(--strong); font-weight: 700; }
  .telemetry span { letter-spacing: 0.06em; color: var(--label); }
  /* 돌아가는 중이라는 표시등. 멈춘 화면과 일하는 화면을 가르는 건
     결국 이런 작은 깜박임이다. gap 대신 여백을 직접 준다. */
  .lamp {
    width: 5px; height: 5px; border-radius: 50%;
    background: var(--strong); margin-right: -3px; flex: none;
  }

  .statusline { font-size: 26px; font-weight: 700; color: var(--ink); line-height: 1.4; }
  .track {
    margin-top: 12px; height: 4px; border-radius: 2px;
    background: #E7EBEF; overflow: hidden;
  }
  .fill {
    height: 100%; width: 0%; border-radius: 2px;
    background: linear-gradient(90deg, var(--mist), var(--strong));
    transition: width 80ms linear;
  }

  .cancel {
    margin: 14px 16px 0; height: 52px; border-radius: 20px;
    border: 1.5px solid var(--outline); background: transparent;
    display: grid; place-items: center;
    font-size: 16px; font-weight: 700; color: #B02426;
  }

  .idle {
    position: absolute; inset: 0; display: grid; place-items: center; align-content: center;
    background: linear-gradient(180deg, #FFFFFF, #F6F7F8);
    gap: 12px; text-align: center; padding: 0 28px; z-index: 2;
  }
  .idle p { margin: 0; font-size: 12.5px; line-height: 1.6; color: var(--label); }

  /* ---- 결과 화면. 분석이 끝나면 이쪽으로 넘어간다.
     분석 화면을 감싸는 .analysing 도 **카드 높이를 그대로 이어받아야** 한다.
     빼먹으면 안쪽 .stage 의 flex:1 이 기댈 곳을 잃어서 무대가 0px 로
     찌그러지고 아바타가 통째로 사라진다 (실제로 그렇게 사라졌다). */
  .analysing, .result {
    flex: 1; min-height: 0; display: flex; flex-direction: column;
  }
  .result { display: none; }
  .card.done .analysing { display: none; }
  .card.done .result { display: flex; }
  .result h2 { margin: 0 0 10px; font-size: 26px; font-weight: 700; color: var(--ink); }
  /* 회색 면에 담지 않는다. 카드를 깔면 방금까지 보던 큰 아바타 화면과
     딴 화면이 되고 문장도 작아진다 — 분석 중 화면과 같은 구성으로 둔다. */
  .shot { position: relative; flex: 1; min-height: 0; }
  .shot canvas { position: absolute; inset: 0; width: 100%; height: 100%; }
  .rregion {
    margin-top: 10px; font-size: 13px; font-weight: 700;
    letter-spacing: 0.4px; color: var(--strong);
  }
  /* 분석 중 화면의 상태 문장과 같은 크기다. 이 화면에서 사람이 읽는 유일한
     문장이라 여기서 줄이면 안 된다. */
  .rline { margin-top: 6px; font-size: 26px; font-weight: 700;
           line-height: 1.4; color: var(--ink); }

  /* ---- 컨트롤 */
  .controls { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; }
  button.play {
    flex: 1 1 auto; min-height: 48px; padding: 0 22px; border-radius: 16px; border: none;
    background: var(--strong); color: #fff; cursor: pointer;
    font-family: inherit; font-size: 15px; font-weight: 700; letter-spacing: 0.01em;
  }
  button.play:hover { filter: brightness(1.12); }
  .toggle {
    display: flex; align-items: center; gap: 8px; min-height: 48px; padding: 0 16px;
    border-radius: 16px; border: 1px solid var(--hair); background: var(--surface);
    font-size: 14px; font-weight: 500; color: var(--ink); cursor: pointer;
  }
  button:focus-visible, .toggle:focus-within { outline: 2px solid var(--strong); outline-offset: 2px; }

  /* ---- 구간 설명. 실제로 순서가 있는 내용이라 시각만 붙였다. */
  ol.beats { list-style: none; margin: 0; padding: 0; }
  ol.beats li {
    display: grid; grid-template-columns: 44px 1fr; gap: 14px;
    padding: 13px 0; border-top: 1px solid var(--hair); align-items: baseline;
  }
  ol.beats li:last-child { border-bottom: 1px solid var(--hair); }
  .at {
    font-size: 11px; font-weight: 700; color: var(--line);
    font-variant-numeric: tabular-nums; letter-spacing: 0.04em;
  }
  .beat b { display: block; font-size: 13.5px; margin-bottom: 3px; }
  .beat span { font-size: 12.5px; line-height: 1.65; color: var(--ink-body); }

  footer { font-size: 12px; line-height: 1.75; color: var(--ink-body); }
  footer code {
    font-family: ui-monospace, "SF Mono", Menlo, monospace;
    font-size: 11.5px; background: var(--surface);
    padding: 2px 6px; border-radius: 5px; border: 1px solid var(--hair);
  }
  @media (prefers-reduced-motion: reduce) { .fill { transition: none; } }
</style>

<main>
  <header>
    <div class="eyebrow">BeautyTalk · 메이크업 분석</div>
    <h1>얼굴 스캔 연출</h1>
    <p class="lede">
      얼굴이 3D로 떠오르고, 일곱 부위를 차례로 짚습니다.
      앱의 <strong>분석 중</strong> 화면 그대로입니다 — 색과 부품 모두 실제 화면과 같습니다.
    </p>
  </header>

  <div class="phone">
    <div class="appbar"><div class="back">‹</div></div>
    <div class="steps" id="steps"></div>
    <div class="card" id="card">
      <div class="result" id="result">
        <h2>메이크업 분석 완료!</h2>
        <div class="shot"><canvas id="shot"></canvas></div>
        <div class="rregion" id="rregion"></div>
        <div class="rline" id="rline"></div>
      </div>
      <div class="analysing">
      <div class="stage">
        <div class="plate" id="plate">
          <canvas id="scan"></canvas>
          <div class="halo" id="halo"></div>
          <img class="holo" id="holo" alt="3D 얼굴 아바타">
          <canvas class="holo" id="holoc" width="512" height="512"></canvas>
          <canvas id="hud"></canvas>
        </div>
      </div>
      <div class="telemetry" id="telemetry"><i class="lamp" id="lamp"></i><b id="tcount"></b><span id="tcoord"></span></div>
      <div class="statusline" id="statusline">분석 준비됨</div>
      <div class="track"><div class="fill" id="fill"></div></div>
      <div class="idle" id="idle">
        <p>브라우저는 한 번 눌러야 소리를 내줍니다.<br>아래 재생 버튼을 눌러 주세요.</p>
      </div>
      </div>
    </div>

    <div class="cancel">취소하고 다시 촬영하기</div>
  </div>

  <div class="controls">
    <button class="play" id="play">연출 재생</button>
    <label class="toggle">
      <input type="checkbox" id="sound" checked>
      소리
    </label>
  </div>

  <ol class="beats">
    <li><span class="at">0.0s</span><span class="beat"><b>아바타가 떠오른다</b>
      <span>사진을 훑는 앞 구간은 뺐습니다. 분석이 언제 끝날지 모르는데 앞에
      긴 연출을 두면 결과가 그만큼 늦게 나오는 것으로 느껴집니다.</span></span></li>
    <li><span class="at">0.2s</span><span class="beat"><b>계기 눈금이 둘린다</b>
      <span>가장자리 눈금 위로 걸린 눈금 하나가 한 칸씩 끊어 옮겨 다닙니다.
      아래로 흐르는 좌표는 지금 찍히는 점의 실제 값입니다.</span></span></li>
    <li><span class="at">2.1s</span><span class="beat"><b>일곱 부위를 짚는다</b>
      <span>이마 · 눈썹 · 눈가 · 볼 · 코 · 입술 · 턱선을 위에서 아래로 훑습니다.
      네 귀퉁이가 조여 들어와 물릴 때마다 삐빅 소리가 함께 납니다.
      <b>수치는 띄우지 않습니다</b> — 어디를 보고 있는지만 짚습니다.</span></span></li>
    <li><span class="at">계속</span><span class="beat"><b>끝났다고 말하지 않는다</b>
      <span>이 화면은 분석이 언제 끝나는지 모릅니다. 문장은 "분석 중"으로
      고정이고, 완료는 결과 화면이 알립니다. 삐빅도 0.8초마다 계속 돌아서
      서버가 오래 걸려도 소리가 끊기지 않습니다.</span></span></li>
  </ol>

  <footer>
    실제 앱에서는 이 화면이 백엔드 응답을 기다리는 20~30초 동안 떠 있습니다.
    앱에서는 같은 문장을 TTS 가 읽어 주고(여기서는 브라우저 음성으로 대신
    들려줍니다), 짚는 점은 얼굴이 돌면 따라 움직입니다.
  </footer>
</main>

<script id="overlay-data" type="application/json">__OVERLAY__</script>
<script>
(() => {
  const DATA = JSON.parse(document.getElementById('overlay-data').textContent);
  const SFX = __SFX__;
  const FIT = __FIT__;
  const TRACK = __TRACK__;
  const RTRACK = __RTRACK__;

  // hologram_scan.dart 의 `_short` 와 같은 값. 한쪽만 고치면 어긋난다.
  // 사진을 훑는 앞 구간은 뺐다 — 분석이 언제 끝날지 모르는데 앞에 7초짜리
  // 연출을 두면 결과가 그만큼 늦게 나오는 것으로 느껴진다. 아바타만 두면
  // 서버가 오래 걸려도 화면이 계속 살아 있다.
  const PHOTO_STAGE = false;
  const INTRO = 5600, RUN = 9000;
  const BEAM = [0, 0], MESH = [0, 0], LOCK = [0.04, 0.34];
  const HOLD_END = 0, MORPH = [0, 0.14], ANALYSIS = 0.38;
  // 계측값이 다 세어진 뒤에 물러난다. 아바타가 뜨는 시점에 맞추면
  // 아직 세는 중에 흐려져서 읽다 만 것처럼 보인다.
  const TELEM = [0.36, 0.54];
  // 아바타를 키우는 배율. 사진 구간이 있으면 1 이어야 한다 —
  // 사진 위 격자와 같은 자리·같은 크기여야 겹쳐 바뀔 때 튀지 않는다.
  // 아바타가 머리 전체를 갖게 된 뒤로 키우지 않는다 (hologram_scan.dart 와 같은 값).
  const ZOOM = 1;
  // 캔버스에 **그리는** 색. 밝기 순서가 코랄 때와 뒤집혀 있다 —
  // 선·점은 흰색이고, 밝은 살결 위에서 읽히도록 **어두운 후광**을 깐다
  // (hologram_scan.dart 의 ScanTone 과 같은 값이어야 앱과 같아 보인다).
  const MIST = '227,230,234', LINE = '255,255,255', STRONG = '255,255,255';
  const LABEL = '139,148,156', GLINT = '255,255,255', HALO = '20,26,32';
  // 얼굴 밖(카드 위)에 그리는 것은 어두워야 보인다 — 조준 눈금, 모서리
  // 갈고리, 라벨 글자, 결과에서 켠 흰 면 위의 삼각형 변 (ScanTone.frame).
  const FRAME = '43,51,59';
  // 결과에서 켜는 흰빛. 어두운 격자 한가운데라 대비로 바로 읽힌다.
  const MARK = '255,255,255';
  // 분석 표시를 얼마나 옅게 얹을지. 격자가 사진 위에 **얹혀 있다** 로
  // 보여야지 덮으면 얼굴이 안 보인다. hologram_scan.dart 의 ScanTone.scrim
  // 과 같은 값이어야 앱과 뷰어가 같은 농도로 보인다.
  // 0.55 까지 내렸다가 1 로 되돌렸다 — **멀리서 보면 옅은 선이 사라진다.**
  // 흰 후광이 선을 띄워 주므로 옅게 하지 않고도 얼굴이 비쳐 보인다.
  const SCRIM = 1.0;
  // 선 굵기 배수. 멀리서도 읽히게 한 단계 굵혔다.
  const WEIGHT = 1.3;

  // (짚는 지점, 라벨 지점, 이름). 전부 0~1 비율.
  // 위에서 아래 순서다 — 스캔선이 내려가는 방향과 같아야 훑으면서 하나씩
  // 잡는 것으로 읽힌다. 라벨은 좌우로 번갈아 두고 세로로 벌린다.
  // (구울 때의 키, 잰 값이 없을 때의 자리, 라벨 자리, 화면에 쓰는 이름).
  // 키와 이름이 다르다 — 좌우를 나눠 구웠지만 라벨에는 "눈썹" 이라고만 쓴다.
  const ZONES = [
    ['이마', [0.52, 0.285], [0.87, 0.13], '이마'],
    ['오른쪽눈썹', [0.38, 0.345], [0.12, 0.25], '눈썹'],
    ['왼쪽눈가', [0.62, 0.395], [0.87, 0.36], '눈가'],
    ['오른쪽볼', [0.355, 0.495], [0.12, 0.47], '볼'],
    ['코', [0.50, 0.505], [0.87, 0.58], '코'],
    ['입술', [0.50, 0.585], [0.12, 0.69], '입술'],
    ['턱선', [0.53, 0.655], [0.87, 0.80], '턱선'],
  ];
  const ZONE_AT = i => 0.05 + i * 0.125;
  const ZONE_LOCK = 0.13 * 0.55;

  // 앱이 실제로 띄우는 문장 하나뿐이다 (`AppState.analysisLine`).
  // 진행에 따라 바뀌지 않고 **끝났다고 말하지 않는다** — 분석이 언제 끝나는지
  // 이 화면은 모른다. 완료는 결과 화면이 알린다.
  const STATUS_LINE = '피부를 분석 중이에요.';
  const STEPS = ['촬영', '질문', '분석', '결과'];

  const stepsEl = document.getElementById('steps');
  const stepEls = [];
  STEPS.forEach((name, i) => {
    if (i) { const r = document.createElement('div'); r.className = 'rule'; stepsEl.append(r); }
    const s = document.createElement('div');
    s.className = 'step';
    s.innerHTML = `<div class="dot">${i + 1}</div><span>${name}</span>`;
    stepEls.push(s);
    stepsEl.append(s);
  });

  /// 지금 단계 하나만 켠다. 분석이 끝나면 결과로 옮겨 간다.
  function setStep(at) {
    stepEls.forEach((el, i) => el.classList.toggle('on', i === at));
  }
  setStep(2);

  const canvas = document.getElementById('scan');
  const ctx = canvas.getContext('2d');
  const hud = document.getElementById('hud');
  const hctx = hud.getContext('2d');
  const holo = document.getElementById('holo');
  const holoc = document.getElementById('holoc');
  const plate = document.getElementById('plate');
  const halo = document.getElementById('halo');
  const idle = document.getElementById('idle');
  const fill = document.getElementById('fill');
  const statusline = document.getElementById('statusline');
  const telemetry = document.getElementById('telemetry');
  const card = document.getElementById('card');
  const shot = document.getElementById('shot');
  const rregion = document.getElementById('rregion');
  const rline = document.getElementById('rline');
  const tcount = document.getElementById('tcount');
  const lamp = document.getElementById('lamp');
  const tcoord = document.getElementById('tcoord');
  const playBtn = document.getElementById('play');
  const soundBox = document.getElementById('sound');

  const photo = new Image();
  photo.src = "__PHOTO__";
  const HOLO_SRC = "__HOLO__";
  const RHOLO_SRC = "__RHOLO__";
  holo.addEventListener('load', fit);
  holo.src = HOLO_SRC;

  const audio = {};
  for (const [k, src] of Object.entries(SFX)) {
    const a = new Audio(src);
    a.preload = 'auto';
    if (k === 'hum') { a.loop = true; a.volume = 0.5; }
    audio[k] = a;
  }
  const VOLUME = { sweep: 0.5, blip: 0.28, rise: 0.55, done: 0.5 };
  function play(name) {
    if (!soundBox.checked) return;
    const a = audio[name];
    if (!a) return;
    try { a.currentTime = 0; a.volume = VOLUME[name] ?? 0.5; a.play(); } catch (e) { /* 소리는 장식이다 */ }
  }

  // 앱에서는 TTS 가 화면 글귀와 **같은 문장**을 읽어 준다. 여기서도 브라우저
  // 음성으로 그대로 읽어야 "분석 중" 이 글자로만 있는 게 아니라는 게 확인된다.
  // 목소리는 기기마다 다르고 없을 수도 있다 — 없으면 조용히 넘어간다.
  function speak(text) {
    if (!soundBox.checked) return;
    try {
      const u = new SpeechSynthesisUtterance(text);
      u.lang = 'ko-KR';
      u.rate = 1.05;
      const ko = speechSynthesis.getVoices().find(v => v.lang.startsWith('ko'));
      if (ko) u.voice = ko;
      // 말하는 동안 기계음을 낮춘다. 삐빅은 말소리와 같은 대역이라
      // 안 낮추면 안내가 씹힌다 — 앱의 ScanSfx.duck 과 같은 처리다.
      audio.hum.volume = 0.14;
      u.onend = u.onerror = () => { audio.hum.volume = 0.5; };
      speechSynthesis.speak(u);
    } catch (e) { /* 소리는 장식이다 */ }
  }

  // 어두운 선 뒤에 까는 흰 후광. 굵고 흐린 흰 선을 먼저 긋고 그 위에 진한
  // 선을 얹으면 배경이 무엇이든 선이 떠 보인다 — 밝은 테두리 + 어두운 심지라
  // **금속을 새긴 것처럼** 읽히고, 무엇보다 멀리서도 선이 살아 있다.
  // 이름을 haloStroke 로 둔다. `halo` 는 이미 후광 div 를 담고 있어서
  // 같은 이름을 쓰면 **스크립트가 통째로 파싱 실패**한다.
  function haloStroke(c, path, width, alpha) {
    c.save();
    c.strokeStyle = `rgba(${HALO},${Math.min(1, alpha * 0.85)})`;
    c.lineWidth = width + 2.2;
    c.lineJoin = 'round';
    c.shadowColor = `rgba(${HALO},${Math.min(1, alpha)})`;
    c.shadowBlur = 3;
    c.stroke(path);
    c.restore();
  }

  // 격자가 사진 안에서 차지하는 사각형. 아바타를 이 자리에 맞춘다.
  let PLACE = null;

  const BOUNDS = (() => {
    const m = DATA.mesh || [];
    if (!m.length) return null;
    let l = m[0][0], r = l, t = m[0][1], b = t;
    for (const [x, y] of m) {
      if (x < l) l = x; if (x > r) r = x;
      if (y < t) t = y; if (y > b) b = y;
    }
    return { l, t, w: r - l, h: b - t };
  })();

  /// 아바타를 2D 격자 자리에 겹쳐 놓는다. 자리가 어긋나면 크기가 튀면서
  /// "변했다" 가 아니라 "잘렸다" 로 보인다.
  function placeHolo(w, h) {
    // 아직 자리를 안 잡았으면(폭 0) 계산이 NaN 이 되어 transform 이 통째로 무시된다.
    if (!FIT || !BOUNDS || !(w > 0 && h > 0)) return;
    const c = FIT.content;             // [l, t, r, b] — 이미지 안 비율
    const cw = c[2] - c[0], ch = c[3] - c[1];
    if (cw <= 0 || ch <= 0) return;

    // object-fit: contain 으로 정사각 이미지를 넣으면 짧은 변에 맞춰 들어간다.
    const side = Math.min(w, h);
    const imgLeft = (w - side) / 2, imgTop = (h - side) / 2;
    const ccx = imgLeft + (c[0] + cw / 2) * side;
    const ccy = imgTop + (c[1] + ch / 2) * side;

    // 제 중심에서 ZOOM 만큼 키운 자리에 앉힌다.
    const tw = BOUNDS.w * ZOOM * w, th = BOUNDS.h * ZOOM * h;
    const tcx = (BOUNDS.l + BOUNDS.w / 2) * w;
    const tcy = (BOUNDS.t + BOUNDS.h / 2) * h;
    const s = Math.min(tw / (cw * side), th / (ch * side));

    const t = `translate(${tcx - ccx * s}px, ${tcy - ccy * s}px) scale(${s})`;
    for (const el of [holo, holoc]) {
      el.style.transformOrigin = '0 0';
      el.style.transform = t;
    }

    // 짚는 표시가 **같은 셈**을 써야 얼굴에서 미끄러지지 않는다.
    // object-fit 여백(imgLeft/imgTop)은 img 가 그리는 그림에 이미 들어 있어서
    // transform 에는 없다 — 좌표를 직접 옮길 때만 더한다.
    PLACE = {
      s,
      dx: tcx - ccx * s + imgLeft * s,
      dy: tcy - ccy * s + imgTop * s,
      side,
    };
  }

  /// 구운 이미지 안 비율 좌표 → 캔버스 좌표.
  function mapZone(u, v) {
    if (!PLACE) return null;
    return [PLACE.dx + u * PLACE.side * PLACE.s,
            PLACE.dy + v * PLACE.side * PLACE.s];
  }

  // 아바타 한 바퀴. 구울 때의 장수 / fps 와 같아야 한다.
  const HOLO_FRAMES = 72, HOLO_LOOP = 3000;

  // 움직이는 WebP 를 <img> 로 틀면 **지금 몇 번째 프레임인지 알 수 없다.**
  // 시계로 어림해 봤는데 안 된다 — 재생이 언제 시작됐는지도 모르고 밀리기도
  // 해서 어긋남이 계속 커진다. 그게 조준틀이 얼굴에서 미끄러지는 원인이었다.
  //
  // ImageDecoder 로 프레임을 **직접 뽑아 캔버스에 그린다.** 그리면 그 번호가
  // 곧 화면에 있는 프레임이라 어림이 없다. 이 API 가 없는 브라우저에서는
  // <img> 를 그대로 틀고 짚는 점은 **고정 좌표로 둔다** — 어긋난 채 움직이는
  // 것보다 안 움직이는 게 낫다.
  let shownFrame = -1;   // 캔버스에 그려져 있는 프레임 (-1 이면 아직 없음)
  let still = null;      // 스캔 바가 없는 0 번 장 (결과 화면용)
  let decoding = false;

  function b64ToBytes(b64) {
    const bin = atob(b64);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  }

  async function startDecoder() {
    if (!('ImageDecoder' in window)) return;
    try {
      // **fetch 를 쓰지 않는다.** 게시된 아티팩트는 CSP 가 빡빡해서 data: URI
      // 로의 요청까지 막힐 수 있고, 그러면 디코더가 통째로 실패해서 짚는 점이
      // 고정 좌표로 떨어지고 결과 화면의 아바타도 안 그려진다.
      // base64 는 어차피 문서 안에 들어 있으니 그냥 푼다.
      const buf = b64ToBytes(HOLO_SRC.slice(HOLO_SRC.indexOf(',') + 1));
      const dec = new ImageDecoder({ data: buf, type: 'image/webp' });
      // completed 만 기다리면 안 된다. 트랙 목록은 따로 준비돼서,
      // 바로 selectedTrack 을 읽으면 null 이다 (여기서 한 번 걸렸다).
      await dec.tracks.ready;
      await dec.completed;
      const track = dec.tracks.selectedTrack;
      const count = (track && track.frameCount) || HOLO_FRAMES;
      const ctx2 = holoc.getContext('2d');

      const draw = async (want) => {
        const { image } = await dec.decode({ frameIndex: want });
        ctx2.clearRect(0, 0, holoc.width, holoc.height);
        ctx2.drawImage(image, 0, 0, holoc.width, holoc.height);
        image.close();
        shownFrame = want;
      };

      // 한 장을 **먼저 그린 뒤에** img 를 숨긴다. 순서를 바꾸면 첫 프레임이
      // 그려질 때까지 아바타가 통째로 사라진다 — 탭이 뒤에 있어서 rAF 가
      // 안 돌면 영영 빈 화면이 된다.
      await draw(0);
      plate.classList.add('decoded');

      // 0 번은 **정면이고 스캔 바가 머리 밖에 있다.** 결과 화면이 이 장을
      // 쓴다 — 아바타가 계속 훑고 돌면 분석이 아직 안 끝난 것으로 보인다.
      still = document.createElement('canvas');
      still.width = holoc.width;
      still.height = holoc.height;
      still.getContext('2d').drawImage(holoc, 0, 0);

      const tick = async () => {
        const want = Math.floor((performance.now() / HOLO_LOOP) * HOLO_FRAMES)
                     % count;
        if (!decoding && want !== shownFrame) {
          decoding = true;
          try {
            await draw(want);
          } catch (e) { /* 한 장 놓쳐도 다음 장에서 따라잡는다 */ }
          decoding = false;
        }
        requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
    } catch (e) { /* 못 하면 <img> 로 그대로 간다 */ }
  }

  function zoneAt(frame) {
    if (!TRACK || !PLACE) return null;
    const row = TRACK.frames[frame % TRACK.frames.length];
    if (!row) return null;
    return ZONES.map(([key]) => {
      const i = TRACK.names.indexOf(key);
      const uv = i < 0 ? null : row[i];
      return uv ? mapZone(uv[0], uv[1]) : null;
    });
  }

  function zoneAnchors() {
    // 그려진 프레임을 모르면 짚는 점을 움직이지 않는다.
    if (shownFrame < 0) return null;
    return zoneAt(shownFrame);
  }

  function fit() {
    const r = canvas.getBoundingClientRect();
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    for (const [el, c] of [[canvas, ctx], [hud, hctx]]) {
      el.width = Math.max(1, Math.round(r.width * dpr));
      el.height = Math.max(1, Math.round(r.height * dpr));
      c.setTransform(dpr, 0, 0, dpr, 0, 0);
    }
    placeHolo(r.width, r.height);
    return r;
  }
  const seg = (t, a, b) => Math.min(1, Math.max(0, (t - a) / (b - a)));

  function drawCover(img, w, h) {
    const s = Math.max(w / img.width, h / img.height);
    const dw = img.width * s, dh = img.height * s;
    ctx.drawImage(img, (w - dw) / 2, (h - dh) / 2, dw, dh);
  }

  // 캔버스가 곧 사진 카드다. 좌표는 캔버스 전체 기준(0~1).
  function draw(t, w, h) {
    ctx.clearRect(0, 0, w, h);
    const morph = seg(t, MORPH[0], MORPH[1]);
    // 계측값 표시도 쓰는 값이라 사진 카드 밖에서 센다.
    const revealed = Math.floor(DATA.points.length * seg(t, LOCK[0], LOCK[1]));

    // 계기 눈금. 아바타만 떠 있으면 '그림' 이지만 눈금이 둘리면 '재는 창' 이
    // 된다. 걸린 눈금 하나가 한 칸씩 끊어 옮겨 다닌다 — 부드럽게 흐르면
    // 계측이 아니라 장식으로 보인다. 눈금에 값은 없다(숫자를 지어내지 않는다).
    const gr = seg(t, 0, 0.22);
    if (gr > 0) {
      const N = 24, live = Math.floor(t * 2.2 * N) % N;
      for (let i = 1; i < N; i++) {
        const big = i % 4 === 0, len = big ? 7 : 3.5;
        if (i === live || i === (live + N / 2) % N) {
          ctx.strokeStyle = `rgba(${FRAME},${0.6 * gr * SCRIM})`; ctx.lineWidth = 1.2 * WEIGHT;
        } else if (big) {
          ctx.strokeStyle = `rgba(${FRAME},${0.3 * gr * SCRIM})`; ctx.lineWidth = WEIGHT;
        } else {
          ctx.strokeStyle = `rgba(${MIST},${0.85 * gr * SCRIM})`; ctx.lineWidth = WEIGHT;
        }
        const x = w * i / N, y = h * i / N;
        ctx.beginPath();
        ctx.moveTo(x, 0); ctx.lineTo(x, len);
        ctx.moveTo(x, h); ctx.lineTo(x, h - len);
        ctx.moveTo(0, y); ctx.lineTo(len, y);
        ctx.moveTo(w, y); ctx.lineTo(w - len, y);
        ctx.stroke();
      }
    }

    // 사진 카드. 앞 구간을 뺐으면 통째로 그리지 않는다 — 잠깐이라도
    // 비쳤다 사라지면 그게 더 눈에 띈다.
    if (PHOTO_STAGE) {
      ctx.save();
      ctx.globalAlpha = 1 - morph;
      ctx.beginPath();
      ctx.roundRect(0, 0, w, h, 17);
      ctx.save();
      ctx.clip();

      ctx.fillStyle = '#FFFFFF';
      ctx.fillRect(0, 0, w, h);
      if (photo.complete) {
        drawCover(photo, w, h);
        // 어둡게 덮지 않고 하얗게 띄운다. 얼굴은 그대로 보이면서 진한 선이 읽힌다.
        ctx.fillStyle = 'rgba(255,255,255,0.10)';
        ctx.fillRect(0, 0, w, h);
      }

      const meshIn = seg(t, MESH[0], MESH[1]);
      const settle = seg(t, MESH[1], HOLD_END);
      if (meshIn > 0 && DATA.mesh) {
        const at = i => [DATA.mesh[i][0] * w, DATA.mesh[i][1] * h];
        const grid = new Path2D(), contour = new Path2D(), front = new Path2D();
        const collect = (lines, settled) => {
          for (const [a, b] of (lines || [])) {
            const midY = (DATA.mesh[a][1] + DATA.mesh[b][1]) / 2;
            if (midY > meshIn) continue;
            const path = (meshIn - midY) < 0.09 ? front : settled;
            const A = at(a), B = at(b);
            path.moveTo(A[0], A[1]); path.lineTo(B[0], B[1]);
          }
        };
        collect(DATA.edges, grid);
        collect(DATA.contours, contour);

        // 흰 후광을 먼저 깐다. 어두운 선은 이래야 얼굴 위에서 떠 보인다.
        haloStroke(ctx, grid, 0.7 * WEIGHT, 0.55 * SCRIM);
        haloStroke(ctx, contour, 0.9 * WEIGHT, 0.7 * SCRIM);
        haloStroke(ctx, front, 1.0 * WEIGHT, 0.7 * SCRIM);

        ctx.lineWidth = 0.7 * WEIGHT;
        ctx.strokeStyle = `rgba(${LINE},${(0.88 + 0.12 * settle) * SCRIM})`;
        ctx.stroke(grid);

        // 이목구비는 한 단계 진하게. 격자가 성근 만큼 이 선들이 형태를 짊어진다.
        ctx.lineWidth = 0.9 * WEIGHT; ctx.lineCap = 'round';
        ctx.strokeStyle = `rgba(${STRONG},${(0.92 + 0.08 * settle) * SCRIM})`;
        ctx.stroke(contour);

        ctx.lineWidth = 1.0 * WEIGHT;
        ctx.strokeStyle = `rgba(${STRONG},${SCRIM})`;
        ctx.stroke(front);
        ctx.lineCap = 'butt';
      }

      // 잡힌 점은 피부 위 하이라이트로 찍는다. 테두리를 두르면 하이라이트가
      // 아니라 얼굴에 박힌 구슬처럼 보인다 — 번짐과 심지 두 겹이면 충분하다.
      ctx.save();
      ctx.shadowColor = `rgba(${GLINT},${0.95 * SCRIM})`;
      ctx.shadowBlur = 10;
      ctx.fillStyle = `rgba(${GLINT},${SCRIM})`;
      for (let i = 0; i < revealed; i++) {
        const [nx, ny] = DATA.points[i];
        const age = Math.min(1, (revealed - i) / 6);
        const r = (1.1 + (1 - age) * 1.8) * 0.95;
        ctx.beginPath(); ctx.arc(nx * w, ny * h, r, 0, Math.PI * 2); ctx.fill();
      }
      ctx.restore();

      const beam = seg(t, BEAM[0], BEAM[1]);
      if (beam > 0 && beam < 1) {
        // 톱니파 — 한 방향으로만 내려가고 화면 밖에서 되돌아온다.
        // 왕복시키면 훑는 게 아니라 흔들리는 것으로 보인다.
        const phase = (beam * 2) % 1;
        const y = h * phase;
        const vis = Math.min(1, Math.min(phase, 1 - phase) / 0.12);
        if (vis > 0) {
          // 잔상은 선 뒤쪽(위)으로만 끌린다. 양쪽으로 번지면 띠가 되어
          // 어디가 지금 지나는 줄인지 알 수 없다.
          const g = ctx.createLinearGradient(0, y - 44, 0, y);
          g.addColorStop(0, `rgba(${MIST},0)`);
          g.addColorStop(1, `rgba(${MIST},${0.5 * vis})`);
          ctx.fillStyle = g;
          ctx.fillRect(0, y - 44, w, 44);
          // 흰 바탕에서는 번지게 하지 않는다 — 번지면 뿌옇기만 하다.
          ctx.strokeStyle = `rgba(${STRONG},${0.9 * vis})`;
          ctx.lineWidth = 1.4;
          ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(w, y); ctx.stroke();
        }
      }
      ctx.restore();

      // 카드 테두리 한 줄. 흰 바탕 위의 흰 카드라 이게 있어야 면이 선다.
      ctx.beginPath(); ctx.roundRect(0.5, 0.5, w - 1, h - 1, 17);
      ctx.strokeStyle = '#E1E5E9'; ctx.lineWidth = 1; ctx.stroke();
      ctx.restore();
    }

    const br = seg(t, 0, 0.18);
    if (br > 0) {
      const len = 22 * br, i2 = 10;
      ctx.strokeStyle = `rgba(${FRAME},${0.6 * br * SCRIM})`;
      ctx.lineWidth = 1.0 * WEIGHT; ctx.lineCap = 'round'; ctx.lineJoin = 'round';
      const L = i2, R = w - i2, T = i2, B = h - i2;
      for (const pts of [
        [[L, T + len], [L, T], [L + len, T]],
        [[R - len, T], [R, T], [R, T + len]],
        [[L, B - len], [L, B], [L + len, B]],
        [[R - len, B], [R, B], [R, B - len]],
      ]) {
        ctx.beginPath();
        ctx.moveTo(pts[0][0], pts[0][1]);
        for (const q of pts.slice(1)) ctx.lineTo(q[0], q[1]);
        ctx.stroke();
      }
      ctx.lineCap = 'butt';
    }
    return revealed;
  }

  // 3D 아바타를 부위별로 짚는 표시.
  // **수치를 지어내지 않는다.** 어디를 보고 있는지만 짚는다 — 그럴듯한 숫자를
  // 띄우면 데모로는 그럴싸해도 제품에서는 거짓말이 된다.
  function drawHud(t, w, h) {
    hctx.clearRect(0, 0, w, h);
    if (t <= ANALYSIS) return;
    const amount = seg(t, ANALYSIS, 1.0);

    // 구울 때 잰 값이 있으면 그걸 쓴다 — 얼굴이 도는 것까지 들어 있다.
    const tracked = zoneAnchors();
    // 첫 장 자리. 라벨을 얼마나 밀지 재는 기준이다.
    const rests = tracked ? zoneAt(0) : null;

    ZONES.forEach(([key, an, ln, name], i) => {
      const at = ZONE_AT(i);
      const on = Math.min(1, Math.max(0, (amount - at) / 0.13));
      if (on <= 0) return;

      // 잰 값이 없을 때만 고정 좌표를 배율만큼 민다. 라벨까지 밀면 화면 밖이다.
      const ox = BOUNDS.l + BOUNDS.w / 2, oy = BOUNDS.t + BOUNDS.h / 2;
      const hit = tracked && tracked[i];
      const ax = hit ? hit[0] : (ox + (an[0] - ox) * ZOOM) * w;
      const ay = hit ? hit[1] : (oy + (an[1] - oy) * ZOOM) * h;

      // 라벨도 얼굴을 따라 움직인다. 짚는 점만 움직이고 이름표가 붙박이면
      // 둘이 따로 노는 것으로 보인다. 다만 **덜 움직인다** — 라벨은 좌우
      // 끝에 붙어 있어서 같은 폭으로 밀면 화면을 넘어간다.
      const rest = rests && rests[i];
      const dxl = (hit && rest) ? (hit[0] - rest[0]) * 0.55 : 0;
      const dyl = (hit && rest) ? (hit[1] - rest[1]) * 0.55 : 0;
      const lx = ln[0] * w + dxl, ly = ln[1] * h + dyl;
      // 짚는 점만 움직이므로 어느 쪽으로 끌지도 매 프레임 다시 본다.
      const toRight = lx > ax;

      hctx.strokeStyle = `rgba(${FRAME},${0.75 * on * SCRIM})`;
      hctx.lineWidth = 0.7 * WEIGHT;
      hctx.beginPath();
      hctx.moveTo(ax, ay);
      if (on > 0.55) {
        // 지시선은 꺾어서 끈다. 비스듬한 직선보다 계측 도면처럼 읽힌다.
        hctx.lineTo(ax + (lx - ax) * 0.55, ly);
        hctx.lineTo(lx, ly);
      } else {
        hctx.lineTo(ax + (lx - ax) * on, ay + (ly - ay) * on);
      }
      hctx.stroke();

      // 짚는 지점 — 속을 비운 작은 원. 채우면 하이라이트와 헷갈린다.
      // 조준틀 — 네 귀퉁이가 조여 들어와 물린다. 그냥 점을 찍으면
      // '표시해 뒀다' 이지만, 조여 들어오면 지금 재고 있다로 읽힌다.
      const close = Math.min(1, on / 0.55);
      const half = 11 - 6.4 * close, arm = 3.4;
      hctx.strokeStyle = `rgba(${STRONG},${0.85 * on * SCRIM})`;
      hctx.lineWidth = 1.0 * WEIGHT; hctx.lineCap = 'round';
      hctx.beginPath();
      for (const [sx, sy] of [[-1, -1], [1, -1], [-1, 1], [1, 1]]) {
        const cx = ax + half * sx, cy = ay + half * sy;
        hctx.moveTo(cx, cy - arm * sy);
        hctx.lineTo(cx, cy);
        hctx.lineTo(cx - arm * sx, cy);
      }
      hctx.stroke();
      hctx.lineCap = 'butt';

      if (close >= 1) {
        hctx.fillStyle = `rgba(${GLINT},${0.9 * on * SCRIM})`;
        hctx.beginPath(); hctx.arc(ax, ay, 2.6, 0, Math.PI * 2); hctx.fill();
        hctx.strokeStyle = `rgba(${STRONG},${0.9 * on * SCRIM})`;
        hctx.lineWidth = 0.9 * WEIGHT;
        hctx.beginPath(); hctx.arc(ax, ay, 2.6, 0, Math.PI * 2); hctx.stroke();
      }

      if (on < 0.6) return;
      const fade = Math.min(1, (on - 0.6) / 0.4);
      // 다음 부위로 넘어가면 앞 부위는 확인된 것으로 바꾼다.
      const state = amount > at + 0.125 ? '확인' : '검사 중';

      hctx.textAlign = toRight ? 'left' : 'right';
      const tx = toRight ? lx + 6 : lx - 6;
      hctx.font = '700 11.5px "Noto Sans KR", sans-serif';
      hctx.fillStyle = `rgba(${FRAME},${fade})`;
      hctx.fillText(name, tx, ly - 6);
      hctx.font = '9px "Noto Sans KR", sans-serif';
      hctx.fillStyle = `rgba(${LABEL},${fade})`;
      hctx.fillText(state, tx, ly + 7);
    });
    hctx.textAlign = 'left';
  }

  // ---- 결과 화면 ----------------------------------------------------------
  //
  // 문제가 있는 자리를 **아바타 위에 빛으로 켠다.** 색을 칠하면 "여기에 뭘
  // 발랐다" 로 읽히지만 빛은 "여기를 보라" 로 읽힌다. 더하기 합성으로 얹어서
  // 아래 피부색이 그대로 살아 있게 한다 — 안 그러면 뭐가 문제인지 안 보인다.
  //
  // 부위 이름 → 구울 때 쓴 키. 좌우가 안 적혀 있으면 한쪽으로 몰아 준다.
  function zoneKey(region) {
    const r = region.replace(/ /g, '');
    const side = (r.includes('왼') || r.includes('좌')) ? '왼쪽' : '오른쪽';
    if (r.includes('이마')) return '이마';
    if (r.includes('눈썹')) return side + '눈썹';
    if (r.includes('눈')) return side + '눈가';
    if (r.includes('볼') || r.includes('뺨')) return side + '볼';
    if (r.includes('코')) return '코';
    if (r.includes('입술') || r.includes('입')) return '입술';
    if (r.includes('턱')) return '턱선';
    return null;
  }

  // 화면 구성을 보여 주기 위한 **예시** 문장이다. 실제 앱에서는 서버가 준
  // region/state/action 이 그대로 들어간다 — 여기서 지어낸 수치는 없다.
  const FINDINGS = [
    ['왼쪽 볼', '베이스가 고르지 않게 발려 있어요.', '퍼프로 가볍게 두드려 정리해 주세요.'],
    ['입술', '입술 경계가 조금 번져 있어요.', '면봉으로 바깥선을 정리해 주세요.'],
    ['이마', '피지로 살짝 무너졌어요.', '기름종이로 누른 뒤 파우더를 얹어 주세요.'],
  ];

  let picked = null;
  let resultRaf = 0;

  function drawShot() {
    const box = shot.getBoundingClientRect();
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const w = box.width, h = box.height;
    if (!w || !h) return;
    shot.width = Math.round(w * dpr);
    shot.height = Math.round(h * dpr);
    const cx = shot.getContext('2d');
    cx.setTransform(dpr, 0, 0, dpr, 0, 0);
    cx.clearRect(0, 0, w, h);

    // 아바타는 분석 화면에서 돌고 있는 캔버스를 그대로 옮겨 그린다.
    // 숨겨져 있어도 그림은 계속 갱신되므로 프레임이 살아 있다.
    //
    // 디코더를 못 쓰는 환경에서는 <img> 를 그대로 옮겨 그린다. 여기서 물러서지
    // 않으면 결과 화면의 아바타 자리가 통째로 비어 버린다.
    const side = Math.min(w, h);
    const ox = (w - side) / 2, oy = (h - side) / 2;
    const src = rFrame >= 0 ? rholo : (still || (holo.complete ? holo : null));
    if (src) cx.drawImage(src, ox, oy, side, side);

    // **삼각형 모양 그대로 밝힌다.** 동그란 빛은 얼굴 위에 얹힌 남의 도형이지만,
    // 삼각형은 방금 분석 화면에서 얼굴을 덮고 있던 바로 그 격자다.
    // 결과용 판의 그 프레임 자리를 쓴다.
    const T = (rFrame >= 0 && RTRACK) ? RTRACK : TRACK;
    const at2 = rFrame >= 0 ? rFrame : 0;
    const pts = (T && T.mesh) ? T.mesh[at2 % T.mesh.length] : null;
    const key = zoneKey(FINDING[0]);
    const tris = (pts && key && T.tris) ? T.tris[key] : null;
    if (!tris || !tris.length) return;

    const path = new Path2D();
    for (const t of tris) {
      if (t.some(i => !pts[i])) continue;
      const a = pts[t[0]], b = pts[t[1]], c = pts[t[2]];
      path.moveTo(ox + a[0] * side, oy + a[1] * side);
      path.lineTo(ox + b[0] * side, oy + b[1] * side);
      path.lineTo(ox + c[0] * side, oy + c[1] * side);
      path.closePath();
    }

    cx.save();
    // 면은 더하기로 얹어 빛으로 읽히게 하되 세기는 낮게 — 진하면 그 자리
    // 피부가 안 보여서 뭐가 문제인지 판단할 수가 없다.
    // **더하기(lighter)가 아니라 그냥 얹는다.** 흰색을 더하면 밝은 피부 위에서
    // 곧바로 흰색에 붙어 스티커가 되고 그 안의 삼각형도 같이 사라진다.
    cx.shadowColor = `rgba(${MARK},0.9)`;
    cx.shadowBlur = 14;
    cx.fillStyle = `rgba(${MARK},0.22)`;
    cx.fill(path);
    cx.shadowBlur = 0;
    // 얼굴이 비쳐 보일 만큼만. 꽉 채우면 흰 스티커가 된다.
    cx.fillStyle = `rgba(${MARK},0.42)`;
    cx.fill(path);
    cx.restore();

    // 밝은 띠가 비스듬히 훑고 지나간다. **두 줄**이다 — 좁고 아주 밝은 앞줄에
    // 넓고 옅은 뒷줄이 따라붙어야 금속에 빛이 스치는 것처럼 보인다.
    const span = side;
    const ph = ((performance.now() / 1400) % 1);
    cx.save();
    cx.clip(path);
    for (const [lead, wide, peak] of [[0, 0.62, 0.55], [0.16, 0.24, 1]]) {
      const at = -span + (((ph + lead) % 1)) * span * 2;
      const g2 = cx.createLinearGradient(
        ox + at, oy + at, ox + at + span * wide, oy + at + span * wide);
      g2.addColorStop(0, `rgba(${MARK},0)`);
      g2.addColorStop(0.5, `rgba(${MARK},${peak})`);
      g2.addColorStop(1, `rgba(${MARK},0)`);
      cx.fillStyle = g2;
      cx.fillRect(0, 0, w, h);
    }
    cx.restore();

    // 테두리도 같이 숨 쉰다. 면만 반짝이면 윤곽은 죽은 채로 남는다.
    const pulse = 0.55 + 0.45 * Math.sin(ph * 2 * Math.PI);
    cx.save();
    cx.strokeStyle = `rgba(${MARK},${0.9 * pulse})`;
    cx.lineWidth = 2.6 * WEIGHT;
    cx.lineJoin = 'round';
    cx.shadowColor = `rgba(${MARK},${pulse})`;
    cx.shadowBlur = 8;
    cx.stroke(path);
    cx.restore();

    // 삼각형의 변. **어두운 선**이어야 흰 면 위에서 보인다.
    cx.strokeStyle = `rgba(${FRAME},0.9)`;
    cx.lineWidth = 1.1 * WEIGHT;
    cx.lineJoin = 'round';
    cx.stroke(path);
  }

  // 결과용 아바타. 스캔 바가 없는 판을 따로 돌린다.
  const rholo = document.createElement('canvas');
  rholo.width = rholo.height = 384;
  let rFrame = -1, rDecoding = false;

  async function startResultDecoder() {
    if (!('ImageDecoder' in window)) return;
    try {
      const buf = b64ToBytes(RHOLO_SRC.slice(RHOLO_SRC.indexOf(',') + 1));
      const dec = new ImageDecoder({ data: buf, type: 'image/webp' });
      await dec.tracks.ready;
      await dec.completed;
      const track = dec.tracks.selectedTrack;
      const count = (track && track.frameCount) || HOLO_FRAMES;
      const c2 = rholo.getContext('2d');

      const step = async () => {
        const want = Math.floor((performance.now() / HOLO_LOOP) * HOLO_FRAMES)
                     % count;
        if (!rDecoding && want !== rFrame
            && card.classList.contains('done')) {
          rDecoding = true;
          try {
            const { image } = await dec.decode({ frameIndex: want });
            c2.clearRect(0, 0, rholo.width, rholo.height);
            c2.drawImage(image, 0, 0, rholo.width, rholo.height);
            image.close();
            rFrame = want;
          } catch (e) { /* 한 장 놓쳐도 다음 장에서 따라잡는다 */ }
          rDecoding = false;
        }
        requestAnimationFrame(step);
      };
      // 첫 장은 미리 그려 둔다. 결과로 넘어간 순간 빈 자리가 없어야 한다.
      const { image } = await dec.decode({ frameIndex: 0 });
      c2.drawImage(image, 0, 0, rholo.width, rholo.height);
      image.close();
      rFrame = 0;
      requestAnimationFrame(step);
    } catch (e) { /* 못 하면 분석용 판으로 물러선다 */ }
  }

  // 결과를 보는 동안에도 아바타는 계속 돈다. 멈춰 있으면 방금까지 살아 있던
  // 화면이 갑자기 정지 사진이 된다.
  function resultLoop() {
    if (!card.classList.contains('done')) { resultRaf = 0; return; }
    drawShot();
    resultRaf = requestAnimationFrame(resultLoop);
  }

  // **한 가지만 보여 준다.** 여러 부위를 돌려 가며 띄우면 화면이 계속 바뀌고
  // TTS 도 그때마다 다시 말한다 — 언제 끝나는지 알 수 없는 소리가 된다.
  const FINDING = FINDINGS[0];

  function showFinding() {
    picked = 0;
    rregion.textContent = FINDING[0];
    rline.textContent = FINDING[1];
    drawShot();
  }

  function showResult() {
    card.classList.add('done');
    setStep(3);

    // 지금 한 번 그린다 — rAF 로만 그리면 화면 뒤에 있는 탭에서는 영영 안
    // 그려져서 자리가 빈 채로 남는다. 크기는 방금 display 를 바꿔서 아직
    // 예전 값일 수 있으므로, 이어지는 루프가 다음 프레임에 다시 잰다.
    showFinding();
    if (!resultRaf) resultRaf = requestAnimationFrame(resultLoop);
    playBtn.textContent = '처음부터 다시';
    // 딱 한 번만 말한다. 부위와 문장까지 같이 실어서 이 한 마디로 끝낸다.
    speak(`메이크업 분석이 끝났어요. ${FINDING[0]}. ${FINDING[1]}`);
  }

  let raf = 0, startedAt = 0, cues = new Set();

  function frame(now) {
    const elapsed = now - startedAt;
    const t = Math.min(1, elapsed / INTRO);
    const box = canvas.getBoundingClientRect();
    const revealed = draw(t, box.width, box.height);
    drawHud(t, box.width, box.height);

    // 자리는 fit() 에서 이미 맞춰 뒀다. 여기서는 나타나기만 한다 —
    // 움직이면 격자가 있던 자리에서 벗어나 이어져 보이지 않는다.
    const morph = seg(t, MORPH[0], MORPH[1]);
    holo.style.opacity = morph;
    holoc.style.opacity = morph;
    halo.style.opacity = morph;

    telemetry.style.opacity =
      Math.max(0, 1 - seg(t, TELEM[0], TELEM[1]) * 0.75);
    lamp.style.opacity = (t * 6) % 1 < 0.5 ? 0.9 : 0.18;
    tcount.textContent =
      `LANDMARKS  ${String(revealed).padStart(2, '0')}/${DATA.points.length}`;
    if (revealed > 0) {
      const [x, y] = DATA.points[revealed - 1];
      tcoord.textContent = `${x.toFixed(3)}   ${y.toFixed(3)}`;
    }

    const cue = (id, at, run) => { if (t >= at && !cues.has(id)) { cues.add(id); run(); } };
    // 훑기 시작 — 삐빅. 연출 맨 앞에 한 번은 반드시 울려야 한다.
    cue('sweep1', BEAM[0], () => play('sweep'));
    // 화면 글귀와 같은 문장을 읽는다. 앱은 분석을 시작하며 바로 말한다.
    cue('say1', 0.06, () => speak(STATUS_LINE));
    if (PHOTO_STAGE) {
      cue('sweep2', BEAM[0] + (BEAM[1] - BEAM[0]) / 2, () => play('sweep'));
      cue('locked', MESH[1], () => play('blip'));
    }
    cue('rise', MORPH[1], () => play('rise'));

    // 조준틀이 부위마다 물릴 때. 그림과 같은 순간이어야 한다.
    ZONES.forEach((_, i) => cue('zone' + i,
      ANALYSIS + (1 - ANALYSIS) * (ZONE_AT(i) + ZONE_LOCK),
      () => play('blip')));

    const prog = Math.min(1, elapsed / RUN);
    fill.style.width = (prog * 100) + '%';
    statusline.textContent = STATUS_LINE;

    if (elapsed < RUN) {
      raf = requestAnimationFrame(frame);
    } else {
      play('done');
      try { audio.hum.pause(); } catch (e) {}
      // 앱도 서버 응답이 오면 곧바로 결과 단계로 넘어간다. 여기서 멈춰 있으면
      // 연출이 어디로 이어지는지가 안 보인다.
      showResult();
    }
  }

  function start() {
    cancelAnimationFrame(raf);
    try { audio.hum.pause(); } catch (e) {}
    try { speechSynthesis.cancel(); } catch (e) {}
    audio.hum.volume = 0.5;
    cues = new Set();
    idle.style.display = 'none';
    // 결과에서 다시 누르면 분석 화면으로 되돌아온다.
    card.classList.remove('done');
    picked = null;
    setStep(2);
    playBtn.textContent = '다시 재생';
    fit();
    if (soundBox.checked) {
      try { audio.hum.currentTime = 0; audio.hum.play(); } catch (e) {}
    }
    startedAt = performance.now();
    raf = requestAnimationFrame(frame);
  }

  playBtn.addEventListener('click', start);
  soundBox.addEventListener('change', () => {
    if (!soundBox.checked) {
      try { audio.hum.pause(); } catch (e) {}
      try { speechSynthesis.cancel(); } catch (e) {}
    }
  });
  startDecoder();
  startResultDecoder();
  window.addEventListener('resize', () => { fit(); drawShot(); });
  photo.addEventListener('load', fit);
  fit();
})();
</script>
"""


# 아티팩트로 올릴 때는 <html>/<head>/<body> 를 붙이지 않는다 — 게시 쪽이
# 감싸 준다. 그런데 그대로 저장해서 브라우저로 열면 **charset 이 없어서 한글이
# 깨지고** 기본 스타일도 안 잡힌다. 파일로 건네줄 때는 이 껍데기를 씌운다.
STANDALONE = """<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  *, *::before, *::after { box-sizing: border-box; }
  html, body { margin: 0; padding: 0; }
  body { -webkit-text-size-adjust: 100%; }
</style>
__HEAD__
</head>
<body>
__BODY__
</body>
</html>
"""


def wrap(html):
    """<style>/<link>/<title> 은 head 로, 나머지는 body 로 나눈다.

    통째로 body 에 넣어도 브라우저가 알아서 올려 주긴 하지만, 그러면 첫
    페인트에서 스타일 없는 화면이 한 번 번쩍인다.
    """
    marker = "</style>"
    cut = html.rindex(marker) + len(marker)
    return (STANDALONE
            .replace("__HEAD__", html[:cut])
            .replace("__BODY__", html[cut:]))


def check_js(html):
    """구운 html 의 스크립트를 문법만이라도 확인한다.

    한 글자 틀리면 **스크립트가 통째로 안 돌고 화면은 멀쩡해 보인다** —
    버튼만 안 눌리므로 눈으로는 못 잡는다. 실제로 헬퍼 이름이 기존 변수와
    겹쳐서 통째로 파싱 실패한 걸 모르고 내보냈다.

    node 가 없으면 조용히 넘어간다. 있으면 공짜로 한 겹 막아 준다.
    """
    import re
    import shutil
    import subprocess
    import tempfile

    node = shutil.which("node")
    if not node:
        print("[artifact] node 가 없어 문법 검사를 건너뛴다")
        return

    blocks = re.findall(r"<script>(.*?)</script>", html, re.S)
    if not blocks:
        return
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "check.js")
        with open(path, "w", encoding="utf-8") as fp:
            fp.write(blocks[-1])
        done = subprocess.run([node, "--check", path],
                              capture_output=True, text=True)
    if done.returncode != 0:
        raise SystemExit(
            "[artifact] 스크립트 문법 오류 — 굽지 않았다\n"
            + (done.stderr or "").strip())
    print("[artifact] 스크립트 문법 확인")


def main():
    html = (HTML
            .replace("__OVERLAY__", json.dumps(overlay, separators=(",", ":")))
            .replace("__SFX__", json.dumps(sfx))
            .replace("__FIT__", json.dumps(fit))
            .replace("__TRACK__",
                     json.dumps(track, ensure_ascii=False,
                                separators=(",", ":")))
            .replace("__RTRACK__",
                     json.dumps(rtrack, ensure_ascii=False,
                                separators=(",", ":")))
            .replace("__RHOLO__", asset("face_hologram_result.webp"))
            .replace("__PHOTO__", asset("demo_face.jpg"))
            .replace("__HOLO__", asset("face_hologram.webp")))

    check_js(html)

    if args.standalone:
        html = wrap(html)

    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fp:
        fp.write(html)
    print(f"[artifact] {os.path.getsize(args.out) / 1024 / 1024:.1f} MB -> {args.out}")


main()
