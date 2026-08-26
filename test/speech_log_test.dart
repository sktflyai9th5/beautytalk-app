import 'package:beauty_talk/services/log_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// 인식된 음성 보관 규칙.
///
/// 음성 인식은 주변 대화까지 받아 적기 때문에, 기기에 남는 양을 짧은 창으로
/// 묶어 둔다. 넘치면 **오래된 것부터** 사라져야 한다.
void main() {
  List<String> lines(int n) => [for (var i = 1; i <= n; i++) '발화$i'];

  test('보관 개수를 넘으면 오래된 것부터 사라진다', () {
    final l = lines(13);
    LogService.keepRecent(l, 10);

    expect(l.length, 10);
    expect(l.first, '발화4', reason: '앞의 3개가 밀려나야 한다');
    expect(l.last, '발화13', reason: '가장 최근은 남아야 한다');
  });

  test('보관 개수 이하면 그대로 둔다', () {
    final l = lines(4);
    LogService.keepRecent(l, 10);
    expect(l, lines(4));
  });

  test('딱 맞으면 그대로 둔다', () {
    final l = lines(10);
    LogService.keepRecent(l, 10);
    expect(l.length, 10);
    expect(l.first, '발화1');
  });

  test('0으로 두면 아무것도 남기지 않는다', () {
    final l = lines(5);
    LogService.keepRecent(l, 0);
    expect(l, isEmpty);
  });

  test('기본 보관 개수는 10건', () {
    expect(LogService.speechKeep, 10);
  });
}
