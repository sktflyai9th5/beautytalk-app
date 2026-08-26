import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:beauty_talk/widgets/hologram_scan.dart';

/// 연출의 각 구간을 실제로 그려서 PNG 로 뽑는다.
///
/// 안드로이드 기기가 없고 브라우저 화면도 못 볼 때, 구도가 맞는지 확인하는
/// 가장 확실한 방법이다. 통과/실패를 보는 테스트가 아니라 **눈으로 보려고**
/// 돌리는 것이다 — 결과는 build/scan_frames/ 에 쌓인다.
///
///     flutter test test/hologram_scan_render_test.dart
void main() {
  testWidgets('연출 구간별로 그려 본다', (tester) async {
    tester.view.physicalSize = const Size(786, 1440); // 393x720 @2x
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: RepaintBoundary(
          key: key,
          child: const HologramScan(
            photo: AssetImage('assets/hologram/demo_face.jpg'),
            statusLine: '메이크업 상태를 보는 중이에요',
            progress: 0.62,
            // 테스트에서는 소리를 내지 않는다 — 오디오 플러그인이 없다.
            sound: false,
          ),
        ),
      ),
    );

    // 사진과 홀로그램을 실제로 디코딩할 시간을 준다.
    // runAsync 밖에서는 이미지 코덱이 돌지 않아 빈 자리로 그려진다.
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 700));
    });
    await tester.pump();

    final dir = Directory('build/scan_frames');
    if (!dir.existsSync()) dir.createSync(recursive: true);

    // 전체 5200ms 를 구간별로 끊어 본다.
    const shots = <String, int>{
      'a_beam': 900,      // 빔이 훑는 중
      'b_lock': 1800,     // 특징점이 잡히는 중
      'c_morph': 3200,    // 홀로그램으로 넘어가는 중
      'd_hold': 4600,     // 홀로그램이 자리 잡음
    };

    var elapsed = 0;
    for (final entry in shots.entries) {
      await tester.pump(Duration(milliseconds: entry.value - elapsed));
      elapsed = entry.value;

      // toImage 는 반드시 runAsync 안에서 기다려야 한다. 밖에서 await 하면
      // 가짜 시계가 완료를 처리하지 못해 두 번째 장부터 그대로 멈춘다.
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1.6);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File('${dir.path}/${entry.key}.png')
            .writeAsBytesSync(bytes!.buffer.asUint8List());
        image.dispose();
      });
      // ignore: avoid_print
      print('[render] ${entry.key}.png  (t=${entry.value}ms)');
    }

    // 홀로그램(움직이는 WebP)이 타이머를 물고 있으면 테스트가 안 끝난다.
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
