/// 모델 라벨 → 사용자에게 읽어줄 문구.
///
/// 라벨은 MobileNetV3 det_head 의 19개 클래스 (runs/mt11/meta.json 의 det_classes 순서,
/// `assets/models/labels.txt` 와 동일해야 함).
class ProductInfo {
  const ProductInfo({
    required this.name,
    required this.description,
    this.usage = '',
  });

  /// 예) "브러쉬"
  final String name;

  /// 예) "이건 브러쉬예요!"
  final String description;

  /// 추가 사용법 (지금은 하드코딩 문구만 사용)
  final String usage;

  String get spoken =>
      [description, usage].where((s) => s.isNotEmpty).join(' ');
}

class ProductCatalog {
  ProductCatalog._();

  /// det 클래스 19종 → "이건 X예요!" 하드코딩.
  static const Map<String, ProductInfo> _items = {
    'base_skincare': ProductInfo(name: '기초 화장품', description: '이건 기초 화장품이에요!'),
    'beauty blender': ProductInfo(name: '뷰티 블렌더', description: '이건 뷰티 블렌더예요!'),
    'blush': ProductInfo(name: '블러셔', description: '이건 블러셔예요!'),
    'bronzer': ProductInfo(name: '브론저', description: '이건 브론저예요!'),
    'brush': ProductInfo(name: '브러쉬', description: '이건 브러쉬예요!'),
    'concealer': ProductInfo(name: '컨실러', description: '이건 컨실러예요!'),
    'eyelash_item': ProductInfo(name: '속눈썹 도구', description: '이건 속눈썹 도구예요!'),
    'eye liner': ProductInfo(name: '아이라이너', description: '이건 아이라이너예요!'),
    'eye shade': ProductInfo(name: '아이섀도우', description: '이건 아이섀도우예요!'),
    'highlighter': ProductInfo(name: '하이라이터', description: '이건 하이라이터예요!'),
    'lip balm': ProductInfo(name: '립밤', description: '이건 립밤이에요!'),
    'lip gloss': ProductInfo(name: '립글로스', description: '이건 립글로스예요!'),
    'lip liner': ProductInfo(name: '립라이너', description: '이건 립라이너예요!'),
    'lipstick': ProductInfo(name: '립스틱', description: '이건 립스틱이에요!'),
    'mascara': ProductInfo(name: '마스카라', description: '이건 마스카라예요!'),
    'nail polish': ProductInfo(name: '매니큐어', description: '이건 매니큐어예요!'),
    'nail polish remover': ProductInfo(name: '네일 리무버', description: '이건 네일 리무버예요!'),
    'powder': ProductInfo(name: '파우더', description: '이건 파우더예요!'),
    'tint': ProductInfo(name: '틴트', description: '이건 틴트예요!'),
  };

  /// 탐지 실패(낮은 신뢰도) 안내
  static const ProductInfo notFound = ProductInfo(
    name: '화장품을 찾지 못했어요',
    description: '화장품이 잘 보이지 않아요. 15센티미터 거리에서 다시 촬영해 주세요.',
  );

  static ProductInfo lookup(String label) {
    if (label == 'unknown') return notFound;
    return _items[label] ?? ProductInfo(name: label, description: '이건 $label 이에요!');
  }
}
