#!/usr/bin/env python3
"""临时破环脚本：把 8 个原创汉字码位插入已提交的字库资产（占位字形）。

目的：让 collect_inventory 的宽度校验先通过，从而生成语料；
随后由 FEBuilder 管线用真字体重渲染并覆盖占位字形。
"""
import struct
import sys
from pathlib import Path

ROOT = Path.home() / "projects" / "fireemblem8-expansion"
GFX = ROOT / "graphics" / "fonts" / "cjk"
NEED = [ord(c) for c in "佩拗耳聪虞郎鸣鼎"]
STRIDE = 64  # 16x16 2bpp -> 16*16/4 = 64 bytes


def load(style):
    cps = (GFX / f"zh-Hans.{style}.codepoints.u32le").read_bytes()
    arr = list(struct.unpack("<%dI" % (len(cps) // 4), cps))
    widths = list((GFX / f"zh-Hans.{style}.widths.u8").read_bytes())
    glyphs = (GFX / f"zh-Hans.{style}.glyphs.2bpp").read_bytes()
    return arr, widths, glyphs


def save(style, arr, widths, glyph_blobs):
    (GFX / f"zh-Hans.{style}.codepoints.u32le").write_bytes(
        struct.pack("<%dI" % len(arr), *arr)
    )
    (GFX / f"zh-Hans.{style}.widths.u8").write_bytes(bytes(widths))
    (GFX / f"zh-Hans.{style}.glyphs.2bpp").write_bytes(b"".join(glyph_blobs))


def main():
    for style in ("system", "talk"):
        arr, widths, glyphs = load(style)
        assert len(widths) == len(arr), (style, len(widths), len(arr))
        assert len(glyphs) == len(arr) * STRIDE, (
            style, len(glyphs), len(arr) * STRIDE
        )
        missing = [cp for cp in NEED if cp not in arr]
        if not missing:
            print(f"[{style}] 无需补：8 字俱在")
            continue
        # 组装 (cp, width, glyph_blob) 再按 cp 升序合并
        rows = [(cp, w, glyphs[i * STRIDE:(i + 1) * STRIDE])
                for i, (cp, w) in enumerate(zip(arr, widths))]
        placeholder = b"\x00" * STRIDE
        for cp in missing:
            rows.append((cp, 16, placeholder))  # 宽度先按全角 16 占位
        rows.sort(key=lambda r: r[0])
        new_arr = [r[0] for r in rows]
        new_w = [r[1] for r in rows]
        new_g = [r[2] for r in rows]
        assert len(new_arr) == len(set(new_arr)), "重复码位"
        save(style, new_arr, new_w, new_g)
        print(f"[{style}] 已插入 {len(missing)} 个占位: "
              + " ".join(hex(c) for c in missing)
              + f" -> {len(arr)} => {len(new_arr)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
