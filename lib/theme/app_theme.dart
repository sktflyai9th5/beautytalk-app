import 'package:flutter/material.dart';

/// 피그마 "Codex Draft · Coral Soft · 원본 보존" (node 368:2) 토큰.
///
/// 값은 눈으로 옮긴 것이 아니라 Figma REST 로 파일에서 직접 뽑았다.
/// 색을 바꿀 일이 있으면 여기만 고치면 된다 — 화면 코드에는 hex 를 두지 않는다.
class AppColors {
  // ── 배경 ──────────────────────────────────────────────
  /// 진입 화면 바탕 (#FFFDFC → #FEF2F0)
  static const canvasTop = Color(0xFFFFFDFC);
  static const canvasMid = Color(0xFFFFF9F7);
  static const canvasBottom = Color(0xFFFEF1EF);
  static const canvasEntryBottom = Color(0xFFFEF2F0);

  /// 카드·시트 바탕
  static const surface = Color(0xFFFFFFFF);

  /// 촬영·분석 면 (#FDF4F1)
  static const surfaceSoft = Color(0xFFFDF4F1);

  /// 확인 중 면 · 질문 카드 (#FCF0ED)
  static const surfaceScan = Color(0xFFFCF0ED);

  /// 결과 카드 (#FCF2F2)
  static const surfaceCard = Color(0xFFFCF2F2);

  /// 선택된 탭 알약 (#FFE9ED)
  static const surfaceTint = Color(0xFFFFE9ED);

  /// 추천 질문 알약 (#FFF5F4)
  static const surfaceSuggest = Color(0xFFFFF5F4);

  /// 행동 칩 (#FFE3E0)
  static const surfaceChip = Color(0xFFFFE3E0);

  /// 진행률 트랙 (#FAE5E3)
  static const track = Color(0xFFFAE5E3);

  // ── 글자 ──────────────────────────────────────────────
  /// 제목. 거의 검정이지만 붉은 기가 돈다 (#301A1C)
  static const ink = Color(0xFF301A1C);

  /// 본문·부제 (#6B5254)
  static const inkBody = Color(0xFF6B5254);

  /// 탭 라벨·비활성 (#755E61)
  static const inkSoft = Color(0xFF755E61);

  /// 비활성 단계 숫자 (#7A6062)
  static const inkMuted = Color(0xFF7A6062);

  /// 추천 질문 글자 (#6E363B)
  static const inkQuestion = Color(0xFF6E363B);

  // ── 브랜드 ────────────────────────────────────────────
  /// 강조 텍스트·선택된 탭 (#B02426)
  static const brand = Color(0xFFB02426);

  /// 활성 단계 라벨·눈썹 문구 (#A82426)
  static const brandLabel = Color(0xFFA32226);

  /// 아주 작은 눈썹 문구 (#A82426)
  static const brandEyebrow = Color(0xFFA82426);

  /// 셔터 라벨·아이콘 (#6B0F1E)
  static const brandDeep = Color(0xFF6B0F1E);

  /// 채움 버튼 글자 (#3A0A14)
  static const brandDark = Color(0xFF3A0A14);

  /// 진입 화면 BEAUTY/TALK (#7A2A35), 인트로는 #471417
  static const brandSerif = Color(0xFF7A2A35);
  static const brandSerifDeep = Color(0xFF471417);

  /// 행동 칩 글자 (#8E2B32)
  static const brandChip = Color(0xFF8E2B32);

  /// 스캔 선 (#B22629)
  static const scanLine = Color(0xFFB22629);

  /// 채움 버튼·셔터
  static const coral = Color(0xFFFF8DA1);
  static const coralDeep = Color(0xFFFF7A92);
  static const coralLight = Color(0xFFFFA5B4);

  // ── 테두리 ────────────────────────────────────────────
  /// 단계 연결선 (#E7D8D8)
  static const border = Color(0xFFE7D8D8);

  /// 버튼 외곽선 (#E1ABB8)
  static const outline = Color(0xFFE1ABB8);

  /// 촬영 면 외곽선 (#CC7A75 30%)
  static const surfaceEdge = Color(0x4DCC7A75);

  /// 카드 외곽선 (#D98C87 28%)
  static const cardEdge = Color(0x47D98C87);

  /// 비활성 단계 원 테두리 (#BF7370 35%)
  static const stepEdge = Color(0x59BF7370);

  /// 칩·추천 질문 테두리 (#B22629 22%)
  static const chipEdge = Color(0x38B22629);

  // ── 그라데이션 ────────────────────────────────────────
  /// 진입 화면 배경 (#FFFDFC → #FEF2F0)
  static const entryBackdrop = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [canvasTop, canvasEntryBottom],
  );

  /// 일반 화면 배경 (#FFFFFF → #FFF9F7 → #FEF1EF)
  static const screenBackdrop = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [surface, canvasMid, canvasBottom],
  );

  /// 진입 화면의 흐릿한 원 3개
  static const blobDeep =
      LinearGradient(colors: [Color(0xFF8E1A22), Color(0xFFC93034)]);
  static const blobCoral =
      LinearGradient(colors: [Color(0xFFD64649), Color(0xFFF98E83)]);
  static const blobPink =
      LinearGradient(colors: [Color(0xFFFBAFA8), Color(0xFFFFDDD9)]);

  /// 활성 단계 원 · 결과 카드 번호 배지
  static const stepActive =
      LinearGradient(colors: [Color(0xFF8E1A22), Color(0xFFC93034)]);
  static const badge =
      LinearGradient(colors: [Color(0xFFFF7A92), Color(0xFFC93034)]);

  /// 셔터·음성 버튼 (#FFA5B4 → #FF7A92)
  static const shutter = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [coralLight, coralDeep],
  );

  /// 진행률 채움 (#8E1A22 → #D64649)
  static const progress =
      LinearGradient(colors: [Color(0xFF8E1A22), Color(0xFFD64649)]);

  /// 카운트다운 화면을 덮는 어둠 (#5C0F1C 42% → #380A14 80%)
  static const dim = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0x6B5C0F1C), Color(0x9E4D0D1A), Color(0xCC380A14)],
  );

  /// 촬영 면 안쪽 비네트 (#59141F 0% → 20%)
  static const vignette = RadialGradient(
    radius: 0.85,
    colors: [Color(0x0059141F), Color(0x0059141F), Color(0x3359141F)],
    stops: [0.0, 0.55, 1.0],
  );

  /// 카드 그림자 (아주 옅은 코랄)
  static const cardShadow = Color(0x14B02426);
}

/// 타이포. 피그마는 Playfair Display(영문 타이틀) + Noto Sans KR(본문)을 쓴다.
///
/// Playfair 는 가변 폰트라 굵기를 `fontVariations` 로 지정해야 700 이 나온다
/// (`fontWeight` 만 주면 Regular 인스턴스가 그려진다).
/// 한글은 기기 기본 본문 글꼴이 곧 Noto Sans CJK KR 이라 그대로 둔다.
class AppText {
  static const _serif = 'PlayfairDisplay';
  static const _bold = [FontVariation('wght', 700)];

  /// BEAUTY / TALK — 진입 화면 44px
  static const display = TextStyle(
    fontFamily: _serif,
    fontVariations: _bold,
    fontSize: 44,
    height: 1.0,
    fontWeight: FontWeight.w700,
    color: AppColors.brandSerif,
  );

  /// BEAUTY / TALK — 인트로 40px
  static const displaySmall = TextStyle(
    fontFamily: _serif,
    fontVariations: _bold,
    fontSize: 40,
    height: 53.3 / 40,
    fontWeight: FontWeight.w700,
    color: AppColors.brandSerifDeep,
  );

  /// MAKEUP AI ASSISTANT — 10px, 자간 0.6
  static const eyebrow = TextStyle(
    fontSize: 10,
    height: 1.2,
    letterSpacing: 0.6,
    fontWeight: FontWeight.w700,
    color: AppColors.brandEyebrow,
  );

  /// 화면 제목 (헤더) 20px
  static const appBarTitle = TextStyle(
    fontSize: 22,
    height: 31 / 22,
    fontWeight: FontWeight.w700,
    color: AppColors.ink,
  );

  /// 화면 본문 큰 제목 26px
  static const h1 = TextStyle(
    fontSize: 26,
    height: 36.4 / 26,
    fontWeight: FontWeight.w700,
    color: AppColors.ink,
  );

  /// 인트로 브랜드 메시지 28px
  static const h1Intro = TextStyle(
    fontSize: 28,
    height: 36 / 28,
    fontWeight: FontWeight.w700,
    color: AppColors.ink,
  );

  /// 제목 아래 설명 15px
  static const sub = TextStyle(
    fontSize: 15,
    height: 23.2 / 15,
    fontWeight: FontWeight.w400,
    color: AppColors.inkBody,
  );

  /// 진입 화면 부제 17px
  static const subLarge = TextStyle(
    fontSize: 17,
    height: 27.2 / 17,
    fontWeight: FontWeight.w400,
    color: Color(0xFF593D40),
  );

  /// 버튼 글자 18px
  static const button = TextStyle(
    fontSize: 18,
    height: 25.2 / 18,
    fontWeight: FontWeight.w700,
  );

  /// 카드 제목 · 추천 질문 17px
  static const cardTitle = TextStyle(
    fontSize: 17,
    height: 27.2 / 17,
    fontWeight: FontWeight.w700,
    color: AppColors.ink,
  );

  /// 카드 본문 15px
  static const cardBody = TextStyle(
    fontSize: 15,
    height: 23.2 / 15,
    fontWeight: FontWeight.w400,
    color: AppColors.inkBody,
  );

  /// 라벨·탭 이름·단계 이름 14px
  static const label = TextStyle(
    fontSize: 14,
    height: 19.6 / 14,
    fontWeight: FontWeight.w700,
  );

  /// 진입 화면 안내 — 이 화면의 유일한 지시문이라 크게 쓴다
  static const entryHint = TextStyle(
    fontSize: 24,
    height: 34 / 24,
    fontWeight: FontWeight.w700,
    color: AppColors.brand,
  );

  /// 결과 카드 — 부위 이름 30px (저시력 기준 — 작으면 화면이 없는 것과 같다)
  static const resultTitle = TextStyle(
    fontSize: 30,
    height: 40 / 30,
    fontWeight: FontWeight.w700,
    color: AppColors.ink,
  );

  /// 결과 카드 — 상태 문장 24px. 굵고 진하게 — 이 문장이 결과의 본문이다.
  static const resultBody = TextStyle(
    fontSize: 24,
    height: 34 / 24,
    fontWeight: FontWeight.w700,
    color: AppColors.ink,
  );

  /// 결과 카드 — 할 일 칩 22px
  static const resultAction = TextStyle(
    fontSize: 20,
    height: 29 / 20,
    fontWeight: FontWeight.w700,
  );

  /// 작은 보조 문구 13px
  static const caption = TextStyle(
    fontSize: 13,
    height: 15.6 / 13,
    fontWeight: FontWeight.w700,
    color: AppColors.inkBody,
  );
}

/// 모서리·간격. 피그마에서 반복되는 값만 이름을 붙였다.
class AppShape {
  /// 좌우 여백 — (393 - 353) / 2
  static const gutter = 20.0;

  /// 화면 콘텐츠 폭 (피그마 353px)
  static const contentWidth = 353.0;

  /// 촬영 면·카드
  static const cardRadius = 28.0;

  /// 버튼
  static const buttonRadius = 20.0;
  static const buttonHeight = 59.0;

  /// 칩·탭 알약
  static const chipRadius = 12.0;
  static const pillRadius = 999.0;

  /// 접근성: 최소 터치 영역. 셔터·음성 버튼은 88 이상 (피그마 명세)
  static const minTouch = 44.0;
  static const bigTouch = 88.0;
}

class AppTheme {
  static ThemeData get light => ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: AppColors.canvasTop,
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppColors.brand,
          primary: AppColors.brand,
          surface: AppColors.surface,
        ),
        splashFactory: InkRipple.splashFactory,
      );
}
