import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../theme/app_theme.dart';
import 'coral.dart';

/// 하단 탭 3개. 피그마 "Bottom navigation" (1:1496).
///
/// 선택된 탭은 색 + 점 크기(26/22) + 라벨 굵기(Bold/Medium) + 스크린리더 "선택됨"
/// 으로 알린다. 색만으로 상태를 구분하지 않는다는 접근성 명세 때문이다.
///
/// 바탕은 흰 판이 아니라 투명 → 흰색 세로 그라데이션이다 (위 25% 에서 완전한 흰색).
///
/// 아이콘은 피그마에서 도형으로 그린 것이라 머티리얼 아이콘이 아니다.
/// 립스틱 / 반짝이는 얼굴 / 슬라이더 — 그대로 옮겨 그린다.
class BottomTabBar extends StatelessWidget {
  const BottomTabBar({
    super.key,
    required this.current,
    required this.onTap,
    this.onShutter,
  });

  final AppTab current;
  final ValueChanged<AppTab> onTap;

  /// 가운데 셔터. 촬영 화면일 때만 들어온다 (null 이면 그리지 않는다).
  final VoidCallback? onShutter;

  /// 설정은 상단 메뉴로 옮겼다 — 하단에는 촬영으로 이어지는 두 갈래만 둔다.
  static const _labels = {AppTab.cosmetic: '화장품 인식', AppTab.makeup: '메이크업 분석'};

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(gradient: AppColors.tabBarVeil),
      child: SafeArea(
        top: false,
        child: Padding(
          // 높이를 줄였다 (위 34 → 14). 위쪽 안내와 그라데이션이 사라지면서
          // 탭바만 두툼하게 남아 있었다.
          padding: const EdgeInsets.only(top: 14, bottom: 4),
          child: Row(
            // 가운데 정렬. 가운데 셔터가 탭보다 훨씬 커서, 위 정렬로 두면
            // 탭 두 개만 위로 붙어 따로 노는 것처럼 보인다.
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: _Item(
                  tab: AppTab.cosmetic,
                  label: _labels[AppTab.cosmetic]!,
                  selected: current == AppTab.cosmetic,
                  onTap: () => onTap(AppTab.cosmetic),
                ),
              ),
              // 가운데 셔터. 두 탭 사이에 놓여 화면에서 가장 큰 표적이 된다.
              // 촬영 화면이 아닐 때는 자리만 비워 탭 두 개가 흔들리지 않는다.
              SizedBox(
                width: 92,
                child: onShutter == null
                    ? const SizedBox.shrink()
                    : Center(child: ShutterButton(onTap: onShutter!)),
              ),
              Expanded(
                child: _Item(
                  tab: AppTab.makeup,
                  label: _labels[AppTab.makeup]!,
                  selected: current == AppTab.makeup,
                  onTap: () => onTap(AppTab.makeup),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Item extends StatefulWidget {
  const _Item({
    required this.tab,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final AppTab tab;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_Item> createState() => _ItemState();
}

class _ItemState extends State<_Item> {
  bool _down = false;

  void _press(bool down) => setState(() => _down = down);

  @override
  Widget build(BuildContext context) {
    final tab = widget.tab;
    final label = widget.label;
    final selected = widget.selected;
    final onTap = widget.onTap;
    // 피그마 1:1496 — 점 색과 글자 색이 서로 다르다.
    // 색은 가운데 셔터 하나만 쓴다. 탭은 검정 — 선택 여부는 굵기와
    // 점 크기(26/22), 스크린리더의 '선택됨' 으로 알린다.
    final labelColor = selected ? AppColors.ink : AppColors.inkSoft;
    final dotColor = selected ? AppColors.ink : AppColors.tabDotIdle;
    final dotSize = selected ? 26.0 : 22.0;
    return Semantics(
      button: true,
      selected: selected,
      label: '$label, 탭',
      child: ExcludeSemantics(
        // **눌리는 게 보여야 한다.** InkWell 잉크 번짐은 흰 바닥에서 거의
        // 안 보여서, 누른 순간 살짝 줄어들었다가(0.88) 떼면 돌아오게 했다 —
        // 물리 버튼이 들어갔다 나오는 그 느낌이다. 진동도 짧게 얹는다.
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) {
            _press(true);
            HapticFeedback.selectionClick();
          },
          onTapCancel: () => _press(false),
          onTapUp: (_) => _press(false),
          onTap: onTap,
          // 탭바에서는 화면 전체 제스처가 통하지 않는다 (의도된 것)
          child: AnimatedScale(
            scale: _down ? 0.88 : 1.0,
            duration: const Duration(milliseconds: 90),
            curve: Curves.easeOut,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 자리는 26 으로 고정하고 그림만 26/22 로 키운다 —
                  // 두 상태의 중심선이 어긋나지 않는다 (피그마 도트 중심 y=51).
                  SizedBox(
                    width: 80,
                    height: 26,
                    child: Center(
                      child: Transform.scale(
                        scale: dotSize / 24,
                        child: CustomPaint(
                          size: const Size(24, 24),
                          painter: switch (tab) {
                            AppTab.cosmetic => _LipstickIcon(dotColor),
                            AppTab.makeup => _SparkleFaceIcon(dotColor),
                            AppTab.settings => _SlidersIcon(dotColor),
                          },
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    label,
                    textAlign: TextAlign.center,
                    style: AppText.label.copyWith(
                      // 피그마 값은 17 이지만 그건 393dp 기준이다. 데모 기기는
                      // 360dp 라 17 이면 '메이크업 분석'이 두 줄로 접힌다 —
                      // 1px 줄여 한 줄을 지킨다 (보기에는 차이가 없다).
                      fontSize: 16,
                      // 얇게. 굵은 라벨은 가운데 셔터와 무게를 다툰다.
                      fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
                      color: labelColor,
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

// ---------------------------------------------------------------- 아이콘
/// 립스틱 — 뚜껑(반투명) · 목테 · 몸통 (피그마 396:6)
class _LipstickIcon extends CustomPainter {
  _LipstickIcon(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // **속을 채우지 않는다.** 꽉 찬 도형은 선택됐을 때 검은 덩어리가 되어
    // 무엇을 그린 것인지 안 보인다. 윤곽선만 그리면 선택돼도 모양이 남는다.
    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3
      ..strokeJoin = StrokeJoin.round;
    void rr(double x, double y, double w, double h, double r, Paint paint) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(x, y, w, h), Radius.circular(r)),
        paint,
      );
    }

    rr(7.5, 2.5, 9, 8, 3, line); // 뚜껑
    rr(6.5, 10.5, 11, 3, 1.3, line); // 목테
    rr(7.5, 13.5, 9, 8, 2, line); // 몸통
  }

  @override
  bool shouldRepaint(covariant _LipstickIcon old) => old.color != color;
}

/// 반짝이는 얼굴 — 원 + 큰 반짝 + 작은 반짝 (피그마 396:12)
class _SparkleFaceIcon extends CustomPainter {
  _SparkleFaceIcon(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawCircle(
      const Offset(10.5, 13.5),
      8.5,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3,
    );
    void diamond(Offset c, double r, Paint paint) {
      canvas.save();
      canvas.translate(c.dx, c.dy);
      canvas.rotate(0.785398); // 45도
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset.zero, width: r, height: r),
          Radius.circular(r * 0.16),
        ),
        paint,
      );
      canvas.restore();
    }

    // 반짝이도 채우지 않고 윤곽선으로. 꽉 찬 마름모는 아이콘을 무겁게 한다.
    Paint outline([double a = 1]) => Paint()
      ..color = color.withValues(alpha: a)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3
      ..strokeJoin = StrokeJoin.round;
    diamond(const Offset(21, 4), 10, outline());
    diamond(const Offset(23, 14), 6, outline(0.55));
  }

  @override
  bool shouldRepaint(covariant _SparkleFaceIcon old) => old.color != color;
}

/// 슬라이더 3줄 — 설정 (피그마 396:19)
class _SlidersIcon extends CustomPainter {
  _SlidersIcon(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final track = Paint()..color = color.withValues(alpha: 0.45);
    final knob = Paint()..color = color;
    for (var i = 0; i < 3; i++) {
      final y = 5.0 + i * 6;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(2, y, 18, 2),
          const Radius.circular(1),
        ),
        track,
      );
    }
    canvas.drawCircle(const Offset(15, 6), 3, knob);
    canvas.drawCircle(const Offset(7, 12), 3, knob);
    canvas.drawCircle(const Offset(17, 18), 3, knob);
  }

  @override
  bool shouldRepaint(covariant _SlidersIcon old) => old.color != color;
}
