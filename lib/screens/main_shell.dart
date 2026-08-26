import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../services/camera_service.dart';
import '../services/voice_service.dart';
import '../theme/app_theme.dart';
import '../widgets/bottom_tab_bar.dart';
import '../widgets/coral.dart';
import '../widgets/gesture_layer.dart';
import 'tabs/cosmetic_tab.dart';
import 'tabs/makeup_tab.dart';
import 'tabs/settings_tab.dart';

/// 진입 화면 이후의 메인 셸.
///
/// 촬영 단계에서는 카메라가 **화면 전체**를 채우고, 그 위에 안내와 조작이 얹힌다.
/// 미리보기가 클수록 대신 봐 주는 사람이 화면을 맞추기 쉽고, 저시력 사용자도
/// 무엇이 잡히는지 알아볼 수 있다.
///
/// 촬영이 아닌 단계(분석·질문·결과·설정)에서는 카메라를 내리고 코랄 배경을 쓴다.
class MainShell extends StatelessWidget {
  const MainShell({super.key, required this.state});
  final AppState state;

  /// 지금 화면이 카메라를 보여 주는 단계인가
  bool get _showCamera =>
      (state.tab == AppTab.cosmetic &&
          state.cosmeticStage == CosmeticStage.capture) ||
      (state.tab == AppTab.makeup &&
          state.makeupStage == MakeupStage.capture);

  @override
  Widget build(BuildContext context) {
    return GestureLayer(
      state: state,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 1) 배경 — 카메라 ↔ 코랄
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: _showCamera
                ? const CameraView(key: ValueKey('camera'))
                : const CoralBackdrop(key: ValueKey('coral'), blobs: false),
          ),
          // 2) 카메라 위 글자가 읽히도록 위아래를 밝게 깔아 준다.
          //    이게 없으면 흰 벽을 비출 때 제목이 사라진다.
          if (_showCamera) const _Scrim(),
          // 3) 뷰파인더 안내 — 갈고리 + 가운데 안내선. 화면 기준으로 띄운다.
          if (_showCamera)
            CaptureGuides(
              guide: state.tab == AppTab.cosmetic
                  ? const ProductGuide()
                  : const FaceGuide(),
            ),
          // 4) 탭 콘텐츠
          SafeArea(
            child: Column(
              children: [
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 260),
                    child: KeyedSubtree(
                      key: ValueKey(state.tab),
                      child: switch (state.tab) {
                        AppTab.cosmetic => CosmeticTab(state: state),
                        AppTab.makeup => MakeupTab(state: state),
                        AppTab.settings => SettingsTab(state: state),
                      },
                    ),
                  ),
                ),
                BottomTabBar(current: state.tab, onTap: state.goTab),
              ],
            ),
          ),
          // 렌즈 검사 중 안내 — 저시력 사용자를 위해 화면에도 띄운다
          if (state.lensChecking) const _LensChecking(),
          // 프레이밍 교정 안내 — 음성이 주 채널이고, 화면은 곁에서 돕는 사람용
          if (state.framingHint.isNotEmpty) _FramingHint(text: state.framingHint),
          // 듣는 중 표시 — 어느 화면에서든 두드리면 뜬다
          const _ListeningBanner(),
        ],
      ),
    );
  }
}

/// 카메라 위 스크림. 위쪽은 제목·단계 표시, 아래쪽은 셔터와 탭바를 받친다.
/// 가운데는 비워 둔다 — 거기가 실제로 봐야 하는 영역이다.
class _Scrim extends StatelessWidget {
  const _Scrim();

  @override
  Widget build(BuildContext context) {
    return const IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xF7FFFDFC),
              Color(0xF0FFFDFC),
              Color(0x00FFF9F7),
              Color(0x00FEF1EF),
              Color(0xF7FEF1EF),
            ],
            stops: [0.0, 0.115, 0.17, 0.70, 0.78],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 카메라
/// 전체 화면 카메라 미리보기. 메인 셸이 배경으로 깐다.
class CameraView extends StatelessWidget {
  const CameraView({super.key});

  @override
  Widget build(BuildContext context) {
    final cam = CameraService.instance;
    return AnimatedBuilder(
      animation: cam,
      builder: (context, _) {
        final c = cam.controller;
        if (c == null || !c.value.isInitialized) {
          return DecoratedBox(
            decoration: const BoxDecoration(gradient: AppColors.blobPink),
            child: cam.error == null
                ? const SizedBox.expand()
                : Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(cam.error!,
                          style: AppText.cardBody, textAlign: TextAlign.center),
                    ),
                  ),
          );
        }
        // 면을 가득 채운다 (cover)
        return LayoutBuilder(
          builder: (context, box) {
            final target = box.maxWidth / box.maxHeight;
            // 세로 모드에서 프리뷰는 회전되어 오므로 역수를 쓴다
            final preview = 1 / c.value.aspectRatio;
            var scale = target / preview;
            if (scale < 1) scale = 1 / scale;
            return ClipRect(
              child: Transform.scale(
                scale: scale,
                child: Center(
                  child: AspectRatio(
                    aspectRatio: preview,
                    child: CameraPreview(c),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

// ---------------------------------------------------------------- 오버레이
/// 찍기 전 프레이밍 교정 안내. 음성과 같은 문장을 크게 띄운다.
class _FramingHint extends StatelessWidget {
  const _FramingHint({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Align(
        // 촬영 면 한가운데. 아래로 내리면 셔터를 가린다.
        alignment: const Alignment(0, -0.05),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 28),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
          decoration: BoxDecoration(
            color: AppColors.ink.withValues(alpha: 0.88),
            borderRadius: BorderRadius.circular(AppShape.buttonRadius),
          ),
          child: Semantics(
            liveRegion: true,
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: AppText.h1.copyWith(fontSize: 22, color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}

/// 렌즈 이물질 검사 중.
/// 「모든 상태는 소리로도 알린다」 — 화면과 스크린리더 양쪽에 남긴다.
class _LensChecking extends StatelessWidget {
  const _LensChecking();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Align(
        alignment: const Alignment(0, -0.72),
        child: Semantics(
          liveRegion: true,
          label: '카메라 렌즈 확인 중',
          child: ExcludeSemantics(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(AppShape.pillRadius),
                border: Border.all(color: AppColors.outline),
                boxShadow: const [
                  BoxShadow(
                      color: AppColors.cardShadow,
                      blurRadius: 14,
                      offset: Offset(0, 4)),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: AppColors.brand),
                  ),
                  const SizedBox(width: 10),
                  Text('카메라 렌즈 확인 중',
                      style: AppText.label.copyWith(color: AppColors.brandChip)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 듣는 중 상태 알약.
///
/// 「접근성 명세」: 녹음 중에는 "듣고 있습니다" 상태를 안내한다.
/// 말하는 중에는 띄우지 않는다 — 소리가 곧 상태라 화면까지 덮을 이유가 없다.
/// 자리는 탭바 바로 위다. 위쪽은 화면 제목이 쓰는 자리라 가리면 안 된다.
class _ListeningBanner extends StatelessWidget {
  const _ListeningBanner();

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: VoiceService.instance,
      builder: (context, _) {
        final v = VoiceService.instance;
        if (!v.isListening) return const SizedBox.shrink();
        final label = v.partialText.isEmpty ? '듣고 있습니다' : v.partialText;
        return IgnorePointer(
          child: SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 92),
                child: Semantics(
                  liveRegion: true,
                  label: label,
                  child: ExcludeSemantics(
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 320),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 10),
                      decoration: BoxDecoration(
                        gradient: AppColors.stepActive,
                        borderRadius:
                            BorderRadius.circular(AppShape.pillRadius),
                        boxShadow: const [
                          BoxShadow(
                              color: Color(0x33B02426),
                              blurRadius: 18,
                              offset: Offset(0, 6)),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.mic_rounded,
                              size: 20, color: Colors.white),
                          const SizedBox(width: 10),
                          Flexible(
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppText.cardTitle
                                  .copyWith(color: Colors.white),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
