"""사진측량 점구름에서 머리 주변만 잘라낸다.

    python tools/hologram/crop_cloud.py --cloud fused.ply --bounds head.json --out head.ply

COLMAP 이 복원하는 건 사람이 아니라 **방 전체**다. 그대로 메시로 만들면
책상과 의자까지 붙은 덩어리가 나오고 시간도 훨씬 오래 걸린다.
head_bounds.py 가 구한 궤도 중심에서 일정 반지름 안의 점만 남긴다.

법선(normal)을 그대로 들고 나가야 한다 — 뒤에 오는 poisson_mesher 가
법선 없이는 면을 만들지 못한다. 그래서 Blender 로 잘라내면 안 되고
(느슨한 점의 법선을 유지하지 않는다) 파일을 직접 다룬다.
"""

import argparse
import json

import numpy as np

# PLY 타입 이름 -> numpy 타입
_TYPES = {
    "char": "i1", "int8": "i1",
    "uchar": "u1", "uint8": "u1",
    "short": "i2", "int16": "i2",
    "ushort": "u2", "uint16": "u2",
    "int": "i4", "int32": "i4",
    "uint": "u4", "uint32": "u4",
    "float": "f4", "float32": "f4",
    "double": "f8", "float64": "f8",
}

parser = argparse.ArgumentParser()
parser.add_argument("--cloud", required=True, help="COLMAP 이 만든 fused.ply")
parser.add_argument("--bounds", required=True, help="head_bounds.py 가 만든 json")
parser.add_argument("--out", required=True)
parser.add_argument("--radius-scale", type=float, default=1.0,
                    help="bounds 의 crop_radius 에 곱할 값")
args = parser.parse_args()


def read_ply(path):
    """binary_little_endian 점구름을 읽는다. 면이 있으면 거부한다."""
    with open(path, "rb") as fp:
        if fp.readline().strip() != b"ply":
            raise SystemExit("ply 파일이 아니다")

        fmt = fp.readline().strip().decode()
        if "binary_little_endian" not in fmt:
            raise SystemExit(f"지원하지 않는 형식이다: {fmt}")

        count = 0
        fields = []
        header = []
        while True:
            line = fp.readline()
            if not line:
                raise SystemExit("헤더가 끝나지 않았다")
            header.append(line)
            text = line.strip().decode()
            if text == "end_header":
                break
            parts = text.split()
            if parts[0] == "element" and parts[1] == "vertex":
                count = int(parts[2])
            elif parts[0] == "element":
                # face 등 다른 요소가 있으면 점구름이 아니다.
                raise SystemExit(f"점구름이 아니다 (element {parts[1]})")
            elif parts[0] == "property":
                if parts[1] == "list":
                    raise SystemExit("list 속성은 다루지 않는다")
                fields.append((parts[2], _TYPES[parts[1]]))

        dtype = np.dtype([(name, t) for name, t in fields])
        data = np.frombuffer(fp.read(count * dtype.itemsize), dtype=dtype, count=count)
    return header, data


def main():
    with open(args.bounds, "r", encoding="utf-8") as fp:
        bounds = json.load(fp)

    head = np.array(bounds["head"], dtype=np.float64)
    radius = bounds["crop_radius"] * args.radius_scale

    header, data = read_ply(args.cloud)
    xyz = np.stack([data["x"], data["y"], data["z"]], axis=1).astype(np.float64)
    keep = np.linalg.norm(xyz - head, axis=1) <= radius
    kept = data[keep]

    if kept.size == 0:
        raise SystemExit("남은 점이 없다. --radius-scale 을 키워라.")

    with open(args.out, "wb") as fp:
        for line in header:
            if line.strip().decode().startswith("element vertex"):
                fp.write(f"element vertex {kept.size}\n".encode())
            else:
                fp.write(line)
        fp.write(kept.tobytes())

    print(f"[crop] {data.size} -> {kept.size} 점 "
          f"(반지름 {radius:.3f}) -> {args.out}")


main()
