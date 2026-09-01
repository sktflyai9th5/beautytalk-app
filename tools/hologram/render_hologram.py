"""스캔한 얼굴 메시를 회전하는 홀로그램 와이어프레임 PNG 시퀀스로 렌더한다.

Blender 헤드리스 전용. 직접 실행하지 말고 build.ps1 을 통해 부른다.

    blender --background --factory-startup --python render_hologram.py -- --out <dir> [옵션]

메시를 주지 않으면 Blender 내장 Suzanne 으로 렌더한다 —
실제 얼굴 스캔이 나오기 전에 앱 쪽 작업을 막지 않으려는 자리 표시용이다.

알파는 렌더 결과의 밝기에서 뽑는다. 투명 배경에 글로우를 그대로 얹으면
빛 번짐이 실루엣에서 잘려나가는데, 밝기를 알파로 쓰면 번짐이 자연스럽게
옅어지면서 어떤 배경 위에 올려도 합성이 깨지지 않는다.
"""

import argparse
import json
import math
import os
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector

# -- 뒤의 인자만 우리 것이다. Blender 가 앞부분을 가져간다.
_argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []

parser = argparse.ArgumentParser()
parser.add_argument("--mesh", default=None,
                    help="obj/glb/ply/fbx/json 경로. 없으면 Suzanne")
parser.add_argument("--sweep", type=float, default=0.0,
                    help="0 이면 한 바퀴, 값을 주면 그 각도(도)만큼 좌우로 훑는다")
parser.add_argument("--out", required=True, help="PNG 시퀀스를 쓸 디렉터리")
parser.add_argument("--frames", type=int, default=96, help="한 바퀴를 몇 장으로 쪼갤지")
parser.add_argument("--res", type=int, default=512, help="정사각 해상도")
parser.add_argument("--faces", type=int, default=1600, help="리토폴로지 목표 쿼드 수")
parser.add_argument("--color", default="00E5FF", help="와이어 색 (hex)")
parser.add_argument("--bg", default="000000",
                    help="배경색 (hex). 밝은 배경에 얹을 거면 흰색으로 굽는다")
parser.add_argument("--emit", type=float, default=1.35,
                    help="와이어 발광 세기. 밝은 배경용이면 1.0 (색 그대로 나온다)")
parser.add_argument("--shell-tint", default="E4F4FA",
                    help="아바타 표면 색 (hex). 배경보다 살짝 어두워야 면이 보인다")
parser.add_argument("--head", action="store_true",
                    help="얼굴 껍데기의 열린 뒤쪽을 닫아 머리(아바타)로 만든다")
parser.add_argument("--head-mesh", default=None,
                    help="실루엣으로 깎은 **실제 머리** (fit_head.py 가 낸 PLY). "
                         "주면 뒤통수를 지어내는 대신 이걸 붙인다")
parser.add_argument("--head-texture", default=None,
                    help="머리에 입힐 텍스처 (bake_head_texture.py 가 구운 PNG). "
                         "OBJ 로 준 머리에만 쓴다 — UV 가 있어야 한다")
parser.add_argument("--head-fade", type=float, nargs=2, default=None,
                    metavar=("LO", "HI"),
                    help="머리 아래쪽을 흐린다. LO 아래는 완전히 투명, HI 위는 "
                         "그대로 (아바타 좌표계의 Z). 깎기가 턱 밑에서 끊겨서 "
                         "생기는 **잘린 단면**을 감춘다")
parser.add_argument("--head-faces", type=int, default=1400,
                    help="깎아낸 머리를 이 면 수까지 줄인다. 복셀에서 나온 "
                         "십만 면짜리를 그대로 두면 격자가 천 조각처럼 보인다")
parser.add_argument("--head-smooth", type=int, default=12,
                    help="깎아낸 머리를 몇 번 문질러 계단을 지울지")
parser.add_argument("--head-depth", type=float, default=1.05,
                    help="뒤통수 깊이 (얼굴 크기 대비)")
parser.add_argument("--head-rings", type=int, default=6,
                    help="뒤통수를 몇 겹으로 쌓을지. 많을수록 매끈하다")
parser.add_argument("--head-cap", type=float, default=1.0,
                    help="맨 뒤 꼭지점 위치 (깊이 대비)")
parser.add_argument("--head-round", type=float, default=0.45,
                    help="뒤통수 둥글기. 1 이면 원뿔, 작을수록 둥글다")
parser.add_argument("--line-lift", type=float, default=0.012,
                    help="선을 표면에서 카메라 쪽으로 띄우는 거리")
parser.add_argument("--head-swell", type=float, default=0.55,
                    help="두개골이 얼굴보다 얼마나 넓어질지. 0 이면 안 보인다")
parser.add_argument("--texture-wash", type=float, default=0.0,
                    help="사진을 흰색 쪽으로 얼마나 띄울지 0~1. "
                         "살결이 진하면 그 위의 선이 묻혀서 안 보인다")
parser.add_argument("--zones", default=None,
                    help="부위를 짚을 mediapipe 정점 번호를 이름과 함께. "
                         "예: '이마=151,눈썹=105'. 매 프레임 화면 위치를 재서 "
                         "json 으로 남긴다 — 얼굴이 돌면 짚는 점도 같이 돈다")
parser.add_argument("--lines-front", action="store_true",
                    help="선·점을 얼굴 뒤에 가리지 않고 항상 앞에 그린다. "
                         "한 장을 두 번 렌더해서 나중에 겹친다 (compose.py)")
parser.add_argument("--line-swell", type=float, default=0.0,
                    help="선을 머리 중심에서 바깥으로 밀어내는 비율. "
                         "--line-lift 는 카메라 쪽으로만 밀어서 옆면에서는 안 듣는다")
parser.add_argument("--texture", default=None,
                    help="얼굴에 입힐 사진. UV 는 격자의 화면 좌표를 그대로 쓴다")
parser.add_argument("--film-alpha", action="store_true",
                    help="배경을 투명하게 렌더하고 색을 그대로 남긴다 (사진 텍스처용)")
parser.add_argument("--scan", action="store_true",
                    help="위아래로 지나가는 스캔면을 넣는다")
parser.add_argument("--scan-color", default="21C7EE", help="스캔면 색 (hex)")
parser.add_argument("--scan-thickness", type=float, default=0.02,
                    help="스캔선 두께. 얇을수록 선으로 읽힌다")
parser.add_argument("--scan-size", type=float, default=2.4,
                    help="스캔면 크기. 머리보다 조금만 크게 잡는다")
parser.add_argument("--scan-halo", type=float, default=0.0,
                    help="스캔선 뒤에 까는 테의 진하기 0~1")
parser.add_argument("--scan-halo-color", default="FFFFFF",
                    help="스캔선 테 색 (hex). 흰 스캔선에는 어두운 테라야 보인다")
parser.add_argument("--scan-alpha", type=float, default=0.85,
                    help="스캔선 불투명도. 선은 또렷해야 읽힌다")
parser.add_argument("--scan-cycles", type=float, default=1.0,
                    help="한 루프에서 위아래로 몇 번 훑을지")
parser.add_argument("--head-wire", default="8FC4DA",
                    help="아바타 전체를 두르는 옅은 격자 색 (hex)")
parser.add_argument("--bare-face", action="store_true",
                    help="**사진 얼굴 면을 안 그린다.** 얼굴 격자는 선과 점, 그리고 "
                         "부위 위치를 잡는 데만 쓰고 표면은 머리 메시가 통째로 "
                         "맡는다. 사진 한 장을 머리 앞에 덧대면 사진이 끝나는 자리에 "
                         "경계선이 남고 그 뒤로 머리 텍스처의 귀가 하나 더 겹쳐 "
                         "보인다 — 얼굴과 머리가 한 메시면 그 선이 아예 없다")
parser.add_argument("--no-head-wire", action="store_true",
                    help="머리에 격자를 두르지 않는다. 지어낸 뒤통수에는 부피를 "
                         "읽히려고 필요했지만, 사진 색이 입혀진 실제 머리 위에 "
                         "얹으면 **가발 망**처럼 보인다")
parser.add_argument("--head-wire-scale", type=float, default=0.9,
                    help="아바타 격자 굵기 (얼굴 마스크 대비)")
parser.add_argument("--head-wire-blocks", type=int, default=0,
                    help="머리 격자를 **복셀**로 각지게 짓는다 (옥트리 깊이). "
                         "4 면 한 변 16칸, 5 면 32칸. 0 이면 안 쓰고 "
                         "--head-wire-faces 로 줄인다")
parser.add_argument("--head-wire-lift", type=float, default=0.0,
                    help="머리 격자를 표면에서 이만큼 띄운다 (얼굴 반지름 1 기준). "
                         "0 이면 표면에 붙어 머리 요철에 반쯤 파묻힌다")
parser.add_argument("--head-wire-faces", type=int, default=0,
                    help="머리 격자를 이 면 수로 줄인 뒤에 두른다. 0 이면 안 줄인다. "
                         "밀집 복원 머리는 면이 3만 장이라 그대로 두르면 격자가 "
                         "아니라 **흰 천**이 된다 — 눈에 코 하나 크기의 그물이 "
                         "보이려면 천 장 언저리로 줄여야 한다. 머리 표면(사진)은 "
                         "그대로 두고 **격자 사본만** 줄이므로 텍스처는 안 상한다")
parser.add_argument("--thickness", type=float, default=0.006, help="와이어 두께")
parser.add_argument("--dots", action="store_true", help="고른 정점에 하이라이트 찍기")
parser.add_argument("--dot-scale", type=float, default=3.4,
                    help="하이라이트 크기 (선 두께 대비)")
parser.add_argument("--dot-color", default="0B5E74",
                    help="하이라이트 색 (hex). 밝은 배경용이면 선보다 진하게")
parser.add_argument("--no-shell", action="store_true", help="내부 면 글로우 끄기")
parser.add_argument("--tilt", type=float, default=8.0, help="카메라 내려보는 각도(도)")
parser.add_argument("--dist", type=float, default=4.2, help="카메라 거리 (작을수록 크게)")
parser.add_argument("--bounds", default=None,
                    help="head_bounds.py 가 만든 json. 사진측량 메시를 세우고 자른다")
args = parser.parse_args(_argv)


def hex_to_linear(hex_str):
    """sRGB hex -> Blender 가 쓰는 선형 RGB."""
    hex_str = hex_str.lstrip("#")
    out = []
    for i in (0, 2, 4):
        c = int(hex_str[i:i + 2], 16) / 255.0
        out.append(c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4)
    return (out[0], out[1], out[2], 1.0)


def srgb_to_linear(c):
    """0~1 sRGB 한 채널을 Blender 가 쓰는 선형 값으로.

    정점 색을 이 변환 없이 넣으면 **화면에서 두 배로 밝아진다.** Blender 는
    BYTE_COLOR 에 넣는 값을 선형으로 보고 sRGB 로 저장했다가 셰이더에서 도로
    선형으로 읽는데, sRGB 값을 그대로 넣으면 그 왕복에서 한 번 밝아진 채로
    남는다. 실제로 머리카락(어두운 색)이 회색 수영모처럼 나왔다.
    """
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


WIRE_RGBA = hex_to_linear(args.color)


# ---------------------------------------------------------------- 씬 초기화

def reset_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    # use_nodes 는 건드리지 않는다. 5.x 부터 node_tree 가 기본으로 있고,
    # 대입하면 6.0 제거 예정 경고를 stderr 로 뱉는다 — PowerShell 이 그걸
    # 에러로 감싸는 바람에 빌드가 통째로 죽는다.
    world = bpy.data.worlds.new("holo_world")
    background = world.node_tree.nodes["Background"]
    background.inputs[0].default_value = hex_to_linear(args.bg)
    # 검은 배경이면 세기 0 으로 완전히 눌러 버린다. 밝은 배경은 그 색이
    # 그대로 찍혀야 하므로 1 로 둔다.
    background.inputs[1].default_value = 0.0 if args.bg.lstrip("#") == "000000" else 1.0
    scene.world = world
    return scene


# ---------------------------------------------------------------- 메시 확보

def read_ascii_ply(path):
    """fit_head.py 가 쓴 ascii PLY 를 읽는다 (정점, 면, 색).

    색은 있을 수도 없을 수도 있다 — color_head.py 를 거쳤으면 정점마다
    머리카락 색이 들어 있다.
    """
    with open(path, "r", encoding="utf-8") as fp:
        counts, current, props = {}, None, []
        while True:
            line = fp.readline()
            if not line:
                raise SystemExit(f"헤더가 끝나기 전에 파일이 끝났다: {path}")
            line = line.strip()
            if line.startswith("element"):
                _, name, count = line.split()[:3]
                counts[name] = int(count)
                current = name
            elif line.startswith("property") and current == "vertex":
                props.append(line.split()[2])
            elif line == "end_header":
                break

        has_color = {"red", "green", "blue"} <= set(props)
        verts, colors = [], []
        for _ in range(counts.get("vertex", 0)):
            row = fp.readline().split()
            verts.append(tuple(float(v) for v in row[:3]))
            if has_color:
                colors.append(tuple(
                    int(float(row[props.index(c)])) / 255.0
                    for c in ("red", "green", "blue")))
        faces = []
        for _ in range(counts.get("face", 0)):
            parts = [int(v) for v in fp.readline().split()]
            faces.append(tuple(parts[1:1 + parts[0]]))
    return verts, faces, (colors if has_color else None)


def read_obj_uv(path):
    """prep_head.py 가 낸 OBJ 에서 (정점, UV, 삼각형) 을 읽는다.

    삼각형은 (정점번호, UV번호) 쌍으로 들고 있는다 — 한 정점이 UV 조각마다
    다른 자리를 갖기 때문에 정점 하나에 UV 하나로 접으면 조각이 뭉개진다.
    """
    verts, uvs, faces = [], [], []
    with open(path, "r", encoding="utf-8") as fp:
        for line in fp:
            if line.startswith("v "):
                verts.append(tuple(float(v) for v in line.split()[1:4]))
            elif line.startswith("vt "):
                uvs.append(tuple(float(v) for v in line.split()[1:3]))
            elif line.startswith("f "):
                corners = []
                for chunk in line.split()[1:]:
                    part = chunk.split("/")
                    vi = int(part[0]) - 1
                    ti = int(part[1]) - 1 if len(part) > 1 and part[1] else -1
                    corners.append((vi, ti))
                for i in range(1, len(corners) - 1):
                    faces.append((corners[0], corners[i], corners[i + 1]))
    return verts, uvs, faces


def reduce_wire(wire, target, lift, face_box=None):
    """머리 격자를 **고른 삼각형**으로 줄인다.

    밀집 복원 머리는 면이 3만 장이라 그대로 두르면 격자가 아니라 흰 천이 된다.
    그런데 그냥 줄이기만 하면 못 쓴다 — 여기서 두 번 헛디뎠다.

    - 데시메이트는 **바늘처럼 가는 삼각형**을 남긴다. 그 위에 「Even Thickness」
      로 선을 두르면 뾰족한 꼭짓점마다 선이 밖으로 늘어나 **별처럼 뻗친 가시**가
      선다 (머리에 흰 생채기가 난 것처럼 보였다).
    - 그렇다고 Even Thickness 를 끄면 비스듬한 면에서 선이 종잇장처럼 얇아져
      **토막토막 끊긴다** — 격자가 아니라 흩뿌린 부스러기가 된다.

    고칠 자리는 선이 아니라 **면**이다. 줄인 뒤에 겹친 점을 녹이고 삼각형을
    다시 이어(`beautify_fill`) 모양을 고르게 만들면, 가시가 설 뾰족한 각이
    애초에 생기지 않는다.

    그리고 **띄운다** ([lift]). 이게 없으면 위 두 가지를 다 해도 격자가
    토막난다 — 문지른 사본은 울퉁불퉁한 원래 표면보다 안쪽으로 내려앉아서,
    머리 밖으로 삐져나온 조각만 보이기 때문이다. 법선 방향으로 조금 밀어
    머리 위에 얹으면 한 겹으로 이어져 보인다.
    """
    calm = wire.modifiers.new("smooth", "SMOOTH")
    calm.factor = 0.6
    # 요철만 죽인다. 세게 문지르면 머리가 쪼그라들어 격자가 표면 안쪽으로
    # 파묻힌다 — 가시를 잡으려고 16까지 올렸던 값인데, 관으로 바꾼 뒤로는
    # 가시가 안 생기므로 되돌린다.
    calm.iterations = 6
    thin = wire.modifiers.new("decimate", "DECIMATE")
    thin.ratio = target / len(wire.data.polygons)

    depsgraph = bpy.context.evaluated_depsgraph_get()
    baked = bpy.data.meshes.new_from_object(wire.evaluated_get(depsgraph))
    wire.modifiers.clear()
    wire.data = baked

    bm = bmesh.new()
    bm.from_mesh(baked)
    bmesh.ops.remove_doubles(bm, verts=bm.verts[:], dist=1e-4)
    bmesh.ops.dissolve_degenerate(bm, dist=1e-4, edges=bm.edges[:])
    bmesh.ops.triangulate(bm, faces=bm.faces[:])
    bmesh.ops.beautify_fill(bm, faces=bm.faces[:], edges=bm.edges[:])

    if lift:
        # **머리 중심에서 바깥으로 밀어 케이지로 띄운다.**
        #
        # 여기서 세 번 헛디뎠다. 격자를 머리 표면에 붙여 두면 — 법선으로
        # 밀든, 셰이더랩으로 표면을 따라가게 하든 — 반드시 어딘가는 살에
        # 잠긴다. 밀집 복원한 머리카락은 요철이 굵고 들쭉날쭉해서, 잠긴
        # 자리의 선은 사라지고 삐져나온 정점 언저리만 남아 **점에서 뻗어
        # 나온 별**이 곳곳에 생긴다 (셰이더랩은 표면 법선이 곳곳에서
        # 뒤집혀 있어 안쪽으로 미는 자리까지 있었다).
        #
        # 표면에 붙이려는 것 자체를 그만뒀다. 머리를 감싸는 **케이지**로
        # 띄우면 요철에 걸릴 일이 없어 한 겹으로 이어지고, 실루엣 밖으로
        # 살짝 나온 테두리가 오히려 "스캔하는 중" 으로 읽힌다.
        mid = Vector((0, 0, 0))
        for v in bm.verts:
            mid += v.co
        mid /= max(len(bm.verts), 1)
        for v in bm.verts:
            away = v.co - mid
            if away.length > 1e-6:
                v.co += away.normalized() * lift

    if face_box is not None:
        # **얼굴 앞을 지나는 조각만 걷어낸다.**
        #
        # 선을 적게 두면서 끊기지 않으려면 케이지를 넉넉히 띄워야 하는데
        # (성기게 두면 머리 요철에 잠겨 토막난다), 그러면 앞쪽 절반이 얼굴
        # 사진 **앞으로** 나와 이목구비를 가로지른다. 그 자리는 어차피 얼굴
        # 격자가 맡고 있으므로 지운다.
        #
        # 얼굴 상자 **안**이면서 얼굴보다 앞인 것만 지운다. 그 밖(머리카락이
        # 있는 옆·위)은 앞쪽이라도 남겨야 실루엣을 두르는 테가 살아 있다.
        x0, x1, z0, z1, mid_y = face_box
        ahead = [v for v in bm.verts
                 if v.co.y < mid_y and x0 <= v.co.x <= x1 and z0 <= v.co.z <= z1]
        if ahead:
            bmesh.ops.delete(bm, geom=ahead, context="VERTS")

    bm.to_mesh(baked)
    bm.free()
    baked.update()


def blockify_wire(wire, depth, lift, face_box=None):
    """머리 격자를 **복셀로 각지게** 다시 짓는다 (레고 느낌).

    복원한 머리를 그냥 줄여서 두르면 끝내 못 쓴다. 유기체 표면을 데시메이트
    하면 삼각형 모양이 제각각이라, 성기게 두면 요철에 잠겨 **토막나고**
    촘촘히 두면 선이 수백 개인 **그물망**이 된다. 그 사이가 없다.

    복셀은 그 둘을 한 번에 푼다. 격자가 축에 정렬된 **정사각형 한 종류**라
    선이 규칙적으로 이어지고, 칸 수(=`depth`)로 개수를 정확히 정할 수 있고,
    무엇보다 각진 계단 모양 자체가 "스캔해서 만든 것" 으로 읽힌다.

    `depth` 는 옥트리 깊이다 — 4 면 한 변 16칸, 5 면 32칸.
    """
    rm = wire.modifiers.new("remesh", "REMESH")
    rm.mode = "BLOCKS"
    rm.octree_depth = depth
    rm.use_remove_disconnected = False

    depsgraph = bpy.context.evaluated_depsgraph_get()
    baked = bpy.data.meshes.new_from_object(wire.evaluated_get(depsgraph))
    wire.modifiers.clear()
    wire.data = baked

    bm = bmesh.new()
    bm.from_mesh(baked)
    if lift:
        # 복셀 면은 원래 표면보다 안쪽에 놓이기도 한다. 중심에서 바깥으로
        # 조금 밀어 머리 위에 얹는다.
        mid = Vector((0, 0, 0))
        for v in bm.verts:
            mid += v.co
        mid /= max(len(bm.verts), 1)
        for v in bm.verts:
            away = v.co - mid
            if away.length > 1e-6:
                v.co += away.normalized() * lift
    if face_box is not None:
        # 얼굴 사진 앞을 지나는 칸만 걷어낸다. 그 자리는 얼굴 격자가 맡는다.
        x0, x1, z0, z1, mid_y = face_box
        ahead = [v for v in bm.verts
                 if v.co.y < mid_y and x0 <= v.co.x <= x1 and z0 <= v.co.z <= z1]
        if ahead:
            bmesh.ops.delete(bm, geom=ahead, context="VERTS")
    bm.to_mesh(baked)
    bm.free()
    baked.update()


def tube_edges(obj, radius):
    """면을 지우고 남은 엣지를 **둥근 관**으로 바꾼다.

    Wireframe 모디파이어는 *면을 밀어* 선을 만든다. 줄인 유기체 메시에는
    가느다란 삼각형이 섞여 있어서, 두께를 고르게 맞추면 뾰족한 꼭짓점마다
    선이 밖으로 뻗쳐 **가시**가 서고, 안 맞추면 비스듬한 면에서 **종잇장처럼
    얇아져 끊긴다.** 둘 다 그 방식의 성질이라 값으로는 못 피한다.

    얼굴 격자는 처음부터 이 방법을 쓴다 — 엣지를 커브로 바꿔 관을 씌우면
    선 하나하나가 독립된 원기둥이라 보는 각도와 무관하게 굵기가 같다.
    머리 격자도 같은 방법을 써야 두 격자가 한 벌로 보인다.
    """
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bmesh.ops.delete(bm, geom=bm.faces[:], context="FACES_ONLY")
    bm.to_mesh(obj.data)
    bm.free()
    obj.data.update()

    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.convert(target="CURVE")
    tube = bpy.context.view_layer.objects.active
    tube.data.bevel_depth = radius
    tube.data.bevel_resolution = 1
    tube.data.fill_mode = "FULL"
    tube.data.use_fill_caps = True
    return tube


def append_textured_hull(obj, path):
    """UV 를 편 머리(OBJ)를 얼굴 격자에 이어 붙인다.

    UV 는 얼굴이 쓰는 층에 **그대로 얹는다.** UV 는 면의 꼭짓점마다 하나씩
    붙는 값이라, 얼굴 쪽 꼭짓점은 사진 좌표를 그대로 두고 머리 쪽만 텍스처
    좌표를 넣으면 재질만 갈라 주면 된다.
    """
    verts, uvs, faces = read_obj_uv(path)
    if not faces:
        raise SystemExit(f"머리 OBJ 에 면이 없다: {path}")

    mesh = obj.data
    offset = len(mesh.vertices)
    bm = bmesh.new()
    bm.from_mesh(mesh)
    added = [bm.verts.new(v) for v in verts]
    bm.verts.ensure_lookup_table()
    made = 0
    for tri in faces:
        try:
            bm.faces.new([added[c[0]] for c in tri])
            made += 1
        except ValueError:
            pass
    bm.to_mesh(mesh)
    bm.free()
    mesh.update()

    # 붙인 면의 꼭짓점마다 UV 를 적는다. bmesh 는 면을 뒤에 이어 붙이므로
    # 얼굴 면 개수 뒤부터가 머리다.
    layer = mesh.uv_layers.active or mesh.uv_layers.new(name="face")
    head_polys = [p for p in mesh.polygons
                  if all(v >= offset for v in p.vertices)]
    lookup = {}
    for tri in faces:
        key = tuple(sorted(c[0] + offset for c in tri))
        lookup[key] = tri
    written = 0
    for poly in head_polys:
        tri = lookup.get(tuple(sorted(poly.vertices)))
        if tri is None:
            continue
        by_vertex = {c[0] + offset: c[1] for c in tri}
        for loop_index in poly.loop_indices:
            ti = by_vertex.get(mesh.loops[loop_index].vertex_index, -1)
            if 0 <= ti < len(uvs):
                layer.data[loop_index].uv = uvs[ti]
                written += 1

    print(f"[holo] 머리(UV) 붙임: 면 {made} / UV {written}개 "
          f"(얼굴 뒤 {offset}번부터)")


def append_hull(obj, path):
    """깎아낸 머리를 얼굴 격자와 **한 메시로** 합친다.

    따로 두면 normalize·회전·재질을 두 번 관리해야 하고 둘이 어긋나기 쉽다.
    한 메시 안에서 얼굴 면 뒤에 이어 붙이면 기존 코드가 그대로 돈다 —
    사진은 앞쪽 면에만, 격자는 뒤쪽 면에만 걸린다.
    """
    verts, faces, colors = read_ascii_ply(path)
    if not faces:
        raise SystemExit(f"머리 메시에 면이 없다: {path}")

    # 복셀에서 나온 메시라 계단이 지고 면이 십만 장이다. 문질러 계단을 지우고
    # 면을 줄인 **뒤에** 붙인다 — 그대로 두면 격자가 천 조각처럼 보이고,
    # 붙인 뒤에 줄이면 얼굴 격자까지 같이 줄어든다.
    temp_mesh = bpy.data.meshes.new("holo_head_raw")
    temp_mesh.from_pydata(verts, [], faces)
    temp_mesh.update()
    if colors:
        # 색은 **줄이기 전에** 얹어야 데시메이트가 같이 섞어 준다. 나중에
        # 얹으려 하면 정점이 이미 사라져서 번호가 안 맞는다.
        layer = temp_mesh.color_attributes.new(
            name="head", type="BYTE_COLOR", domain="CORNER")
        for loop in temp_mesh.loops:
            r, g, b = colors[loop.vertex_index]
            layer.data[loop.index].color = (srgb_to_linear(r), srgb_to_linear(g),
                                            srgb_to_linear(b), 1.0)
    temp = bpy.data.objects.new("holo_head_raw", temp_mesh)
    bpy.context.collection.objects.link(temp)

    if args.head_smooth > 0:
        smooth = temp.modifiers.new("smooth", "SMOOTH")
        smooth.factor = 0.7
        smooth.iterations = args.head_smooth
    if 0 < args.head_faces < len(faces):
        decimate = temp.modifiers.new("decimate", "DECIMATE")
        decimate.ratio = args.head_faces / len(faces)

    depsgraph = bpy.context.evaluated_depsgraph_get()
    baked = bpy.data.meshes.new_from_object(temp.evaluated_get(depsgraph))
    reduced = [tuple(v.co) for v in baked.vertices]
    reduced_faces = [tuple(p.vertices) for p in baked.polygons]
    reduced_colors = None
    if colors and baked.color_attributes:
        # 줄인 메시의 코너 색을 정점으로 되돌린다 (한 정점에 여러 코너가
        # 붙지만 같은 값이라 첫 것을 쓰면 된다).
        source = baked.color_attributes[0].data
        reduced_colors = [(1.0, 1.0, 1.0)] * len(reduced)
        for loop in baked.loops:
            c = source[loop.index].color
            reduced_colors[loop.vertex_index] = (c[0], c[1], c[2])
    bpy.data.objects.remove(temp, do_unlink=True)
    bpy.data.meshes.remove(temp_mesh)
    bpy.data.meshes.remove(baked)

    mesh = obj.data
    offset = len(mesh.vertices)
    if reduced_colors:
        # 얼굴 쪽은 사진을 입히므로 흰색으로 채워 두고, 머리 쪽만 실제 색을
        # 넣는다. 재질이 갈려 있어서 얼굴 값은 쓰이지 않는다.
        obj["holo_head_colors"] = [c for rgb in reduced_colors for c in rgb]
    bm = bmesh.new()
    bm.from_mesh(mesh)
    added = [bm.verts.new(v) for v in reduced]
    bm.verts.ensure_lookup_table()
    made = 0
    for f in reduced_faces:
        try:
            bm.faces.new([added[i] for i in f])
            made += 1
        except ValueError:
            # 같은 면이 두 번 오면 bmesh 가 거부한다. 건너뛰면 된다.
            pass
    bm.to_mesh(mesh)
    bm.free()
    mesh.update()

    if reduced_colors:
        # 합친 메시에 색을 다시 얹는다. 얼굴 쪽 정점은 흰색으로 둔다 —
        # 거기는 사진 재질이라 이 값을 안 본다.
        layer = mesh.color_attributes.get("head")
        if layer is None:
            layer = mesh.color_attributes.new(
                name="head", type="BYTE_COLOR", domain="CORNER")
        for loop in mesh.loops:
            i = loop.vertex_index - offset
            if 0 <= i < len(reduced_colors):
                r, g, b = reduced_colors[i]
            else:
                r = g = b = 1.0
            layer.data[loop.index].color = (r, g, b, 1.0)

    print(f"[holo] 깎아낸 머리 붙임: 면 {len(faces)} -> {made} "
          f"(얼굴 뒤 {offset}번부터)"
          + (" / 사진 색 입힘" if reduced_colors else ""))


def import_face_json(path):
    """face_to_mesh.py 가 뽑은 얼굴 격자를 그대로 메시로 만든다.

    면 없이 정점과 엣지만 있다. 격자가 이미 반듯해서 리토폴로지가 필요 없고,
    엣지가 곧 그리려는 선이라 중간 변환을 하나도 안 거친다.
    """
    with open(path, "r", encoding="utf-8") as fp:
        payload = json.load(fp)

    # 성근 격자 + 이목구비 윤곽. 윤곽이 없으면 눈·입이 사라져서
    # 돌려 봐도 누구 얼굴인지 알 수 없다.
    faces = [tuple(f) for f in payload.get("faces", [])]
    contours = {tuple(sorted(e)) for e in payload.get("contours", [])}
    lines = {tuple(sorted(e)) for e in payload["edges"]}
    # 면이 만드는 변은 빼 준다. from_pydata 에 둘 다 주면 같은 변이 겹쳐 생긴다.
    for f in faces:
        for a, b in zip(f, f[1:] + f[:1]):
            lines.discard((min(a, b), max(a, b)))

    mesh = bpy.data.meshes.new("face_mesh")
    mesh.from_pydata([tuple(v) for v in payload["vertices"]], sorted(lines), faces)
    mesh.update()

    # 화면 좌표를 그대로 UV 로 쓴다. mediapipe 가 낸 2D 위치가 곧 사진 안에서의
    # 자리라서, 원본 프레임을 그대로 입히면 정확히 얼굴에 맞는다.
    # Blender 의 V 는 아래에서 위로 세므로 뒤집는다.
    flat_uv = payload.get("points_2d") or []
    if flat_uv:
        layer = mesh.uv_layers.new(name="face")
        for loop in mesh.loops:
            u, v = flat_uv[loop.vertex_index]
            layer.data[loop.index].uv = (u, 1.0 - v)

    obj = bpy.data.objects.new("face_mesh", mesh)
    bpy.context.collection.objects.link(obj)
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)

    # 실루엣으로 깎은 머리를 **여기서** 이어 붙인다. 뒤(build_hologram)에서
    # 붙이면 그 전에 normalize 가 얼굴만 보고 크기를 정해서 둘이 어긋난다.
    # 얼굴 면 개수를 남겨 두면 그 뒤 면들은 뒤통수로 취급된다 (재질·격자).
    obj["holo_face_polys"] = 0 if args.bare_face else len(mesh.polygons)
    if args.bare_face:
        # 얼굴 면을 지운다. 선과 점은 엣지에서 뽑으므로 그대로 남는다.
        mesh.polygons.foreach_set("select", [True] * len(mesh.polygons))
        bm = bmesh.new()
        bm.from_mesh(mesh)
        bmesh.ops.delete(bm, geom=list(bm.faces), context="FACES_ONLY")
        bm.to_mesh(mesh)
        bm.free()
        mesh.update()
        print(f"[holo] 사진 얼굴 면을 뺐다 — 표면은 머리 메시가 맡는다")
    if args.head_mesh:
        if os.path.splitext(args.head_mesh)[1].lower() == ".obj":
            append_textured_hull(obj, args.head_mesh)
        else:
            append_hull(obj, args.head_mesh)
    # 이 격자는 이미 다듬어져 있다. 리토폴로지를 돌리면 도로 잘게 쪼개진다.
    obj["holo_prepared"] = True
    # 이목구비 윤곽은 격자와 **따로** 들고 있다가 더 굵게 뽑는다. 같은 굵기로
    # 그리면 성근 격자에 묻혀서 돌려 봐도 누구 얼굴인지 알 수 없다.
    # 커스텀 속성은 평평한 정수 목록만 담을 수 있어 (a,b) 를 풀어서 넣는다.
    obj["holo_contours"] = [i for e in sorted(contours) for i in e]
    # 그릴 선은 **여기 적힌 것만** 이다. 메시에서 면을 지우고 남은 변을 쓰면
    # 표면 삼각형의 변까지 딸려 들어와 얼굴이 그물로 덮인다.
    obj["holo_lines"] = [i for e in payload["edges"] for i in e]
    # 하이라이트로 찍을 정점. 2D 오버레이가 쓰는 목록과 같아야 이어져 보인다.
    obj["holo_highlights"] = list(payload.get("highlights", []))
    # 성근 격자의 삼각형. 결과 화면에서 부위를 삼각형 모양으로 밝힌다.
    obj["holo_line_faces"] = [i for f in payload.get("line_faces", []) for i in f]
    print(f"[holo] 얼굴 격자: 정점 {len(mesh.vertices)} / 엣지 {len(mesh.edges)}"
          f" / 면 {len(mesh.polygons)} (출처 {payload.get('source_frame', '?')})")
    return obj


def import_mesh(path):
    ext = os.path.splitext(path)[1].lower()
    if ext == ".json":
        return import_face_json(path)

    before = set(bpy.data.objects)

    if ext == ".obj":
        bpy.ops.wm.obj_import(filepath=path)
    elif ext in (".glb", ".gltf"):
        bpy.ops.import_scene.gltf(filepath=path)
    elif ext == ".ply":
        bpy.ops.wm.ply_import(filepath=path)
    elif ext == ".stl":
        bpy.ops.wm.stl_import(filepath=path)
    elif ext == ".fbx":
        # 5.x 에서 오퍼레이터 이름이 옮겨다녀서 둘 다 시도한다.
        if hasattr(bpy.ops.wm, "fbx_import"):
            bpy.ops.wm.fbx_import(filepath=path)
        else:
            bpy.ops.import_scene.fbx(filepath=path)
    else:
        raise SystemExit(f"지원하지 않는 형식이다: {ext}")

    new_meshes = [o for o in set(bpy.data.objects) - before if o.type == "MESH"]
    if not new_meshes:
        raise SystemExit(f"메시를 못 찾았다: {path}")

    # 스캔 결과가 여러 조각으로 쪼개져 오는 일이 흔하다. 하나로 합친다.
    for obj in bpy.data.objects:
        obj.select_set(obj in new_meshes)
    bpy.context.view_layer.objects.active = new_meshes[0]
    if len(new_meshes) > 1:
        bpy.ops.object.join()
    return bpy.context.view_layer.objects.active


def make_placeholder():
    bpy.ops.mesh.primitive_monkey_add(size=2.0)
    obj = bpy.context.active_object
    obj.name = "placeholder_head"
    return obj


# ---------------------------------------------------------------- 메시 정리

def close_back(obj, rings, depth, cap):
    """얼굴 껍데기의 열린 뒤쪽을 닫아 **머리**로 만든다.

    mediapipe 격자는 얼굴 앞면만 있는 껍데기다. 그대로 돌리면 아바타가 아니라
    가면이 누워 있는 것으로 보인다. 테두리를 뒤로 밀면서 좁혀 반구를 만들어
    붙이면 그 순간 머리로 읽힌다.

    고리를 쌓을 때 뒤로 미는 거리는 sin, 반지름은 cos 의 거듭제곱에 중간이
    부푸는 항을 더해 정한다.

    **중간에서 얼굴보다 넓어져야 한다.** 반지름이 1 을 넘지 않으면 두개골이
    얼굴 윤곽 뒤에 통째로 가려서, 아무리 돌려도 머리가 안 보이고 가면으로만
    보인다. 실제 머리도 관자놀이 뒤쪽이 얼굴보다 넓다.
    """
    def radius(a):
        return (math.cos(a) ** args.head_round
                + args.head_swell * math.sin(2 * a) * 0.5)

    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bm.edges.ensure_lookup_table()

    boundary = [e for e in bm.edges if e.is_boundary]
    if not boundary:
        bm.free()
        return obj

    ring_verts = {v for e in boundary for v in e.verts}
    center = Vector((0.0, 0.0, 0.0))
    for v in ring_verts:
        center += v.co
    center /= len(ring_verts)

    # 얼굴은 -Y 를 보고 있다. 뒤통수는 +Y 쪽이다.
    current = boundary
    for i in range(rings):
        a0 = math.pi / 2 * i / rings
        a1 = math.pi / 2 * (i + 1) / rings
        shrink = radius(a1) / max(radius(a0), 1e-4)
        push = depth * (math.sin(a1) - math.sin(a0))

        result = bmesh.ops.extrude_edge_only(bm, edges=current)
        made = result["geom"]
        new_verts = [g for g in made if isinstance(g, bmesh.types.BMVert)]
        for v in new_verts:
            rel = v.co - center
            v.co = Vector((
                center.x + rel.x * shrink,
                v.co.y + push,
                center.z + rel.z * shrink,
            ))
        current = [g for g in made
                   if isinstance(g, bmesh.types.BMEdge) and g.is_boundary]
        if not current:
            break

    if current:
        last = list({v for e in current for v in e.verts})
        back = Vector((center.x, center.y + depth * cap, center.z))
        bmesh.ops.pointmerge(bm, verts=last, merge_co=back)

    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    bm.to_mesh(obj.data)
    bm.free()
    obj.data.update()
    print(f"[holo] 뒤통수를 닫아 머리로 만듦 (면 {len(obj.data.polygons)})")
    return obj


def keep_largest_island(obj):
    """서로 떨어진 덩어리 중 가장 큰 것만 남긴다.

    사진측량이 복원하는 건 사람이 아니라 방이다. 구로 잘라내도 책상 모서리나
    의자 같은 조각이 반경 안에 남는데, 그것들은 머리와 이어져 있지 않다.
    """
    mesh = obj.data
    bm = bmesh.new()
    bm.from_mesh(mesh)
    bm.verts.ensure_lookup_table()

    seen = set()
    best = []
    for start in bm.verts:
        if start.index in seen:
            continue
        seen.add(start.index)
        stack = [start]
        group = []
        while stack:
            vert = stack.pop()
            group.append(vert)
            for edge in vert.link_edges:
                other = edge.other_vert(vert)
                if other.index not in seen:
                    seen.add(other.index)
                    stack.append(other)
        if len(group) > len(best):
            best = group

    if best and len(best) < len(bm.verts):
        keep = {v.index for v in best}
        bmesh.ops.delete(
            bm, geom=[v for v in bm.verts if v.index not in keep], context="VERTS")
        print(f"[holo] 떨어진 조각 정리: 정점 {len(keep)} 만 남김")

    bm.to_mesh(mesh)
    bm.free()
    mesh.update()
    return obj


def orient_and_crop(obj, bounds_path):
    """사진측량 메시를 똑바로 세우고 머리 주변만 남긴다.

    COLMAP 좌표계는 방향이 정해져 있지 않아서, 그대로 두면 머리가 비스듬히
    누운 채 아무 데나 보고 있다. head_bounds.py 가 카메라 궤도에서 구해 준
    위쪽·정면으로 회전시켜 Blender 축에 맞춘다.

    카메라는 -Y 에서 +Y 쪽을 본다. 그러니 얼굴의 정면이 -Y 를 향해야
    카메라를 마주 본다.
    """
    with open(bounds_path, "r", encoding="utf-8") as fp:
        bounds = json.load(fp)

    head = Vector(bounds["head"])
    up = Vector(bounds["up"]).normalized()
    forward = Vector(bounds["forward"])
    # 정면에서 위쪽 성분을 빼 직교시킨다. 카메라가 조금 높았어도 상관없게.
    forward = (forward - up * forward.dot(up)).normalized()
    right = forward.cross(up).normalized()

    # 각 행이 "월드 벡터를 이 축에 투영한 값" 이 되도록 짠다.
    # right -> -X, forward -> -Y, up -> +Z
    rotation = Matrix((
        (-right.x, -right.y, -right.z),
        (-forward.x, -forward.y, -forward.z),
        (up.x, up.y, up.z),
    ))

    mesh = obj.data
    for vert in mesh.vertices:
        vert.co = rotation @ (vert.co - head)
    mesh.update()

    radius = bounds["crop_radius"]
    bm = bmesh.new()
    bm.from_mesh(mesh)
    far = [v for v in bm.verts if v.co.length > radius]
    if far:
        bmesh.ops.delete(bm, geom=far, context="VERTS")
    bm.to_mesh(mesh)
    bm.free()
    mesh.update()

    print(f"[holo] 세우고 자름: 반지름 {radius:.3f}, "
          f"정점 {len(mesh.vertices)} / 면 {len(mesh.polygons)}")

    if len(mesh.polygons) > 0:
        keep_largest_island(obj)
    return obj


def normalize(obj):
    """원점 중심으로 옮기고 높이 2 에 맞춰 스케일."""
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.origin_set(type="ORIGIN_GEOMETRY", center="BOUNDS")
    obj.location = (0, 0, 0)

    dims = obj.dimensions
    longest = max(dims.x, dims.y, dims.z)
    if longest > 0:
        obj.scale = (2.0 / longest,) * 3
    bpy.ops.object.transform_apply(location=True, rotation=False, scale=True)

    # 스캔 메시는 바운딩박스 중심과 시각적 중심이 어긋나 있다. 한 번 더 맞춘다.
    bpy.ops.object.origin_set(type="ORIGIN_GEOMETRY", center="BOUNDS")
    obj.location = (0, 0, 0)
    return obj


def retopologize(obj, target_faces):
    """사진측량 결과는 수십만 폴리곤짜리 삼각형 덩어리다.

    그대로 와이어프레임을 씌우면 격자가 아니라 노이즈 얼룩으로 보인다.
    사각 격자로 다시 짜야 SF 홀로그램처럼 읽힌다.
    """
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)

    face_count = len(obj.data.polygons)
    if face_count == 0 or obj.get("holo_prepared"):
        print("[holo] 이미 다듬어진 격자 — 리토폴로지 건너뜀")
        return obj

    print(f"[holo] 원본 면 수: {face_count}")

    # QuadriFlow 는 입력이 너무 무거우면 몇 분씩 잡아먹는다. 먼저 깎아둔다.
    if face_count > 120_000:
        dec = obj.modifiers.new("pre_decimate", "DECIMATE")
        dec.ratio = 120_000 / face_count
        bpy.ops.object.modifier_apply(modifier=dec.name)
        print(f"[holo] 사전 데시메이트 -> {len(obj.data.polygons)}")

    try:
        bpy.ops.object.quadriflow_remesh(target_faces=target_faces)
        print(f"[holo] QuadriFlow -> {len(obj.data.polygons)} 쿼드")
    except Exception as exc:
        # 열린 경계가 많은 스캔에서 가끔 실패한다. 데시메이트로 물러난다.
        print(f"[holo] QuadriFlow 실패({exc}) — 데시메이트로 대체")
        current = len(obj.data.polygons)
        if current > target_faces:
            dec = obj.modifiers.new("fallback_decimate", "DECIMATE")
            dec.ratio = target_faces / current
            bpy.ops.object.modifier_apply(modifier=dec.name)
        print(f"[holo] 데시메이트 -> {len(obj.data.polygons)}")

    bpy.ops.object.shade_smooth()
    return obj


# ---------------------------------------------------------------- 재질

def emission_material(name, rgba, strength):
    mat = bpy.data.materials.new(name)
    nt = mat.node_tree
    nt.nodes.clear()

    emit = nt.nodes.new("ShaderNodeEmission")
    emit.inputs["Color"].default_value = rgba
    emit.inputs["Strength"].default_value = strength
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    nt.links.new(emit.outputs["Emission"], out.inputs["Surface"])
    return mat


def lift(obj):
    """선·점을 얼굴 표면에서 떼어 낸다.

    두 가지를 같이 쓴다. `--line-lift` 는 카메라 쪽으로 통째로 미는 것이라
    정면에서는 듣지만 볼·턱처럼 표면이 옆을 향하는 데서는 거의 안 듣는다 —
    거기서 선이 살에 묻힌다. `--line-swell` 은 머리 중심에서 바깥으로
    부풀려서 어느 면에서든 같은 만큼 떠오르게 한다.
    """
    if args.line_swell:
        k = 1.0 + args.line_swell
        obj.scale = (k, k, k)
    obj.location.y -= args.line_lift


def textured_material(name, path, fade=None):
    """사진을 그대로 발광으로 내보내는 재질.

    조명을 쓰지 않는다. 사진에 이미 빛이 들어 있어서, 다시 비추면 두 번
    밝아지고 얼굴이 떠 버린다.
    """
    mat = bpy.data.materials.new(name)
    nt = mat.node_tree
    nt.nodes.clear()

    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = bpy.data.images.load(path)
    emit = nt.nodes.new("ShaderNodeEmission")
    emit.inputs["Strength"].default_value = 1.0
    out = nt.nodes.new("ShaderNodeOutputMaterial")

    if args.texture_wash > 0:
        # 사진을 흰색 쪽으로 띄운다. 2D 화면에서 사진 위에 흰 막을 한 겹
        # 얹던 것과 같은 처리다 — 얼굴은 그대로 보이면서 그 위의 선이 읽힌다.
        # 어둡게 덮으면 얼굴이 죽고 선도 같이 묻힌다.
        #
        # ShaderNodeMix 의 A/B 는 자료형마다 같은 이름이 여러 개라 이름으로
        # 못 집는다. RGBA 는 입력 6·7, 출력 2 다.
        mix = nt.nodes.new("ShaderNodeMix")
        mix.data_type = "RGBA"
        mix.blend_type = "MIX"
        mix.inputs["Factor"].default_value = args.texture_wash
        mix.inputs[7].default_value = (1.0, 1.0, 1.0, 1.0)
        nt.links.new(tex.outputs["Color"], mix.inputs[6])
        nt.links.new(mix.outputs[2], emit.inputs["Color"])
    else:
        nt.links.new(tex.outputs["Color"], emit.inputs["Color"])

    if fade:
        # **알파 합성(BLENDED)을 쓰면 안 된다.** 깊이 정렬을 하지 않아서 닫힌
        # 머리의 안쪽 면이 앞면 위로 비쳐 조각난 것처럼 보인다. 디더링은
        # 깊이를 그대로 쓰고, 어차피 뒤에서 글로우가 번지게 하므로 점이 튀지 않는다.
        if hasattr(mat, "surface_render_method"):
            mat.surface_render_method = "DITHERED"
        fade_alpha(nt, emit.outputs["Emission"], out, fade[0], fade[1])
    else:
        nt.links.new(emit.outputs["Emission"], out.inputs["Surface"])
    return mat


def add_scan_plane(rig):
    """머리를 위아래로 훑고 지나가는 면.

    셰이더로 띠를 만드는 대신 실제 판을 통과시킨다. 머리에 가려지는 부분이
    저절로 가려져서 '면이 머리를 뚫고 지나간다' 로 읽힌다 — 화면에 그린 띠는
    앞뒤 구분이 없어 평면처럼 보인다.
    """
    # 사각 판은 각진 모서리가 얼굴 밖으로 튀어나와 "화면을 덮은 띠" 로 보인다.
    # 둥근 면을 쓰고 가장자리를 흐려야 스캔 영역으로 읽힌다.
    bpy.ops.mesh.primitive_circle_add(vertices=64, radius=args.scan_size / 2,
                                      fill_type="NGON")
    plane = bpy.context.active_object
    plane.name = "holo_scan"
    plane.data.materials.clear()
    plane.data.materials.append(scan_material("holo_scan_mat"))

    solid = plane.modifiers.new("thickness", "SOLIDIFY")
    solid.thickness = args.scan_thickness
    solid.offset = 0.0

    # 뒤에 흰 판을 한 겹 더 깐다. 어두운 스캔선 혼자로는 밝은 얼굴 위에서
    # 눈에 안 띈다 — 흰 테가 둘려야 **떠 있는 막대**로 읽히고 멀리서도 보인다.
    if args.scan_halo > 0:
        bpy.ops.mesh.primitive_circle_add(
            vertices=64, radius=args.scan_size / 2, fill_type="NGON")
        glow = bpy.context.active_object
        glow.name = "holo_scan_halo"
        glow.data.materials.clear()
        glow.data.materials.append(
            scan_material("holo_scan_halo_mat", color=args.scan_halo_color,
                          alpha=args.scan_halo))
        gs = glow.modifiers.new("thickness", "SOLIDIFY")
        # 심지보다 넉넉해야 테두리가 된다.
        gs.thickness = args.scan_thickness * 3.4
        gs.offset = 0.0
        glow.parent = plane

    # 기울기는 매 프레임 카메라를 향해 다시 잡는다 (scan_edge_on).

    # 리그에 붙이지 않는다. 붙이면 머리가 좌우로 훑을 때 판이 같이 돌아
    # 카메라에 원판 면이 그대로 보인다(선이 뭉개지는 원인이었다).
    # 안 붙여도 머리는 제자리에서 돌기만 해서 통과 위치는 그대로다.
    return plane


def scan_material(name, color=None, alpha=None):
    """스캔면. 반투명이어야 얼굴을 가리지 않고 훑고 지나가는 것으로 보인다."""
    mat = bpy.data.materials.new(name)
    nt = mat.node_tree
    nt.nodes.clear()

    emit = nt.nodes.new("ShaderNodeEmission")
    emit.inputs["Color"].default_value = hex_to_linear(color or args.scan_color)
    emit.inputs["Strength"].default_value = args.emit
    transp = nt.nodes.new("ShaderNodeBsdfTransparent")
    mix = nt.nodes.new("ShaderNodeMixShader")
    out = nt.nodes.new("ShaderNodeOutputMaterial")

    # 가운데는 진하고 가장자리로 갈수록 사라진다. 경계가 딱 끊기면
    # 원판 하나가 떠 있는 것으로 보이지 스캔 영역으로 안 읽힌다.
    # 오브젝트 좌표를 쓴다. 월드 좌표로 재면 판이 위아래로 움직일 때마다
    # 중심이 딸려 가서 흐림이 엉뚱한 데로 옮겨 간다.
    coord = nt.nodes.new("ShaderNodeTexCoord")
    dist = nt.nodes.new("ShaderNodeVectorMath")
    dist.operation = "LENGTH"
    fade = nt.nodes.new("ShaderNodeMapRange")
    fade.inputs["From Min"].default_value = args.scan_size * 0.40
    fade.inputs["From Max"].default_value = args.scan_size * 0.5
    fade.inputs["To Min"].default_value = (
        args.scan_alpha if alpha is None else alpha)
    fade.inputs["To Max"].default_value = 0.0
    fade.clamp = True

    nt.links.new(coord.outputs["Object"], dist.inputs[0])
    nt.links.new(dist.outputs["Value"], fade.inputs["Value"])
    nt.links.new(fade.outputs["Result"], mix.inputs["Fac"])
    nt.links.new(transp.outputs["BSDF"], mix.inputs[1])
    nt.links.new(emit.outputs["Emission"], mix.inputs[2])
    nt.links.new(mix.outputs["Shader"], out.inputs["Surface"])

    # 블렌드 모드 이름이 버전마다 바뀌어서 되는 걸로 하나 고른다.
    for mode in ("BLENDED", "BLEND", "HASHED"):
        try:
            mat.blend_method = mode
            break
        except (TypeError, AttributeError):
            continue
    return mat


def fade_alpha(nt, shader, out, lo, hi):
    """아래로 갈수록 투명해지게 셰이더에 알파를 물린다.

    깎아낸 머리는 턱 밑에서 끊긴다 — 그 아래 머리카락은 실루엣에서 이미
    사라져서 되살릴 수가 없다. 단면을 그대로 두면 잘린 살점처럼 보이므로,
    **홀로그램답게 흐려서** 끝낸다.
    """
    geo = nt.nodes.new("ShaderNodeNewGeometry")
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    ramp = nt.nodes.new("ShaderNodeMapRange")
    ramp.inputs[1].default_value = lo
    ramp.inputs[2].default_value = hi
    ramp.clamp = True
    transparent = nt.nodes.new("ShaderNodeBsdfTransparent")
    mix = nt.nodes.new("ShaderNodeMixShader")

    nt.links.new(geo.outputs["Position"], sep.inputs["Vector"])
    nt.links.new(sep.outputs["Z"], ramp.inputs["Value"])
    nt.links.new(transparent.outputs["BSDF"], mix.inputs[1])
    nt.links.new(shader, mix.inputs[2])
    nt.links.new(ramp.outputs["Result"], mix.inputs["Fac"])
    nt.links.new(mix.outputs["Shader"], out.inputs["Surface"])


def head_color_material(name):
    """깎아낸 머리에 **정점 색**을 그대로 쓴다.

    실루엣으로 깎은 머리를 단색으로 칠하면 하얀 수영모처럼 보인다.
    color_head.py 가 촬영본에서 읽어 온 색을 그대로 내보내면 머리카락은
    머리카락 색이 되고, 얼굴 사진과 한 사람으로 읽힌다.
    """
    mat = bpy.data.materials.new(name)
    nt = mat.node_tree
    nt.nodes.clear()

    attribute = nt.nodes.new("ShaderNodeAttribute")
    attribute.attribute_name = "head"
    emit = nt.nodes.new("ShaderNodeEmission")
    emit.inputs["Strength"].default_value = 1.0
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    nt.links.new(attribute.outputs["Color"], emit.inputs["Color"])
    nt.links.new(emit.outputs["Emission"], out.inputs["Surface"])
    return mat


def shell_material(name):
    """아바타의 표면. 평평한 한 가지 톤이다.

    선만 있으면 앞뒤가 겹쳐서 얼굴이 아니라 철사 덩어리로 보인다. 면을 아주
    옅게 채우면 그 순간 머리 형태로 읽힌다.

    프레넬로 가장자리를 밝히는 방식은 어두운 배경용이다 — 흰 바탕에서는
    가장자리가 배경 쪽으로 밝아져서 오히려 사라진다. 배경보다 조금 어두운
    평평한 톤이면 후처리에서 그만큼이 알파가 되어 은은한 면이 남는다.
    """
    mat = bpy.data.materials.new(name)
    nt = mat.node_tree
    nt.nodes.clear()

    emit = nt.nodes.new("ShaderNodeEmission")
    emit.inputs["Color"].default_value = hex_to_linear(args.shell_tint)
    emit.inputs["Strength"].default_value = 1.0
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    nt.links.new(emit.outputs["Emission"], out.inputs["Surface"])
    return mat


def fill_line_mesh(mesh, obj, pairs):
    """선 쌍만으로 메시를 채운다. **쓰는 정점만** 넣는 게 핵심이다.

    예전에는 원본의 정점을 통째로 넣고 선만 얹었다. 얼굴 격자뿐일 때는 남는
    점이 없어 문제가 안 됐는데, 깎아낸 머리를 같은 메시에 붙이자 쓰지 않는
    정점이 5만 개 딸려 들어왔다. 이 메시를 커브로 바꾸는 순간 그 외톨이
    점들이 제멋대로 이어져 **화면을 가로지르는 실**이 됐다.
    """
    used = sorted({i for pair in pairs for i in pair})
    remap = {old: new for new, old in enumerate(used)}
    coords = [obj.data.vertices[i].co.copy() for i in used]
    mesh.from_pydata(coords, [(remap[a], remap[b]) for a, b in pairs], [])
    mesh.update()


def build_hologram(obj):
    """와이어 오브젝트 + (옵션) 껍질 + (옵션) 꼭짓점 점 을 만들어 하나로 묶는다."""
    rig = bpy.data.objects.new("holo_rig", None)
    bpy.context.collection.objects.link(rig)

    has_faces = len(obj.data.polygons) > 0
    # 얼굴 격자는 면과 별개로 이목구비 윤곽선을 따로 들고 있다. Wireframe
    # 모디파이어는 면에서만 선을 뽑기 때문에 그 윤곽이 통째로 사라진다.
    # 그래서 면을 지우고 남은 엣지를 커브로 바꿔 두께를 준다.
    from_edges = obj.get("holo_prepared") or not has_faces

    # 와이어: 원본을 복제해서 선을 실제 지오메트리로 만든다.
    wire = obj.copy()
    wire.data = obj.data.copy()
    wire.name = "holo_wire"
    bpy.context.collection.objects.link(wire)

    if from_edges:
        flat_lines = list(obj.get("holo_lines") or [])
        if flat_lines:
            # 적어 둔 선만으로 새로 만든다. 표면과 선의 밀도가 다르기 때문에
            # 메시에서 면만 지우는 방식으로는 선을 골라낼 수 없다.
            pairs = [(flat_lines[i], flat_lines[i + 1])
                     for i in range(0, len(flat_lines) - 1, 2)]
            lmesh = bpy.data.meshes.new("holo_wire_mesh")
            fill_line_mesh(lmesh, obj, pairs)
            wire.data = lmesh
        elif len(wire.data.polygons) > 0:
            bm = bmesh.new()
            bm.from_mesh(wire.data)
            bmesh.ops.delete(bm, geom=bm.faces[:], context="FACES_ONLY")
            bm.to_mesh(wire.data)
            bm.free()
            wire.data.update()

        bpy.ops.object.select_all(action="DESELECT")
        wire.select_set(True)
        bpy.context.view_layer.objects.active = wire
        bpy.ops.object.convert(target="CURVE")
        wire = bpy.context.view_layer.objects.active
        wire.data.bevel_depth = args.thickness
        wire.data.bevel_resolution = 1
        wire.data.fill_mode = "FULL"
        wire.data.use_fill_caps = True
    else:
        wf = wire.modifiers.new("wireframe", "WIREFRAME")
        wf.thickness = args.thickness
        wf.use_replace = True
        wf.use_even_offset = True

    # 표면과 같은 자리에 있으면 선이 반쯤 묻힌다. 카메라 쪽(-Y)으로 조금
    # 띄워야 마스크가 얼굴 **위에** 얹힌 것으로 보인다.
    lift(wire)

    wire.data.materials.clear()
    # 톤매핑이 Standard 라 세기 1 이면 지정한 색이 화면에 그대로 찍힌다.
    # 어두운 배경용은 조금 올려 빛나게 하고, 밝은 배경용은 1 로 둬서
    # 잉크로 그린 선처럼 만든다.
    wire.data.materials.append(emission_material("holo_wire_mat", WIRE_RGBA, args.emit))
    wire.parent = rig

    # 이목구비 윤곽을 한 겹 더, 더 굵게. 격자가 성글수록 이 선들이 형태를 짊어진다.
    flat = list(obj.get("holo_contours") or [])
    if flat:
        edges = [(flat[i], flat[i + 1]) for i in range(0, len(flat) - 1, 2)]
        cmesh = bpy.data.meshes.new("holo_contour_mesh")
        fill_line_mesh(cmesh, obj, edges)
        contour = bpy.data.objects.new("holo_contour", cmesh)
        bpy.context.collection.objects.link(contour)

        bpy.ops.object.select_all(action="DESELECT")
        contour.select_set(True)
        bpy.context.view_layer.objects.active = contour
        bpy.ops.object.convert(target="CURVE")
        contour = bpy.context.view_layer.objects.active
        contour.data.bevel_depth = args.thickness * 1.9
        contour.data.bevel_resolution = 1
        contour.data.fill_mode = "FULL"
        contour.data.use_fill_caps = True
        lift(contour)
        contour.data.materials.clear()
        contour.data.materials.append(
            emission_material("holo_contour_mat", WIRE_RGBA, args.emit))
        contour.parent = rig
        print(f"[holo] 윤곽선 {len(edges)}개를 굵게 얹음")

    if args.dots:
        # 하이라이트는 고른 정점에만 심는다. 정점 전체에 심으면 얼굴이 덮인다.
        # 커브로 바뀐 와이어는 꼭짓점 인스턴싱을 못 하므로 전용 메시를 만든다.
        picked = list(obj.get("holo_highlights") or range(len(obj.data.vertices)))
        coords = [obj.data.vertices[i].co.copy()
                  for i in picked if i < len(obj.data.vertices)]

        emesh = bpy.data.meshes.new("holo_dot_mesh")
        emesh.from_pydata(coords, [], [])
        emesh.update()
        emitter = bpy.data.objects.new("holo_dot_emitter", emesh)
        bpy.context.collection.objects.link(emitter)
        lift(emitter)
        emitter.instance_type = "VERTS"
        emitter.show_instancer_for_render = False
        emitter.parent = rig

        # 하이라이트는 선보다 밝고 조금 굵다. 그래야 '짚은 자리' 로 읽힌다.
        bpy.ops.mesh.primitive_ico_sphere_add(
            subdivisions=2, radius=args.thickness * args.dot_scale)
        dot = bpy.context.active_object
        dot.name = "holo_dot"
        dot.data.materials.clear()
        dot.data.materials.append(
            emission_material("holo_dot_mat", hex_to_linear(args.dot_color), args.emit))
        dot.parent = emitter
        print(f"[holo] 하이라이트 {len(coords)}개")

    # 아바타 본체. 선만 있으면 얼굴이 아니라 철사 덩어리로 보인다.
    # 와이어·윤곽·하이라이트를 **먼저** 뽑아 둔 뒤에 뒤통수를 닫는다 —
    # 순서를 바꾸면 새로 생긴 뒤통수 변까지 마스크에 딸려 들어간다.
    if args.no_shell or not has_faces:
        bpy.data.objects.remove(obj, do_unlink=True)
    else:
        # 뒤통수는 나중에 붙는다. 사진은 얼굴 쪽 면에만 있으므로,
        # 여기서 개수를 세 뒀다가 그 뒤 면들은 단색으로 칠한다.
        # 깎아낸 머리를 붙였으면 얼굴 면은 그때 세어 둔 값이다.
        face_polys = obj.get("holo_face_polys", len(obj.data.polygons))
        if args.head or args.head_mesh:
            if not args.head_mesh:
                close_back(obj, args.head_rings, args.head_depth, args.head_cap)
            bpy.context.view_layer.objects.active = obj
            bpy.ops.object.select_all(action="DESELECT")
            obj.select_set(True)
            bpy.ops.object.shade_smooth()

            # 머리 전체에 옅은 격자를 한 겹 두른다. 뒤통수에 선이 하나도
            # 없으면 부피가 안 읽혀서 방패처럼 보인다. 얼굴 쪽 마스크보다
            # 가늘고 옅게 둬야 "아바타 위에 마스크" 로 층이 진다.
            #
            # 사진 색이 입혀진 실제 머리에는 필요 없다 — 색과 명암이 이미
            # 부피를 말해 주는데 격자까지 얹으면 가발 망을 쓴 것처럼 보인다.
            if not args.no_head_wire:
                head_wire = obj.copy()
                head_wire.data = obj.data.copy()
                head_wire.name = "holo_head_wire"
                bpy.context.collection.objects.link(head_wire)

                # 뒤통수 면만 남긴다. 얼굴 쪽은 표면을 촘촘히 깔아 두었기
                # 때문에 거기까지 격자를 두르면 얼굴이 그물로 덮인다 —
                # 마스크 선이 따로 있으므로 여기서는 두개골 구조만 보여 준다.
                bm = bmesh.new()
                bm.from_mesh(head_wire.data)
                bm.faces.ensure_lookup_table()
                front = [f for f in bm.faces if f.index < face_polys]
                if front:
                    bmesh.ops.delete(bm, geom=front, context="FACES")
                bm.to_mesh(head_wire.data)
                bm.free()
                head_wire.data.update()
                # 격자를 두르기 **전에** 줄인다. 두른 뒤에 줄이면 이미
                # 선이 된 것을 뭉개서 마디가 끊긴다.
                if args.head_wire_blocks > 0 or (
                        0 < args.head_wire_faces < len(head_wire.data.polygons)):
                    face_pts = [obj.data.vertices[i].co
                                for p in obj.data.polygons[:face_polys]
                                for i in p.vertices]
                    box = None
                    if face_pts:
                        xs = [c.x for c in face_pts]
                        zs = [c.z for c in face_pts]
                        ys = [c.y for c in face_pts]
                        box = (min(xs), max(xs), min(zs), max(zs),
                               sum(ys) / len(ys))
                    if args.head_wire_blocks > 0:
                        blockify_wire(head_wire, args.head_wire_blocks,
                                      args.head_wire_lift, box)
                    else:
                        reduce_wire(head_wire, args.head_wire_faces,
                                    args.head_wire_lift, box)
                    # 줄인 격자는 **관**으로 씌운다 (얼굴 격자와 같은 방법).
                    head_wire = tube_edges(
                        head_wire, args.thickness * args.head_wire_scale)
                else:
                    # 안 줄였으면 면이 수만 장이라 관으로 만들 수 없다.
                    hw = head_wire.modifiers.new("wireframe", "WIREFRAME")
                    hw.thickness = args.thickness * args.head_wire_scale
                    hw.use_replace = True
                    hw.use_even_offset = True
                head_wire.data.materials.clear()
                head_wire.data.materials.append(emission_material(
                    "holo_head_wire_mat", hex_to_linear(args.head_wire),
                    args.emit))
                head_wire.name = "holo_head_wire"
                head_wire.parent = rig
        obj.name = "holo_shell"
        obj.data.materials.clear()
        if args.texture:
            # 0번은 얼굴(사진), 1번은 뒤통수(단색). 뒤통수에는 UV 가 없어서
            # 사진을 그대로 입히면 이미지 한 귀퉁이가 늘어붙는다.
            obj.data.materials.append(
                textured_material("holo_face_mat", args.texture))
            if args.head_texture:
                # 머리도 사진이다. 얼굴과 같은 UV 층을 쓰고 그림만 다르다.
                obj.data.materials.append(
                    textured_material("holo_back_mat", args.head_texture,
                                      fade=args.head_fade))
            elif obj.data.color_attributes.get("head"):
                obj.data.materials.append(head_color_material("holo_back_mat"))
            else:
                obj.data.materials.append(shell_material("holo_back_mat"))
            for poly in obj.data.polygons:
                poly.material_index = 0 if poly.index < face_polys else 1
            print(f"[holo] 얼굴에 사진을 입힘 (면 {face_polys})")
        else:
            obj.data.materials.append(shell_material("holo_shell_mat"))
        obj.parent = rig

    return rig


# ---------------------------------------------------------------- 카메라 / 회전

def setup_camera(scene, tilt_deg, dist):
    cam_data = bpy.data.cameras.new("holo_cam")
    cam_data.lens = 60
    cam = bpy.data.objects.new("holo_cam", cam_data)
    bpy.context.collection.objects.link(cam)
    scene.camera = cam

    tilt = math.radians(tilt_deg)
    cam.location = Vector((0.0, -dist * math.cos(tilt), dist * math.sin(tilt)))
    cam.rotation_euler = (math.radians(90.0) - tilt, 0.0, 0.0)
    return cam


_SCAN_SPAN = 1.5


def scan_edge_on(z):
    """높이 z 에 있는 스캔면이 카메라에 **옆날로만** 보이도록 기울일 각도.

    카메라가 원근이라 눈높이를 지날 때만 저절로 선으로 보인다. 위아래로
    벗어나면 원판 면이 드러나 얼굴을 덮은 덩어리가 된다 (실제로 그렇게 나왔다).
    그래서 매 프레임 판의 법선이 시선과 직각이 되게 다시 눕힌다.
    """
    tilt = math.radians(args.tilt)
    return math.atan2(z - args.dist * math.sin(tilt), args.dist * math.cos(tilt))


# 앞에 그릴 것 / 뒤에 남길 것. `--lines-front` 가 이 둘을 따로 렌더한다.
_FRONT = ("holo_wire", "holo_contour", "holo_dot_emitter", "holo_dot")
_BACK = ("holo_shell", "holo_head_wire", "holo_scan", "holo_scan_halo")


def only(names):
    """`names` 만 남기고 나머지 홀로그램 부품을 렌더에서 숨긴다."""
    keep = set(names)
    for o in bpy.data.objects:
        if o.name in _FRONT or o.name in _BACK:
            o.hide_render = o.name not in keep


def parse_zones(spec):
    """'이마=151,눈썹=105' → [('이마', 151), ...]"""
    out = []
    for part in (spec or "").split(","):
        part = part.strip()
        if not part:
            continue
        name, _, idx = part.partition("=")
        out.append((name.strip(), int(idx)))
    return out


def zone_fans(obj, zones):
    """부위마다 **그 자리를 덮는 삼각형 무리**를 고른다.

    반지름을 재서 자르지 않는다 — 값 하나로 모든 부위에 맞출 수가 없다.
    부위 정점에서 가장 가까운 격자 꼭짓점을 찾고, **그 꼭짓점을 쓰는 삼각형**
    을 전부 가져온다. 자연히 이어진 한 덩어리가 나온다.

    (격자 정점 목록, 부위이름 → 삼각형(목록 안 번호) 목록) 을 돌려준다.
    """
    flat = list(obj.get("holo_line_faces") or [])
    tris = [flat[i:i + 3] for i in range(0, len(flat) - 2, 3)]
    if not tris:
        return [], {}

    verts = obj.data.vertices
    used = sorted({i for t in tris for i in t if i < len(verts)})
    slot = {v: k for k, v in enumerate(used)}

    out = {}
    for name, idx in zones:
        if idx >= len(verts):
            continue
        here = verts[idx].co
        near = min(used, key=lambda v: (verts[v].co - here).length)
        fan = [t for t in tris if near in t and all(i in slot for i in t)]
        # 한두 장뿐이면 너무 작아서 안 보인다. 한 겹 넓힌다.
        if len(fan) < 4:
            ring = {i for t in fan for i in t}
            fan = [t for t in tris
                   if ring & set(t) and all(i in slot for i in t)]
        out[name] = [[slot[i] for i in t] for t in fan]
    return used, out


def zone_screen(scene, obj, indices):
    """지금 프레임에서 각 정점이 화면 어디에 찍히는지 (0~1, 왼쪽 위 기준).

    화면 밖으로 나가도 그대로 둔다 — 잘라 버리면 얼굴이 돌 때 점이 가장자리에
    달라붙는다. 쓰는 쪽에서 판단하게 값만 넘긴다.
    """
    from bpy_extras.object_utils import world_to_camera_view

    mat = obj.matrix_world
    verts = obj.data.vertices
    out = []
    for i in indices:
        if i >= len(verts):
            out.append(None)
            continue
        co = world_to_camera_view(scene, scene.camera, mat @ verts[i].co)
        # world_to_camera_view 의 y 는 위가 1 이다. 화면 좌표로 뒤집는다.
        out.append([round(co.x, 5), round(1.0 - co.y, 5)])
    return out


def render_turntable(scene, rig, frames, out_dir, scan=None, zones=None,
                     shell=None, fan_verts=None, fans=None):
    """한 바퀴를 frames 장으로 쪼개 한 장씩 렌더한다.

    키프레임을 쓰지 않고 매 장마다 직접 각도를 넣는다. Blender 4.4 에서
    Action 이 슬롯 구조로 바뀌면서 fcurves 접근 경로가 달라졌는데,
    이렇게 하면 그 API 를 아예 건드리지 않아 버전을 안 탄다.

    360도는 0도와 같은 그림이라 렌더에 넣지 않는다. 넣으면 첫 장이
    두 번 나와서 루프가 한 박자 튄다.
    """
    sweep = math.radians(args.sweep)
    tracks = []
    mesh_tracks = []
    indices = [i for _, i in (zones or [])]
    fan_verts = fan_verts or []
    for frame in range(frames):
        phase = 2 * math.pi * frame / frames

        if scan is not None:
            # 위에서 아래로 **곧게** 내려간다. 왕복하면 훑는 게 아니라 흔들리는
            # 것으로 보인다. 되돌아가는 순간에는 선이 머리 밖에 있어서
            # (범위를 머리보다 넓게 잡았다) 튀는 게 보이지 않는다.
            travel = (frame / frames * args.scan_cycles) % 1.0
            scan.location.z = _SCAN_SPAN - 2 * _SCAN_SPAN * travel
            scan.rotation_euler = (scan_edge_on(scan.location.z), 0.0, 0.0)

        if sweep > 0:
            # 좌우로 훑는 스캔. 사인이라 양 끝에서 저절로 느려지고,
            # 한 주기가 정확히 맞아떨어져 이음매가 없다.
            # 얼굴 격자는 뒤통수가 없어서 한 바퀴 돌리면 뒤가 뚫려 보인다.
            angle = sweep * math.sin(phase)
        else:
            angle = phase
        rig.rotation_euler = (0, 0, angle)

        if indices and shell is not None:
            # 회전을 넣은 뒤 **의존 그래프를 갱신해야** matrix_world 가 따라온다.
            # 안 하면 매 프레임 이전 각도의 위치를 재게 된다.
            bpy.context.view_layer.update()
            tracks.append(zone_screen(scene, shell, indices))
            if fan_verts:
                mesh_tracks.append(zone_screen(scene, shell, fan_verts))

        if args.lines_front:
            # 두 번 렌더한다. 선을 얼굴보다 조금 띄우는 것만으로는 볼·턱에서
            # 계속 살에 잠긴다 — 깊이를 아예 겨루지 않게 따로 그려서 위에 얹는다.
            only(_BACK)
            scene.render.filepath = os.path.join(out_dir, f"frame_{frame:04d}")
            bpy.ops.render.render(write_still=True)
            only(_FRONT)
            scene.render.filepath = os.path.join(out_dir, f"lines_{frame:04d}")
            bpy.ops.render.render(write_still=True)
            only(_FRONT + _BACK)
        else:
            scene.render.filepath = os.path.join(out_dir, f"frame_{frame:04d}")
            bpy.ops.render.render(write_still=True)
        if frame % 12 == 0:
            print(f"[holo] {frame + 1}/{frames}")

    if tracks:
        path = os.path.join(
            os.path.dirname(os.path.normpath(out_dir)), "zones.json")
        with open(path, "w", encoding="utf-8") as fp:
            json.dump({
                "names": [n for n, _ in zones],
                "frames": tracks,
                # 격자 꼭짓점의 프레임별 위치와, 부위마다 그 위를 덮는 삼각형.
                "mesh": mesh_tracks,
                "tris": fans or {},
            }, fp)
        count = sum(len(v) for v in (fans or {}).values())
        print(f"[holo] 부위 {len(zones)}개 / 격자 정점 {len(fan_verts)}개 / "
              f"삼각형 {count}장 저장")


# ---------------------------------------------------------------- 렌더 설정

def setup_render(scene, out_dir, res):
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x = res
    scene.render.resolution_y = res
    scene.render.resolution_percentage = 100

    # 검은 배경에 그대로 렌더한다. 글로우와 알파는 glow.py 가 뒤에서 만든다.
    # Blender 5.x 는 컴포지터를 노드 그룹으로 갈아엎어서 Math/MixRGB 노드조차
    # 없어졌다. 빛 번짐 정도는 밖에서 처리하는 편이 버전을 안 타고,
    # 다시 렌더하지 않고도 세기를 고칠 수 있다.
    # 사진을 입힐 때는 배경을 투명하게 두고 색을 그대로 남긴다. 밝기를 알파로
    # 바꾸는 방식(잉크)은 색을 한 가지로 뭉개서 텍스처가 통째로 죽는다.
    scene.render.film_transparent = args.film_alpha
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA" if args.film_alpha else "RGB"
    scene.render.image_settings.compression = 15
    scene.render.filepath = os.path.join(out_dir, "frame_")

    ee = scene.eevee
    for attr, value in (("taa_render_samples", 32), ("use_gtao", False)):
        if hasattr(ee, attr):
            setattr(ee, attr, value)

    # 발광 물체라 톤매핑이 걸리면 색이 흰색으로 빠진다.
    try:
        scene.view_settings.view_transform = "Standard"
    except TypeError:
        pass


# ---------------------------------------------------------------- 실행

def main():
    scene = reset_scene()

    if args.mesh:
        print(f"[holo] 메시 불러오는 중: {args.mesh}")
        obj = import_mesh(args.mesh)
    else:
        print("[holo] 메시가 없어서 Suzanne 자리 표시용으로 렌더한다")
        obj = make_placeholder()

    # 사진측량 결과는 방향이 제멋대로다. 정규화보다 먼저 세워야
    # 바운딩 박스가 머리 기준으로 잡힌다.
    if args.bounds:
        orient_and_crop(obj, args.bounds)

    normalize(obj)
    retopologize(obj, args.faces)
    normalize(obj)

    rig = build_hologram(obj)
    # 스캔면은 리그에 붙인다. 머리가 돌면 같이 돌아야 뚫고 지나가는 것으로 보인다.
    scan = add_scan_plane(rig) if args.scan else None
    setup_camera(scene, args.tilt, args.dist)

    os.makedirs(args.out, exist_ok=True)
    setup_render(scene, args.out, args.res)

    print(f"[holo] {args.frames}장 렌더 -> {args.out}")
    zones = parse_zones(args.zones)
    shell = bpy.data.objects.get("holo_shell")
    fan_verts, fans = ([], {})
    if zones and shell is not None:
        fan_verts, fans = zone_fans(shell, zones)
    render_turntable(scene, rig, args.frames, args.out, scan, zones, shell,
                     fan_verts, fans)

    # 정렬 측정용 한 장. 2D 마스크와 **같은 범위**만 남겨야 한다 —
    # 머리(두개골)까지 재면 그 넓이에 맞추느라 아바타가 확 작아진다.
    # 스캔면도 머리보다 넓어서 그대로 재면 화면 전체가 잡힌다.
    hidden = [o for o in bpy.data.objects
              if o.name in ("holo_shell", "holo_head_wire", "holo_scan",
                         "holo_scan_halo")]
    if hidden:
        for o in hidden:
            o.hide_render = True
        rig.rotation_euler = (0, 0, 0)
        scene.render.filepath = os.path.join(
            os.path.dirname(os.path.normpath(args.out)), "align")
        bpy.ops.render.render(write_still=True)
        print("[holo] 정렬용 프레임 저장")

    print("[holo] 렌더 완료")


main()
