/// 찍은 사진을 경로로 읽는 자리. 플랫폼에 따라 구현이 갈린다.
///
/// `dart:io` 를 화면 코드가 직접 import 하면 그 파일이 딸린 화면 전체가
/// 웹에서 컴파일되지 않는다. 연출을 기기 없이 브라우저에서 확인하려면
/// 화면 부품(coral.dart)이 웹에서도 빌드돼야 해서 여기로 몰아 두었다.
library;

export 'photo_source_io.dart'
    if (dart.library.js_interop) 'photo_source_web.dart';
