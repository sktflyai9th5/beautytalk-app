"""밀집 복원으로 뜬 머리를 **모양을 지키면서** 최소한만 정리한다.

    blender -b --factory-startup --python tools/hologram/clean_dense.py -- ^
        --mesh s7.ply --out head.obj --faces 14000

`prep_head.py` 는 실루엣으로 깎은 머리를 위한 것이다. 거기서는 표면이 톱니처럼
물어뜯겨 있어서 **두께를 주고 복셀로 다시 뜨는(Solidify + Remesh)** 게 필요했다.
밀집 복원 결과에 그걸 하면 형상이 공처럼 뭉갠다 — 실제로 그렇게 나왔다. 여기서는
다시 뜨지 않는다.

하는 일은 넷뿐이다.

  · **가장 큰 덩어리만 남긴다** — 떨어져 나온 조각은 화면에서 뜬 것처럼 보인다.
  · **바닥을 자르고 그 테두리를 막는다** — 목·어깨는 필요 없고, 열어 두면
    돌 때 안이 비쳐 보인다.
  · **문지른다** — 밀집 복원 표면에는 1~3mm 잡음이 남아 있어 그대로 두면
    피부가 오돌토돌하다.
  · **면을 줄이고 UV 를 편다** — 텍스처를 입히려면 UV 가 있어야 한다.
"""

import argparse
import math
import os
import sys

import bmesh
import bpy
from mathutils import Vector

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
parser = argparse.ArgumentParser()
parser.add_argument("--mesh", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--faces", type=int, default=14000, help="줄일 목표 면 수")
parser.add_argument("--smooth", type=int, default=6, help="문지르는 횟수")
parser.add_argument("--floor", type=float, default=None, help="이 높이(Z) 아래를 자른다")
parser.add_argument("--floor-side", type=float, default=None,
                    help="**옆(머리카락)만 더 아래까지 남긴다.** 턱 아래에는 목과 "
                         "옷깃이 같이 복원되는데, 그걸 남기면 아바타 밑에 살색·"
                         "옷 덩어리가 붙는다. 그렇다고 평평하게 잘라 버리면 얼굴 "
                         "옆으로 흘러내린 잔머리까지 없어져서 머리가 짧아 보인다. "
                         "가운데는 --floor 에서, 좌우 바깥은 이 높이에서 자른다")
parser.add_argument("--floor-side-x", type=float, nargs=2, default=[0.45, 0.75],
                    help="이 좌우 거리(|X|) 사이에서 --floor 가 --floor-side 로 "
                         "서서히 내려간다")
parser.add_argument("--front", type=float, default=None,
                    help="**얼굴보다 앞에 있는 것을 걷어낸다** (이 Y 보다 앞). "
                         "앉아서 찍으면 옷깃과 가슴이 얼굴보다 앞으로 나와서 같이 "
                         "복원된다. 그걸 남겨 두면 '얼굴 자리'로 오인해서 뒤로 "
                         "끌어당기게 되고 턱이 찢어진다. 코끝이 대략 -0.4 이니 "
                         "-0.55 쯤이면 얼굴은 안 건드린다")
parser.add_argument("--cap-ratio", type=float, default=0.0,
                    help="**바깥으로 뻗은 덩어리를 두상 안으로 눌러 넣는다.** 방향마다 "
                         "반지름을 재서 넓게 문지르면 '그 언저리 두상의 반지름'이 "
                         "나온다. 어느 정점도 그 값의 이 배를 못 넘게 막는다. "
                         "가시 하나가 아니라 머리카락 한 다발처럼 넓게 뻗은 것은 "
                         "--shave 로는 안 잡힌다. 안쪽으로는 안 건드리므로 귀처럼 "
                         "파인 구조는 그대로 남는다. 1.03~1.10 쯤")
parser.add_argument("--cap-symmetric", action="store_true",
                    help="**상한을 좌우 대칭으로 강제한다.** 방향별 평균 반지름을 "
                         "좌우 거울 방향과 비교해 작은 쪽으로 맞춘다. 복원이 "
                         "한쪽만 들뜨게 나왔을 때, 들뜬 쪽이 반대쪽 수준으로 "
                         "눌린다 (수지님 왼쪽 머리가 들떠서 넣었다)")
parser.add_argument("--cap-az", type=int, default=64)
parser.add_argument("--cap-el", type=int, default=32)
parser.add_argument("--cap-smooth", type=int, default=10)
parser.add_argument("--shave", type=float, default=0.0,
                    help="**바깥으로 튀어나온 정점만 눌러 준다.** 이웃들의 평균보다 "
                         "이 거리 이상 바깥에 있으면 평균 쪽으로 끌어당긴다. 머리카락 "
                         "언저리에 남은 가시가 실루엣에서 '뜯어진' 느낌을 만드는데, "
                         "전체를 문지르면 머리가 통째로 쪼그라든다 — 튀어나온 것만 "
                         "골라 눌러야 부피가 안 준다")
parser.add_argument("--shave-rounds", type=int, default=6,
                    help="눌러 주기를 몇 번 되풀이할지")
parser.add_argument("--min-part", type=float, default=0.05,
                    help="가장 큰 덩어리의 이 비율보다 작은 조각은 버린다")
args = parser.parse_args(argv)

bpy.ops.wm.read_factory_settings(use_empty=True)
ext = os.path.splitext(args.mesh)[1].lower()
if ext == ".ply":
    bpy.ops.wm.ply_import(filepath=args.mesh)
else:
    bpy.ops.wm.obj_import(filepath=args.mesh)
obj = bpy.context.selected_objects[0]
bpy.context.view_layer.objects.active = obj
print(f"[clean] 받은 메시: 정점 {len(obj.data.vertices)} / 면 {len(obj.data.polygons)}")

# 1. 가장 큰 덩어리만 남긴다.
bm = bmesh.new()
bm.from_mesh(obj.data)
parts, seen = [], set()
for face in bm.faces:
    if face.index in seen:
        continue
    stack, group = [face], []
    seen.add(face.index)
    while stack:
        f = stack.pop()
        group.append(f)
        for edge in f.edges:
            for nb in edge.link_faces:
                if nb.index not in seen:
                    seen.add(nb.index)
                    stack.append(nb)
    parts.append(group)
parts.sort(key=len, reverse=True)
if len(parts) > 1:
    limit = len(parts[0]) * args.min_part
    drop = [f for g in parts[1:] if len(g) < limit for f in g]
    print(f"[clean] 덩어리 {len(parts)}개 — 가장 큰 것 {len(parts[0])}면, "
          f"작은 조각 {len(drop)}면 버림")
    if drop:
        bmesh.ops.delete(bm, geom=drop, context="FACES")

# 2. 바닥과 앞쪽(옷깃·가슴)을 자르고 그 테두리를 막는다.
if args.front is not None:
    ahead = [v for v in bm.verts if v.co.y < args.front]
    if ahead:
        bmesh.ops.delete(bm, geom=ahead, context="VERTS")
        bm.verts.ensure_lookup_table()
        print(f"[clean] 얼굴보다 앞(Y<{args.front}) 정점 {len(ahead)}개를 걷어냈다")

if args.floor is not None and args.floor_side is not None:
    x0, x1 = args.floor_side_x
    def floor_at(x):
        t = min(max((abs(x) - x0) / max(x1 - x0, 1e-6), 0.0), 1.0)
        t = t * t * (3 - 2 * t)                       # 부드럽게 (smoothstep)
        return args.floor + (args.floor_side - args.floor) * t
    low = [v for v in bm.verts if v.co.z < floor_at(v.co.x)]
elif args.floor is not None:
    low = [v for v in bm.verts if v.co.z < args.floor]
else:
    low = []

if low:
    bmesh.ops.delete(bm, geom=low, context="VERTS")
    bm.verts.ensure_lookup_table()
    border = [e for e in bm.edges if len(e.link_faces) == 1]
    if border:
        bmesh.ops.holes_fill(bm, edges=border, sides=0)
    where = (f"{args.floor}(가운데)~{args.floor_side}(옆)"
             if args.floor_side is not None else str(args.floor))
    print(f"[clean] 바닥 {where} 아래 {len(low)}정점을 자르고 "
          f"테두리 {len(border)}변을 막았다")

bm.to_mesh(obj.data)
bm.free()
obj.data.update()

# 3a. 넓게 뻗은 덩어리를 두상 반지름 안으로 눌러 넣는다.
if args.cap_ratio > 0:
    import numpy as np
    co = np.array([v.co[:] for v in obj.data.vertices], dtype=np.float64)
    centre = np.median(co, axis=0)
    if args.cap_symmetric:
        # 대칭 기준면이 얼굴 정중선(X=0)과 일치해야 한다. 중심이 옆으로
        # 밀려 있으면 엉뚱한 면을 기준으로 접는다.
        centre[0] = 0.0
    rel = co - centre
    radius = np.linalg.norm(rel, axis=1)
    safe = np.maximum(radius, 1e-9)
    az, el = args.cap_az, args.cap_el
    ia = np.clip(((np.arctan2(rel[:, 0], rel[:, 1]) + math.pi)
                  / (2 * math.pi) * az).astype(int), 0, az - 1)
    ie = np.clip(((np.arcsin(np.clip(rel[:, 2] / safe, -1, 1)) + math.pi / 2)
                  / math.pi * el).astype(int), 0, el - 1)

    grid = np.zeros((az, el)); count = np.zeros((az, el))
    np.add.at(grid, (ia, ie), radius)
    np.add.at(count, (ia, ie), 1.0)
    # 빈 방향이 생기면 그 자리가 0 이 되어 엉뚱하게 눌린다. 가중 평균으로 편다.
    for _ in range(args.cap_smooth):
        g = (grid + np.roll(grid, 1, 0) + np.roll(grid, -1, 0)
             + np.pad(grid, ((0, 0), (1, 0)), mode="edge")[:, :-1]
             + np.pad(grid, ((0, 0), (0, 1)), mode="edge")[:, 1:])
        c = (count + np.roll(count, 1, 0) + np.roll(count, -1, 0)
             + np.pad(count, ((0, 0), (1, 0)), mode="edge")[:, :-1]
             + np.pad(count, ((0, 0), (0, 1)), mode="edge")[:, 1:])
        grid, count = g, c
    mean_radius = grid / np.maximum(count, 1e-9)

    if args.cap_symmetric:
        # 방위각은 atan2(x, y) 라 x -> -x 미러가 인덱스 뒤집기다.
        mirrored = mean_radius[::-1, :]
        mean_radius = np.minimum(mean_radius, mirrored)
        print(f"[clean] 상한을 좌우 대칭(작은 쪽)으로 맞췄다")

    limit = mean_radius[ia, ie] * args.cap_ratio
    over = radius > limit
    if over.any():
        scale = np.where(over, limit / safe, 1.0)
        moved = centre + rel * scale[:, None]
        for i, v in enumerate(obj.data.vertices):
            if over[i]:
                v.co = moved[i]
        print(f"[clean] 두상 반지름의 {args.cap_ratio}배 밖으로 나간 정점 "
              f"{int(over.sum())}개를 눌러 넣었다 "
              f"(최대 {float(np.max(radius - limit)):.3f})")

# 3b. 튀어나온 가시를 눌러 준다. 문지르기보다 먼저 해야 한다 —
#    가시가 남은 채로 문지르면 가시가 뭉툭해질 뿐 없어지지 않는다.
if args.shave > 0:
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bm.verts.ensure_lookup_table()
    moved_total = 0
    for _ in range(args.shave_rounds):
        moved = 0
        targets = []
        for v in bm.verts:
            linked = [e.other_vert(v) for e in v.link_edges]
            if len(linked) < 3:
                continue
            avg = sum((w.co for w in linked), Vector()) / len(linked)
            out = v.co - avg
            if out.length > args.shave:
                targets.append((v, avg + out.normalized() * args.shave))
                moved += 1
        for v, co in targets:
            v.co = co
        moved_total += moved
        if not moved:
            break
    bm.to_mesh(obj.data)
    bm.free()
    obj.data.update()
    print(f"[clean] 튀어나온 정점 {moved_total}번 눌렀다 (기준 {args.shave})")

# 4. 문지른다. (복셀로 다시 뜨지 않는다 — 형상이 뭉갠다)
if args.smooth > 0:
    mod = obj.modifiers.new("smooth", "SMOOTH")
    mod.factor = 0.5
    mod.iterations = args.smooth
    bpy.ops.object.modifier_apply(modifier=mod.name)

# 4. 면을 줄이고 UV 를 편다.
if len(obj.data.polygons) > args.faces:
    dec = obj.modifiers.new("decimate", "DECIMATE")
    dec.ratio = args.faces / len(obj.data.polygons)
    bpy.ops.object.modifier_apply(modifier=dec.name)

bpy.ops.object.select_all(action="DESELECT")
obj.select_set(True)
bpy.ops.object.mode_set(mode="EDIT")
bpy.ops.mesh.select_all(action="SELECT")
bpy.ops.uv.smart_project(angle_limit=math.radians(66), island_margin=0.004)
bpy.ops.object.mode_set(mode="OBJECT")
bpy.ops.object.shade_smooth()

# **축을 바꾸지 마라.** OBJ 내보내기는 기본이 Y-up 이라 Blender 의 Z 를 Y 로
# 돌려 버린다. 이 파이프라인은 얼굴 격자 좌표(얼굴이 -Y, 위가 +Z)를 끝까지
# 그대로 쓰므로, 여기서 한 번 돌아가면 뒤에 오는 것이 전부 어긋난다 —
# 얼굴 자리를 뒤로 미는 계산이 엉뚱한 축으로 돌아 턱이 찢어졌다.
bpy.ops.wm.obj_export(filepath=args.out, forward_axis="Y", up_axis="Z",
                      export_selected_objects=True,
                      export_uv=True, export_normals=True,
                      export_materials=False, export_triangulated_mesh=True)
print(f"[clean] 정점 {len(obj.data.vertices)} / 면 {len(obj.data.polygons)} "
      f"-> {args.out}")
