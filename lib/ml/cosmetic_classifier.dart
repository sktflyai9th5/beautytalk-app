import 'dart:io';
import 'dart:ui' show Rect;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import 'model_config.dart';
import 'product_catalog.dart';

/// 인식 결과.
class CosmeticPrediction {
  const CosmeticPrediction({
    required this.label,
    required this.confidence,
    required this.product,
    this.box,
  });

  final String label;
  final double confidence;
  final ProductInfo product;

  /// 검출 박스 — 원본 사진 기준 0..1 정규화 (left, top, right, bottom).
  /// 결과 화면이 "어디를 보고 그렇게 판단했는지" 그려 준다.
  final Rect? box;
}

/// 렌즈 상태 (cls_head: clean / dirty)
class LensCheck {
  const LensCheck({
    required this.dirtyProb,
    required this.sharpness,
    required this.isDirty,
  });

  /// cls_head 의 dirty 확률
  final double dirtyProb;

  /// 라플라시안 분산 (0..255 회색조 기준). 낮을수록 뿌옇다.
  final double sharpness;
  final bool isDirty;
}

/// 화장품 인식기 인터페이스.
abstract class CosmeticClassifier {
  Future<void> load();
  Future<CosmeticPrediction> classifyFile(String imagePath);

  /// 카메라 렌즈 이물질 검사 (cls_head). 지원하지 않으면 null.
  Future<LensCheck?> checkLens(String imagePath);
  void dispose();
}

/// 모델 파일이 있으면 LiteRT 검출기, 없으면 Mock.
class CosmeticClassifierFactory {
  static Future<CosmeticClassifier> create({
    ModelConfig config = ModelConfig.defaults,
  }) async {
    final det = LiteRtCosmeticDetector(config);
    try {
      await det.load();
      debugPrint('[Classifier] LiteRT detector loaded: ${config.modelAsset}');
      return det;
    } catch (e) {
      debugPrint('[Classifier] LiteRT unavailable ($e) → Mock');
      final mock = MockCosmeticClassifier();
      await mock.load();
      return mock;
    }
  }
}

/// Qualcomm MobileNetV3-Small det_head (CenterNet-lite) — LiteRT(tflite_flutter) 실행.
///
/// 후처리: sigmoid 된 히트맵(1,48,48,C)에서 전체 최고점 하나를 찾아
/// (클래스, 신뢰도)로 변환. 데모 용도로는 bbox 디코드 없이 충분하다.
class LiteRtCosmeticDetector implements CosmeticClassifier {
  LiteRtCosmeticDetector(this.config);

  final ModelConfig config;
  Interpreter? _interpreter;
  List<String> _labels = const [];
  int _hmIndex = 0;
  int _clsIndex = -1;
  int _whIndex = -1;
  int _offIndex = -1; // cls_logits [1,2] (clean, dirty) — 없으면 -1

  @override
  Future<void> load() async {
    final raw = await rootBundle.loadString(config.labelsAsset);
    _labels = raw
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty && !e.startsWith('#'))
        .toList();

    final options = InterpreterOptions()..threads = config.numThreads;
    // TODO(qualcomm): QNN/NNAPI delegate 를 쓸 경우 여기서 addDelegate.
    _interpreter = await Interpreter.fromAsset(config.modelAsset, options: options);

    // 출력 텐서 식별: 클래스 수 채널 = 히트맵, [1,2] = cls_logits(clean/dirty)
    final n = _interpreter!.getOutputTensors().length;
    _hmIndex = -1;
    _clsIndex = -1;
    for (var i = 0; i < n; i++) {
      final shape = _interpreter!.getOutputTensor(i).shape;
      if (shape.contains(_labels.length)) {
        _hmIndex = i;
      } else if (shape.length == 2 && shape[1] == 2) {
        _clsIndex = i;
      } else if (shape.length == 4 && shape.last == 2) {
        // wh / off — tflite 에 이름이 남아 있다. 없으면 내보낸 순서(wh 먼저).
        final name = _interpreter!.getOutputTensor(i).name;
        if (name.contains('off')) {
          _offIndex = i;
        } else if (name.contains('wh') || _whIndex < 0) {
          _whIndex = i;
        } else {
          _offIndex = i;
        }
      }
    }
    if (_hmIndex < 0) {
      throw StateError('heatmap output (C=${_labels.length}) not found');
    }
    debugPrint('[Classifier] outputs=${List.generate(n, (i) => _interpreter!.getOutputTensor(i).shape)} hm=$_hmIndex cls=$_clsIndex');
  }

  /// 한 번 추론한다. 결과는 [_output] 으로 텐서에서 직접 읽는다.
  ///
  /// 입력/출력 모두 **바이트 버퍼**로 주고받는다. tflite_flutter 는 중첩 List 를
  /// 받으면 스칼라마다 4바이트 버퍼를 만들어 이어붙이는데(384*384*3 = 44만 번),
  /// Uint8List 는 그대로 memcpy 하는 빠른 경로를 탄다.
  /// 모델 입력(전처리된 RGB 평탄 배열)을 돌려준다 — 렌즈 검사가 선명도 계산에 다시 쓴다.
  Future<Float32List> _run(String imagePath, {bool centerCrop = false}) async {
    final interpreter = _interpreter!;
    final swPre = Stopwatch()..start();
    final bytes = await File(imagePath).readAsBytes();
    final input = await compute(
        preprocess, PreArgs(bytes, config.inputSize, centerCrop: centerCrop));
    swPre.stop();

    final swInf = Stopwatch()..start();
    interpreter.runInference([input.buffer.asUint8List()]);
    swInf.stop();
    debugPrint('[Classifier] preprocess=${swPre.elapsedMilliseconds}ms '
        'inference=${swInf.elapsedMilliseconds}ms');
    return input;
  }

  /// 출력 텐서를 float 뷰로 읽는다 (네이티브 버퍼 직접 참조 — 복사 없음).
  Float32List _output(int index) {
    final b = _interpreter!.getOutputTensor(index).data;
    return b.buffer.asFloat32List(b.offsetInBytes, b.lengthInBytes ~/ 4);
  }

  @override
  Future<LensCheck?> checkLens(String imagePath) async {
    if (_interpreter == null || _clsIndex < 0) return null;
    final input = await _run(imagePath, centerCrop: true);
    final logits = _output(_clsIndex); // [clean, dirty]
    // softmax
    final m = math.max(logits[0], logits[1]);
    final e0 = math.exp(logits[0] - m), e1 = math.exp(logits[1] - m);
    final dirty = e1 / (e0 + e1);
    final sharp = sharpness(input, config.inputSize);
    final isDirty = lensVerdict(dirty, sharp, config);
    debugPrint('[Classifier] lens dirty=${dirty.toStringAsFixed(3)} '
        'sharp=${sharp.toStringAsFixed(1)} → ${isDirty ? "닦아야 함" : "깨끗"}');
    return LensCheck(dirtyProb: dirty, sharpness: sharp, isDirty: isDirty);
  }

  @override
  Future<CosmeticPrediction> classifyFile(String imagePath) async {
    if (_interpreter == null) throw StateError('model not loaded');
    await _run(imagePath);

    // 히트맵 최고점 탐색 (NHWC: [1,H,W,C] / NCHW: [1,C,H,W] 모두 지원)
    final shape = _interpreter!.getOutputTensor(_hmIndex).shape;
    final hm = _output(_hmIndex);
    var best = 0.0;
    var bestIdx = -1;
    for (var i = 0; i < hm.length; i++) {
      if (hm[i] > best) {
        best = hm[i];
        bestIdx = i;
      }
    }
    // 평탄 인덱스 → 클래스 번호
    final channelLast = shape.last == _labels.length;
    final bestClass = bestIdx < 0
        ? -1
        : channelLast
            ? bestIdx % shape.last // [1,H,W,C]
            : bestIdx ~/ (shape[2] * shape[3]); // [1,C,H,W]

    final label = (best >= config.scoreThreshold &&
            bestClass >= 0 &&
            bestClass < _labels.length)
        ? _labels[bestClass]
        : 'unknown';

    // 어디를 보고 그렇게 판단했는지 — CenterNet 디코드.
    // 최고점 (y,x) + off 로 중심을, wh(피처맵 단위) ×stride 로 크기를 복원한다.
    // 입력이 원본을 통째로 384×384 로 찌그러뜨린 것이라, /384 정규화 좌표는
    // 원본 사진에 그대로 얹으면 된다.
    Rect? box;
    if (label != 'unknown' && _whIndex >= 0 && _offIndex >= 0 && channelLast) {
      final fh = shape[1], fw = shape[2], c = shape.last;
      final cell = bestIdx ~/ c; // 평탄 인덱스 → (y*fw + x)
      final py = cell ~/ fw, px = cell % fw;
      final wh = _output(_whIndex);
      final off = _output(_offIndex);
      final stride = config.inputSize / fw;
      final ox = off[cell * 2].clamp(0.0, 1.0);
      final oy = off[cell * 2 + 1].clamp(0.0, 1.0);
      final bw = wh[cell * 2] * stride;
      final bh = wh[cell * 2 + 1] * stride;
      if (bw > 0 && bh > 0) {
        final cx = (px + ox) * stride, cy = (py + oy) * stride;
        final n = config.inputSize.toDouble();
        box = Rect.fromLTRB(
          ((cx - bw / 2) / n).clamp(0.0, 1.0),
          ((cy - bh / 2) / n).clamp(0.0, 1.0),
          ((cx + bw / 2) / n).clamp(0.0, 1.0),
          ((cy + bh / 2) / n).clamp(0.0, 1.0),
        );
        debugPrint('[Classifier] box=(${box.left.toStringAsFixed(2)},'
            '${box.top.toStringAsFixed(2)})~(${box.right.toStringAsFixed(2)},'
            '${box.bottom.toStringAsFixed(2)}) @($py,$px) fh=$fh');
      }
    }
    debugPrint('[Classifier] best=$label score=${best.toStringAsFixed(3)}');
    return CosmeticPrediction(
      label: label,
      confidence: best,
      product: ProductCatalog.lookup(label),
      box: box,
    );
  }

  @override
  void dispose() {
    _interpreter?.close();
    _interpreter = null;
  }
}

@visibleForTesting
class PreArgs {
  PreArgs(this.bytes, this.size, {this.centerCrop = false});
  final Uint8List bytes;
  final int size;

  /// 가운데 정사각형만 잘라 쓴다. 렌즈 검사 전용 —
  /// 세로 프레임(720×1280)을 정사각으로 찌그러뜨리면 물방울·얼룩의 결이
  /// 뭉개져서, 실제 젖은 렌즈가 0.52 로 문턱(0.60) 아래에 머물렀다.
  /// 크롭하면 같은 프레임이 0.97, 깨끗한 렌즈는 0.14 이하다.
  final bool centerCrop;
}

/// 전체 이미지를 SxS 로 리사이즈 (크롭 없음 — 검출 모델이라 물체가 잘리면 안 됨),
/// RGB 0..1 float, NHWC 평탄 배열. (mean/std 정규화는 그래프 내부에 포함)
///
/// isolate 에서 실행된다. 중첩 List 대신 Float32List 로 만들어야
/// isolate 경계를 넘는 비용도, tflite 입력 변환 비용도 사라진다.
///
/// 픽셀 순서가 틀리면 모델이 조용히 엉뚱한 답을 내므로
/// test/preprocess_test.dart 가 (y, x, c) 배치를 검증한다.
@visibleForTesting
Float32List preprocess(PreArgs args) {
  var decoded = img.decodeImage(args.bytes);
  if (decoded == null) throw StateError('decode failed');
  decoded = img.bakeOrientation(decoded);
  if (args.centerCrop) {
    final s = decoded.width < decoded.height ? decoded.width : decoded.height;
    decoded = img.copyCrop(
      decoded,
      x: (decoded.width - s) ~/ 2,
      y: (decoded.height - s) ~/ 2,
      width: s,
      height: s,
    );
  }
  final resized = img.copyResize(
    decoded,
    width: args.size,
    height: args.size,
    interpolation: img.Interpolation.linear,
  );
  final out = Float32List(args.size * args.size * 3);
  var i = 0;
  for (final p in resized) {
    out[i++] = p.r / 255.0;
    out[i++] = p.g / 255.0;
    out[i++] = p.b / 255.0;
  }
  return out;
}

/// 렌즈가 더러운가. 두 신호를 이렇게 합친다 (model_config 의 세 문턱 참고):
///   · 뿌옇다(선명도 < blurThreshold) → 더럽다. 모델이 뭐라 하든.
///   · 아주 선명하다(≥ sharpTrust) → 깨끗하다. 모델이 뭐라 하든.
///   · 그 사이 → 모델(dirty ≥ dirtyThreshold)을 따른다.
@visibleForTesting
bool lensVerdict(double dirty, double sharp, ModelConfig c) {
  if (sharp < c.blurThreshold) return true;
  if (sharp >= c.sharpTrust) return false;
  return dirty >= c.dirtyThreshold;
}

/// 선명도 — 회색조 라플라시안의 분산. [rgb] 는 preprocess 가 만든
/// 0..1 NHWC 평탄 배열이고, 값은 0..255 회색조 기준으로 돌려준다
/// (수치를 파이썬 PIL 'L' + numpy 와 바로 비교할 수 있게).
@visibleForTesting
double sharpness(Float32List rgb, int size) {
  // ITU-R 601-2 luma — PIL 의 convert('L') 과 같은 계수
  final g = Float32List(size * size);
  for (var i = 0; i < g.length; i++) {
    g[i] = (0.299 * rgb[i * 3] + 0.587 * rgb[i * 3 + 1] + 0.114 * rgb[i * 3 + 2]) * 255;
  }
  var sum = 0.0, sq = 0.0;
  final n = (size - 2) * (size - 2);
  for (var y = 1; y < size - 1; y++) {
    for (var x = 1; x < size - 1; x++) {
      final i = y * size + x;
      final l = -4 * g[i] + g[i - 1] + g[i + 1] + g[i - size] + g[i + size];
      sum += l;
      sq += l * l;
    }
  }
  final mean = sum / n;
  return sq / n - mean * mean;
}

/// 모델이 없을 때의 데모 폴백.
class MockCosmeticClassifier implements CosmeticClassifier {
  @override
  Future<void> load() async {}

  @override
  Future<CosmeticPrediction> classifyFile(String imagePath) async {
    await Future<void>.delayed(const Duration(milliseconds: 900));
    const label = 'brush';
    return CosmeticPrediction(
      label: label,
      confidence: 0.93,
      product: ProductCatalog.lookup(label),
    );
  }

  @override
  Future<LensCheck?> checkLens(String imagePath) async => null;

  @override
  void dispose() {}
}
