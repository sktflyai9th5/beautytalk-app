import 'package:beauty_talk/app_state.dart';
import 'package:flutter_test/flutter_test.dart';

/// 가이드 탭에서 서버로 보낼 발화를 고르는 필터 검증.
/// (실제 앱은 공백을 제거한 문자열을 넘긴다)
bool q(String s) => AppState.looksLikeQuestion(s.replaceAll(' ', ''));

void main() {
  group('서버로 보내야 하는 발화', () {
    const yes = [
      '지금 어때?',
      '지금 어때',
      '립 봐줘',
      '눈 화장 봐줘',
      '볼 괜찮아?',
      '이거 이상해 보여?',
      '내 얼굴 확인해줘',
      '메이크업 점검해줘',
      '입술 색 어떤가요',
      '이거 맞아?',
      '지금 촬영해줘',
      '얼굴 좀 알려줘',
      '눈썹 대칭 맞나',
      '잘 됐는지 봐줘',
      // 결함을 서술로 짚는 말도 확인 요청이다 (물음표 없이도)
      '입술 번졌어',
      '립 번졌나',
      '아이라인 번짐',
      '파운데이션 뭉쳤어',
      '볼터치 지저분해',
      '베이스 들떴어',
      '입가에 묻었어',
    ];
    for (final s in yes) {
      test('"$s" → 전송', () => expect(q(s), isTrue));
    }
  });

  group('무시해야 하는 주변 대화', () {
    const no = [
      '아 진짜 배고프다',
      '오늘 날씨 좋네',
      '내일 학교 가야 되는데',
      '그거 다음 주까지 제출이야',
      '밥 먹고 왔어',
      '아니 그게 아니고',
      '음 그러니까',
      '잠깐만',
      // 결함 어휘를 넣었어도 화장과 무관한 말은 여전히 무시해야 한다
      '커피 쏟았어',
      '어제 늦게 잤어',
    ];
    for (final s in no) {
      test('"$s" → 무시', () => expect(q(s), isFalse));
    }
  });

  group('navTarget — 말로 탭 이동', () {
    test('짧은 한 마디', () {
      expect(AppState.navTarget('설정'), AppTab.settings);
      expect(AppState.navTarget('화장품'), AppTab.cosmetic);
      expect(AppState.navTarget('메이크업'), AppTab.makeup);
    });
    test('이동 표현이 있으면 길어도 이동', () {
      expect(AppState.navTarget('설정탭으로가줘'), AppTab.settings);
      expect(AppState.navTarget('메이크업분석으로이동'), AppTab.makeup);
      expect(AppState.navTarget('화장품인식탭열어'), AppTab.cosmetic);
    });
    test('질문은 이동이 아니다', () {
      expect(AppState.navTarget('메이크업어때'), isNull);
      expect(AppState.navTarget('입술화장이어때'), isNull);
      expect(AppState.navTarget('베이스'), isNull); // 탭 이름 아님
    });
  });
}
