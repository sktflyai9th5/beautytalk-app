import 'package:flutter/material.dart';

import '../app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/coral.dart';

/// 진입 화면. 피그마 「ENTRY · BeautyTalk 진입 화면」(446:2)에서
/// 버튼 두 개와 작은 글씨를 걷어낸 형태다.
///
/// 앞이 보이지 않는 사용자에게 버튼 두 개는 "어느 쪽을 눌렀는지 모르는" 갈림길이다.
/// 화면 어디를 눌러도 촬영으로 들어가고, 다른 곳은 하단 탭으로 간다.
///
/// 낭독 순서:
///   1. "BeautyTalk, 메이크업 AI 어시스턴트" — 화면 제목
///   2. "화면을 터치하면 바로 시작합니다" — 안내
class EntryScreen extends StatelessWidget {
  const EntryScreen({super.key, required this.state});
  final AppState state;

  /// 화면과 음성이 같은 문장을 쓴다. 둘이 어긋나면 안내가 아니라 혼란이 된다.
  static const hint = '화면을 터치하면 바로 시작합니다.';

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => state.start(to: AppTab.cosmetic),
      child: CoralBackdrop(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppShape.gutter),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Spacer(flex: 420),
                Semantics(
                  header: true,
                  label: 'BeautyTalk, 메이크업 AI 어시스턴트',
                  child: const ExcludeSemantics(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('BEAUTY', style: AppText.display),
                        SizedBox(height: 4),
                        Text('TALK', style: AppText.display),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 36),
                // 이 화면에서 할 일은 하나뿐이라 안내도 하나만 크게 둔다
                Semantics(
                  label: hint,
                  child: const ExcludeSemantics(
                    child: Text(hint, style: AppText.entryHint),
                  ),
                ),
                const Spacer(flex: 330),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 서비스 준비가 끝나기 전에 잠깐 보이는 진입 화면 배경.
/// 인트로를 일찍 건너뛰었을 때만 나온다 — 버튼은 아직 누를 수 없다.
class EntryScreenPlaceholder extends StatelessWidget {
  const EntryScreenPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return CoralBackdrop(
      child: Center(
        child: Semantics(
          liveRegion: true,
          label: '준비하고 있어요. 잠시만 기다려 주세요.',
          child: SizedBox.shrink(),
        ),
      ),
    );
  }
}
