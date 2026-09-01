import 'package:audioplayers/audioplayers.dart';

/// 분석 연출에 쓰는 기계음.
///
/// **말소리가 먼저다.** BeautyTalk 은 눈이 보이지 않는 사용자가 쓰고, 안내는
/// 전부 TTS 로 나간다. 그래서 여기 소리는 전부 짧은 악센트이고, 유일하게
/// 계속 나는 hum 은 아주 작게 깐다. TTS 가 말을 시작하면 [duck] 으로
/// 한 번 더 낮춘다 — 안내를 덮는 순간 이 연출은 앱을 망가뜨린다.
///
/// 음원은 받아온 게 아니라 `tools/hologram/make_sounds.py` 가 합성한다.
class ScanSfx {
  ScanSfx._();
  static final ScanSfx instance = ScanSfx._();

  /// 설정에서 끌 수 있게 해 둔다. 소리가 방해가 되는 사용자가 있다.
  bool enabled = true;

  /// 분석 내내 도는 소리(hum + 0.8초마다 삐빅)의 크기.
  ///
  /// 이 파일 안에 삐빅이 들어 있어서 예전 hum 보다 조금 올려 잡았다.
  /// TTS 가 말을 시작하면 [duck] 이 이걸 절반 아래로 내린다 — 삐빅은
  /// 말소리와 같은 대역이라 안 내리면 안내가 씹힌다.
  static const _humVolume = 0.5;
  static const _duckedHumVolume = 0.14;

  AudioPlayer? _hum;

  /// 한 방짜리 소리를 돌려 쓰는 자리. 매번 새로 만들면 특징점이 촘촘히
  /// 잡힐 때 플레이어가 수십 개씩 쌓인다.
  final List<AudioPlayer> _pool = [];
  int _next = 0;
  static const _poolSize = 4;

  Future<void> _oneShot(String file, double volume) async {
    if (!enabled) return;
    if (_pool.isEmpty) {
      for (var i = 0; i < _poolSize; i++) {
        _pool.add(AudioPlayer()..setReleaseMode(ReleaseMode.stop));
      }
    }
    final player = _pool[_next];
    _next = (_next + 1) % _poolSize;
    try {
      await player.stop();
      await player.setVolume(volume);
      await player.play(AssetSource('hologram/sfx/$file'));
    } catch (_) {
      // 소리는 장식이다. 못 나와도 연출과 분석은 그대로 굴러가야 한다.
    }
  }

  /// 빔이 한 번 훑고 지나갈 때
  Future<void> sweep() => _oneShot('scan_sweep.wav', 0.5);

  /// 부위 하나가 조준틀에 물릴 때. 도는 삐빅 위에 얹는 악센트라 작게 낸다.
  Future<void> blip() => _oneShot('lock_blip.wav', 0.28);

  /// 홀로그램이 올라올 때
  Future<void> rise() => _oneShot('hologram_rise.wav', 0.55);

  /// 분석이 끝났을 때. 바로 뒤에 TTS 가 결과를 읽는다.
  Future<void> done() => _oneShot('analysis_done.wav', 0.5);

  /// 잘못된 제품 경고 — 굵은 삐삐삐 5번. 화면의 붉은 깜빡임 5번과 같은
  /// 박자다 (둘 다 2.4초에 봉우리 5개). 소리와 색이 따로 놀면 두 사건이 된다.
  Future<void> alarm() => _oneShot('alert_beeps.wav', 0.75);

  /// 분석 중 계속 도는 소리. 저음 위에 0.8초마다 삐빅 한 쌍이 얹혀 있다 —
  /// 서버가 오래 걸려도 소리가 끊기지 않아야 "아직 하고 있다" 로 들린다.
  Future<void> startHum() async {
    if (!enabled || _hum != null) return;
    try {
      final player = AudioPlayer()..setReleaseMode(ReleaseMode.loop);
      _hum = player;
      await player.setVolume(_humVolume);
      await player.play(AssetSource('hologram/sfx/hum_loop.wav'));
    } catch (_) {
      _hum = null;
    }
  }

  Future<void> stopHum() async {
    final player = _hum;
    _hum = null;
    if (player == null) return;
    try {
      await player.stop();
      await player.dispose();
    } catch (_) {}
  }

  /// TTS 가 말하는 동안 배경음을 더 낮춘다.
  Future<void> duck(bool speaking) async {
    try {
      await _hum?.setVolume(speaking ? _duckedHumVolume : _humVolume);
    } catch (_) {}
  }

  Future<void> dispose() async {
    await stopHum();
    for (final player in _pool) {
      try {
        await player.dispose();
      } catch (_) {}
    }
    _pool.clear();
  }
}
