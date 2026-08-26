import 'dart:async';

import 'package:camera/camera.dart' show CameraLensDirection;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import 'app_state.dart';
import 'ml/cosmetic_classifier.dart';
import 'screens/entry_screen.dart';
import 'screens/intro_screen.dart';
import 'screens/main_shell.dart';
import 'services/backend_service.dart';
import 'services/camera_service.dart';
import 'services/log_service.dart';
import 'services/stt_diagnostics.dart';
import 'services/voice_service.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  // 잡히지 않은 예외까지 파일 로그에 남기도록 zone 안에서 실행
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    await LogService.instance.init();
    debugPrint('[Log] file = ${LogService.instance.path}');
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
    ));
    runApp(const BeautyTalkApp());
  }, (error, stack) {
    LogService.instance.write('!! Zone error: $error\n$stack');
    LogService.instance.flush();
    debugPrint('!! Zone error: $error');
  });
}

class BeautyTalkApp extends StatelessWidget {
  const BeautyTalkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BeautyTalk',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      home: const _Root(),
    );
  }
}

class _Root extends StatefulWidget {
  const _Root();

  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> with WidgetsBindingObserver {
  AppState? _state;

  /// 인트로가 끝났는지. 서비스 준비와 별개로 흘러간다 —
  /// 「인트로 접근성 규칙」이 "최소 노출 시간은 두지 않는다" 고 못박았기 때문에,
  /// 두드리면 준비가 덜 끝났어도 진입 화면으로 넘어가야 한다.
  bool _introDone = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _boot();
  }

  Future<void> _boot() async {
    // 권한
    await [Permission.camera, Permission.microphone].request();

    // 서비스 초기화 (병렬)
    final results = await Future.wait([
      VoiceService.instance.init(),
      CameraService.instance.init(lens: CameraLensDirection.front),
      CosmeticClassifierFactory.create(),
    ]);
    final classifier = results[2] as CosmeticClassifier;

    final s = AppState(classifier: classifier)..bindVoice();
    if (!mounted) return;
    setState(() => _state = s);
    // 온디바이스 STT 언어팩 상태 점검 (없으면 한국어 모델 다운로드 요청)
    unawaited(SttDiagnostics.instance.reportAndEnsureKorean());

    // 백엔드(Tailscale 내부 주소) 탐색 + GPU 깨우기 — 앱 켜는 순간 1회
    unawaited(BackendService.instance.discover().then((ok) {
      if (ok) BackendService.instance.warmUp(reason: '(앱 시작)');
    }));
  }

  /// 「인트로 접근성 규칙」 — 0.2초에 시작하는 안내.
  /// 건너뛰어도 끊지 않고 진입 화면에서 이어서 재생한다.
  void _speakIntro() {
    unawaited(VoiceService.instance
        .announce('뷰티톡. ${EntryScreen.hint}'));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final cam = CameraService.instance;
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      cam.pause();
      VoiceService.instance.stopListening();
      LogService.instance.flush(); // 백그라운드 진입 전 로그 저장
    } else if (state == AppLifecycleState.resumed) {
      cam.resume();
      // 복귀했다고 마이크를 자동으로 켜지 않는다 — 두드릴 때만 듣는다
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _state?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _state;

    // ① 인트로 애니메이션 (2.6초, 두드리면 즉시 건너뜀)
    if (!_introDone) {
      return Scaffold(
        body: IntroScreen(
          onDone: () => setState(() => _introDone = true),
          onSpeak: _speakIntro,
        ),
      );
    }
    // 서비스 준비가 아직이면 진입 화면 배경만 (버튼 없이)
    if (s == null) {
      return const Scaffold(body: EntryScreenPlaceholder());
    }
    return Scaffold(
      body: AnimatedBuilder(
        animation: s,
        builder: (context, _) => switch (s.phase) {

          AppPhase.entry => EntryScreen(state: s),
          AppPhase.main => MainShell(state: s),
        },
      ),
    );
  }
}
