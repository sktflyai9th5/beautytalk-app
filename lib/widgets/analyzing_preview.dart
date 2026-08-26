import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'coral.dart';
import 'hologram_scan.dart';

// 이 화면을 쓰는 쪽은 격자 자료와 색도 같이 다뤄야 한다. import 를 두 개 시키지 않는다.
export 'hologram_scan.dart' show FaceOverlay, ScanTone;

/// 메이크업 분석 탭의 '분석 중' 화면을 기기 없이 세워 보기 위한 껍데기.
///
/// 헤더·단계 표시기·홀로그램 카드·취소 버튼까지 실제 화면
/// (`makeup_tab.dart` 의 `MakeupTab` + `_Analyzing`)과 같은 부품을 같은 순서로
/// 쓴다. 실제 탭과 다른 점은 진행률과 문장을 [AppState] 가 아니라 바깥에서
/// 넣어 준다는 것 하나뿐이다.
///
/// 미리보기(`preview_main.dart`)와 영상 뽑는 테스트가 같이 쓴다. 두 곳에
/// 따로 베껴 두면 화면이 바뀔 때마다 어긋난다.
class AnalyzingPreview extends StatelessWidget {
  const AnalyzingPreview({
    super.key,
    required this.photo,
    required this.statusLine,
    required this.progress,
    this.overlay,
    this.sequenceKey,
    this.accent = defaultAccent,
    this.sound = true,
    this.onCancel,
  });

  /// 하늘색에 연회색을 섞어 채도를 낮춘 톤. 흰 바탕 전제다.
  static const defaultAccent = ScanTone.line;

  /// `MakeupTab.steps` 와 같다. 그 파일을 import 하면 AppState 를 타고
  /// 카메라·STT 까지 딸려 와서 웹에서 빌드되지 않는다.
  static const steps = ['촬영', '질문', '분석', '결과'];

  final ImageProvider photo;
  final String statusLine;
  final double progress;
  final FaceOverlay? overlay;

  /// 값이 바뀌면 연출이 처음부터 다시 돈다.
  final Object? sequenceKey;

  final Color accent;
  final bool sound;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(gradient: AppColors.screenBackdrop),
      child: SafeArea(
        child: Column(
          children: [
            ScreenHeader(
              title: '메이크업 분석',
              showTitle: false,
              onBack: onCancel,
            ),
            const SizedBox(height: 12),
            const Gutter(child: StepIndicator(steps: steps, current: 2)),
            const SizedBox(height: 8),
            Expanded(
              child: Gutter(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppShape.cardRadius),
                  child: HologramScan(
                    key: ValueKey(sequenceKey),
                    photo: photo,
                    overlay: overlay,
                    statusLine: statusLine,
                    progress: progress,
                    accent: accent,
                    sound: sound,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
            if (onCancel != null)
              Gutter(
                child: CoralButton(
                  label: '취소하고 다시 촬영하기',
                  filled: false,
                  onTap: onCancel!,
                ),
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}
