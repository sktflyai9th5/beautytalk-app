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
    /* 하늘색 세 단계. 흰 바탕에서 읽히도록 명도만 내려 잡았다. */
    --mist: #FFD3DC;
    --line: #E4607A;
    --strong: #C93F5C;
    --label: #B08A92;
    --hair: #EFE2E5;
    --shadow: rgba(201, 63, 92, 0.14);
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
    background: linear-gradient(180deg, #FFFFFF, #FEFBFB 55%, #FBF5F5);
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
    background: radial-gradient(circle, rgba(255,211,220,0.30) 0%, rgba(255,211,220,0.10) 60%, transparent 100%);
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

  /* 결과 면. 분석 카드와 같은 자리에 겹쳐 두고 서로 바꿔 낀다. */
  .result { display: none; }
  .phone.done .card:not(.result) { display: none; }
  .phone.done .result { display: flex; flex-direction: column; }
  .rtitle { font-size: 24px; font-weight: 700; color: var(--ink); line-height: 1.3; }
  .rshot {
    margin-top: 14px; border-radius: 20px; overflow: hidden;
    height: 190px; background: var(--hair);
  }
  .rshot canvas { display: block; width: 100%; height: 100%; }
  .rcards { margin-top: 14px; display: flex; flex-direction: column; gap: 10px; }
  .rcard {
    text-align: left; border: 1px solid var(--border); border-radius: 16px;
    background: var(--surface); padding: 13px 15px; cursor: pointer;
    font: inherit; color: inherit;
  }
  .rcard.on { border-color: var(--strong); border-width: 2px; padding: 12px 14px; }
  .rcard b { display: block; font-size: 13.5px; color: var(--ink); }
  .rcard span { display: block; margin-top: 3px; font-size: 12px; color: var(--ink-body); line-height: 1.5; }
  .rcard i {
    display: inline-block; margin-top: 7px; font-style: normal; font-size: 11px;
    font-weight: 700; color: var(--strong);
    background: rgba(201, 63, 92, 0.10); border-radius: 999px; padding: 3px 9px;
  }
  .rnote { margin: 12px 0 0; font-size: 11px; line-height: 1.6; color: var(--label); }

  .statusline { font-size: 26px; font-weight: 700; color: var(--ink); line-height: 1.4; }
  .track {
    margin-top: 12px; height: 4px; border-radius: 2px;
    background: #F2E4E6; overflow: hidden;
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
    background: linear-gradient(180deg, #FFFFFF, #FBF5F5);
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
  .result h2 { margin: 0 0 12px; font-size: 26px; font-weight: 700; color: var(--ink); }
  .shot {
    position: relative; height: 190px; border-radius: 20px; overflow: hidden;
    flex: none; background: #EEE;
  }
  .shot canvas { position: absolute; inset: 0; width: 100%; height: 100%; }
  .cards { flex: 1; min-height: 0; overflow-y: auto; margin-top: 14px;
           display: flex; flex-direction: column; gap: 10px; padding-right: 2px; }
  .rcard {
    text-align: left; width: 100%; border-radius: 18px; padding: 14px 16px;
    background: var(--surface); border: 1px solid var(--border);
    cursor: pointer; font: inherit; color: inherit;
  }
  .rcard.on { border-color: var(--strong); border-width: 2px; padding: 13px 15px; }
  .rcard b { display: block; font-size: 15px; color: var(--ink); }
  .rcard span { display: block; margin-top: 4px; font-size: 12.5px;
                line-height: 1.5; color: var(--ink-body); }
  .rcard i {
    display: inline-block; margin-top: 8px; padding: 5px 10px; border-radius: 10px;
    background: rgba(201, 63, 92, 0.10); color: var(--strong);
    font-size: 11.5px; font-style: normal; font-weight: 700;
  }
  .sample { margin: 10px 0 0; font-size: 11px; color: var(--label); }

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
      <div class="result">
        <h2>메이크업 분석 완료!</h2>
        <div class="shot"><canvas id="shot"></canvas></div>
        <p class="sample">아래 문장은 화면 구성을 보여 주기 위한 <b>예시</b>입니다 —
          실제로는 서버가 분석한 결과가 들어갑니다. 카드를 누르면 그 자리만 진해집니다.</p>
        <div class="cards" id="cards"></div>
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

    <!-- 분석이 끝나면 여기로 넘어간다. 앱도 서버 응답이 오면 곧바로
         결과 단계로 바뀐다 — 사용자가 따로 누를 게 없다. -->
    <div class="card result" id="result">
      <div class="rtitle">메이크업 분석 완료!</div>
      <div class="rshot"><canvas id="rshot"></canvas></div>
      <div class="rcards" id="rcards"></div>
      <p class="rnote">문장은 <b>보여 주기 위한 예시</b>입니다 — 실제로는 서버가
        보낸 결과가 들어갑니다. 카드를 누르면 사진에서 그 자리만 짚어 줍니다.</p>
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
  const ZOOM = PHOTO_STAGE ? 1 : 1.5;
  const MIST = '255,211,220', LINE = '228,96,122', STRONG = '201,63,92';
  const LABEL = '176,138,146', GLINT = '255,141,161';

  // (짚는 지점, 라벨 지점, 이름). 전부 0~1 비율.
  // 위에서 아래 순서다 — 스캔선이 내려가는 방향과 같아야 훑으면서 하나씩
  // 잡는 것으로 읽힌다. 라벨은 좌우로 번갈아 두고 세로로 벌린다.
  const ZONES = [
    [[0.52, 0.285], [0.87, 0.13], '이마'],
    [[0.38, 0.345], [0.12, 0.25], '눈썹'],
    [[0.62, 0.395], [0.87, 0.36], '눈가'],
    [[0.355, 0.495], [0.12, 0.47], '볼'],
    [[0.50, 0.505], [0.87, 0.58], '코'],
    [[0.50, 0.585], [0.12, 0.69], '입술'],
    [[0.53, 0.655], [0.87, 0.80], '턱선'],
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
  const cards = document.getElementById('cards');
  const tcount = document.getElementById('tcount');
  const lamp = document.getElementById('lamp');
  const tcoord = document.getElementById('tcoord');
  const playBtn = document.getElementById('play');
  const soundBox = document.getElementById('sound');

  const photo = new Image();
  photo.src = "__PHOTO__";
  const HOLO_SRC = "__HOLO__";
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
  let decoding = false;

  async function startDecoder() {
    if (!('ImageDecoder' in window)) return;
    try {
      const buf = await (await fetch(HOLO_SRC)).arrayBuffer();
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

  function zoneAnchors() {
    // 그려진 프레임을 모르면 짚는 점을 움직이지 않는다.
    if (!TRACK || !PLACE || shownFrame < 0) return null;
    const row = TRACK.frames[shownFrame % TRACK.frames.length];
    if (!row) return null;
    return ZONES.map(([, , name]) => {
      const i = TRACK.names.indexOf(name);
      const uv = i < 0 ? null : row[i];
      return uv ? mapZone(uv[0], uv[1]) : null;
    });
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
          ctx.strokeStyle = `rgba(${STRONG},${0.55 * gr})`; ctx.lineWidth = 1.2;
        } else if (big) {
          ctx.strokeStyle = `rgba(${LINE},${0.28 * gr})`; ctx.lineWidth = 1;
        } else {
          ctx.strokeStyle = `rgba(${MIST},${0.85 * gr})`; ctx.lineWidth = 1;
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

        // 머리카락이나 어두운 옷 위에서도 보이도록 흰 받침을 먼저 깐다.
        // 선이 얇을수록 이 받침이 중요해진다.
        ctx.lineWidth = 1.0;
        ctx.strokeStyle = `rgba(${MIST},0.30)`;
        ctx.stroke(grid); ctx.stroke(contour);

        // 반투명하게 그으면 뒤 사진과 섞여 채도가 날아가 회색으로 보인다.
        // 얇게 유지하되 색은 거의 불투명하게 얹어야 하늘색으로 읽힌다.
        ctx.lineWidth = 0.7;
        ctx.strokeStyle = `rgba(${LINE},${0.88 + 0.12 * settle})`;
        ctx.stroke(grid);

        // 이목구비는 한 단계 진하게. 격자가 성근 만큼 이 선들이 형태를 짊어진다.
        ctx.lineWidth = 0.9; ctx.lineCap = 'round';
        ctx.strokeStyle = `rgba(${STRONG},${0.92 + 0.08 * settle})`;
        ctx.stroke(contour);

        ctx.lineWidth = 1.0;
        ctx.strokeStyle = `rgb(${STRONG})`;
        ctx.stroke(front);
        ctx.lineCap = 'butt';
      }

      // 잡힌 점은 피부 위 하이라이트로 찍는다. 테두리를 두르면 하이라이트가
      // 아니라 얼굴에 박힌 구슬처럼 보인다 — 번짐과 심지 두 겹이면 충분하다.
      ctx.save();
      ctx.shadowColor = `rgba(${GLINT},0.95)`;
      ctx.shadowBlur = 10;
      ctx.fillStyle = `rgb(${GLINT})`;
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
      ctx.strokeStyle = '#EFE2E5'; ctx.lineWidth = 1; ctx.stroke();
      ctx.restore();
    }

    const br = seg(t, 0, 0.18);
    if (br > 0) {
      const len = 22 * br, i2 = 10;
      ctx.strokeStyle = `rgba(${LINE},${0.6 * br})`;
      ctx.lineWidth = 1.0; ctx.lineCap = 'round'; ctx.lineJoin = 'round';
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

    ZONES.forEach(([an, ln, name], i) => {
      const at = ZONE_AT(i);
      const on = Math.min(1, Math.max(0, (amount - at) / 0.13));
      if (on <= 0) return;

      // 잰 값이 없을 때만 고정 좌표를 배율만큼 민다. 라벨까지 밀면 화면 밖이다.
      const ox = BOUNDS.l + BOUNDS.w / 2, oy = BOUNDS.t + BOUNDS.h / 2;
      const hit = tracked && tracked[i];
      const ax = hit ? hit[0] : (ox + (an[0] - ox) * ZOOM) * w;
      const ay = hit ? hit[1] : (oy + (an[1] - oy) * ZOOM) * h;
      const lx = ln[0] * w, ly = ln[1] * h;
      // 짚는 점만 움직이므로 어느 쪽으로 끌지도 매 프레임 다시 본다.
      const toRight = lx > ax;

      hctx.strokeStyle = `rgba(${LINE},${0.75 * on})`;
      hctx.lineWidth = 0.7;
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
      hctx.strokeStyle = `rgba(${STRONG},${0.85 * on})`;
      hctx.lineWidth = 1.0; hctx.lineCap = 'round';
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
        hctx.fillStyle = `rgba(255,255,255,${0.9 * on})`;
        hctx.beginPath(); hctx.arc(ax, ay, 2.6, 0, Math.PI * 2); hctx.fill();
        hctx.strokeStyle = `rgba(${STRONG},${0.9 * on})`;
        hctx.lineWidth = 0.9;
        hctx.beginPath(); hctx.arc(ax, ay, 2.6, 0, Math.PI * 2); hctx.stroke();
      }

      if (on < 0.6) return;
      const fade = Math.min(1, (on - 0.6) / 0.4);
      // 다음 부위로 넘어가면 앞 부위는 확인된 것으로 바꾼다.
      const state = amount > at + 0.125 ? '확인' : '검사 중';

      hctx.textAlign = toRight ? 'left' : 'right';
      const tx = toRight ? lx + 6 : lx - 6;
      hctx.font = '700 11.5px "Noto Sans KR", sans-serif';
      hctx.fillStyle = `rgba(${STRONG},${fade})`;
      hctx.fillText(name, tx, ly - 6);
      hctx.font = '9px "Noto Sans KR", sans-serif';
      hctx.fillStyle = `rgba(${LABEL},${fade})`;
      hctx.fillText(state, tx, ly + 7);
    });
    hctx.textAlign = 'left';
  }

  // ---- 결과 화면 ----------------------------------------------------------
  //
  // 부위 이름 → 사진에서의 자리. 손으로 어림한 값이 아니라 앱과 **같은 표**다
  // (`ProblemSpot._zoneTable`, demo_face_points.json 의 실제 랜드마크에서 뽑았다).
  // 눈대중으로 넣었더니 입술이 턱 아래, 볼이 목에 찍혔다.
  const ZONE_BOX = {
    '이마': [0.266, 0.223, 0.745, 0.345],
    '왼쪽 눈썹': [0.535, 0.284, 0.730, 0.359],
    '오른쪽 눈썹': [0.270, 0.302, 0.471, 0.376],
    '왼쪽 볼': [0.634, 0.385, 0.764, 0.547],
    '오른쪽 볼': [0.239, 0.410, 0.392, 0.526],
    '코': [0.437, 0.354, 0.594, 0.532],
    '입술': [0.415, 0.528, 0.621, 0.615],
    '턱선': [0.332, 0.586, 0.672, 0.687],
  };

  // 화면 구성을 보여 주기 위한 **예시** 문장이다. 실제 앱에서는 서버가 준
  // region/state/action 이 그대로 들어간다 — 여기서 지어낸 수치는 없다.
  const FINDINGS = [
    ['왼쪽 볼', '베이스가 고르지 않게 발려 있어요.', '퍼프로 가볍게 두드려 정리해 주세요.'],
    ['입술', '입술 경계가 조금 번져 있어요.', '면봉으로 바깥선을 정리해 주세요.'],
    ['이마', '피지로 살짝 무너졌어요.', '기름종이로 누른 뒤 파우더를 얹어 주세요.'],
  ];

  let picked = null;

  function drawShot() {
    const box = shot.getBoundingClientRect();
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    shot.width = Math.round(box.width * dpr);
    shot.height = Math.round(box.height * dpr);
    const cx = shot.getContext('2d');
    cx.setTransform(dpr, 0, 0, dpr, 0, 0);
    const w = box.width, h = box.height;
    if (!w || !h) return;

    // object-fit: cover 와 같은 셈.
    const iw = photo.naturalWidth || 3, ih = photo.naturalHeight || 4;
    const sc = Math.max(w / iw, h / ih);
    const dx = (w - iw * sc) / 2, dy = (h - ih * sc) / 2;
    cx.clearRect(0, 0, w, h);
    if (photo.complete) cx.drawImage(photo, dx, dy, iw * sc, ih * sc);
    const map = (nx, ny) => [nx * iw * sc + dx, ny * ih * sc + dy];

    // **네모로 칠하지 않는다.** 테두리를 두른 구역은 "여기를 정확히 쟀다" 는
    // 말이 되고, 무엇보다 어디가 문제인지가 아니라 네모가 먼저 보인다.
    // 가운데가 진하고 밖으로 스미는 얼룩이라야 "이 언저리" 로 읽히고,
    // 화장품 앱에도 맞는 언어다. 번호도 안 붙인다 — 자리에 색이 번져 있으면
    // 카드의 이름만으로 바로 이어진다.
    const INK = 0.46;
    FINDINGS.forEach(([region], i) => {
      const b = ZONE_BOX[region];
      if (!b) return;
      const [x0, y0] = map(b[0], b[1]), [x1, y1] = map(b[2], b[3]);
      const rw = (x1 - x0) / 2, rh = (y1 - y0) / 2;
      const mx = x0 + rw, my = y0 + rh;

      // 고른 게 있으면 그것만 한 단계 올리고 나머지는 확실히 내린다. 둘의
      // 차이가 작으면 눌러도 아무것도 안 짚힌 것처럼 보인다. 그래도 아주
      // 지우지는 않는다 — 흔적이 없으면 "다른 데도 있었나" 를 알 수 없다.
      const ink = picked === null ? INK
                : (picked === i ? INK * 1.5 : INK * 0.28);

      cx.save();
      cx.translate(mx, my);
      cx.scale(1, rh / rw);
      const g = cx.createRadialGradient(0, 0, 0, 0, 0, rw);
      g.addColorStop(0, `rgba(255,122,146,${ink})`);
      g.addColorStop(0.55, `rgba(255,141,161,${ink * 0.72})`);
      g.addColorStop(1, 'rgba(255,141,161,0)');
      cx.fillStyle = g;
      cx.beginPath();
      cx.arc(0, 0, rw, 0, Math.PI * 2);
      cx.fill();
      cx.restore();
    });
  }

  function buildCards() {
    cards.innerHTML = '';
    FINDINGS.forEach(([region, state, action], i) => {
      const el = document.createElement('button');
      el.className = 'rcard';
      el.innerHTML = `<b>${region}</b><span>${state}</span><i>${action}</i>`;
      el.addEventListener('click', () => {
        picked = picked === i ? null : i;
        [...cards.children].forEach((c, j) =>
          c.classList.toggle('on', picked === j));
        drawShot();
        // 앱은 여기서 TTS 로 한 번 더 알려 준다. 화면을 못 보면 짚어 준 게
        // 안 보이기 때문이다.
        speak(picked === null ? '전체를 다시 보여 드릴게요.'
                              : `${region}. ${state}`);
      });
      cards.append(el);
    });
  }

  function showResult() {
    card.classList.add('done');
    setStep(3);
    buildCards();
    // 두 번 그린다. 지금 한 번 — rAF 로만 그리면 화면 뒤에 있는 탭에서는
    // 영영 안 그려져서 사진 자리가 빈 채로 남는다. 그리고 다음 프레임에 한
    // 번 더 — 방금 display 를 바꿔서 지금 잰 크기는 아직 예전 값이다.
    drawShot();
    requestAnimationFrame(drawShot);
    playBtn.textContent = '처음부터 다시';
    speak('메이크업 분석이 끝났어요.');
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
    // 기다리는 동안 한 번 더. 서버가 오래 걸릴 때 말이 끊기면 멈춘 줄 안다.
    if (prog >= 0.62 && !cues.has('say2')) {
      cues.add('say2');
      speak('피부를 꼼꼼히 보는 중이에요.');
    }
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


def main():
    html = (HTML
            .replace("__OVERLAY__", json.dumps(overlay, separators=(",", ":")))
            .replace("__SFX__", json.dumps(sfx))
            .replace("__FIT__", json.dumps(fit))
            .replace("__TRACK__",
                     json.dumps(track, ensure_ascii=False,
                                separators=(",", ":")))
            .replace("__PHOTO__", asset("demo_face.jpg"))
            .replace("__HOLO__", asset("face_hologram.webp")))

    if args.standalone:
        html = wrap(html)

    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fp:
        fp.write(html)
    print(f"[artifact] {os.path.getsize(args.out) / 1024 / 1024:.1f} MB -> {args.out}")


main()
