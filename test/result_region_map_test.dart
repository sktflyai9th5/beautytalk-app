import 'package:flutter_test/flutter_test.dart';
import 'package:beauty_talk/widgets/hologram_scan.dart';

/// 서버가 실제로 보내는 부위 이름이 아바타 자리로 전부 풀리는지 본다.
///
/// 목록은 서버 `makeup_regions.py` 의 FINE_TO_HEAD 키(세밀 라벨)와 그것을
/// 한 단계 낮춘 상위 표현을 그대로 옮긴 것이다. 하나라도 null 이 되면
/// 결과 화면에서 그 부위는 불이 켜지지 않는다 — 예전에 '콧대'('코'라는
/// 글자가 없다)와 '미간'·'인중'·'애교살'이 그렇게 조용히 빠졌다.
void main() {
  const fromServer = <String, String>{
    '이마 중앙': '이마',
    '이마': '이마',
    '미간': '이마',
    '콧대': '코',
    '코끝': '코',
    '콧볼': '코',
    '코': '코',
    '눈썹 위 왼쪽': '왼쪽눈썹',
    '눈썹 바로 밑 오른쪽': '오른쪽눈썹',
    '눈두덩이 왼쪽': '왼쪽눈가',
    '눈 아래 오른쪽': '오른쪽눈가',
    '애교살 왼쪽': '왼쪽눈가',
    '눈꼬리 오른쪽': '오른쪽눈가',
    '눈 왼쪽': '왼쪽눈가',
    '볼 위쪽 왼쪽': '왼쪽볼',
    '볼 중앙 오른쪽': '오른쪽볼',
    '볼 아래쪽 왼쪽': '왼쪽볼',
    '인중': '입술',
    '입 옆': '입술',
    '입': '입술',
    '턱 중앙': '턱선',
    '턱': '턱선',
  };

  test('서버 부위 이름이 전부 아바타 자리로 풀린다', () {
    final missed = <String>[];
    fromServer.forEach((region, want) {
      final got = ResultHologram.keyFor(region);
      if (got != want) missed.add('$region → $got (기대 $want)');
    });
    expect(missed, isEmpty, reason: missed.join('\n'));
  });

  test('좌우가 안 적혀 있으면 한쪽으로 몬다 — 양쪽에 켜지 않는다', () {
    expect(ResultHologram.keyFor('볼 중앙'), '오른쪽볼');
    expect(ResultHologram.keyFor('눈두덩이'), '오른쪽눈가');
  });

  test('얼굴 밖 이름은 조용히 빠진다', () {
    expect(ResultHologram.keyFor('머리카락'), isNull);
    expect(ResultHologram.keyFor('피부'), isNull);
  });

  group('서버가 자리를 지정하면 그걸 쓴다', () {
    test('서버 값이 이름 맞추기를 이긴다', () {
      // 이름으로는 '오른쪽볼'로 몰리지만, 서버는 bbox 로 왼쪽인 걸 안다.
      expect(ResultHologram.keyFor('볼 중앙'), '오른쪽볼');
      expect(ResultHologram.spotFor('볼 중앙', '왼쪽볼'), '왼쪽볼');
    });

    test('모르는 자리를 보내면 이름으로 되돌아간다', () {
      expect(ResultHologram.spotFor('콧대 왼쪽', '귓불'), '코');
      expect(ResultHologram.spotFor('콧대 왼쪽', ''), '코');
      expect(ResultHologram.spotFor('콧대 왼쪽', null), '코');
    });

    test('서버가 보낼 수 있는 자리는 전부 아바타에 있다', () {
      for (final z in ResultHologram.zoneNames) {
        expect(ResultHologram.spotFor('아무거나', z), z);
      }
    });
  });
}
