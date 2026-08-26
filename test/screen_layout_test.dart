import 'package:beauty_talk/app_state.dart';
import 'package:beauty_talk/ml/cosmetic_classifier.dart';
import 'package:beauty_talk/ml/product_catalog.dart';
import 'package:beauty_talk/screens/tabs/cosmetic_tab.dart';
import 'package:beauty_talk/screens/tabs/makeup_tab.dart';
import 'package:beauty_talk/screens/tabs/settings_tab.dart';
import 'package:beauty_talk/services/backend_service.dart';
import 'package:beauty_talk/theme/app_theme.dart';
import 'package:beauty_talk/widgets/bottom_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 화면이 실제로 들어가는지만 본다.
///
/// 촬영 결과 화면들은 카메라 앞에 진짜 제품이나 얼굴이 있어야 나온다 —
/// 기기에서 눌러 볼 수 없으니 여기서 각 단계를 직접 세워 놓고 그린다.
/// 넘치면(RenderFlex overflow) 디버그 빌드에서 예외가 나므로 이 테스트가 잡는다.
///
/// 글꼴이 없어 한글은 네모로 그려지지만, 자리·크기는 그대로 계산된다.
void main() {
  /// 피그마 기준(393×852)과, 상태바·내비바를 뺀 실제 기기(393×745) 두 가지.
  const sizes = {
    '피그마 393x852': Size(393, 852),
    '기기 세이프 393x745': Size(393, 745),
    '작은 화면 360x640': Size(360, 640),
  };

  Widget wrap(Widget child, Size size) => MediaQuery(
        data: MediaQueryData(size: size),
        child: MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            backgroundColor: AppColors.canvasTop,
            body: SizedBox.expand(child: child),
          ),
        ),
      );

  Future<void> draw(WidgetTester tester, Widget child, Size size) async {
    tester.view.physicalSize = size * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrap(child, size));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
  }

  AppState makeState() => AppState(classifier: _StubClassifier());

  for (final entry in sizes.entries) {
    final label = entry.key;
    final size = entry.value;

    group(label, () {
      testWidgets('화장품 · 촬영', (t) async {
        await draw(t, CosmeticTab(state: makeState()), size);
        // 촬영 화면에는 글자를 두지 않는다 — 안내는 TTS 로만 나간다
        // 셔터에는 글자가 없다 — 아이콘으로 찾는다
        expect(find.byIcon(Icons.photo_camera_rounded), findsOneWidget);
        expect(find.text('촬영하기'), findsNothing);
        expect(find.text('화장품 인식'), findsNothing);
      });

      testWidgets('화장품 · 분석 중', (t) async {
        final s = makeState()..cosmeticStage = CosmeticStage.analyzing;
        await draw(t, CosmeticTab(state: s), size);
        expect(find.text('화장품을 분석 중이에요.'), findsOneWidget);
      });

      testWidgets('화장품 · 결과', (t) async {
        final s = makeState()
          ..cosmeticStage = CosmeticStage.result
          ..prediction = const CosmeticPrediction(
            label: 'lipstick',
            confidence: 0.91,
            product: ProductInfo(
              name: '립스틱',
              description: '이건 립스틱이에요!',
              usage: '입술 가운데부터 발라 주세요.',
            ),
          );
        await draw(t, CosmeticTab(state: s), size);
        expect(find.text('제품을 찾았어요.'), findsOneWidget);
        expect(find.text('다시 촬영하기'), findsOneWidget);
        // "이건 ~예요" 는 화면에 쓰지 않는다 — 음성으로만
        expect(find.text('이건 립스틱이에요!'), findsNothing);
      });

      testWidgets('메이크업 · 촬영', (t) async {
        await draw(t, MakeupTab(state: makeState()), size);
        expect(find.byIcon(Icons.photo_camera_rounded), findsOneWidget);
        expect(find.text('촬영하기'), findsNothing);
        expect(find.text('메이크업 분석'), findsNothing);
      });

      testWidgets('메이크업 · 질문', (t) async {
        final s = makeState()..makeupStage = MakeupStage.question;
        await draw(t, MakeupTab(state: s), size);
        // 글자 없이 음성 버튼이 화면을 채운다
        expect(find.text('궁금한 걸 질문해보세요.'), findsNothing);
        expect(find.text('음성으로 질문하기'), findsNothing);
        expect(find.byIcon(Icons.mic_rounded), findsOneWidget);
        // 피그마 「Suggested questions」 3개가 그대로 있어야 한다
        for (final q in [
          '입술 화장이 어때?',
          '베이스 뭉친 곳 있어?',
          '전체적으로 자연스러운가요?',
        ]) {
          expect(find.text(q), findsOneWidget);
        }
      });

      testWidgets('메이크업 · 분석 중', (t) async {
        final s = makeState()
          ..makeupStage = MakeupStage.analyzing
          ..lastHeard = '입술 화장이 어때?'
          ..analysisProgress = 0.65;
        await draw(t, MakeupTab(state: s), size);
        expect(find.text('취소하고 다시 촬영하기'), findsOneWidget);
        // 퍼센트가 아니라 무엇을 보고 있는지
        expect(find.text('입술을 분석 중이에요.'), findsOneWidget);
        expect(find.textContaining('퍼센트'), findsNothing);
      });

      testWidgets('메이크업 · 분석 중 (받침 없는 부위 → 를)', (t) async {
        final s = makeState()
          ..makeupStage = MakeupStage.analyzing
          ..lastHeard = '베이스 뭉친 곳 있어?';
        await draw(t, MakeupTab(state: s), size);
        expect(find.text('피부를 분석 중이에요.'), findsOneWidget);
      });

      testWidgets('메이크업 · 결과 (항목 2개)', (t) async {
        final s = makeState()
          ..makeupStage = MakeupStage.result
          ..lastSpokenResult = '왼쪽 볼 아래 베이스가 고르지 않아요.'
          ..analysisItems = const [
            AnalysisItem(
              region: '왼쪽 볼 아래',
              state: '베이스가 고르지 않게 발려 있어요.',
              action: '퍼프로 가볍게 두드려 정리해 주세요',
              type: 'base',
            ),
            AnalysisItem(
              region: '오른쪽 눈 아래',
              state: '발린 곳과 안 발린 곳 경계가 티나요.',
              action: '만져서 턱진 선을 찾아 문질러 주세요',
              type: 'base',
            ),
          ];
        await draw(t, MakeupTab(state: s), size);
        expect(find.text('메이크업 분석 완료!'), findsOneWidget);
        expect(find.text('왼쪽 볼 아래'), findsOneWidget);
        expect(find.text('다시 들려주기'), findsOneWidget);
      });

      testWidgets('메이크업 · 결과 (립 경로 — 항목 없음)', (t) async {
        final s = makeState()
          ..makeupStage = MakeupStage.result
          ..lastHeard = '입술 화장이 어때?'
          ..lastSpokenResult = '입술 색이 고르게 발렸어요. 앞니만 한 번 확인해 보세요.';
        await draw(t, MakeupTab(state: s), size);
        expect(find.textContaining('입술 색이'), findsOneWidget);
        // 카드 제목은 질문이 짚은 부위 — 베이스를 물었는데 "입술" 이 나오면 안 된다
        expect(find.text('입술'), findsOneWidget);
      });

      testWidgets('설정', (t) async {
        await draw(t, SettingsTab(state: makeState()), size);
        expect(find.text('화면 제스처'), findsOneWidget);
      });

      testWidgets('하단 탭바', (t) async {
        await draw(
          t,
          Align(
            alignment: Alignment.bottomCenter,
            child: BottomTabBar(current: AppTab.cosmetic, onTap: (_) {}),
          ),
          size,
        );
        expect(find.text('메이크업 분석'), findsOneWidget);
      });
    });
  }
}

/// 화면만 그리므로 추론은 하지 않는다.
class _StubClassifier implements CosmeticClassifier {
  @override
  Future<void> load() async {}

  @override
  Future<CosmeticPrediction> classifyFile(String imagePath) async =>
      const CosmeticPrediction(
        label: 'unknown',
        confidence: 0,
        product: ProductInfo(name: '', description: ''),
      );

  @override
  Future<LensCheck?> checkLens(String imagePath) async => null;

  @override
  void dispose() {}
}
