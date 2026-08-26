import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../services/voice_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/coral.dart';

/// 설정 탭 — 개발자용.
///
/// 이 탭은 눈으로 보고 손으로 만지는 화면이라 진입할 때 안내 음성을 내지 않는다.
/// 음성을 고르는 버튼을 눌렀을 때만, 그 목소리로 샘플 문장을 읽어 준다.
///
/// 피그마에는 설정 화면이 없다. 코랄 소프트의 부품(카드·칩·버튼)만 그대로 쓴다.
class SettingsTab extends StatelessWidget {
  const SettingsTab({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const ScreenHeader(title: '설정'),
        const SizedBox(height: 14),
        Expanded(
          child: SingleChildScrollView(
            child: Gutter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  _VoiceSection(),
                  SizedBox(height: 18),
                  _GestureSection(),
                  SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------ 음성 설정
class _VoiceSection extends StatefulWidget {
  const _VoiceSection();

  @override
  State<_VoiceSection> createState() => _VoiceSectionState();
}

class _VoiceSectionState extends State<_VoiceSection> {
  // 드래그하는 동안 보여줄 값 (손을 뗄 때 실제로 적용·저장한다)
  double? _dragRate;
  double? _dragPitch;

  @override
  Widget build(BuildContext context) {
    final v = VoiceService.instance;
    return AnimatedBuilder(
      animation: v,
      builder: (context, _) {
        final voices = v.offlineKoreanVoiceNames;
        return CoralCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('목소리', style: AppText.cardTitle),
              const SizedBox(height: 4),
              Text(
                voices.isEmpty
                    ? '기기에서 한국어 오프라인 음성을 찾지 못했어요. 기기 기본 음성을 씁니다.'
                    : '누르면 그 목소리로 바뀌고, 바로 읽어 줘요. 선택은 저장돼요.',
                style: AppText.cardBody,
              ),
              if (voices.isNotEmpty) ...[
                const SizedBox(height: 14),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final name in voices)
                      _VoiceChip(
                        label: VoiceService.voiceTag(name),
                        sub: name,
                        selected: v.voiceName == name,
                        onTap: () => v.previewVoice(name),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 18),
              _SliderRow(
                label: '말하는 속도',
                value: _dragRate ?? v.speechRate,
                min: 0.2,
                max: 1.0,
                display: (x) => '${(x / 0.5).toStringAsFixed(2)}배',
                onChanged: (x) => setState(() => _dragRate = x),
                onEnd: (x) async {
                  setState(() => _dragRate = null);
                  await v.setSpeechRate(x);
                  await v.speak(VoiceService.sampleSentence);
                },
              ),
              const SizedBox(height: 10),
              _SliderRow(
                label: '음 높이',
                value: _dragPitch ?? v.pitch,
                min: 0.6,
                max: 1.6,
                display: (x) => x.toStringAsFixed(2),
                onChanged: (x) => setState(() => _dragPitch = x),
                onEnd: (x) async {
                  setState(() => _dragPitch = null);
                  await v.setPitch(x);
                  await v.speak(VoiceService.sampleSentence);
                },
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: _ActionButton(
                      icon: Icons.volume_up_rounded,
                      label: '들어보기',
                      onTap: () => v.speak(VoiceService.sampleSentence),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _ActionButton(
                      icon: Icons.refresh_rounded,
                      label: '기본값으로',
                      onTap: () async {
                        await v.setSpeechRate(0.5);
                        await v.setPitch(1.0);
                        await v.speak(VoiceService.sampleSentence);
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 음성 하나 = 알약 버튼. 선택된 것은 브랜드 그라데이션.
class _VoiceChip extends StatelessWidget {
  const _VoiceChip({
    required this.label,
    required this.sub,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String sub;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: '$label 목소리${selected ? ", 선택됨" : ""}',
      child: ExcludeSemantics(
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppShape.chipRadius),
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 11, 16, 11),
            decoration: BoxDecoration(
              gradient: selected ? AppColors.stepActive : null,
              color: selected ? null : AppColors.surfaceChip,
              borderRadius: BorderRadius.circular(AppShape.chipRadius),
              border: Border.all(
                  color: selected ? Colors.transparent : AppColors.chipEdge),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      selected
                          ? Icons.check_circle_rounded
                          : Icons.play_circle_outline_rounded,
                      size: 18,
                      color: selected ? Colors.white : AppColors.brand,
                    ),
                    const SizedBox(width: 7),
                    Text(
                      label,
                      style: AppText.cardTitle.copyWith(
                          color: selected ? Colors.white : AppColors.brandChip),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  sub,
                  style: AppText.caption.copyWith(
                    fontSize: 11,
                    color: selected
                        ? Colors.white.withValues(alpha: 0.85)
                        : AppColors.inkSoft,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.display,
    required this.onChanged,
    required this.onEnd,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String Function(double) display;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onEnd;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: AppText.cardTitle),
            Text(display(value),
                style: AppText.label.copyWith(color: AppColors.brand)),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 6,
            activeTrackColor: AppColors.brand,
            inactiveTrackColor: AppColors.track,
            thumbColor: AppColors.brand,
            overlayColor: AppColors.cardShadow,
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 20),
          ),
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: ((max - min) * 20).round(),
            onChanged: onChanged,
            onChangeEnd: onEnd,
          ),
        ),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: ExcludeSemantics(
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppShape.chipRadius),
          child: Container(
            height: AppShape.minTouch,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: AppColors.surfaceChip,
              borderRadius: BorderRadius.circular(AppShape.chipRadius),
              border: Border.all(color: AppColors.chipEdge),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 18, color: AppColors.brand),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(label,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.label.copyWith(color: AppColors.brandChip)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ 제스처 안내
class _GestureSection extends StatelessWidget {
  const _GestureSection();

  @override
  Widget build(BuildContext context) {
    return CoralCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: const [
          Text('화면 제스처', style: AppText.cardTitle),
          SizedBox(height: 4),
          Text('대상은 화면 전체예요.\n탭바와 버튼은 원래 하던 대로 동작해요.',
              style: AppText.cardBody),
          SizedBox(height: 14),
          _RuleTile(
            title: '한 번 두드리기',
            action: '음성 인식 시작',
            scope: '모든 화면 · 평소엔 듣지 않아요',
          ),
          SizedBox(height: 10),
          _RuleTile(
            title: '두 번 연속 두드리기',
            action: '사진 촬영',
            scope: '화장품 인식 · 메이크업 분석 탭',
          ),
          SizedBox(height: 10),
          _RuleTile(
            title: '1.5초 길게 누르기',
            action: '앱 종료',
            scope: '모든 화면',
          ),
        ],
      ),
    );
  }
}

/// 제목 / 동작 / 범위 — 코랄 칩 배경
class _RuleTile extends StatelessWidget {
  const _RuleTile({
    required this.title,
    required this.action,
    required this.scope,
  });

  final String title;
  final String action;
  final String scope;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$title, $action, $scope',
      child: ExcludeSemantics(
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 13, 16, 13),
          decoration: BoxDecoration(
            color: AppColors.surfaceChip,
            borderRadius: BorderRadius.circular(AppShape.chipRadius),
            border: Border.all(color: AppColors.chipEdge),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: AppText.cardTitle),
              const SizedBox(height: 4),
              Text('→ $action',
                  style: AppText.label.copyWith(color: AppColors.brand)),
              const SizedBox(height: 3),
              Text(scope, style: AppText.cardBody.copyWith(fontSize: 14)),
            ],
          ),
        ),
      ),
    );
  }
}
