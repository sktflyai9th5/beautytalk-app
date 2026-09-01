"""머리 표면에서 자라 **흘러내리는 머리카락 다발을 만들어 붙인다.**

    blender -b --factory-startup --python tools/hologram/make_hair.py -- ^
        --head head.obj --out head_hair.obj --strands 60

**왜 만드나.** 얼굴 옆으로 내려온 잔머리는 밀집 스테레오가 못 잡는다 — 몇 화소
굵기에 프레임마다 흔들려서 화소 대응이 안 잡힌다. 실루엣 깎기에는 남아 있지만,
튀어나온 것을 눌러 주는 정리(가시 제거·반지름 상한)가 그것도 같이 지운다.
**널빤지를 없애는 조작과 잔머리를 살리는 조작이 같아서** 둘을 동시에 가질 수가
없다. 그래서 복원이 아니라 만들어 붙인다.

가닥은 이렇게 짓는다.

  · **머리 표면에서 시작한다.** 옆머리가 실제로 나는 자리(관자놀이~귀 앞)에서
    법선이 옆을 보는 점을 고른다.
  · **두상을 타고 내려온다.** 한 걸음씩 아래로 가되, 머리에서 가까우면 표면에
    다시 붙인다(BVH 로 가장 가까운 점을 찾는다). 그래야 머리에서 떠 보이지
    않는다. 머리를 벗어나면 그때부터 곧게 떨어지며 살짝 안으로 말린다.
  · **끝으로 갈수록 가늘어진다.** 굵기가 일정하면 국수 가락처럼 보인다.

**색은 칠하지 않는다.** 가닥의 UV 를 **그 자리에서 가장 가까운 머리 표면의
UV** 로 준다. 머리 텍스처가 이미 그 자리 머리카락 색이라, 주변과 저절로 맞고
따로 텍스처를 굽지 않아도 된다.
"""

import argparse
import math
import random
import sys

import bmesh
import bpy
from mathutils import Vector
from mathutils.bvhtree import BVHTree

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
parser = argparse.ArgumentParser()
parser.add_argument("--head", required=True, help="UV 가 있는 머리 OBJ")
parser.add_argument("--out", required=True, help="머리+머리카락을 쓸 OBJ")
parser.add_argument("--strands", type=int, default=60, help="가닥 수")
parser.add_argument("--seed", type=int, default=7)
parser.add_argument("--zone-x", type=float, default=0.55,
                    help="이 좌우 거리(|X|)보다 바깥에서 자란다")
parser.add_argument("--zone-z", type=float, nargs=2, default=[-0.55, 0.85],
                    help="자라나는 높이 범위")
parser.add_argument("--zone-y", type=float, default=1.2,
                    help="이 깊이(Y)보다 앞에서만 자란다 (뒤통수는 놔둔다)")
parser.add_argument("--facing", type=float, default=0.45,
                    help="법선이 이만큼은 옆을 봐야 자란다")
parser.add_argument("--bottom", type=float, default=-1.6, help="여기까지 내려온다")
parser.add_argument("--step", type=float, default=0.055, help="한 걸음 길이")
parser.add_argument("--offset", type=float, default=0.012,
                    help="표면에서 이만큼 띄운다 (파고들지 않게)")
parser.add_argument("--cling", type=float, default=0.18,
                    help="머리에서 이 거리 안이면 표면에 다시 붙인다")
parser.add_argument("--curl", type=float, default=0.35,
                    help="머리를 벗어난 뒤 안으로 말리는 정도")
parser.add_argument("--radius", type=float, nargs=2, default=[0.030, 0.007],
                    help="시작 굵기와 끝 굵기")
parser.add_argument("--sides", type=int, default=6, help="가닥 단면의 각 수")
parser.add_argument("--ribbon", type=float, nargs=2, default=None,
                    metavar=("START", "END"),
                    help="**둥근 가닥 대신 납작한 다발로 만든다** (시작 너비, 끝 "
                         "너비). 둥근 관으로 만들면 굵기를 키워도 밧줄처럼 보이고, "
                         "가늘게 하면 국수가 된다. 실제 옆머리는 여러 올이 붙은 "
                         "**납작한 판**이라 이쪽이 머리카락으로 읽힌다")
parser.add_argument("--ribbon-thick", type=float, default=0.018,
                    help="다발의 두께")
parser.add_argument("--cling-above", type=float, default=None,
                    help="이 높이 위에서만 표면에 붙는다. 아래에서는 그냥 떨어진다 "
                         "— 안 그러면 가닥이 뺨을 타고 기어가서 벌레처럼 보인다")
parser.add_argument("--uv-drift", type=float, default=0.012,
                    help="가닥을 따라 UV 를 이만큼만 움직인다. 가장 가까운 표면을 "
                         "매번 따라가면 색이 줄무늬로 끊긴다")
parser.add_argument("--spread", type=float, default=0.22,
                    help="옆으로 얼마나 벌어지며 내려오는지. 크면 머리에서 떨어져 "
                         "나가 끈처럼 보인다")
parser.add_argument("--taper", type=float, default=2.0,
                    help="끝으로 갈수록 가늘어지는 정도. 1 이면 곧게 줄고, 크면 "
                         "**끝이 뾰족해진다** — 뭉툭하게 끝나면 끈으로 보인다")
parser.add_argument("--texture", default=None,
                    help="머리 텍스처 PNG. 주면 **그 자리 색이 머리카락일 때만** "
                         "가닥이 자란다. 안 주면 뿌리가 뺨에 잡혀 살색 끈이 "
                         "달린다 — 실제로 그렇게 나왔다")
parser.add_argument("--hair-luma", type=float, default=0.42,
                    help="밝기가 이보다 어두워야 머리카락으로 친다 (0~1)")
parser.add_argument("--jitter", type=float, default=0.35,
                    help="길이·굵기·방향을 가닥마다 흩뜨리는 정도")
args = parser.parse_args(argv)

rng = random.Random(args.seed)

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.wm.obj_import(filepath=args.head, forward_axis="Y", up_axis="Z")
head = bpy.context.selected_objects[0]
mesh = head.data
mesh.calc_loop_triangles()
uv_layer = mesh.uv_layers.active
if uv_layer is None:
    raise SystemExit("머리 OBJ 에 UV 가 없다")

tris = [(t.vertices[0], t.vertices[1], t.vertices[2], t.loops) for t in mesh.loop_triangles]
verts = [v.co.copy() for v in mesh.vertices]
bvh = BVHTree.FromPolygons(verts, [(a, b, c) for a, b, c, _ in tris], all_triangles=True)
print(f"[hair] 머리: 정점 {len(verts)} / 삼각형 {len(tris)}")


def uv_at(location, tri_index):
    """삼각형 안의 위치를 무게중심 좌표로 풀어 UV 를 뽑는다."""
    a, b, c, loops = tris[tri_index]
    pa, pb, pc = verts[a], verts[b], verts[c]
    n = (pb - pa).cross(pc - pa)
    area = n.length
    if area < 1e-12:
        return Vector(uv_layer.data[loops[0]].uv)
    wa = (pb - location).cross(pc - location).length / area
    wb = (pc - location).cross(pa - location).length / area
    wc = max(1.0 - wa - wb, 0.0)
    ua = Vector(uv_layer.data[loops[0]].uv)
    ub = Vector(uv_layer.data[loops[1]].uv)
    uc = Vector(uv_layer.data[loops[2]].uv)
    return ua * wa + ub * wb + uc * wc


# ---- 텍스처를 읽어 둔다 (머리카락 색인 자리만 고르려고)
tex = None
if args.texture:
    img = bpy.data.images.load(args.texture)
    tw, th = img.size
    pixels = list(img.pixels)
    def luma_at(uv):
        x = min(max(int(uv.x * (tw - 1)), 0), tw - 1)
        y = min(max(int(uv.y * (th - 1)), 0), th - 1)
        i = (y * tw + x) * img.channels
        r, g, b = pixels[i], pixels[i + 1], pixels[i + 2]
        return 0.299 * r + 0.587 * g + 0.114 * b
    tex = luma_at
    print(f"[hair] 텍스처 {tw}x{th} 를 읽었다 (밝기 {args.hair_luma} 아래만 머리카락)")

# ---- 자라날 자리 고르기
centre = sum(verts, Vector()) / len(verts)
vert_uv = {}
for tri_a, tri_b, tri_c, loops in tris:
    for vi, loop in zip((tri_a, tri_b, tri_c), loops):
        vert_uv.setdefault(vi, Vector(uv_layer.data[loop].uv))
anchors = []
for v in mesh.vertices:
    co, no = v.co, v.normal
    if abs(co.x) < args.zone_x:
        continue
    if not (args.zone_z[0] <= co.z <= args.zone_z[1]):
        continue
    if co.y > args.zone_y:
        continue
    side = Vector((1.0 if co.x > 0 else -1.0, 0.0, 0.0))
    if no.dot(side) < args.facing:
        continue
    if tex is not None:
        uv = vert_uv.get(v.index)
        if uv is None or tex(uv) > args.hair_luma:
            continue
    anchors.append(v.index)
print(f"[hair] 자라날 수 있는 자리 {len(anchors)}개")
if not anchors:
    raise SystemExit("자라날 자리가 없다 — zone 값을 넓혀라")

rng.shuffle(anchors)
picked = anchors[:args.strands]
left = sum(1 for i in picked if verts[i].x < 0)
print(f"[hair] 가닥 {len(picked)}개 (왼쪽 {left} / 오른쪽 {len(picked) - left})")

# ---- 가닥 그리기
bm = bmesh.new()
uv_out = bm.loops.layers.uv.new("hair")

made = 0
for idx in picked:
    start = verts[idx].copy()
    normal = mesh.vertices[idx].normal.copy()
    outward = Vector((normal.x, normal.y * 0.3, 0.0))
    if outward.length < 1e-6:
        continue
    outward.normalize()

    length_scale = 1.0 + rng.uniform(-args.jitter, args.jitter)
    bottom = args.bottom * (0.75 + 0.25 * length_scale)
    thick = 1.0 + rng.uniform(-args.jitter, args.jitter)

    path, uvs = [], []
    p = start + normal * args.offset
    root_hit = bvh.find_nearest(start, 0.2)
    root_uv = (uv_at(root_hit[0], root_hit[2]) if root_hit[0] is not None
               else Vector((0.5, 0.5)))
    ang = rng.uniform(0, 2 * math.pi)
    uv_slide = Vector((math.cos(ang), math.sin(ang))) * args.uv_drift
    drift = Vector((rng.uniform(-0.25, 0.25), rng.uniform(-0.2, 0.35), 0.0))
    free = 0
    for step in range(400):
        if p.z < bottom:
            break
        path.append(p.copy())
        may_cling = args.cling_above is None or p.z > args.cling_above
        hit = bvh.find_nearest(p, args.cling * 2.0) if may_cling else (None,)
        if hit[0] is not None and hit[3] < args.cling:
            # 표면에 다시 붙인다 — 머리에서 떠 보이지 않게.
            p = hit[0] + hit[1] * args.offset
            free = 0
        else:
            free += 1
        # UV 는 뿌리 자리에서 아주 조금씩만 옮긴다 (줄무늬 방지).
        uvs.append(root_uv + uv_slide * (step / 60.0))
        direction = (Vector((0.0, 0.0, -1.0)) + outward * args.spread
                     + drift * 0.12)
        if free:
            # 머리를 벗어나면 안으로 말리며 떨어진다.
            curl = min(free * 0.06, 1.0) * args.curl
            direction += Vector((-outward.x, -outward.y, 0.0)) * curl
        direction.normalize()
        p = p + direction * args.step

    if len(path) < 4:
        continue

    # ---- 폴리라인을 굵기가 줄어드는 관으로 만든다
    rings = []
    n = len(path)
    for i, point in enumerate(path):
        t = i / (n - 1)
        radius = (args.radius[0] * (1 - t) + args.radius[1] * t) * thick
        if i < n - 1:
            tangent = (path[i + 1] - point).normalized()
        else:
            tangent = (point - path[i - 1]).normalized()
        up = Vector((0.0, 0.0, 1.0))
        if abs(tangent.dot(up)) > 0.95:
            up = Vector((0.0, 1.0, 0.0))
        side = tangent.cross(up).normalized()
        other = tangent.cross(side).normalized()
        ring = []
        if args.ribbon:
            # 납작한 다발: 너비는 넓게, 두께는 얇게. 네 귀퉁이만 있으면 된다.
            # 끝으로 갈수록 빠르게 가늘어져야 뾰족하게 사라진다.
            fade = (1.0 - t) ** args.taper
            half = (args.ribbon[1] + (args.ribbon[0] - args.ribbon[1]) * fade)                 * thick * 0.5
            deep = args.ribbon_thick * 0.5
            for sx, sy in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
                ring.append(bm.verts.new(point + side * (half * sx)
                                         + other * (deep * sy)))
        else:
            for k in range(args.sides):
                a = 2 * math.pi * k / args.sides
                off = (side * (math.cos(a) * radius * 1.4)
                       + other * (math.sin(a) * radius * 0.7))
                ring.append(bm.verts.new(point + off))
        rings.append(ring)

    corners = 4 if args.ribbon else args.sides
    for i in range(len(rings) - 1):
        a, b = rings[i], rings[i + 1]
        uva, uvb = uvs[min(i, len(uvs) - 1)], uvs[min(i + 1, len(uvs) - 1)]
        for k in range(corners):
            k2 = (k + 1) % corners
            face = bm.faces.new((a[k], a[k2], b[k2], b[k]))
            for loop in face.loops:
                loop[uv_out].uv = uva if loop.vert in a else uvb
    made += 1

print(f"[hair] 만든 가닥 {made}개 / 정점 {len(bm.verts)} / 면 {len(bm.faces)}")

hair_mesh = bpy.data.meshes.new("hair")
bm.to_mesh(hair_mesh)
bm.free()
hair = bpy.data.objects.new("hair", hair_mesh)
bpy.context.collection.objects.link(hair)
hair.data.uv_layers[0].name = uv_layer.name

bpy.ops.object.select_all(action="DESELECT")
head.select_set(True)
hair.select_set(True)
bpy.context.view_layer.objects.active = head
bpy.ops.object.join()
bpy.ops.object.shade_smooth()

bpy.ops.wm.obj_export(filepath=args.out, forward_axis="Y", up_axis="Z",
                      export_selected_objects=True, export_uv=True,
                      export_normals=True, export_materials=False,
                      export_triangulated_mesh=True)
print(f"[hair] 합쳐서 정점 {len(head.data.vertices)} / 면 {len(head.data.polygons)} "
      f"-> {args.out}")
