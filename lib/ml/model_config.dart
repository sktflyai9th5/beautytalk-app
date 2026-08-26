/// 화장품 인식 모델 설정 (Qualcomm MobileNetV3-Small det_head, LiteRT/.tflite).
///
/// 모델: C:\Users\012\MoblieNet-v3-small runs/mt11/best.pt →
///       ONNX(mtnet_det) → onnx2tf → assets/models/cosmetic_det.tflite
/// 입력: 1x384x384x3 (NHWC), RGB 0..1 float — mean/std 정규화는 그래프 안에 포함.
/// 출력: hm(1,48,48,19: sigmoid 적용됨) / wh(1,48,48,2) / off(1,48,48,2)
///
/// 교체 방법: 새 .tflite 를 assets/models/ 에 덮어쓰고 labels.txt 를 클래스 순서로 갱신.
class ModelConfig {
  const ModelConfig({
    this.modelAsset = 'assets/models/cosmetic_both.tflite',
    this.labelsAsset = 'assets/models/labels.txt',
    this.inputSize = 384,
    this.scoreThreshold = 0.30,
    this.dirtyThreshold = 0.60,
    this.blurThreshold = 55.0,
    this.sharpTrust = 150.0,
    this.numThreads = 4,
  });

  final String modelAsset;
  final String labelsAsset;
  final int inputSize;

  /// 히트맵 최고점이 이 값보다 낮으면 "찾지 못함" 처리.
  final double scoreThreshold;

  /// cls_head 의 dirty 확률이 이 값 이상이면 "렌즈를 닦아 주세요" 안내.
  final double dirtyThreshold;

  /// 선명도(가운데 크롭 384px 회색조의 라플라시안 분산)가 이 값 아래면 렌즈가
  /// 젖었거나 뿌연 것으로 본다. cls_head 는 물 자국을 잘 못 잡는다 —
  /// 실제 젖은 렌즈 3장 중 1장만 0.97 이고 둘은 0.03 이었다.
  ///
  /// 수치는 **이 앱의 전처리(image 패키지 linear 리사이즈)** 기준이다. 파이썬 PIL 로
  /// 재면 안티앨리어싱 때문에 절반쯤 나오니 섞어 쓰면 안 된다.
  /// 실측(Dart): 젖은 렌즈 16·25·29 / 깨끗한 렌즈 121(살짝 흔들린 셀카)·218~233·557.
  /// 55 는 양쪽 끝(29 ↔ 121)에서 약 2배씩 떨어진 지점이다.
  /// 단, 아무 무늬 없는 벽이나 어두운 방을 비추면 깨끗해도 걸릴 수 있다.
  final double blurThreshold;

  /// 선명도가 이 값 이상이면 cls_head 의 말을 **듣지 않는다.** 물이 묻은 렌즈는
  /// 이렇게 선명한 그림을 만들 수 없다. 반대로 cls_head 는 깨끗한 렌즈로 찍은
  /// 점박이 천장 타일을 0.78~0.87 로 "더럽다" 고 했다(선명도 214~218) —
  /// 점들을 얼룩으로 읽는다. 실제 젖은 렌즈는 전부 30 아래였다.
  final double sharpTrust;
  final int numThreads;

  static const ModelConfig defaults = ModelConfig();
}
