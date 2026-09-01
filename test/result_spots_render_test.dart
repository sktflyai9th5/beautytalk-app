// 결과 화면의 '부위를 삼각형으로 밝히기' 를 눈으로 보려고 돌리는 테스트다.
// 통과/실패를 보는 게 아니라 build/result_light.png 를 남긴다.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:beauty_talk/widgets/hologram_scan.dart';

void main() {
  Future<void> shot(WidgetTester tester, String region, String out) async {
    final key = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Colors.white,
        body: Center(
          child: RepaintBoundary(
            key: key,
            child: SizedBox(
              width: 361,
              height: 320,
              child: ResultShowcase(
                regions: [region],
                sentence: '베이스가 고르지 않게 발려 있어요.',
              ),
            ),
          ),
        ),
      ),
    ));

    await tester.runAsync(() async {
      // 아바타 프레임과 격자 좌표가 실릴 때까지 몇 번 돌린다.
      for (var i = 0; i < 12; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 60));
        await tester.pump();
      }
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2.0);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory('build').createSync(recursive: true);
      File(out).writeAsBytesSync(bytes!.buffer.asUint8List());
      image.dispose();
    });

    await tester.pumpWidget(const SizedBox());
  }

  testWidgets('부위를 삼각형으로 밝힌다', (tester) async {
    tester.view.physicalSize = const Size(786, 900);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    await shot(tester, '왼쪽 볼', 'build/result_light.png');
    await shot(tester, '이마', 'build/result_light_forehead.png');
  });
}
