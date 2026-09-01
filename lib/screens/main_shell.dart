import 'package:camera/camera.dart';
import 'dart:math' as math;

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
          // 2) 밝게 깔던 띠는 없앴다. 그 위에 있던 안내 문구가 사라졌고,
          //    셔터는 자기 테두리와 그림자로, 탭바는 자기 바닥색으로
          //    카메라 위에서 읽힌다.
          // 3) 조준선은 뺐다. 안내 TTS 가 처음부터 나오면서 파형이 같은
          //    자리에 뜨는데, 말이 끝날 때마다 조준선이 나타났다 사라지니
          //    화면이 계속 바뀌는 것처럼 보였다. 겨눌 곳은 음성 안내가
          //    이미 말한다 ("얼굴을 화면 가운데에").
          // 3-1) 촬영까지 3·2·1
          if (_showCamera) CountdownOverlay(value: state.countdown),
          // 3-2) 상태표시줄(시계·배터리) 자리까지 흰색으로 채운다.
          //     카메라가 그 아래까지 올라와 있어서, 비워 두면 시계가
          //     배경에 묻혀 안 보인다.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: MediaQuery.of(context).padding.top,
            child: const ColoredBox(color: AppColors.surface),
          ),
          // 3-3) 화면 맨 아래 시스템 제스처 바 자리도 흰색으로 덮는다.
          //     systemNavigationBarColor 만으로는 안 덮이는 기기가 있다.
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            height: MediaQuery.of(context).padding.bottom,
            child: const ColoredBox(color: AppColors.surface),
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
                // 촬영을 끝내고 흐름을 타는 동안에는 하단 바를 통째로 뺀다 —
                // 그때는 누를 것이 없고, 화면은 사진·아바타가 끝까지 채워야
                // 한다. 촬영 화면과 결과 화면에서만 남긴다.
                if (!(state.tab == AppTab.cosmetic &&
                        state.cosmeticStage == CosmeticStage.analyzing) &&
                    !(state.tab == AppTab.makeup &&
                        (state.makeupStage == MakeupStage.question ||
                            state.makeupStage == MakeupStage.analyzing)))
                  BottomTabBar(
                  current: state.tab,
                  onTap: state.goTab,
                  // 셔터는 촬영·분석·결과 내내 자리를 지킨다. 찍고 나서
                  // 사라지면 화면이 흔들리고, 다시 찍으려면 어디를 눌러야
                  // 하는지 매번 찾아야 한다. 설정 탭에서만 뺀다.
                  // 촬영 단계면 찍고, 그 뒤 단계면 다시 찍기로 돌아간다.
                  // 자리만 지키고 눌러도 아무 일이 없으면 고장으로 읽힌다.
                  onShutter: switch (state.tab) {
                    AppTab.settings => null,
                    AppTab.cosmetic =>
                      state.cosmeticStage == CosmeticStage.capture
                          ? state.captureAndAnalyze
                          : state.retakeCosmetic,
                    AppTab.makeup => state.makeupStage == MakeupStage.capture
                        ? state.captureAndAsk
                        : () => state.retakeMakeup(),
                  },
                ),
              ],
            ),
          ),
          // 말하는 동안 화면 가운데 파형.
          // **첫 촬영 화면에서만** 띄운다 — 분석·결과 화면에는 이미 볼 것이
          // 가득해서 파형까지 얹으면 그것들을 가린다. 세는 동안(3·2·1)도
          // 뺀다. 숫자 하나만 남아야 한다.
          if (_showCamera && state.countdown == null) const SpeakingWaves(),
          // 렌즈 검사 중 안내 — 저시력 사용자를 위해 화면에도 띄운다
          if (state.lensChecking) const _LensChecking(),
          // 프레이밍 교정 안내 — 음성이 주 채널이고, 화면은 곁에서 돕는 사람용
          if (state.framingHint.isNotEmpty) _FramingHint(text: state.framingHint),
          // 듣는 중 표시 — 어느 화면에서든 두드리면 뜬다
          const _ListeningBanner(),
          // 잘못된 제품 경고 — 화면 전체가 붉게 세 번 깜빡인다 (데모).
          // 맨 위에 얹는다: 상단바·탭바까지 물들어야 "화면 전체" 다.
          _AlertFlash(pulse: state.alertPulse),
        ],
      ),
    );
  }
}

// ------------------------------------------------------- 잘못된 제품 경고
/// [pulse] 가 올라갈 때마다 화면 전체를 붉게 **다섯 번** 깜빡인다.
///
/// 경고는 색으로도 와야 한다 — 소리는 옆 사람에게 들리지 않을 수 있고,
/// 저시력 사용자에게는 전체가 물드는 색 변화가 글자보다 먼저 닿는다.
class _AlertFlash extends StatefulWidget {
  const _AlertFlash({required this.pulse});
  final int pulse;

  @override
  State<_AlertFlash> createState() => _AlertFlashState();
}

class _AlertFlashState extends State<_AlertFlash>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    // 다섯 번 깜빡이는 길이. 삐삐삐 소리(alert_beeps.wav, 2.4초)와
    // 같아야 봉우리마다 소리가 맞아떨어진다.
    duration: const Duration(milliseconds: 2400),
  );

  @override
  void didUpdateWidget(_AlertFlash old) {
    super.didUpdateWidget(old);
    if (widget.pulse != old.pulse) _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          if (!_c.isAnimating) return const SizedBox.shrink();
          // sin 5π: 0~1 사이에 봉우리가 다섯 번 — 다섯 번의 깜빡임이다.
          final v = math.sin(_c.value * math.pi * 5).abs();
          return ColoredBox(
            color: const Color(0xFFC62828).withValues(alpha: 0.45 * v),
            child: const SizedBox.expand(),
          );
        },
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
        // 상단바 바로 아래. 카메라 면의 위쪽에 붙여 둔다.
        alignment: const Alignment(0, -0.65),
        child: Semantics(
          liveRegion: true,
          label: '카메라 렌즈 확인 중',
          child: ExcludeSemantics(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(AppShape.pillRadius),
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
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.4, color: AppColors.ink),
                  ),
                  const SizedBox(width: 12),
                  // 글자를 키우고 검정으로. 곁에서 보는 사람이 읽는 안내라
                  // 색보다 대비가 먼저다.
                  Text('카메라 렌즈 확인 중',
                      style: AppText.label
                          .copyWith(fontSize: 20, color: AppColors.ink)),
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
                // 탭바(약 96) 위로 올린다. 겹치면 셔터를 가린다.
                // 화면 높이의 0.05 만큼(약 37) 더 띄웠다.
                padding: const EdgeInsets.only(bottom: 155),
                child: Semantics(
                  liveRegion: true,
                  label: label,
                  child: ExcludeSemantics(
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 340),
                      // 「카메라 렌즈 확인 중」 과 같은 모습이다 — 같은 자리에
                      // 같은 일(지금 무엇을 하는 중)을 알리는 표시라
                      // 서로 다른 옷을 입힐 이유가 없다.
                      padding: const EdgeInsets.symmetric(
                          horizontal: 22, vertical: 14),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius:
                            BorderRadius.circular(AppShape.pillRadius),
                        boxShadow: const [
                          BoxShadow(
                              color: AppColors.cardShadow,
                              blurRadius: 18,
                              offset: Offset(0, 6)),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.mic_rounded,
                              size: 20, color: AppColors.ink),
                          const SizedBox(width: 12),
                          Flexible(
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppText.label.copyWith(
                                  fontSize: 20, color: AppColors.ink),
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
