#!/usr/bin/env python3
"""在截图里搜「虞」「聪」等汉字字形（模板匹配）。

思路：
  1. 从运行时字库资产取目标字的 16x16 2bpp 位图（真值来源，与 ROM 内一致）。
  2. 在截图（PPM）上滑窗，找位图"有墨/无墨"模式匹配的位置。
  3. 只判形状（二值化），忽略调色板。

用法：
  python3 _find_glyphs_in_shots.py <shots_dir> <targets...>
  例：python3 _find_glyphs_in_shots.py ~/shanhe-shots4 虞聪
"""
import sys
import glob
import pathlib
import struct

FRAMEWORK = pathlib.Path.home() / "projects" / "fireemblem8-expansion"

# 8 个原创字的码位
TARGETS = {
    "佩": 0x4F69, "拗": 0x62D7, "耳": 0x8033, "聪": 0x806A,
    "虞": 0x865E, "郎": 0x90CE, "鸣": 0x9E23, "鼎": 0x9F0E,
}


def load_runtime_glyph(prefix, cp):
    """从 graphics/fonts/cjk/<prefix>.{codepoints.u32le,glyphs.2bpp} 取字形位图。
    返回 16x16 的 0..3 2bpp 值矩阵（行主序）。"""
    base = FRAMEWORK / "graphics" / "fonts" / "cjk"
    cps = base / f"{prefix}.codepoints.u32le"
    gly = base / f"{prefix}.glyphs.2bpp"
    if not cps.exists() or not gly.exists():
        return None
    data = cps.read_bytes()
    codepoints = list(struct.unpack(f"<{len(data)//4}I", data))
    try:
        idx = codepoints.index(cp)
    except ValueError:
        return None
    gdata = gly.read_bytes()
    off = idx * 64
    chunk = gdata[off:off + 64]
    if len(chunk) < 64:
        return None
    # 16x16 2bpp：每行 4 字节
    rows = []
    for y in range(16):
        row = []
        for b in range(4):
            byte = chunk[y * 4 + b]
            for k in range(3, -1, -1):  # 每字节 4 个像素，高位在左
                row.append((byte >> (k * 2)) & 0x3)
        rows.append(row)
    return rows


def read_ppm(p):
    with open(p, "rb") as f:
        assert f.readline().strip() == b"P6"
        dims = f.readline().split()
        while dims[0].startswith(b"#"):
            dims = f.readline().split()
        w, h = int(dims[0]), int(dims[1])
        f.readline()
        px = f.read(w * h * 3)
    return w, h, px


def binarize(w, h, px):
    """把截图二值化成 1=有墨（暗像素）。"""
    mask = bytearray(w * h)
    for i in range(w * h):
        r, g, b = px[i * 3], px[i * 3 + 1], px[i * 3 + 2]
        # 有墨 = 明显偏暗且低饱和（字通常黑/深色）
        mx, mn = max(r, g, b), min(r, g, b)
        if mx < 140 and (mx - mn) < 90:
            mask[i] = 1
    return mask


def match(mask, w, h, glyph, ox, oy):
    """在 (ox,oy) 位置匹配字形；返回 (匹配墨点数, 字形墨点数)。

    约束：
      - 字形区域必须完全在画面内；
      - 排除贴边位置（x/y < 2 或贴右下角），避免均匀纹理假阳性。
    """
    if ox < 2 or oy < 2 or ox + 16 > w - 2 or oy + 16 > h - 2:
        return None
    hit = 0
    total = 0
    for y in range(16):
        for x in range(16):
            if glyph[y][x]:
                total += 1
                if mask[(oy + y) * w + (ox + x)]:
                    hit += 1
    return hit, total


def main():
    shots_dir = sys.argv[1]
    targets = sys.argv[2:] or ["虞", "聪"]
    for t in targets:
        cp = TARGETS.get(t)
        if cp is None:
            print(f"{t}: 不在已知原创字表")
            continue
        g = load_runtime_glyph("zh-Hans.system", cp) or load_runtime_glyph("zh-Hans.talk", cp)
        if g is None:
            print(f"{t} (U+{cp:04X}): 运行时字库无此字")
            continue
        total = sum(1 for row in g for v in row if v)
        print(f"{t} (U+{cp:04X}): 字形墨点 {total}")

    # 逐张扫；只报"高命中且在画面内"的位置
    for ppm in sorted(glob.glob(f"{shots_dir}/*.ppm")):
        w, h, px = read_ppm(ppm)
        mask = binarize(w, h, px)
        found = []
        for t in targets:
            cp = TARGETS.get(t)
            if cp is None:
                continue
            g = load_runtime_glyph("zh-Hans.system", cp) or load_runtime_glyph("zh-Hans.talk", cp)
            if g is None:
                continue
            gtotal = sum(1 for row in g for v in row if v)
            if gtotal == 0:
                continue
            best = (0, 0, 0)
            for oy in range(2, h - 18, 2):
                for ox in range(2, w - 18, 2):
                    r = match(mask, w, h, g, ox, oy)
                    if r and r[0] > best[0]:
                        best = (r[0], ox, oy)
            if best[0] / max(1, gtotal) >= 0.92:
                found.append(f"{t}@({best[1]},{best[2]}) {best[0]}/{gtotal}")
        if found:
            print(f"  {pathlib.Path(ppm).name}: {', '.join(found)}")


if __name__ == "__main__":
    main()
