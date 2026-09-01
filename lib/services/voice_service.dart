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

  /// 받아 적어 둔 것을 비운다.
  ///
  /// 세션이 끝나도 [partialText] 와 후보는 남아 있어서, 다음 화면에서
  /// **지난번에 한 말이 그대로 다시 올라온다.** 새로 들을 자리에서는
  /// 반드시 먼저 비운다.
  void clearHeard() {
    if (_partial.isEmpty && _candidates.isEmpty) return;
    _partial = '';
    _candidates = const [];
    notifyListeners();
  }

  /// 지금 들어오는 소리 크기 0~1. 듣고 있지 않으면 0 이다.
  ///
  /// 질문 화면의 파형이 이 값으로 움직인다 — **실제로 말할 때만** 움직여야
  /// 마이크가 살아 있다는 신호가 된다. 가만히 흔들리는 파형은 장식일 뿐이고,
  /// 소리가 안 잡히는 상황(권한·먹통)을 사용자가 알아챌 방법이 없어진다.
  double get soundLevel => _level;
  double _level = 0;

  /// TTS 가 지금 읽고 있는 세기 0~1. 낱말이 바뀔 때 1 로 튀고, 화면 쪽에서
  /// 시간에 따라 가라앉힌다. 말하지 않으면 0 이다.
  double get speechPulse => isVoicing ? _speechPulse : 0;
  double _speechPulse = 0;

  /// **소리가 실제로 나오는 중인가.** [isSpeaking] 은 대기열 깃발이라 이
  /// 기기에서 `speak()` 가 낭독이 끝나기 전에 돌아오면 소리보다 먼저
  /// 꺼지고, 반대로 문장 사이나 엔진이 숨을 고르는 동안에는 소리가 없는데
  /// 켜져 있다 — 둘 다 파형이 소리와 어긋나는 원인이었다.
  ///
  /// 그래서 낱말 신호가 한 번이라도 온 엔진에서는 **신호만 본다**: 엔진이
  /// 낱말을 읽을 때마다 progress 가 오므로, 마지막 신호가 0.65초 안이면
  /// 말하는 중이다. 말이 끊기면 파형도 같이 끊기고, 다시 시작하면 첫
  /// 낱말과 함께 돌아온다. (낱말 사이 간격은 이보다 짧아서 안 깜빡인다.)
  /// 신호를 안 주는 엔진에서만 깃발로 되돌아간다.
  bool get isVoicing => _sawWordSignal
      ? DateTime.now().difference(_lastWordAt) <
          const Duration(milliseconds: 650)
      : _speaking;
  DateTime _lastWordAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _sawWordSignal = false;

  /// 파형이 스스로 가라앉게 화면에서 부른다.
  void decaySpeechPulse() {
    if (_speechPulse <= 0) return;
    _speechPulse = (_speechPulse - 0.06).clamp(0.0, 1.0);
  }

  /// 「못 들었어요」 안내를 잠시 끈다.
  ///
  /// 질문 화면에서는 세션이 짧은 침묵에 스스로 꺼져도 [AppState] 가 마이크를
  /// 다시 연다. 그때마다 "못 들었어요" 를 읽으면, 말하려고 숨 고르는 사이에
  /// 안내가 계속 끼어들어 정작 말을 못 한다.
  bool suppressMissedPrompt = false;

  /// 안드로이드가 주는 값은 대체로 -2 ~ 10 dB 언저리다. 0~1 로 눌러 담고
  /// 조금씩만 따라가게 해서 파형이 튀지 않게 한다.
  void _onLevel(double db) {
    final v = ((db + 2) / 12).clamp(0.0, 1.0);
    final next = _level + (v - _level) * 0.35;
    if ((next - _level).abs() < 0.01) return;
    _level = next;
    notifyListeners();
  }

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
    // 읽고 있는 낱말이 바뀔 때마다 알려 준다. 이 신호로 파형을 튀게 한다 —
    // TTS 출력의 실제 음량은 받아올 수 없지만, **낱말 경계는 말의 박자**라
    // 그것만으로도 "지금 이 말을 하고 있다" 가 보인다.
    _tts.setProgressHandler((text, start, end, word) {
      _speechPulse = 1.0;
      _lastWordAt = DateTime.now();
      _sawWordSignal = true;
      notifyListeners();
    });

    await _loadVoices();
    await _applyPreferredVoice();
    // 여기까지 오면 저장된 목소리·속도·음높이가 엔진에 들어갔다
    if (!_ttsReady.isCompleted) _ttsReady.complete();

    // STT
    // **기본 엔진을 먼저 쓴다.** androidIntentLookup 은 이 기기에서
    // com.google.android.as (AiAi) 를 고르는데, 그건 "볼륨 올려" 같은 짧은
    // 명령을 알아듣는 인식기라 **한 마디만 듣고 스스로 끊는다.** 질문을
    // 말하려고 숨 고르는 사이에 이미 세션이 끝나 있었다.
    // 기본 엔진이 없을 때만 AiAi 로 되돌아간다.
    _sttAvailable = await _initStt(aiAi: false);
    if (!_sttAvailable) {
      debugPrint('[STT] 기본 엔진 초기화 실패 → AiAi 로 폴백');
      _sttAvailable = await _initStt(aiAi: true);
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
              !suppressMissedPrompt &&
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
      if (_queued > 0) _queued--; // stopSpeaking 이 이미 비웠을 수 있다
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
    // 엔진이 완료를 안 알려 준 말이 큐에 남으면 다음 듣기가 막힌다.
    // 여기서 끊었으니 큐도 같이 비운다.
    _queued = 0;
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
    if (!_sttAvailable || _muted || _stt.isListening) {
      // 조용히 돌아가면 "눌러도 아무 일이 없다" 로만 보인다. 어디서 막혔는지
      // 남겨야 다음에 같은 신고가 왔을 때 추측하지 않아도 된다.
      debugPrint('[STT] 시작 못 함 — 사용가능=$_sttAvailable 음소거=$_muted '
          '이미듣는중=${_stt.isListening}');
      return;
    }
    _wantListening = true;
    notifyListeners();
    // 이전 세션이 완전히 정리되도록 아주 짧게 양보 (error_busy 방지)
    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (!_wantListening || _speaking || _muted || _stt.isListening) {
      debugPrint('[STT] 대기 후 취소 — 원함=$_wantListening 말하는중=$_speaking '
          '음소거=$_muted 이미듣는중=${_stt.isListening}');
      return;
    }
    try {
      await _stt.listen(
        onResult: _onResult,
        onSoundLevelChange: _onLevel,
        listenOptions: SpeechListenOptions(
          localeId: _localeId,
          listenFor: const Duration(seconds: 40),
          // 말이 멎은 뒤 세션을 닫기까지. 짧게 잡아야 최종 결과가 빨리 온다 —
          // 길면 다 말하고도 몇 초를 기다리게 된다. 말을 시작하기 전의
          // 뜸은 listenFor 가 받아 준다.
          pauseFor: const Duration(seconds: 3),
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
    _level = 0; // 파형이 마지막 크기로 굳어 있으면 아직 듣는 줄로 보인다
    if (_stt.isListening) await _stt.stop();
    notifyListeners();
  }

  /// 세션 종료 — 다시 들으려면 화면을 두드려야 한다.
  void _stopSession() {
    _wantListening = false;
    _level = 0;
    notifyListeners();
  }

  /// 세션이 열린 시각. 얼마나 버티는지 로그로 재려고 둔다.
  DateTime? _listenStart;

  void _onStatus(String status) {
    if (status == 'listening') {
      _listenStart = DateTime.now();
      debugPrint('[STT] 듣기 시작');
    } else if (_listenStart != null) {
      final ms = DateTime.now().difference(_listenStart!).inMilliseconds;
      debugPrint('[STT] $status — ${ms}ms 열려 있었다');
      if (status == 'done' || status == 'notListening') _listenStart = null;
    }
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
