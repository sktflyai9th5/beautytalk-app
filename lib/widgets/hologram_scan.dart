import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../services/scan_sfx.dart';
import '../theme/app_theme.dart';

/// 사진 위에 얼굴을 따라 붙는 격자.
///
/// `tools/hologram/make_demo_assets.py` 가 만든 좌표를 담는다. 값은 전부
/// 사진 안에서의 0~1 위치다.
class FaceOverlay {
  const FaceOverlay({
    required this.points,
    required this.mesh,
    required this.edges,
    required this.contours,
  });

  /// 하이라이트로 찍히는 특징점. 격자 전체를 찍으면 얼굴이 덮여서
  /// 몇 개만 골라 둔 것이다.
  final List<Offset> points;

  /// 격자의 정점 478개. [edges] 와 [contours] 가 이 인덱스를 가리킨다.
  final List<Offset> mesh;

  /// 성글게 솎아 다시 삼각분할한 격자 선.
  final List<(int, int)> edges;

  /// 눈·눈썹·입술·얼굴 윤곽선. 격자를 성글게 하면 이목구비가 사라지는데,
  /// 얼굴을 알아보게 하는 건 결국 이 선들이라 따로 들고 진하게 그린다.
  final List<(int, int)> contours;

  /// 격자가 사진 안에서 차지하는 사각형(0~1).
  ///
  /// 3D 아바타를 이 자리에 맞춰 놓아야 사진 위 격자가 **그대로** 떠오르는
  /// 것처럼 보인다. 자리가 어긋나면 "바뀌었다" 가 아니라 "잘렸다" 로 보인다.
  Rect get bounds {
    if (mesh.isEmpty) return const Rect.fromLTRB(0, 0, 1, 1);
    var l = mesh.first.dx, t = mesh.first.dy, r = l, b = t;
    for (final p in mesh) {
      if (p.dx < l) l = p.dx;
      if (p.dx > r) r = p.dx;
      if (p.dy < t) t = p.dy;
      if (p.dy > b) b = p.dy;
    }
    return Rect.fromLTRB(l, t, r, b);
  }

  static Future<FaceOverlay?> load(String asset) async {
    try {
      final raw = await rootBundle.loadString(asset);
      final map = jsonDecode(raw) as Map<String, dynamic>;

      List<Offset> toOffsets(String key) => [
            for (final p in (map[key] as List? ?? const []))
              Offset((p[0] as num).toDouble(), (p[1] as num).toDouble()),
          ];

      List<(int, int)> toPairs(String key) => [
            for (final e in (map[key] as List? ?? const []))
              (e[0] as int, e[1] as int),
          ];

      return FaceOverlay(
        points: toOffsets('points'),
        mesh: toOffsets('mesh'),
        edges: toPairs('edges'),
        contours: toPairs('contours'),
      );
    } catch (_) {
      // 좌표가 없어도 빔과 홀로그램은 그대로 돈다.
      return null;
    }
  }
}

/// 구운 아바타의 첫 프레임이 이미지 안에서 차지하는 영역.
///
/// `tools/hologram/measure_hologram.py` 가 재서 남긴 값이다. 이게 있어야
/// 아바타를 2D 격자 자리에 정확히 겹쳐 놓을 수 있다.
class HologramFit {
  const HologramFit(this.content);
  final Rect content;

  static Future<HologramFit?> load(String asset) async {
    try {
      final raw = await rootBundle.loadString(asset);
      final v = (jsonDecode(raw) as Map<String, dynamic>)['content'] as List;
      return HologramFit(Rect.fromLTRB(
        (v[0] as num).toDouble(),
        (v[1] as num).toDouble(),
        (v[2] as num).toDouble(),
        (v[3] as num).toDouble(),
      ));
    } catch (_) {
      return null;
    }
  }
}

/// 부위마다 **프레임별로** 화면 어디에 찍히는지.
///
/// `render_hologram.py --zones` 가 매 프레임 실제 정점을 카메라에 투영해
/// 남긴 값이다. 얼굴이 좌우로 훑는데 짚는 점이 고정돼 있으면 이마를 짚던
/// 점이 관자놀이로 밀려난다 — 각도를 어림해 계산하지 않고 구울 때 잰 값을 쓴다.
///
/// 좌표계는 **구운 이미지 기준 0~1** 이다. 화면에 얹으려면
/// [HologramPlacement] 를 거쳐야 한다.
class ZoneTrack {
  const ZoneTrack(this.names, this.frames, this.mesh, this.tris);

  final List<String> names;

  /// [프레임][부위] → 이미지 안 위치. 화면 밖으로 나간 값도 그대로 있다.
  final List<List<Offset?>> frames;

  /// [프레임][격자 꼭짓점] → 이미지 안 위치. 성근 격자의 점들이다.
  final List<List<Offset?>> mesh;

  /// 부위 이름 → 그 자리를 덮는 삼각형(= [mesh] 안의 번호 셋).
  final Map<String, List<List<int>>> tris;

  int get length => frames.length;

  /// 이름으로 찾은 자리. 없으면 -1.
  int indexOf(String name) => names.indexOf(name);

  /// 프레임을 감아서 읽는다. 루프를 도는 값이라 나머지 연산이 맞다.
  List<Offset?> at(int frame) =>
      frames.isEmpty ? const [] : frames[frame % frames.length];

  /// 그 프레임의 격자 꼭짓점들.
  List<Offset?>? meshAt(int frame) =>
      mesh.isEmpty ? null : mesh[frame % mesh.length];

  static Future<ZoneTrack?> load(String asset) async {
    try {
      final map = jsonDecode(await rootBundle.loadString(asset))
          as Map<String, dynamic>;
      final names = [for (final n in map['names'] as List) n as String];
      final frames = [
        for (final f in map['frames'] as List)
          [
            for (final p in f as List)
              p == null
                  ? null
                  : Offset((p[0] as num).toDouble(), (p[1] as num).toDouble()),
          ],
      ];
      List<List<Offset?>> readFrames(Object? raw) => [
            for (final f in (raw as List? ?? const []))
              [
                for (final p in f as List)
                  p == null
                      ? null
                      : Offset(
                          (p[0] as num).toDouble(), (p[1] as num).toDouble()),
              ],
          ];

      final tris = <String, List<List<int>>>{
        for (final e in (map['tris'] as Map? ?? const {}).entries)
          e.key as String: [
            for (final t in e.value as List) [for (final i in t as List) i as int],
          ],
      };

      if (names.isEmpty || frames.isEmpty) return null;
      return ZoneTrack(names, frames, readFrames(map['mesh']), tris);
    } catch (_) {
      // 없으면 고정 좌표로 되돌아간다. 짚는 점이 멈춰 있을 뿐 연출은 돈다.
      return null;
    }
  }
}

/// 구운 이미지를 화면 어디에 어떻게 얹었는지.
///
/// 아바타와 **그 위에 얹는 표시가 같은 셈을 써야** 한다. 따로 계산하면
/// 조준틀이 얼굴에서 미끄러진다. 그래서 한 번 만들어 둘 다에 넘긴다.
class HologramPlacement {
  const HologramPlacement._(this._scale, this._dx, this._dy);

  final double _scale;
  final double _dx;
  final double _dy;

  /// 이미지가 정사각이라 `BoxFit.contain` 은 짧은 변에 맞춰 넣는다.
  static HologramPlacement? of(HologramFit? fit, Rect? target, Size box) {
    final content = fit?.content;
    final want = target;
    final w = box.width, h = box.height;
    // 자리를 못 잡았으면(폭 0) 계산이 NaN 이 되어 통째로 사라진다.
    if (content == null || want == null || content.width <= 0 ||
        !(w > 0 && h > 0)) {
      return null;
    }
    final side = w < h ? w : h;
    final imgLeft = (w - side) / 2, imgTop = (h - side) / 2;

    final cw = content.width * side, ch = content.height * side;
    final ccx = imgLeft + (content.left + content.width / 2) * side;
    final ccy = imgTop + (content.top + content.height / 2) * side;

    final tw = want.width * w, th = want.height * h;
    final tcx = (want.left + want.width / 2) * w;
    final tcy = (want.top + want.height / 2) * h;

    // 가로세로 중 덜 넘치는 쪽에 맞춘다. 넘치면 잘려 보인다.
    final scale = (tw / cw) < (th / ch) ? tw / cw : th / ch;
    return HologramPlacement._(scale, tcx - ccx * scale, tcy - ccy * scale);
  }

  /// 맞출 자리 없이 상자를 꽉 채울 때 (`BoxFit.contain` 과 같다).
  static const HologramPlacement contain = HologramPlacement._(1, 0, 0);

  /// [contain] 을 상자 한가운데에서 [k] 배로 키운다.
  ///
  /// 구운 판은 정사각인데 머리는 그 안에서 가로로 6할쯤만 쓴다 — 상자에
  /// 그냥 담으면 얼굴이 화면 너비의 6할밖에 안 된다. 키워서 담고 넘치는
  /// 여백은 자른다 (머리는 세로가 길어서 좌우로는 안 잘린다).
  static HologramPlacement zoom(double k, Size box) => HologramPlacement._(
        k,
        box.width / 2 * (1 - k),
        box.height / 2 * (1 - k),
      );

  /// 이미지 안 비율 좌표 → 화면 좌표.
  ///
  /// `contain` 여백(imgLeft/imgTop)은 위젯이 그리는 그림에 이미 들어 있어서
  /// [transform] 에는 없다. 좌표를 직접 옮길 때는 여기서 더해 줘야 한다.
  Offset map(Offset uv, Size box) {
    final w = box.width, h = box.height;
    final side = w < h ? w : h;
    final imgLeft = (w - side) / 2, imgTop = (h - side) / 2;
    return Offset(
      _dx + (imgLeft + uv.dx * side) * _scale,
      _dy + (imgTop + uv.dy * side) * _scale,
    );
  }

  Matrix4 get transform => Matrix4.identity()
    ..translateByDouble(_dx, _dy, 0, 1)
    ..scaleByDouble(_scale, _scale, 1, 1);
}

/// 어두운 선 뒤에 까는 흰 후광.
///
/// 굵고 흐린 흰 선을 먼저 긋고 그 위에 진한 선을 얹으면, 배경이 무엇이든
/// 선이 떠 보인다 — 지도 글자·자막이 배경을 안 타는 것과 같은 방법이고,
/// 밝은 테두리 + 어두운 심지라서 **금속을 새긴 것처럼** 읽힌다.
///
/// [width] 는 위에 얹을 선의 굵기다. 후광은 그보다 넉넉해야 테두리가 된다.
void _haloStroke(Canvas canvas, Path path, double width, double alpha) {
  canvas.drawPath(
    path,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width + 1.6
      ..strokeJoin = StrokeJoin.round
      // **아주 옅게.** 이 후광은 흰 선이 밝은 피부에 묻히지 않게 받쳐 주는
      // 그림자일 뿐이다. 진하게 깔면 그게 검은 선으로 보이고, 정작 흰 선은
      // 그 안의 가는 심지처럼 되어 버린다 — 실제로 그렇게 보였다.
      ..color =
          ScanTone.halo.withValues(alpha: (alpha * ScanTone.haloAlpha).clamp(0, 1))
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.4),
  );
}

/// 분석 연출에 쓰는 색. 그래파이트 실버와 흰 후광이다.
///
/// **밝은 은색을 그대로 쓰지 않는다.** 은색은 모던하지만 밝은 얼굴 위에서는
/// 대비가 없어 멀리서 사라진다 — 실제로 "멀리서 안 보인다" 가 문제였다.
/// 그래서 심지는 푸른기 도는 짙은 회색으로 두고, **뒤에 흰 후광**을 깔아
/// 금속처럼 도드라지게 한다. 밝은 은빛 인상은 후광이 만들고, 대비는 심지가
/// 지킨다. 지도 글자나 자막이 배경을 안 타는 것과 같은 방법이다.
///
/// **밝기 순서는 밝은 화면 기준이다.** 어두운 색은 진할수록 잘 보이므로,
/// 가장 눈에 띄어야 하는 잡힌 점이 가장 진하고 격자가 가장 연하다.
class ScanTone {
  /// 스캔선 잔상, 아바타 뒤 후광.
  static const mist = Color(0xFFE3E6EA);

  /// 선 뒤에 까는 흰 후광. 이게 있어야 어두운 선이 얼굴에서 떠 보인다.
  /// 선 뒤에 까는 후광. 선이 흰색이 되면서 **어둡게 뒤집었다** —
  /// 흰 선 뒤에 흰 후광을 깔면 밝은 피부 위에서 둘 다 사라진다.
  static const halo = Color(0xFF2B3238);

  /// 후광을 얼마나 진하게 깔지. 흰 선을 받쳐 줄 만큼만 — 이 값이 크면
  /// 후광이 검은 선처럼 보인다.
  static const haloAlpha = 0.16;

  /// 격자의 기본 선. 홀로그램 에셋의 선 색과 같은 값이다 —
  /// 사진 위 격자가 그대로 3D 로 떠오르는 것처럼 보이려면 같아야 한다.
  static const line = Color(0xFFFFFFFF);

  /// 이목구비 윤곽, 지시선, 조준틀, 스캔선. **그리는 데만 쓴다.**
  static const strong = Color(0xFFFFFFFF);

  /// 잡힌 점(하이라이트). 가장 진하다 — 피부 위에서 가장 눈에 띄어야 한다.
  static const glint = Color(0xFFF2F6F8);

  /// 결과에서 문제 부위를 켜는 흰빛.
  static const mark = Color(0xFFFFFFFF);

  /// **글자에 쓰는 색.** 선 밝기를 만져도 글자는 여기 고정이다.
  static const ink = Color(0xFF1B2026);

  /// 계측값 글자. 읽히되 앞으로 나서지 않는다.
  /// 계기 글자. 흰 바탕에 얹히므로 회색이 옅으면 안 읽힌다.
  static const label = Color(0xFF56606A);

  /// 분석 표시를 얼마나 옅게 얹을지.
  ///
  /// 0.55 까지 내렸다가 1 로 되돌렸다 — **멀리서 보면 옅은 선이 통째로
  /// 사라진다.** 흰 후광이 사진을 가리지 않고 선을 띄워 주므로, 꽉 채워도
  /// 얼굴이 비쳐 보인다. 옅게 하고 싶으면 이 값만 내리면 된다.
  /// 선을 얼마나 진하게 얹을지. 흰 선은 옅으면 아예 안 보여서 올려 잡는다.
  static const scrim = 0.9;

  /// 선을 얼마나 굵게 그을지. 기준 굵기에 곱한다.
  ///
  /// 멀리서 보이라고 1.3 까지 올렸었는데, 얼굴 위에서 선이 두꺼워 보인다는
  /// 이야기가 있어 살짝 내렸다. 흰 후광이 아직 남아 있어 대비는 그대로다.
  static const weight = 1.12;
}

/// 결과 화면에서 **문제가 있는 자리를 아바타 위에 빛으로 켠다.**
///
/// 색을 칠하는 것보다 빛이 직관적이다 — 칠은 "여기에 뭘 발랐다" 로 읽히지만
/// 빛은 "여기를 보라" 로 읽힌다. 그래서 더하기 합성([BlendMode.plus])으로
/// 얹는다. 아래에 깔린 피부색이 그대로 살아 있어야 무엇이 문제인지 보인다.
///
/// 아바타가 좌우로 훑으므로 빛도 [ZoneTrack] 을 따라 같이 움직인다.
///
/// **스캔 바가 없는 판을 따로 쓴다** (`face_hologram_result.webp`). 분석용
/// 판에는 위아래로 훑는 막대가 구워져 있는데, 결과인데 그게 계속 지나가면
/// 아직 분석 중인 것으로 보인다. 얼굴이 좌우로 도는 건 그대로 둔다 —
/// 멈춰 세우면 화면이 죽는다.
///
/// **아바타는 미리 구워 둔 한 사람의 얼굴이다.** 사용자 본인의 얼굴이 아니다.
/// 분석 화면에서 쓰던 시각화를 결과에서도 이어 쓰는 것이라 지금은 이대로 두지만,
/// 기기에서 사람마다 3D 를 만들 수 있게 되면 그때 갈아 끼워야 한다.
class ResultHologram extends StatefulWidget {
  const ResultHologram({
    super.key,
    required this.regions,
    this.zones,
    this.active,
    this.hologramAsset = 'assets/hologram/face_hologram_result.webp',
  });

  /// 서버가 준 부위 이름 목록. 자리를 못 찾은 것은 조용히 건너뛴다.
  final List<String> regions;

  /// 서버가 직접 지정한 자리. [regions] 와 같은 순서로 짝을 이룬다.
  /// 있으면 이름 맞추기보다 **이쪽을 먼저 쓴다** — 서버는 bbox 로 좌우를
  /// 실제로 알기 때문이다. 옛 서버는 안 보내므로 없거나 짧을 수 있다.
  final List<String?>? zones;

  /// 지금 고른 항목. 그것만 밝게 켜고 나머지는 낮춘다.
  final int? active;

  final String hologramAsset;

  /// 아바타를 구울 때 쓴 자리 이름 전부. 서버가 보낸 값을 이걸로 검사한다 —
  /// 오타나 새 이름이 오면 조용히 무시하지 말고 이름 맞추기로 되돌아간다.
  static const zoneNames = {
    '이마', '왼쪽눈썹', '오른쪽눈썹', '왼쪽눈가', '오른쪽눈가',
    '왼쪽볼', '오른쪽볼', '코', '입술', '턱선',
  };

  /// 불을 켤 자리. **서버가 정한 것이 우선이다** — 서버는 bbox 와 랜드마크로
  /// 좌우를 실제로 알지만, [keyFor] 는 이름에 좌우가 안 적혀 있으면 한쪽으로
  /// 몰아 찍는 수밖에 없다. 서버가 안 보내거나 모르는 이름을 보내면 그때만
  /// 이름으로 찾는다.
  static String? spotFor(String region, [String? zone]) {
    if (zone != null && zoneNames.contains(zone)) return zone;
    return keyFor(region);
  }

  /// 부위 이름 → 구울 때 쓴 키. 좌우가 안 적혀 있으면 한쪽으로 몰아 준다 —
  /// 양쪽에 다 켜면 어디를 보라는 건지 알 수 없다.
  static String? keyFor(String region) {
    final r = region.replaceAll(' ', '');
    final left = r.contains('왼') || r.contains('좌');
    String side(String base) => '${left ? '왼쪽' : '오른쪽'}$base';

    // **순서가 규칙이다.** 서버 이름은 서로 글자를 나눠 갖는다 —
    // '눈썹 바로 밑' 은 '눈' 보다 먼저, '콧볼' 은 '볼' 보다 먼저 걸러야
    // 엉뚱한 자리에 불이 켜진다.
    if (r.contains('이마') || r.contains('미간')) return '이마';
    if (r.contains('눈썹')) return side('눈썹');
    // 콧대·콧볼·코끝 — '콧' 에는 '코' 라는 글자가 없다. 둘 다 본다.
    if (r.contains('코') || r.contains('콧')) return '코';
    if (r.contains('눈') || r.contains('애교살')) return side('눈가');
    if (r.contains('볼') || r.contains('뺨')) return side('볼');
    if (r.contains('입') || r.contains('인중')) return '입술';
    if (r.contains('턱')) return '턱선';
    return null;
  }

  @override
  State<ResultHologram> createState() => _ResultHologramState();
}

class _ResultHologramState extends State<ResultHologram>
    with SingleTickerProviderStateMixin {
  ZoneTrack? _track;
  final ValueNotifier<int> _frame = ValueNotifier(0);

  /// 반짝임 전용 시계. 아바타가 멈추므로 프레임 번호를 위상으로 쓸 수 없다.
  late final AnimationController _sparkle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _sparkle.dispose();
    _frame.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final path =
        widget.hologramAsset.replaceAll(RegExp(r'\.webp$'), '_zones.json');
    final loaded = await ZoneTrack.load(path);
    if (!mounted || loaded == null) return;
    setState(() => _track = loaded);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      return AnimatedBuilder(
        animation: Listenable.merge([_frame, _sparkle]),
        builder: (context, _) {
          final frame = _frame.value;
          final track = _track;
          final size = box.biggest;
          // 분석 화면과 **같은 배율**이다 (_HologramScanState._faceZoom).
          final place = HologramPlacement.zoom(1.12, size);

          // 부위마다 그 자리를 덮는 삼각형을 화면 좌표로 푼다.
          final patches = <List<Offset>?>[];
          for (var i = 0; i < widget.regions.length; i++) {
            final region = widget.regions[i];
            final sent = switch (widget.zones) {
              final List<String?> z when i < z.length => z[i],
              _ => null,
            };
            final key = ResultHologram.spotFor(region, sent);
            final tris = key == null ? null : track?.tris[key];
            final pts = track?.meshAt(frame);
            if (tris == null || pts == null || tris.isEmpty) {
              patches.add(null);
              continue;
            }
            final flat = <Offset>[];
            for (final t in tris) {
              if (t.any((i) => i >= pts.length || pts[i] == null)) continue;
              for (final i in t) {
                flat.add(place.map(pts[i]!, size));
              }
            }
            patches.add(flat.isEmpty ? null : flat);
          }

          return ClipRect(
              child: Stack(
            fit: StackFit.expand,
            children: [
              _Hologram(
                asset: widget.hologramAsset,
                placement: place,
                onFrame: (i) => _frame.value = i,
              ),
              IgnorePointer(
                child: CustomPaint(
                  painter: _LightPainter(
                    patches: patches,
                    active: widget.active,
                    phase: _sparkle.value,
                  ),
                ),
              ),
            ],
          ));
        },
      );
    });
  }
}

/// 결과를 **분석 중 화면과 같은 구성**으로 보여 준다.
///
/// 카드에 담아 늘어놓지 않는다. 회색 면이 여러 장 깔리면 방금까지 보던 큰
/// 아바타 화면과 딴 화면이 되고, 여러 장을 한 화면에 넣느라 문장이 작아져서
/// 저시력 사용자가 못 읽는다. 큰 아바타 아래 큰 문장 하나 — 분석 중 화면에서
/// 상태 문장을 띄우던 자리 그대로다.
///
/// 부위는 **한꺼번에 다 켠다.** 돌려 가며 띄우면 화면이 계속 바뀌고
/// TTS 도 그때마다 다시 말한다. 문제가 된 자리 전부에 같은 세기로
/// 불을 켜 두면, 어디어디가 문제인지 한눈에 남는다.
class ResultShowcase extends StatelessWidget {
  const ResultShowcase({
    super.key,
    required this.regions,
    this.sentence = '',
    this.title,
    this.zones,
  });

  /// 짚을 부위들. 서버가 준 이름 그대로다. **비어 있을 수 있다** — 문제를
  /// 하나도 못 찾았거나 자리를 못 맞춘 경우다. 그때도 아바타는 그대로 돌고,
  /// 불만 켜지 않는다. 결과 화면이 회색 카드로 바뀌면 방금까지 보던
  /// 3D 얼굴과 딴 화면이 된다.
  final List<String> regions;

  /// 부위가 없을 때 제목 자리에 쓸 이름 (예: '피부').
  final String? title;

  /// 서버가 지정한 자리들. [regions] 와 짝. [ResultHologram.spotFor] 로 간다.
  final List<String?>? zones;

  /// 상태 문장. **비워 둘 수 있다** — 결과 화면에서는 이 문장이 아래 시트로
  /// 옮겨 갔다. 얼굴 밑에 긴 문장을 두면 얼굴이 그만큼 작아진다.
  final String sentence;

  @override
  Widget build(BuildContext context) {
    final heading = regions.isNotEmpty ? regions.join(', ') : (title ?? '');
    return Semantics(
      label: [heading, sentence].where((t) => t.isNotEmpty).join('. '),
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              // 아래에서 시트가 올라오므로 가운데에 두면 아래로 치우쳐 보인다.
              // 크기는 그대로 두고 자리만 10% 올린다.
              child: FractionalTranslation(
                translation: const Offset(0, -0.10),
                child: ResultHologram(
                  regions: regions,
                  zones: zones,
                  // 고르지 않는다 — 전부 같은 세기로 켠다.
                  active: null,
                ),
              ),
            ),
            // 부위 이름은 글자로 적지 않는다 — 얼굴 위 하이라이트가 이미
            // 그 자리를 가리키고 있고, 이름이 화면에 또 있으면 시선이
            // 얼굴에서 글자로 내려간다. 음성과 Semantics 라벨에는 남는다.
            if (sentence.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                sentence,
                // 분석 중 화면의 상태 문장과 같은 크기다. 이 화면에서 사람이
                // 읽는 유일한 문장이라 여기서 줄이면 안 된다.
                style: AppText.h1.copyWith(color: AppColors.ink),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 문제 자리를 **격자 삼각형 모양 그대로** 밝힌다.
///
/// 동그란 빛으로 켜다가 바꿨다. 동그라미는 얼굴 위에 얹힌 남의 도형이지만,
/// 삼각형은 방금 분석 화면에서 얼굴을 덮고 있던 바로 그 격자다 — "저기를
/// 분석했다" 가 형태로 이어진다.
class _LightPainter extends CustomPainter {
  const _LightPainter({
    required this.patches,
    required this.active,
    required this.phase,
  });

  /// 부위마다 삼각형 꼭짓점을 3개씩 이어 붙인 목록. 자리를 못 찾으면 null.
  final List<List<Offset>?> patches;
  final int? active;

  /// 0~1 을 도는 값. 밝은 띠가 삼각형 위를 훑는 위치다.
  final double phase;

  @override
  void paint(Canvas canvas, Size size) {
    final only = active;

    for (var i = 0; i < patches.length; i++) {
      final pts = patches[i];
      if (pts == null || pts.length < 3) continue;

      // 고른 게 있으면 그것만 올리고 나머지는 확실히 내린다. 그래도 아주
      // 끄지는 않는다 — 꺼 버리면 "다른 데도 있었나" 를 알 수 없다.
      final gain = only == null ? 1.0 : (only == i ? 1.6 : 0.26);

      final path = Path();
      for (var k = 0; k + 2 < pts.length; k += 3) {
        path.moveTo(pts[k].dx, pts[k].dy);
        path.lineTo(pts[k + 1].dx, pts[k + 1].dy);
        path.lineTo(pts[k + 2].dx, pts[k + 2].dy);
        path.close();
      }

      // **더하기가 아니라 그냥 얹는다.** 흰색을 더하면 밝은 피부 위에서
      // 곧바로 255 에 붙어 하얀 스티커가 되고, 그 안의 삼각형도 같이 사라진다.
      // 일반 합성이면 흰 쪽으로 끌어올리면서도 얼굴이 비쳐 보인다.
      canvas.drawPath(
        path,
        Paint()
          ..color = ScanTone.mark.withValues(alpha: (0.22 * gain).clamp(0, 1))
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
      );
      canvas.drawPath(
        path,
        Paint()
          // 얼굴이 비쳐 보일 만큼만. 꽉 채우면 흰 스티커가 되어
          // 그 자리 피부가 안 보이고, 뭐가 문제인지 판단할 수가 없다.
          ..color = ScanTone.mark.withValues(alpha: (0.42 * gain).clamp(0, 1)),
      );
      // 밝은 띠가 비스듬히 훑고 지나간다. 가만히 있는 흰 면은 스티커로
      // 보이지만, 빛이 지나가면 **켜져 있는 면**으로 읽힌다.
      //
      // 띠는 **두 줄**이다. 좁고 아주 밝은 앞줄에 넓고 옅은 뒷줄이 따라붙어야
      // 금속에 빛이 스치는 것처럼 보인다 — 한 줄이면 그냥 밝아졌다 어두워진다.
      final box = path.getBounds();
      if (box.width > 0 && box.height > 0) {
        final span = box.width + box.height;
        canvas.save();
        canvas.clipPath(path);
        for (final (lead, wide, peak) in [
          (0.0, 0.62, 0.55),
          (0.16, 0.24, 1.0),
        ]) {
          final at = -span + ((phase + lead) % 1.0) * span * 2;
          canvas.drawRect(
            box.inflate(span),
            Paint()
              ..shader = LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  ScanTone.mark.withValues(alpha: 0),
                  ScanTone.mark.withValues(alpha: (peak * gain).clamp(0, 1)),
                  ScanTone.mark.withValues(alpha: 0),
                ],
                stops: const [0.0, 0.5, 1.0],
              ).createShader(Rect.fromLTWH(
                  box.left + at, box.top + at, span * wide, span * wide)),
          );
        }
        canvas.restore();
      }

      // 테두리도 같이 숨 쉰다. 면만 반짝이면 윤곽은 죽은 채로 남는다.
      final pulse = 0.55 + 0.45 * math.sin(phase * 2 * math.pi);
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.6 * ScanTone.weight
          ..strokeJoin = StrokeJoin.round
          ..color = ScanTone.mark
              .withValues(alpha: (0.9 * pulse * gain).clamp(0, 1))
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3.0),
      );

      // 삼각형 하나하나의 변. **어두운 선**이어야 흰 면 위에서 보인다 —
      // 흰 선을 흰 면에 그으면 아무것도 안 보인다.
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.1 * ScanTone.weight
          ..strokeJoin = StrokeJoin.round
          ..color = ScanTone.strong.withValues(alpha: (0.9 * gain).clamp(0, 1)),
      );
    }
  }

  @override
  bool shouldRepaint(_LightPainter old) =>
      old.active != active ||
      old.phase != phase ||
      !listEquals(old.patches, patches);
}

/// 분석 중 연출 — 3D 아바타가 떠오르고, 부위를 하나씩 짚는다.
///
/// 화면 옆으로 흐르는 좌표는 지어낸 숫자가 아니라 **지금 화면에 찍히고 있는
/// 특징점의 실제 좌표**다. 의미 없는 숫자를 흘리면 데모 티가 난다.
///
/// **끝났다고 말하지 않는다.** 이 위젯은 분석이 언제 끝나는지 모른다.
/// 완료는 결과 화면이 알린다 — 여기서 "끝났어요" 를 띄우면 아직 기다리는
/// 중에 다 됐다고 거짓말을 하게 된다.
///
/// 이 위젯은 그림과 소리만 맡는다. 분석의 진행이나 결과는 바깥에서 넣어 준다.
class HologramScan extends StatefulWidget {
  const HologramScan({
    super.key,
    this.photo,
    this.overlay,
    this.templateAsset = 'assets/hologram/demo_face_points.json',
    required this.statusLine,
    this.showStatus = true,
    this.progress = 0.0,
    this.hologramAsset = 'assets/hologram/face_hologram.webp',
    this.accent = ScanTone.line,
    this.sound = true,
    this.photoStage = false,
    this.onIntroDone,
  });

  /// 방금 찍은 사진. 없으면 빈 면 위로 빔만 지나간다.
  final ImageProvider? photo;

  /// 사진 위에 붙일 얼굴 격자.
  ///
  /// 넘기지 않으면 [templateAsset] 에서 읽는다. 기기에서 특징점을 실시간으로
  /// 잡지는 않으므로 이건 **연출용 배치**다 — 촬영 화면이 얼굴을 가운데로
  /// 잡아 주기 때문에 대체로 얼굴에 맞아떨어진다. 온디바이스로 특징점을
  /// 잡게 되면 그때 실제 좌표를 넣어라.
  final FaceOverlay? overlay;

  /// 격자를 안 넘겼을 때 읽을 파일. 빈 문자열이면 격자를 그리지 않는다.
  final String templateAsset;

  /// 지금 무엇을 보고 있는지. 같은 문장을 TTS 도 읽는다.
  final String statusLine;

  /// 문장·진행 막대를 이 위젯 안에 그릴지. **false 면 얼굴이 그만큼 커진다** —
  /// 분석 화면은 이걸 끄고 문장을 아래 시트로 옮겨 담는다.
  final bool showStatus;

  /// 분석 진행률 0~1.
  final double progress;

  final String hologramAsset;
  final Color accent;
  final bool sound;

  /// 사진을 훑는 앞 구간(빔·격자·모프)을 넣을지.
  ///
  /// 기본은 끔. 분석이 언제 끝날지 모르는데 앞에 7초짜리 연출을 두면 결과가
  /// 그만큼 늦게 나오는 것으로 느껴진다. 아바타만 두면 서버가 오래 걸려도
  /// 화면이 계속 살아 있다. 되돌리려면 이 값만 true 로 주면 된다 —
  /// 구간표(`_full`) 와 그림 부품은 그대로 남겨 두었다.
  final bool photoStage;

  /// 연출이 자리를 잡은 순간.
  final VoidCallback? onIntroDone;

  @override
  State<HologramScan> createState() => _HologramScanState();
}

class _HologramScanState extends State<HologramScan>
    with TickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: _p.ms),
  );

  /// 연출이 끝난 뒤에도 계속 도는 시계.
  ///
  /// [_c] 는 5.6초에 멈추는데, 아바타 WebP 는 3초 루프로 계속 돈다. 짚는 점과
  /// 눈금·표시등이 [_c] 만 보면 연출이 끝나는 순간 얼어붙어서, 서버를 더
  /// 기다리는 동안 화면이 죽은 것처럼 보인다.
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: _hologramLoopMs),
  );

  /// 아바타 WebP 한 바퀴. 티커에만 쓴다 — 프레임 번호는 어림하지 않는다.
  static const _hologramLoopMs = 3000;

  /// **화면에 그려진** 아바타 프레임 번호. [_Hologram] 이 알려 준다.
  ///
  /// 시계로 어림하던 값이었는데, 재생 시작이 마운트보다 늦고 프레임이 밀리기도
  /// 해서 어긋남이 계속 커졌다 — 조준틀이 얼굴에서 미끄러지는 원인이었다.
  /// 그려진 번호를 그대로 받으면 어림이 없다.
  final ValueNotifier<int> _holoFrame = ValueNotifier(0);

  /// 이미 울린 신호. 컨트롤러 리스너는 초당 60번 불리므로 한 번만 울리게 막는다.
  final Set<String> _fired = {};

  FaceOverlay? _overlay;
  HologramFit? _fit;
  ZoneTrack? _track;

  // 연출 구간표. 겹치게 둬서 장면이 끊기지 않고 이어진다.
  // 사진 구간을 넣고 빼는 두 벌이다 ([HologramScan.photoStage]).

  /// 아바타만. 처음부터 떠 있고 부위 표시만 붙는다.
  static const _short = (
    ms: 5600,
    beamA: 0.0, beamB: 0.0, meshA: 0.0, meshB: 0.0,
    lockA: 0.04, lockB: 0.34, hold: 0.0,
    morphA: 0.0, morphB: 0.14, analysis: 0.38,
    // 계측값이 다 세어진 뒤에 물러난다. 아바타가 뜨는 시점에 맞추면
    // 아직 세는 중에 흐려져서 읽다 만 것처럼 보인다.
    telemA: 0.36, telemB: 0.54,
  );

  /// 사진을 훑고 나서 아바타로 넘어가는 원래 연출.
  ///
  /// 사진 → 3D 는 **얼굴을 지우지 않고** 바로 넘긴다. 아바타에도 같은 얼굴
  /// 사진이 입혀져 있고 자리·크기도 맞춰 두었으므로, 겹쳐 놓고 바꾸면 얼굴은
  /// 그대로 있고 입체감만 생긴다. 중간에 사진을 먼저 지우면 얼굴이 잠깐
  /// 사라졌다가 돌아와서 "사라졌다" 로 보인다.
  static const _full = (
    ms: 9600,
    beamA: 0.02, beamB: 0.26, meshA: 0.12, meshB: 0.40,
    lockA: 0.15, lockB: 0.38, hold: 0.50,
    morphA: 0.52, morphB: 0.68, analysis: 0.68,
    telemA: 0.52, telemB: 0.68,
  );

  late final _p = widget.photoStage ? _full : _short;

  /// 사진 없이 아바타만 띄울 때 얼굴을 키우는 배율.
  /// **결과 화면([ResultHologram]) 과 같은 값이어야** 넘어갈 때 안 튄다.
  static const _faceZoom = 1.12;

  /// 아바타를 얼마나 키울지.
  ///
  /// 사진 구간이 있으면 1 이어야 한다 — 사진 위 격자와 **같은 자리·같은 크기**
  /// 여야 겹쳐 바뀔 때 튀지 않는다.
  ///
  /// 사진을 안 쓸 때도 **1 이다.** 한때 1.5 로 키웠는데, 결과 화면
  /// ([ResultHologram]) 은 상자를 그대로 채우므로 분석에서 결과로 넘어갈 때
  /// 얼굴이 눈에 띄게 줄었다 — 같은 사람 같은 아바타인데 화면이 바뀐 것처럼
  /// 보인다. 두 화면이 **같은 셈**(`HologramPlacement.contain`)을 쓴다.
  static const _zoom = 1.0;

  /// 아바타가 앉을 자리. [_zoom] 만큼 제 중심에서 키운다.
  Rect? get _target {
    final b = _overlay?.bounds;
    if (b == null) return null;
    return Rect.fromCenter(
      center: b.center,
      width: b.width * _zoom,
      height: b.height * _zoom,
    );
  }

  @override
  void initState() {
    super.initState();
    _overlay = widget.overlay;
    if (_overlay == null && widget.templateAsset.isNotEmpty) _loadTemplate();
    _loadFit();
    _loadTrack();
    _c.addListener(_onTick);
    _c.forward();
    _spin.repeat();
    if (widget.sound) ScanSfx.instance.startHum();
  }

  Future<void> _loadTemplate() async {
    final loaded = await FaceOverlay.load(widget.templateAsset);
    if (!mounted || loaded == null) return;
    setState(() => _overlay = loaded);
  }

  /// 아바타 에셋 옆의 `_zones.json` 이 부위별 프레임 위치를 담고 있다.
  Future<void> _loadTrack() async {
    final path = widget.hologramAsset.replaceAll(RegExp(r'\.webp$'), '_zones.json');
    final loaded = await ZoneTrack.load(path);
    if (!mounted || loaded == null) return;
    setState(() => _track = loaded);
  }

  /// 아바타 에셋 옆의 `.json` 이 첫 프레임 위치를 담고 있다.
  Future<void> _loadFit() async {
    final path = widget.hologramAsset.replaceAll(RegExp(r'\.webp$'), '.json');
    final loaded = await HologramFit.load(path);
    if (!mounted || loaded == null) return;
    setState(() => _fit = loaded);
  }

  @override
  void dispose() {
    _c.removeListener(_onTick);
    _c.dispose();
    _spin.dispose();
    _holoFrame.dispose();
    ScanSfx.instance.stopHum();
    super.dispose();
  }

  double _seg(double t, double a, double b) =>
      ((t - a) / (b - a)).clamp(0.0, 1.0);

  void _onTick() {
    final t = _c.value;

    void cue(String id, double at, VoidCallback run) {
      if (t >= at && _fired.add(id)) run();
    }

    if (widget.sound) {
      // 훑기 시작 — 삐비빅. 연출 맨 앞에 한 번은 반드시 울려야 한다.
      // 기계가 일을 시작했다는 신호가 이것뿐이다.
      cue('sweep1', _p.beamA, ScanSfx.instance.sweep);
      if (widget.photoStage) {
        // 사진 위를 빔이 두 번 지나간다. 두 번째 시작에 한 번 더.
        cue('sweep2', _p.beamA + (_p.beamB - _p.beamA) / 2,
            ScanSfx.instance.sweep);
        // 격자가 다 붙는 순간.
        cue('locked', _p.meshB, ScanSfx.instance.blip);
      }
      // 아바타가 다 올라선 순간. 올라서기 **전에** 울리면 소리가 앞서 나간다.
      cue('rise', _p.morphB, ScanSfx.instance.rise);

      // 특징점이 찍힐 때마다 따로 울리지 않는다. 도는 삐빅(hum_loop)이
      // 이미 박자를 잡고 있어서, 여기서 또 울리면 박자가 엉킨다.
    }

    // 조준틀이 부위에 물리는 순간마다 한 번. 그림과 소리가 같은 순간에
    // 걸려야 "지금 저기를 재고 있다" 로 읽힌다.
    if (widget.sound) {
      final span = 1.0 - _p.analysis;
      for (var i = 0; i < _AnalysisPainter.zoneCount; i++) {
        cue(
          'zone$i',
          _p.analysis +
              span * (_AnalysisPainter.zoneAt(i) + _AnalysisPainter.zoneLock),
          ScanSfx.instance.blip,
        );
      }
    }

    cue('introDone', _p.morphB, () => widget.onIntroDone?.call());
  }

  int _revealedCount(double t) {
    final points = _overlay?.points;
    if (points == null || points.isEmpty) return 0;
    return (points.length * _seg(t, _p.lockA, _p.lockB)).floor();
  }

  /// 홀로그램이 **깜빡인다.** 빛으로 쏘아 만든 상이 잠깐씩 흔들리는 것으로
  /// 읽힌다 — 이게 없으면 아무리 각지게 만들어도 그냥 그림이다.
  ///
  /// 일정한 간격으로 깜빡이면 화면이 고장 난 것처럼 보인다. 주기가 다른 두
  /// 파동을 곱해서, **둘이 같이 높아지는 순간에만** 튀게 했다 — 언제 올지
  /// 모르는 불규칙한 떨림이 된다. 소리(`ScanSfx` 의 도는 삐빅)와 박자를
  /// 맞추지 않는 것도 일부러다. 맞추면 기계가 아니라 음악이 된다.
  ///
  /// [gain] 0~1 은 훑는 막대가 얼마나 내려왔는지다. **내려갈수록 자주,
  /// 깊게** 떤다 — 위에서부터 훑어 내려오며 기계가 점점 바빠지는 것으로
  /// 읽힌다. 처음부터 끝까지 같은 세기로 떨면 그냥 배경 효과가 된다.
  static double _flick(double t, double gain) {
    final fast = t * (1.0 + gain * 0.8);
    final together = math.sin(fast * 41.0) * math.sin(fast * 13.7 + 1.7);
    final deep = 0.16 + 0.42 * gain;
    if (together > 0.95 - 0.13 * gain) return 1.0 - deep;
    if (together > 0.86 - 0.10 * gain) return 1.0 - deep * 0.4;
    return 1.0;
  }

  /// 지금 프레임에서 각 부위를 짚을 화면 좌표.
  ///
  /// 구울 때 잰 값([ZoneTrack])이 있으면 그걸 쓰고, 없으면 null 을 돌려
  /// 페인터가 고정 좌표로 그리게 둔다 — 에셋을 다시 굽기 전에도 화면은 돈다.
  List<Offset?>? _anchors(HologramPlacement? place, int frame, Size box) {
    final track = _track;
    if (track == null || place == null) return null;
    final now = track.at(frame);
    return [
      for (final key in _AnalysisPainter.zoneKeys)
        () {
          final i = track.indexOf(key);
          if (i < 0 || i >= now.length) return null;
          final uv = now[i];
          return uv == null ? null : place.map(uv, box);
        }(),
    ];
  }

  /// 머리를 감싸는 사각형. 갈고리를 여기에 두른다.
  ///
  /// 구울 때 잰 `content` 를 써 봤는데 그건 **얼굴 격자**가 닿는 범위라,
  /// 갈고리가 눈썹에서 턱 아래까지만 두르고 머리는 밖으로 나갔다 —
  /// 얼굴을 잘라낸 것처럼 보인다. 아바타 판은 정사각이고 그 안에 머리가
  /// 꽉 차게 구워져 있으므로, **판이 그려지는 정사각**을 조금 줄여 쓴다.
  Rect? _faceFrame(HologramPlacement? place, Size box) {
    if (place == null || box.isEmpty) return null;
    // 구울 때 잰 `content` 를 써 봤는데 그건 **얼굴 격자**가 닿는 범위라,
    // 갈고리가 눈썹에서 턱 아래까지만 두르고 머리는 밖으로 나갔다.
    // 판 안에서 머리가 앉는 자리는 굽는 설정이 같으면 거의 안 변하므로
    // 여기에 적어 둔다 (판 기준 비율 — 배율은 [place] 가 태워 준다).
    final a = place.map(const Offset(0.15, 0.04), box);
    final b = place.map(const Offset(0.85, 0.96), box);
    return Rect.fromLTRB(a.dx, a.dy, b.dx, b.dy);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_c, _spin, _holoFrame]),
      builder: (context, _) {
        final t = _c.value;
        // 어림이 아니라 방금 그려진 프레임 번호다.
        final holoFrame = _holoFrame.value;
        // 연출이 끝난 뒤에도 흐르는 값. 눈금과 표시등이 여기에 걸린다.
        final life = t < 1 ? t : 1 + _spin.value;
        final beam = _seg(t, _p.beamA, _p.beamB);
        final morph = _seg(t, _p.morphA, _p.morphB);
        final revealed = _revealedCount(t);

        // 흰 바탕에서는 글자를 사진 위에 얹지 않는다. 사진은 카드로 세우고
        // 계측값과 문장은 그 아래 여백에 둔다 — 어두운 화면에서는 겹쳐도
        // 읽혔지만 밝은 화면에서는 지저분해 보인다.
        return DecoratedBox(
          decoration: const BoxDecoration(gradient: _backdrop),
          child: Padding(
            // 여백은 아래에 계측값·문장을 같이 그릴 때만 필요하다. 분석
            // 화면은 문장을 시트로 내렸으므로 결과 화면처럼 상자를 다 쓴다 —
            // 여백이 남아 있으면 그만큼 얼굴이 작아져 결과와 크기가 어긋난다.
            padding: widget.showStatus
                ? const EdgeInsets.fromLTRB(16, 16, 16, 14)
                : EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _Frame(
                    // 3:4 틀도 미리보기에만 있다. 결과 화면은 상자를 그대로
                    // 쓰므로, 여기서 틀을 씌우면 같은 아바타가 더 작게 앉는다.
                    boxed: widget.showStatus,
                      // 아바타와 그 위에 얹는 표시가 **같은 배치 셈**을 써야
                      // 조준틀이 얼굴에서 미끄러지지 않는다. 여기서 한 번
                      // 만들어 둘 다에 넘긴다.
                      child: LayoutBuilder(builder: (context, box) {
                        // 사진 구간이 없으면 맞출 상대도 없다 — 결과 화면과
                        // 똑같이 상자에 담는다.
                        final place = widget.photoStage
                            ? HologramPlacement.of(_fit, _target, box.biggest)
                            : HologramPlacement.zoom(_faceZoom, box.biggest);
                        return Stack(
                      fit: StackFit.expand,
                      children: [
                        // 계기 눈금(화면 가장자리 자)은 두지 않는다 —
                        // 오른쪽에 막대가 생긴 것처럼 보였고, 재는 값이
                        // 실제로 있는 것도 아니었다.
                        // 사진은 먼저 녹고, 격자는 제자리에 남는다.
                        if (widget.photoStage)
                          Opacity(
                            opacity: (1 - morph).clamp(0.0, 1.0),
                            child: _PhotoPlate(
                              photo: widget.photo,
                              accent: widget.accent,
                              beam: beam,
                              overlay: _overlay,
                              meshIn: _seg(t, _p.meshA, _p.meshB),
                              // 격자가 다 붙은 뒤 아주 조금 또렷해진다.
                              settle: _seg(t, _p.meshB, _p.hold),
                              revealed: revealed,
                            ),
                          ),
                        // 남아 있던 격자가 그 자리에서 3D 아바타가 된다.
                        // 자리를 맞추지 않으면 크기가 튀어서 "잘렸다" 로 보인다.
                        if (morph > 0)
                          Opacity(
                            // 훑는 막대가 위에서 아래로 내려가는 동안
                            // (한 바퀴 = _spin) 떨림이 점점 세진다.
                            opacity: (morph * _flick(life, _spin.value))
                                .clamp(0.0, 1.0),
                            child: _Hologram(
                              asset: widget.hologramAsset,
                              placement: place,
                              onFrame: (i) => _holoFrame.value = i,
                            ),
                          ),
                        // **갈고리가 먼저다.** 나중에 그리면 이름표 위에
                        // 얹혀서 「이마」처럼 갈고리와 높이가 겹치는 글자를
                        // 가로질러 가린다. 테두리는 배경이지 표시가 아니다.
                        IgnorePointer(
                          child: CustomPaint(
                            painter: _BracketPainter(
                              amount: _seg(t, 0.0, 0.18),
                              frame: _faceFrame(place, box.biggest),
                            ),
                          ),
                        ),
                        // 부위를 차례로 짚는 표시. 아바타가 다 올라온 뒤에 붙는다.
                        if (t > _p.analysis)
                          IgnorePointer(
                            child: CustomPaint(
                              painter: _AnalysisPainter(
                                amount: _seg(t, _p.analysis, 1.0),
                                zoom: _zoom,
                                origin: _overlay?.bounds.center ??
                                    const Offset(0.5, 0.5),
                                // 얼굴이 돌면 짚는 점도 같이 돈다.
                                anchors: _anchors(place, holoFrame,
                                    box.biggest),
                                // 첫 장 자리. 라벨을 얼마나 밀지 재는 기준이다.
                                rests: _anchors(place, 0, box.biggest),
                                frame: _faceFrame(place, box.biggest),
                              ),
                            ),
                          ),
                        ],
                        );
                      }),
                  ),
                ),
                if (widget.showStatus) ...[
                  const SizedBox(height: 18),
                  _Telemetry(
                    points: _overlay?.points,
                    revealed: revealed,
                    settled: _seg(t, _p.telemA, _p.telemB),
                    pulse: life,
                  ),
                  ScanStatusBar(
                    line: widget.statusLine,
                    progress: widget.progress,
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 3:4 틀에 담을지, 상자를 그대로 줄지 고른다.
///
/// 분석 화면과 결과 화면이 **같은 크기로 얼굴을 그려야** 한다. 결과는 상자를
/// 그대로 쓰므로 분석도 그래야 하는데, 계측값을 아래에 같이 그리는
/// 미리보기에서는 틀이 있어야 그림과 글이 안 붙는다.
class _Frame extends StatelessWidget {
  const _Frame({required this.boxed, required this.child});

  final bool boxed;
  final Widget child;

  @override
  Widget build(BuildContext context) => boxed
      ? Center(child: AspectRatio(aspectRatio: 3 / 4, child: child))
      : child;
}

/// 이 구간의 바탕. 흰색에 아주 옅은 냉기만 남겼다 — 완전한 순백은
/// 주변 코랄 화면과 붙었을 때 오히려 비어 보인다.
const _backdrop = LinearGradient(
  begin: Alignment.topCenter,
  end: Alignment.bottomCenter,
  colors: [Color(0xFFFFFFFF), Color(0xFFFCFCFD), Color(0xFFF6F7F8)],
);

// ---------------------------------------------------------------- 사진 + 스캔

class _PhotoPlate extends StatelessWidget {
  const _PhotoPlate({
    required this.photo,
    required this.accent,
    required this.beam,
    required this.overlay,
    required this.meshIn,
    required this.settle,
    required this.revealed,
  });

  final ImageProvider? photo;
  final Color accent;
  final double beam;
  final FaceOverlay? overlay;
  final double meshIn;
  final double settle;
  final int revealed;

  @override
  Widget build(BuildContext context) {
    final face = overlay;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        // 흰 바탕 위의 흰 카드라 테두리 한 줄이 있어야 면이 선다.
        border: Border.all(color: const Color(0xFFE4E5E7)),
        boxShadow: const [
          BoxShadow(color: Color(0x0F2E4652), blurRadius: 24, offset: Offset(0, 8)),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(17),
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: Colors.white),
            if (photo != null) ...[
              Image(image: photo!, fit: BoxFit.cover),
              // 사진을 살짝 걷어 낸다. 어둡게 덮지 않고 하얗게 띄워야
              // 얼굴은 그대로 보이면서 그 위의 진한 선이 읽힌다.
              const ColoredBox(color: Color(0x1AFFFFFF)),
            ],
            // 얼굴을 따라 붙는 격자. 위에서 아래로 채워지며 나타난다.
            if (face != null && face.edges.isNotEmpty && meshIn > 0)
              CustomPaint(
                painter: _FaceMeshPainter(
                  overlay: face,
                  amount: meshIn,
                  settle: settle,
                ),
              ),
            if (face != null && revealed > 0)
              CustomPaint(
                painter: _DotsPainter(points: face.points, revealed: revealed),
              ),
            CustomPaint(painter: _BeamPainter(beam: beam)),
          ],
        ),
      ),
    );
  }
}

/// 실제 얼굴 위에 달라붙는 격자.
///
/// 사진을 지우고 격자만 띄우면 누구 얼굴인지 알 수 없는 가면이 된다.
/// 얼굴이 그대로 보이는 채로 그물이 이목구비를 감싸야 "그 사람" 으로 읽힌다.
///
/// 선을 하나씩 `drawLine` 으로 그리면 1322 번을 매 프레임 반복하게 된다.
/// 경로 하나로 모아 한 번에 그린다.
class _FaceMeshPainter extends CustomPainter {
  const _FaceMeshPainter({
    required this.overlay,
    required this.amount,
    required this.settle,
  });

  final FaceOverlay overlay;

  /// 0~1. 격자가 위에서 아래로 채워지는 정도.
  final double amount;

  /// 0~1. 다 붙은 뒤 자리를 잡는 정도.
  final double settle;

  @override
  void paint(Canvas canvas, Size size) {
    final mesh = overlay.mesh;
    if (mesh.isEmpty) return;

    Offset at(int i) => Offset(mesh[i].dx * size.width, mesh[i].dy * size.height);

    // 아직 안 그려진 곳 바로 앞줄은 진하게 — 훑고 지나가는 결이 생긴다.
    const frontBand = 0.09;
    final grid = Path();
    final contour = Path();
    final front = Path();

    void collect(List<(int, int)> lines, Path settled) {
      for (final (a, b) in lines) {
        if (a >= mesh.length || b >= mesh.length) continue;
        final midY = (mesh[a].dy + mesh[b].dy) / 2;
        if (midY > amount) continue;

        final path = (amount - midY) < frontBand ? front : settled;
        path.moveTo(at(a).dx, at(a).dy);
        path.lineTo(at(b).dx, at(b).dy);
      }
    }

    collect(overlay.edges, grid);
    collect(overlay.contours, contour);

    // 흰 후광을 먼저 깐다. 예전엔 옅은 색 받침이었는데, 어두운 선으로 바뀐
    // 뒤로는 **흰 후광이라야** 얼굴 위에서 선이 떠 보인다.
    const gridW = 0.7 * ScanTone.weight;
    const contourW = 0.9 * ScanTone.weight;
    const frontW = 1.0 * ScanTone.weight;
    _haloStroke(canvas, grid, gridW, 0.55 * ScanTone.scrim);
    _haloStroke(canvas, contour, contourW, 0.7 * ScanTone.scrim);
    _haloStroke(canvas, front, frontW, 0.7 * ScanTone.scrim);

    canvas.drawPath(
      grid,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = gridW
        ..color = ScanTone.line
            .withValues(alpha: (0.88 + 0.12 * settle) * ScanTone.scrim),
    );
    // 이목구비는 한 단계 진하게. 격자가 성글어진 만큼 이 선들이 형태를 짊어진다.
    canvas.drawPath(
      contour,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = contourW
        ..strokeCap = StrokeCap.round
        ..color = ScanTone.strong
            .withValues(alpha: (0.92 + 0.08 * settle) * ScanTone.scrim),
    );
    canvas.drawPath(
      front,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = frontW
        ..color = ScanTone.strong.withValues(alpha: ScanTone.scrim),
    );
  }

  @override
  bool shouldRepaint(_FaceMeshPainter old) =>
      old.amount != amount || old.settle != settle;
}

/// 위에서 아래로 곧게 내려가는 스캔선.
///
/// 왕복시키면 훑는 게 아니라 흔들리는 것으로 보인다. 한 방향으로만 내려가고
/// 화면 밖에서 되돌아온다 — 복사기·바코드 스캐너와 같은 결이다.
class _BeamPainter extends CustomPainter {
  const _BeamPainter({required this.beam});
  final double beam;

  /// 훑는 횟수. 되돌아가는 순간은 화면 밖이라 보이지 않는다.
  static const _passes = 2;

  /// 선이 위/아래 끝에서 사라지는 구간. 화면 경계에 선이 딱 붙어 있으면
  /// 되돌아가는 게 눈에 띈다.
  static const _fade = 0.12;

  @override
  void paint(Canvas canvas, Size size) {
    if (beam <= 0 || beam >= 1) return;

    // 톱니파. 아래까지 가면 위에서 다시 시작한다.
    final phase = (beam * _passes) % 1.0;
    final y = size.height * phase;

    // 끝에서 살짝 흐려 되돌아가는 이음매를 감춘다.
    final edge = math.min(phase, 1 - phase) / _fade;
    final visible = edge.clamp(0.0, 1.0);
    if (visible <= 0) return;

    // 선이 지나간 자리에 남는 잔상. 선 **뒤쪽**(위)으로만 끌린다 —
    // 양쪽으로 번지면 띠가 되어 어디가 지금 지나는 줄인지 알 수 없다.
    const trail = 44.0;
    final tail = Rect.fromLTRB(0, y - trail, size.width, y);
    canvas.drawRect(
      tail,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            ScanTone.mist.withValues(alpha: 0),
            ScanTone.mist.withValues(alpha: 0.5 * visible),
          ],
        ).createShader(tail),
    );

    // 선 자체. 흰 바탕에서는 번지게 하지 않는다 — 번지면 뿌옇기만 하다.
    canvas.drawLine(
      Offset(0, y),
      Offset(size.width, y),
      Paint()
        ..color = ScanTone.strong.withValues(alpha: 0.9 * visible)
        ..strokeWidth = 1.4,
    );
  }

  @override
  bool shouldRepaint(_BeamPainter old) => old.beam != beam;
}

/// 잡힌 특징점을 **피부 위 하이라이트**로 찍는다.
///
/// 진한 점으로 찍으면 밝은 사진 위에서 티끌처럼 보인다. 빛이 반짝 걸린 것처럼
/// 흰빛으로 얹으면 같은 정보가 얼굴을 해치지 않고, 메이크업 앱에도 맞는다.
class _DotsPainter extends CustomPainter {
  const _DotsPainter({required this.points, required this.revealed});

  final List<Offset> points;
  final int revealed;

  @override
  void paint(Canvas canvas, Size size) {
    // 테두리를 그리지 않는다. 윤곽이 생기는 순간 하이라이트가 아니라
    // 얼굴에 박힌 구슬처럼 보인다. 번짐과 심지, 두 겹이면 충분하다.
    // 어두운 점이라 번짐이 아니라 **흰 테**를 둘러야 떠 보인다.
    final bloom = Paint()
      ..color = ScanTone.halo.withValues(alpha: 0.8)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.4);
    final core =
        Paint()..color = ScanTone.glint.withValues(alpha: ScanTone.scrim);

    for (var i = 0; i < revealed && i < points.length; i++) {
      final p = points[i];
      final at = Offset(p.dx * size.width, p.dy * size.height);

      // 방금 걸린 몇 개는 아직 크게 번져 있다.
      final age = ((revealed - i) / 6).clamp(0.0, 1.0);
      final r = 1.1 + (1 - age) * 1.8;

      canvas.drawCircle(at, r * 3.4, bloom);
      canvas.drawCircle(at, r * 0.95, core);
    }
  }

  @override
  bool shouldRepaint(_DotsPainter old) => old.revealed != revealed;
}

// ---------------------------------------------------------------- 홀로그램

/// 3D 아바타를 부위별로 짚어 가는 표시.
///
/// **수치를 지어내지 않는다.** 어디를 보고 있는지만 짚는다 — 그럴듯한 숫자를
/// 띄우면 데모로는 그럴싸해도 제품에서는 거짓말이 된다. 앞이 보이지 않는
/// 사용자에게 지어낸 분석은 오답보다 나쁘다는 원칙이 여기에도 그대로 걸린다.
class _AnalysisPainter extends CustomPainter {
  const _AnalysisPainter({
    required this.amount,
    this.zoom = 1.0,
    this.origin = const Offset(0.5, 0.5),
    this.anchors,
    this.rests,
    this.frame,
  });

  /// 0~1. 아바타 구간 안에서의 진행 정도.
  final double amount;

  /// 아바타를 키운 배율. **짚는 지점에만** 건다 — 라벨까지 밀면 화면 밖으로
  /// 나간다. 아바타와 같은 중심에서 같은 배율로 밀어야 짚는 자리가 안 어긋난다.
  final double zoom;

  /// 그 배율의 중심 (아바타가 앉은 자리의 가운데).
  final Offset origin;

  /// 지금 프레임에 짚을 **화면 좌표**. [zoneNames] 와 같은 순서다.
  ///
  /// 구울 때 잰 값이 있으면 여기로 들어오고, 그때는 [_zones] 의 고정 좌표와
  /// [zoom] 을 쓰지 않는다 — 얼굴이 도는 것까지 반영된 값이라 그게 더 정확하다.
  final List<Offset?>? anchors;

  /// 첫 장에서의 자리. [anchors] 와의 차이만큼 라벨도 따라 민다.
  final List<Offset?>? rests;

  /// 얼굴을 감싸는 사각형 (갈고리와 같은 값). 이름표를 이 **바로 옆**에 둔다.
  final Rect? frame;

  // (짚는 지점, 라벨 지점, 이름). 전부 0~1 비율이다.
  // 아바타가 좌우로 훑기 때문에 짚는 지점은 가운데 쪽으로 잡아야 얼굴을 벗어나지 않는다.
  /// 부위 개수. 소리 큐가 이 개수를 따라간다.
  static int get zoneCount => _zones.length;

  /// 구울 때 넘긴 `--zones` 의 키. 화면에 쓰는 이름과 다르다 —
  /// 좌우를 나눠 구웠지만 라벨에는 "눈썹" 이라고만 쓴다.
  static List<String> get zoneKeys => [for (final z in _zones) z.$1];


  /// i 번째 부위를 짚기 시작하는 시점 (구간 안 0~1 비율).
  static double zoneAt(int i) => 0.05 + i * 0.125;

  /// 조준틀이 다 조여 물리는 데 걸리는 몫. 소리는 이때 울린다.
  static const zoneLock = 0.13 * 0.55;

  /// 짚는 순서는 **위에서 아래**다. 스캔선이 내려가는 방향과 같아야
  /// 훑으면서 하나씩 잡는 것으로 읽힌다. 라벨은 좌우로 번갈아 두고
  /// 세로로 벌려 놓는다 — 같은 쪽에 몰리면 지시선이 서로를 넘는다.
  /// (구울 때의 키, 라벨 자리, 화면에 쓰는 이름, 잰 값이 없을 때의 자리)
  /// **네 귀퉁이는 비워 둔다.** 얼굴을 겨누는 갈고리([_BracketPainter])가
  /// 판의 0.08~0.92 자리에 서 있어서, 예전처럼 0.13·0.80 까지 올리고
  /// 내리면 「이마」와 「턱선」이 갈고리에 겹쳐 글자가 잘려 보였다.
  /// 위아래를 0.21~0.79 로 좁히고 간격을 고르게 벌렸다.
  static const _zones = <(String, Offset, String, Offset)>[
    ('이마', Offset(0.86, 0.21), '이마', Offset(0.52, 0.285)),
    ('오른쪽눈썹', Offset(0.14, 0.305), '눈썹', Offset(0.38, 0.345)),
    ('왼쪽눈가', Offset(0.86, 0.40), '눈가', Offset(0.62, 0.395)),
    ('오른쪽볼', Offset(0.14, 0.495), '볼', Offset(0.355, 0.495)),
    ('코', Offset(0.86, 0.59), '코', Offset(0.50, 0.505)),
    ('입술', Offset(0.14, 0.685), '입술', Offset(0.50, 0.585)),
    ('턱선', Offset(0.86, 0.79), '턱선', Offset(0.53, 0.655)),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < _zones.length; i++) {
      final at = zoneAt(i);
      final on = ((amount - at) / 0.13).clamp(0.0, 1.0);
      if (on <= 0) continue;

      final (_, labelN, name, rawN) = _zones[i];
      final tracked = (anchors != null && i < anchors!.length)
          ? anchors![i]
          : null;
      // 잰 값이 없을 때만 고정 좌표를 배율만큼 밀어서 쓴다.
      final anchor = tracked ??
          Offset(
            (origin.dx + (rawN.dx - origin.dx) * zoom) * size.width,
            (origin.dy + (rawN.dy - origin.dy) * zoom) * size.height,
          );
      // 짚는 지점 — 네 귀퉁이가 조여 들어와 물리는 조준틀.
      // 그냥 점을 찍으면 '표시해 뒀다' 이지만, 조여 들어오면 **지금 재고 있다**
      // 로 읽힌다. 다 조인 뒤에 속을 비운 작은 원을 남긴다.
      // 이름표는 **얼굴 밖 여백**에 두고 지시선으로 잇는다. 짚는 자리에
      // 바로 붙여 봤지만 글자가 얼굴 위에 얹혀서 격자를 가렸다.
      // 자리는 [_zones] 에 좌우로 번갈아, 세로로 벌려 잡아 두었다 —
      // 같은 쪽에 몰리면 지시선이 서로를 넘는다.
      //
      // **첫 장 기준으로 잡아 둔 자리에 고정한다.** 얼굴이 좌우로 훑는
      // 동안 이름표까지 따라 흔들리면 글자를 읽을 수가 없다. 움직이는
      // 것은 짚는 점과 지시선뿐이다.
      // 이름표는 **얼굴 테두리 바로 옆**이다. 화면 가장자리에 붙여 봤더니
      // 지시선이 화면을 반쯤 가로지르는 긴 막대가 됐다 — 글자가 얼굴을
      // 겨누는 게 아니라 딴 데서 소리치는 것처럼 보인다. 갈고리 테두리
      // ([frame]) 에서 조금만 떨어뜨리면 지시선이 짧아진다.
      final toRight = labelN.dx > 0.5;
      final box = frame;
      final edgeX = box == null
          ? (toRight ? size.width - _labelPad : _labelPad)
          : (toRight ? box.right + 4 : box.left - 4);
      final label = Offset(
        toRight
            ? math.min(edgeX, size.width - _labelPad)
            : math.max(edgeX, _labelPad),
        labelN.dy * size.height,
      );
      _leader(canvas, anchor, label, on, toRight, _measure(name));
      _reticle(canvas, anchor, on);
      _name(canvas, label, name, on, toRight);
    }
  }

  /// 짚는 점에서 이름표까지 잇는 지시선. **도해에 쓰는 모양** 그대로다 —
  /// 조준틀에서 사선으로 나와 이름표 앞에서 **짧은 가로**로 받친다.
  ///
  /// 두 번 고쳤다. 처음엔 가로로 길게 나온 뒤 꺾어 붙였는데 가로 구간이
  /// 막대처럼 남았고, 그다음엔 곧은 사선 하나로 했는데 글자에 비스듬히
  /// 꽂혀서 조준선처럼 보였다. 사선이 거리를 다 삼키고 가로는 글자 앞
  /// 받침(14px)만 남기면, 눈이 사선을 타고 와 가로에서 글자로 넘어간다.
  static void _leader(
      Canvas canvas, Offset from, Offset to, double on, bool toRight,
      double width) {
    if (on <= 0) return;
    // 이름표 글자 바로 앞에서 멈춘다.
    final end = Offset(to.dx + (toRight ? -width - 6 : width + 6), to.dy);
    // 글자 앞 짧은 가로 받침. 사선이 이 지점까지 온다.
    final knee = Offset(end.dx + (toRight ? -14 : 14), end.dy);
    final v = knee - from;
    if (v.distance < 24) return; // 겹칠 만큼 가까우면 선이 오히려 지저분하다
    final start = from + v * (12.0 / v.distance);
    final path = Path()
      ..moveTo(start.dx, start.dy)
      ..lineTo(knee.dx, knee.dy)
      ..lineTo(end.dx, end.dy);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0 * ScanTone.weight + 2.4
        ..color = const Color(0xFFFFFFFF).withValues(alpha: 0.7 * on),
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0 * ScanTone.weight
        ..color = ScanTone.label.withValues(alpha: 0.85 * on),
    );
  }

  /// 상자 가장자리에서 이름표까지 띄우는 여백.
  static const _labelPad = 6.0;

  /// 이름표 글자 크기. 작을수록 얼굴을 덜 가리지만 저시력 사용자가 못 읽는다.
  static const _labelSize = 16.0;

  /// 글자 폭. 지시선을 어디서 멈출지 재는 데만 쓴다.
  static double _measure(String text) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
            fontSize: _labelSize, height: 1.1, fontWeight: FontWeight.w700),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    return tp.width;
  }

  /// 이름표. **검은 글씨에 흰 받침**이다.
  ///
  /// 여백에 두지만 얼굴이 돌면서 걸칠 수도 있어 배경을 장담할 수 없다.
  /// 흰 테를 두른 검은 글씨는 밝은 바탕에도 어두운 머리카락에도 견딘다.
  /// 판(pill)을 깔지 않는 이유는 그게 얼굴 옆 가로 막대로 보이기 때문이다.
  static void _name(
      Canvas canvas, Offset at, String text, double on, bool toRight) {
    if (on <= 0) return;
    final body = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: _labelSize,
          height: 1.1,
          fontWeight: FontWeight.w700,
          color: ScanTone.ink.withValues(alpha: on),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final edge = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: _labelSize,
          height: 1.1,
          fontWeight: FontWeight.w700,
          foreground: Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 4.0
            ..strokeJoin = StrokeJoin.round
            ..color = const Color(0xFFFFFFFF).withValues(alpha: 0.9 * on),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    // 자리는 이름표의 **바깥쪽 끝**이다 (상자 가장자리).
    final x = toRight ? at.dx - body.width : at.dx;
    final y = at.dy - body.height / 2;
    edge.paint(canvas, Offset(x, y));
    body.paint(canvas, Offset(x, y));
  }

  /// 조준틀. `on` 0 → 1 동안 열려 있던 네 귀퉁이가 조여 든다.
  ///
  /// **검은색이다.** 아바타 격자와 같은 흰색으로 그렸더니 밝은 피부 위에서
  /// 격자에 묻혀, 코·턱선을 짚고 있는데도 짚은 자리가 안 보였다. 이건 격자의
  /// 일부가 아니라 "지금 여기를 보고 있다" 는 표시라서 배경과 갈라져야 한다.
  static void _reticle(Canvas canvas, Offset at, double on) {
    // 조이는 건 앞 절반에서 끝낸다. 뒤 절반은 라벨이 붙는 시간이다.
    final close = (on / 0.55).clamp(0.0, 1.0);
    // **물릴 때까지 깜빡인다** — 삐빅삐빅. 소리(`ScanSfx.blip`) 는 물리는
    // 순간에 한 번 울리는데, 그림이 조용히 조여들기만 하면 그 소리가
    // 어디서 났는지 안 보인다. 조여드는 동안 세 번 깜빡여 두면 소리와
    // 그림이 같은 일을 하고 있는 것으로 읽힌다.
    final latch =
        close < 1 ? ((close * 6).floor().isEven ? 1.0 : 0.28) : 1.0;
    final live = on * latch;
    final half = 11.0 - 6.4 * close;
    const arm = 3.4;

    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4 * ScanTone.weight
      ..strokeCap = StrokeCap.round
      ..color = ScanTone.ink.withValues(alpha: 0.9 * live);

    final path = Path();
    for (final (sx, sy) in const [(-1, -1), (1, -1), (-1, 1), (1, 1)]) {
      final cx = at.dx + half * sx, cy = at.dy + half * sy;
      path.moveTo(cx, cy + arm * -sy);
      path.lineTo(cx, cy);
      path.lineTo(cx + arm * -sx, cy);
    }
    // 어두운 조준틀에는 **흰 받침**이다 (격자에 쓰는 어두운 후광의 반대).
    // 검은 머리카락 위에 걸릴 때 조준틀만 사라지는 걸 막는다.
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4 * ScanTone.weight + 2.4
        ..strokeCap = StrokeCap.round
        ..color = const Color(0xFFFFFFFF).withValues(alpha: 0.75 * live),
    );
    canvas.drawPath(path, edge);

    if (close < 1) return;
    // 가운데 점. 흰 테를 먼저 깔고 검은 심지를 얹는다 — 밝은 피부에서도
    // 검은 머리카락에서도 한쪽은 반드시 배경과 갈라진다.
    canvas.drawCircle(
      at,
      4.0,
      Paint()..color = const Color(0xFFFFFFFF).withValues(alpha: 0.75 * on),
    );
    canvas.drawCircle(
      at,
      2.6,
      Paint()..color = ScanTone.ink.withValues(alpha: 0.92 * on),
    );
  }

  @override
  bool shouldRepaint(_AnalysisPainter old) =>
      old.amount != amount ||
      old.zoom != zoom ||
      old.origin != origin ||
      !listEquals(old.anchors, anchors) ||
      !listEquals(old.rests, rests) ||
      old.frame != frame;
}

/// 3D 아바타. 2D 격자가 있던 자리에 정확히 맞춰 놓는다.
///
/// 첫 프레임이 정면이라 (스윕이 sin 이라 0 에서 시작한다) 자리만 맞추면
/// 사진 위 격자가 그대로 일어서는 것처럼 보인다. 위젯은 이 구간에서 처음
/// 만들어지므로 애니메이션도 첫 프레임부터 돈다.
/// 아바타를 **우리가 프레임을 넘겨 가며** 그린다.
///
/// `Image.asset` 에 맡기면 그림은 나오지만 **지금 몇 번째 프레임인지 알 수
/// 없다.** 시계로 어림해 봤는데 안 된다 — 재생은 이미지가 다 실린 뒤에
/// 시작하고(마운트보다 수백 ms 늦다) 프레임이 밀리거나 건너뛰면 어긋남이
/// 계속 커진다. 그 어긋남이 그대로 조준틀이 얼굴에서 미끄러지는 것으로 보인다.
///
/// 그래서 코덱을 직접 돌린다. [onFrame] 으로 알리는 번호가 **화면에 그려진
/// 바로 그 프레임**이라 어림이 없다. 느려지면 같이 느려질 뿐 어긋나지 않는다.
///
/// 프레임을 전부 풀어 두지 않는다 — 512px 72장이면 75MB다. 코덱이 순서대로
/// 한 장씩 내주는 것을 그때그때 그리고 버린다.
class _Hologram extends StatefulWidget {
  const _Hologram({
    required this.asset,
    this.placement,
    required this.onFrame,
  });

  final String asset;

  /// 이미지를 화면 어디에 얹을지. 위에 그리는 표시와 **같은 값**을 쓴다.
  final HologramPlacement? placement;

  /// 방금 그린 프레임 번호.
  final ValueChanged<int> onFrame;

  @override
  State<_Hologram> createState() => _HologramState();
}

class _HologramState extends State<_Hologram> {
  ui.Codec? _codec;
  ui.Image? _image;
  int _index = -1;
  bool _stopped = false;

  /// 다음 장을 그릴 타이머. **붙잡고 있다가 취소해야 한다** —
  /// `Future.delayed` 로 기다리면 취소할 수가 없어서 위젯이 사라진 뒤에도
  /// 타이머가 남는다(위젯 테스트가 `!timersPending` 으로 걸린다).
  Timer? _next;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _stopped = true;
    _next?.cancel();
    _image?.dispose();
    _codec?.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final data = await rootBundle.load(widget.asset);
      final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
      if (_stopped) {
        codec.dispose();
        return;
      }
      _codec = codec;
      _step();
    } catch (_) {
      // 아바타가 안 나와도 연출과 분석은 그대로 굴러가야 한다.
    }
  }

  Future<void> _step() async {
    final codec = _codec;
    if (_stopped || codec == null) return;
    try {
      final clock = Stopwatch()..start();
      final frame = await codec.getNextFrame();
      if (_stopped) {
        frame.image.dispose();
        return;
      }
      final old = _image;
      setState(() {
        _image = frame.image;
        _index = (_index + 1) % codec.frameCount;
      });
      // 한 장 그리고 바로 버린다. 쥐고 있으면 장수만큼 메모리가 쌓인다.
      old?.dispose();
      widget.onFrame(_index);

      // **디코드에 쓴 시간을 빼고 기다린다.** 그냥 duration 만큼 자면
      // 한 장의 주기가 `디코드 + duration` 이 되어 판이 통째로 느려진다 —
      // 768px 판에서 한 장에 20ms 가 걸리면 24fps 로 구운 것이 16fps 로
      // 돌아간다. 그게 "느리고 뚝뚝 끊긴다" 로 보였다.
      final want = frame.duration.inMicroseconds > 0
          ? frame.duration.inMicroseconds
          : 33333;
      final spent = clock.elapsedMicroseconds;
      _next = Timer(
        Duration(microseconds: want - spent > 0 ? want - spent : 0),
        _step,
      );
    } catch (_) {
      // 한 장 못 뽑아도 화면은 마지막 장으로 남는다.
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    final place = widget.placement;
    return Stack(
      fit: StackFit.expand,
      children: [
        // 뒤에 아주 옅게 깔리는 후광. 흰 바탕에서 형태가 붕 뜨지 않게 잡아 준다.
        DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              radius: 0.60,
              colors: [
                ScanTone.mist.withValues(alpha: 0.22),
                ScanTone.mist.withValues(alpha: 0.07),
                ScanTone.mist.withValues(alpha: 0),
              ],
              stops: const [0.0, 0.6, 1.0],
            ),
          ),
        ),
        if (image != null)
          if (place == null)
            CustomPaint(painter: _FramePainter(image))
          else
            Transform(
              transform: place.transform,
              child: CustomPaint(painter: _FramePainter(image)),
            ),
      ],
    );
  }
}

/// 정사각 프레임을 `BoxFit.contain` 과 같은 자리에 그린다.
class _FramePainter extends CustomPainter {
  const _FramePainter(this.image);
  final ui.Image image;

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.width < size.height ? size.width : size.height;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH((size.width - side) / 2, (size.height - side) / 2, side, side),
      // **none(최근접) 이다.** 판이 이미 네모 블록으로 구워져 있으므로
      // (`tools/hologram/pixelate.py`) 늘릴 때 섞으면 블록 모서리가 흐려져
      // 계단이 뭉개진다. 안 섞어야 레고블록이 그대로 커진다.
      Paint()..filterQuality = FilterQuality.none,
    );
  }

  @override
  bool shouldRepaint(_FramePainter old) => !identical(old.image, image);
}

// ---------------------------------------------------------------- HUD

/// 네 모서리 갈고리. 촬영 면(CornerBrackets)과 같은 언어를 쓴다.
class _BracketPainter extends CustomPainter {
  const _BracketPainter({required this.amount, this.frame});
  final double amount;

  /// 갈고리를 두를 자리. **얼굴을 감싸는 사각형**이다.
  ///
  /// 없으면 상자 네 귀퉁이에 두른다. 한때 그게 기본이었는데, 분석 화면이
  /// 상자를 세로로 길게 쓰게 되면서 갈고리가 화면 위아래 끝으로 밀려나
  /// 잘려 나갔다 — 얼굴을 겨누던 테두리가 통째로 사라져 보였다.
  final Rect? frame;

  @override
  void paint(Canvas canvas, Size size) {
    if (amount <= 0) return;
    final len = 26.0 * amount;
    final paint = Paint()
      // 기본값이 fill 이라 이걸 빼면 갈고리가 삼각형으로 칠해진다.
      ..style = PaintingStyle.stroke
      // **검은색이다.** 흰 선이었는데, 화면 바탕이 흰색으로 바뀐 뒤로는
      // 흰 바탕에 흰 갈고리라 통째로 안 보였다 — 얼굴을 겨누던 테두리가
      // 사라진 것처럼 보인 게 이것이다.
      ..color = ScanTone.ink.withValues(alpha: 0.85 * amount)
      ..strokeWidth = 1.6 * ScanTone.weight
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    const inset = 10.0;
    final box = frame ??
        Rect.fromLTRB(inset, inset, size.width - inset, size.height - inset);
    final l = box.left, r = box.right;
    final t = box.top, b = box.bottom;
    final corners = <List<Offset>>[
      [Offset(l, t + len), Offset(l, t), Offset(l + len, t)],
      [Offset(r - len, t), Offset(r, t), Offset(r, t + len)],
      [Offset(l, b - len), Offset(l, b), Offset(l + len, b)],
      [Offset(r - len, b), Offset(r, b), Offset(r, b - len)],
    ];

    // 어두운 갈고리에는 **흰 받침**이다 (격자에 쓰는 어두운 후광의 반대).
    // 갈고리가 머리카락 위에 걸릴 때 그것만 사라지는 걸 막는다.
    final backing = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6 * ScanTone.weight + 2.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = const Color(0xFFFFFFFF).withValues(alpha: 0.7 * amount);
    for (final c in corners) {
      final path = Path()..addPolygon(c, false);
      canvas.drawPath(path, backing);
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_BracketPainter old) =>
      old.amount != amount || old.frame != frame;
}

/// 사진 아래로 흐르는 좌표 한 줄. 지금 찍히고 있는 점의 실제 값이다.
///
/// 흰 바탕에서는 한 줄이면 충분하다. 여러 줄을 흘리면 재고 있다는 느낌보다
/// 화면이 바쁘다는 인상이 먼저 온다.
class _Telemetry extends StatelessWidget {
  const _Telemetry({
    required this.points,
    required this.revealed,
    required this.settled,
    required this.pulse,
  });

  final List<Offset>? points;
  final int revealed;
  final double settled;

  /// 깜박이는 표시등의 위상 (연출 진행값 그대로).
  final double pulse;

  @override
  Widget build(BuildContext context) {
    final all = points;
    // 자리는 늘 잡아 둔다 — 나타났다 사라지면 아래 문장이 위아래로 튄다.
    if (all == null || all.isEmpty) return const SizedBox(height: 22);

    final last = revealed > 0 ? all[(revealed - 1).clamp(0, all.length - 1)] : null;
    return SizedBox(
      height: 22,
      child: Opacity(
        // 홀로그램이 자리를 잡으면 뒤로 물러난다.
        opacity: (1 - settled * 0.75).clamp(0.0, 1.0),
        child: Row(
          children: [
            // 돌아가는 중이라는 표시등. 멈춰 있는 화면과 일하는 화면을
            // 가르는 건 결국 이런 작은 깜박임이다.
            Padding(
              padding: const EdgeInsets.only(right: 7),
              child: SizedBox(
                width: 5,
                height: 5,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: ScanTone.strong.withValues(
                      alpha: (pulse * 6) % 1.0 < 0.5 ? 0.9 : 0.18,
                    ),
                  ),
                ),
              ),
            ),
            Text(
              'LANDMARKS  ${revealed.toString().padLeft(2, '0')}/${all.length}',
              style: const TextStyle(
                fontSize: 9.5,
                letterSpacing: 1.3,
                fontWeight: FontWeight.w700,
                fontFeatures: [FontFeature.tabularFigures()],
                color: ScanTone.ink,
              ),
            ),
            if (last != null) ...[
              const SizedBox(width: 10),
              // 좁은 화면에서는 좌표가 먼저 잘린다. 개수는 끝까지 읽혀야 한다.
              Flexible(
                child: Text(
                  '${last.dx.toStringAsFixed(3)}   ${last.dy.toStringAsFixed(3)}',
                  softWrap: false,
                  overflow: TextOverflow.clip,
                  style: const TextStyle(
                    fontSize: 9.5,
                    letterSpacing: 0.6,
                    fontFeatures: [FontFeature.tabularFigures()],
                    color: ScanTone.label,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 문장 한 줄 + 진행 막대. 이 문장은 TTS 도 같이 읽는다.
class ScanStatusBar extends StatelessWidget {
  const ScanStatusBar(
      {super.key, required this.line, required this.progress});

  final String line;
  final double progress;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          line,
          // 저시력 사용자가 읽는 유일한 문장이다. 얼굴 위 선은 옅은
          // 하늘색이지만 **글자는 본문 잉크색(검정)** 이다 — 읽으라고 있는
          // 글자라 화면의 색 맞추기보다 대비가 먼저다.
          style: AppText.h1.copyWith(color: AppColors.ink),
        ),
        const SizedBox(height: 14),
        // 진행 막대. 5초 동안 채우기로 **약속**된 눈금이다 (AppState 참고) —
        // 서버의 남은 시간을 재는 게 아니라, 그 시간만큼은 반드시 기다린다.
        // 그래서 눈금이 중간에서 멈추거나 갑자기 튀지 않는다.
        Semantics(
          liveRegion: true,
          label: '분석 진행률 ${(progress.clamp(0.0, 1.0) * 100).round()} 퍼센트',
          child: ExcludeSemantics(
            child: Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Stack(
                      children: [
                        // 아직 안 찬 구간은 **회색**이다. 옅은 초록이면
                        // 찬 곳과 안 찬 곳이 같은 계열이라 어디까지 왔는지
                        // 한눈에 안 들어온다.
                        Container(height: 10, color: const Color(0xFFDCDFE2)),
                        FractionallySizedBox(
                          widthFactor: progress.clamp(0.0, 1.0),
                          child: Container(
                            height: 10,
                            decoration: const BoxDecoration(
                                gradient: AppColors.scanProgress),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                SizedBox(
                  width: 54,
                  child: Text(
                    '${(progress.clamp(0.0, 1.0) * 100).round()}%',
                    textAlign: TextAlign.right,
                    style: AppText.h1.copyWith(
                        fontSize: 20, color: AppColors.ink),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
