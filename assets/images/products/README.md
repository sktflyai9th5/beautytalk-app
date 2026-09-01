# 제품 샘플 사진

결과 화면에 띄우는 **클래스별 대표 사진**이다. 찍은 사진 대신 이걸 보여 준다 —
찍은 사진은 손·배경·그림자가 섞여 있어서 "이게 무슨 제품인지" 를 알려 주는
그림으로는 오히려 방해가 된다.

파일 이름은 `assets/models/labels.txt` 의 클래스 이름에서 **빈칸을 밑줄로**
바꾼 것이다. 확장자는 `.jpg`.

다만 여러 클래스가 한 장을 나눠 쓰는 경우가 있다 (`coral.dart` 의 `_sampleAlias`):

    lip.jpg          <- lip balm · lip gloss · lip liner · lipstick · tint
    foundation.jpg   <- base_skincare

립 계열은 병 모양이 사실상 같아서 종류마다 따로 찍어도 화면에서 구분이 안 되고,
이름은 어차피 사진 밑에 글자로 적힌다.

지금 들어 있는 것: `lip.jpg` · `foundation.jpg` · `concealer.jpg` · `mascara.jpg`

    base_skincare.jpg      beauty_blender.jpg    blush.jpg
    bronzer.jpg            brush.jpg             concealer.jpg
    eyelash_item.jpg       eye_liner.jpg         eye_shade.jpg
    highlighter.jpg        lip_balm.jpg          lip_gloss.jpg
    lip_liner.jpg          lipstick.jpg          mascara.jpg
    nail_polish.jpg        nail_polish_remover.jpg
    powder.jpg             tint.jpg

권장: 정사각형에 가깝게, 배경은 단색(흰색·아주 옅은 회색), 제품 하나만.
없는 클래스는 **찍은 사진으로 자동으로 되돌아간다** — 있는 것부터 넣으면 된다.
