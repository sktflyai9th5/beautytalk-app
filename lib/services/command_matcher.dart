import 'dart:math' as math;

/// 한국어 음성 명령 매칭기.
///
/// 온디바이스 STT 는 짧은 명령을 자주 틀린다("화장품"→"화장뿜", "가이드"→"가있드").
/// 우리 명령어는 **닫힌 집합**이라, 자모 단위 편집거리로 가장 가까운 명령을 찾으면
/// 인식기를 바꾸지 않고도 적중률을 크게 올릴 수 있다.
///
/// 또한 STT 는 여러 후보(alternates)를 주는데 1순위만 쓰면 정보를 버리는 것이므로,
/// [matchAny] 로 모든 후보를 검사한다.
class CommandMatcher {
  CommandMatcher._();

  // ── 한글 자모 분해 ────────────────────────────────────────────
  static const _cho = 'ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ';
  static const _jung = 'ㅏㅐㅑㅒㅓㅔㅕㅖㅗㅘㅙㅚㅛㅜㅝㅞㅟㅠㅡㅢㅣ';
  static const _jong = ' ㄱㄲㄳㄴㄵㄶㄷㄹㄺㄻㄼㄽㄾㄿㅀㅁㅂㅄㅅㅆㅇㅈㅊㅋㅌㅍㅎ';

  /// "화장품" → "ㅎㅘㅈㅏㅇㅍㅜㅁ"
  /// 오인식은 대개 자음 하나 차이라, 자모로 펴면 유사도가 훨씬 정확해진다.
  static String decompose(String s) {
    final b = StringBuffer();
    for (final r in s.runes) {
      if (r >= 0xAC00 && r <= 0xD7A3) {
        final i = r - 0xAC00;
        b.write(_cho[i ~/ 588]);
        b.write(_jung[(i % 588) ~/ 28]);
        final j = _jong[i % 28];
        if (j != ' ') b.write(j);
      } else if (r != 0x20) {
        b.writeCharCode(r);
      }
    }
    return b.toString();
  }

  /// 편집거리 (Levenshtein)
  static int _edit(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    var prev = List<int>.generate(b.length + 1, (i) => i);
    final cur = List<int>.filled(b.length + 1, 0);
    for (var i = 1; i <= a.length; i++) {
      cur[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        cur[j] = math.min(math.min(cur[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost);
      }
      prev = List<int>.from(cur);
    }
    return prev[b.length];
  }

  /// 자모 기준 유사도 0.0~1.0
  static double similarity(String a, String b) {
    final ja = decompose(a);
    final jb = decompose(b);
    if (ja.isEmpty || jb.isEmpty) return 0;
    final d = _edit(ja, jb);
    return 1.0 - d / math.max(ja.length, jb.length);
  }

  /// [text] 안에 [keyword] 와 충분히 비슷한 부분이 있는지.
  ///
  /// 정확히 포함되면 즉시 true. 아니면 키워드 길이만큼의 창을 밀며
  /// 자모 유사도가 [threshold] 이상인 구간을 찾는다.
  static bool containsFuzzy(String text, String keyword, {double threshold = 0.75}) {
    final t = text.replaceAll(' ', '');
    final k = keyword.replaceAll(' ', '');
    if (t.contains(k)) return true;
    if (t.length < k.length) return similarity(t, k) >= threshold;
    for (var i = 0; i + k.length <= t.length; i++) {
      // 길이 ±1 창까지 확인 (음절이 하나 더/덜 붙는 오인식 대응)
      for (final len in [k.length, k.length + 1]) {
        if (i + len > t.length) continue;
        if (similarity(t.substring(i, i + len), k) >= threshold) return true;
      }
    }
    return false;
  }

  /// 여러 인식 후보 중 하나라도 [keyword] 와 맞으면 true.
  ///
  /// STT 1순위가 틀려도 2·3순위에 정답이 있는 경우가 흔하다.
  static bool matchAny(
    Iterable<String> candidates,
    String keyword, {
    double threshold = 0.75,
  }) {
    for (final c in candidates) {
      if (containsFuzzy(c, keyword, threshold: threshold)) return true;
    }
    return false;
  }

  /// 후보들 중 [vocabulary] 의 어떤 단어와 가장 잘 맞는지 찾는다.
  /// 반환: (매칭된 단어, 유사도) — 임계값 미만이면 null.
  static (String, double)? bestMatch(
    Iterable<String> candidates,
    Iterable<String> vocabulary, {
    double threshold = 0.75,
  }) {
    String? bestWord;
    var bestScore = 0.0;
    for (final c in candidates) {
      final t = c.replaceAll(' ', '');
      if (t.isEmpty) continue;
      for (final w in vocabulary) {
        if (t.contains(w)) return (w, 1.0);
        final s = similarity(t, w);
        if (s > bestScore) {
          bestScore = s;
          bestWord = w;
        }
        // 부분 문자열 창 검사
        final k = w.replaceAll(' ', '');
        if (t.length >= k.length) {
          for (var i = 0; i + k.length <= t.length; i++) {
            final s2 = similarity(t.substring(i, i + k.length), k);
            if (s2 > bestScore) {
              bestScore = s2;
              bestWord = w;
            }
          }
        }
      }
    }
    if (bestWord != null && bestScore >= threshold) return (bestWord, bestScore);
    return null;
  }
}
