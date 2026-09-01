import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../theme/app_theme.dart';
import 'entry_screen.dart';

/// 진입 인트로. 영상 한 편을 틀고 **화면을 두드리면 시작**한다.
///
/// 「인트로 접근성 규칙」(424:12)에서 그대로 가져온 것:
///   · 화면 전체가 탭 영역. 한 번 두드리면 즉시 넘어간다.
///   · 0.2초에 TTS 를 시작한다 — 화면이 보이지 않는 사용자에게 인트로는
///     그냥 침묵이다. 연출 시간을 안내 시간으로 함께 쓴다.
///   · 건너뛰어도 음성은 끊지 않는다 (진입 화면에서 이어서 재생)
///   · ANIMATOR_DURATION_SCALE == 0 이거나 TalkBack 이 켜져 있으면
///     **영상을 기다리지 않고 바로 넘어간다.** 이것만은 자동이어야 한다 —
///     두드려야만 넘어가게 두면 화면을 못 보는 사용자가 갇힌다.
///
/// **영상 소리는 끈다.** 이 앱의 안내는 전부 TTS 로 나가고, 그 위에 다른
/// 소리가 겹치면 안내를 덮는다. 인트로 음악을 살리고 싶으면 [muted] 를 끄되,
/// 그때는 TTS 시작 시점을 뒤로 미뤄야 한다.
class IntroScreen extends StatefulWidget {
  const IntroScreen({
    super.key,
    required this.onDone,
    required this.onSpeak,
    this.abbreviated = false,
    this.muted = true,
  });

  /// 사용자가 두드렸거나(또는 접근성 설정 때문에) 넘어갈 때
  final VoidCallback onDone;

  /// 0.2초에 부른다 (지금은 쓰지 않는다 — 안내는 [voiceAsset] 이 맡는다).
  /// 부르는 쪽(main.dart)의 약속을 깨지 않기 위해 남겨 둔다.
  final VoidCallback onSpeak;

  /// 두 번째 실행부터 true. 지금은 영상을 두드릴 때까지 두므로 화면은 같고,
  /// 부르는 쪽(main.dart)의 약속을 깨지 않기 위해 남겨 둔다.
  final bool abbreviated;

  /// 영상 소리를 끌지. 기본은 끈다 (TTS 를 덮지 않기 위해).
  final bool muted;

  static const asset = 'assets/video/intro.mp4';
  static const speakAt = Duration(milliseconds: 200);

  /// 인트로 안내 음성. **기기 TTS 가 아니라 구워 둔 파일이다.**
  /// 기기마다 목소리·속도가 달라 첫인상이 들쭉날쭉했고, 사용자가 설정에서
  /// 바꾼 속도가 인트로에까지 적용돼 너무 빠르거나 느리게 들렸다.
  /// 여기 한 문장만은 항상 같은 소리로 나가야 한다.
  static const voiceAsset = 'audio/intro_voice.m4a';

  @override
  State<IntroScreen> createState() => _IntroScreenState();
}

class _IntroScreenState extends State<IntroScreen>
    with SingleTickerProviderStateMixin {
  /// 구워 둔 안내 음성. 화면을 떠날 때 같이 멈춘다 — 남겨 두면 카메라 화면의
  /// 안내와 두 목소리가 겹친다.
  final AudioPlayer _voice = AudioPlayer()..setReleaseMode(ReleaseMode.stop);

  /// 안내 문구가 숨 쉬는 시계. 영상이 멈춘 뒤에도 화면이 살아 있다는 신호다.
  late final AnimationController _blink = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  VideoPlayerController? _video;
  Timer? _speakTimer;
  bool _finished = false;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    // 애니메이션보다 음성이 먼저다.
    _speakTimer = Timer(IntroScreen.speakAt, _playVoice);

    // 「모션 축소 설정 대응」 — 영상을 아예 띄우지 않고 바로 넘어간다.
    if (WidgetsBinding
        .instance.platformDispatcher.accessibilityFeatures.disableAnimations) {
      Timer(IntroScreen.speakAt, _finish);
      return;
    }
    _load();
  }

  Future<void> _load() async {
    final v = VideoPlayerController.asset(IntroScreen.asset);
    _video = v;
    try {
      await v.initialize();
      if (!mounted) return;
      await v.setVolume(widget.muted ? 0 : 1);
      // **한 번만 튼다.** 되감아 다시 트는 인트로는 첫 화면이 아니라 배경
      // 영상처럼 보여서, 두드려야 넘어간다는 걸 알아채기 어렵다. 끝나면
      // 마지막 장면에 멈춰 두고, 두드리라는 안내만 깜빡이게 한다.
      // 계속 돈다. 두드릴 때까지 기다리는 화면이라 멈춰 있으면 앱이
      // 죽은 것으로 보인다. **음성만 한 번이다** — 안내를 반복해서 틀면
      // 화면을 못 보는 사용자에게는 같은 말이 계속 끼어드는 소음이 된다.
      await v.setLooping(true);
      await v.play();
      setState(() => _ready = true);
    } catch (_) {
      // 영상이 없거나 못 틀어도 진입은 막지 않는다.
      // 이 화면은 장식이고, 앱은 그대로 굴러가야 한다.
      if (mounted) _finish();
    }
  }

  Future<void> _playVoice() async {
    if (!mounted) return;
    try {
      // **오디오 포커스를 가져가지 않는다.** 가져가면 같은 화면에서 돌던
      // 영상이 (ExoPlayer 가 포커스를 잃고) 그 자리에 멈춰 버린다 —
      // 실제로 인트로가 첫 장면에서 굳었다.
      await _voice.setAudioContext(AudioContext(
        android: const AudioContextAndroid(
          contentType: AndroidContentType.speech,
          usageType: AndroidUsageType.assistanceAccessibility,
          audioFocus: AndroidAudioFocus.none,
        ),
      ));
      await _voice.play(AssetSource(IntroScreen.voiceAsset));
    } catch (e) {
      // 파일이 없거나 못 틀면 기기 TTS 로 되돌아간다 — 화면을 못 보는
      // 사용자에게 인트로가 통째로 침묵이 되면 안 된다.
      debugPrint('[Intro] 안내 음성 실패 → TTS 로 대체: $e');
      if (mounted) widget.onSpeak();
    }
  }

  /// 한 번만 넘어간다 (탭이 여러 번 들어올 수 있다)
  void _finish() {
    if (_finished || !mounted) return;
    _finished = true;
    widget.onDone();
  }

  void _tap() {
    HapticFeedback.selectionClick();
    _finish(); // 음성은 그대로 두고 화면만 넘어간다
  }

  @override
  void dispose() {
    _speakTimer?.cancel();
    unawaited(_voice.dispose());
    _blink.dispose();
    _video?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = _video;
    return Semantics(
      button: true,
      label: '뷰티톡입니다. 화면을 두드리면 시작합니다.',
      child: GestureDetector(
        // 화면 전체가 탭 영역
        behavior: HitTestBehavior.opaque,
        onTap: _tap,
        child: ColoredBox(
          color: AppColors.surface,
          child: ExcludeSemantics(
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 영상이 준비되기 전에는 빈 면으로 둔다. 준비 중 표시를 넣으면
                // 0.3초 나타났다 사라져서 오히려 깜박임으로 보인다.
                if (_ready && v != null)
                  FittedBox(
                    // 영상(406x720)이 화면보다 가로로 넓다. 채워서 자른다 —
                    // 레터박스를 두면 인트로가 창에 갇힌 것처럼 보인다.
                    fit: BoxFit.cover,
                    clipBehavior: Clip.hardEdge,
                    child: SizedBox(
                      width: v.value.size.width,
                      height: v.value.size.height,
                      child: VideoPlayer(v),
                    ),
                  ),
                // 두드리라는 안내. 화면이 보이는 사용자를 위한 것이고,
                // 보이지 않는 사용자에게는 위 Semantics 라벨이 같은 말을 한다.
                Positioned(
                  left: AppShape.gutter,
                  right: AppShape.gutter,
                  bottom: 64,
                  child: FadeTransition(
                    // 0 까지 꺼뜨리지 않는다 — 완전히 사라졌다 나타나면
                    // 오류로 보인다. 밝기만 오간다.
                    opacity: _ready
                        ? Tween<double>(begin: 0.45, end: 1.0).animate(
                            CurvedAnimation(
                                parent: _blink, curve: Curves.easeInOut))
                        : const AlwaysStoppedAnimation(0.0),
                    child: Text(
                      EntryScreen.hint,
                      textAlign: TextAlign.center,
                      // 영상 위에 얹히는 글자다. 흰색으로 두되 어두운 그림자를
                      // 깐다 — 인트로에는 밝은 장면도 지나가는데, 그때 흰 글자만
                      // 있으면 안내가 통째로 사라진다.
                      style: AppText.entryHint.copyWith(
                        color: Colors.white,
                        shadows: const [
                          Shadow(blurRadius: 12, color: Color(0x8A000000)),
                          Shadow(blurRadius: 3, color: Color(0x66000000)),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
