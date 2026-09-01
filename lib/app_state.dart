import 'dart:async';

import 'package:camera/camera.dart' show CameraLensDirection;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'ml/cosmetic_classifier.dart';
import 'services/backend_service.dart';
import 'services/camera_service.dart';
import 'services/command_matcher.dart';
import 'services/log_service.dart';
import 'services/scan_sfx.dart';
import 'services/voice_service.dart';

enum AppTab { cosmetic, makeup, settings }

/// 앱 최상위 흐름. 피그마 ①진입 화면 기준.
///   entry : 두 버튼이 있는 진입 화면
///   main  : 탭 + 플로우 화면
///
/// 그 앞의 진입 애니메이션은 `AppState` 가 만들어지기 전에도 돌아야 해서
/// main.dart 가 따로 들고 있다 (「최소 노출 시간은 두지 않는다」).
enum AppPhase { entry, main }

/// 화장품 인식 3단계 (피그마 단계 표시기: 촬영 → 분석 → 결과)
enum CosmeticStage { capture, analyzing, result }

/// 메이크업 분석 4단계 (촬영 → 질문 → 분석 → 결과)
enum MakeupStage { capture, question, analyzing, result }

class ChatMessage {
  const ChatMessage({required this.text, required this.fromUser, this.latency});
  final String text;
  final bool fromUser;

  /// 서버 응답 소요 시간 (봇 메시지에만).
  final Duration? latency;
}

/// 화면 상태 + 음성 명령 라우팅.
class AppState extends ChangeNotifier {
  AppState({required this.classifier});

  final CosmeticClassifier classifier;
  final voice = VoiceService.instance;
  final camera = CameraService.instance;
  final backend = BackendService.instance;

  bool started = false; // 진입 화면을 지났는지
  AppPhase phase = AppPhase.entry;
  AppTab tab = AppTab.cosmetic;
  CosmeticStage cosmeticStage = CosmeticStage.capture;
  MakeupStage makeupStage = MakeupStage.capture;
  CosmeticPrediction? prediction;

  /// 메이크업 결과를 부위별로 쪼갠 것 (피그마 결과 리스트).
  /// 서버가 items 를 주면 채워지고, 없으면 비어 있다 (문장만 읽어 준다).
  List<AnalysisItem> analysisItems = const [];

  /// 마지막으로 읽어 준 분석 문장 — "다시 들려주기" 가 쓴다
  String lastSpokenResult = '';

  /// 서버 분석 진행률 0.0~1.0 (화면 진행 바)
  double analysisProgress = 0;

  /// 받침이 있으면 '을', 없으면 '를'. "피부을 분석" 이라고 말하면
  /// 기계 티가 나는 정도가 아니라 잘못 알아듣기 쉽다.
  static String _eulReul(String word) {
    if (word.isEmpty) return '을';
    final c = word.codeUnitAt(word.length - 1);
    if (c < 0xAC00 || c > 0xD7A3) return '을';
    return (c - 0xAC00) % 28 != 0 ? '을' : '를';
  }

  /// 질문이 짚은 부위 — 항목 없는 결과 카드의 제목으로도 쓴다
  String get analysisFocus => _focusOf(lastHeard);

  /// 지금 무엇을 보고 있는지 — 분석 화면 글귀. 음성과 같은 말이다.
  String get analysisLine {
    final f = _focusOf(lastHeard);
    return '$f${_eulReul(f)} 분석 중이에요.';
  }

  /// 마지막으로 인식된 사용자 발화 (질문 화면에 그대로 보여 준다)
  String lastHeard = '';

  /// 마지막으로 찍은 사진 경로.
  /// 피그마 결과 카드의 제품 사진 자리에 이걸 보여 준다.
  String? lastShotPath;

  /// 피그마의 대화 기록은 샘플 — 실제 앱은 빈 상태로 시작한다.
  final List<ChatMessage> chat = [];

  /// 가이드 탭 촬영 안내를 이미 읽어 줬는지 (처음 한 번만 길게 말한다)
  bool _makeupIntroDone = false;

  /// 렌즈 이물질 검사 중인가 (온디바이스 cls_head)
  bool lensChecking = false;
  StreamSubscription<String>? _cmdSub;

  // ------------------------------------------------------------ lifecycle
  void bindVoice() {
    _cmdSub ??= voice.onCommand.listen(handleVoice);
    voice.addListener(_onVoicePartial);
  }

  String _lastPartialFired = '';
  DateTime _squelchFinalUntil = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _makeupDebounce;
  String _makeupPending = '';

  /// 새로 들을 자리에서 지난 발화를 지운다 — 화면·대기값·중복 방지값까지.
  void _clearHeard() {
    voice.clearHeard();
    lastHeard = '';
    _makeupPending = '';
    _lastPartialFired = '';
    _makeupDebounce?.cancel();
  }

  /// 최종 인식(침묵 4초 대기)을 기다리지 않고, 부분 인식에 명령어가 보이면 즉시 실행.
  /// 같은 발화의 최종 결과가 뒤따라 와도 중복 실행되지 않게 잠시 무시한다.
  void _onVoicePartial() {
    // 세션이 꺼졌으면 다시 열지 판단한다. 부분 인식이 없어도 불려야 하므로
    // 아래 조기 반환보다 먼저 둔다.
    _maybeReopenMic();
    // 말하는 중에 들어온 부분 인식은 전부 버린다 — 자기 안내 방송이다
    if (voice.isSpeaking) return;
    final p = voice.partialText.replaceAll(' ', '');
    if (p.isEmpty) return;

    if (!started) {
      if (p.contains('시작') || p.contains('스타트') || p.contains('뷰티톡')) {
        _firePartial(p);
        start();
      }
      return;
    }
    if (p == _lastPartialFired) return; // 같은 발화 중복 방지

    // 가이드 탭에서는 짧은 발화만 이동 명령으로 취급 —
    // "눈썹 어때?" 같은 질문은 서버 분석으로 가야 한다.
    // 질문 화면에서는 어떤 발화도 이동 명령으로 안 본다. 마이크를 눌러 놓고
    // 말했는데 짧다고 버리거나 탭을 옮겨 버리면 "음성이 안 된다" 가 된다.
    final inQuestion =
        tab == AppTab.makeup && makeupStage == MakeupStage.question;

    // 이동 명령이 먼저다 — 어느 화면에서든 말로 탭을 옮길 수 있어야 한다.
    // 질문("메이크업 어때?")은 navTarget 이 걸러서 아래 질문 경로로 내려간다.
    AppTab? navTo;
    for (final c in (voice.candidates.isEmpty ? [p] : voice.candidates)) {
      navTo = navTarget(c.replaceAll(' ', ''));
      if (navTo != null) break;
    }
    if (navTo != null) {
      if (navTo != tab) {
        _firePartial(p);
        goTab(navTo);
      }
      return;
    }
    if (p.contains('처음') || p.contains('홈으로')) {
      _firePartial(p);
      resetToStart();
      return;
    }

    final allowNav = !inQuestion && (tab != AppTab.makeup || p.length <= 5);

    // 가이드 탭 질문: 최종 인식 결과를 기다리지 않고 부분 인식이 멎으면 전송.
    // (STT 세션이 중간에 끊겨 최종 결과가 안 오는 경우가 있어서)
    if (tab == AppTab.makeup && !asking && !allowNav) {
      _makeupPending = voice.partialText.trim();
      _makeupDebounce?.cancel();
      // **이 타이머는 주 경로가 아니라 안전망이다.**
      //
      // 문장이 끝난 시점은 인식기가 직접 판단해 최종 결과로 알려 준다
      // (handleVoice → ask). 사람이 말을 마치는 순간을 우리 시계로 재는 것보다
      // 정확하다 — 말이 빠른 사람도, 중간에 뜸을 들이는 사람도 같이 맞는다.
      //
      // 다만 세션이 중간에 끊겨 최종 결과가 영영 안 오는 기기가 있어서,
      // 그때만 늦게라도 보내라고 이 타이머를 남겨 둔다. 그래서 인식기가
      // 판단할 시간을 먼저 주도록 넉넉히 잡는다.
      _makeupDebounce = Timer(const Duration(milliseconds: 900), () {
        final q = _makeupPending;
        if (q.length < 2 || asking || tab != AppTab.makeup) return;
        // 질문형/트리거가 아닌 발화(주변 대화 등)는 무시 —
        // 단, 질문 화면에서는 사용자가 마이크를 눌러 놓고 한 말이라
        // 전부 질문으로 받는다. "베이스" 한 마디도 질문이다.
        if (!inQuestion && !looksLikeQuestion(q.replaceAll(' ', ''))) {
          LogService.instance.writeSpeech('무시(질문 아님) "$q"');
          debugPrint('[Makeup] 무시(질문 아님): ${q.length}자');
          return;
        }
        _firePartial(p);
        _closeMicWindow();
        // 보냈으면 마이크를 닫는다. 열어 두면 서버를 기다리는 동안 주변
        // 소리를 계속 받아 적고, 사용자에게는 아직 듣는 중으로 보인다.
        unawaited(voice.stopListening());
        ask(q);
      });
      return;
    }

    // 인식 후보 전부를 대상으로 판정 (1순위가 틀려도 2·3순위에 정답이 있음)
    final cands = voice.candidates.isEmpty ? [p] : voice.candidates;
    bool has(String kw) => CommandMatcher.matchAny(cands, kw);

    // 화장품 탭: 촬영
    if (tab == AppTab.cosmetic &&
        cosmeticStage == CosmeticStage.capture &&
        (has('촬영') || has('사진') || has('인식') || p.contains('찍'))) {
      _firePartial(p);
      captureAndAnalyze();
    }
  }

  void _firePartial(String p) {
    _lastPartialFired = p;
    _squelchFinalUntil = DateTime.now().add(const Duration(seconds: 4));
  }

  @override
  void dispose() {
    voice.removeListener(_onVoicePartial);
    _cmdSub?.cancel();
    _makeupDebounce?.cancel();
    _warmUpTimer?.cancel();
    _framingTimer?.cancel();
    _progressTimer?.cancel();
    super.dispose();
  }

  // ------------------------------------------------------------ countdown
  /// 촬영까지 남은 초. 3·2·1 을 세는 동안만 값이 있고 평소에는 null 이다.
  int? countdown;

  /// 세는 중에 화면을 벗어나면 취소한다. 세대가 어긋나면 그 카운트는 버린다.
  int _countGen = 0;

  /// 찍기 직전 3·2·1.
  ///
  /// 「접근성 명세」: 숫자만 읽는다. 화면을 못 보는 사용자에게 이 셋은
  /// **자세를 잡을 시간**이고, 그동안 다른 말을 얹으면 셋을 놓친다.
  /// 모션 축소 설정이면 숫자는 애니메이션 없이 뜨지만 음성 카운트는 유지한다 —
  /// 세는 소리가 없으면 언제 찍히는지 알 방법이 없다.
  ///
  /// 도중에 탭을 옮기면 false 를 돌려주고 촬영하지 않는다.
  Future<bool> _countThreeTwoOne() async {
    final gen = ++_countGen;
    for (var n = 3; n >= 1; n--) {
      if (gen != _countGen) return false;
      countdown = n;
      notifyListeners();
      HapticFeedback.selectionClick();
      unawaited(voice.announce('$n'));
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    if (gen != _countGen) {
      return false;
    }
    countdown = null;
    notifyListeners();
    return true;
  }

  /// 세던 것을 끊는다 (탭 이동·촬영 취소).
  void _cancelCountdown() {
    _countGen++;
    if (countdown != null) {
      countdown = null;
      notifyListeners();
    }
  }

  // ------------------------------------------------------------ navigation
  /// 진입 화면에서 플로우로 들어간다.
  ///
  /// 「접근성 명세」: 화면 아무 곳이나 두드리면 화장품 촬영 화면으로 이동하며,
  /// 이때 "화장품 인식, 탭, 선택됨" 을 함께 읽는다.
  Future<void> start({AppTab to = AppTab.cosmetic}) async {
    if (started) return;
    started = true;
    phase = AppPhase.main;
    tab = to;
    notifyListeners();
    HapticFeedback.mediumImpact();
    await goTab(to, announce: true);
  }

  Future<void> goTab(AppTab t, {bool announce = true}) async {
    // 화면을 떠나면 그 화면의 말은 끝낸다. 지나간 화면을 설명하며 몇 초를
    // 붙잡고 있으면 새 화면에서 무엇을 해야 하는지 듣지 못한다.
    // (설정 탭처럼 새 안내가 없는 곳으로 갈 때도 반드시 끊어야 한다)
    if (t != tab) await voice.stopSpeaking();
    _cancelCountdown();
    _closeMicWindow();
    tab = t;
    // 탭에 들어오면 항상 처음(촬영)부터. 지난 결과·진행 중이던 분석 화면이
    // 남아 있으면 중간부터 시작하는 셈이다. 돌아오던 서버 응답은 세대(_askGen)
    // 불일치로 버려진다.
    _askGen++;
    cosmeticStage = CosmeticStage.capture;
    makeupStage = MakeupStage.capture;
    prediction = null;
    analysisItems = const [];
    analysisProgress = 0;
    framingHint = '';
    lastShotPath = null;
    _pendingShot = null;
    final ff = _freshFrame;
    _freshFrame = null;
    if (ff != null) unawaited(camera.discard(ff));
    notifyListeners();
    HapticFeedback.selectionClick();
    // 모든 탭 전면(셀카) 카메라
    unawaited(camera.switchTo(CameraLensDirection.front));
    // 가이드 탭은 백엔드(Qwen) 분석을 쓰므로 미리 연결 + GPU 깨우기
    if (t == AppTab.makeup) {
      unawaited(backend.connect());
      unawaited(backend.warmUp(reason: '(가이드 탭 진입)'));
      _startWarmUpTimer();
      _startFramingWatch();
    } else {
      _stopWarmUpTimer();
      _stopFramingWatch();
    }
    // 메이크업 촬영 탭에서만 도는 잘못된-제품 경고 (데모).
    if (t == AppTab.cosmetic) {
      _startAlertTimer();
    } else {
      _stopAlertTimer();
    }
    // 카메라 탭에 들어올 때마다 렌즈 이물질 검사.
    // 한 번만 하면 그 뒤에 묻은 물·지문은 영영 못 잡는다 — 실제로 그랬다.
    //
    // **안내는 검사를 기다리지 않는다.** 검사가 끝난 뒤에 말하게 했더니
    // 탭에 들어와서 3초 가까이 조용했다 — 앞이 안 보이는 사용자에게 그
    // 침묵은 "앱이 멈췄다" 다. 검사는 뒤에서 돌고, 더러우면 그때 끼어든다.
    if (t != AppTab.settings) {
      if (announce) _announceCurrent();
      unawaited(_runLensCheck(announce: false));
      return;
    }
    if (announce) _announceCurrent();
  }

  // ------------------------------------------------------- 데모: 잘못된 제품 경고
  /// 올라갈 때마다 화면이 붉게 세 번 깜빡인다 (main_shell 의 _AlertFlash).
  int alertPulse = 0;

  Timer? _alertTimer;

  static const _alertLine = '그건 마스카라예요. 입술에는 립스틱이나 틴트를 발라 주세요.';

  /// 화장품 인식 탭에 머무는 동안 15초마다 — 잘못된 화장품을 집었다는
  /// 시연 장면. 화면이 붉게 깜빡이고 같은 말을 읽는다. [demoScript] 전용.
  void _startAlertTimer() {
    if (!demoScript) return;
    _alertTimer ??= Timer.periodic(const Duration(seconds: 15), (_) {
      // 촬영 대기 화면에서만 — 분석·결과 위에 경고가 얹히면 무슨 일이
      // 벌어진 건지 알 수 없다.
      if (tab != AppTab.cosmetic || cosmeticStage != CosmeticStage.capture) {
        return;
      }
      alertPulse++;
      notifyListeners();
      HapticFeedback.heavyImpact();
      // 삐삐삐(2.4초)가 깜빡임과 함께 먼저 울리고, 말은 그 위로 들어온다.
      unawaited(ScanSfx.instance.alarm());
      voice.announce(_alertLine);
    });
  }

  void _stopAlertTimer() {
    _alertTimer?.cancel();
    _alertTimer = null;
  }

  /// "처음으로": 화장품 식별 대기 화면으로.
  Future<void> resetToStart() async {
    await goTab(AppTab.cosmetic);
  }

  Timer? _warmUpTimer;

  /// 가이드 탭에 머무는 동안 GPU 를 깨워 둔다 (첫 응답 지연 방지).
  ///
  /// 마지막 GPU 활동(warm-up **또는 실제 분석**)으로부터 5분이 지났을 때만 보낸다.
  /// 분석 자체가 GPU 를 최대로 돌리므로 그것도 warm 으로 친다.
  void _startWarmUpTimer() {
    _warmUpTimer?.cancel();
    _warmUpTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (tab != AppTab.makeup) {
        _stopWarmUpTimer();
        return;
      }
      if (asking) return; // 분석 중이면 GPU 를 뺏지 않는다
      final idle = DateTime.now().difference(backend.lastWarm);
      if (idle < BackendConfig.warmUpInterval) return; // 아직 따뜻함
      unawaited(backend.warmUp(reason: '(${idle.inMinutes}분 유휴)'));
    });
  }

  void _stopWarmUpTimer() {
    _warmUpTimer?.cancel();
    _warmUpTimer = null;
  }

  /// 촬영한 프레임이 더러운 렌즈로 찍힌 것인지. 결과를 로그에도 남긴다.
  Future<bool> _lensDirty(String path) async {
    try {
      final r = await classifier.checkLens(path);
      return r != null && r.isDirty;
    } catch (e) {
      debugPrint('[Lens] check failed: $e');
      return false;
    }
  }

  static const _dirtyLens = '카메라 렌즈에 이물질이 있어요. 렌즈를 닦고 다시 촬영해 주세요.';

  /// 카메라 탭에 들어올 때의 렌즈 이물질 검사. 더러우면 닦으라고 안내한다.
  /// 셔터를 누를 때도 그 프레임으로 한 번 더 본다 — 그쪽이 진짜 관문이다.
  Future<void> _runLensCheck({bool announce = true}) async {
    lensChecking = true;
    notifyListeners();
    try {
      // 카메라 프리뷰가 준비될 시간을 잠깐 준다 (탭 전환 직후)
      for (var i = 0; i < 12 && !camera.isReady; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      final shot = await camera.takePicture();
      if (shot == null) return;
      if (await _lensDirty(shot)) {
        HapticFeedback.mediumImpact();
        // announce — 진행 중인 탭 안내를 끊는다. 렌즈가 더러우면 그 안내는
        // 어차피 헛말이고, 이 말이 먼저 들려야 한다.
        await voice.announce('카메라 렌즈에 이물질이 있어요. 렌즈를 닦고 시작해 주세요.');
      }
    } finally {
      // 검사 자체는 0.5초면 끝나 알약이 깜박이고 사라진다. 최소 2.5초는
      // 띄운다 — 곁에서 보는 사람이 "무엇을 하는 중" 인지 읽을 시간이다.
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      lensChecking = false;
      notifyListeners();
      if (announce) _announceCurrent();
    }
  }

  /// 앱을 켜고 처음 탭에 들어왔을 때 한 번만 — 화면 사용법.
  bool _gestureGuideDone = false;

  String _gestureGuide() {
    if (_gestureGuideDone) return '';
    _gestureGuideDone = true;
    return '화면 사용법이에요. 한 번 두드리면 음성 인식, '
        '두 번 두드리면 촬영, 길게 누르면 앱을 종료해요. ';
  }

  void _announceCurrent() {
    switch (tab) {
      case AppTab.cosmetic:
        switch (cosmeticStage) {
          case CosmeticStage.capture:
            // 기능 설명은 이 한 문장이 전부다 — 길게 늘어놓으면 라이브로
            // 보고 있다는 핵심이 묻힌다.
            voice.announce('화장품 인식, 탭, 선택됨. ${_gestureGuide()}'
                '지금 라이브로 메이크업 도구들을 판단하고 있어요.');
          case CosmeticStage.analyzing:
            voice.announce('화장품을 분석 중이에요. 조금만 기다려 주세요.');
          case CosmeticStage.result:
            final p = prediction;
            if (p != null) voice.announce('제품을 찾았어요. ${p.product.spoken}');
        }
      case AppTab.makeup:
        switch (makeupStage) {
          case MakeupStage.capture:
            // 첫 진입에만 촬영 자세를 알려 준다. 재촬영 사유의 대부분(얼굴 못 찾음,
            // 너무 작음, 어두움)이 자세에서 갈리는데, 사용자는 화면을 못 보므로
            // 찍고 나서 되돌아오기 전에는 알 방법이 없다. 매번 읽으면 방해라 처음만.
            if (_makeupIntroDone) {
              voice.announce('메이크업 분석, 탭, 선택됨. ${_gestureGuide()}'
                  '얼굴을 찍고 궁금한 걸 물어보면 살펴봐 드려요. '
                  '준비되면 촬영하기 버튼을 눌러 주세요.');
            } else {
              _makeupIntroDone = true;
              voice.announce('메이크업 분석, 탭, 선택됨. ${_gestureGuide()}'
                  '얼굴을 화면 가운데에 맞춰 주세요. '
                  '팔꿈치를 굽혀서 얼굴에서 한 뼘 반쯤 떨어뜨리고 정면을 봐 주세요. '
                  '밝은 곳일수록 잘 보여요. '
                  '준비되면 촬영하기 버튼을 누르거나 화면을 두 번 두드려 주세요.');
            }
          case MakeupStage.question:
            voice.announce('궁금한 걸 질문해 보세요. '
                '음성으로 질문하기 버튼을 누른 뒤 편하게 말씀하세요. '
                '추천 질문을 골라도 됩니다.');
          case MakeupStage.analyzing:
            voice.announce('메이크업을 살펴보고 있어요. 얼굴을 그대로 두시면 곧 알려드릴게요.');
          case MakeupStage.result:
            if (lastSpokenResult.isNotEmpty) voice.announce(lastSpokenResult);
        }
      case AppTab.settings:
        // 개발자용 화면이지만, 어디로 들어왔는지는 알려 준다.
        voice.announce('설정, 탭, 선택됨. 개발자용 화면이에요. '
            '목소리와 말 속도를 바꿀 수 있어요. '
            '화장품 인식이나 메이크업 분석 탭으로 돌아가려면 하단 탭을 누르세요.');
    }
  }

  // ------------------------------------------------------------ cosmetic flow
  /// 촬영~결과 사이 로딩 화면을 최소한 이만큼은 보여준다.
  static const _minAnalyzing = Duration(milliseconds: 1200);

  Future<void> captureAndAnalyze() async {
    if (tab != AppTab.cosmetic || cosmeticStage != CosmeticStage.capture) return;
    if (countdown != null) return; // 이미 세고 있다
    if (!await _countThreeTwoOne()) return;
    // 세는 동안 화면이 바뀌었을 수 있다 — 다시 확인한다
    if (tab != AppTab.cosmetic || cosmeticStage != CosmeticStage.capture) return;
    cosmeticStage = CosmeticStage.analyzing;
    prediction = null;
    lastShotPath = null; // 새 사진이 오기 전까지 이전 사진을 띄우지 않는다
    notifyListeners();
    // 셔터 피드백 — 「접근성 명세」: 누르는 즉시 진동 1회와 셔터음, 이어서 안내
    await _shutterFeedback();

    final sw = Stopwatch()..start();
    final path = await camera.takePicture();
    lastShotPath = path;
    // **여기서 알려야 한다.** 이게 없으면 분석 화면이 다시 그려지지 않아,
    // 사진을 찍어 두고도 분석 내내 빈 판만 보였다.
    notifyListeners();

    // 더러운 렌즈로 찍은 사진은 인식해 봐야 엉뚱한 답이 나온다.
    // 같은 모델의 다른 머리라 추론 한 번(~100ms)이면 된다.
    if (path != null && await _lensDirty(path)) {
      cosmeticStage = CosmeticStage.capture;
      framingHint = _dirtyLens; // 같은 이유로 화면에도 남긴다
      notifyListeners();
      HapticFeedback.mediumImpact();
      await voice.announce(_dirtyLens);
      framingHint = '';
      notifyListeners();
      return;
    }

    CosmeticPrediction? result;
    if (path != null) {
      try {
        result = await classifier.classifyFile(path);
      } catch (e) {
        debugPrint('[Analyze] classify failed: $e');
      }
    }
    // 로딩 화면이 깜빡이고 지나가지 않게 최소 표시 시간만 채운다.
    // (고정 대기가 아니라 남은 시간만 — 인식이 느려지면 추가 대기는 0)
    final rest = _minAnalyzing - sw.elapsed;
    if (rest > Duration.zero) await Future<void>.delayed(rest);

    if (cosmeticStage != CosmeticStage.analyzing) return; // 중간에 탭 이동
    if (result == null) {
      cosmeticStage = CosmeticStage.capture;
      notifyListeners();
      await voice.announce('사진을 확인하지 못했어요. 다시 촬영하기 버튼을 눌러 주세요.');
      return;
    }
    // 신뢰도 낮음 → 재촬영 안내 후 촬영 화면 복귀
    if (result.label == 'unknown') {
      cosmeticStage = CosmeticStage.capture;
      notifyListeners();
      await voice.speak(result.product.spoken);
      return;
    }
    prediction = result;
    cosmeticStage = CosmeticStage.result;
    notifyListeners();
    HapticFeedback.mediumImpact();
    // 「접근성 명세」: 촬영은 되돌릴 수 없으므로 완료 후 다음 행동을 알려 준다
    await voice.speak('제품을 찾았어요. ${result.product.spoken} '
        '저장하기 또는 다시 촬영하기 버튼을 고를 수 있어요.');
  }

  /// 셔터 피드백. 진동 → 셔터음 → 안내 순서는 「접근성 명세」가 정한 것이다.
  Future<void> _shutterFeedback() async {
    HapticFeedback.heavyImpact();
    await SystemSound.play(SystemSoundType.click);
    unawaited(voice.speak('촬영했습니다.'));
  }

  /// 결과 카드의 "다시 들려주기" — 찾은 제품을 한 번 더 읽어 준다
  Future<void> speakProduct() async {
    final p = prediction;
    if (p == null) return;
    await voice.announce(p.product.spoken);
  }

  // ------------------------------------------------------------ 촬영 도구


  /// 화장품 결과 → 촬영 화면으로 되돌린다 ("다시 촬영하기")
  Future<void> retakeCosmetic() async {
    cosmeticStage = CosmeticStage.capture;
    prediction = null;
    lastShotPath = null;
    notifyListeners();
    await voice.announce('다시 촬영할게요. 화장품을 카메라 앞에 들어 주세요.');
  }

  // ------------------------------------------------------------ 화면 제스처
  /// 한 번 두드리기 — 음성 인식 시작 (모든 화면).
  /// 평소에는 마이크를 끄고 있다가, 두드린 순간부터 한 발화만 듣는다.
  Future<void> startListening() async {
    HapticFeedback.mediumImpact(); // 듣기 시작을 촉각으로 알림
    await SystemSound.play(SystemSoundType.click);
    await voice.startListening();
    notifyListeners();
  }

  Future<void> captureAndAsk() async {
    if (tab != AppTab.makeup || asking) return;
    if (makeupStage != MakeupStage.capture) return;
    if (countdown != null) return; // 이미 세고 있다
    if (!await _countThreeTwoOne()) return;
    if (tab != AppTab.makeup || makeupStage != MakeupStage.capture) return;

    // 찍기 전에 프레이밍부터 본다.
    // 이걸 안 하면 찍고 20초 기다린 끝에야 "다시 찍어 주세요" 를 듣는다.
    final shot = await _approvedShot();
    if (shot == null) return;

    await _shutterFeedback();

    // 프레이밍 확인에 쓴 프레임이 곧 촬영본이다 — 방금 "좋다" 고 판정받은
    // 바로 그 장면이고, 카메라를 두 번 누르지 않아도 된다.
    _pendingShot = shot;
    lastShotPath = shot;
    framingHint = ''; // 촬영은 끝났다 — 교정 안내를 남겨 두지 않는다
    // 셔터로 찍으면 항상 질문 화면으로 간다. 한때 직전 질문을 재사용해
    // 건너뛰게 했더니, 다른 걸 물으려고 재촬영한 사용자가 "베이스를 골랐는데
    // 입술을 분석한다" 를 겪었다. 질문을 고를 기회는 매번 있어야 한다.
    // (촬영 화면에서 음성으로 바로 질문하는 지름길은 그대로다 — 그건 ask() 경로)
    makeupStage = MakeupStage.question;
    // **지난 발화를 지우고 시작한다.** 안 지우면 앞서 한 말이 화면에
    // 그대로 떠 있고, 이어서 들어오는 부분 인식과 섞여 **예전 질문이
    // 그대로 서버로 간다.**
    _clearHeard();
    notifyListeners();
    // **안내를 끝까지 읽는다.** 여기서 마이크를 스스로 열면 그 순간
    // 안내가 잘린다 — 무엇을 해야 하는지 듣지 못한 채 마이크만 열려 있다.
    // 듣기는 사용자가 화면을 눌렀을 때만 시작한다 ([askByVoice]).
    await voice.announce('화면을 눌러 궁금한 걸 말씀해 주세요.');
  }

  /// 촬영해 둔 사진. 질문 단계에서 분석으로 넘어갈 때 쓴다.
  String? _pendingShot;

  /// 메이크업 플로우를 촬영 단계로 되돌린다
  /// ("다시 촬영하기" / "취소하고 다시 촬영하기")
  Future<void> retakeMakeup({bool announce = true}) async {
    makeupStage = MakeupStage.capture;
    analysisItems = const [];
    analysisProgress = 0;
    lastHeard = ''; // 새 촬영 = 새 질문. 묵은 질문이 화면에 남지 않게 지운다
    lastShotPath = null;
    _pendingShot = null;
    final ff = _freshFrame;
    _freshFrame = null;
    if (ff != null) unawaited(camera.discard(ff));
    notifyListeners();
    if (announce) await voice.announce('다시 촬영할게요. 얼굴을 화면 가운데에 맞춰 주세요.');
  }

  /// 결과를 한 번 더 읽어 준다 ("다시 들려주기")
  Future<void> repeatResult() async {
    if (lastSpokenResult.isEmpty) return;
    await voice.announce(lastSpokenResult);
  }

  /// 질문 화면의 마이크 버튼 — 화면 두드리기와 같은 피드백을 준다.
  ///
  /// 「접근성 명세」: 녹음 시작과 종료를 서로 다른 진동·소리로 구분한다.
  /// 질문 화면에서 마이크를 눌러 둔 시간. 이 동안에는 세션이 꺼져도 다시 연다.
  DateTime? _keepMicUntil;
  bool _reopening = false;

  /// 다시 연 횟수. **무한히 열지 않는다** — 마이크가 실제로 죽었거나 권한이
  /// 없으면 세션이 즉시 끝나는데, 그때 계속 다시 열면 표시가 깜빡이기만 하고
  /// 사용자는 무엇이 잘못됐는지 알 수 없다.
  int _reopens = 0;
  static const _maxReopens = 4;

  /// 마이크를 눌러 둔 상태인지. 화면 표시는 이 값을 쓴다 —
  /// 인식기가 잠깐씩 꺼졌다 켜지는 걸 그대로 보여 주면 파형이 깜빡인다.
  bool get micOpen => _keepMicUntil != null;

  /// 안드로이드 인식기는 **짧은 침묵에도 스스로 꺼진다.** 말하려고 숨 고르는
  /// 사이에 끊기면 사용자에게는 "눌렀는데 금방 끝난다" 로 보인다.
  /// 아직 아무 말도 못 들었고 질문 화면에 있으면 조용히 다시 연다.
  void _maybeReopenMic() {
    final until = _keepMicUntil;
    if (until == null || _reopening) return;
    if (tab != AppTab.makeup || makeupStage != MakeupStage.question) {
      _closeMicWindow();
      return;
    }
    if (voice.isListening || voice.partialText.isNotEmpty) return;
    if (DateTime.now().isAfter(until) || _reopens >= _maxReopens) {
      final gaveUp = _reopens >= _maxReopens;
      _closeMicWindow();
      // 조용히 포기하면 죽은 마이크에 대고 계속 말하게 된다.
      if (gaveUp && voice.partialText.isEmpty) {
        unawaited(voice.speak('잘 못 들었어요. 다시 눌러서 말씀해 주세요.'));
      }
      return;
    }
    _reopening = true;
    _reopens++;
    Timer(const Duration(milliseconds: 300), () async {
      _reopening = false;
      if (_keepMicUntil == null) return;
      if (tab != AppTab.makeup || makeupStage != MakeupStage.question) return;
      if (voice.isListening || voice.partialText.isNotEmpty) return;
      await voice.startListening();
    });
  }

  void _closeMicWindow() {
    if (_keepMicUntil == null) return;
    _keepMicUntil = null;
    _reopens = 0;
    voice.suppressMissedPrompt = false;
    notifyListeners();
  }

  Future<void> askByVoice() async {
    if (tab != AppTab.makeup || makeupStage != MakeupStage.question) return;
    // 다시 물으려고 누른 것이다 — 앞서 받아 적은 말은 지우고 새로 듣는다.
    _clearHeard();
    // 15초 동안은 끊겨도 다시 연다. 그동안 "못 들었어요" 는 말하지 않는다 —
    // 다시 열 때마다 끼어들면 정작 말을 못 한다.
    _keepMicUntil = DateTime.now().add(const Duration(seconds: 15));
    _reopens = 0;
    voice.suppressMissedPrompt = true;
    notifyListeners();
    // **안내를 기다리지 않는다.** announce 가 돌려주는 Future 는 TTS 엔진이
    // 완료를 알려 줘야 끝나는데, 다음 안내가 stop() 을 부르면 그 통보가
    // 오지 않는다. 그걸 await 하면 아래 듣기 시작이 통째로 실행되지 않는다 —
    // "버튼을 눌러도 안 듣는다" 가 정확히 이 경로였다.
    //
    // 듣기 시작은 진동 + 짧은 소리로 알린다 ([startListening]). 말로 알리면
    // 그 말꼬리가 마이크에 들어가 첫 단어를 먹기도 한다.
    await startListening();
  }

  // ------------------------------------------------------- 실시간 프레이밍 안내
  /// 가이드 탭에 있는 동안 주기적으로 자세를 봐 준다.
  ///
  /// 누르고 나서 알려주면 이미 한 박자 늦다. 미리 잡아 두면 누르는 순간엔 이미
  /// 자세가 맞아 있다. 서버 판정이 GPU 를 안 쓰고 수십 ms 라 부담이 없다.
  ///
  /// **바뀔 때만 말한다.** 같은 말을 3초마다 반복하면 앱이 아니라 잔소리가 된다.
  static const framingPollInterval = Duration(seconds: 3);

  Timer? _framingTimer;

  /// 프레이밍 감시가 마지막으로 본 프레임과 그 시각.
  /// 감시는 말하는 중·듣는 중에는 쉬기 때문에, 이 프레임은 생각보다
  /// 오래된 것일 수 있다 — 나이를 보고 쓸지 말지 정한다.
  String? _freshFrame;
  DateTime _freshFrameAt = DateTime.fromMillisecondsSinceEpoch(0);
  String _lastFramingCode = '';
  bool _framingBusy = false;

  void _startFramingWatch() {
    _framingTimer?.cancel();
    _lastFramingCode = '';
    _framingTimer = Timer.periodic(framingPollInterval, (_) => _pollFraming());
  }

  void _stopFramingWatch() {
    _framingTimer?.cancel();
    _framingTimer = null;
    _lastFramingCode = '';
    if (framingHint.isNotEmpty) {
      framingHint = '';
      notifyListeners();
    }
  }

  Future<void> _pollFraming() async {
    // 말하는 중·듣는 중·분석 중에는 끼어들지 않는다
    // 이미 찍은 뒤(질문·분석·결과)에는 보지 않는다 — 3초마다 프레임을 찍으며
    // "얼굴이 안 보여요" 를 외치는 건, 사용자에겐 계속 촬영하려 드는 걸로 들린다.
    if (_framingBusy ||
        tab != AppTab.makeup ||
        makeupStage != MakeupStage.capture ||
        asking ||
        lensChecking ||
        voice.isSpeaking ||
        voice.isListening) {
      return;
    }
    _framingBusy = true;
    try {
      final shot = await camera.takePicture(transient: true);
      if (shot == null) return;
      final f = await backend.checkFraming(shot);
      // 마지막 확인 프레임은 남겨 둔다 — 촬영 화면에서 바로 음성 질문이 오면
      // 이 프레임이 "그때 카메라에 보이던 얼굴" 이다. 새 프레임이 이전 것을 민다.
      final prev = _freshFrame;
      _freshFrame = shot;
      _freshFrameAt = DateTime.now();
      if (prev != null) unawaited(camera.discard(prev));
      if (f == null || tab != AppTab.makeup) return;

      framingHint = f.ok ? '' : f.guidance;
      notifyListeners();

      if (f.code == _lastFramingCode) return; // 같은 상태면 다시 말하지 않는다
      final wasBad = _lastFramingCode.isNotEmpty && _lastFramingCode != 'ok';
      _lastFramingCode = f.code;
      if (f.ok) {
        // 고쳐졌을 때만 알려 준다. 처음부터 괜찮았으면 아무 말 안 한다.
        if (wasBad) await voice.speak('좋아요. 이제 두 번 두드리면 찍어요.');
      } else {
        await voice.speak(f.guidance);
      }
    } finally {
      _framingBusy = false;
    }
  }

  /// 지금 화면이 쓸 만한지 서버에 물어보고, 아니면 고칠 방향을 말해 준다.
  ///
  /// **촬영 버튼을 누른 순간에만** 한 번 본다. 카메라에 얼굴이 들어올 때마다
  /// 말하면 가만히 있어도 계속 떠드는 앱이 된다.
  ///
  /// 서버 판정은 GPU 를 쓰지 않아 수십 ms 다. 못 쓸 사진이면 촬영을 접고 고칠
  /// 방향을 말해 준다 — 3초 세고 찍어서 20초 기다린 끝에 재촬영을 듣는 것보다
  /// 훨씬 빠르다. 대신 **촬영이 취소됐다는 걸 반드시 알려야 한다.** 앞이 보이지
  /// 않으면 결과를 기다리는 중인지 취소된 건지 구분할 방법이 없다.
  ///
  /// 서버가 없거나 카메라가 안 되면 판단하지 않고 그냥 찍는다.
  /// 반환값은 "촬영을 진행할지".
  /// 찍어서 프레이밍을 확인하고, 쓸 만하면 **그 프레임을** 돌려준다.
  /// 못 쓸 사진이면 고칠 방향을 말하고 null — 촬영은 없던 일이 된다.
  Future<String?> _approvedShot() async {
    final shot = await camera.takePicture(transient: true);
    if (shot == null) return null; // 카메라 문제 — 찍을 수 없다
    // 렌즈가 더러우면 서버까지 갈 것도 없다 — 20초 기다린 끝에 쓰레기를 듣는다
    if (await _lensDirty(shot)) {
      unawaited(camera.discard(shot));
      HapticFeedback.mediumImpact();
      // **화면에도 띄운다.** 소리로만 알리면, 보고 있는 사람에게는 셔터를
      // 눌렀는데 아무 일도 안 일어난 것처럼 보인다 — 실제로 "안 넘어간다" 는
      // 신고가 이 경로였다.
      framingHint = _dirtyLens;
      notifyListeners();
      await voice.announce(_dirtyLens);
      framingHint = '';
      notifyListeners();
      return null;
    }
    // **4초 상한.** 프레이밍 확인은 잘 되면 1초 안에 온다. 서버가 안 닿는
    // 상태(와이파이 꺼짐, VPN 끊김)에서는 탐색 → 재시도로 16초까지 늘어질
    // 수 있는데, 그동안 셔터 소리만 나고 화면이 안 넘어가서 "찍었는데
    // 안 넘어간다" 가 됐다. 판정은 도우미지 관문이 아니다 — 늦으면 버린다.
    final f = await backend
        .checkFraming(shot)
        .timeout(const Duration(seconds: 4), onTimeout: () => null);
    if (f == null) return shot; // 서버 없음/지연 — 판정 없이 이 프레임으로 간다
    if (f.ok) return shot;

    framingHint = f.guidance;
    notifyListeners();
    // 입술만 작은 건 베이스 확인에는 쓸 수 있다. 알려만 주고 진행한다.
    if (f.code == 'lip_small') {
      await voice.speak(f.guidance);
      framingHint = '';
      notifyListeners();
      return shot;
    }
    unawaited(camera.discard(shot));
    await voice.announce('${f.guidance} 준비되면 다시 두 번 두드려 주세요.');
    framingHint = '';
    notifyListeners();
    return null;
  }

  /// 프레이밍 교정 안내 (화면 표시용. 비어 있으면 표시 안 함)
  String framingHint = '';

  /// 1.5초 길게 누르기 — 앱 종료 (모든 화면)
  Future<void> exitApp() async {
    debugPrint('[Gesture] 앱 종료');
    await voice.announce('앱을 종료할게요.');
    await voice.stopListening();
    await LogService.instance.close();
    await SystemNavigator.pop();
  }

  // ------------------------------------------------------------ guide chat
  bool asking = false;

  /// **데모 대본 모드.** 켜면 메이크업 분석이 서버를 부르지 않고, 진행바가
  /// 다 찬 뒤 항상 아래의 고정 결과(오른쪽 볼 + 입술)를 낸다. 화장품 인식
  /// 탭의 15초 경고(마스카라)도 이 스위치에 묶여 있다.
  ///
  /// **기본은 꺼짐 — 실제 서버 분석을 쓴다.** 시연장에서 네트워크가
  /// 불안할 때만 잠깐 켠다. 켜 두고 배포하면 어떤 질문에도 같은 답이
  /// 나가므로, 켠 채로 커밋하지 마라.
  static const demoScript = false;

  static const _demoItems = [
    AnalysisItem(
      region: '오른쪽 볼',
      state: '오른쪽 볼에 파우더가 고르게 펴지지 않고 뭉쳐 있어요.',
      action: '퍼프로 가볍게 두드려 뭉친 파우더를 펴 주세요.',
      type: 'base',
      zone: '오른쪽볼',
    ),
    AnalysisItem(
      region: '입술',
      state: '입술 오른쪽 라인 밖으로 립이 살짝 번져 있어요.',
      action: '면봉으로 바깥 라인을 따라 정리해 주세요.',
      type: 'lip',
      zone: '입술',
    ),
  ];

  static const _demoReply = '오른쪽 볼에 파우더가 고르게 펴지지 않고 뭉쳐 있어요. '
      '퍼프로 가볍게 두드려 뭉친 파우더를 펴 주세요. '
      '그리고 입술 오른쪽 라인 밖으로 립이 살짝 번져 있어요. '
      '면봉으로 바깥 라인을 따라 정리해 주세요.';

  /// 메이크업 질문: 촬영해 둔 사진 + 질문을 백엔드로 보내고 결과를 읽어 준다.
  /// 서버가 없으면 로컬 canned 응답으로 폴백.
  /// 분석 요청 세대. 탭을 옮기면 올라가고, 뒤늦게 온 응답은 버려진다.
  int _askGen = 0;

  Future<void> ask(String text) async {
    if (asking) return;
    final gen = ++_askGen;
    asking = true;
    lastHeard = text;
    // 어떤 사진으로 분석하나 — "지금" 에 가장 가까운 것.
    //   1. 방금 셔터로 찍은 사진 (한 번 쓰면 소비 — 다음 질문에 재탕하지 않는다)
    //   2. 프레이밍 감시가 4초 안에 본 프레임 (감시는 말하는 중엔 쉬어서,
    //      그보다 오래된 프레임은 "전에 찍은 사진" 이다. 실제로 그게 들어갔다)
    //   3. 지금 새로 찍는다
    var shot = _pendingShot;
    _pendingShot = null;
    if (shot == null &&
        _freshFrame != null &&
        DateTime.now().difference(_freshFrameAt) <
            const Duration(seconds: 4)) {
      shot = _freshFrame;
      _freshFrame = null; // 소비했다
    }
    shot ??= await camera.takePicture();
    lastShotPath = shot;
    makeupStage = MakeupStage.analyzing;
    analysisProgress = 0;
    analysisItems = const [];
    chat.add(ChatMessage(text: text, fromUser: true));
    notifyListeners();
    // 서버 응답이 올 때까지 STT 완전 차단 (다른 말 안 받음)
    voice.muted = true;

    // 「접근성 명세」: 끝나면 인식된 문장을 그대로 다시 들려준다.
    // 잘못 알아들었으면 사용자가 지금 알아채야 20초를 버리지 않는다.
    //
    // 뒤에 **무엇을 보고 있는지** 바로 붙인다. 예전에는 "살펴보고 있어요" 라고만
    // 하고 부위 이름은 30% 지점에서야 나왔는데, 그때까지 화면도 소리도 있는데
    // 말만 없어서 멈춘 것처럼 느껴졌다. 화면 글귀와 같은 문장이다.
    await voice.announce('$text, 라고 들었어요. ${_focusLine(text)}');

    _startProgress(text);
    String? reply; // null = 실패
    List<AnalysisItem> items = const [];
    Duration? latency;
    final sw = Stopwatch()..start();
    if (demoScript) {
      // ── 데모 대본 ── 서버를 부르지 않는다. 진행바(5초)가 다 차면
      // 무조건 아래의 고정 결과로 넘어간다 — 시연 중에 서버·네트워크가
      // 어떤 상태든 흐름이 끊기지 않아야 한다.
      reply = _demoReply;
      items = _demoItems;
      voice.muted = false;
    } else {
    try {
      // 답을 기다리는 20~30초 사이 핫스팟이 순단되면 연결이 끊긴다.
      // 서버는 답을 다 만들어 놓고 죽은 소켓에 보낸다 (18:41 로그로 확인) —
      // 끊긴 요청은 새로 접속해서 딱 한 번 다시 보낸다.
      for (var attempt = 0; attempt < 2; attempt++) {
        if (!await backend.connect()) {
          debugPrint('[Makeup] backend unavailable (attempt $attempt)');
          break;
        }
        try {
          final r = await backend.analyze(text, imagePath: shot);
          if (r.message.isNotEmpty) {
            reply = r.message;
            items = r.items;
            latency = sw.elapsed;
          }
          break;
        } catch (e) {
          debugPrint('[Makeup] backend analyze failed (attempt $attempt): $e');
          // 연결 단절만 재시도한다. 타임아웃(70초)은 이미 충분히 기다린 것이다.
          if (attempt == 0 && e is StateError) {
            await Future<void>.delayed(const Duration(seconds: 2));
            continue;
          }
          break;
        }
      }
    } finally {
      voice.muted = false; // 응답 후 다시 듣기 시작
      // **여기서 진행 타이머를 끄지 않는다.** 끄면 막대가 그 자리에서
      // 얼어붙고, 아래에서 5초를 채우는 동안 30% 에 멈춰 있게 된다 —
      // "다 안 됐는데 넘어간다" 가 이것이었다. 막대가 100% 를 찍은 뒤에 끈다.
    }
    }
    // 그 사이 탭을 옮겼으면 이 결과는 버린다 — 다른 화면에서 결과가
    // 튀어나오거나, 돌아왔을 때 중간(결과)부터 시작하게 된다.
    if (gen != _askGen) {
      _stopProgress();
      asking = false;
      return;
    }

    // 서버가 없으면 실패했다고 말한다. 예전에는 하드코딩된 문장을 대신 읽어 줬는데,
    // 얼굴을 보지도 않은 답이 매번 똑같이 나오니 "캐시된 답" 처럼 들렸다 —
    // 앞이 보이지 않는 사용자에게 지어낸 분석은 오답보다 나쁘다.
    if (reply == null) {
      _stopProgress();
      makeupStage = MakeupStage.capture;
      asking = false;
      notifyListeners();
      await voice.announce('서버에 연결하지 못했어요. 잠시 뒤에 다시 시도해 주세요.');
      return;
    }
    // **진행바가 다 찰 때까지 기다린다.** 눈금이 30%에서 갑자기 결과로
    // 튀면, 방금까지 보던 것이 무엇이었는지 알 수 없다.
    // **막대가 다 찰 때까지 기다린다.** 타이머는 아직 돌고 있어서 그동안
    // 눈금이 계속 올라간다. 5초가 지나 이미 가득 찼으면 곧바로 지나간다.
    final clock = _analysisClock;
    if (clock != null && clock.elapsed < _progressGuess) {
      await Future<void>.delayed(_progressGuess - clock.elapsed);
      if (tab != AppTab.makeup || makeupStage != MakeupStage.analyzing) return;
    }
    _stopProgress();
    // 100% 를 한 번 그리고 넘어간다. 98% 에서 사라지면 다 안 됐는데
    // 넘어간 것으로 보인다.
    analysisProgress = 1;
    notifyListeners();
    await Future<void>.delayed(const Duration(milliseconds: 320));
    if (tab != AppTab.makeup || makeupStage != MakeupStage.analyzing) return;
    chat.add(ChatMessage(text: reply, fromUser: false, latency: latency));
    analysisItems = items;
    lastSpokenResult = reply.replaceAll('\n', ' ');
    analysisProgress = 1;
    makeupStage = MakeupStage.result;
    asking = false;
    notifyListeners();
    HapticFeedback.mediumImpact();
    await voice.announce(lastSpokenResult);
  }

  // ------------------------------------------------------- 분석 진행률
  /// 「접근성 명세」: 진행률은 10% 단위로만 안내해 과도한 낭독을 막는다.
  ///
  /// 서버가 진행률을 주지 않으므로 경과 시간으로 추정한다. 정확한 수치가 아니라
  /// "멈추지 않았다" 를 알리는 용도다 — 그래서 90%에서 멈춰 기다린다.
  /// 진행바가 100% 까지 차는 데 걸리는 시간.
  ///
  /// 서버는 남은 시간을 알려 주지 않는다. 그래서 **눈금은 예상이 아니라
  /// 약속이다** — 5초 동안 채우고, 그 안에 답이 와도 5초는 채운 뒤에
  /// 결과로 넘어간다. 5초가 지나도 안 오면 가득 찬 채로 기다린다.
  /// 눈금이 중간에서 멈췄다 갑자기 끝나는 것보다 이쪽이 덜 불안하다.
  static const _progressGuess = Duration(seconds: 5);
  Timer? _progressTimer;

  /// 이번 분석이 시작된 시각. 결과가 빨리 와도 진행바를 다 채운 뒤에
  /// 넘어가려고 잰다.
  Stopwatch? _analysisClock;
  int _lastSpokenDecile = 0;

  /// 질문으로 어디를 보는지 짚는다. 서버 라우터와 같은 기준(입술 → 립 경로).
  static String _focusOf(String question) {
    final q = question.replaceAll(' ', '');
    if (q.contains('입술') || q.contains('립')) return '입술';
    if (q.contains('베이스') || q.contains('피부') || q.contains('파운')) return '피부';
    if (q.contains('눈')) return '눈가';
    return '메이크업';
  }

  /// 무엇을 보고 있는지 한 문장. 화면 글귀([analysisLine])와 같은 말이다 —
  /// 보이는 것과 들리는 것이 다르면 옆 사람이 읽어 줄 때 어긋난다.
  String _focusLine(String question) {
    final f = _focusOf(question);
    return '$f${_eulReul(f)} 분석 중이에요.';
  }

  /// 기다리는 동안 들려줄 말. 숫자 대신 무엇을 보고 있는지 말한다 —
  /// "30퍼센트" 는 앞이 보이지 않는 사용자에게 아무 그림도 안 그려 준다.
  ///
  /// 시작할 때 이미 [_focusLine] 을 들려줬으므로 같은 문장으로 시작하지
  /// 않는다. 대신 **부위 이름은 계속 끼워 둔다** — 그래야 기다리는 내내
  /// 무엇을 보고 있는지가 남는다.
  List<String> _progressLines(String question) {
    final f = _focusOf(question);
    return [
      '$f${_eulReul(f)} 꼼꼼히 보는 중이에요.',
      '$f${_eulReul(f)} 아직 보고 있어요. 조금만요.',
      '거의 다 됐어요.',
    ];
  }

  void _startProgress(String question) {
    _lastSpokenDecile = 0;
    final lines = _progressLines(question);
    final sw = Stopwatch()..start();
    _analysisClock = sw;
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(const Duration(milliseconds: 400), (_) {
      final t = sw.elapsed.inMilliseconds / _progressGuess.inMilliseconds;
      analysisProgress = t.clamp(0.0, 1.0);
      notifyListeners();
      final decile = (analysisProgress * 10).floor();
      if (decile > _lastSpokenDecile && decile % 3 == 0) {
        // 30% · 60% · 90% 지점에서 한 마디씩 — 전부 읽으면 시끄럽다
        _lastSpokenDecile = decile;
        HapticFeedback.selectionClick();
        final line = lines[(decile ~/ 3 - 1).clamp(0, lines.length - 1)];
        if (!voice.isSpeaking) voice.speak(line);
      }
    });
  }

  void _stopProgress() {
    _progressTimer?.cancel();
    _progressTimer = null;
  }

  /// 메이크업 탭에서 서버로 보낼 발화인지 판단.
  ///
  /// 주변 대화나 혼잣말이 그대로 질문으로 전송되는 것을 막기 위해,
  /// **질문형 어미**나 **명시적 트리거 단어**가 있을 때만 통과시킨다.
  /// (공백 제거된 문자열을 받는다)
  /// 이동 명령 판별. 질문과 헷갈리지 않게 두 단계로 본다.
  ///  · "설정 탭으로 가줘" 처럼 이동 표현이 있으면 길이와 무관하게 이동
  ///  · 이동 표현이 없으면 "설정" 같은 짧은 한 마디(6자 이하, 질문형 아님)만
  /// (공백 제거된 문자열을 받는다)
  static AppTab? navTarget(String t) {
    const goWords = [
      '이동', '가줘', '가자', '갈래', '탭', '열어', '켜줘', '바꿔', '로가', '으로가',
    ];
    final hasGo = goWords.any(t.contains);
    if (!hasGo && (t.length > 6 || looksLikeQuestion(t))) return null;
    if (t.contains('설정') || t.contains('세팅')) return AppTab.settings;
    if (t.contains('화장품') || t.contains('제품')) return AppTab.cosmetic;
    if (t.contains('메이크업') || t.contains('가이드')) return AppTab.makeup;
    return null;
  }

  static bool looksLikeQuestion(String t) {
    if (t.contains('?')) return true;

    // 명시적 트리거 — "봐줘", "확인해줘", "촬영" 등
    const triggers = [
      '봐줘', '봐주', '봐도', '봐봐', '보여줘',
      '확인', '점검', '체크', '알려줘', '알려주', '말해줘',
      '촬영', '찍어', '사진',
    ];
    for (final k in triggers) {
      if (t.contains(k)) return true;
    }

    // 결함을 짚는 말 — "입술 번졌어" 처럼 서술형이어도 확인 요청이다.
    // 화장 상황에서만 쓰는 어휘라 주변 대화에 섞일 일이 거의 없다.
    const defectWords = [
      '번졌', '번진', '번짐', '묻었', '묻은', '삐져', '삐졌',
      '지저분', '뭉쳤', '뭉친', '들떴', '들뜬', '갈라졌', '갈라진',
      '뜬거', '떴어', '안발렸', '덜발렸', '비었',
    ];
    for (final k in defectWords) {
      if (t.contains(k)) return true;
    }

    // 질문형 어미 — "어때", "괜찮아", "이상해", "~할까", "~인가요"
    const questionForms = [
      '어때', '어떄', '어떻', '어떤', '어디', '언제', '얼마',
      '괜찮', '이상해', '이상한', '이상하',
      '뭐야', '뭔가', '무엇', '뭐가',
      '맞아', '맞나', '맞는', '됐어', '됐나', '있어', '있나',
      '까요', '을까', 'ㄹ까', '나요', '가요', '인가', '건가', '는지',
    ];
    for (final k in questionForms) {
      if (t.contains(k)) return true;
    }
    return false;
  }



  // ------------------------------------------------------------ voice routing
  /// 인식된 문장으로 화면 전환/동작 수행. 화면의 버튼과 동일한 경로를 탑니다.
  Future<void> handleVoice(String text) async {
    final t = text.replaceAll(' ', '');
    debugPrint('[Voice] ${text.length}자 tab=$tab');

    // 부분 인식으로 이미 실행한 발화의 최종 결과는 무시 (중복 실행 방지)
    if (DateTime.now().isBefore(_squelchFinalUntil)) {
      _lastPartialFired = '';
      return;
    }

    if (!started) {
      if (t.contains('시작') || t.contains('스타트') || t.contains('뷰티톡') ||
          t.contains('열어') || t.contains('시자') || t.contains('사작')) {
        await start();
      }
      return;
    }

    // 가이드 탭에서는 짧은 발화만 이동 명령으로 취급 (긴 문장 = 서버 질문)
    final inQuestion =
        tab == AppTab.makeup && makeupStage == MakeupStage.question;

    // 인식 후보 전부 + 자모 유사도로 판정 (오인식 교정)
    final cands = voice.candidates.isEmpty ? [text] : voice.candidates;
    bool has(String kw) => CommandMatcher.matchAny(cands, kw);

    // 전역 이동 — 부분 인식(_onVoicePartial)과 같은 판별을 쓴다
    AppTab? navTo;
    for (final c in cands) {
      navTo = navTarget(c.replaceAll(' ', ''));
      if (navTo != null) break;
    }
    if (navTo != null) {
      if (navTo != tab) return goTab(navTo);
      return;
    }
    if (t.contains('처음') || t.contains('홈으로')) {
      return resetToStart();
    }
    if (t.contains('조용') || t.contains('그만') || t.contains('멈춰')) {
      await voice.stopSpeaking();
      return;
    }

    // 탭별 명령
    switch (tab) {
      case AppTab.cosmetic:
        if (cosmeticStage == CosmeticStage.capture &&
            (has('촬영') || has('사진') || has('인식') || has('확인') || t.contains('찍'))) {
          return captureAndAnalyze();
        }
        if (cosmeticStage == CosmeticStage.result &&
            (t.contains('다시') || t.contains('한번더') || t.contains('설명'))) {
          final p = prediction;
          if (t.contains('설명') && p != null) return voice.announce(p.product.spoken);
          return resetToStart();
        }
      case AppTab.settings:
        return; // 설정 탭은 안내 화면 — 별도 명령 없음
      case AppTab.makeup:
        if (!inQuestion && !looksLikeQuestion(t)) {
          LogService.instance.writeSpeech('무시(질문 아님) "$text"');
          debugPrint('[Makeup] 무시(질문 아님): ${text.length}자');
          return;
        }
        return ask(text);
    }

    // 알아듣지 못한 경우: 가이드 탭이 아니면 짧게 안내
    if (t.length >= 2) {
      await voice.speak('화장품 인식, 메이크업 분석, 설정 중에 말해 주세요.');
    }
  }
}
