import 'dart:async';
import 'dart:ui' show Rect;
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:web_socket_channel/web_socket_channel.dart';

/// 팀 노트북 백엔드 (Tailscale tailnet 내부 주소). server/README.md 참고.
///  - 8100: 모델 라우터 (Docker) → 우선
///  - 8000: 예비 포트           → 폴백
///
/// 서버가 질문을 보고 경로를 고른다 — "립"이 들어가면 입술 크롭 + 립 프롬프트,
/// 아니면 얼굴 크롭 + 메이크업 어댑터. 앱은 어느 쪽인지 몰라도 된다.
class BackendConfig {
  /// 서버 주소는 **빌드할 때 넣는다.** 기본값이 없다 —
  /// 저장소에 특정 팀의 사설망 주소를 박아 두지 않기 위해서다.
  ///   flutter run --dart-define=BT_HOST=100.x.x.x
  /// (USB 로 PC 서버에 붙일 때는 `adb reverse tcp:8100 tcp:8100` 을 함께)
  ///
  /// 비어 있으면 메이크업 분석만 꺼지고, 온디바이스 기능은 그대로 동작한다.
  static const host = String.fromEnvironment('BT_HOST');
  static const ports = [8100, 8000];
  static const healthTimeout = Duration(seconds: 3);

  /// 실모델은 응답까지 20~60초 걸릴 수 있음
  /// 서버 생성 제한(BT_GENERATE_TIMEOUT=60초)보다 길어야 한다.
  /// 앱이 먼저 포기하면 다 만든 답을 버리고, 그 요청이 GPU 한 자리를
  /// 계속 잡고 있어서 바로 이어지는 재촬영까지 느려진다.
  static const analyzeTimeout = Duration(seconds: 70);

  static const warmUpTimeout = Duration(seconds: 25);

  /// 가이드 탭에 머무는 동안 GPU 를 깨워 두는 주기
  static const warmUpInterval = Duration(minutes: 5);

  /// 서버로 보낼 스냅샷의 긴 변 크기(px).
  ///
  /// 카메라가 1280x720 으로 찍는데 896 으로 줄여 보내고 있었다. 그러면 서버의
  /// 입술 검출 임계값(60px) 대비 여유가 1.1배밖에 안 남아서, 조금만 멀리 들어도
  /// "입술이 너무 작게 나왔어요" 로 되돌아온다. 촬영본을 그대로 보내면 1.6배가 된다.
  /// (인계 문서도 긴 변 1080px 이상을 권장했다)
  ///
  /// 추론은 느려지지 않는다 — 서버가 모델에 넣기 전 크롭을 640px 로 다시 줄인다.
  /// 전송량만 두 배쯤 되는데 Tailscale 로컬망이라 문제되지 않는다.
  static const snapshotMaxSide = 1280;
  static const snapshotJpegQuality = 88;
}

/// 찍기 전 프레이밍 판정 (GPU 안 씀 — 수십 ms).
class FramingCheck {
  const FramingCheck({required this.ok, required this.code, required this.guidance});
  final bool ok;
  final String code;    // ok | too_dark | no_face | too_small | cut_off | lip_small
  final String guidance; // 그대로 읽어 줄 짧은 한국어
}

/// 결과를 부위별로 쪼갠 것. 화면이 목록으로 그린다.
///
/// 음성은 [AnalysisResult.message] 를 그대로 읽는다 — 이 항목들을 이어 붙여
/// 문장을 다시 만들면 낭독과 화면이 어긋난다.
class AnalysisItem {
  const AnalysisItem({
    required this.region,
    required this.state,
    required this.action,
    required this.type,
    this.box,
  });

  final String region; // 왼쪽 볼 아래
  final String state;  // 베이스가 고르지 않게 발려 있어요.
  final String action; // 퍼프로 가볍게 두드려 정리해 주세요.
  final String type;   // 덜발림 | 경계 | 불균형

  /// 문제 위치 — 찍은 사진 기준 0..1 (서버가 정규화해서 준다). 없을 수 있다.
  final Rect? box;

  static AnalysisItem? tryParse(Object? o) {
    if (o is! Map) return null;
    final r = (o['region'] ?? '').toString();
    if (r.isEmpty) return null;
    Rect? box;
    final b = o['box'];
    if (b is List && b.length == 4) {
      final v = [for (final e in b) e is num ? e.toDouble() : double.nan];
      if (!v.any((e) => e.isNaN)) box = Rect.fromLTRB(v[0], v[1], v[2], v[3]);
    }
    return AnalysisItem(
      region: r,
      state: (o['state'] ?? '').toString(),
      action: (o['action'] ?? '').toString(),
      type: (o['type'] ?? '').toString(),
      box: box,
    );
  }
}

/// 서버 `analysis_result` 중 앱이 쓰는 부분.
class AnalysisResult {
  const AnalysisResult({
    required this.status,
    required this.message,
    this.items = const [],
  });

  final String status; // ok | retake | error
  final String message; // TTS 로 읽어줄 문장
  /// 화면 표시용. 립 경로는 문장만 오므로 비어 있다.
  final List<AnalysisItem> items;
}

/// WebSocket `/ws/{session_id}` 로 `analyze` 요청 → `analysis_result` 수신.
/// 영상은 WebRTC 대신 스냅샷(`image_b64`) 폴백을 사용한다 (앱 기능 동일).
class BackendService extends ChangeNotifier {
  BackendService._();
  static final BackendService instance = BackendService._();

  String? _base; // e.g. 100.91.201.104:8100
  String analyzer = '-';
  WebSocketChannel? _ws;
  StreamSubscription? _sub;
  bool _connecting = false;
  final _pending = <String, Completer<AnalysisResult>>{};
  int _reqCounter = 0;
  final String sessionId =
      'app-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}-${math.Random().nextInt(0xffff).toRadixString(16)}';

  // ------------------------------------------------------------ discovery
  /// 8100 → 8000 순서로 /health 를 확인해 살아있는 서버 선택.
  Future<bool> discover() async {
    if (BackendConfig.host.isEmpty) {
      // 주소를 안 넣고 빌드한 경우. 매번 3초씩 헛되이 기다리지 않는다.
      debugPrint('[Backend] BT_HOST 가 비어 있다 — '
          '--dart-define=BT_HOST=<주소> 로 빌드해야 메이크업 분석이 동작한다');
      return false;
    }
    for (final port in BackendConfig.ports) {
      final base = '${BackendConfig.host}:$port';
      try {
        final r = await http
            .get(Uri.parse('http://$base/health'))
            .timeout(BackendConfig.healthTimeout);
        if (r.statusCode == 200) {
          final j = jsonDecode(r.body) as Map<String, dynamic>;
          if (j['status'] == 'healthy') {
            _base = base;
            analyzer = (j['analyzer'] ?? '?').toString();
            debugPrint('[Backend] using $base analyzer=$analyzer');
            notifyListeners();
            return true;
          }
        }
      } catch (e) {
        debugPrint('[Backend] $base unreachable: $e');
      }
    }
    _base = null;
    notifyListeners();
    return false;
  }

  // ------------------------------------------------------------ websocket
  Future<bool> connect() async {
    // mock(8000)에 붙어 있으면 실모델(8100)이 떠 있는지 재탐색 후 갈아탄다
    if (_ws != null && analyzer == 'mock') {
      final prev = _base;
      await discover();
      if (_base != prev) {
        debugPrint('[Backend] upgrading $prev → $_base');
        await disconnect();
      }
    }
    if (_ws != null) return true;
    if (_connecting) return false;
    _connecting = true;
    try {
      if (_base == null && !await discover()) return false;
      final uri = Uri.parse('ws://$_base/ws/$sessionId');
      final ch = WebSocketChannel.connect(uri);
      await ch.ready.timeout(const Duration(seconds: 6));
      _ws = ch;
      _sub = ch.stream.listen(_onMessage, onDone: _onClosed, onError: (e) {
        debugPrint('[Backend] ws error: $e');
        _onClosed();
      });
      debugPrint('[Backend] ws connected $uri');
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('[Backend] ws connect failed: $e');
      _ws = null;
      _base = null; // 다음 시도에서 8100→8000 순서로 재탐색
      return false;
    } finally {
      _connecting = false;
    }
  }

  void _onClosed() {
    _sub?.cancel();
    _sub = null;
    _ws = null;
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(StateError('connection closed'));
    }
    _pending.clear();
    notifyListeners();
  }

  void _onMessage(dynamic data) {
    if (data is! String) return;
    Map<String, dynamic> m;
    try {
      m = jsonDecode(data) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final type = m['type'];
    if (type == 'analysis_result') {
      final id = m['request_id']?.toString();
      final c = id == null ? null : _pending.remove(id);
      final r = AnalysisResult(
        status: (m['status'] ?? 'error').toString(),
        message: (m['message'] ?? '').toString(),
        items: [
          for (final e in (m['items'] as List? ?? const []))
            ?AnalysisItem.tryParse(e),
        ],
      );
      if (c != null && !c.isCompleted) c.complete(r);
    } else if (type == 'error') {
      debugPrint('[Backend] server error: ${m['message']}');
    }
  }

  // ------------------------------------------------------------ analyze
  /// [imagePath] 는 방금 찍은 JPEG. 없으면 영상 없이 요청 (mock 서버는 응답, 실모델은 error).
  Future<AnalysisResult> analyze(String question, {String? imagePath}) async {
    if (!await connect()) throw StateError('backend unavailable');
    String? b64;
    if (imagePath != null) {
      final sw = Stopwatch()..start();
      final encoded = await compute(_encodeSnapshot, imagePath);
      b64 = encoded;
      debugPrint('[Backend] snapshot ${(encoded.length * 3 / 4 / 1024).round()}KB '
          '(${BackendConfig.snapshotMaxSide}px, ${sw.elapsedMilliseconds}ms)');
    }
    final id = 'app-${++_reqCounter}';
    final c = Completer<AnalysisResult>();
    _pending[id] = c;
    _ws!.sink.add(jsonEncode({
      'type': 'analyze',
      'question': question,
      'request_id': id,
      'image_b64': ?b64,
    }));
    // 분석 요청 = GPU 가 지금부터 최대로 돌아감 → warm 으로 간주
    markWarm();
    return c.future.timeout(BackendConfig.analyzeTimeout, onTimeout: () {
      _pending.remove(id);
      // 타임아웃의 흔한 원인은 죽은 소켓이다 (Tailscale 순단 — 서버는 멀쩡한데
      // 앱만 유령 연결을 물고 있다). 끊어 버려야 다음 시도가 새로 접속한다.
      try {
        _ws?.sink.close();
      } catch (_) {}
      _onClosed();
      debugPrint('[Backend] analyze timeout after ${BackendConfig.analyzeTimeout.inSeconds}s (id=$id)');
      throw TimeoutException('analysis timeout');
    }).whenComplete(markWarm); // 응답 직후가 GPU 가 가장 뜨거운 시점
  }

  /// 찍기 전에 지금 화면이 쓸 만한지 물어본다.
  ///
  /// 분석과 같은 크기로 보내야 한다 — 서버가 픽셀 단위 임계값으로 판정하므로
  /// 여기서 작게 보내면 통과해 놓고 본 촬영에서 재촬영이 뜬다.
  /// 서버가 없거나 실패하면 null — 호출부는 그냥 촬영을 진행한다.
  Future<FramingCheck?> checkFraming(String imagePath) async {
    if (_base == null && !await discover()) return null;
    try {
      final b64 = await compute(_encodeSnapshot, imagePath);
      final r = await http
          .post(Uri.parse('http://$_base/framing'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'image_b64': b64}))
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return null;
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      debugPrint('[Framing] ${j['code']} face=${j['face_w']} lip=${j['lip_w']} ${j['ms']}ms');
      return FramingCheck(
        ok: j['ok'] == true,
        code: (j['code'] ?? '').toString(),
        guidance: (j['guidance'] ?? '').toString(),
      );
    } catch (e) {
      debugPrint('[Framing] 확인 실패 (그냥 촬영 진행): $e');
      return null;
    }
  }

  bool _warming = false;
  DateTime _lastWarm = DateTime.fromMillisecondsSinceEpoch(0);

  /// GPU 가 방금 일했다고 표시. 실제 분석도 GPU 를 최대로 돌리므로
  /// warm-up 과 동일하게 취급해서 불필요한 추가 요청을 막는다.
  void markWarm() => _lastWarm = DateTime.now();

  /// 마지막으로 GPU 가 돌아간 시각 (분석 포함)
  DateTime get lastWarm => _lastWarm;

  /// GPU 깨우기 — 서버에 토큰 1개짜리 추론을 시켜 저전력 상태에서 빠져나오게 한다.
  /// 노트북 GPU 가 절전으로 내려가면 첫 추론이 30~60초 걸리는 문제 대응.
  /// 실패해도 무시(서버가 없을 수도 있음). 분석 중이면 건너뛴다.
  Future<void> warmUp({String reason = ''}) async {
    if (_warming) return;
    // 방금 데운 직후면 생략
    if (DateTime.now().difference(_lastWarm) < const Duration(seconds: 60)) return;
    if (_base == null && !await discover()) return;
    _warming = true;
    final sw = Stopwatch()..start();
    try {
      final r = await http
          .post(Uri.parse('http://$_base/warmup'))
          .timeout(BackendConfig.warmUpTimeout);
      _lastWarm = DateTime.now();
      debugPrint('[Backend] GPU warm-up $reason → ${r.statusCode} in ${sw.elapsedMilliseconds}ms');
    } catch (e) {
      debugPrint('[Backend] GPU warm-up $reason failed (${sw.elapsedMilliseconds}ms): $e');
    } finally {
      _warming = false;
    }
  }

  Future<void> disconnect() async {
    await _sub?.cancel();
    await _ws?.sink.close();
    _onClosed();
  }
}

/// 긴 변 896px, JPEG q88 로 다시 인코딩 (isolate).
/// 원본보다 크게 키우지는 않는다.
String _encodeSnapshot(String path) {
  final bytes = File(path).readAsBytesSync();
  var im = img.decodeImage(bytes);
  if (im == null) return base64Encode(bytes);
  im = img.bakeOrientation(im);
  final longSide = math.max(im.width, im.height);
  if (longSide > BackendConfig.snapshotMaxSide) {
    final s = BackendConfig.snapshotMaxSide / longSide;
    im = img.copyResize(
      im,
      width: (im.width * s).round(),
      height: (im.height * s).round(),
      interpolation: img.Interpolation.cubic,
    );
  }
  return base64Encode(
    img.encodeJpg(im, quality: BackendConfig.snapshotJpegQuality),
  );
}
