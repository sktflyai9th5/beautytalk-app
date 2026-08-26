import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import 'entry_screen.dart';

/// 진입 애니메이션. 피그마 「Intro · BeautyTalk 진입 애니메이션」(412:13) +
/// 「인트로 접근성 규칙」(424:12).
///
/// 규칙이 이 화면의 전부라 옮겨 적어 둔다:
///   · 2.6초는 화면이 보이지 않는 사용자에게는 2.6초의 침묵이다.
///     연출 시간을 음성 안내 시간으로 함께 쓴다 → 0.2초에 TTS 시작
///   · 화면 전체(393×852)가 탭 영역. 한 번 탭하면 즉시 끊고 넘어간다.
///     **최소 노출 시간은 두지 않는다.**
///   · 건너뛰어도 음성은 끊지 않는다 (진입 화면에서 이어서 재생)
///   · 두 번째 실행부터는 0.9초 축약 버전
///   · ANIMATOR_DURATION_SCALE == 0 이거나 TalkBack 이 켜져 있으면
///     애니메이션을 생략하고 바로 넘어간다
class IntroScreen extends StatefulWidget {
  const IntroScreen({
    super.key,
    required this.onDone,
    required this.onSpeak,
    this.abbreviated = false,
  });

  /// 애니메이션이 끝났거나 사용자가 건너뛰었을 때
  final VoidCallback onDone;

  /// 0.2초에 부른다. 건너뛰어도 취소하지 않는다.
  final VoidCallback onSpeak;

  /// 두 번째 실행부터 true → 0.9초 축약
  final bool abbreviated;

  static const full = Duration(milliseconds: 2600);
  static const short = Duration(milliseconds: 900);
  static const speakAt = Duration(milliseconds: 200);

  @override
  State<IntroScreen> createState() => _IntroScreenState();
}

class _IntroScreenState extends State<IntroScreen>
    with SingleTickerProviderStateMixin {
  late final Duration _dur =
      widget.abbreviated ? IntroScreen.short : IntroScreen.full;
  late final AnimationController _c =
      AnimationController(vsync: this, duration: _dur);

  Timer? _speakTimer;
  Timer? _doneTimer;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    // 애니메이션보다 음성이 먼저다. 0.2초에 시작해서 2.6초 전에 끝난다.
    _speakTimer = Timer(IntroScreen.speakAt, () {
      if (mounted) widget.onSpeak();
    });
    _start();
  }

  void _start() {
    // 「모션 축소 설정 대응」 — 애니메이션을 생략하고 홈 화면을 바로 띄운다.
    final reduce = WidgetsBinding
        .instance.platformDispatcher.accessibilityFeatures.disableAnimations;
    if (reduce) {
      _doneTimer = Timer(IntroScreen.speakAt, _finish);
      return;
    }
    _c.forward();
    _doneTimer = Timer(_dur, _finish);
  }

  /// 한 번만 넘어간다 (탭과 타이머가 겹칠 수 있다)
  void _finish() {
    if (_finished || !mounted) return;
    _finished = true;
    widget.onDone();
  }

  void _skip() {
    HapticFeedback.selectionClick();
    _finish(); // 음성은 그대로 두고 화면만 넘어간다
  }

  @override
  void dispose() {
    _speakTimer?.cancel();
    _doneTimer?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '뷰티톡을 시작합니다. 화면을 두드리면 바로 시작합니다.',
      child: GestureDetector(
        // 화면 전체가 탭 영역
        behavior: HitTestBehavior.opaque,
        onTap: _skip,
        child: ColoredBox(
          color: AppColors.surface,
          child: AnimatedBuilder(
            animation: _c,
            builder: (context, _) => _Content(t: _c.value),
          ),
        ),
      ),
    );
  }
}

class _Content extends StatelessWidget {
  const _Content({required this.t});
  final double t;

  double _stage(double from, double to) =>
      Curves.easeOutCubic.transform(((t - from) / (to - from)).clamp(0.0, 1.0));

  @override
  Widget build(BuildContext context) {
    final hero = _stage(0.00, 0.45);
    final title = _stage(0.15, 0.60);
    final message = _stage(0.45, 1.00);

    Widget rise(double v, Widget child) => Opacity(
          opacity: v,
          child:
              Transform.translate(offset: Offset(0, 18 * (1 - v)), child: child),
        );

    return ExcludeSemantics(
      child: LayoutBuilder(
        builder: (context, box) {
          // 피그마 393×852 좌표를 실제 화면에 비례로 옮긴다
          double x(double v) => v / 393 * box.maxWidth;
          double y(double v) => v / 852 * box.maxHeight;

          return Stack(
            children: [
              // 왼쪽 위 립 스와치 — 장식. 사진 대신 코랄 덩어리로 그린다.
              Positioned(
                left: x(-56),
                top: y(-16),
                child: Opacity(
                  opacity: hero,
                  child: Transform.scale(
                    scale: 0.9 + 0.1 * hero,
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: x(282),
                      height: y(423),
                      child: const _TintSwatch(),
                    ),
                  ),
                ),
              ),
              // 오른쪽 위 브랜드 로고
              Positioned(
                left: x(206),
                top: y(168),
                child: rise(
                  title,
                  const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('BEAUTY', style: AppText.displaySmall),
                      Text('TALK', style: AppText.displaySmall),
                    ],
                  ),
                ),
              ),
              // 안내 한 줄. 진입 화면과 같은 문장을 쓴다.
              Positioned(
                left: AppShape.gutter,
                right: AppShape.gutter,
                top: y(470),
                child: rise(
                  message,
                  const Text(EntryScreen.hint, style: AppText.entryHint),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 인트로 히어로 이미지 — 피그마 「Editorial coral hero」의 립 스와치 사진.
/// 파일에서 그대로 받아 번들했다 (427:5 의 이미지 채움).
class _TintSwatch extends StatelessWidget {
  const _TintSwatch();

  @override
  Widget build(BuildContext context) => const Image(
        image: AssetImage('assets/images/intro_hero.png'),
        fit: BoxFit.cover,
        alignment: Alignment.topLeft,
      );
}
