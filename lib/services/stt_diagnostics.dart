import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 온디바이스 STT 진단 — Android 13+ 의 checkRecognitionSupport /
/// triggerModelDownload 를 호출한다 (speech_to_text 가 노출하지 않는 API).
///
/// 앱 시작 시 1회 상태를 로그로 남기고, 한국어 온디바이스 모델이 없으면
/// 다운로드를 요청한다.
class SttDiagnostics {
  SttDiagnostics._();
  static final SttDiagnostics instance = SttDiagnostics._();

  static const _ch = MethodChannel('beautytalk/stt_diag');

  Future<List<String>> listRecognizers() async {
    try {
      final r = await _ch.invokeListMethod<String>('listRecognizers');
      return r ?? const [];
    } catch (e) {
      debugPrint('[SttDiag] listRecognizers failed: $e');
      return const [];
    }
  }

  Future<bool> onDeviceAvailable() async {
    try {
      return await _ch.invokeMethod<bool>('onDeviceAvailable') ?? false;
    } catch (e) {
      return false;
    }
  }

  Future<Map<String, dynamic>> checkSupport({String locale = 'ko-KR'}) async {
    try {
      final r = await _ch.invokeMapMethod<String, dynamic>(
        'checkSupport',
        {'locale': locale},
      );
      return r ?? const {};
    } catch (e) {
      debugPrint('[SttDiag] checkSupport failed: $e');
      return {'error': '$e'};
    }
  }

  Future<Map<String, dynamic>> downloadModel({String locale = 'ko-KR'}) async {
    try {
      final r = await _ch.invokeMapMethod<String, dynamic>(
        'downloadModel',
        {'locale': locale},
      );
      return r ?? const {};
    } catch (e) {
      debugPrint('[SttDiag] downloadModel failed: $e');
      return {'error': '$e'};
    }
  }

  /// 앱 시작 시 호출 — 상태를 로그로 남기고 한국어 모델이 없으면 다운로드 요청.
  Future<void> reportAndEnsureKorean() async {
    final recognizers = await listRecognizers();
    final available = await onDeviceAvailable();
    debugPrint('[SttDiag] 인식기 ${recognizers.length}개: ${recognizers.join(", ")}');
    debugPrint('[SttDiag] 온디바이스 인식 가능: $available');

    final s = await checkSupport();
    if (s.containsKey('error')) {
      debugPrint('[SttDiag] checkSupport 오류: ${s['error']}');
      return;
    }
    final installed = (s['installedOnDevice'] as List?)?.cast<String>() ?? const [];
    final pending = (s['pendingOnDevice'] as List?)?.cast<String>() ?? const [];
    final supported = (s['supportedOnDevice'] as List?)?.cast<String>() ?? const [];
    debugPrint('[SttDiag] 설치됨(${installed.length}): $installed');
    debugPrint('[SttDiag] 대기중(${pending.length}): $pending');
    debugPrint('[SttDiag] 설치가능(${supported.length}): '
        '${supported.take(12).toList()}${supported.length > 12 ? "..." : ""}');

    bool hasKo(List<String> l) =>
        l.any((e) => e.toLowerCase().startsWith('ko'));

    if (hasKo(installed)) {
      debugPrint('[SttDiag] ✅ 한국어 온디바이스 모델 설치됨');
      return;
    }
    if (hasKo(pending)) {
      debugPrint('[SttDiag] ⏳ 한국어 모델 다운로드 진행 중');
      return;
    }
    debugPrint('[SttDiag] ⚠️ 한국어 온디바이스 모델 없음 → 다운로드 요청');
    final d = await downloadModel();
    debugPrint('[SttDiag] 다운로드 요청 결과: $d');
  }
}
