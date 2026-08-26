import 'dart:async';

import 'package:flutter/material.dart';

import 'services/scan_sfx.dart';
import 'theme/app_theme.dart';
import 'widgets/analyzing_preview.dart';

/// 분석 연출만 따로 띄워 보는 미리보기.
///
///     flutter run -d chrome -t lib/preview_main.dart
///
/// 카메라·STT·모델을 건드리지 않으므로 안드로이드 기기가 없어도 돌아간다.
/// 실제 앱 화면이 아니라 [HologramScan] 을 확인하기 위한 껍데기다 —
/// 위젯 자체는 메이크업 분석 탭이 쓰는 것과 같은 코드다.
void main() => runApp(const _PreviewApp());

class _PreviewApp extends StatelessWidget {
  const _PreviewApp();

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'BeautyTalk 분석 연출 미리보기',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        home: const _PreviewHome(),
      );
}

const _accent = AnalyzingPreview.defaultAccent;

class _PreviewHome extends StatefulWidget {
  const _PreviewHome();

  @override
  State<_PreviewHome> createState() => _PreviewHomeState();
}

class _PreviewHomeState extends State<_PreviewHome> {
  /// 브라우저는 사용자가 한 번 누르기 전에는 소리를 내주지 않는다.
  /// 그래서 바로 시작하지 않고 버튼을 하나 두었다.
  bool _running = false;
  bool _sound = true;

  /// 연출을 처음부터 다시 돌리기 위한 키. 값이 바뀌면 위젯이 새로 만들어진다.
  int _take = 0;

  FaceOverlay? _overlay;
  double _progress = 0;
  String _line = _kLine;
  Timer? _timer;

  /// 앱이 실제로 띄우는 문장 (`AppState.analysisLine`). 진행에 따라 바뀌지
  /// **않는다** — 무엇을 보고 있는지만 말하고, 끝났다는 말은 결과 화면 몫이다.
  /// 여기서 "분석이 끝났어요" 를 띄우면 아직 기다리는 중에 거짓말이 된다.
  static const _kLine = '피부를 분석 중이에요.';

  @override
  void initState() {
    super.initState();
    _loadPoints();
  }

  @override
  void dispose() {
    _timer?.cancel();
    ScanSfx.instance.dispose();
    super.dispose();
  }

  Future<void> _loadPoints() async {
    final loaded =
        await FaceOverlay.load('assets/hologram/demo_face_points.json');
    if (!mounted || loaded == null) return;
    setState(() => _overlay = loaded);
  }

  void _start() {
    _timer?.cancel();
    ScanSfx.instance.enabled = _sound;
    setState(() {
      _running = true;
      _take++;
      _progress = 0;
      _line = _kLine;
    });

    // 연출보다 길게 잡는다. 실제로는 백엔드 분석이 이 값을 준다 —
    // 연출이 먼저 끝나고 나서도 화면은 계속 기다릴 수 있어야 한다.
    const tick = Duration(milliseconds: 80);
    const total = 8000;
    var elapsed = 0;
    _timer = Timer.periodic(tick, (timer) {
      elapsed += tick.inMilliseconds;
      final p = (elapsed / total).clamp(0.0, 1.0);
      setState(() => _progress = p);
      if (p >= 1.0) {
        timer.cancel();
        // 완료음은 결과 화면으로 넘어가는 신호다. 문장은 바뀌지 않는다.
        if (_sound) ScanSfx.instance.done();
        ScanSfx.instance.stopHum();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF120309),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                // 실제 화면 비율(휴대폰)로 가둬 놓고 본다. 브라우저 창이
                // 넓어도 폰에서 보이는 그대로여야 판단이 된다.
                child: AspectRatio(
                  aspectRatio: 393 / 720,
                  child: Container(
                    margin: const EdgeInsets.all(16),
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(AppShape.cardRadius),
                      boxShadow: const [
                        BoxShadow(color: Color(0x66000000), blurRadius: 40),
                      ],
                    ),
                    child: _running
                        ? AnalyzingPreview(
                            sequenceKey: _take,
                            photo: const AssetImage(
                                'assets/hologram/demo_face.jpg'),
                            overlay: _overlay,
                            statusLine: _line,
                            progress: _progress,
                            accent: _accent,
                            sound: _sound,
                            onCancel: _start,
                          )
                        : _Idle(onStart: _start),
                  ),
                ),
              ),
            ),
            _Controls(
              running: _running,
              sound: _sound,
              onReplay: _start,
              onSound: (v) {
                setState(() => _sound = v);
                ScanSfx.instance.enabled = v;
                if (!v) ScanSfx.instance.stopHum();
              },
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

class _Idle extends StatelessWidget {
  const _Idle({required this.onStart});
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF2A0810), Color(0xFF1B0710)],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.play_circle_outline_rounded,
                size: 72, color: _accent),
            const SizedBox(height: 16),
            const Text('분석 연출 재생',
                style: TextStyle(
                    fontSize: 20, fontWeight: FontWeight.w700, color: Colors.white)),
            const SizedBox(height: 8),
            Text('브라우저는 한 번 눌러야 소리를 내줍니다',
                style: TextStyle(
                    fontSize: 13, color: Colors.white.withValues(alpha: 0.6))),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: onStart,
              style: FilledButton.styleFrom(
                backgroundColor: _accent,
                foregroundColor: const Color(0xFF1B0710),
                padding:
                    const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
              ),
              child: const Text('시작', style: AppText.button),
            ),
          ],
        ),
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.running,
    required this.sound,
    required this.onReplay,
    required this.onSound,
  });

  final bool running;
  final bool sound;
  final VoidCallback onReplay;
  final ValueChanged<bool> onSound;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 12,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        FilledButton.icon(
          onPressed: onReplay,
          icon: const Icon(Icons.replay_rounded),
          label: Text(running ? '다시 재생' : '재생'),
          style: FilledButton.styleFrom(
            backgroundColor: _accent,
            foregroundColor: const Color(0xFF1B0710),
          ),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Switch(value: sound, onChanged: onSound, activeThumbColor: _accent),
            const Text('소리', style: TextStyle(color: Colors.white70)),
          ],
        ),
      ],
    );
  }
}
