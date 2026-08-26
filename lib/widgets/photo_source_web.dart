import 'dart:typed_data';

import 'package:flutter/widgets.dart';

/// 웹에는 `dart:io` 가 없다. 웹에서는 카메라로 찍는 흐름 자체가 없고
/// 연출 미리보기만 도니까, 파일 경로를 받으면 빈 것을 돌려준다.
/// 부르는 쪽이 전부 errorBuilder 로 받아내고 있다.
ImageProvider photoProvider(String path) => MemoryImage(Uint8List(0));

Future<Uint8List> readPhotoBytes(String path) async => Uint8List(0);
