import 'package:flutter/material.dart';

import '../../ml/cosmetic_classifier.dart';
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
          onMenu: () => state.goTab(AppTab.settings),
          onHome: state.resetToStart,
          // 뒤로 가기는 **언제나 있다.** 단계 중간이면 앞 단계로, 첫
          // 단계면 처음(화장품 촬영)으로 돌아간다 — 화면마다 있다 없다
          // 하면 "여기선 왜 없지" 를 매번 겪는다.
          onBack: state.cosmeticStage == CosmeticStage.capture
              ? state.resetToStart
              : state.retakeCosmetic,
        ),
        // 단계 표시기(1·2·3)는 두지 않는다 — 지금 어디인지는 화면 제목과
        // 음성이 이미 말하고, 눈금이 위쪽 자리를 크게 먹었다.
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
        // 카메라와 조준선은 메인 셸이 화면 전체에 깔아 준다.
        // 여기서는 그만큼 자리만 비워 둔다.
        const Expanded(child: SizedBox.expand()),
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
        // 사진이 화면을 다 채운다. 글자는 두지 않고 **음성과 스크린리더로만**
        // 알린다 — 화면을 보는 사람에게는 훑고 지나가는 스캔 선이 이미
        // "분석 중" 을 말하고, 글자는 사진을 그만큼 가릴 뿐이다.
        Expanded(
          child: Semantics(
            liveRegion: true,
            label: line,
            child: ExcludeSemantics(
              child: ScanningPhoto(path: state.lastShotPath),
            ),
          ),
        ),
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
        // 「제품을 찾았어요」 같은 글자는 두지 않는다 — 음성이 이미 그렇게
        // 말했고, 그 자리는 사진이 쓰는 편이 낫다. 제품 이름은 아래 시트에 있다.
        Expanded(
          flex: 3,
          // 사진이 그 자리를 남김없이 채운다 — 뒤 배경이 비치면 화면이
          // 두 겹으로 보인다.
          child: SizedBox.expand(
            // **찍은 사진 그대로다.** 미리 준비한 대표 사진을 대신 띄우면
            // 화면과 손에 든 물건이 달라서, 곁에서 보는 사람이 "이게 그거
            // 맞나" 를 되묻게 된다.
            child: ClipRect(
              child: _Shot(path: state.lastShotPath, box: p.box),
            ),
          ),
        ),
        const SizedBox(height: 12),
        _ProductSheet(state: state, p: p),
      ],
    );
  }
}

/// 제품 시트. 분류 · 이름 · 사용법 한 줄 · 버튼 두 개.
class _ProductSheet extends StatelessWidget {
  const _ProductSheet({required this.state, required this.p});

  final AppState state;
  final CosmeticPrediction p;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: [
          BoxShadow(
              color: AppColors.cardShadow, blurRadius: 30, offset: Offset(0, -8)),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
              AppShape.gutter, 10, AppShape.gutter, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
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
              // 분류 — 이름 위에 작게. 음성은 이미 "이건 ~예요" 라고 말했다.
              Text(p.label,
                  style: AppText.label
                      .copyWith(fontSize: 13, color: AppColors.inkSoft)),
              const SizedBox(height: 2),
              Semantics(
                header: true,
                child: Text(p.product.name, style: AppText.h1),
              ),
              if (p.product.usage.isNotEmpty) ...[
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('사용량',
                        style: AppText.label.copyWith(
                            fontSize: 15, color: AppColors.inkSoft)),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        p.product.usage,
                        textAlign: TextAlign.right,
                        style: AppText.label
                            .copyWith(fontSize: 15, color: AppColors.ink),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: CoralButton(
                      label: '자세히 듣기',
                      icon: Icons.volume_up_rounded,
                      soft: true,
                      onTap: state.speakProduct,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: CoralButton(
                      label: '다시 촬영',
                      icon: Icons.refresh_rounded,
                      beige: true,
                      onTap: state.retakeCosmetic,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
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
    // 높이를 정하지 않는다 — 부모가 준 자리를 그대로 채운다. 180 으로
    // 묶어 두면 결과 화면에서 사진 위아래로 배경이 드러난다.
    return ClipRect(
      child: SizedBox.expand(
        child: DecoratedBox(
          decoration: const BoxDecoration(color: AppColors.surface),
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
