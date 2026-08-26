import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 앱 전체에서 하나의 카메라 컨트롤러를 공유합니다 (모든 탭 배경이 카메라).
class CameraService extends ChangeNotifier {
  CameraService._();
  static final CameraService instance = CameraService._();

  CameraController? controller;
  List<CameraDescription> _cameras = const [];
  CameraLensDirection _lens = CameraLensDirection.back;
  String? error;

  bool get isReady => controller?.value.isInitialized ?? false;
  CameraLensDirection get lens => _lens;

  Future<void> init({CameraLensDirection lens = CameraLensDirection.back}) async {
    unawaited(_trimShots()); // 지난 실행에서 남은 것부터 정리
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        error = '카메라를 찾을 수 없어요';
        notifyListeners();
        return;
      }
      await _open(lens);
    } catch (e) {
      error = '카메라 오류: $e';
      debugPrint('[Camera] $error');
      notifyListeners();
    }
  }

  Future<void> _open(CameraLensDirection lens) async {
    final cam = _cameras.firstWhere(
      (c) => c.lensDirection == lens,
      orElse: () => _cameras.first,
    );
    _lens = cam.lensDirection;
    final old = controller;
    controller = null;
    notifyListeners();
    await old?.dispose();

    final c = CameraController(
      cam,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    await c.initialize();
    controller = c;
    error = null;
    notifyListeners();
  }

  /// 화장품 탭 = 후면, 가이드/눈썹 탭 = 전면 카메라 처럼 탭별로 바꿀 때 사용.
  Future<void> switchTo(CameraLensDirection lens) async {
    if (_lens == lens && isReady) return;
    if (_cameras.isEmpty) return;
    try {
      await _open(lens);
    } catch (e) {
      debugPrint('[Camera] switch failed: $e');
    }
  }

  /// 촬영 파일을 몇 장까지 남길지. 안 지우면 캐시에 계속 쌓인다
  /// (탭 진입마다 렌즈 검사 1장 + 촬영마다 1장, 장당 수백 KB).
  /// 최근 것만 남겨 두면 "방금 뭘 찍었길래 저렇게 인식했지"를 확인할 수 있다.
  static const shotKeep = 10;

  /// [transient] 는 프레이밍 확인처럼 바로 버릴 프레임이다.
  /// 보관 정리(_trimShots)를 건너뛴다 — 안 그러면 3초마다 찍는 확인용 프레임이
  /// 실제 촬영 기록을 하나씩 밀어내서, 최근 10장이 금세 확인용으로만 채워진다.
  Future<String?> takePicture({bool transient = false}) async {
    final c = controller;
    if (c == null || !c.value.isInitialized || c.value.isTakingPicture) {
      return null;
    }
    try {
      final file = await c.takePicture();
      if (!transient) unawaited(_trimShots());
      return file.path;
    } catch (e) {
      debugPrint('[Camera] takePicture failed: $e');
      return null;
    }
  }

  /// 확인용으로만 쓴 프레임을 즉시 버린다.
  ///
  /// 프레이밍 확인은 3초마다 찍는데, 그대로 두면 최근 10장이 전부 확인용으로
  /// 채워져 "방금 뭘 찍었길래 저렇게 나왔지" 를 볼 수 없게 된다.
  Future<void> discard(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {
      // 실패해도 무시 — 어차피 최근 N장 정리에서 걸린다
    }
  }

  /// 촬영 파일을 최근 [shotKeep] 장만 남기고 오래된 것부터 지운다.
  /// 앱 시작 시(지난 실행 잔여물)와 촬영 직후에 부른다.
  Future<void> _trimShots() async {
    try {
      final dir = await getTemporaryDirectory();
      final shots = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.jpg'))
          .toList();
      if (shots.length <= shotKeep) return;
      // 오래된 순 정렬 → 앞에서부터 초과분 삭제
      shots.sort((a, b) => a.statSync().modified.compareTo(b.statSync().modified));
      final drop = shots.length - shotKeep;
      for (final f in shots.take(drop)) {
        f.deleteSync();
      }
      debugPrint('[Camera] 촬영 파일 $drop개 정리 (최근 $shotKeep장 유지)');
    } catch (e) {
      debugPrint('[Camera] 촬영 파일 정리 실패: $e');
    }
  }

  Future<void> pause() async {
    try {
      await controller?.pausePreview();
    } catch (_) {}
  }

  Future<void> resume() async {
    try {
      await controller?.resumePreview();
    } catch (_) {}
  }

  @override
  void dispose() {
    controller?.dispose();
    super.dispose();
  }
}
