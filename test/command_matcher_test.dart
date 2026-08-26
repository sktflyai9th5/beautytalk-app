import 'package:beauty_talk/services/command_matcher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('자모 분해', () {
    test('화장품', () => expect(CommandMatcher.decompose('화장품'), 'ㅎㅘㅈㅏㅇㅍㅜㅁ'));
    test('가이드', () => expect(CommandMatcher.decompose('가이드'), 'ㄱㅏㅇㅣㄷㅡ'));
  });

  group('오인식 교정 (실제로 나올 법한 케이스)', () {
    const cases = {
      '화장뿜': '화장품',
      '화장품을': '화장품',
      '가있드': '가이드',
      '가이드요': '가이드',
      '설정을': '설정',
      '쵤영해줘': '촬영',
      '촬영 해 줘': '촬영',
    };
    cases.forEach((heard, want) {
      test('"$heard" → "$want" 인식', () {
        expect(CommandMatcher.containsFuzzy(heard, want), isTrue,
            reason: '유사도 ${CommandMatcher.similarity(heard, want)}');
      });
    });
  });

  group('다른 단어는 안 걸려야 함', () {
    const negatives = {
      '화장실': '화장품',
      '가스레인지': '가이드',
      '설거지': '설정',
      '오늘 날씨': '촬영',
    };
    negatives.forEach((heard, kw) {
      test('"$heard" ≠ "$kw"', () {
        expect(CommandMatcher.containsFuzzy(heard, kw), isFalse,
            reason: '유사도 ${CommandMatcher.similarity(heard, kw)}');
      });
    });
  });

  group('여러 후보 중 하나라도 맞으면 통과', () {
    test('1순위 오답 + 2순위 정답', () {
      expect(
        CommandMatcher.matchAny(['가스', '가이드', '가위'], '가이드'),
        isTrue,
      );
    });
    test('전부 무관하면 실패', () {
      expect(CommandMatcher.matchAny(['배고파', '날씨'], '가이드'), isFalse);
    });
  });

  group('bestMatch — 명령어 집합에서 최선 선택', () {
    const vocab = ['화장품', '가이드', '설정', '처음', '촬영'];
    test('정확히 포함', () {
      final r = CommandMatcher.bestMatch(['가이드 탭 열어'], vocab);
      expect(r?.$1, '가이드');
    });
    test('오인식도 매칭', () {
      final r = CommandMatcher.bestMatch(['화장뿜'], vocab);
      expect(r?.$1, '화장품');
    });
    test('무관한 말은 null', () {
      final r = CommandMatcher.bestMatch(['오늘 점심 뭐 먹지'], vocab);
      expect(r, isNull);
    });
  });
}
