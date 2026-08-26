import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';

/// 피그마 "화면 제스처" 규칙을 화면 전체에 적용하는 레이어.
///
/// | 제스처 | 동작 | 범위 |
/// |---|---|---|
/// | 한 번 두드리기 | 음성 인식 시작 (평소엔 듣지 않음) | 모든 화면 |
/// | 두 번 연속 두드리기 | 사진 촬영 → 서버 분석 | 가이드 탭 |
/// | 1.5초 길게 누르기 | 앱 종료 | 모든 화면 |
///
/// 탭바·마이크 알약 같은 조작 위젯은 이 레이어보다 위에 있어 원래 동작이 우선한다.
/// (두 번 두드리기를 기다리므로 한 번 두드리기는 약 300ms 늦게 반응)
class GestureLayer extends StatefulWidget {
  const GestureLayer({super.key, required this.state, required this.child});

  final AppState state;
  final Widget child;

  @override
  State<GestureLayer> createState() => _GestureLayerState();
}

class _GestureLayerState extends State<GestureLayer> {
  Timer? _exitTimer;
  bool _exitArmed = false;
  Offset _pressOrigin = Offset.zero;

  /// 이만큼 움직이면 "길게 누르기"가 아니라 드래그로 본다.
  /// (설정 탭 슬라이더를 천천히 끌 때 앱이 꺼지면 안 된다)
  static const _dragSlop = 12.0;

  /// 한 번 두드리기 → 음성 인식 시작 (평소에는 듣지 않는다)
  void _onTap() => widget.state.startListening();

  /// 두 번 연속 두드리기 → 촬영
  /// - 가이드 탭: 3·2·1 카운트다운 후 촬영 → 서버 분석
  /// - 화장품 탭: 온디바이스 인식 촬영
  void _onDoubleTap() {
    switch (widget.state.tab) {
      case AppTab.makeup:
        HapticFeedback.mediumImpact();
        widget.state.captureAndAsk();
      case AppTab.cosmetic:
        HapticFeedback.mediumImpact();
        widget.state.captureAndAnalyze();
      case AppTab.settings:
        break;
    }
  }

  /// 1.5초 이상 누르고 있어야 종료. 0.5초를 넘겨 눌렀다 떼면 아무 일도 없다.
  void _onPressDown(PointerDownEvent e) {
    _exitTimer?.cancel();
    _exitArmed = true;
    _pressOrigin = e.position;
    _exitTimer = Timer(const Duration(milliseconds: 1500), () async {
      if (!_exitArmed) return;
      HapticFeedback.heavyImpact();
      await widget.state.exitApp();
    });
  }

  /// 손가락이 움직이면 종료 타이머를 푼다 (스크롤·슬라이더 조작 보호)
  void _onPressMove(PointerMoveEvent e) {
    if (!_exitArmed) return;
    if ((e.position - _pressOrigin).distance > _dragSlop) _cancelPress();
  }

  void _cancelPress([_]) {
    _exitArmed = false;
    _exitTimer?.cancel();
  }

  @override
  void dispose() {
    _exitTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPressDown,
      onPointerMove: _onPressMove,
      onPointerUp: _cancelPress,
      onPointerCancel: _cancelPress,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _onTap,
        onDoubleTap: _onDoubleTap,
        child: widget.child,
      ),
    );
  }
}
