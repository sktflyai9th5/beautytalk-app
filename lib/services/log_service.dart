import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 앱 로그를 파일로 남긴다 (시연 중 문제 발생 시 사후 추적용).
///
/// - `debugPrint` 로 찍히는 모든 로그 + 잡히지 않은 예외를 파일에 기록
/// - 저장 위치(안드로이드): `/storage/emulated/0/Android/data/<패키지>/files/logs/app.log`
///   → 루팅 없이 `adb pull` 로 가져올 수 있다:
///   `adb pull /storage/emulated/0/Android/data/com.skt.beautytalk.beauty_talk/files/logs/app.log`
/// - 2MB 를 넘으면 app.log → app.prev.log 로 넘기고 새로 시작 (최대 2개 유지)
///
/// 인식된 음성은 app.log 에 넣지 않고 [writeSpeech] 로 speech.log 에 따로,
/// **최근 10건만** 남긴다 ([speechKeep]).
class LogService {
  LogService._();
  static final LogService instance = LogService._();

  static const _maxBytes = 2 * 1024 * 1024; // 2MB

  /// 인식된 음성을 몇 건까지 보관할지. 넘으면 오래된 것부터 지운다.
  static const speechKeep = 10;

  File? _file;
  File? _speechFile;
  IOSink? _sink;
  int _written = 0;
  final _buffer = StringBuffer();
  final _speech = <String>[];
  Timer? _flushTimer;
  bool _initialized = false;

  String? get path => _file?.path;

  /// main() 에서 가장 먼저 호출. 실패해도 앱은 정상 동작한다.
  Future<void> init() async {
    if (_initialized) return;
    try {
      final base = await _logDir();
      final dir = Directory('${base.path}/logs');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      _file = File('${dir.path}/app.log');
      _speechFile = File('${dir.path}/speech.log');
      await _rotateIfNeeded();
      _sink = _file!.openWrite(mode: FileMode.append);
      _written = _file!.existsSync() ? _file!.lengthSync() : 0;
      _initialized = true;

      _flushTimer = Timer.periodic(const Duration(seconds: 2), (_) => flush());
      _hookDebugPrint();
      _hookErrors();

      write('===== BeautyTalk 시작 ${DateTime.now().toIso8601String()} =====');
    } catch (e) {
      // 로그 파일을 못 열어도 앱은 그대로 동작
      debugPrint('[Log] init failed: $e');
    }
  }

  Future<Directory> _logDir() async {
    if (Platform.isAndroid) {
      // adb pull 로 접근 가능한 앱 전용 외부 저장소
      final ext = await getExternalStorageDirectory();
      if (ext != null) return ext;
    }
    return getApplicationDocumentsDirectory();
  }

  Future<void> _rotateIfNeeded() async {
    final f = _file;
    if (f == null || !f.existsSync()) return;
    if (f.lengthSync() < _maxBytes) return;
    final prev = File('${f.parent.path}/app.prev.log');
    if (prev.existsSync()) prev.deleteSync();
    f.renameSync(prev.path);
    _written = 0;
  }

  /// debugPrint 를 감싸서 콘솔 + 파일 양쪽에 출력
  void _hookDebugPrint() {
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      original(message, wrapWidth: wrapWidth);
      if (message != null) write(message);
    };
  }

  void _hookErrors() {
    final prevOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      write('!! FlutterError: ${details.exceptionAsString()}\n${details.stack}');
      flush();
      prevOnError?.call(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      write('!! Uncaught: $error\n$stack');
      flush();
      return false; // 기본 처리도 계속
    };
  }

  /// 타임스탬프를 붙여 버퍼에 쌓는다 (실제 쓰기는 2초마다 flush).
  void write(String message) {
    if (!_initialized) return;
    final t = DateTime.now();
    final ts = '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}:'
        '${t.second.toString().padLeft(2, '0')}.'
        '${t.millisecond.toString().padLeft(3, '0')}';
    _buffer.writeln('$ts $message');
    if (_buffer.length > 8 * 1024) flush();
  }

  /// 인식된 음성 한 건. app.log 가 아니라 speech.log 에 최근 [speechKeep] 건만 남는다.
  ///
  /// 음성 인식은 주변 대화까지 받아 적기 때문에, 앱 로그에 그대로 쌓이면
  /// 시연장에서 오간 말이 통째로 파일에 남는다. 디버깅에 필요한 건 방금 몇 건뿐이라
  /// 짧은 창만 유지하고 나머지는 지운다.
  void writeSpeech(String text) {
    if (!_initialized) return;
    final t = DateTime.now();
    final ts = '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}:'
        '${t.second.toString().padLeft(2, '0')}';
    _speech.add('$ts $text');
    keepRecent(_speech, speechKeep);
    try {
      // 매번 통째로 다시 쓴다 — 10줄짜리라 비용이 없고, 오래된 줄이 확실히 사라진다
      _speechFile?.writeAsStringSync('${_speech.join('\n')}\n');
    } catch (_) {
      // 쓰기 실패는 무시 (앱 동작 우선)
    }
  }

  /// 최근 [keep] 개만 남기고 오래된 앞쪽을 잘라낸다 (제자리 수정).
  @visibleForTesting
  static void keepRecent(List<String> lines, int keep) {
    if (keep <= 0) {
      lines.clear();
    } else if (lines.length > keep) {
      lines.removeRange(0, lines.length - keep);
    }
  }

  void flush() {
    if (!_initialized || _buffer.isEmpty) return;
    final chunk = _buffer.toString();
    _buffer.clear();
    try {
      _sink?.write(chunk);
      _written += chunk.length;
      if (_written >= _maxBytes) unawaited(_reopenRotated());
    } catch (e) {
      // 쓰기 실패는 무시 (앱 동작 우선)
    }
  }

  Future<void> _reopenRotated() async {
    try {
      await _sink?.flush();
      await _sink?.close();
      _sink = null;
      await _rotateIfNeeded();
      _sink = _file!.openWrite(mode: FileMode.append);
      _written = 0;
    } catch (_) {}
  }

  /// 앱 종료/백그라운드 진입 시 호출
  Future<void> close() async {
    flush();
    _flushTimer?.cancel();
    try {
      await _sink?.flush();
      await _sink?.close();
    } catch (_) {}
    _sink = null;
    _initialized = false;
  }
}
