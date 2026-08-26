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
  const ZoneTrack(this.names, this.frames);

  final List<String> names;

  /// [프레임][부위] → 이미지 안 위치. 화면 밖으로 나간 값도 그대로 있다.
  final List<List<Offset?>> frames;

  int get length => frames.length;

  /// 이름으로 찾은 자리. 없으면 -1.
  int indexOf(String name) => names.indexOf(name);

  /// 프레임을 감아서 읽는다. 루프를 도는 값이라 나머지 연산이 맞다.
  List<Offset?> at(int frame) =>
      frames.isEmpty ? const [] : frames[frame % frames.length];

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
      if (names.isEmpty || frames.isEmpty) return null;
      return ZoneTrack(names, frames);
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

/// 분석 연출에 쓰는 색. 코랄 네 단계다.
///
/// 앱의 [AppColors.coral] · [AppColors.brand] 에 맞춰 잡았다 — 분석 화면만
/// 다른 색을 쓰면 그 구간만 딴 앱처럼 보인다. 흰 바탕에 얹는 것을 전제로
/// 명도를 내렸다. 아주 밝은 코랄은 흰 화면에서 그냥 사라진다.
class ScanTone {
  /// 빔이 지나가는 띠, 후광. 배경에 가까운 옅은 코랄.
  static const mist = Color(0xFFFFD3DC);

  /// 격자의 기본 선. 홀로그램 에셋의 선 색과 같은 값이다 —
  /// 사진 위 격자가 그대로 3D 로 떠오르는 것처럼 보이려면 같아야 한다.
  static const line = Color(0xFFE4607A);

  /// 이목구비 윤곽, 훑고 지나가는 앞줄. 가장 진한 단계.
  /// 앱의 brand(#B02426)를 그대로 쓰면 코랄이 아니라 경고등처럼 빨갛다 —
  /// 같은 코랄 계열에서 명도만 내린 값이어야 격자가 한 색으로 묶인다.
  static const strong = Color(0xFFC93F5C);

  /// 잡힌 점(하이라이트). 사진 위에서 눈에 띄어야 해서 가장 밝은 코랄이다
  /// (앱의 coral 과 같은 값). 흰 반짝임을 쓰면 이 화면에서 유일하게 색이
  /// 없는 요소가 되어 따로 논다.
  static const glint = Color(0xFFFF8DA1);

  /// 계측값 글자. 읽히되 앞으로 나서지 않는다. 회색이 아니라 코랄 계열이다.
  static const label = Color(0xFFB08A92);
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

  /// 아바타를 얼마나 키울지.
  ///
  /// 사진 구간이 있으면 1 이어야 한다 — 사진 위 격자와 **같은 자리·같은 크기**
  /// 여야 겹쳐 바뀔 때 튀지 않는다. 사진을 안 쓰면 맞출 상대가 없으므로
  /// 얼굴만 덩그러니 작게 뜨지 않도록 화면을 채운다.
  late final _zoom = widget.photoStage ? 1.0 : 1.5;

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

  /// 지금 프레임에서 각 부위를 짚을 화면 좌표.
  ///
  /// 구울 때 잰 값([ZoneTrack])이 있으면 그걸 쓰고, 없으면 null 을 돌려
  /// 페인터가 고정 좌표로 그리게 둔다 — 에셋을 다시 굽기 전에도 화면은 돈다.
  List<Offset?>? _anchors(HologramPlacement? place, int frame, Size box) {
    final track = _track;
    if (track == null || place == null) return null;
    final now = track.at(frame);
    return [
      for (final name in _AnalysisPainter.zoneNames)
        () {
          final i = track.indexOf(name);
          if (i < 0 || i >= now.length) return null;
          final uv = now[i];
          return uv == null ? null : place.map(uv, box);
        }(),
    ];
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
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: 3 / 4,
                      // 아바타와 그 위에 얹는 표시가 **같은 배치 셈**을 써야
                      // 조준틀이 얼굴에서 미끄러지지 않는다. 여기서 한 번
                      // 만들어 둘 다에 넘긴다.
                      child: LayoutBuilder(builder: (context, box) {
                        final place = HologramPlacement.of(
                            _fit, _target, box.biggest);
                        return Stack(
                      fit: StackFit.expand,
                      children: [
                        // 계기 눈금. 아바타보다 먼저 깔려서 화면이 '창' 이 된다.
                        IgnorePointer(
                          child: CustomPaint(
                            painter: _GraticulePainter(
                              amount: _seg(t, 0.0, 0.22),
                              sweep: life,
                            ),
                          ),
                        ),
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
                            opacity: morph,
                            child: _Hologram(
                              asset: widget.hologramAsset,
                              placement: place,
                              onFrame: (i) => _holoFrame.value = i,
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
                              ),
                            ),
                          ),
                          IgnorePointer(
                            child: CustomPaint(
                              painter:
                                  _BracketPainter(amount: _seg(t, 0.0, 0.18)),
                            ),
                          ),
                        ],
                        );
                      }),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                _Telemetry(
                  points: _overlay?.points,
                  revealed: revealed,
                  settled: _seg(t, _p.telemA, _p.telemB),
                  pulse: life,
                ),
                _StatusBar(
                  line: widget.statusLine,
                  progress: widget.progress,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 이 구간의 바탕. 흰색에 아주 옅은 냉기만 남겼다 — 완전한 순백은
/// 주변 코랄 화면과 붙었을 때 오히려 비어 보인다.
const _backdrop = LinearGradient(
  begin: Alignment.topCenter,
  end: Alignment.bottomCenter,
  colors: [Color(0xFFFFFFFF), Color(0xFFFEFBFB), Color(0xFFFBF5F5)],
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
        border: Border.all(color: const Color(0xFFEFE2E5)),
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

    // 머리카락이나 어두운 옷 위에서도 선이 보이도록 아주 옅은 받침을 먼저
    // 깐다. 선이 얇을수록 이게 중요해진다 — 없으면 어두운 데서 선이 사라진다.
    // 흰색이 아니라 가장 옅은 하늘색을 쓴다. 흰 받침은 이 화면에서 유일하게
    // 색이 없는 요소가 되어 자세히 보면 따로 논다.
    final backing = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..color = ScanTone.mist.withValues(alpha: 0.30);
    canvas.drawPath(grid, backing);
    canvas.drawPath(contour, backing);

    // 얇게 긋되 진하게. 굵은 선보다 가는 선이 정밀해 보인다.
    // 반투명하게 그으면 뒤 사진과 섞여 채도가 날아가 회색으로 보인다.
    // 얇게 유지하되 색은 거의 불투명하게 얹어야 하늘색으로 읽힌다.
    canvas.drawPath(
      grid,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.7
        ..color = ScanTone.line.withValues(alpha: 0.88 + 0.12 * settle),
    );
    // 이목구비는 한 단계 진하게. 격자가 성글어진 만큼 이 선들이 형태를 짊어진다.
    canvas.drawPath(
      contour,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.9
        ..strokeCap = StrokeCap.round
        ..color = ScanTone.strong.withValues(alpha: 0.92 + 0.08 * settle),
    );
    canvas.drawPath(
      front,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0
        ..color = ScanTone.strong,
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
    final bloom = Paint()
      ..color = ScanTone.glint.withValues(alpha: 0.55)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4.0);
    final core = Paint()..color = ScanTone.glint;

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

  // (짚는 지점, 라벨 지점, 이름). 전부 0~1 비율이다.
  // 아바타가 좌우로 훑기 때문에 짚는 지점은 가운데 쪽으로 잡아야 얼굴을 벗어나지 않는다.
  /// 부위 개수. 소리 큐가 이 개수를 따라간다.
  static int get zoneCount => _zones.length;

  /// 부위 이름. 구울 때 넘긴 `--zones` 의 이름과 같아야 짝이 맞는다.
  static List<String> get zoneNames => [for (final z in _zones) z.$3];

  /// i 번째 부위를 짚기 시작하는 시점 (구간 안 0~1 비율).
  static double zoneAt(int i) => 0.05 + i * 0.125;

  /// 조준틀이 다 조여 물리는 데 걸리는 몫. 소리는 이때 울린다.
  static const zoneLock = 0.13 * 0.55;

  /// 짚는 순서는 **위에서 아래**다. 스캔선이 내려가는 방향과 같아야
  /// 훑으면서 하나씩 잡는 것으로 읽힌다. 라벨은 좌우로 번갈아 두고
  /// 세로로 벌려 놓는다 — 같은 쪽에 몰리면 지시선이 서로를 넘는다.
  static const _zones = <(Offset, Offset, String)>[
    (Offset(0.52, 0.285), Offset(0.87, 0.13), '이마'),
    (Offset(0.38, 0.345), Offset(0.12, 0.25), '눈썹'),
    (Offset(0.62, 0.395), Offset(0.87, 0.36), '눈가'),
    (Offset(0.355, 0.495), Offset(0.12, 0.47), '볼'),
    (Offset(0.50, 0.505), Offset(0.87, 0.58), '코'),
    (Offset(0.50, 0.585), Offset(0.12, 0.69), '입술'),
    (Offset(0.53, 0.655), Offset(0.87, 0.80), '턱선'),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < _zones.length; i++) {
      final at = zoneAt(i);
      final on = ((amount - at) / 0.13).clamp(0.0, 1.0);
      if (on <= 0) continue;

      final (rawN, labelN, name) = _zones[i];
      final tracked = (anchors != null && i < anchors!.length)
          ? anchors![i]
          : null;
      // 잰 값이 없을 때만 고정 좌표를 배율만큼 밀어서 쓴다.
      final anchor = tracked ??
          Offset(
            (origin.dx + (rawN.dx - origin.dx) * zoom) * size.width,
            (origin.dy + (rawN.dy - origin.dy) * zoom) * size.height,
          );
      final label = Offset(labelN.dx * size.width, labelN.dy * size.height);
      // 라벨은 제자리에 있고 짚는 점만 움직인다. 그래서 어느 쪽으로 끌지도
      // **매 프레임 다시** 봐야 한다 — 안 그러면 선이 점을 지나쳐 돌아온다.
      final toRight = label.dx > anchor.dx;

      // 지시선은 꺾어서 끈다. 비스듬한 직선 하나보다 계측 도면처럼 읽힌다.
      final bend = Offset(anchor.dx + (label.dx - anchor.dx) * 0.55, label.dy);
      final tip = Offset.lerp(anchor, label, on)!;
      final line = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.7
        ..color = ScanTone.line.withValues(alpha: 0.75 * on);

      final path = Path()..moveTo(anchor.dx, anchor.dy);
      if (on > 0.55) {
        path.lineTo(bend.dx, bend.dy);
        path.lineTo(label.dx, label.dy);
      } else {
        path.lineTo(tip.dx, tip.dy);
      }
      canvas.drawPath(path, line);

      // 짚는 지점 — 네 귀퉁이가 조여 들어와 물리는 조준틀.
      // 그냥 점을 찍으면 '표시해 뒀다' 이지만, 조여 들어오면 **지금 재고 있다**
      // 로 읽힌다. 다 조인 뒤에 속을 비운 작은 원을 남긴다.
      _reticle(canvas, anchor, on);

      if (on < 0.6) continue;
      final text = ((on - 0.6) / 0.4).clamp(0.0, 1.0);
      // 다음 부위로 넘어가면 앞 부위는 확인된 것으로 바꾼다.
      final done = amount > at + 0.125;
      _label(canvas, label, name, done, toRight, text);
    }
  }

  /// 조준틀. `on` 0 → 1 동안 열려 있던 네 귀퉁이가 조여 든다.
  static void _reticle(Canvas canvas, Offset at, double on) {
    // 조이는 건 앞 절반에서 끝낸다. 뒤 절반은 라벨이 붙는 시간이다.
    final close = (on / 0.55).clamp(0.0, 1.0);
    final half = 11.0 - 6.4 * close;
    const arm = 3.4;

    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..strokeCap = StrokeCap.round
      ..color = ScanTone.strong.withValues(alpha: 0.85 * on);

    final path = Path();
    for (final (sx, sy) in const [(-1, -1), (1, -1), (-1, 1), (1, 1)]) {
      final cx = at.dx + half * sx, cy = at.dy + half * sy;
      path.moveTo(cx, cy + arm * -sy);
      path.lineTo(cx, cy);
      path.lineTo(cx + arm * -sx, cy);
    }
    canvas.drawPath(path, edge);

    if (close < 1) return;
    canvas.drawCircle(at, 2.6,
        Paint()..color = Colors.white.withValues(alpha: 0.9 * on));
    canvas.drawCircle(
      at,
      2.6,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.9
        ..color = ScanTone.strong.withValues(alpha: 0.9 * on),
    );
  }

  void _label(Canvas canvas, Offset at, String name, bool done, bool toRight,
      double fade) {
    final title = TextPainter(
      text: TextSpan(
        text: name,
        style: TextStyle(
          fontSize: 11.5,
          height: 1.2,
          fontWeight: FontWeight.w700,
          color: ScanTone.strong.withValues(alpha: fade),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final state = TextPainter(
      text: TextSpan(
        text: done ? '확인' : '검사 중',
        style: TextStyle(
          fontSize: 9,
          height: 1.3,
          letterSpacing: 0.6,
          color: ScanTone.label.withValues(alpha: fade),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final w = title.width > state.width ? title.width : state.width;
    // 라벨은 지시선 끝에서 바깥쪽으로 붙는다. 안쪽으로 붙으면 얼굴을 가린다.
    final x = toRight ? at.dx + 6 : at.dx - w - 6;
    final dx = toRight ? 0.0 : w - title.width;
    title.paint(canvas, Offset(x + dx, at.dy - 15));
    state.paint(canvas,
        Offset(toRight ? x : x + w - state.width, at.dy - 1));
  }

  @override
  bool shouldRepaint(_AnalysisPainter old) =>
      old.amount != amount ||
      old.zoom != zoom ||
      old.origin != origin ||
      !listEquals(old.anchors, anchors);
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

      // duration 이 0 인 파일이 있다. 그대로 두면 꽉 찬 루프가 된다.
      final wait = frame.duration.inMilliseconds > 0
          ? frame.duration
          : const Duration(milliseconds: 42);
      _next = Timer(wait, _step);
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
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(_FramePainter old) => !identical(old.image, image);
}

// ---------------------------------------------------------------- HUD

/// 계기 눈금자.
///
/// 화면 가장자리를 따라 눈금을 새기고, 그 위로 걸린 눈금 하나가 천천히
/// 옮겨 다닌다. 아바타만 떠 있으면 "그림" 이지만, 눈금이 둘리면 **재는 창** 이
/// 된다. 지어낸 숫자는 쓰지 않는다 — 눈금에는 값이 없다.
class _GraticulePainter extends CustomPainter {
  const _GraticulePainter({required this.amount, required this.sweep});

  /// 0~1. 눈금이 그려지는 정도.
  final double amount;

  /// 걸린 눈금이 옮겨 다니는 위상 (연출 진행값 그대로).
  final double sweep;

  /// 한 변의 눈금 개수. 촘촘하면 자가 아니라 무늬가 된다.
  static const _ticks = 24;

  @override
  void paint(Canvas canvas, Size size) {
    if (amount <= 0) return;

    final faint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..color = ScanTone.mist.withValues(alpha: 0.85 * amount);
    final major = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..color = ScanTone.line.withValues(alpha: 0.28 * amount);

    // 걸린 눈금. 한 칸씩 딱딱 끊어 옮긴다 — 부드럽게 흐르면 계측이 아니라
    // 장식으로 보인다.
    final live = ((sweep * 2.2 * _ticks).floor()) % _ticks;

    for (var i = 1; i < _ticks; i++) {
      final f = i / _ticks;
      final big = i % 4 == 0;
      final len = big ? 7.0 : 3.5;
      final p = (i == live || i == (live + _ticks ~/ 2) % _ticks)
          ? (Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2
            ..color = ScanTone.strong.withValues(alpha: 0.55 * amount))
          : (big ? major : faint);

      final x = size.width * f, y = size.height * f;
      canvas.drawLine(Offset(x, 0), Offset(x, len), p);
      canvas.drawLine(Offset(x, size.height), Offset(x, size.height - len), p);
      canvas.drawLine(Offset(0, y), Offset(len, y), p);
      canvas.drawLine(Offset(size.width, y), Offset(size.width - len, y), p);
    }
  }

  @override
  bool shouldRepaint(_GraticulePainter old) =>
      old.amount != amount || old.sweep != sweep;
}

/// 네 모서리 갈고리. 촬영 면(CornerBrackets)과 같은 언어를 쓴다.
class _BracketPainter extends CustomPainter {
  const _BracketPainter({required this.amount});
  final double amount;

  @override
  void paint(Canvas canvas, Size size) {
    if (amount <= 0) return;
    final len = 22.0 * amount;
    final paint = Paint()
      // 기본값이 fill 이라 이걸 빼면 갈고리가 삼각형으로 칠해진다.
      ..style = PaintingStyle.stroke
      ..color = ScanTone.line.withValues(alpha: 0.6 * amount)
      ..strokeWidth = 1.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    const inset = 10.0;
    final l = inset, r = size.width - inset;
    final t = inset, b = size.height - inset;
    final corners = <List<Offset>>[
      [Offset(l, t + len), Offset(l, t), Offset(l + len, t)],
      [Offset(r - len, t), Offset(r, t), Offset(r, t + len)],
      [Offset(l, b - len), Offset(l, b), Offset(l + len, b)],
      [Offset(r - len, b), Offset(r, b), Offset(r, b - len)],
    ];

    for (final c in corners) {
      canvas.drawPath(Path()..addPolygon(c, false), paint);
    }
  }

  @override
  bool shouldRepaint(_BracketPainter old) => old.amount != amount;
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
                color: ScanTone.strong,
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
class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.line, required this.progress});

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
          // 저시력 사용자가 읽는 유일한 문장이다. 흰 바탕이라 앱의 본문
          // 잉크색을 그대로 쓴다 — 여기만 다른 색이면 화면이 따로 논다.
          style: AppText.h1.copyWith(color: AppColors.ink),
        ),
        const SizedBox(height: 12),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: Stack(
            children: [
              Container(height: 4, color: const Color(0xFFF2E4E6)),
              FractionallySizedBox(
                widthFactor: progress.clamp(0.0, 1.0),
                child: Container(
                  height: 4,
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      colors: [ScanTone.mist, ScanTone.strong],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
