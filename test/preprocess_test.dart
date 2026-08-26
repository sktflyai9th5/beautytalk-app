import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:beauty_talk/ml/cosmetic_classifier.dart';
import 'package:beauty_talk/ml/model_config.dart';

/// 모델 입력 텐서의 픽셀 배치 검증.
///
/// 전처리는 Float32List 평탄 배열을 만드는데, 순서가 (y, x, c) 가 아니면
/// 모델은 **에러 없이 엉뚱한 답**을 낸다. 그래서 이 배치만 따로 못 박아 둔다.
void main() {
  /// 픽셀마다 값이 전부 다른 이미지 — 순서가 틀리면 반드시 걸린다.
  /// (좌우/상하/채널 중 하나만 뒤집혀도 값이 어긋난다)
  img.Image asymmetricImage(int size) {
    final im = img.Image(width: size, height: size);
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        im.setPixelRgb(x, y, x % 256, y % 256, (x + 2 * y) % 256);
      }
    }
    return im;
  }

  test('입력 텐서는 NHWC (y, x, c) 순서로 채워진다', () {
    const size = 32;
    final src = asymmetricImage(size);
    final out = preprocess(PreArgs(img.encodePng(src), size));

    expect(out.length, size * size * 3, reason: '384x384x3 평탄 배열');

    // 리사이즈가 항등(같은 크기)이므로 원본 픽셀과 1:1로 맞아야 한다
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        final p = src.getPixel(x, y);
        final base = (y * size + x) * 3;
        expect(out[base + 0], closeTo(p.r / 255.0, 1e-6), reason: 'R($x,$y)');
        expect(out[base + 1], closeTo(p.g / 255.0, 1e-6), reason: 'G($x,$y)');
        expect(out[base + 2], closeTo(p.b / 255.0, 1e-6), reason: 'B($x,$y)');
      }
    }
  });

  test('가로세로가 다른 이미지도 정사각으로 리사이즈된다 (크롭 없음)', () {
    // 검출 모델이라 물체가 잘리면 안 되므로, 비율을 무시하고 늘려 담는다
    final wide = img.Image(width: 64, height: 16);
    img.fill(wide, color: img.ColorRgb8(255, 0, 0));
    final out = preprocess(PreArgs(img.encodePng(wide), 32));

    expect(out.length, 32 * 32 * 3);
    expect(out[0], closeTo(1.0, 1e-6)); // R
    expect(out[1], closeTo(0.0, 1e-6)); // G
    expect(out[2], closeTo(0.0, 1e-6)); // B
  });

  test('값은 0..1 범위로 정규화된다', () {
    final im = img.Image(width: 8, height: 8);
    img.fill(im, color: img.ColorRgb8(0, 128, 255));
    final out = preprocess(PreArgs(img.encodePng(im), 8));

    expect(out.reduce((a, b) => a < b ? a : b), greaterThanOrEqualTo(0.0));
    expect(out.reduce((a, b) => a > b ? a : b), lessThanOrEqualTo(1.0));
    expect(out[0], closeTo(0.0, 1e-6));
    expect(out[1], closeTo(128 / 255.0, 1e-6));
    expect(out[2], closeTo(1.0, 1e-6));
  });

  test('centerCrop 은 가운데 정사각형만 남긴다', () {
    // 40×20: 왼쪽 10열 빨강 / 가운데 20열 초록 / 오른쪽 10열 파랑.
    // 가운데 20×20 만 남기면 전부 초록이어야 한다.
    final im = img.Image(width: 40, height: 20);
    for (var y = 0; y < 20; y++) {
      for (var x = 0; x < 40; x++) {
        im.setPixelRgb(x, y, x < 10 ? 255 : 0, x >= 10 && x < 30 ? 255 : 0,
            x >= 30 ? 255 : 0);
      }
    }
    final out = preprocess(PreArgs(img.encodePng(im), 8, centerCrop: true));
    for (var i = 0; i < 8 * 8; i++) {
      expect(out[i * 3], 0.0, reason: 'pixel $i r');
      expect(out[i * 3 + 1], 1.0, reason: 'pixel $i g');
      expect(out[i * 3 + 2], 0.0, reason: 'pixel $i b');
    }
    // 크롭 없이 찌그러뜨리면 빨강·파랑이 섞여 들어온다
    final squashed = preprocess(PreArgs(img.encodePng(im), 8));
    expect(squashed[0], 1.0); // 첫 픽셀은 빨강
  });

  group('sharpness', () {
    test('민무늬는 0, 바둑판은 크다', () {
      const n = 16;
      final flat = Float32List(n * n * 3)..fillRange(0, n * n * 3, 0.5);
      expect(sharpness(flat, n), closeTo(0, 1e-6));

      final board = Float32List(n * n * 3);
      for (var y = 0; y < n; y++) {
        for (var x = 0; x < n; x++) {
          final v = (x + y).isEven ? 1.0 : 0.0;
          board[(y * n + x) * 3] = v;
          board[(y * n + x) * 3 + 1] = v;
          board[(y * n + x) * 3 + 2] = v;
        }
      }
      // 픽셀마다 |라플라시안| = 4*255 이고 부호가 번갈아 → 평균 0, 분산 = (1020)^2
      expect(sharpness(board, n), closeTo(1020 * 1020, 1));
    });

    test('뿌옇게 만들면 떨어진다', () {
      const n = 32;
      // 줄무늬 → 흐리게(이웃 평균) 하면 분산이 줄어야 한다
      Float32List stripes(bool blur) {
        final g = List<double>.generate(n * n, (i) => (i % n) % 4 < 2 ? 1.0 : 0.0);
        final src = blur
            ? List<double>.generate(n * n, (i) {
                final x = i % n;
                final l = g[i - (x > 0 ? 1 : 0)], r = g[i + (x < n - 1 ? 1 : 0)];
                return (l + g[i] + r) / 3;
              })
            : g;
        final out = Float32List(n * n * 3);
        for (var i = 0; i < n * n; i++) {
          out[i * 3] = out[i * 3 + 1] = out[i * 3 + 2] = src[i];
        }
        return out;
      }
      expect(sharpness(stripes(true), n), lessThan(sharpness(stripes(false), n)));
    });
  });

  group('lensVerdict', () {
    const c = ModelConfig.defaults;
    test('뿌옇면 모델이 깨끗하다 해도 더럽다 (젖은 렌즈 16·25·29)', () {
      expect(lensVerdict(0.03, 25, c), isTrue);
    });
    test('아주 선명하면 모델이 더럽다 해도 깨끗하다 (점박이 천장 0.8 @ 215)', () {
      expect(lensVerdict(0.85, 215, c), isFalse);
    });
    test('그 사이에서는 모델을 따른다', () {
      expect(lensVerdict(0.88, 100, c), isTrue);
      expect(lensVerdict(0.09, 121, c), isFalse);
    });
  });
}
