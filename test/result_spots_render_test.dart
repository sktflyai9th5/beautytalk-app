// 결과 화면의 '문제 자리 짚기' 를 눈으로 보려고 돌리는 테스트다.
// 통과/실패를 보는 게 아니라 build/result_spots.png 를 남긴다.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:beauty_talk/widgets/coral.dart';

void main() {
  Future<void> shot(WidgetTester tester, int? active, String out) async {
    final key = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: RepaintBoundary(
            key: key,
            child: SizedBox(
              width: 361,
              height: 240,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: ShotWithBoxes(
                  // 두 번째 카드를 누른 상태. 나머지는 테두리만 남는다.
                  active: active,
                  path: 'assets/hologram/demo_face.jpg',
                  spots: const [
                    // 서버가 좌표를 안 준 경우 — 부위 이름으로 어림한다.
                    ProblemSpot(region: '왼쪽 볼'),
                    ProblemSpot(region: '입술'),
                    ProblemSpot(region: '오른쪽 눈썹'),
                    // 좌표를 준 경우 — 또렷하게 그린다.
                    ProblemSpot(
                        region: '이마',
                        box: Rect.fromLTRB(0.40, 0.26, 0.61, 0.32)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ));

    await tester.runAsync(() async {
      // 사진을 읽어 크기를 잡을 때까지 몇 번 돌린다.
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 60));
        await tester.pump();
      }
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2.0);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory('build').createSync(recursive: true);
      File(out)
          .writeAsBytesSync(bytes!.buffer.asUint8List());
      image.dispose();
    });

    await tester.pumpWidget(const SizedBox());
  }

  testWidgets('문제 자리를 사진 위에 짚는다', (tester) async {
    tester.view.physicalSize = const Size(786, 720);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    await shot(tester, null, 'build/result_spots.png');
    await shot(tester, 0, 'build/result_spots_picked.png');
  });
}
