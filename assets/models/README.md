# 화장품 인식 모델 넣는 곳

학습이 끝난 Qualcomm MobileNet 모델을 이 폴더에 넣으면 앱이 자동으로 사용합니다.
(파일이 없으면 데모용 Mock 분류기가 동작합니다 — 화면 하단에 "데모 모델" 표시)

```
assets/models/
├─ cosmetic_mobilenet.tflite   ← Qualcomm AI Hub 에서 export 한 .tflite
├─ labels.txt                  ← 클래스 순서대로 한 줄에 하나
└─ README.md
```

## 교체 절차

1. `cosmetic_mobilenet.tflite` 를 이 폴더에 복사 (파일명이 다르면 `lib/ml/model_config.dart` 의 `modelAsset` 수정)
2. `labels.txt` 를 학습 클래스 순서로 갱신
3. 입력 규격이 다르면 `lib/ml/model_config.dart` 만 수정
   - `inputWidth/inputHeight` (기본 224)
   - `inputIsFloat` (float32 정규화 vs uint8 원본) / `mean`, `std`
   - `applySoftmax` (출력이 logits 이면 true)
4. `lib/ml/product_catalog.dart` 에 라벨별 이름·설명·사용법 추가 (음성으로 읽어줌)
5. `flutter run` — 재빌드하면 끝. 코드 변경 없이 모델만 갈아끼울 수 있습니다.

## QNN(Hexagon NPU) 가속

`lib/ml/cosmetic_classifier.dart` 의 `TfliteCosmeticClassifier._buildOptions()` 에서
delegate 를 추가하면 됩니다. 기본은 CPU 4 스레드.
