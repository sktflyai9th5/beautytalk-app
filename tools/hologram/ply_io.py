"""PLY 읽고 쓰기. COLMAP 이 내는 바이너리와 우리가 쓰는 ascii 를 둘 다 다룬다.

색(red/green/blue)이 있으면 같이 들고 다닌다 — 깎아낸 머리에 사진 색을
입히고 나면 그게 곧 머리카락 색이라 잃어버리면 안 된다.

Blender 안에서 도는 render_hologram.py 는 이 모듈을 쓰지 않는다. Blender 의
파이썬은 이 폴더를 import 경로에 넣어 주지 않아서, 거기서는 ascii 만 읽는
작은 함수를 따로 갖고 있다.
"""

import numpy as np

_TYPES = {"float": ("f4", 4), "float32": ("f4", 4), "double": ("f8", 8),
          "uchar": ("u1", 1), "uint8": ("u1", 1), "char": ("i1", 1),
          "int": ("i4", 4), "int32": ("i4", 4), "uint": ("u4", 4),
          "short": ("i2", 2), "ushort": ("u2", 2)}


def read_ply(path, want_normals=False):
    """(정점 Nx3, 면 목록, 색 Nx3 uint8 또는 None) 을 돌려준다.

    `want_normals=True` 면 (정점, 면, 색, 법선) 네 개를 돌려준다. COLMAP 이 낸
    밀집 점구름에는 법선이 들어 있고, **포아송 메시는 법선이 없으면 못 돈다** —
    안팎을 구분할 수가 없어서다. 잘라 내면서 잃어버리면 다시 만들 수 없다.
    """
    with open(path, "rb") as fp:
        header, current, counts, vprops, fprops = [], None, {}, [], []
        while True:
            line = fp.readline()
            if not line:
                raise SystemExit(f"헤더가 끝나기 전에 파일이 끝났다: {path}")
            line = line.decode("ascii", "replace").strip()
            header.append(line)
            if line == "end_header":
                break
            if line.startswith("element"):
                _, name, count = line.split()[:3]
                counts[name] = int(count)
                current = name
            elif line.startswith("property"):
                if current == "vertex":
                    vprops.append(line.split())
                elif current == "face":
                    fprops.append(line.split())

        fmt = next(l for l in header if l.startswith("format")).split()[1]
        n_vertex, n_face = counts.get("vertex", 0), counts.get("face", 0)
        names = [p[2] for p in vprops]
        has_color = {"red", "green", "blue"} <= set(names)

        if fmt == "ascii":
            rows = [fp.readline().split() for _ in range(n_vertex)]
            verts = np.array([[float(r[names.index(a)]) for a in ("x", "y", "z")]
                              for r in rows], dtype=np.float64)
            colors = None
            if has_color:
                colors = np.array(
                    [[int(float(r[names.index(c)]))
                      for c in ("red", "green", "blue")] for r in rows],
                    dtype=np.uint8)
            normals = None
            if want_normals and {"nx", "ny", "nz"} <= set(names):
                normals = np.array(
                    [[float(r[names.index(a)]) for a in ("nx", "ny", "nz")]
                     for r in rows], dtype=np.float64)
            faces = []
            for _ in range(n_face):
                parts = [int(v) for v in fp.readline().split()]
                faces.append(parts[1:1 + parts[0]])
            return (verts, faces, colors, normals) if want_normals else (
                verts, faces, colors)

        endian = "<" if "little" in fmt else ">"
        dtype = np.dtype([(p[2], endian + _TYPES[p[1]][0]) for p in vprops])
        data = np.frombuffer(fp.read(dtype.itemsize * n_vertex), dtype=dtype)
        verts = np.stack([data["x"], data["y"], data["z"]],
                         axis=1).astype(np.float64)
        colors = None
        if has_color:
            colors = np.stack([data["red"], data["green"], data["blue"]],
                              axis=1).astype(np.uint8)
        normals = None
        if want_normals and {"nx", "ny", "nz"} <= set(names):
            normals = np.stack([data["nx"], data["ny"], data["nz"]],
                               axis=1).astype(np.float64)

        # 면은 "개수 + 번호들" 이라 길이가 제각각이다. 바이트를 직접 훑는다.
        rest = fp.read()
        count_type = endian + _TYPES[fprops[0][2]][0] if fprops else endian + "u1"
        count_size = _TYPES[fprops[0][2]][1] if fprops else 1
        index_type = endian + _TYPES[fprops[0][3]][0] if fprops else endian + "i4"
        index_size = _TYPES[fprops[0][3]][1] if fprops else 4
        faces, offset = [], 0
        for _ in range(n_face):
            count = int(np.frombuffer(rest, dtype=count_type, count=1,
                                      offset=offset)[0])
            offset += count_size
            idx = np.frombuffer(rest, dtype=index_type, count=count, offset=offset)
            offset += index_size * count
            faces.append([int(v) for v in idx])
        return (verts, faces, colors, normals) if want_normals else (
            verts, faces, colors)


def write_ply(path, verts, faces, colors=None, normals=None):
    """ascii 로 쓴다. 사람이 열어 볼 수 있어야 디버깅이 편하다."""
    with open(path, "w", encoding="utf-8") as fp:
        fp.write("ply\nformat ascii 1.0\n")
        fp.write(f"element vertex {len(verts)}\n")
        fp.write("property float x\nproperty float y\nproperty float z\n")
        if normals is not None:
            fp.write("property float nx\nproperty float ny\nproperty float nz\n")
        if colors is not None:
            fp.write("property uchar red\nproperty uchar green\n"
                     "property uchar blue\n")
        fp.write(f"element face {len(faces)}\n")
        fp.write("property list uchar int vertex_indices\n")
        fp.write("end_header\n")
        for i, v in enumerate(verts):
            line = f"{v[0]:.6f} {v[1]:.6f} {v[2]:.6f}"
            if normals is not None:
                n = normals[i]
                line += f" {n[0]:.6f} {n[1]:.6f} {n[2]:.6f}"
            if colors is not None:
                c = colors[i]
                line += f" {int(c[0])} {int(c[1])} {int(c[2])}"
            fp.write(line + "\n")
        for f in faces:
            fp.write(str(len(f)) + " " + " ".join(str(i) for i in f) + "\n")
