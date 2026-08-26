import 'package:flutter/material.dart';

import '../app_state.dart';
import '../theme/app_theme.dart';

/// 하단 탭 3개. 피그마 "Bottom navigation" (396:2).
///
/// 선택된 탭은 색 + 알약 배경 + 스크린리더 "선택됨" 세 가지로 알린다.
/// 색만으로 상태를 구분하지 않는다는 접근성 명세 때문이다.
///
/// 아이콘은 피그마에서 도형으로 그린 것이라 머티리얼 아이콘이 아니다.
/// 립스틱 / 반짝이는 얼굴 / 슬라이더 — 그대로 옮겨 그린다.
class BottomTabBar extends StatelessWidget {
  const BottomTabBar({super.key, required this.current, required this.onTap});

  final AppTab current;
  final ValueChanged<AppTab> onTap;

  static const _labels = {
    AppTab.cosmetic: '화장품 인식',
    AppTab.makeup: '메이크업 분석',
    AppTab.settings: '설정',
  };

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(color: AppColors.surface),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 8),
          child: Row(
            children: [
              for (final e in _labels.entries)
                Expanded(
                  child: _Item(
                    tab: e.key,
                    label: e.value,
                    selected: current == e.key,
                    onTap: () => onTap(e.key),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Item extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final color = selected ? AppColors.brand : AppColors.inkSoft;
    return Semantics(
      button: true,
      selected: selected,
      label: '$label, 탭',
      child: ExcludeSemantics(
        child: InkWell(
          onTap: onTap,
          // 탭바에서는 화면 전체 제스처가 통하지 않는다 (의도된 것)
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 80,
                  height: 46,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: selected ? AppColors.surfaceTint : Colors.transparent,
                    borderRadius: BorderRadius.circular(AppShape.chipRadius),
                  ),
                  child: CustomPaint(
                    size: const Size(24, 24),
                    painter: switch (tab) {
                      AppTab.cosmetic => _LipstickIcon(color),
                      AppTab.makeup => _SparkleFaceIcon(color),
                      AppTab.settings => _SlidersIcon(color),
                    },
                  ),
                ),
                const SizedBox(height: 6),
                Text(label, style: AppText.label.copyWith(color: color)),
              ],
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
    final p = Paint()..color = color.withValues(alpha: 0.55);
    void rr(double x, double y, double w, double h, double r, Paint paint) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(x, y, w, h), Radius.circular(r)),
        paint,
      );
    }

    rr(6, 2, 8, 10, 3, p); // 뚜껑
    final solid = Paint()..color = color;
    rr(6, 10, 12, 3, 1.3, solid); // 목테
    rr(6, 13, 10, 10, 2, solid); // 몸통
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
        ..strokeWidth = 2,
    );
    void diamond(Offset c, double r, Paint paint) {
      canvas.save();
      canvas.translate(c.dx, c.dy);
      canvas.rotate(0.785398); // 45도
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromCenter(center: Offset.zero, width: r, height: r),
            Radius.circular(r * 0.16)),
        paint,
      );
      canvas.restore();
    }

    diamond(const Offset(21, 4), 10, Paint()..color = color);
    diamond(const Offset(23, 14), 6,
        Paint()..color = color.withValues(alpha: 0.55));
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
            Rect.fromLTWH(2, y, 18, 2), const Radius.circular(1)),
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
