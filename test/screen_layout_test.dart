import 'package:beauty_talk/app_state.dart';
import 'package:beauty_talk/widgets/coral.dart';
import 'package:beauty_talk/ml/cosmetic_classifier.dart';
import 'package:beauty_talk/ml/product_catalog.dart';
import 'package:beauty_talk/screens/tabs/cosmetic_tab.dart';
import 'package:beauty_talk/screens/tabs/makeup_tab.dart';
import 'package:beauty_talk/screens/tabs/settings_tab.dart';
import 'package:beauty_talk/services/backend_service.dart';
import 'package:beauty_talk/theme/app_theme.dart';
import 'package:beauty_talk/widgets/bottom_tab_bar.dart';
import 'package:beauty_talk/widgets/hologram_scan.dart';
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
        // 셔터는 탭 화면이 아니라 **하단 탭바 가운데**에 있다 (메인 셸이 그린다)
        expect(find.byType(ShutterButton), findsNothing);
        expect(find.text('촬영하기'), findsNothing);
        expect(find.text('화장품 인식'), findsNothing);
      });

      testWidgets('화장품 · 분석 중', (t) async {
        final s = makeState()..cosmeticStage = CosmeticStage.analyzing;
        await draw(t, CosmeticTab(state: s), size);
        // 글자는 두지 않는다 — 음성과 스크린리더(liveRegion)로만 알린다
        expect(find.text('화장품을 분석 중이에요.'), findsNothing);
        expect(find.byType(ScanningPhoto), findsOneWidget);
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
        expect(find.text('제품을 찾았어요.'), findsNothing);
        // 시트 안 — 분류 · 이름 · 사용량 · 버튼 두 개
        expect(find.text('lipstick'), findsOneWidget);
        expect(find.text('립스틱'), findsOneWidget);
        expect(find.text('사용량'), findsOneWidget);
        expect(find.text('자세히 듣기'), findsOneWidget);
        expect(find.text('다시 촬영'), findsOneWidget);
        // "이건 ~예요" 는 화면에 쓰지 않는다 — 음성으로만
        expect(find.text('이건 립스틱이에요!'), findsNothing);
      });

      testWidgets('메이크업 · 촬영', (t) async {
        await draw(t, MakeupTab(state: makeState()), size);
        // 셔터는 탭 화면이 아니라 **하단 탭바 가운데**에 있다 (메인 셸이 그린다)
        expect(find.byType(ShutterButton), findsNothing);
        expect(find.text('촬영하기'), findsNothing);
        expect(find.text('메이크업 분석'), findsNothing);
      });

      testWidgets('메이크업 · 질문', (t) async {
        final s = makeState()..makeupStage = MakeupStage.question;
        await draw(t, MakeupTab(state: s), size);
        // 위쪽은 방금 찍은 얼굴, 말하기는 아래 시트의 파형이 맡는다.
        // 마이크 그림은 더 이상 두지 않는다.
        expect(find.text('궁금한 걸 질문해보세요.'), findsNothing);
        expect(find.byIcon(Icons.mic_rounded), findsNothing);
        // 시트를 없앴다 — 화면 전체가 "눌러서 말하기" 다.
        expect(find.text('무엇을 확인할까요?'), findsNothing);
        expect(find.text('화면을 눌러 궁금한 걸 말씀하세요.'), findsOneWidget);
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
        // 제목은 두지 않는다 — 음성이 말하고, 시트 제목이 같은 말을 한다
        expect(find.text('메이크업 분석 완료!'), findsNothing);
        expect(find.text('메이크업 분석 결과'), findsOneWidget);
        // 부위 이름은 **글자로 쓰지 않는다** — 얼굴 위 하이라이트가 그 자리를
        // 가리키고, 이름은 음성과 스크린리더 라벨로만 나간다.
        expect(find.text('왼쪽 볼 아래'), findsNothing);
        // 항목이 여럿이면 시트에는 **전체 요약**(lastSpokenResult)이 온다.
        // 하이라이트는 두 부위 다 켜지므로 한 항목의 문장만 골라 쓰면
        // 불 켜진 자리와 글이 어긋난다.
        expect(find.text('왼쪽 볼 아래 베이스가 고르지 않아요.'), findsOneWidget);
        expect(find.text('베이스가 고르지 않게 발려 있어요.'), findsNothing);
        expect(find.text('발린 곳과 안 발린 곳 경계가 티나요.'), findsNothing);
        expect(find.text('카메라 화면으로'), findsOneWidget);
        expect(find.text('다시 들려주기'), findsOneWidget);
      });

      testWidgets('메이크업 · 결과 (립 경로 — 항목 없음)', (t) async {
        final s = makeState()
          ..makeupStage = MakeupStage.result
          ..lastHeard = '입술 화장이 어때?'
          ..lastSpokenResult = '입술 색이 고르게 발렸어요. 앞니만 한 번 확인해 보세요.';
        await draw(t, MakeupTab(state: s), size);
        // 짚을 자리가 없어도 문장은 시트에 그대로 나온다 (얼굴은 불 없이 돈다)
        expect(find.textContaining('입술 색이'), findsOneWidget);
        // 부위 이름을 따로 적지 않는다
        expect(find.text('입술'), findsNothing);
      });

      testWidgets('메이크업 · 분석과 결과의 아바타가 같은 크기', (t) async {
        // 같은 사람 같은 아바타인데 넘어가면서 얼굴이 줄면 화면이 바뀐 것으로
        // 보인다. **크기**만 본다 — 높이는 분석 쪽이 더 위다 (시트가 0.30 까지
        // 올라와 있어서 같은 자리에 두면 얼굴 아래가 덮인다).
        final a = makeState()..makeupStage = MakeupStage.analyzing;
        await draw(t, MakeupTab(state: a), size);
        final analyzing = t.getRect(find.byType(HologramScan)).size;

        final r = makeState()
          ..makeupStage = MakeupStage.result
          ..analysisItems = const [
            AnalysisItem(
              region: '코',
              state: '들떴어요.',
              action: '눌러 주세요',
              type: 'base',
            ),
          ];
        await draw(t, MakeupTab(state: r), size);
        expect(t.getRect(find.byType(ResultHologram)).size, analyzing);
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
        // 설정은 상단 메뉴로 옮겼다
        expect(find.text('설정'), findsNothing);
      });

      testWidgets('하단 탭바 · 촬영 중이면 가운데에 셔터', (t) async {
        await draw(
          t,
          Align(
            alignment: Alignment.bottomCenter,
            child: BottomTabBar(
              current: AppTab.cosmetic,
              onTap: (_) {},
              onShutter: () {},
            ),
          ),
          size,
        );
        expect(find.byType(ShutterButton), findsOneWidget);
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
