"""깎아낸 머리를 **텍스처를 입힐 수 있는 메시**로 다듬는다 (Blender 전용).

    blender --background --factory-startup --python prep_head.py -- ^
        --mesh head_fitted.ply --out head_uv.obj [--faces 6000] [--smooth 3]

하는 일은 셋이다. 면을 줄이고, 살짝 문지르고, **UV 를 편다.**

UV 가 왜 필요한가: 지금까지는 정점마다 색 하나를 물려 두었는데, 면을 수천 개로
줄이고 나면 색도 그만큼밖에 안 남아서 머리카락이 뭉갠 얼룩으로 보인다. UV 를
펴 두면 촬영본을 1024x1024 그림 한 장으로 구워 붙일 수 있고, 그때부터는
색이 픽셀 단위로 들어간다 (`bake_head_texture.py`).

OBJ 로 내보내는 이유는 PLY 가 UV 를 제대로 실어 나르지 못해서다.
"""

import argparse
import os
import sys

import bmesh
import bpy

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
parser = argparse.ArgumentParser()
parser.add_argument("--mesh", required=True, help="fit_head.py 가 낸 PLY")
parser.add_argument("--out", required=True, help="쓸 OBJ 경로")
parser.add_argument("--faces", type=int, default=6000,
                    help="이 면 수까지 줄인다. 텍스처를 입히므로 형태만 담으면 된다")
parser.add_argument("--smooth", type=int, default=3,
                    help="복셀 계단을 몇 번 문지를지. 많이 하면 머리카락 결이 죽는다")
parser.add_argument("--back", type=float, default=None,
                    help="이 깊이(Y)보다 뒤를 잘라낸다. 묶은 머리를 통째로 덜어내 "
                         "두상만 남긴다 — 늘어진 머리카락은 실루엣으로 복원되지 "
                         "않아서 남겨 두면 덩어리로 보인다")
parser.add_argument("--side", type=float, default=None,
                    help="좌우로 이 폭(|X|)을 넘는 부분을 잘라낸다. 실루엣 깎기는 "
                         "묶은 머리가 여러 화면에서 머리와 겹쳐 보이는 탓에 한쪽으로 "
                         "덧살을 남기는데, 그게 옆에 붙은 딴 조각처럼 보인다")
parser.add_argument("--floor", type=float, default=None,
                    help="이 높이(Z) 아래를 잘라낸다. 묶은 머리 끝이 상자에 걸려 "
                         "너덜하게 남는 것을 턱선에서 깔끔히 끊는다")
parser.add_argument("--fill-sides", type=int, default=12,
                    help="변이 이 개수 이하인 구멍만 메운다. 0 이면 모든 구멍을 "
                         "메우는데 **얼굴 자리까지 막힌다**")
parser.add_argument("--remesh", type=float, default=0.0,
                    help="이 복셀 크기로 표면을 **다시 뜬다**. 실루엣 깎기가 남긴 "
                         "찢어진 테두리와 구멍이 한 번에 없어진다 (0 이면 끔)")
parser.add_argument("--face-mesh", default=None,
                    help="리메시 뒤에 얼굴 자리를 다시 도려낼 때 쓸 격자 JSON. "
                         "리메시는 물샐틈없는 껍데기를 만들어서 얼굴 구멍도 막아 버린다")
parser.add_argument("--cut-inset", type=int, default=20,
                    help="얼굴 자리를 이 칸만큼 안쪽으로 줄여 도려낸다")
parser.add_argument("--front-margin", type=float, default=0.04,
                    help="얼굴 표면보다 이만큼 뒤까지 도려낸다")
parser.add_argument("--angle", type=float, default=66.0,
                    help="UV 를 가를 각도(도). 작을수록 조각이 잘게 나뉜다")
args = parser.parse_args(argv)


def face_depth_map(path, n, inset):
    """얼굴 앞면의 깊이를 (X, Z) 격자에 굽는다 (fit_head.py 와 같은 방식).

    리메시는 물샐틈없는 껍데기를 만들기 때문에 얼굴 구멍이 막힌다. 여기서
    **다시 뚫는다.** 테두리는 안쪽으로 줄여서(inset) 얼굴 격자가 못 덮는
    자리가 뚫리지 않게 한다.
    """
    import json
    import numpy as np

    with open(path, "r", encoding="utf-8") as fp:
        payload = json.load(fp)
    verts = np.array(payload["vertices"], dtype=np.float64)
    tris = [f for f in payload.get("faces", []) if len(f) == 3]
    lo = verts[:, [0, 2]].min(axis=0)
    hi = verts[:, [0, 2]].max(axis=0)
    span = np.maximum(hi - lo, 1e-9)
    depth = np.full((n, n), np.nan)

    for tri in tris:
        p = verts[tri]
        cell = (p[:, [0, 2]] - lo) / span * (n - 1)
        x0, z0 = np.floor(cell.min(axis=0)).astype(int)
        x1, z1 = np.ceil(cell.max(axis=0)).astype(int)
        x0, z0 = max(x0, 0), max(z0, 0)
        x1, z1 = min(x1, n - 1), min(z1, n - 1)
        if x1 < x0 or z1 < z0:
            continue
        gx, gz = np.meshgrid(np.arange(x0, x1 + 1), np.arange(z0, z1 + 1),
                             indexing="ij")
        px, pz = gx.ravel(), gz.ravel()
        (ax, az), (bx, bz), (cx, cz) = cell
        det = (bz - cz) * (ax - cx) + (cx - bx) * (az - cz)
        if abs(det) < 1e-12:
            continue
        w0 = ((bz - cz) * (px - cx) + (cx - bx) * (pz - cz)) / det
        w1 = ((cz - az) * (px - cx) + (ax - cx) * (pz - cz)) / det
        w2 = 1.0 - w0 - w1
        inside = (w0 >= -0.02) & (w1 >= -0.02) & (w2 >= -0.02)
        if not inside.any():
            continue
        y = w0 * p[0, 1] + w1 * p[1, 1] + w2 * p[2, 1]
        ix, iz, yy = px[inside], pz[inside], y[inside]
        current = depth[ix, iz]
        better = np.isnan(current) | (yy < current)
        depth[ix[better], iz[better]] = yy[better]

    keep = ~np.isnan(depth)
    for _ in range(max(inset, 0)):
        shrunk = keep.copy()
        shrunk[1:, :] &= keep[:-1, :]
        shrunk[:-1, :] &= keep[1:, :]
        shrunk[:, 1:] &= keep[:, :-1]
        shrunk[:, :-1] &= keep[:, 1:]
        keep = shrunk
    return np.where(keep, depth, np.nan), lo, span


def cut_face_hole(obj, path, inset, margin, n=224):
    """리메시로 막힌 얼굴 자리를 다시 뚫는다."""
    import numpy as np

    depth, lo, span = face_depth_map(path, n, inset)
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bm.faces.ensure_lookup_table()

    doomed = []
    for face in bm.faces:
        c = face.calc_center_median()
        ix = int(round((c.x - lo[0]) / span[0] * (n - 1)))
        iz = int(round((c.z - lo[1]) / span[1] * (n - 1)))
        if not (0 <= ix < n and 0 <= iz < n):
            continue
        y = depth[ix, iz]
        if not np.isnan(y) and c.y < y + margin:
            doomed.append(face)
    if doomed:
        bmesh.ops.delete(bm, geom=doomed, context="FACES")
    bm.to_mesh(obj.data)
    bm.free()
    obj.data.update()
    print(f"[prep] 얼굴 자리 {len(doomed)}면을 다시 뚫었다")


def main():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    try:
        bpy.ops.wm.ply_import(filepath=args.mesh)
    except AttributeError:
        bpy.ops.import_mesh.ply(filepath=args.mesh)

    obj = bpy.context.selected_objects[0]
    bpy.context.view_layer.objects.active = obj
    before = len(obj.data.polygons)

    # 떨어져 나온 조각을 버리고 **가장 큰 덩어리만** 남긴다. 실루엣 깎기는
    # 마스크가 한두 장 튀면 귀 옆이나 묶은 머리 근처에 작은 덩어리를 남기는데,
    # 렌더에서는 그게 허공에 붕 뜬 살점으로 보인다.
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.mesh.separate(type="LOOSE")
    bpy.ops.object.mode_set(mode="OBJECT")
    parts = [o for o in bpy.context.selected_objects if o.type == "MESH"]
    parts.sort(key=lambda o: len(o.data.polygons), reverse=True)
    obj = parts[0]
    dropped = sum(len(o.data.polygons) for o in parts[1:])
    for extra in parts[1:]:
        bpy.data.objects.remove(extra, do_unlink=True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    if dropped:
        print(f"[prep] 떨어진 조각 {len(parts) - 1}개 / 면 {dropped} 버림")

    # 턱선 아래를 잘라낸다. 깎기 상자에 걸린 묶은 머리 끝이 너덜한 그루터기로
    # 남는데, 화면에서는 그게 허공에 뜬 살점으로 보인다. 깔끔히 끊는 편이 낫다.
    if (args.floor is not None or args.side is not None
            or args.back is not None):
        bm = bmesh.new()
        bm.from_mesh(obj.data)
        doomed = [v for v in bm.verts
                  if (args.floor is not None and v.co.z < args.floor)
                  or (args.side is not None and abs(v.co.x) > args.side)
                  or (args.back is not None and v.co.y > args.back)]
        if doomed:
            bmesh.ops.delete(bm, geom=doomed, context="VERTS")
        # 잘라낸 자리는 뚫린 채로 남는다. 그대로 두면 그 단면이 **어두운 조각**
        # 으로 보인다 (안쪽에는 색이 없다). 얼굴 구멍은 열어 두어야 하므로,
        # **얼굴보다 뒤에 있는** 테두리만 골라 막는다.
        bm.edges.ensure_lookup_table()
        rim = [e for e in bm.edges if e.is_boundary
               and min(v.co.y for v in e.verts) > 0.2]
        if rim:
            bmesh.ops.holes_fill(bm, edges=rim, sides=0)
        bm.to_mesh(obj.data)
        bm.free()
        obj.data.update()
        print(f"[prep] 바닥 {args.floor} / 폭 {args.side} / 뒤 {args.back} "
              f"밖 정점 {len(doomed)}개 잘라내고 뒤쪽 테두리 {len(rim)}변을 막았다")

    # 마스크가 튄 자리에 뚫린 **작은** 구멍만 메운다. 그대로 두면 안쪽이
    # 비쳐서 살점이 뜯긴 것처럼 보인다.
    #
    # `sides=0` (모든 구멍) 을 주면 안 된다 — 얼굴이 들어갈 앞쪽 구멍까지
    # 막아 버려서 사진 얼굴 앞에 막이 한 겹 씌워진다.
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.mesh.fill_holes(sides=args.fill_sides)
    bpy.ops.object.mode_set(mode="OBJECT")

    # 표면을 다시 뜬다. 실루엣 깎기가 남긴 찢어진 테두리와 잔구멍이 한 번에
    # 없어지고 물샐틈없는 껍데기가 된다 — 잘라 내거나 문질러서는 안 없어진다.
    if args.remesh > 0:
        # 복셀 리메시는 **닫힌 면**을 요구한다. 열린 껍데기를 그대로 넣으면
        # 조각조각 부서진다 — 두께를 먼저 줘서 닫아 놓는다.
        thick = obj.modifiers.new("solidify", "SOLIDIFY")
        thick.thickness = args.remesh * 2.0
        thick.offset = 0.0
        bpy.ops.object.modifier_apply(modifier=thick.name)

        mod = obj.modifiers.new("remesh", "REMESH")
        mod.mode = "VOXEL"
        mod.voxel_size = args.remesh
        bpy.ops.object.modifier_apply(modifier=mod.name)
        print(f"[prep] 복셀 {args.remesh} 로 다시 뜸 -> 면 {len(obj.data.polygons)}")
        if args.face_mesh:
            cut_face_hole(obj, args.face_mesh, args.cut_inset, args.front_margin)

    if args.smooth > 0:
        mod = obj.modifiers.new("smooth", "SMOOTH")
        mod.factor = 0.7
        mod.iterations = args.smooth
        bpy.ops.object.modifier_apply(modifier=mod.name)

    if 0 < args.faces < len(obj.data.polygons):
        dec = obj.modifiers.new("decimate", "DECIMATE")
        dec.ratio = args.faces / len(obj.data.polygons)
        bpy.ops.object.modifier_apply(modifier=dec.name)

    # UV 펴기. 각을 기준으로 조각내는 방식이라 머리처럼 둥근 덩어리에서도
    # 늘어남이 적다. 여백(island_margin)을 조금 줘야 구운 텍스처의 조각끼리
    # 색이 새어 들지 않는다.
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.smart_project(angle_limit=args.angle * 3.14159265 / 180.0,
                             island_margin=0.006)
    bpy.ops.object.mode_set(mode="OBJECT")

    os.makedirs(os.path.dirname(os.path.abspath(args.out)) or ".", exist_ok=True)
    # **축을 바꾸지 마라.** OBJ 내보내기는 기본이 Y-up 이라 Blender 의 Z 를 Y 로
# 돌려 버린다. 이 파이프라인은 얼굴 격자 좌표(얼굴이 -Y, 위가 +Z)를 끝까지
# 그대로 쓰므로, 여기서 한 번 돌아가면 뒤에 오는 것이 전부 어긋난다 —
# 얼굴 자리를 뒤로 미는 계산이 엉뚱한 축으로 돌아 턱이 찢어졌다.
bpy.ops.wm.obj_export(filepath=args.out, forward_axis="Y", up_axis="Z",
                      export_selected_objects=True,
                          export_uv=True, export_normals=True,
                          export_materials=False, export_triangulated_mesh=True,
                          forward_axis="Y", up_axis="Z")
    print(f"[prep] 면 {before} -> {len(obj.data.polygons)} / UV 폄 -> {args.out}")


main()
