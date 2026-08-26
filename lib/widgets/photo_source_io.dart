import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

/// 기기에서 찍은 사진을 파일 경로로 읽는다. 안드로이드/데스크톱 쪽 구현이다.
ImageProvider photoProvider(String path) => FileImage(File(path));

Future<Uint8List> readPhotoBytes(String path) => File(path).readAsBytes();
