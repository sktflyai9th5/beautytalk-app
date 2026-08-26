import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'log_service.dart';

/// 온디바이스 TTS(안드로이드 TTS 엔진) + STT(안드로이드 SpeechRecognizer).
///
/// 듣기는 **단발**이다 — 화면을 두드리면 한 발화만 듣고 스스로 멈춘다.
/// 계속 켜 두면 주변 대화가 전부 들어오고 배터리·프라이버시에도 불리하다.
///
/// [speak] 중에는 마이크를 끊어 자기 목소리를 명령으로 오인하지 않게 한다.
/// 인식된 최종 문장은 [onCommand] 스트림으로 나간다.
class VoiceService extends ChangeNotifier {
  VoiceService._();
  static final VoiceService instance = VoiceService._();

  final FlutterTts _tts = FlutterTts();
  final SpeechToText _stt = SpeechToText();

  final _commandController = StreamController<String>.broadcast();
  Stream<String> get onCommand => _commandController.stream;

  /// 실제로 어떤 경로로 초기화됐는지 (로그·디버그용)
  String engineLabel = '-';

  bool _sttAvailable = false;

  /// 두드린 뒤 실제 세션이 열리기 전까지의 가드.
  bool _wantListening = false;

  /// true 인 동안 STT 를 완전히 차단 (서버 응답 대기 등).
  bool _muted = false;
  bool get muted => _muted;
  set muted(bool v) {
    _muted = v;
    if (v) {
      if (_stt.isListening) _stt.stop();
      _wantListening = false;
      _partial = '';
    }
    notifyListeners();
  }

  bool _speaking = false;
  String _partial = '';
  String? _localeId;

  /// 마지막 인식의 후보 목록 (1순위 포함). STT 가 여러 가설을 주므로
  /// 1순위만 쓰지 않고 전부 명령 매칭에 쓴다.
  List<String> _candidates = const [];
  List<String> get candidates => _candidates;

  bool get isListening => _stt.isListening;
  bool get isSpeaking => _speaking;
  bool get sttAvailable => _sttAvailable;
  String get partialText => _partial;

  /// TTS 쪽 준비가 끝났는지. STT 초기화는 느려서 [init] 전체를 기다리면
  /// 인트로 안내(0.2초)가 **저장된 목소리가 적용되기 전에** 나가 버린다.
  /// 그래서 TTS 부분만 따로 알린다.
  final _ttsReady = Completer<void>();

  Future<void> init() async {
    // TTS — 저장된 음성/속도/음높이를 먼저 읽고 그 값으로 시작한다
    await _loadPrefs();
    await _tts.setLanguage('ko-KR');
    await _tts.setSpeechRate(_rate);
    await _tts.setPitch(_pitch);
    await _tts.setVolume(1.0);
    await _tts.awaitSpeakCompletion(true);
    // 완료 핸들러에서 _speaking 을 꺾지 않는다. 문장 하나가 끝날 때마다
    // 꺾이면, 대기열의 다음 문장이 시작되기 전 틈새에 마이크가 열리고 —
    // 앱이 자기 안내 방송("…촬영하기 버튼을…")을 받아 적어 혼자 촬영하고
    // 질문하고 분석까지 갔다. _speaking 은 대기열(_enqueue/whenComplete)만 만진다.
    _tts.setErrorHandler((m) => debugPrint('[TTS] engine error: $m'));

    await _loadVoices();
    await _applyPreferredVoice();
    // 여기까지 오면 저장된 목소리·속도·음높이가 엔진에 들어갔다
    if (!_ttsReady.isCompleted) _ttsReady.complete();

    // STT
    // AiAi(Android System Intelligence) 엔진 사용 시도 → 실패하면 기본 엔진으로 폴백.
    // androidIntentLookup 은 RecognitionService 목록의 첫 번째를 고르는데,
    // 이 기기에서는 com.google.android.as (AiAi) 가 첫 번째다.
    _sttAvailable = await _initStt(aiAi: true);
    if (!_sttAvailable) {
      debugPrint('[STT] AiAi 초기화 실패 → 기본 엔진으로 폴백');
      _sttAvailable = await _initStt(aiAi: false);
    }

    if (_sttAvailable) {
      final locales = await _stt.locales();
      final ko = locales.where((l) => l.localeId.startsWith('ko')).toList();
      _localeId = ko.isNotEmpty ? ko.first.localeId : null;
      debugPrint('[STT] 엔진=$engineLabel locale=$_localeId');
    }
    notifyListeners();
  }

  Future<bool> _initStt({required bool aiAi}) async {
    try {
      final ok = await _stt.initialize(
        onStatus: _onStatus,
        options: aiAi ? [SpeechToText.androidIntentLookup] : const [],
        onError: (e) {
          debugPrint('[STT] error: ${e.errorMsg} permanent=${e.permanent}');
          // 아무것도 못 들은 채 꺼졌으면 말해 준다. 조용히 꺼지면 사용자는
          // 죽은 마이크에 대고 계속 말한다 — 실제로 그랬다.
          if (_partial.isEmpty &&
              (e.errorMsg == 'error_no_match' ||
                  e.errorMsg == 'error_speech_timeout')) {
            unawaited(speak(missedSentence));
          }
          _stopSession();
        },
        debugLogging: false,
      );
      engineLabel = aiAi ? 'AiAi(intentLookup)' : '기본(폴백)';
      return ok;
    } catch (e) {
      debugPrint('[STT] init 실패(${aiAi ? "AiAi" : "기본"}): $e');
      return false;
    }
  }

  // ------------------------------------------------------------ TTS 음성 설정
  /// 설정 탭에서 고른 값이 여기에 저장된다 (앱을 껐다 켜도 유지).
  static const _prefsFileName = 'voice_prefs.json';
  File? _prefsFile;

  /// 지금 적용된 음성 이름 (null = 기기 기본값)
  String? _voiceName;
  String? get voiceName => _voiceName;

  double _rate = 0.5;
  double _pitch = 1.0;
  double get speechRate => _rate;
  double get pitch => _pitch;

  /// 설정 탭에서 버튼을 눌렀을 때 들려줄 샘플 문장.
  /// 실제 앱이 하는 말투 그대로여야 고를 때 판단이 된다.
  static const sampleSentence =
      '입술 오른쪽 아래 라인이 살짝 번졌어요. 면봉으로 가볍게 닦아 주세요.';

  /// 저장된 선택이 없을 때 쓸 기본 음성 후보 (앞쪽 우선).
  /// 기기마다 목록이 달라서 하나만 박아 두면 다른 폰에서 깨진다.
  static const _defaultVoices = <String>[
    'ko-kr-x-ism-local',
    'ko-kr-x-kob-local',
    'ko-kr-x-koc-local',
    'ko-kr-x-kod-local',
  ];

  List<Map<String, String>> _koVoices = const [];

  /// 기기가 지원하는 TTS 엔진·한국어 음성을 읽어 둔다 (설정 탭 목록용).
  Future<void> _loadVoices() async {
    try {
      debugPrint('[TTS] 엔진: ${await _tts.getEngines}');
      final voices = await _tts.getVoices;
      if (voices is! List) return;
      _koVoices = voices
          .whereType<Map>()
          .map((v) => v.map((k, val) => MapEntry('$k', '$val')))
          .where((v) => (v['locale'] ?? '').toLowerCase().startsWith('ko'))
          .toList();
      debugPrint('[TTS] 한국어 음성 ${_koVoices.length}개: '
          '${_koVoices.map((v) => v['name']).toList()}');
    } catch (e) {
      debugPrint('[TTS] 음성 목록 조회 실패: $e');
    }
  }

  /// 인터넷 없이 쓸 수 있는 한국어 음성만. 설정 탭에 이것만 띄운다.
  /// (network 판은 오프라인에서 침묵하고, kok-* 는 한국어가 아니라 콘칸어다)
  List<String> get offlineKoreanVoiceNames => _koVoices
      .map((v) => v['name'] ?? '')
      .where((n) => n.startsWith('ko-kr') && n.endsWith('-local'))
      .toList();

  /// 'ko-kr-x-ism-local' → 'ism'. 목록에서 서로 구분하는 짧은 이름.
  static String voiceTag(String name) {
    final parts = name.split('-');
    return parts.length >= 4 ? parts[3] : name;
  }

  /// 음성을 이름으로 즉시 바꾼다. 성공하면 선택을 저장한다.
  Future<bool> setVoiceByName(String name) async {
    final v = _koVoices.where((e) => e['name'] == name).firstOrNull;
    if (v == null) {
      debugPrint('[TTS] 음성 없음: $name');
      return false;
    }
    try {
      await _tts.setVoice({'name': v['name']!, 'locale': v['locale']!});
    } catch (e) {
      debugPrint('[TTS] 음성 변경 실패($name): $e');
      return false;
    }
    _voiceName = name;
    debugPrint('[TTS] 음성 변경: $name');
    notifyListeners();
    await _savePrefs();
    return true;
  }

  Future<void> setSpeechRate(double v) async {
    _rate = v.clamp(0.2, 1.0);
    await _tts.setSpeechRate(_rate);
    notifyListeners();
    await _savePrefs();
  }

  Future<void> setPitch(double v) async {
    _pitch = v.clamp(0.5, 2.0);
    await _tts.setPitch(_pitch);
    notifyListeners();
    await _savePrefs();
  }

  /// 설정 탭에서 음성을 눌렀을 때 — 바꾸고 바로 그 목소리로 샘플을 읽어 준다.
  Future<void> previewVoice(String name) async {
    if (!await setVoiceByName(name)) return;
    await announce(sampleSentence);
  }

  /// 저장된 선택 → 기본 후보 순으로 적용한다.
  Future<void> _applyPreferredVoice() async {
    for (final name in [?_voiceName, ..._defaultVoices]) {
      final v = _koVoices.where((e) => e['name'] == name).firstOrNull;
      if (v == null) continue;
      try {
        await _tts.setVoice({'name': v['name']!, 'locale': v['locale']!});
        _voiceName = name;
        debugPrint('[TTS] 음성 적용: ${v['name']} (${v['locale']})');
        return;
      } catch (e) {
        debugPrint('[TTS] 음성 적용 실패(${v['name']}): $e');
      }
    }
    _voiceName = null;
    debugPrint('[TTS] 기본 음성 사용');
  }

  // ------------------------------------------------------- 설정 저장 / 불러오기
  Future<File> _prefs() async =>
      _prefsFile ??= File('${(await getApplicationDocumentsDirectory()).path}'
          '/$_prefsFileName');

  Future<void> _loadPrefs() async {
    try {
      final f = await _prefs();
      if (!await f.exists()) return;
      final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      _voiceName = m['voice'] as String?;
      _rate = (m['rate'] as num?)?.toDouble() ?? _rate;
      _pitch = (m['pitch'] as num?)?.toDouble() ?? _pitch;
      debugPrint('[TTS] 저장된 설정: voice=$_voiceName rate=$_rate pitch=$_pitch');
    } catch (e) {
      debugPrint('[TTS] 설정 불러오기 실패: $e');
    }
  }

  Future<void> _savePrefs() async {
    try {
      final f = await _prefs();
      await f.writeAsString(
        jsonEncode({'voice': _voiceName, 'rate': _rate, 'pitch': _pitch}),
      );
    } catch (e) {
      debugPrint('[TTS] 설정 저장 실패: $e');
    }
  }

  // ---------------------------------------------------------------- TTS
  //
  // 말은 **겹치지 않는다.** 앞의 문장이 끝나야 다음 문장이 시작된다.
  // 겹쳐 나오면 앞이 보이지 않는 사용자에게는 둘 다 못 알아듣는 소리가 된다.
  //
  // 대신 **화면이 바뀌면 그 화면의 말은 버린다.** 이미 지나간 화면을 설명하며
  // 몇 초를 붙잡고 있으면, 새 화면에서 무엇을 해야 하는지 듣지 못한다.
  // 그 경계를 긋는 게 [announce] 다.

  /// 대기열 꼬리. 새 발화는 여기에 이어 붙는다.
  Future<void> _chain = Future<void>.value();

  /// 화면 세대. [announce] 가 올리면 앞 세대의 대기열은 전부 버려진다.
  int _scope = 0;

  /// 대기 중 + 재생 중인 발화 수
  int _queued = 0;

  /// 한 문장이 아무리 길어도 이만큼이면 끝난 것으로 본다.
  /// (엔진이 완료를 안 알려 주면 대기열이 영영 멈춘다)
  static const _speakCap = Duration(seconds: 30);

  /// 앞의 말이 끝난 뒤에 이어서 말한다.
  Future<void> speak(String text) => _enqueue(text, _scope);

  /// 화면이 바뀔 때 쓴다. 지금 하던 말과 대기열을 버리고 이것부터 말한다.
  Future<void> announce(String text) {
    _scope++; // 앞 세대 대기열 무효화
    _chain = Future<void>.value();
    unawaited(_tts.stop());
    return _enqueue(text, _scope);
  }

  Future<void> _enqueue(String text, int scope) {
    if (text.trim().isEmpty) return Future<void>.value();
    _queued++;
    _speaking = true;
    notifyListeners();
    final next = _chain.then((_) async {
      if (scope != _scope) return; // 화면이 바뀌었다 — 이 말은 버린다
      await _play(text);
    }).whenComplete(() {
      _queued--;
      if (_queued == 0) {
        _speaking = false;
        notifyListeners();
      }
    });
    _chain = next.catchError((_) {});
    return next;
  }

  Future<void> _play(String text) async {
    // 첫 안내가 기기 기본 목소리로 나가지 않도록 설정 적용을 기다린다.
    // 인트로는 2.6초라 이 정도(보통 수백 ms)는 연출 안에서 흡수된다.
    if (!_ttsReady.isCompleted) {
      await _ttsReady.future
          .timeout(const Duration(seconds: 2), onTimeout: () {});
    }
    // 듣는 중이면 잠시 멈춤 (자기 목소리 인식 방지)
    if (_stt.isListening) await _stt.stop();
    final sw = Stopwatch()..start();
    try {
      // awaitSpeakCompletion(true) 라서 이 await 가 낭독 끝까지 잡고 있는다
      await _tts.speak(text).timeout(_speakCap, onTimeout: () {});
      // 겹침을 눈으로 확인하려면 이 두 줄의 시각을 보면 된다
      debugPrint('[TTS] ${text.length}자 ${sw.elapsedMilliseconds}ms '
          '(대기 ${_queued - 1})');
    } catch (e) {
      debugPrint('[TTS] speak failed: $e');
    }
  }

  /// 지금 말과 **대기열 전부**를 버린다 ("조용히", 듣기 시작 직전 등)
  Future<void> stopSpeaking() async {
    _scope++;
    _chain = Future<void>.value();
    await _tts.stop();
    _speaking = false;
    notifyListeners();
  }

  // ---------------------------------------------------------------- STT
  /// 듣기가 빈손으로 끝났을 때 읽어 주는 문장
  static const missedSentence = '못 들었어요. 다시 눌러서 말씀해 주세요.';

  /// 한 번 듣기 시작 (화면을 두드렸을 때).
  /// 말이 끝나거나 시간이 지나면 스스로 멈춘다 — 계속 듣지 않는다.
  Future<void> startListening() async {
    if (_speaking || _queued > 0) {
      await stopSpeaking(); // 읽는 중이거나 읽을 게 남았으면 끊고 바로 듣기
    }
    if (!_sttAvailable || _muted || _stt.isListening) return;
    _wantListening = true;
    notifyListeners();
    // 이전 세션이 완전히 정리되도록 아주 짧게 양보 (error_busy 방지)
    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (!_wantListening || _speaking || _muted || _stt.isListening) return;
    try {
      await _stt.listen(
        onResult: _onResult,
        listenOptions: SpeechListenOptions(
          localeId: _localeId,
          listenFor: const Duration(seconds: 30),
          // 2초면 "말씀하세요" 를 듣고 숨 고르는 사이에 꺼진다. 실제로 그랬다.
          pauseFor: const Duration(seconds: 4),
          partialResults: true,
          cancelOnError: true,
          listenMode: ListenMode.dictation,
          onDevice: false, // 온디바이스 팩이 없는 기기 대비. 팩이 있으면 true 로.
        ),
      );
    } catch (e) {
      debugPrint('[STT] listen failed: $e');
      _wantListening = false;
    }
    notifyListeners();
  }

  Future<void> stopListening() async {
    _wantListening = false;
    if (_stt.isListening) await _stt.stop();
    notifyListeners();
  }

  /// 세션 종료 — 다시 들으려면 화면을 두드려야 한다.
  void _stopSession() {
    _wantListening = false;
    notifyListeners();
  }

  void _onStatus(String status) {
    debugPrint('[STT] status=$status');
    if (status == 'done' || status == 'notListening') _stopSession();
    notifyListeners();
  }

  void _onResult(SpeechRecognitionResult r) {
    if (_muted) return; // 서버 대기 중 들어온 인식 결과는 버림
    if (_speaking) return; // 말하는 중 — 자기 목소리를 받아 적지 않는다
    if (!r.finalResult) {
      // 받아 적은 내용은 app.log 에 남기지 않는다 (주변 대화가 통째로 쌓임)
      debugPrint('[STT] partial($engineLabel): ${r.recognizedWords.length}자');
    }
    _partial = r.recognizedWords;
    // 후보 전부 보관 (중복 제거) — 1순위가 틀려도 2·3순위에 정답이 있는 경우가 많다
    _candidates = {
      r.recognizedWords,
      ...r.alternates.map((a) => a.recognizedWords),
    }.where((s) => s.trim().isNotEmpty).toList();
    notifyListeners();
    if (!r.finalResult) return;

    _wantListening = false; // 한 발화가 끝나면 청취 종료
    if (r.recognizedWords.trim().isEmpty) return;
    // 인식된 문장은 speech.log 에 최근 10건만 (app.log 에는 길이·신뢰도만)
    LogService.instance.writeSpeech('"${r.recognizedWords}"'
        '${_candidates.length > 1 ? " 후보=${_candidates.skip(1).take(3).toList()}" : ""}');
    debugPrint('[STT] final: ${r.recognizedWords.length}자'
        '${_candidates.length > 1 ? " 후보 ${_candidates.length - 1}개" : ""}'
        '${r.confidence > 0 ? " conf=${r.confidence.toStringAsFixed(2)}" : ""}');
    _commandController.add(r.recognizedWords.trim());
    _partial = '';
  }

  @override
  void dispose() {
    _commandController.close();
    _stt.cancel();
    _tts.stop();
    super.dispose();
  }
}
