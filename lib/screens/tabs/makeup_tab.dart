import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../../app_state.dart';
import '../../services/scan_sfx.dart';
import '../../services/voice_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/coral.dart';
import '../../widgets/hologram_scan.dart';
import '../../widgets/photo_source.dart';
import '../../services/backend_service.dart' show AnalysisItem;

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
    final step = switch (state.makeupStage) {
      MakeupStage.capture => 0,
      MakeupStage.question => 1,
      MakeupStage.analyzing => 2,
      MakeupStage.result => 3,
    };
    return Column(
      children: [
        // 화면 이름은 스크린리더만 읽는다 (화장품 인식 탭과 같은 이유)
        ScreenHeader(
          title: '메이크업 분석',
          showTitle: false,
          onBack: state.makeupStage == MakeupStage.capture
              ? null
              : () => state.retakeMakeup(),
        ),
        const SizedBox(height: 12),
        Gutter(child: StepIndicator(steps: steps, current: step)),
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
        // 촬영 안내는 글자로 쓰지 않는다 — TTS 로만 말한다
        // (AppState._announceCurrent).
        // 카메라와 안내선은 메인 셸이 화면 전체에 깔아 준다.
        // 여기서는 그만큼 자리만 비워 둔다.
        const Expanded(child: SizedBox.expand()),
        const SizedBox(height: 8),
        // 플래시는 두지 않는다 (화장품 인식 탭과 같은 이유)
        Center(child: ShutterButton(onTap: state.captureAndAsk)),
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

  /// 피그마 「Suggested questions」(373:55~373:60) 문구 그대로.
  static const suggestions = [
    '입술 화장이 어때?',
    '베이스 뭉친 곳 있어?',
    '전체적으로 자연스러운가요?',
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(child: Gutter(child: _VoiceSurface(state: state))),
        const SizedBox(height: 12),
        // ListView 가 아니라 Row — 화면 밖 칩도 만들어 두어야 스크린리더가
        // 세 개를 다 읽는다 (ListView 는 보이는 것만 만든다)
        SizedBox(
          height: 48,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: AppShape.gutter),
            child: Row(
              children: [
                for (final q in suggestions) ...[
                  _SuggestionChip(label: q, onTap: () => state.ask(q)),
                  const SizedBox(width: 10),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }
}

/// 화면을 채우는 음성 버튼. 면 전체가 누르는 곳이다.
///
/// 배경은 촬영 면과 같은 코랄 블롭 — 같은 앱이라는 걸 손끝이 아니라 눈으로
/// 알아보는 저시력 사용자를 위한 것이고, 갈고리도 그래서 그대로 둔다.
class _VoiceSurface extends StatelessWidget {
  const _VoiceSurface({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: VoiceService.instance,
      builder: (context, _) {
        final v = VoiceService.instance;
        final listening = v.isListening;
        final heard = v.partialText.isNotEmpty ? v.partialText : state.lastHeard;
        return Semantics(
          button: true,
          liveRegion: true,
          label: listening
              ? '듣고 있습니다. $heard'
              : heard.isEmpty
                  ? '음성으로 질문하기, 버튼. 누른 뒤 편하게 말씀하세요'
                  : '$heard, 라고 들었어요. 음성으로 질문하기, 버튼',
          child: ExcludeSemantics(
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(AppShape.cardRadius),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: state.askByVoice,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    const CoralBlobs(),
                    const CornerBrackets(),
                    Center(child: _MicVisual(listening: listening)),
                    if (heard.isNotEmpty)
                      Align(
                        alignment: const Alignment(0, 0.82),
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 22),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 18, vertical: 10),
                          decoration: BoxDecoration(
                            color: AppColors.ink.withValues(alpha: 0.82),
                            borderRadius:
                                BorderRadius.circular(AppShape.buttonRadius),
                          ),
                          child: Text(
                            heard,
                            textAlign: TextAlign.center,
                            style: AppText.cardTitle.copyWith(color: Colors.white),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
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
              for (final k in [0.0, 0.5]) _Pulse(base: d, t: (_c.value + k) % 1.0),
            const _Ring(d: d * 1.18, alpha: 0.30, width: 2),
            Container(
              width: d,
              height: d,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: AppColors.shutter,
                boxShadow: [
                  BoxShadow(color: Color(0x33FF7A92), blurRadius: 24, offset: Offset(0, 8)),
                ],
              ),
              child: const Icon(Icons.mic_rounded, size: 72, color: Colors.white),
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
              color: AppColors.scanLine.withValues(alpha: alpha), width: width),
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

/// 추천 질문 알약 — 한 줄에 가로로 늘어놓는다
class _SuggestionChip extends StatelessWidget {
  const _SuggestionChip({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '$label, 추천 질문',
      child: ExcludeSemantics(
        child: Material(
          color: AppColors.surfaceSuggest,
          borderRadius: BorderRadius.circular(AppShape.cardRadius),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(AppShape.cardRadius),
            child: Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 18),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppShape.cardRadius),
                border: Border.all(color: AppColors.chipEdge),
              ),
              child: Text(label,
                  style: AppText.label.copyWith(
                      fontSize: 15, color: AppColors.inkQuestion)),
            ),
          ),
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
    return Column(
      children: [
        Expanded(
          child: Gutter(
            child: Semantics(
              liveRegion: true,
              label: state.analysisLine,
              child: ExcludeSemantics(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppShape.cardRadius),
                  child: HologramScan(
                    photo: shot == null ? null : photoProvider(shot),
                    statusLine: state.analysisLine,
                    progress: state.analysisProgress,
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        Gutter(
          // 「접근성 명세」: 이 버튼은 항상 마지막에 읽는다
          child: CoralButton(
            label: '취소하고 다시 촬영하기',
            filled: false,
            onTap: () => state.retakeMakeup(),
          ),
        ),
        const SizedBox(height: 12),
      ],
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
  /// 지금 사진에서 짚어 보는 항목. null 이면 전부 같은 무게로 보여 준다.
  ///
  /// 여럿을 한꺼번에 짚으면 어느 게 어느 카드인지 눈으로 못 잇는다.
  /// 카드를 누르면 그 자리만 남고, 한 번 더 누르면 다시 전부 보인다.
  int? _picked;

  /// 카드를 눌렀을 때. 화면을 못 보는 사용자에게는 짚어 준 게 안 보이므로
  /// **말로 한 번 더 알려 준다.**
  void _pick(int? at, AnalysisItem? item) {
    setState(() => _picked = at);
    final state = widget.state;
    if (at == null) {
      state.voice.speak('전체를 다시 보여 드릴게요.');
    } else if (item != null) {
      state.voice.speak('${item.region}. ${item.state}');
    }
    HapticFeedback.selectionClick();
  }

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
    // 사진 위에 짚을 자리. 자리를 못 찾은 항목은 빠진다 — 어디인지 모르면서
    // 아무 데나 동그라미를 치는 것보다 안 그리는 게 낫다.
    final spots = [
      for (final e in items)
        if (ProblemSpot(region: e.region, box: e.box).area != null)
          ProblemSpot(region: e.region, box: e.box),
    ];
    return Column(
      children: [
        const Gutter(
          child: SizedBox(
            width: double.infinity,
            child: Text('메이크업 분석 완료!', style: AppText.h1),
          ),
        ),
        const SizedBox(height: 14),
        Expanded(
          child: SingleChildScrollView(
            child: Gutter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 어디가 문제인지 — 찍은 사진 위에 짚어 준다.
                  //
                  // 서버가 좌표를 안 줘도 부위 이름으로 자리를 어림한다
                  // (ProblemSpot.zoneOf). 예전에는 좌표가 있을 때만 사진이
                  // 떴는데, 실제로는 좌표 없이 오는 경우가 더 많아서 결과에
                  // "어디가" 가 통째로 빠져 있었다. 어림한 자리는 흐리게
                  // 그려서 잰 값처럼 보이지 않게 한다.
                  if (state.lastShotPath != null && spots.isNotEmpty) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: SizedBox(
                        height: 240,
                        width: double.infinity,
                        child: ShotWithBoxes(
                          path: state.lastShotPath!,
                          spots: spots,
                          active: _picked,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  if (items.isEmpty)
                    // 항목 없는 결과(립 경로, 결함 없음 등)는 문장 하나로 온다.
                    // 제목은 질문이 짚은 부위 — '입술' 로 박아 두면 베이스를
                    // 물어봐도 입술 카드가 나온다. 실제로 그랬다.
                    ResultCard(
                      title: state.analysisFocus,
                      body: state.lastSpokenResult,
                    )
                  else
                    for (var i = 0; i < items.length; i++) ...[
                      () {
                        final at =
                            spots.indexWhere((s) => s.region == items[i].region);
                        return ResultCard(
                          // 번호는 안 붙인다. 사진에는 부위 자리에 코랄이
                          // 번져 있어서, 이름만으로 어디인지 바로 이어진다.
                          title: items[i].region,
                          body: items[i].state,
                          action: items[i].action,
                          selected: at >= 0 && _picked == at,
                          // 사진에 자리가 없는 항목은 눌러도 보여 줄 게 없다.
                          onTap: at < 0
                              ? null
                              : () => _pick(
                                  _picked == at ? null : at, items[i]),
                        );
                      }(),
                      if (i < items.length - 1) const SizedBox(height: 16),
                    ],
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Gutter(
          child: Row(
            children: [
              Expanded(
                child: CoralButton(
                  label: '다시 들려주기',
                  filled: false,
                  onTap: state.repeatResult,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: CoralButton(
                  label: '다시 촬영하기',
                  onTap: () => state.retakeMakeup(),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }
}
