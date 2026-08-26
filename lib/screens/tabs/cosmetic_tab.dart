import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../theme/app_theme.dart';
import '../../widgets/coral.dart';

/// 화장품 인식 플로우.
/// 피그마 「② 화장품 인식 · 촬영 → 확인 → 결과」 (379:2 / 373:24 / 370:2).
///
/// 단계 표시기는 3단계다. 카메라 미리보기는 메인 셸이 배경에 깔아 주므로
/// 여기서는 미리보기를 감싸는 면과 안내만 그린다.
class CosmeticTab extends StatelessWidget {
  const CosmeticTab({super.key, required this.state});
  final AppState state;

  static const steps = ['촬영', '분석', '결과'];

  @override
  Widget build(BuildContext context) {
    final step = switch (state.cosmeticStage) {
      CosmeticStage.capture => 0,
      CosmeticStage.analyzing => 1,
      CosmeticStage.result => 2,
    };
    return Column(
      children: [
        // 화면 이름은 스크린리더만 읽는다. 눈으로 볼 사용자에게는
        // 단계 표시기가 같은 정보를 더 짧게 준다.
        ScreenHeader(
          title: switch (state.cosmeticStage) {
            CosmeticStage.capture => '화장품 인식',
            CosmeticStage.analyzing => '제품 확인 중',
            CosmeticStage.result => '제품 정보',
          },
          showTitle: false,
          onBack: state.cosmeticStage == CosmeticStage.result
              ? state.retakeCosmetic
              : null,
        ),
        const SizedBox(height: 12),
        Gutter(child: StepIndicator(steps: steps, current: step)),
        const SizedBox(height: 8),
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 260),
            child: KeyedSubtree(
              key: ValueKey(state.cosmeticStage),
              child: switch (state.cosmeticStage) {
                CosmeticStage.capture => _Capture(state: state),
                CosmeticStage.analyzing => _Scanning(state: state),
                CosmeticStage.result => _Result(state: state),
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
        // 촬영 안내는 글자로 쓰지 않는다 — 앞이 보이지 않는 사용자에게는
        // 읽히지 않고, 카메라를 가리기만 한다. 같은 내용을 TTS 로 말한다
        // (AppState._announceCurrent).
        // 카메라와 안내선은 메인 셸이 화면 전체에 깔아 준다.
        // 여기서는 그만큼 자리만 비워 둔다.
        const Expanded(child: SizedBox.expand()),
        const SizedBox(height: 8),
        // 플래시는 두지 않는다 — 눈으로 밝기를 확인할 수 없는 사용자에게
        // 켜고 끄는 판단을 맡기는 버튼이라 쓸모가 없다.
        Center(child: ShutterButton(onTap: state.captureAndAnalyze)),
      ],
    );
  }
}

// ---------------------------------------------------------------- 확인 중
/// 분석 중 — 방금 찍은 사진이 가운데에 올라가고 스캔 선이 훑는다.
class _Scanning extends StatelessWidget {
  const _Scanning({required this.state});
  final AppState state;

  static const line = '화장품을 분석 중이에요.';

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: Gutter(
            child: Semantics(
              liveRegion: true,
              label: line,
              child: ExcludeSemantics(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppShape.cardRadius),
                  child: ScanningPhoto(path: state.lastShotPath),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        Gutter(
          child: SizedBox(
            width: double.infinity,
            child: ExcludeSemantics(
              child: Text(line, style: AppText.h1.copyWith(color: AppColors.brand)),
            ),
          ),
        ),
        const SizedBox(height: 20),
      ],
    );
  }
}

// ---------------------------------------------------------------- 결과
/// 결과. 메이크업 결과와 같은 카드 — 방금 찍은 사진을 위에 얹고,
/// 배지에는 번호 대신 체크, 제목은 제품 이름, 할 일 칩에는 사용법.
class _Result extends StatelessWidget {
  const _Result({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final p = state.prediction;
    if (p == null) return const SizedBox.shrink();
    return Column(
      children: [
        const Gutter(
          child: SizedBox(
            width: double.infinity,
            child: Text('제품을 찾았어요.', style: AppText.h1),
          ),
        ),
        const SizedBox(height: 14),
        Expanded(
          child: SingleChildScrollView(
            child: Gutter(
              // "이건 ~예요" 는 화면에 안 쓴다 — 음성이 이미 그렇게 말한다.
              // 화면에는 이름과, 어디를 보고 판단했는지(박스)만 남긴다.
              child: ResultCard(
                badge: const Icon(Icons.check_rounded),
                title: p.product.name,
                action: p.product.usage.isEmpty ? null : p.product.usage,
                top: _Shot(path: state.lastShotPath, box: p.box),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Gutter(
          child: Row(
            children: [
              Expanded(
                child: CoralButton(
                  label: '다시 들려주기',
                  filled: false,
                  onTap: state.speakProduct,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: CoralButton(
                  label: '다시 촬영하기',
                  onTap: state.retakeCosmetic,
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

/// 방금 찍은 사진 + 검출 박스.
/// 박스는 "모델이 어디를 보고 그 제품이라고 했는지" 다. cover 로 잘린 부분을
/// 감안해 원본 좌표(0..1)를 화면 좌표로 옮겨 그린다.
class _Shot extends StatelessWidget {
  const _Shot({required this.path, this.box});
  final String? path;
  final Rect? box;

  @override
  Widget build(BuildContext context) {
    final p = path;
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: SizedBox(
        width: double.infinity,
        height: 180,
        child: DecoratedBox(
          decoration: const BoxDecoration(gradient: AppColors.blobPink),
          child: p == null
              ? const SizedBox.expand()
              : ShotWithBoxes(
                  path: p,
                  spots: [if (box != null) ProblemSpot(region: '', box: box)],
                ),
        ),
      ),
    );
  }
}
