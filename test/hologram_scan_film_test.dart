import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:beauty_talk/widgets/analyzing_preview.dart';

/// 연출 전체를 한 장씩 그려서 영상으로 묶을 수 있게 뽑는다.
///
/// 기기도 없고 브라우저 화면도 못 볼 때 완성된 연출을 확인하는 방법이다.
/// 뽑은 프레임은 `tools/hologram/make_film.ps1` 이 소리와 함께 mp4 로 묶는다.
///
///     flutter test test/hologram_scan_film_test.dart
///
/// 진행률과 상태 문장은 preview_main.dart 의 대본과 같은 값을 흉내 낸다.
void main() {
  const fps = 24;
  // 연출이 5.6초라 그보다 길게 잡아야 마지막 부위까지 담긴다.
  const seconds = 8;

  // 그 뒤로 결과 화면을 이어 붙인다. 분석만 담으면 연출이 어디로 이어지는지가
  // 안 보인다 — 실제로 "결과 부분이 안 나온다" 는 얘기를 들었다.
  const resultSeconds = 4;

  // 실제 앱에서는 서버가 준 값이 들어온다. 여기 문장은 화면 구성을 보여 주기
  // 위한 예시다.
  const findings = <(String, String, String)>[
    ('왼쪽 볼', '베이스가 고르지 않게 발려 있어요.', '퍼프로 가볍게 두드려 정리해 주세요.'),
    ('입술', '입술 경계가 조금 번져 있어요.', '면봉으로 바깥선을 정리해 주세요.'),
    ('이마', '피지로 살짝 무너졌어요.', '기름종이로 누른 뒤 파우더를 얹어 주세요.'),
  ];
  const total = fps * seconds;

  // 앱이 실제로 띄우는 문장. 진행에 따라 바뀌지 않고, **끝났다고 말하지
  // 않는다** — 완료는 결과 화면 몫이다 (`AppState.analysisLine`).
  const line = '피부를 분석 중이에요.';

  testWidgets('연출 전체를 프레임으로 뽑는다', (tester) async {
    tester.view.physicalSize = const Size(786, 1440); // 393x720 @2x
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    final dir = Directory('build/scan_film');
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    dir.createSync(recursive: true);

    final key = GlobalKey();

    // 홀로그램만이 아니라 분석 중 화면 전체를 그린다 — 앱 안에서 어떻게
    // 보이는지가 확인하려는 것이라 헤더와 단계 표시기까지 있어야 한다.
    // Scaffold 로 감싼다. 헤더와 버튼이 InkWell 을 쓰는데 Material 조상이
    // 없으면 그 자리가 에러 위젯으로 바뀌고, 그 폭이 무한이라 레이아웃까지
    // 통째로 무너진다.
    Widget frame(double p) => MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            body: RepaintBoundary(
              key: key,
              child: AnalyzingPreview(
                // 연출 키를 고정해야 매 프레임 처음부터 다시 시작하지 않는다.
                sequenceKey: 'film',
                photo: const AssetImage('assets/hologram/demo_face.jpg'),
                statusLine: line,
                progress: p,
                sound: false,
                onCancel: () {},
              ),
            ),
          ),
        );

    await tester.pumpWidget(frame(0));

    // 사진과 홀로그램을 실제로 디코딩할 시간을 준다.
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 900));
    });
    await tester.pump();

    const step = Duration(milliseconds: 1000 ~/ fps);
    for (var i = 0; i < total; i++) {
      final p = (i / (total - 1)).clamp(0.0, 1.0);
      await tester.pumpWidget(frame(p));
      await tester.pump(step);

      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1.0);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File('${dir.path}/f_${i.toString().padLeft(4, '0')}.png')
            .writeAsBytesSync(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    // 이어서 결과 화면. 중간에 한 항목을 골라서 "누르면 그 자리만 밝아진다" 는
    // 것까지 보여 준다.
    Widget resultFrame() => MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            body: RepaintBoundary(
              key: key,
              child: ResultPreview(findings: findings),
            ),
          ),
        );

    const resultTotal = fps * resultSeconds;
    await tester.pumpWidget(resultFrame());
    // 아바타 프레임과 부위 좌표가 실릴 시간을 준다.
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 700));
    });
    await tester.pump();

    // 결과는 한 가지만 보여 준다 — 넘길 것이 없다.
    for (var i = 0; i < resultTotal; i++) {
      await tester.pump(step);

      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1.0);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File('${dir.path}/f_${(total + i).toString().padLeft(4, '0')}.png')
            .writeAsBytesSync(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    // ignore: avoid_print
    print('[film] ${total + resultTotal} 장 -> ${dir.path}');

    // 움직이는 WebP 가 타이머를 물고 있으면 테스트가 안 끝난다.
    await tester.pumpWidget(const SizedBox.shrink());
  }, timeout: const Timeout(Duration(minutes: 10)));
}
