# 디자인 교체 계약서

> UI를 전면 교체할 때 **바꿔도 되는 것**과 **바꾸면 앱이 깨지는 것**을 가른 문서.
> 기준은 하나다 — **사용자는 화면을 보지 못한다.** 그래서 "보이는 것"이 아니라
> "들리는 것·손으로 되는 것"이 기능이다.

읽는 순서: [1분 요약](#1분-요약) → [절대 규칙 6가지](#절대-규칙-6가지) →
담당 화면 → [교체 후 점검표](#교체-후-점검표)

---

## 1분 요약

| | 마음껏 바꿔도 되는 것 | 절대 못 바꾸는 것 |
| --- | --- | --- |
| **색·모양** | 색상, 그라데이션, 모서리 반경, 그림자, 여백, 폰트, 아이콘 모양, 카드 배치, 애니메이션 곡선·길이 | — |
| **글자** | 화면에만 보이는 라벨 문구 | **TTS로 읽히는 문구**, `Semantics(label:)` |
| **구조** | 위젯 트리 재구성, 새 컴포넌트 도입 | 위젯이 읽는 **상태**와 부르는 **동작**의 연결 |
| **동작** | — | 제스처, 타이머 주기, 화면 전환 시 부수효과 |
| **배치·크기** | 자유롭게 재구성 | 카드 크기·위치는 **제스처 영역을 바꾼다**. 터치 타깃은 줄이면 안 됨 |
| **통신** | — | **API 명세 전부** (엔드포인트·필드·타입) |

한 줄로: **`lib/theme/`와 각 위젯의 `decoration`/`TextStyle`은 자유. `lib/app_state.dart`,
`lib/services/`, `server/`는 손대지 말 것.**

---

## 절대 규칙 6가지

### 1. TTS로 나가는 문자열은 기능이다

화면 문구는 바꿔도 되지만, **읽어 주는 문구는 UI가 아니라 사용자 인터페이스 그 자체**다.
전부 `lib/app_state.dart`와 `lib/main.dart`에 있다. 디자인 작업에서는 건드릴 일이 없다.

```
main.dart           뷰티톡. 화면을 터치하면 바로 시작합니다.
app_state.dart       카메라 렌즈에 이물질이 있어요. 렌즈를 닦고 시작해 주세요.   (탭 진입 검사)
app_state.dart       카메라 렌즈에 이물질이 있어요. 렌즈를 닦고 다시 촬영해 주세요. (셔터 검사 — 촬영을 접는다)
 화장품을 카메라 앞에 들어 주세요. …
app_state.dart       화장품을 분석 중이에요. 조금만 기다려 주세요.
app_state.dart:291   제품을 찾았어요. {제품 설명}
app_state.dart:300   메이크업 분석, 탭, 선택됨. 준비되면 촬영하기 버튼을 눌러 주세요.
app_state.dart:303   메이크업 분석, 탭, 선택됨. 얼굴을 화면 가운데에 맞춰 주세요. …
app_state.dart:310   궁금한 걸 질문해 보세요. 음성으로 질문하기 버튼을 누른 뒤 …
app_state.dart:314   메이크업을 살펴보고 있어요. 얼굴을 그대로 두시면 곧 알려드릴게요.
app_state.dart:358   사진을 확인하지 못했어요. 다시 촬영하기 버튼을 눌러 주세요.
app_state.dart:373   제품을 찾았어요. {제품 설명} 저장하기 또는 다시 촬영하기 …
app_state.dart:381   촬영했습니다.                       (셔터 피드백)
app_state.dart:413   후면 카메라예요. / 전면 카메라예요.
app_state.dart:421   다시 촬영할게요. 화장품을 비춰 주세요.
app_state.dart:472   궁금한 걸 질문해 보세요. …            (촬영 직후 질문 단계 안내)
app_state.dart:489   다시 촬영할게요. 얼굴을 화면 가운데에 맞춰 주세요.
app_state.dart:562   좋아요. 이제 두 번 두드리면 찍어요.
app_state.dart:600   {프레이밍 안내} 준비되면 다시 두 번 두드려 주세요.
app_state.dart:612   앱을 종료할게요.
app_state.dart:637   {인식된 문장}, 라고 들었어요. 메이크업을 살펴보고 있어요.
app_state.dart       {부위}을 분석 중이에요. / 꼼꼼히 보는 중이에요. 조금만요. / 거의 다 됐어요.   (30·60·90%)
app_state.dart       화면 사용법이에요. 한 번 두드리면 음성 인식, … (첫 탭 진입 시 1회)
app_state.dart       설정, 탭, 선택됨. 개발자용 화면이에요. …
app_state.dart       서버에 연결하지 못했어요. 잠시 뒤에 다시 시도해 주세요.  (정직한 실패 — 지어낸 답 금지)
app_state.dart       말씀하세요.                         (질문 화면 마이크 — 듣기 직전)
voice_service.dart   못 들었어요. 다시 눌러서 말씀해 주세요. (빈손으로 끝난 듣기)
app_state.dart:838   화장품 인식, 메이크업 분석, 설정 중에 말해 주세요.
```

#### `speak` 와 `announce` 는 다르다

말은 **겹치지 않는다.** `VoiceService` 가 대기열을 들고 있어서 앞 문장이 끝나야
다음 문장이 나간다. 겹쳐 나오면 앞이 보이지 않는 사용자에게는 둘 다 못 알아듣는
소리가 된다.

| 호출 | 뜻 | 쓰는 곳 |
| --- | --- | --- |
| `voice.speak(text)` | 앞의 말이 끝난 뒤 **이어서** 말한다 | 같은 화면 안의 보조 안내 (셔터음, 진행률, 프레이밍) |
| `voice.stopSpeaking()` | 전부 버리고 침묵 | "조용히", 듣기 시작, 안내 없는 탭으로 이동 |

`goTab()` 은 탭이 바뀌면 먼저 `stopSpeaking()` 을 부른다 — 설정 탭처럼 새 안내가
없는 곳으로 갈 때도 지나간 화면의 말을 끊어야 하기 때문이다.
새 안내 문구를 넣을 때 **화면이 바뀌는 순간이면 `announce`**, 아니면 `speak` 다.
반대로 쓰면 앞 화면 설명이 새 화면까지 따라오거나, 같은 화면 안내가 서로 끊는다.

### 2. `Semantics`는 디자인이 아니라 기능이다

스크린리더가 읽는 값이다. 위젯을 새로 만들 때 **반드시 같이 옮겨야 한다.**
디자인 교체에서 가장 자주 유실되는 부분이다.

| 위치 | 유지해야 할 것 |
| --- | --- |
| `intro_screen.dart` | `button: true`, `label: '뷰티톡을 시작합니다. 화면을 두드리면 바로 시작합니다.'` |
| `entry_screen.dart` | 제목+부제를 한 덩어리로 — `header: true`, `label: 'BeautyTalk, 메이크업 AI 어시스턴트. …'` |
| `main_shell.dart` `_ListeningBanner` | `liveRegion: true` — 듣는 중 상태 |
| `main_shell.dart` `_FramingHint` | `liveRegion: true` |
| `main_shell.dart` `_LensChecking` | `liveRegion: true`, `label: '카메라 렌즈 확인 중'` |
| `coral.dart` `ScreenHeader` | 뒤로 가기 `button: true` + 제목 `header: true` |
| `coral.dart` `StepIndicator` | `label: '전체 N단계 중 M단계, 이름'` — 한 덩어리로 |
| `coral.dart` `CoralButton` / `CircleIconButton` / `ShutterButton` | `button: true` + 이름 |
| `cosmetic_tab.dart` 결과 카드 | `label:` 에 제품 이름 + 설명 + 사용법 전문 |
| `makeup_tab.dart` `_MicButton` | `button: true`, 듣는 중/대기 라벨 분기 |
| `makeup_tab.dart` `_HeardText` | `liveRegion: true` — 인식된 문장을 그대로 |
| `makeup_tab.dart` `_SuggestionChip` | `button: true`, `label: '$질문, 추천 질문'` |
| `makeup_tab.dart` `_ResultCard` | `label: 'N번, 부위. 상태 행동'` |
| `settings_tab.dart` 음성 칩 | `button: true`, `selected:` |
| `bottom_tab_bar.dart` | `button: true`, `selected:`, `label: '$label, 탭'` |

**`liveRegion: true`가 특히 중요하다.** 상태가 바뀔 때 스크린리더가 자동으로 읽어 주게 하는
플래그다. 빠뜨리면 사용자는 상태 변화를 전혀 알 수 없다.

### 3. 제스처는 화면 전체에 걸려 있다

`GestureLayer`가 **전체 화면을 감싸고 있다** (`main_shell.dart:27`).

| 제스처 | 동작 | 범위 |
| --- | --- | --- |
| 한 번 두드리기 | 음성 인식 시작 | 모든 화면 |
| 두 번 연속 두드리기 | 촬영 (화장품·가이드) | 탭별 |
| 1.5초 길게 누르기 | 앱 종료 | 모든 화면 |

**새 위젯을 올릴 때 지켜야 할 것:**

- 화면을 덮는 오버레이는 **반드시 `IgnorePointer`로 감싼다.**
  전부 그렇게 되어 있다.

  무엇이 막히는지 정확히 알아 두자. `GestureLayer`는 오버레이의 **조상**이고
  `HitTestBehavior.translucent` 라서, 화면 전체 두드리기는 `IgnorePointer` 없이도
  계속 동작한다. 실제로 죽는 건 **오버레이 아래에 깔린 진짜 버튼**이다 —
  하단 탭바(`main_shell.dart:108`), 촬영 버튼(`makeup_tab.dart:122`),
  마이크 알약(`makeup_tab.dart:127`).
- 버튼류(`InkWell`/`GestureDetector`)는 `GestureLayer`보다 안쪽에 있어야 한다.
  Flutter는 안쪽 제스처가 이기므로 지금 구조를 유지하면 자동으로 해결된다.
- **드래그가 필요한 위젯**(슬라이더·스크롤)을 새로 넣으면 `gesture_layer.dart:35`의
  `_dragSlop = 12.0`이 보호해 준다. 12px 넘게 움직이면 종료 타이머가 풀린다.
  이 값을 낮추면 슬라이더를 천천히 끌 때 앱이 꺼진다.

#### 레이아웃이 곧 제스처 지도다 ← 개편에서 제일 위험한 지점

**자식 위젯의 `onTap`은 그 영역의 "두 번 두드리기"를 잡아먹는다.**
카드를 키우거나 옮기면 **두 번 두드려 촬영되는 영역이 같이 바뀐다.**
시각적으로만 바꿨다고 생각한 변경이 제스처 동작을 바꾼다.

| 위치 | 지금 상태 |
| --- | --- |
| 하단 탭바 | `HitTestBehavior.opaque` — **여기서는 화면 제스처가 안 먹는다** (의도된 것) |
| 가이드라인 카드 (`cosmetic_tab.dart:57`) | 카드 전체가 촬영 버튼이다. 장식 카드가 아니다 |
| 결과 카드 (`cosmetic_tab.dart:119`) | 카드 전체가 "처음으로" 버튼이다 |
| 마이크 알약 (`makeup_tab.dart:306`) | `onTap`/`onLongPress` 둘 다 있다 |

- **한 번 두드리기는 약 300ms 늦게 반응한다.** `onDoubleTap`이 있어 두 번째 탭을
  기다리기 때문이다. 이 지연은 사용자 안내와 짝이라 없앨 수 없다.
- **1.5초 길게 누르기는 `Listener`(원시 포인터)로 되어 있어 제스처 아레나 밖이다.**
  그래서 어떤 위젯 위에서든 동작한다. 새 버튼을 올려도 그 위에서 길게 누르면 종료된다.
  `_MicPill`의 `onLongPress`와 겹치는 것도 이 때문이다 — 둘 다 발동한다.
- **인트로·진입 화면은 `GestureLayer` 밖에 있다.** 제스처 규칙이 다르다.
  화면 전체 `opaque` 탭 하나가 전부이고, 두드리기·길게 누르기가 없다.

### 4. UI 안의 타이머는 전부 기능이다

애니메이션 길이가 아니다. **사용자에게 정보를 전달하는 주기**다.

| 위치 | 주기 | 무엇을 하나 |
| --- | --- | --- |
| `gesture_layer.dart:61` | 1500ms | 길게 누르기 → 앱 종료 |
| `makeup_tab.dart:182` | 12초 | 서버 대기 중 "아직 보고 있어요" + 진동 |
| `makeup_tab.dart:173` | 1초 | 경과 시간 갱신 |
| `makeup_tab.dart:46` | 8초 | 대화 카드 자동 숨김 |
| `app_state.dart` `framingPollInterval` | 3초 | 실시간 프레이밍 확인 |
| `app_state.dart` `_minAnalyzing` | 1200ms | 화장품 로딩 화면 최소 표시 |
| `app_state.dart` `_startWarmUpTimer` | 30초 검사 / 5분 주기 | GPU 깨우기 |

**12초 음성 알림을 빼면 안 된다.** 서버 추론이 15~44초 걸리는데, 그동안 아무 소리도 없으면
사용자는 앱이 멈춘 줄 안다.

#### 위젯 수명이 곧 타이머 수명이다

타이머가 `initState`/`dispose`에 묶여 있어서, **위젯이 다시 만들어지면 타이머도 리셋된다.**

- `AnimatedSwitcher > KeyedSubtree(key: ValueKey(state.tab))` (`main_shell.dart:97-98`)
  — 애니메이션용 키처럼 보이지만 **`GuideTab`의 `State` 수명을 정한다.**
  키를 매 빌드마다 바뀌게 만들면(예: `UniqueKey()`) 12초 알림 타이머가 영원히 리셋되어
  **한 번도 울리지 않는다.**
- `_InferenceView`는 `s.asking`일 때만 마운트된다 (`makeup_tab.dart:88`).
  12초 타이머의 수명이 곧 이 위젯의 수명이다.
- `_Scanning` 의 회전 컨트롤러는 무한 `repeat()` 이다. 트리에 상시 두면 계속 돈다 —
  지금은 로딩 중에만 마운트된다.
- `_MicButtonState._sync` (`makeup_tab.dart`)는 애니메이션 정리처럼 보이지만
  **듣는 중일 때만 돌리는 전력 가드**다. 항상 `repeat()`으로 되돌리면
  대기 중에도 매 프레임 다시 그린다.

### 5. 여백·크기가 기능인 곳이 있다

전부 여백처럼 보이지만 이유가 있다.

| 위치 | 값 | 왜 |
| --- | --- | --- |
| `bottom_tab_bar.dart` | `SafeArea(top: false)` | 여백이 아니라 **OS 제스처 영역(홈 인디케이터) 회피**. 없애면 탭바가 시스템 스와이프와 겹친다 |
| `intro_screen.dart` | 아래쪽만 `MediaQuery.paddingOf().bottom` 보정 | 히어로 이미지는 위로 흘려 보내고, 버튼·힌트만 내비바를 피한다 |
| `bottom_tab_bar.dart` | 아이콘 슬롯 80×46 · 탭 `Expanded` | 터치 타깃 크기다. 앞이 안 보이는 사용자는 **손가락으로 더듬어 찾는다** |
| `coral.dart` `ShutterButton` | 링 100px · 채움 88px | 「접근성 명세」의 "셔터와 음성 버튼은 88px 이상" |
| `makeup_tab.dart` `_MicButton` | 118px | 같은 규정. 작게 만들면 못 찾는다 |
| `coral.dart` `ScreenHeader` 뒤로 가기 | 글리프 26px, 터치 44px | 「최소 44px」 규정. 글자만 키우지 말고 터치 영역을 지킨다 |
| `main.dart` | `portraitUp` 고정 | `CameraView` 의 cover 스케일 계산이 세로 전제다. 회전을 허용하면 프리뷰가 찌그러진다 |

> 크기를 줄이는 건 **접근성 후퇴**다. 키우는 건 자유.

### 6. API 명세는 한 글자도 안 바뀐다

디자인 작업에서 서버를 건드릴 일은 없다. 참고용으로만 둔다 → [API 명세](#api-명세-변경-금지)

---

## 화면별 계약

화면 구성은 피그마 「Codex Draft · Coral Soft · 원본 보존」(node 368:2)을 따른다.
색·크기·글꼴 토큰은 `lib/theme/app_theme.dart` 한 곳에 있고, 공통 부품은
`lib/widgets/coral.dart` 에 있다. **화면 코드에 hex 를 새로 적지 않는다.**

### 인트로 (`intro_screen.dart`)

피그마 「인트로 접근성 규칙」(424:12)이 이 화면의 명세 전부다.

| 유지 | 자유 |
| --- | --- |
| `IntroScreen({onDone, onSpeak, abbreviated})` 시그니처 | 히어로 이미지·등장 곡선 |
| **0.2초에 `onSpeak`** — 애니메이션(2.6초)보다 먼저 끝나야 한다 | 글자 등장 순서 |
| 화면 전체 탭 → 즉시 `onDone`. **최소 노출 시간을 두지 않는다** | |
| 건너뛰어도 음성은 끊지 않는다 (`onSpeak` 취소 금지) | |
| `disableAnimations` 면 애니메이션 생략하고 바로 `onDone` | |
| `Semantics(button: true, label: '뷰티톡을 시작합니다. …')` | |

> `AppState` 가 만들어지기 전에도 돌아야 해서 `main.dart` 가 직접 들고 있다.
> 여기서 `AppState` 를 요구하면 "최소 노출 시간 없음" 규칙을 지킬 수 없다.

### 진입 화면 (`entry_screen.dart`)

버튼도 작은 글씨도 두지 않는다. 앞이 보이지 않는 사용자에게 버튼 두 개는
"어느 쪽을 눌렀는지 모르는" 갈림길이라, 이 화면에서 할 수 있는 일을 하나로 줄였다.

| 유지 | 자유 |
| --- | --- |
| 낭독 순서: 제목 → 안내 문구 (둘뿐이다) | 배치·여백·블롭 위치 |
| 화면 아무 곳이나 탭 → `state.start(to: AppTab.cosmetic)` | 글자 크기 |
| `EntryScreen.hint` 한 문장을 **화면·인트로·음성이 공유한다** | |

> 문구를 바꾸려면 `EntryScreen.hint` 만 고친다. 화면·인트로 애니메이션·
> 시작 안내 음성이 전부 이걸 참조하므로 한 곳만 고치면 세 곳이 같이 바뀐다.
> 따로 적어 두면 "보이는 말"과 "들리는 말"이 갈라진다.

### 메인 셸 (`main_shell.dart`)

**반드시 유지할 구조:**

```
GestureLayer(state)              ← 최상위. 이 밖으로 나가면 제스처가 죽는다
  └ CoralBackdrop(blobs: false)
     └ Stack
        ├ SafeArea > Column
        │   ├ Expanded(탭 콘텐츠)    ← state.tab 으로 분기
        │   └ BottomTabBar          ← onTap: state.goTab
        ├ 렌즈 확인 중 표시           ← state.lensChecking, liveRegion
        ├ 프레이밍 안내               ← state.framingHint.isNotEmpty, IgnorePointer
        └ 듣는 중 알약                ← voice.isListening, liveRegion
```

**촬영 단계에서는 카메라가 화면 전체를 채운다.** 미리보기가 클수록 대신 봐 주는
사람이 화면을 맞추기 쉽고, 저시력 사용자도 무엇이 잡히는지 알아볼 수 있다.
`_showCamera` 가 그 조건이고, 아닐 때는 코랄 배경으로 바뀐다.

**카메라 위에는 글자를 얹지 않는다.** 촬영 화면에는 화면 이름도 안내 문구도 두지
않고 TTS 로만 말한다 — 어차피 앞이 보이지 않는 사용자에게는 읽히지 않고,
저시력 사용자에게는 카메라를 가리기만 한다. 남는 건 단계 표시기와 셔터뿐이다.

**`_Scrim` 과 `CaptureGuides._band` 는 짝이다.** 스크림이 위아래를 밝게 깔아
단계 표시기와 셔터를 받치고, 안내선은 그 사이 비어 있는 구간에만 뜬다.
한쪽 stops 를 바꾸면 다른 쪽 `_band`/`_center` 도 같이 맞춰야 겹치지 않는다.

**카메라 프리뷰 채우기**: `Transform.scale` + `AspectRatio` 로 면을 꽉 채운다.
세로 모드에서 프리뷰가 회전되어 오므로 종횡비 역수 처리가 들어 있다.
프리뷰 위젯을 새로 만들 때 이 계산을 빠뜨리면 화면이 찌그러진다.

**듣는 중 알약은 화면 위쪽에 두지 않는다.** 위는 화면 제목 자리다.
말하는 중에는 띄우지 않는다 — 소리가 곧 상태다.

### 화장품 인식 탭 (`cosmetic_tab.dart`)

3단계: `capture` → `analyzing` → `result` (단계 표시기 3칸)

| 유지 | 자유 |
| --- | --- |
| `state.cosmeticStage` 로 분기 | 카드·면 디자인 전부 |
| 촬영 화면에 **글자를 두지 않는다** — 안내는 TTS (`_announceCurrent`) | 안내선 모양 |
| 셔터 → `state.captureAndAnalyze` | 셔터 모양 (단, 88px 이상) |
| "다시 들려주기" → `state.speakProduct` | 버튼 배치 |
| "다시 촬영하기" → `state.retakeCosmetic` | |
| `state.prediction` 의 `name`/`description`/`usage` 표시 | 글자 배치 |
| 결과 카드 `Semantics(label:)` 에 제품 설명 전문 | 스피너 모양 |
| **셔터는 화면 정중앙**, 글자 없이 아이콘만 — 손으로 더듬어 찾는 유일한 기준점이다 | 링·아이콘 표현 |

> 피그마의 "저장하기" 자리에는 **"다시 들려주기"** 를 둔다. 저장 기능이 없는데
> 버튼만 만들면 앞이 보이지 않는 사용자에게는 없는 기능을 있다고 말하는 셈이다.

### 메이크업 분석 탭 (`makeup_tab.dart`)

4단계: `capture` → `question` → `analyzing` → `result` (단계 표시기 4칸)

| 유지 | 자유 |
| --- | --- |
| `state.makeupStage` 로 분기 | 카드·칩 디자인 전부 |
| 질문 화면은 **음성 버튼 하나가 면 전체**다 → `state.askByVoice`. 제목·설명 글자는 두지 않는다 | 블롭 배경·링·펄스 표현 |
| 추천 질문 3개 → `state.ask(문구)` — 문구는 피그마 그대로 | 칩 모양 |
| 인식 중 문장 표시 (`voice.partialText` → `state.lastHeard`), `liveRegion` | |
| 진행률 바 ← `state.analysisProgress`. 글귀·낭독은 **퍼센트가 아니라 `state.analysisLine`** ("입술을 분석 중이에요.") | 바 스타일 |
| "취소하고 다시 촬영하기" 는 **항상 마지막에 읽는다** | |
| 결과 카드: `state.analysisItems` 의 `region`/`state`/`action` | 카드 디자인 |
| `analysisItems` 가 비면 `state.lastSpokenResult` 문장을 보여 준다 | |
| "다시 들려주기" → `state.repeatResult` / "다시 촬영하기" → `state.retakeMakeup` | |

> 결과 항목이 없는 경우가 정상이다 — 립 경로(서버 라우터)는 문장만 돌려준다.
> 그때 빈 화면을 보이면 안 되므로 읽어 준 문장을 그대로 카드에 담는다.

### 설정 탭 (`settings_tab.dart`)

**개발자용이라 진입 시 안내 음성이 없다.** 이건 의도된 동작이다.
피그마에 설정 화면은 없다 — 코랄 소프트 부품만 그대로 쓴다.

| 유지 | 자유 |
| --- | --- |
| 음성 칩 누름 → `v.previewVoice(name)` (바꾸고 샘플 낭독) | 칩 디자인 |
| 슬라이더는 **손 뗄 때** 적용 (`onChangeEnd`) | 슬라이더 스타일 |
| `v.offlineKoreanVoiceNames` 만 나열 | 목록 배치 |
| 선택 표시 = `v.voiceName == name` | 선택 표현 방식 |
| `AnimatedBuilder(animation: VoiceService.instance)` 구독 | |
| 제스처 안내 문구가 `gesture_layer.dart` 의 실제 동작과 일치할 것 | |

> 슬라이더를 `onChanged` 에서 바로 적용하면 드래그 중 매 프레임 TTS 설정이 바뀌고
> 파일 저장이 폭주한다.

### 하단 탭바 (`bottom_tab_bar.dart`)

| 유지 | 자유 |
| --- | --- |
| 탭 3개: 화장품 인식 / 메이크업 분석 / 설정 | 아이콘 그림 |
| 선택 상태를 **색 말고도** 알린다 (알약 배경 + `selected: true`) | 알약 모양 |
| `Semantics(button: true, selected:, label: '$label, 탭')` | 크기·간격 |
| 터치 영역 최소 44px | |

## 위젯 ↔ 상태 연결 (유실 주의)

디자인을 갈아엎을 때 **가장 자주 끊어지는 부분**이다. 새 위젯에서 아래를 전부 다시 이어야 한다.

**읽는 상태**

```
state.phase            entry / main            (인트로는 main.dart 가 따로 관리)
state.tab              cosmetic / makeup / settings
state.cosmeticStage    capture / analyzing / result           (3단계 표시기)
state.makeupStage      capture / question / analyzing / result (4단계 표시기)
state.prediction       인식 결과 (name, description, usage)
state.analysisItems    부위별 결과 [{region, state, action, type}]  ← 결과 카드
state.lastSpokenResult 마지막으로 읽어 준 문장 (items 가 비면 이걸 보여 준다)
state.analysisProgress 0.0~1.0 서버 분석 진행률
state.lastHeard        마지막으로 인식된 발화 (질문 화면에 그대로 표시)
state.lastShotPath     마지막 촬영 파일 (제품 결과 카드의 사진 자리)
state.chat             대화 기록 (text, fromUser, latency)
state.asking           서버 분석 중인가
state.framingHint      프레이밍 교정 안내 (빈 문자열이면 표시 안 함)
state.lensChecking     렌즈 확인 중인가
```

**부르는 동작**

```
state.start(to: tab)        진입 화면 → 플로우 시작
state.goTab(tab)            탭 이동
state.startListening()      음성 인식 시작
state.captureAndAnalyze()   화장품 촬영
state.askByVoice()          질문 화면의 마이크 버튼
state.ask(text)             질문 전송 (추천 질문 버튼도 같은 경로)
state.retakeCosmetic()      화장품 다시 촬영
state.retakeMakeup()        메이크업 다시 촬영 / 분석 취소
state.repeatResult()        결과 다시 들려주기
state.speakProduct()        제품 설명 다시 들려주기
state.resetToStart()        처음으로
state.exitApp()             종료
```

**VoiceService 직접 구독** (`makeup_tab`, `settings_tab`, `main_shell`)

```
VoiceService.instance        AnimatedBuilder 로 구독
  .isSpeaking / .isListening / .partialText / .sttAvailable
  .speak() / .startListening() / .stopSpeaking()
  .addListener() / .removeListener()   ← dispose 에서 반드시 해제
```

> `addListener`를 걸었으면 `dispose`에서 `removeListener`를 반드시 부른다.
> 안 하면 화면을 떠난 위젯이 계속 깨어나 `setState` 오류가 난다.

---

## 탭 전환 시 반드시 일어나는 일

`AppState.goTab()`이 처리한다. **UI는 `goTab`을 부르기만 하면 되고, 이 부수효과를
UI 쪽에서 흉내 내면 안 된다.**

0. **두 플로우 모두 촬영 단계로 리셋** — 탭에 들어오면 항상 처음부터.
   진행 중이던 분석 응답은 세대(_askGen) 불일치로 버려진다
1. `notifyListeners()`
2. 햅틱 (`selectionClick`)
3. 전면 카메라로 전환
4. 메이크업 분석 탭이면 → 백엔드 연결 + GPU 깨우기 + warm-up 타이머 + **프레이밍 감시 시작**
   (감시는 **촬영 단계에서만** 찍는다. 찍고 난 뒤에도 3초마다 찍으면 사용자에겐 계속 촬영하려 드는 걸로 들린다)
5. 다른 탭이면 → 두 타이머 정지
6. 카메라 탭이면 → 렌즈 이물질 검사 (**들어올 때마다**. 한 번만 하면 그 뒤에 묻은 물은 영영 못 잡는다)
   셔터를 누를 때도 그 프레임으로 한 번 더 본다 — 더러우면 인식·전송 없이 촬영 화면으로 되돌린다
7. 탭 안내 음성

---

## API 명세 (변경 금지)

서버 `100.91.201.104:8100`. 앱은 8100 → 8000 순으로 `/health`를 훑어 살아있는 쪽을 쓴다.

### 앱이 실제로 쓰는 경로

**WebSocket `/ws/{session_id}`** — 분석 (OpenAPI에 안 잡히므로 여기 기록)

```jsonc
// 앱 → 서버
{ "type": "analyze", "request_id": "app-1",
  "question": "립 어때?", "image_b64": "…", "mirrored": false }

// 서버 → 앱
{ "type": "analysis_result", "request_id": "app-1",
  "status": "ok",            // ok | retake | error
  "message": "읽어줄 문장",    // 앱은 이것만 읽는다
  "route": "lip", "action": "wipe", "prep_ms": 14, "infer_ms": 3120 }
```

**`POST /framing`** — 찍기 전 자세 확인 (GPU 안 씀, 27~81ms)

```jsonc
// 요청
{ "image_b64": "…", "mirrored": null }
// 응답
{ "ok": false, "code": "too_small",
  "guidance": "조금 더 가까이 가져와 주세요.",
  "face_w": 96, "lip_w": 35, "ms": 31 }
```

`code`: `ok` · `too_dark` · `no_face` · `too_small` · `lip_small` · `cut_off` · `unreadable` · `empty`

**`POST /warmup`** — GPU 깨우기 · **`GET /health`** — 서버 탐색

### 나머지 (앱은 안 쓰지만 존재)

`POST /analyze` (curl 시험용) · `GET /routes` · `GET /route-test?q=…`

### 앱 쪽 고정값 (`backend_service.dart`)

```
host              100.91.201.104     ports 8100 → 8000
snapshotMaxSide   1280               ← 낮추면 입술 검출이 임계값에 걸린다
snapshotJpegQuality 88
analyzeTimeout    90초
healthTimeout     3초
warmUpInterval    5분
```

---

## 이미 어긋나 있는 것 (개편 때 같이 고치면 좋음)

감사 중에 발견한 **기존 불일치**다. 디자인 교체와 무관하지만, 어차피 손대는 김에
정리하면 좋다. 지금 고치지 않아도 디자인 교체 자체는 안전하다.

| # | 문제 | 상태 |
| --- | --- | --- |
| 1 | 설정 탭 제스처 안내가 "가이드 탭에서만"이라고 했지만 화장품 탭에서도 동작 | **고침** — "화장품 인식 · 메이크업 분석 탭" 으로 수정 |
| 2 | 타임아웃이 역전돼 있었다 (앱 90초 < 서버 120초). 앱이 먼저 끊으면 다 만든 답을 버리고, 그 요청이 GPU 한 자리를 계속 잡아 바로 이어지는 재촬영까지 느려졌다 | **고침** — 서버 60초 · 앱 70초. 정상 추론이 20~35초라 60초면 충분하고, 이제 항상 서버가 먼저 답한다 |
| 3 | 마이크 버튼이 `AppState.startListening()` 을 우회해 햅틱·클릭음이 빠졌다 | **고침** — `state.askByVoice()` → `startListening()` 경유 |
| 4 | "카메라 렌즈 확인 중" 이 화면에만 뜨고 낭독이 없었다 | **고침** — `liveRegion` 추가 |

---

## 교체 후 점검표

디자인 교체가 끝나면 이 순서로 확인한다. **눈으로 보는 것만으로는 부족하다 —
화면을 끄거나 눈을 감고 해 봐야 진짜 검증이다.**

**자동**

```bash
flutter analyze && flutter test
```

```bash
cd server && python -m pytest tests/ -q
```

**손으로 (앱)**

- [ ] 인트로에서 아무 곳이나 두드리면 즉시 진입 화면으로 간다 (음성은 안 끊긴다)
- [ ] 진입 화면에서 아무 곳이나 터치하면 화장품 촬영으로 간다
- [ ] 세 탭 모두 진입 시 안내 음성이 나온다 (설정 탭은 **안 나오는 게 정상**)
- [ ] 어느 화면에서든 한 번 두드리면 "듣고 있어요" 오버레이가 뜬다
- [ ] 오버레이가 떠 있어도 두드리기가 계속 먹힌다 (`IgnorePointer` 확인)
- [ ] 어느 화면에서든 1.5초 길게 누르면 종료된다
- [ ] 설정 탭 슬라이더를 **천천히** 끌어도 앱이 안 꺼진다
- [ ] 화장품 탭: 촬영 → 로딩 → 결과 카드 → 카드 두드리면 처음으로
- [ ] 가이드 탭 대기 중 12초마다 "아직 보고 있어요" + 진동
- [ ] 가이드 탭에 3초쯤 있으면 자세 안내가 나온다 (자세가 나쁠 때만)
- [ ] 설정 탭에서 음성을 누르면 그 목소리로 샘플을 읽는다

**스크린리더 (TalkBack 켜고)**

- [ ] 모든 버튼에 라벨이 읽힌다

**로그로 확인**

```bash
adb logcat -s flutter:* | grep -E "Framing|Backend|STT|TTS"
```

`[Framing] ok … 40ms` / `[Backend] snapshot …KB (1280px, …ms)`가 보이면 통신은 정상이다.

---

## 오해하기 쉬운 것 (사실은 바꿔도 된다)

감사 과정에서 "기능인 줄 알았는데 아니었던" 것들이다. 겁먹고 안 건드리면 디자인이
반쪽이 되므로 명시해 둔다.

| 항목 | 사실 |
| --- | --- |
| 화면 전체 두드리기와 오버레이 | `GestureLayer`가 조상이라 `IgnorePointer` 없이도 두드리기는 살아 있다. 막히는 건 **아래 깔린 버튼**뿐 |
| 대화 카드를 올리는 트리거 | 주 경로는 `didUpdateWidget`(새 메시지·`asking`)이다. `VoiceService` 구독은 보조라 카드 UI를 새로 짜도 무방 |
| `_phrases` (대기 화면 순환 문구) | **화면에만** 보인다. 자유롭게 바꿔도 된다. 단 `_spoken`(12초마다 읽는 3문장)은 기능 |
| 음성 상태 칩의 `label` 문자열 | 화면 표시와 `Semantics`가 같은 값을 쓸 뿐이다. 표시 문구를 바꿔도 되지만 **`Semantics`에도 같이 반영**해야 한다 |
| `Column` 안 위젯 순서 | 시각적 배치라 자유. 단 `BottomTabBar`가 `onTap: state.goTab`을 유지해야 한다 |
| 마이크 알약의 길게 누르기 | 시연 편의 기능이다. 없애도 음성으로 같은 일을 할 수 있다 |
| `hideCamera` 조건과 음성 차단 | 서로 독립이다. 배경 전환을 바꿔도 `voice.muted`와 어긋나지 않는다 |

---

## 자주 하는 실수

| 실수 | 결과 |
| --- | --- |
| 카드를 키우거나 옮김 | **두 번 두드려 촬영되는 영역이 같이 바뀐다** (자식 `onTap`이 부모 제스처를 잡아먹음) |
| `ValueKey(state.tab)`을 `UniqueKey()` 등으로 바꿈 | `GuideTab` State가 매 빌드 재생성 → 12초 알림이 **한 번도 안 울림** |
| `_syncAnimation`을 지우고 항상 `repeat()` | 대기 중에도 매 프레임 재렌더 (발열·배터리) |
| 하단 `SizedBox(height: 18)` 축소 | 탭바가 OS 홈 인디케이터 스와이프와 겹침 |
| 오버레이를 `SafeArea` 안으로 옮김 | 노치 옆이 안 덮여 화면이 새어 보임 |
| 버튼을 작고 예쁘게 | 손으로 더듬어 찾는 사용자가 못 찾음 |
| 화면 회전 허용 | 카메라 프리뷰 cover 계산이 세로 전제라 찌그러짐 |
| 무한 `repeat()` 컨트롤러를 상시 트리에 둠 | 대기 중에도 매 프레임 다시 그린다 |
| 오버레이를 `IgnorePointer` 없이 올림 | 아래 깔린 탭바·촬영 버튼·마이크 알약이 죽음 (화면 전체 두드리기는 살아 있다) |
| `Semantics` 빠뜨림 | 스크린리더 사용자가 버튼을 못 찾음 |
| `liveRegion` 빠뜨림 | 상태가 바뀌어도 안 읽어 줌 |
| `removeListener` 빠뜨림 | 화면 떠난 뒤 `setState` 오류 |
| 슬라이더를 `onChanged`에서 적용 | 드래그 중 TTS 설정·파일 저장 폭주 |
| `_dragSlop` 낮춤 | 슬라이더 끌다가 앱 종료 |
| 12초 음성 알림 제거 | 20~40초 대기 중 사용자가 멈춘 줄 앎 |
| `snapshotMaxSide` 낮춤 | 입술 검출이 임계값에 걸려 재촬영 급증 |
