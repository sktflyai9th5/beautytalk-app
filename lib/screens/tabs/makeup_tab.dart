
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../services/scan_sfx.dart';
import '../../services/voice_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/coral.dart';
import '../../widgets/hologram_scan.dart';
import '../../widgets/photo_source.dart';

/// 메이크업 분석 플로우.
/// 피그마 「③ 메이크업 분석 · 촬영 → 질문 → 분석 → 결과」
/// (368:9 / 380:2 / 373:26 / 380:16 / 380:50).
///
/// 단계 표시기는 4단계다. 카운트다운(380:2)은 두지 않는다 — 셔터를 누르면 바로 찍는다.
class MakeupTab extends StatelessWidget {
  const MakeupTab({super.key, required this.state});
  final AppState state;

  static const steps = ['촬영', '질문', '분석', '결과'];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // 화면 이름은 스크린리더만 읽는다 (화장품 인식 탭과 같은 이유)
        ScreenHeader(
          title: '메이크업 분석',
          showTitle: false,
          onMenu: () => state.goTab(AppTab.settings),
          onHome: state.resetToStart,
          // 뒤로 가기는 언제나 있다 (화장품 탭과 같은 규칙).
          onBack: state.makeupStage == MakeupStage.capture
              ? state.resetToStart
              : () => state.retakeMakeup(),
        ),
        // 단계 표시기(1·2·3·4)는 두지 않는다 — 지금 어디인지는 화면 제목과
        // 음성이 이미 말하고, 눈금이 위쪽 자리를 크게 먹었다.
        const SizedBox(height: 8),
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 260),
            child: KeyedSubtree(
              key: ValueKey(state.makeupStage),
              child: switch (state.makeupStage) {
                MakeupStage.capture => _Capture(state: state),
                MakeupStage.question => _Question(state: state),
                MakeupStage.analyzing => _Analyzing(state: state),
                MakeupStage.result => _Result(state: state),
              },
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- 촬영
class _Capture extends StatelessWidget {
  const _Capture({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // 카메라와 조준선은 메인 셸이 화면 전체에 깔아 준다.
        // 여기서는 그만큼 자리만 비워 둔다.
        const Expanded(child: SizedBox.expand()),
      ],
    );
  }
}

// ---------------------------------------------------------------- 질문
/// 질문 화면. 글자 없이 **음성 버튼 하나가 화면을 채운다.**
///
/// 피그마(373:26)에는 제목과 설명이 있었지만 두지 않는다 — 앞이 보이지 않는
/// 사용자에게 읽히지 않고, 저시력 사용자에게는 버튼을 작게 만들 뿐이다.
/// 할 일이 하나뿐인 화면은 그 하나로 채운다. 추천 질문은 아래 한 줄로 남긴다.
class _Question extends StatelessWidget {
  const _Question({required this.state});
  final AppState state;

  /// 무엇을 물어볼 수 있는지 알려 주는 예시. 화면을 못 보는 사용자에게는
  /// 이게 유일한 목록이라 빼지 않는다.
  static const suggestions = [
    '입술 화장이 어때?',
    '베이스 뭉친 곳 있어?',
    '자연스러운가요?',
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // 시트를 두지 않는다 — 이 화면에서 할 일은 말하는 것 하나뿐이라
        // 누를 것을 늘어놓을 이유가 없다. 화면 아무 데나 누르면 듣는다.
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(child: _ShotPreview(state: state)),
              // 추천 질문 — 화면 아래에 얹는다. 시트를 되살리지 않고
              // 사진 위에 그대로 띄워서 "눌러서 말하기" 를 가리지 않는다.
              Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 26),
                  child: SizedBox(
                    height: 48,
                    // ListView 가 아니라 Row — 화면 밖 칩도 만들어 두어야
                    // 스크린리더가 세 개를 다 읽는다.
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppShape.gutter),
                      child: Row(
                        children: [
                          for (final q in suggestions) ...[
                            _SuggestionChip(
                                label: q, onTap: () => state.ask(q)),
                            const SizedBox(width: 10),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 방금 찍은 얼굴 — 화면을 채우고 그 위에 **흐린 어둠**이 깔린다.
///
/// 사진을 그대로 두면 눈이 거기 붙들리고, 아예 없애면 무엇을 두고 묻는지
/// 알 수 없다. 흐리게 덮으면 "이 사진에 대해 묻는 중" 만 남는다.
/// 듣는 동안에는 그 위에 파형이 흐른다.
class _ShotPreview extends StatelessWidget {
  const _ShotPreview({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final shot = state.lastShotPath;
    final heard = state.lastHeard;
    return Semantics(
      label: heard.isEmpty ? null : '$heard, 라고 들었어요',
      child: ExcludeSemantics(
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (shot == null)
              const ColoredBox(color: AppColors.surfaceSoft)
            else
              Image(
                image: photoProvider(shot),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) =>
                    const ColoredBox(color: AppColors.surfaceSoft),
              ),
            // 흐림 + 어둠. 둘 다 있어야 사진이 뒤로 물러난다.
            // **ClipRect 로 감싼다.** 안 그러면 흐림이 제 영역 밖까지
            // 번져 위쪽 상단바까지 뿌옇게 만든다.
            ClipRect(
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                child: const ColoredBox(color: Color(0x8C10161C)),
              ),
            ),
            // 화면 아무 데나 눌러도 듣는다. GestureLayer 의 한 번 두드리기와
            // 같은 길이지만, 여기서는 그게 이 화면의 유일한 할 일이라
            // 스크린리더에도 버튼으로 알린다.
            Positioned.fill(
              child: Semantics(
                button: true,
                label: '음성으로 질문하기. 화면을 누르고 말씀하세요',
                child: ExcludeSemantics(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: state.askByVoice,
                  ),
                ),
              ),
            ),
            // 안내 한 줄. 듣는 중에는 감춘다 — 그때는 파형이 상태를 말한다.
            AnimatedBuilder(
              animation: VoiceService.instance,
              builder: (context, _) {
                if (VoiceService.instance.isListening) {
                  return const SizedBox.shrink();
                }
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 28),
                    child: Text(
                      '화면을 눌러 궁금한 걸 말씀하세요.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 34,
                        height: 1.4,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        shadows: [
                          Shadow(blurRadius: 12, color: Color(0x8A000000)),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
            // 듣는 동안 흐르는 파형과 **받아 적은 말**.
            //
            // 말한 것이 화면에 되돌아와야 잘못 들었는지 바로 안다 —
            // 서버까지 갔다 와서야 "입술을 물었는데 베이스를 봤네" 를
            // 겪으면 처음부터 다시 해야 한다.
            AnimatedBuilder(
              animation: VoiceService.instance,
              builder: (context, _) {
                final v = VoiceService.instance;
                if (!v.isListening) return const SizedBox.shrink();
                final heard =
                    v.partialText.isNotEmpty ? v.partialText : state.lastHeard;
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    Center(
                      child: VoiceWaves(
                        level: (0.35 + 0.65 * v.soundLevel).clamp(0.0, 1.0),
                        height: 200,
                      ),
                    ),
                    if (heard.isNotEmpty)
                      Align(
                        alignment: const Alignment(0, 0.42),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 28),
                          child: Text(
                            heard,
                            textAlign: TextAlign.center,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 26,
                              height: 1.35,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                              shadows: [
                                Shadow(
                                    blurRadius: 14, color: Color(0x9E000000)),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// 가운데 마이크 원 + 링. 누르는 건 바깥 면이 맡는다 — 여기는 그림만.
class _MicVisual extends StatefulWidget {
  const _MicVisual({required this.listening});
  final bool listening;

  @override
  State<_MicVisual> createState() => _MicVisualState();
}

class _MicVisualState extends State<_MicVisual>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant _MicVisual old) {
    super.didUpdateWidget(old);
    _sync();
  }

  /// 듣는 중일 때만 링을 돌린다 (대기 중 매 프레임 재렌더 방지)
  void _sync() {
    if (widget.listening && !_c.isAnimating) {
      _c.repeat();
    } else if (!widget.listening && _c.isAnimating) {
      _c.stop();
      _c.value = 0;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const d = 150.0; // 채움 원. 「88px 이상」을 넉넉히 넘는다
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => SizedBox(
        width: d * 2,
        height: d * 2,
        child: Stack(
          alignment: Alignment.center,
          children: [
            const _Ring(d: d * 1.9, alpha: 0.14, width: 1.5),
            const _Ring(d: d * 1.55, alpha: 0.26, width: 2),
            if (widget.listening)
              for (final k in [0.0, 0.5])
                _Pulse(base: d, t: (_c.value + k) % 1.0),
            const _Ring(d: d * 1.18, alpha: 0.30, width: 2),
            Container(
              width: d,
              height: d,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: AppColors.shutter,
                boxShadow: [
                  BoxShadow(
                    color: Color(0x3342805A),
                    blurRadius: 24,
                    offset: Offset(0, 8),
                  ),
                ],
              ),
              child: const Icon(
                Icons.mic_rounded,
                size: 72,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Ring extends StatelessWidget {
  const _Ring({required this.d, required this.alpha, required this.width});
  final double d;
  final double alpha;
  final double width;

  @override
  Widget build(BuildContext context) => Container(
    width: d,
    height: d,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      border: Border.all(
        color: AppColors.scanLine.withValues(alpha: alpha),
        width: width,
      ),
    ),
  );
}

/// 듣는 중에만 바깥으로 퍼지는 링
class _Pulse extends StatelessWidget {
  const _Pulse({required this.base, required this.t});
  final double base;
  final double t;

  @override
  Widget build(BuildContext context) {
    final d = base * (1.18 + 0.8 * t);
    return Container(
      width: d,
      height: d,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: AppColors.coral.withValues(alpha: 0.55 * (1 - t)),
          width: 2,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 분석 중
/// 분석 중 — 찍은 사진을 빔이 훑고, 특징점이 잡히고, 3D 홀로그램으로 넘어간다.
///
/// 앱에서 유일하게 어두운 화면이다. 일부러 그렇게 뒀다 — 기계가 지금 일하고
/// 있다는 걸 한 박자로 보여 주고 결과에서 다시 밝아진다.
/// 상태 문장과 진행 막대는 [HologramScan] 안으로 들어갔다. 어두운 면 위에
/// 얹혀야 읽히고, 바깥에 또 두면 같은 문장이 두 번 나온다.
class _Analyzing extends StatelessWidget {
  const _Analyzing({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final shot = state.lastShotPath;
    // 결과 화면과 같은 짜임이다 — 얼굴이 화면을 다 쓰고, 문장과 버튼은
    // 그 위에 겹친 시트에 담긴다. 시트를 끌어 내리면 얼굴이 다 드러난다.
    final face = Gutter(
      child: Semantics(
        liveRegion: true,
        label: state.analysisLine,
        child: ExcludeSemantics(
          // **결과 화면과 같은 짜임이다.** 아래 20px 여백과 -0.10 밀기까지
          // [ResultShowcase] 와 맞춰 뒀다 — 분석에서 결과로 넘어갈 때 얼굴이
          // 크기도 자리도 그대로여야 같은 아바타로 읽힌다.
          child: Column(
            children: [
              Expanded(
                // 아래에서 시트가 올라오므로 가운데에 두면 아래로 치우쳐
                // 보인다. **결과 화면(-0.10) 보다 더 올린다** — 분석 중에는
                // 시트가 0.30 까지 올라와 있어서 같은 자리에 두면 얼굴 아래가
                // 그만큼 덮인다. 크기(1.12배) 는 두 화면이 같아야 한다 —
                // 넘어갈 때 얼굴이 줄면 화면이 바뀐 것으로 보인다.
                child: FractionalTranslation(
                  translation: const Offset(0, -0.17),
                  child: ClipRect(
                    child: HologramScan(
                      photo: shot == null ? null : photoProvider(shot),
                      statusLine: state.analysisLine,
                      progress: state.analysisProgress,
                      // 문장과 막대는 아래 시트가 맡는다 — 얼굴이 그만큼 커진다.
                      showStatus: false,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );

    // **ClipRect 로 가둔다.** 아래 face 가 FractionalTranslation 으로
    // 위로 밀려 있어서, 자르지 않으면 그만큼 상단바 위로 그려진다 —
    // 분석 중에 상단바가 사라진 것처럼 보였던 게 이것이다.
    return ClipRect(
      child: Stack(
        children: [
          face,
          _AnalyzingSheet(state: state),
        ],
      ),
    );
  }
}

/// 분석 중 시트 — 문장 · 진행 막대 · 취소.
class _AnalyzingSheet extends StatelessWidget {
  const _AnalyzingSheet({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.30,
      minChildSize: 0.14, // 손잡이와 문장 한 줄은 항상 남는다
      maxChildSize: 0.62,
      builder: (context, controller) => DecoratedBox(
        decoration: const BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          boxShadow: [
            BoxShadow(
              color: AppColors.cardShadow,
              blurRadius: 30,
              offset: Offset(0, -8),
            ),
          ],
        ),
        child: SafeArea(
          top: false,
          // ListView 가 아니다 — 보이는 것만 만들면 작은 화면에서 아래 버튼이
          // 스크린리더에 아예 안 잡힌다.
          child: SingleChildScrollView(
            controller: controller,
            padding: const EdgeInsets.fromLTRB(
              AppShape.gutter,
              14,
              AppShape.gutter,
              16,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Center(
                  child: ExcludeSemantics(
                    child: SizedBox(
                      width: 44,
                      height: 4,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: AppColors.track,
                          borderRadius: BorderRadius.all(Radius.circular(2)),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                // 문장은 얼굴 위 Semantics 가 이미 읽는다 — 여기서는 그림만.
                ExcludeSemantics(
                  child: ScanStatusBar(
                    line: state.analysisLine,
                    progress: state.analysisProgress,
                  ),
                ),
                const SizedBox(height: 16),
                // 「접근성 명세」: 이 버튼은 항상 마지막에 읽는다
                CoralButton(
                  label: '취소하고 다시 촬영하기',
                  icon: Icons.close_rounded,
                  warn: true,
                  onTap: () => state.retakeMakeup(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 결과
/// 결과. 피그마 「Draft · 메이크업 결과」(380:50)의 카드(번호 · 부위 / 상태 / 할 일)
/// 를 큰 글씨로. 저시력 사용자가 읽는 화면이다.
class _Result extends StatefulWidget {
  const _Result({required this.state});
  final AppState state;

  @override
  State<_Result> createState() => _ResultState();
}

class _ResultState extends State<_Result> {
  @override
  void initState() {
    super.initState();
    // 분석이 끝났다는 신호. 이 위젯은 단계가 결과로 바뀔 때 새로 만들어지므로
    // (AnimatedSwitcher 가 단계로 키를 잡는다) 여기서 딱 한 번 울린다.
    // 바로 뒤에 TTS 가 결과를 읽기 시작하니 소리는 짧게 끝나야 한다.
    ScanSfx.instance.done();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final items = state.analysisItems;
    // 아바타에서 자리를 찾은 항목들. 못 찾은 것은 빠진다 — 어디인지 모르면서
    // 아무 데나 불을 켜는 것보다 안 켜는 게 낫다.
    final lit = [
      for (var i = 0; i < items.length; i++)
        if (ResultHologram.spotFor(items[i].region, items[i].zone) != null) i,
    ];
    final face = Column(
      children: [
        // 「메이크업 분석 완료!」 는 두지 않는다 — 음성이 이미 그렇게 말했고,
        // 그 자리는 얼굴이 쓰는 편이 낫다. 시트 제목이 같은 말을 한다.
        // **얼굴이 화면의 주인이다.** 문장 카드를 옆에 세우면 얼굴이 손톱만
        // 해져서, 어디를 짚었는지 멀리서 보이지 않는다. 얼굴을 크게 두고
        // 문장은 아래 시트로 내린다.
        Expanded(
          child: Gutter(
            // 카드에 담아 늘어놓지 않는다. 회색 면이 여러 장 깔리면 방금까지
            // 보던 큰 아바타 화면과 딴 화면이 되고, 문장도 작아져서 저시력
            // 사용자가 못 읽는다. 분석 중 화면과 같은 구성으로 둔다.
            // **언제나 3D 아바타다.** 문제를 하나도 못 찾았을 때
            // 회색 카드로 바꾸면, 방금까지 보던 얼굴이 사라져서 결과가
            // 아니라 다른 화면으로 넘어온 것처럼 보인다. 짚을 자리가 없으면
            // 불만 켜지 않고 얼굴은 그대로 돌린다.
            //
            // **하나만 보여 준다.** 여러 부위를 돌려 가며 띄우면 화면이
            // 계속 바뀌고 TTS 도 그때마다 다시 말한다. 결과 문장은
            // 분석이 끝날 때 AppState 가 이미 한 번 읽어 준다 —
            // 여기서 또 읽으면 같은 말을 두 번 하게 된다.
            // 문장은 아래 시트에 있다 — 여기서는 얼굴만 크게 띄운다.
            child: lit.isEmpty
                ? ResultShowcase(regions: const [], title: state.analysisFocus)
                : ResultShowcase(
                    regions: [for (final i in lit) items[i].region],
                    zones: [for (final i in lit) items[i].zone],
                  ),
          ),
        ),
        const SizedBox(height: 20),
      ],
    );

    return Stack(
      children: [
        face,
        _ResultSheet(
          state: state,
          sentence: lit.length == 1
              ? items[lit.first].state
              : state.lastSpokenResult,
        ),
      ],
    );
  }
}

/// 결과 시트. 얼굴 아래에서 올라온 흰 판에 문장과 버튼이 있다.
///
/// 시트로 내린 이유는 얼굴을 크게 두기 위해서다 — 이 화면에서 사람이 보는
/// 것은 "어디가 문제인가" 이고, 그건 3D 얼굴 위의 불로만 알 수 있다.
class _ResultSheet extends StatelessWidget {
  const _ResultSheet({required this.state, required this.sentence});
  final AppState state;

  /// 결과 문장. 얼굴 밑에 두면 얼굴이 그만큼 작아져서 시트 안으로 옮겼다.
  final String sentence;

  @override
  Widget build(BuildContext context) {
    // **얼굴 위에 겹쳐 뜬다.** 시트를 아래에 세워 두면 그만큼 얼굴이 줄어드는데,
    // 이 화면에서 봐야 할 것은 어디에 불이 켜졌는지다. 겹쳐 두고 손으로
    // 끌어 내리면 얼굴이 분석 화면과 똑같은 크기로 다 드러난다.
    return DraggableScrollableSheet(
      // **처음에는 접혀 있다.** 손잡이만 보이고, 올려야 문장과 버튼이
      // 나온다 — 결과 화면에서 먼저 봐야 할 것은 얼굴 위의 불이지 글자가
      // 아니다. 음성은 접혀 있어도 그대로 결과를 읽는다.
      initialChildSize: 0.13,
      minChildSize: 0.13,
      maxChildSize: 0.86,
      snap: true,
      snapSizes: const [0.13, 0.62],
      builder: (context, controller) => DecoratedBox(
        decoration: const BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          boxShadow: [
            BoxShadow(
              color: AppColors.cardShadow,
              blurRadius: 30,
              offset: Offset(0, -8),
            ),
          ],
        ),
        child: SafeArea(
          top: false,
          // ListView 가 아니라 이쪽이다 — ListView 는 보이는 것만 만들어서
          // 작은 화면에서 아래 버튼이 스크린리더에 아예 안 잡힌다.
          child: SingleChildScrollView(
            controller: controller,
            padding: const EdgeInsets.fromLTRB(
              AppShape.gutter,
              14,
              AppShape.gutter,
              16,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 손잡이 — 끌어 내릴 수 있다는 유일한 신호라 없애면 안 된다.
                const Center(
                  child: ExcludeSemantics(
                    child: SizedBox(
                      width: 44,
                      height: 4,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: AppColors.track,
                          borderRadius: BorderRadius.all(Radius.circular(2)),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Semantics(
                  header: true,
                  child: Text(
                    '메이크업 분석 결과',
                    style: AppText.h1.copyWith(fontSize: 30),
                  ),
                ),
                const SizedBox(height: 14),
                // 이 화면에서 사람이 읽는 유일한 문장이다. 멀리서도 읽혀야 한다.
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 18,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: AppColors.outline),
                  ),
                  child: Text(
                    sentence,
                    style: AppText.h1.copyWith(
                      fontSize: 22,
                      height: 1.45,
                      color: AppColors.ink,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                // 「카메라 화면으로」가 이 화면의 다음 걸음이라 가로를 다 쓴다.
                SizedBox(
                  width: double.infinity,
                  child: CoralButton(
                    label: '카메라 화면으로',
                    icon: Icons.photo_camera_rounded,
                    soft: true,
                    onTap: () => state.retakeMakeup(),
                  ),
                ),
                const SizedBox(height: 8),
                // 다시 듣기는 화면을 못 보는 사용자가 결과를 되짚는 유일한
                // 수단이라 없애지 않는다. 대신 아래로 내려 강조를 낮춘다.
                SizedBox(
                  width: double.infinity,
                  child: CoralButton(
                    label: '다시 들려주기',
                    icon: Icons.volume_up_rounded,
                    beige: true,
                    onTap: state.repeatResult,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 추천 질문 한 알. 흐린 사진 위에 얹히므로 흰 면에 진한 글자다.
class _SuggestionChip extends StatelessWidget {
  const _SuggestionChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: ExcludeSemantics(
        child: Material(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppShape.buttonRadius),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(AppShape.buttonRadius),
            child: Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Text(label,
                  style: AppText.label
                      .copyWith(fontSize: 16, color: AppColors.ink)),
            ),
          ),
        ),
      ),
    );
  }
}
