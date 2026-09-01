import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import '../services/voice_service.dart';
import 'photo_source.dart';

/// 피그마 "Coral Soft" 공통 부품.
///
/// 접근성 규칙(피그마 「접근성 · 스크린리더 명세」)을 부품 안에 넣어 두었다.
/// 화면에서 매번 챙기면 빠뜨리기 때문이다.
///   · 버튼은 "이름 + 역할" 순으로 읽는다 → Semantics(button: true, label: 이름)
///   · 터치 영역 최소 44px, 셔터·음성 버튼은 88px 이상
///   · 색만으로 상태를 구분하지 않는다 → 선택 상태는 selected 로도 알린다
///   · 장식 그래픽은 접근성 트리에서 제외한다 → ExcludeSemantics

// ---------------------------------------------------------------- 배경
/// 흐릿한 원 세 개가 깔린 진입 화면 배경. 순수 장식이라 접근성 트리에서 뺀다.
///
/// 원의 자리·크기는 피그마 393×852 기준값(546:2~546:4)을 비율로 옮긴 것이다.
class CoralBackdrop extends StatelessWidget {
  const CoralBackdrop({super.key, this.child, this.blobs = true});

  final Widget? child;

  /// false 면 원 없이 배경 그라데이션만 (일반 화면용)
  final bool blobs;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: blobs ? AppColors.entryBackdrop : AppColors.screenBackdrop,
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (blobs)
            const ExcludeSemantics(child: IgnorePointer(child: _Blobs())),
          ?child,
        ],
      ),
    );
  }
}

class _Blobs extends StatelessWidget {
  const _Blobs();

  @override
  Widget build(BuildContext context) {
    final s = MediaQuery.sizeOf(context);
    // 피그마 좌표(393×852)를 화면 비율로 환산한다
    Widget blob(double x, double y, double d, Gradient g) {
      final size = d / 393 * s.width;
      return Positioned(
        left: x / 393 * s.width,
        top: y / 852 * s.height,
        child: ImageFiltered(
          imageFilter: ui.ImageFilter.blur(sigmaX: 50, sigmaY: 50),
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(shape: BoxShape.circle, gradient: g),
          ),
        ),
      );
    }

    return Stack(
      clipBehavior: Clip.none,
      children: [
        blob(-148, -52, 330, AppColors.blobDeep),
        blob(252, 236, 292, AppColors.blobCoral),
        blob(-126, 606, 306, AppColors.blobPink),
      ],
    );
  }
}

/// 좌우 20px 여백. 피그마 콘텐츠 폭 353px 을 그대로 만든다.
class Gutter extends StatelessWidget {
  const Gutter({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: AppShape.gutter),
    child: child,
  );
}

// ---------------------------------------------------------------- 헤더
/// 뒤로 가기 + 화면 제목.
///
/// 「접근성 명세 · 촬영 화면」 낭독 순서 1·2번이다.
/// onBack 이 null 이면 화살표를 자리만 비워 두고 그리지 않는다 (첫 단계).
class ScreenHeader extends StatelessWidget {
  const ScreenHeader({
    super.key,
    required this.title,
    this.onBack,
    this.onMenu,
    this.onHome,
    this.showTitle = true,
  });

  final String title;
  final VoidCallback? onBack;

  /// 오른쪽 메뉴(설정). null 이면 자리만 비운다.
  final VoidCallback? onMenu;

  /// 가운데 워드마크를 눌렀을 때 — 처음으로 돌아간다.
  final VoidCallback? onHome;

  /// false 면 제목을 눈에 보이게 그리지 않는다.
  /// 스크린리더는 그대로 읽는다 — 화면 이름은 지우면 안 되는 정보다.
  final bool showTitle;

  @override
  Widget build(BuildContext context) {
    // 보일 것도 누를 것도 없으면 자리를 차지하지 않는다.
    // 촬영 화면에서 이 빈 줄이 카메라를 그만큼 밀어냈다.
    if (!showTitle && onBack == null && onMenu == null) {
      return const SizedBox.shrink();
    }
    return Container(
      // 카메라 위에 그대로 얹으면 글자가 배경에 묻힌다. 흰 바탕을 깐다.
      color: AppColors.surface,
      // 아래 여백을 조금 더 준다 — 흰 바탕이 그만큼 내려와 카메라와의
      // 경계가 글자에 바짝 붙지 않는다.
      padding: const EdgeInsets.fromLTRB(
        AppShape.gutter,
        8,
        AppShape.gutter,
        16,
      ),
      child: Row(
        children: [
          if (onBack != null)
            Semantics(
              button: true,
              label: '뒤로 가기',
              child: ExcludeSemantics(
                child: InkResponse(
                  onTap: onBack,
                  radius: 24,
                  // 원 없이 화살표만. 터치 영역은 그대로 44px 이다.
                  child: const SizedBox(
                    width: AppShape.minTouch,
                    height: AppShape.minTouch,
                    child: Center(
                      child: Text(
                        '‹',
                        style: TextStyle(
                          fontSize: 30,
                          height: 1.0,
                          fontWeight: FontWeight.w600,
                          color: AppColors.ink,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            )
          else
            const SizedBox(width: AppShape.minTouch, height: AppShape.minTouch),
          // 가운데 워드마크. 화면 제목은 스크린리더에만 남긴다 —
          // 상단에는 앱 이름이 서고, 어느 화면인지는 음성이 말한다.
          Expanded(
            child: Semantics(
              header: true,
              label: title,
              child: ExcludeSemantics(
                child: Center(child: WordMark(onTap: onHome)),
              ),
            ),
          ),
          if (onMenu != null)
            Semantics(
              button: true,
              label: '설정 열기',
              child: ExcludeSemantics(
                child: InkResponse(
                  onTap: onMenu,
                  radius: 24,
                  child: const SizedBox(
                    width: AppShape.minTouch,
                    height: AppShape.minTouch,
                    child: Icon(
                      Icons.menu_rounded,
                      size: 24,
                      color: AppColors.ink,
                    ),
                  ),
                ),
              ),
            )
          else
            const SizedBox(width: AppShape.minTouch, height: AppShape.minTouch),
        ],
      ),
    );
  }
}

/// 상단 가운데 앱 이름. 로고와 같은 글자꼴로 소문자 워드마크를 쓴다.
class WordMark extends StatelessWidget {
  const WordMark({super.key, this.onTap});

  /// 누르면 처음으로. null 이면 그냥 글자다.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final text = _text();
    if (onTap == null) return text;
    return Semantics(
      button: true,
      label: '뷰티톡, 처음으로',
      child: ExcludeSemantics(
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: text,
          ),
        ),
      ),
    );
  }

  /// 인트로 영상의 제목과 같은 짜임이다: 세리프(Playfair Display) ·
  /// 대문자 · **가는 획** · 넓은 자간. 굵게 쓰면 간판이 되고, 가늘게
  /// 벌려 쓰면 이름이 된다.
  static const _spacing = 1.4;
  static const _face = TextStyle(
    fontFamily: 'PlayfairDisplay',
    fontSize: 22,
    height: 1.0,
    fontWeight: FontWeight.w400,
    letterSpacing: _spacing,
    color: AppColors.ink,
  );

  Widget _text() => const FittedBox(
    // 360dp 처럼 좁은 화면에서는 뒤로가기·메뉴 사이 자리가 모자라
    // 31px 넘쳤다. 자간을 줄이는 대신 **그 화면에서만 살짝 줄인다** —
    // 넓은 화면에서는 그대로 22px 이다.
    fit: BoxFit.scaleDown,
    child: Padding(
      // 자간은 **글자 뒤에** 붙는다. 마지막 글자 뒤에도 그만큼 남아서
      // 가운데 정렬을 하면 왼쪽으로 그 절반만큼 밀린다 — 왼쪽에 같은
      // 폭을 넣어 되돌린다.
      padding: EdgeInsets.only(left: _spacing),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('BEAUTY', style: _face),
          // 낱말 사이. 빈칸 문자에도 자간이 붙어 너무 벌어진다 —
          // 폭을 직접 준다.
          SizedBox(width: 8),
          Text('TALK', style: _face),
        ],
      ),
    ),
  );
}

// ---------------------------------------------------------------- 단계 표시
/// 원 안에 번호 + 아래 이름. 피그마 "Step indicator".
///
/// 「접근성 명세」: "전체 N단계 중 M단계, 이름" 한 덩어리로 읽는다.
/// 색만으로 구분하지 않으려고 현재 단계는 채움 + 굵은 라벨로도 표시한다.
class StepIndicator extends StatelessWidget {
  const StepIndicator({super.key, required this.steps, required this.current});

  final List<String> steps;
  final int current;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '전체 ${steps.length}단계 중 ${current + 1}단계, ${steps[current]}',
      child: ExcludeSemantics(
        child: SizedBox(
          // 피그마 상단 바: 원(34) + 6 + 라벨(17 × 1.4 = 23.8) = 63.8
          height: 64,
          child: Row(
            children: [
              for (var i = 0; i < steps.length; i++) ...[
                if (i > 0)
                  const Expanded(
                    child: Padding(
                      // 원(34) 위아래 가운데에 선을 맞춘다
                      padding: EdgeInsets.only(bottom: 30),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: AppColors.border,
                          borderRadius: BorderRadius.all(Radius.circular(1.5)),
                        ),
                        child: SizedBox(height: 3, width: double.infinity),
                      ),
                    ),
                  ),
                _Step(index: i, label: steps[i], active: i == current),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.index, required this.label, required this.active});
  final int index;
  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      // 피그마: 원 중심 간격 − 연결선 = 44. 라벨(2글자 · 17px)이 들어갈 만큼만 준다
      width: 48,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            // 피그마는 그림자 없는 납작한 원이다 — 채움/테두리로만 구분한다
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active ? AppColors.coralDeep : AppColors.surfaceTint,
              border: active
                  ? null
                  : Border.all(color: AppColors.stepEdge, width: 1.5),
            ),
            child: Text(
              '${index + 1}',
              style: AppText.label.copyWith(
                fontSize: 16,
                color: active ? Colors.white : AppColors.inkMuted,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: AppText.label.copyWith(
              fontSize: 17,
              // 색만으로 구분하지 않는다 — 현재 단계는 굵기로도 다르다
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              color: active ? AppColors.brandLabel : AppColors.inkSoft,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 버튼
/// 가로로 꽉 차는 기본 버튼. 높이 59, 반지름 20 (피그마).
///
/// filled=true  → 코랄 채움 + 진한 자주 글자
/// filled=false → 흰 바탕 + 코랄 테두리 + 브랜드 글자
class CoralButton extends StatelessWidget {
  const CoralButton({
    super.key,
    required this.label,
    required this.onTap,
    this.filled = true,
    this.semanticLabel,
    this.icon,
    this.beige = false,
    this.soft = false,
    this.warn = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool filled;

  /// 글자 왼쪽에 붙는 그림. 없어도 된다 — **뜻은 글자가 지고**, 그림은
  /// 눈으로 훑을 때 어느 버튼인지 빨리 찾게 돕는 보조다.
  final IconData? icon;

  /// 연한 베이지 면. 나란히 놓이는 두 버튼을 **둘 다 채워진 면**으로 두되
  /// 서로 다른 색으로 가른다 — 한쪽만 테두리 버튼이면 그쪽이 덜 중요한
  /// 것으로 읽히는데, 둘 다 할 수 있는 일이다.
  final bool beige;

  /// 연한 초록 면. [beige] 와 한 쌍으로 쓴다 — 셔터의 두 색 그대로다.
  final bool soft;

  /// 연한 빨강 면. **되돌리는 버튼**에만 쓴다 — 하던 일을 버리는 자리라
  /// 다른 버튼과 색으로 갈라 둔다.
  final bool warn;

  /// 셔터의 두 색을 한 단계 더 밝힌 값. 면이 밝은 만큼 **글자는 짙게**
  /// 간다 — 흰 글자를 얹으면 대비가 2:1 아래로 떨어져 아예 안 읽힌다.
  /// 아래 조합은 6.8:1 / 6.8:1 이다.
  static const _softFill = Color(0xFFA8E0C4);
  static const _beigeFill = Color(0xFFF4E6CE);
  static const _warnFill = Color(0xFFFDF0EE);
  /// 연한 빨강 면에 두르는 빨간 테두리. 되돌리는 버튼은 색만으로도
  /// 눈에 걸려야 해서 윤곽까지 준다.
  static const _warnEdge = Color(0xFFC24A3E);

  /// 화면에 보이는 글자와 읽어 줄 이름이 다를 때만 쓴다
  final String? semanticLabel;

  Color get _inkColor {
    if (beige || soft || warn) return AppColors.ink; // 연한 면에는 검은 글자
    return filled ? AppColors.brandDark : AppColors.brand;
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel ?? label,
      child: ExcludeSemantics(
        child: Material(
          // 초록 개편안: 채움은 짙은 초록, 보조는 옅은 초록 면이다.
          // (코랄 때는 보조가 흰 면이었다)
          color: warn
              ? _warnFill
              : beige
              ? _beigeFill
              : soft
              ? _softFill
              : filled
              ? AppColors.coral
              : AppColors.surfaceTint,
          borderRadius: BorderRadius.circular(AppShape.buttonRadius),
          elevation: 0,
          child: InkWell(
            onTap: () {
              HapticFeedback.selectionClick();
              onTap();
            },
            borderRadius: BorderRadius.circular(AppShape.buttonRadius),
            child: Container(
              height: AppShape.buttonHeight,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppShape.buttonRadius),
                border: warn
                    ? Border.all(color: _warnEdge, width: 1.5)
                    : (filled || beige || soft)
                        ? null
                        : Border.all(color: AppColors.outline, width: 1.5),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 20, color: _inkColor),
                    const SizedBox(width: 8),
                  ],
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: AppText.button.copyWith(color: _inkColor),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 셔터. 100px 링 + 88px 채움 (「접근성 명세」의 88px 이상 규정).
/// 글자는 두지 않는다 — 이름은 스크린리더가 읽고, 눈에는 카메라 아이콘이면 충분하다.
class ShutterButton extends StatelessWidget {
  const ShutterButton({
    super.key,
    required this.onTap,
    this.semanticLabel = '촬영하기',
  });

  final VoidCallback onTap;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: ExcludeSemantics(
        child: SizedBox(
          width: 100,
          height: 100,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Material(
                shape: const CircleBorder(),
                clipBehavior: Clip.antiAlias,
                color: Colors.transparent,
                child: InkWell(
                  onTap: onTap,
                  child: Ink(
                    width: AppShape.bigTouch,
                    height: AppShape.bigTouch,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: AppColors.shutter,
                      boxShadow: [
                        BoxShadow(
                          color: Color(0x3D6B4E2E),
                          blurRadius: 16,
                          offset: Offset(0, 6),
                        ),
                      ],
                    ),
                    // 카메라 그림은 두지 않는다 — 무엇을 하는 버튼인지는
                    // 자리와 음성 안내가 이미 말한다.
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 분석 중 화면 — 방금 찍은 사진이 가운데에 올라가고 스캔 선이 훑는다.
/// "무엇을 분석하는지" 를 눈으로 보여 주는 게 목적이라, 사진이 없으면
/// (테스트·오류) 블롭 위로 스캔 선만 지나간다.
class ScanningPhoto extends StatefulWidget {
  const ScanningPhoto({super.key, this.path});
  final String? path;

  @override
  State<ScanningPhoto> createState() => _ScanningPhotoState();
}

class _ScanningPhotoState extends State<ScanningPhoto>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.path;
    // **사진이 있으면 사진이 화면을 다 덮는다.** 예전에는 초록 배경 위에
    // 액자처럼 얹혀 있었는데, 그러면 방금 무엇을 찍었는지가 작아서 안 보이고
    // 화면의 대부분이 배경이었다. 사진이 아직 없을 때만 배경을 그린다.
    if (p == null) {
      return Stack(
        fit: StackFit.expand,
        children: [const CoralBlobs(), _sweep(const SizedBox.expand())],
      );
    }
    return _sweep(
      Image(
        image: photoProvider(p),
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) =>
            const ColoredBox(color: AppColors.surfaceSoft),
      ),
    );
  }

  /// 사진(또는 빈 면) 위로 스캔 선이 오가고, 선 아래쪽은 살짝 어둡다
  Widget _sweep(Widget child) {
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        AnimatedBuilder(
          animation: _c,
          builder: (context, _) => Align(
            alignment: Alignment(0, _c.value * 2 - 1),
            child: const ScanBeam(),
          ),
        ),
        AnimatedBuilder(
          animation: _c,
          builder: (context, _) => Align(
            alignment: Alignment.bottomCenter,
            child: FractionallySizedBox(
              heightFactor: 1 - _c.value,
              child: const ColoredBox(color: Color(0x1F121A15)),
            ),
          ),
        ),
      ],
    );
  }
}

/// 촬영 면의 흐릿한 블롭 (피그마 379:15~379:19 색). 순수 장식.
/// 질문·분석 화면의 배경이다 — 두 탭이 같은 그림을 쓴다.
class CoralBlobs extends StatelessWidget {
  const CoralBlobs({super.key});

  @override
  Widget build(BuildContext context) =>
      const CustomPaint(painter: _BlobPainter());
}

class _BlobPainter extends CustomPainter {
  const _BlobPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    canvas.drawRect(Offset.zero & size, Paint()..color = AppColors.surfaceSoft);
    void blob(
      double cx,
      double cy,
      double rw,
      double rh,
      Color c,
      double blur,
    ) {
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(cx * w, cy * h),
          width: rw * w,
          height: rh * h,
        ),
        Paint()
          ..color = c
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur),
      );
    }

    blob(0.80, 0.12, 0.70, 0.50, const Color(0xD942805A), 28); // 코랄, 오른쪽 위
    blob(0.12, 0.86, 0.80, 0.52, const Color(0xAD2E6B45), 30); // 라즈베리, 왼쪽 아래
    blob(0.92, 0.82, 0.46, 0.34, const Color(0xCCB9D8C3), 26); // 살구, 오른쪽 아래
    blob(0.30, 0.45, 0.70, 0.45, const Color(0xC79AC489), 26); // 연분홍, 가운데
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(0.45 * w, 0.14 * h),
        width: 0.5 * w,
        height: 0.18 * h,
      ),
      Paint()..color = Colors.white.withValues(alpha: 0.5), // 광택
    );
  }

  @override
  bool shouldRepaint(covariant _BlobPainter old) => false;
}

/// 위아래로 오가는 스캔 띠 (피그마 434:2)
class ScanBeam extends StatelessWidget {
  const ScanBeam({super.key});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 72,
      child: Stack(
        alignment: Alignment.center,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  AppColors.scanLine.withValues(alpha: 0),
                  AppColors.scanLine.withValues(alpha: 0.26),
                  AppColors.scanLine.withValues(alpha: 0),
                ],
              ),
            ),
            child: const SizedBox(width: double.infinity, height: 72),
          ),
          Container(
            height: 2,
            color: AppColors.scanLine.withValues(alpha: 0.92),
          ),
        ],
      ),
    );
  }
}

/// 결과 카드. 피그마 399:2 — 번호 배지 · 제목 / 상태 문장 / 할 일 칩,
/// 왼쪽 아래에 코랄 번짐(399:3). 화장품·메이크업 결과가 같은 카드를 쓴다.
/// 글자는 저시력 사용자 기준으로 22/19/18px.
class ResultCard extends StatelessWidget {
  const ResultCard({
    super.key,
    this.badge,
    required this.title,
    this.body,
    this.action,
    this.top,
    this.onTap,
    this.selected = false,
    this.spoken,
  });

  /// 40px 원 안에 들어갈 것 (아이콘 등). null 이면 원을 그리지 않는다 —
  /// 번호는 없앴다. 순서를 눈으로 세게 하는 것 말고는 하는 일이 없었다.
  final Widget? badge;
  final String title;

  /// 상태 문장. 화면에 안 쓰고 음성으로만 말하는 경우 생략한다.
  final String? body;

  /// 할 일 칩. 없으면 안 그린다.
  final String? action;

  /// 카드 맨 위 (제품 사진 등)
  final Widget? top;

  /// 누르면 할 일. 결과 화면에서 **이 항목의 자리만 사진에 짚기** 위해 쓴다.
  final VoidCallback? onTap;

  /// 지금 짚혀 있는 항목인가. 테두리로 표시한다.
  final bool selected;

  /// 읽어 줄 말. 화면에 안 쓰는 문장까지 여기에 담는다.
  ///
  /// 결과 화면은 작은 글씨를 걷어내고 부위 이름만 크게 남기는데, **읽어 주는
  /// 내용까지 같이 사라지면 안 된다.** 이 앱에서는 그게 본문이다.
  final String? spoken;

  @override
  Widget build(BuildContext context) {
    final a = action;
    final b = body;
    return Semantics(
      // 누를 수 있는 카드는 그렇다고 알려 준다. 화면을 못 보는 사용자에게
      // '누를 수 있음' 이 안 읽히면 이 기능은 없는 것과 같다.
      button: onTap != null,
      label: onTap == null
          ? (spoken ?? '$title. ${b ?? ''} ${a ?? ''}')
          : '${spoken ?? '$title. ${b ?? ''} ${a ?? ''}'} '
                '두 번 누르면 그 자리를 짚어 줍니다.',
      child: ExcludeSemantics(
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: AppColors.surfaceCard,
              borderRadius: BorderRadius.circular(AppShape.cardRadius),
              border: Border.all(
                color: selected ? AppColors.brand : AppColors.cardEdge,
                width: selected ? 2 : 1,
              ),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x0A000000),
                  blurRadius: 5,
                  offset: Offset(0, 2),
                ),
                BoxShadow(
                  color: AppColors.cardShadow,
                  blurRadius: 26,
                  offset: Offset(0, 12),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppShape.cardRadius),
              child: Stack(
                children: [
                  // 왼쪽 아래 코랄 번짐
                  const Positioned(
                    left: -10,
                    bottom: -50,
                    child: _CoralAccent(),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (top != null) ...[top!, const SizedBox(height: 16)],
                        Row(
                          children: [
                            if (badge != null) ...[
                              Container(
                                width: 40,
                                height: 40,
                                alignment: Alignment.center,
                                decoration: const BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: AppColors.badge,
                                  boxShadow: [
                                    BoxShadow(
                                      color: AppColors.cardShadow,
                                      blurRadius: 10,
                                      offset: Offset(0, 3),
                                    ),
                                  ],
                                ),
                                child: IconTheme(
                                  data: const IconThemeData(
                                    color: Colors.white,
                                    size: 24,
                                  ),
                                  child: badge!,
                                ),
                              ),
                              const SizedBox(width: 14),
                            ],
                            Expanded(
                              child: Text(title, style: AppText.resultTitle),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        if (b != null) Text(b, style: AppText.resultBody),
                        if (a != null && a.isNotEmpty) ...[
                          SizedBox(height: b == null ? 0 : 14),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.surfaceChip,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: AppColors.chipEdge),
                            ),
                            child: Text(
                              a,
                              style: AppText.resultAction.copyWith(
                                color: AppColors.brandChip,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 결과 카드 왼쪽 아래의 코랄 번짐 (#FF7464 45%, blur 26)
class _CoralAccent extends StatelessWidget {
  const _CoralAccent();

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ImageFiltered(
      imageFilter: ui.ImageFilter.blur(sigmaX: 26, sigmaY: 26),
      child: Container(
        width: 170,
        height: 130,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: Color(0x7342805A),
        ),
      ),
    ),
  );
}

/// 사진 위에 박스를 그린다 — "어디를 보고 판단했는지 / 어디가 문제인지".
/// cover 로 잘리는 부분을 감안해 원본 기준 0..1 좌표를 화면 좌표로 옮긴다.
/// 결과 화면에서 **문제가 있는 자리**를 사진 위에 짚어 준다.
///
/// 서버가 좌표(`box`)를 주면 그걸 쓰고, 안 주면 부위 이름으로 자리를 어림한다
/// (`ProblemSpot.zoneOf`). 어림한 자리는 **일부러 넉넉하고 흐리게** 그린다 —
/// 딱 떨어지는 네모를 그리면 서버가 재지도 않은 좌표를 잰 것처럼 보인다.
///
/// 번호는 아래 카드 순서와 같다. 눈이 보이지 않는 사용자에게는 TTS 가 읽어
/// 주지만, 옆에서 봐 주는 사람이 "두 번째 게 여기" 라고 짚으려면 번호가 있어야 한다.
class ShotWithBoxes extends StatefulWidget {
  const ShotWithBoxes({
    super.key,
    required this.path,
    this.spots = const [],
    this.active,
  });

  final String path;
  final List<ProblemSpot> spots;

  /// 지금 짚어 볼 항목 (없으면 전부 같은 무게로 그린다).
  ///
  /// 여럿을 한꺼번에 짚으면 어느 게 어느 카드인지 눈으로 못 잇는다.
  /// 카드를 누르면 그 자리만 남기고 나머지는 물러난다.
  final int? active;

  @override
  State<ShotWithBoxes> createState() => _ShotWithBoxesState();
}

/// 사진 위에 짚을 자리 하나.
class ProblemSpot {
  const ProblemSpot({required this.region, this.box});

  /// 서버가 준 부위 이름 ("왼쪽 볼 아래" 처럼 자유 문장이다).
  final String region;

  /// 서버가 준 좌표 (0~1, 원본 사진 기준). 없을 수 있다.
  final Rect? box;

  /// 좌표가 없을 때 쓰는 자리. 없으면 짚지 않는다 —
  /// 어디인지 모르면서 아무 데나 동그라미를 치면 그게 더 나쁘다.
  Rect? get area => box ?? zoneOf(region);

  /// 좌표가 정확한가. 어림한 자리는 더 흐리고 넓게 그린다.
  bool get exact => box != null;

  /// 부위 이름 → 얼굴에서의 대략적인 자리 (0~1, 사진 기준).
  ///
  /// 촬영 화면이 얼굴을 가운데로 잡아 주기 때문에 대체로 맞아떨어진다.
  /// 서버가 좌표를 주기 시작하면 이 표는 저절로 안 쓰인다.
  static Rect? zoneOf(String region) {
    final r = region.replaceAll(' ', '');
    // 왼쪽/오른쪽은 **찍힌 사람 기준**이다. 아래 표가 mediapipe 의 좌우 이름을
    // 그대로 따라가므로 사진에서 어느 쪽에 그릴지도 저절로 맞는다 —
    // 거울상 여부를 따로 따질 필요가 없다.
    final left = r.contains('왼') || r.contains('좌');
    final right = r.contains('오른') || r.contains('우');

    // 긴 이름이 먼저다 — '입술' 이 '입' 보다, '눈썹' 이 '눈' 보다 앞이어야
    // 짧은 쪽이 먼저 걸려서 엉뚱한 자리를 짚지 않는다.
    for (final (keys, mid, l, rt) in _zoneTable) {
      if (!keys.any(r.contains)) continue;
      if (left && l != null) return l;
      if (right && rt != null) return rt;
      return mid ?? l ?? rt;
    }
    return null;
  }

  /// (키워드, 좌우 안 적혔을 때, 왼쪽, 오른쪽) — 전부 0~1, 사진 기준.
  ///
  /// 손으로 어림한 값이 아니라 `assets/hologram/demo_face_points.json` 의
  /// **실제 얼굴 랜드마크**에서 뽑았다. 처음엔 눈대중으로 넣었다가 입술이
  /// 턱 아래에, 볼이 목에 찍혀서 다시 계산했다. 촬영 화면이 얼굴을 가운데로
  /// 잡아 주기 때문에 다른 사람 사진에서도 대체로 맞아떨어진다.
  static const _zoneTable = <(List<String>, Rect?, Rect?, Rect?)>[
    (['이마'], Rect.fromLTRB(0.266, 0.223, 0.745, 0.345), null, null),
    (
      ['눈썹'],
      null,
      Rect.fromLTRB(0.535, 0.284, 0.730, 0.359),
      Rect.fromLTRB(0.270, 0.302, 0.471, 0.376),
    ),
    (
      ['눈'],
      null,
      Rect.fromLTRB(0.551, 0.344, 0.676, 0.403),
      Rect.fromLTRB(0.327, 0.358, 0.457, 0.415),
    ),
    (
      ['볼', '뺨'],
      null,
      Rect.fromLTRB(0.634, 0.385, 0.764, 0.547),
      Rect.fromLTRB(0.239, 0.410, 0.392, 0.526),
    ),
    (['코'], Rect.fromLTRB(0.437, 0.354, 0.594, 0.532), null, null),
    (['입술', '입'], Rect.fromLTRB(0.415, 0.528, 0.621, 0.615), null, null),
    (['턱'], Rect.fromLTRB(0.332, 0.586, 0.672, 0.687), null, null),
    // 얼굴 전체. 격자의 바깥 사각형과 같다.
    (
      ['피부', '베이스', '전체'],
      Rect.fromLTRB(0.256, 0.243, 0.744, 0.667),
      null,
      null,
    ),
  ];
}

class _ShotWithBoxesState extends State<ShotWithBoxes> {
  Size? _imgSize; // cover 매핑에 원본 크기가 필요하다

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    try {
      final buf = await ui.ImmutableBuffer.fromUint8List(
        await readPhotoBytes(widget.path),
      );
      final desc = await ui.ImageDescriptor.encoded(buf);
      if (mounted) {
        setState(
          () => _imgSize = Size(desc.width.toDouble(), desc.height.toDouble()),
        );
      }
      desc.dispose();
      buf.dispose();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final size = _imgSize;
    final spots = [
      for (final s in widget.spots)
        if (s.area != null) s,
    ];
    return Stack(
      fit: StackFit.expand,
      children: [
        Image(
          image: photoProvider(widget.path),
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => const SizedBox.expand(),
        ),
        if (spots.isNotEmpty && size != null)
          CustomPaint(painter: _SpotsPainter(spots, size, widget.active)),
      ],
    );
  }
}

class _SpotsPainter extends CustomPainter {
  const _SpotsPainter(this.spots, this.img, this.active);
  final List<ProblemSpot> spots;
  final Size img;
  final int? active;

  /// 얼룩 한가운데의 진하기. 이보다 옅으면 사진 위에서 안 보이고,
  /// 진하면 그 자리 피부가 안 보여서 뭐가 문제인지 판단할 수가 없다.
  static const _ink = 0.46;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = (size.width / img.width) > (size.height / img.height)
        ? size.width / img.width
        : size.height / img.height;
    final dx = (size.width - img.width * scale) / 2;
    final dy = (size.height - img.height * scale) / 2;
    Offset map(double nx, double ny) =>
        Offset(nx * img.width * scale + dx, ny * img.height * scale + dy);

    final only = active;
    for (var i = 0; i < spots.length; i++) {
      final b = spots[i].area!;
      final r = Rect.fromPoints(map(b.left, b.top), map(b.right, b.bottom));

      // 고른 게 있으면 그것만 한 단계 올리고 나머지는 확실히 내린다.
      // 둘의 차이가 작으면 눌러도 아무것도 안 짚힌 것처럼 보인다 —
      // 실제로 0.3배로 뒀다가 구분이 안 돼서 벌렸다. 그래도 **아주 지우지는
      // 않는다.** 흔적이 없으면 "다른 데도 있었나" 를 알 수 없다.
      final ink = only == null ? _ink : (only == i ? _ink * 1.5 : _ink * 0.28);

      // **네모로 칠하지 않는다.** 테두리를 두른 구역은 "여기를 정확히 쟀다" 는
      // 말이 되는데 부위 이름만 받은 자리는 그렇지 않고, 무엇보다 어디가
      // 문제인지가 아니라 네모가 먼저 보인다. 가운데가 진하고 밖으로 스미는
      // 얼룩이라야 "이 언저리" 로 읽히고, 화장품 앱에도 맞는 언어다.
      final paint = Paint()
        ..shader = RadialGradient(
          colors: [
            AppColors.coralDeep.withValues(alpha: ink),
            AppColors.coral.withValues(alpha: ink * 0.72),
            AppColors.coral.withValues(alpha: 0),
          ],
          stops: const [0.0, 0.55, 1.0],
        ).createShader(r);
      canvas.drawOval(r, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _SpotsPainter old) =>
      old.spots != spots || old.img != img || old.active != active;
}

// ---------------------------------------------------------------- 카드·면
/// 코랄 소프트 카드. 결과·질문 화면이 공통으로 쓴다.
class CoralCard extends StatelessWidget {
  const CoralCard({
    super.key,
    required this.child,
    this.color = AppColors.surfaceCard,
    this.padding = const EdgeInsets.all(18),
  });

  final Widget child;
  final Color color;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(AppShape.cardRadius),
        border: Border.all(color: AppColors.cardEdge),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0A000000),
            blurRadius: 5,
            offset: Offset(0, 2),
          ),
          BoxShadow(
            color: AppColors.cardShadow,
            blurRadius: 26,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: child,
    );
  }
}

/// 카메라 위에 겹치는 촬영 안내 — 모서리 갈고리 + 가운데 안내선.
///
/// 배경을 그리지 않는다. 카메라는 화면 전체에 깔려 있고 이건 그 위에만 얹힌다.
/// 「접근성 명세」대로 미리보기는 포커스 대상이 아니라 통째로 트리에서 뺀다.
class CaptureGuides extends StatelessWidget {
  const CaptureGuides({super.key, this.guide});

  /// 가운데 안내 (제품 사각형 / 얼굴 타원)
  final Widget? guide;

  /// 스크림이 비워 두는 구간에 맞춘다 — 위아래 밝은 띠를 피해 가운데에 뜬다.
  /// 위는 단계 표시까지, 아래는 셔터 줄까지가 밝은 띠다.
  static const _band = 0.50;
  static const _center = -0.17;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: IgnorePointer(
        child: Align(
          alignment: const Alignment(0, _center),
          child: FractionallySizedBox(
            widthFactor: 0.88,
            heightFactor: _band,
            child: Stack(
              fit: StackFit.expand,
              children: [const CornerBrackets(), ?guide],
            ),
          ),
        ),
      ),
    );
  }
}

/// 말하는 동안 화면 가운데에 뜨는 초록 파형.
///
/// 화면을 못 보는 사용자에게는 소리가 곧 상태지만, 곁에서 보는 사람에게는
/// 앱이 말하고 있다는 표시가 하나도 없었다. 이 파형이 그 자리를 맡는다.
///
/// 파형은 [VoiceService.speechPulse] 로 뛴다 — 읽는 낱말이 바뀔 때마다
/// 솟았다가 가라앉는다. 그래서 말의 박자를 따라 움직인다.
class SpeakingWaves extends StatefulWidget {
  const SpeakingWaves({super.key});

  @override
  State<SpeakingWaves> createState() => _SpeakingWavesState();
}

class _SpeakingWavesState extends State<SpeakingWaves>
    with SingleTickerProviderStateMixin {
  Ticker? _tick;

  @override
  void initState() {
    super.initState();
    // **initState 에서 만들어 켠다.** late final 로 두면 아무도 읽지 않아
    // 영영 만들어지지 않는다 — 그래서 파형이 한 번도 다시 그려지지 않았다.
    _tick = createTicker((_) {
      VoiceService.instance.decaySpeechPulse();
      if (mounted) setState(() {});
    })..start();
  }

  @override
  void dispose() {
    _tick?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = VoiceService.instance;
    // [VoiceService.isVoicing] — 대기열 깃발(isSpeaking)이 아니라 **엔진이
    // 실제로 낱말을 읽고 있는가**다. 이 기기에서 speak() 가 낭독이 끝나기
    // 전에 돌아와서, 깃발만 보면 말하는 중인데 파형이 사라졌다.
    if (!v.isVoicing) return const SizedBox.shrink();
    // **말하기 신호 하나로 뜨고 사라진다.** TTS 출력의 음량은 받아올 수
    // 없고 낱말 신호(setProgressHandler)도 엔진에 따라 안 온다. 그런 것에
    // 기대지 않고, 말이 시작되면 나오고 끝나면 사라진다 — 그 사이에는
    // 늘 흐르고, 낱말 신호가 오는 기기에서는 그 위로 솟는다.
    final level = (0.62 + 0.38 * v.speechPulse).clamp(0.0, 1.0);
    return IgnorePointer(
      child: ExcludeSemantics(
        child: Center(
          // 배경을 깔지 않는다 — 아래 화면이 그대로 보여야 한다.
          // 대신 파형 자체를 크게 그려 어느 배경에서도 눈에 든다.
          child: SizedBox(
            width: double.infinity,
            child: VoiceWaves(level: level, height: 240),
          ),
        ),
      ),
    );
  }
}

/// 말하는 동안 흔들리는 초록 파형.
///
/// **[level] 이 0 이면 거의 평평하다.** 가만히 출렁이는 파형은 장식일 뿐이고,
/// 마이크가 안 잡히는 상황(권한 거부·엔진 먹통)을 사용자가 알아챌 방법이
/// 없어진다. 실제로 소리가 들어올 때만 커져야 "듣고 있다" 는 신호가 된다.
class VoiceWaves extends StatefulWidget {
  const VoiceWaves({super.key, required this.level, this.height = 92});

  /// 지금 들어오는 소리 크기 0~1 ([VoiceService.soundLevel]).
  final double level;
  final double height;

  @override
  State<VoiceWaves> createState() => _VoiceWavesState();
}

class _VoiceWavesState extends State<VoiceWaves>
    with SingleTickerProviderStateMixin {
  /// **감기지 않는 시계.** 0~1 을 도는 값으로 파형을 그리면, 되감기는
  /// 순간 줄마다 위상이 제각각 튀어 물결이 뚝 끊긴다 (줄마다 속도가
  /// 달라서 한 바퀴가 딱 맞아떨어지지 않는다). 계속 커지는 초를 쓰면
  /// 끊길 자리가 아예 없다.
  double _t = 0;

  /// 화면에 그리는 세기. 들어오는 값이 튀어도 여기서 부드럽게 따라간다 —
  /// 소리 크기는 프레임마다 크게 흔들려서, 그대로 그리면 파형이 덜덜 떤다.
  double _shown = 0;

  Ticker? _tick;

  @override
  void initState() {
    super.initState();
    _tick = createTicker((elapsed) {
      _t = elapsed.inMicroseconds / 1e6;
      _shown += (widget.level - _shown) * 0.12;
      if (mounted) setState(() {});
    })
      ..start();
  }

  @override
  void dispose() {
    _tick?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: SizedBox(
        height: widget.height,
        width: double.infinity,
        child: CustomPaint(
          painter: _WavePainter(phase: _t / 2.6, level: _shown),
        ),
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  const _WavePainter({required this.phase, required this.level});

  final double phase;
  final double level;

  @override
  void paint(Canvas canvas, Size size) {
    // 세 줄이 서로 다른 속도·높이로 흐른다. 한 줄이면 그래프처럼 보이고,
    // 여러 줄이 어긋나 흘러야 소리처럼 읽힌다.
    // 초록 두 줄에 베이지 한 줄을 섞는다. 같은 계열만 겹치면 한 덩어리로
    // 보이는데, 다른 색이 하나 끼면 줄이 몇 개인지가 눈에 들어온다.
    const lines = [
      (1.0, 0.0, 1.00, AppColors.coralDeep),
      (1.6, 0.35, 0.72, AppColors.coralLight),
      (0.7, 0.68, 0.72, Color(0xFFD9C09A)),
    ];
    for (final (speed, lead, weight, color) in lines) {
      final amp = size.height * (0.06 + 0.40 * level) * weight;
      final mid = size.height / 2;
      final path = Path()..moveTo(0, mid);
      for (var x = 0.0; x <= size.width; x += 3) {
        final t = x / size.width;
        final y =
            mid +
            amp *
                math.sin((t * 2.2 + (phase * speed) + lead) * 2 * math.pi) *
                // 양 끝을 잡아 둬야 화면 가장자리에서 잘린 것처럼 안 보인다
                math.sin(t * math.pi);
        path.lineTo(x, y);
      }
      // **가는 심지 + 넓은 잔상.** 넓은 띠는 아주 옅게 깔아 지나간 자리만
      // 남기고, 그 위에 가는 선을 진하게 얹는다 — 굵은 띠를 통째로 옅게
      // 칠하면 무엇이 그려졌는지 안 보인다.
      // 굵기는 그대로 두고 진하기만 올린다.
      final a = 0.42 + 0.58 * level;
      for (final (px, fade) in [(20.0, 0.18), (11.0, 0.30), (3.4, 1.0)]) {
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = px * weight
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round
            ..color = color.withValues(alpha: (a * fade).clamp(0, 1)),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _WavePainter old) =>
      old.phase != phase || old.level != level;
}

/// 촬영까지 3·2·1. 카메라 위에 큰 흰 숫자 하나만 띄운다.
///
/// 「접근성 명세」: 숫자만 읽고 다른 요소는 포커스에서 뺀다. 화면을 못 보는
/// 사용자에게 이 셋은 자세를 잡을 시간이고, 음성은 [AppState] 가 낸다 —
/// 여기서 또 읽으면 같은 숫자를 두 번 듣는다.
///
/// 모션 축소 설정이면 커졌다 작아지는 연출을 건너뛴다. 숫자는 그대로 뜬다.
class CountdownOverlay extends StatelessWidget {
  const CountdownOverlay({super.key, required this.value});

  /// 3 · 2 · 1. null 이면 아무것도 그리지 않는다.
  final int? value;

  @override
  Widget build(BuildContext context) {
    final n = value;
    if (n == null) return const SizedBox.shrink();
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final text = Text(
      '$n',
      key: ValueKey(n),
      style: const TextStyle(
        fontSize: 132,
        height: 1.0,
        fontWeight: FontWeight.w700,
        color: Colors.white,
        shadows: [
          Shadow(blurRadius: 28, color: Color(0x8A000000)),
          Shadow(blurRadius: 6, color: Color(0x66000000)),
        ],
      ),
    );
    return ExcludeSemantics(
      child: IgnorePointer(
        child: Container(
          // 숫자만 남게 화면을 눌러 둔다. 밝은 벽·흰 세면대를 비출 때
          // 흰 숫자가 배경에 묻히던 것도 이걸로 같이 해결된다.
          color: const Color(0x73000000),
          alignment: Alignment.center,
          child: reduced
              ? text
              : AnimatedSwitcher(
                  duration: const Duration(milliseconds: 260),
                  transitionBuilder: (child, t) => FadeTransition(
                    opacity: t,
                    child: ScaleTransition(
                      scale: Tween<double>(begin: 1.35, end: 1.0).animate(t),
                      child: child,
                    ),
                  ),
                  child: text,
                ),
        ),
      ),
    );
  }
}

/// 카메라 조준선 — 가운데 **노란 십자 + 네 귀퉁이 갈고리**.
///
/// 예전에는 화면을 크게 두르는 흰 사각형(+ 점선 타원/사각)이었는데,
/// 큰 테두리는 "이 안에 다 넣어라" 로 읽혀서 얼굴을 멀리 두게 만들었다.
/// 작은 십자는 **여기를 겨눠라** 한 가지만 말한다.
///
/// 노란색인 이유: 카메라가 비추는 건 대개 피부·화장품·벽이라 흰색은 묻힌다.
/// 노랑은 그 어느 것과도 겹치지 않아 어두운 데서도 밝은 데서도 남는다.
class AimReticle extends StatelessWidget {
  const AimReticle({super.key});

  /// 조준선이 차지하는 정사각형 한 변
  static const size = 116.0;

  /// 연한 초록. 카메라가 비추는 피부·화장품·벽 어느 것과도 겹치지 않아
  /// 어두운 데서도 밝은 데서도 남는다.
  static const color = Color(0xFF9FE0BC);

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: IgnorePointer(
        child: Align(
          // 위아래 밝은 띠(제목·셔터)를 피해 가운데보다 조금 위
          alignment: const Alignment(0, -0.17),
          child: SizedBox(
            width: size,
            height: size,
            child: CustomPaint(painter: _ReticlePainter()),
          ),
        ),
      ),
    );
  }
}

class _ReticlePainter extends CustomPainter {
  /// 귀퉁이 갈고리 길이 · 십자가 상자에서 차지하는 비율 · 굵기
  ///
  /// 십자는 짧은 '+' 가 아니라 **상자를 가로지르는 긴 선**이다. 짧은 십자는
  /// 그 점 하나만 가리키는데, 긴 선은 화면을 사분면으로 나눠 "이 안에 넣어라"
  /// 까지 같이 말한다. 선은 얇게 — 굵으면 조준선이 아니라 그림이 된다.
  static const _hook = 30.0;
  static const _armRatio = 0.86;
  static const _w = 2.0;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = AimReticle.color
      ..strokeWidth = _w
      ..strokeCap = StrokeCap.square
      ..style = PaintingStyle.stroke;

    // 어두운 화면에도 밝은 화면에도 남게 얇은 그림자를 먼저 깐다.
    final shadow = Paint()
      // 크림색은 밝은 배경에 묻히기 쉬워 그림자를 조금 더 진하게 잡는다.
      ..color = const Color(0x73000000)
      ..strokeWidth = _w + 2.0
      ..strokeCap = StrokeCap.square
      ..style = PaintingStyle.stroke;

    final w = size.width, h = size.height;
    final cx = w / 2, cy = h / 2;

    void hooks(Paint paint) {
      // 왼위 · 오른위 · 왼아래 · 오른아래
      for (final (x, y, dx, dy) in [
        (0.0, 0.0, 1.0, 1.0),
        (w, 0.0, -1.0, 1.0),
        (0.0, h, 1.0, -1.0),
        (w, h, -1.0, -1.0),
      ]) {
        canvas.drawLine(Offset(x, y), Offset(x + _hook * dx, y), paint);
        canvas.drawLine(Offset(x, y), Offset(x, y + _hook * dy), paint);
      }
    }

    void cross(Paint paint) {
      final half = w * _armRatio / 2;
      canvas.drawLine(Offset(cx - half, cy), Offset(cx + half, cy), paint);
      canvas.drawLine(Offset(cx, cy - half), Offset(cx, cy + half), paint);
    }

    hooks(shadow);
    cross(shadow);
    hooks(p);
    cross(p);
  }

  @override
  bool shouldRepaint(covariant _ReticlePainter old) => false;
}

/// 네 모서리의 흰 갈고리. 피그마 30×4 / 4×30, 안쪽으로 18px.
class CornerBrackets extends StatelessWidget {
  const CornerBrackets({super.key});

  static const _len = 30.0;
  static const _thick = 4.0;
  static const _inset = 22.0;

  Widget _bar(double w, double h) => Container(
    width: w,
    height: h,
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(2),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned(left: _inset, top: _inset, child: _bar(_len, _thick)),
        Positioned(left: _inset, top: _inset, child: _bar(_thick, _len)),
        Positioned(right: _inset, top: _inset, child: _bar(_len, _thick)),
        Positioned(right: _inset, top: _inset, child: _bar(_thick, _len)),
        Positioned(left: _inset, bottom: _inset, child: _bar(_len, _thick)),
        Positioned(left: _inset, bottom: _inset, child: _bar(_thick, _len)),
        Positioned(right: _inset, bottom: _inset, child: _bar(_len, _thick)),
        Positioned(right: _inset, bottom: _inset, child: _bar(_thick, _len)),
      ],
    );
  }
}

/// 제품을 맞출 점선 사각형.
/// 피그마 555:8 은 353×398 면 안에서 170×220 이다 — 비율로 옮겨서
/// 면이 낮은 기기에서도 잘리지 않게 한다.
class ProductGuide extends StatelessWidget {
  const ProductGuide({super.key});

  @override
  Widget build(BuildContext context) => const Center(
    child: FractionallySizedBox(
      heightFactor: 0.78,
      child: AspectRatio(aspectRatio: 170 / 220, child: _Dashed(radius: 16)),
    ),
  );
}

/// 얼굴을 맞출 안내.
/// 촬영 중에는 점선 타원(피그마 553:33, 183×230),
/// 분석 중에는 실선 이중 링(피그마 380:36·380:37)이다.
class FaceGuide extends StatelessWidget {
  const FaceGuide({super.key, this.dashed = true});

  final bool dashed;

  @override
  Widget build(BuildContext context) {
    if (dashed) {
      return const Center(
        child: FractionallySizedBox(
          heightFactor: 0.86,
          child: AspectRatio(
            aspectRatio: 183 / 230,
            child: _Dashed(oval: true),
          ),
        ),
      );
    }
    return Center(
      child: FractionallySizedBox(
        widthFactor: 221 / 353,
        heightFactor: 272 / 391,
        child: Stack(
          alignment: Alignment.center,
          children: [
            _Ring(color: Colors.white.withValues(alpha: 0.40), width: 2),
            FractionallySizedBox(
              widthFactor: 181 / 221,
              heightFactor: 232 / 272,
              child: _Ring(
                color: Colors.white.withValues(alpha: 0.90),
                width: 3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 실선 타원 테두리. BoxShape.circle 은 짧은 변에 맞춘 원이라 못 쓴다.
class _Ring extends StatelessWidget {
  const _Ring({required this.color, required this.width});
  final Color color;
  final double width;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _OvalOutline(color, width),
    child: const SizedBox.expand(),
  );
}

class _OvalOutline extends CustomPainter {
  _OvalOutline(this.color, this.width);
  final Color color;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawOval(
      Offset.zero & size,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = width,
    );
  }

  @override
  bool shouldRepaint(covariant _OvalOutline old) =>
      old.color != color || old.width != width;
}

class _Dashed extends StatelessWidget {
  const _Dashed({this.radius = 0, this.oval = false});
  final double radius;
  final bool oval;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: DashedOutline(radius: radius, oval: oval),
    child: const SizedBox.expand(),
  );
}

/// 점선 테두리. 피그마의 strokeDashes = [9, 9], strokeWeight = 2.5.
class DashedOutline extends CustomPainter {
  DashedOutline({this.radius = 0, this.oval = false});

  final double radius;
  final bool oval;

  static const _dash = 9.0;
  static const _gap = 9.0;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    final rect = Offset.zero & size;
    final path = oval
        ? (Path()..addOval(rect))
        : (Path()
            ..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius))));
    for (final m in path.computeMetrics()) {
      var d = 0.0;
      while (d < m.length) {
        canvas.drawPath(m.extractPath(d, (d + _dash).clamp(0.0, m.length)), p);
        d += _dash + _gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant DashedOutline old) =>
      old.radius != radius || old.oval != oval;
}
