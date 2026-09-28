#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成《山河烬》原创神器的**道具图标**（16x16 索引色，铺进框架 graphics/item_icon/）。

为什么需要这个脚本
------------------
框架的道具图标不是"一张大图"，而是 `src/data/data_item_icon.c` 里**每图标一条**
`u8 item_icon_<名>[] = INCBIN_U8("graphics/item_icon/item_icon_<名>.4bpp")`，
这些数组按**声明顺序**连成一块 blob，`ItemData.iconId` 就是**这块 blob 里的索引**
（第 N 条声明 = 索引 N）。所以：

  · 想给一件道具**自己**的图标，就往文件**末尾追加**一条声明 ——
    新索引 = 追加前的声明条数，**不移动任何既有索引**（这是"追加"而非"插入"的关键）；
  · 十六个索引色是**全体道具图标共用**的一张表（graphics/item_icon/item_icon_palette.agbpal
    的前 16 项；索引 0 恒为透明），所以本脚本画图时只能用**那 16 个索引**，
    颜色本身由共享调色板决定 —— 见 PALETTE 的注释。

产出
----
    content/assets/icons/item_icon_shanhe_<名>.png

⚠️ 本脚本**不碰框架**：铺进 graphics/item_icon/ 由 tools/shanhe-build.sh 的图标步骤负责。

用法
----
    python3 tools/shanhe-item-icon.py write        # 生成全部 PNG
    python3 tools/shanhe-item-icon.py preview <名> [倍率]   # 生成放大预览（仅供目视）
    python3 tools/shanhe-item-icon.py check        # 自检：调色板一致性 + 索引往返 + 索引映射

自检（check）会读框架侧的 data_item_icon.c 与 .agbpal，因此要求框架已就位。
"""

import os
import struct
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
OUTDIR = os.path.join(REPO, "content", "assets", "icons")

FW = os.environ.get("SHANHE_FRAMEWORK_DIR",
                    os.path.expanduser("~/projects/fireemblem8-expansion"))
FW_ICON_DIR = os.path.join(FW, "graphics", "item_icon")
FW_ICON_SRC = os.path.join(FW, "src", "data", "data_item_icon.c")

# ── 共享调色板（16 项，与框架 graphics/item_icon/*.png 的 PLTE 逐项一致） ──────
# 这些色值是**框架既有图标 PNG 里的原样字节**（已与 item_icon_palette.agbpal 的前 16 项
# 比对过：每通道差 ≤ 8，即 5bit 量化误差）。运行时真正的调色板是 .agbpal，
# PNG 里的 PLTE 只用于"人看"和部分工具链 —— 真正决定画面的是**索引**。
#   0 透明占位（画布色）   1 白      2 浅暖灰   3 中灰     4 近黑（描边）
#   5 金黄                 6 红      7 蓝       8 灰蓝     9 淡紫灰
#  10 玉绿                11 青绿   12 棕      13 浅棕    14 深紫褐
#  15 橙棕
PALETTE = [
    (0xC5, 0xFF, 0xCD), (0xFF, 0xFF, 0xFF), (0xCD, 0xC5, 0xBD), (0x94, 0x94, 0x83),
    (0x29, 0x39, 0x20), (0xDE, 0xD5, 0x20), (0xA4, 0x08, 0x08), (0x39, 0x52, 0xF6),
    (0x73, 0x7B, 0x94), (0xB4, 0xB4, 0xD5), (0x29, 0x83, 0x62), (0x6A, 0xCD, 0xBD),
    (0x73, 0x52, 0x31), (0x9C, 0x83, 0x73), (0x52, 0x39, 0x41), (0xC5, 0x62, 0x00),
]

# ── 图标：16 行 x 16 列，每字符是调色板索引（0-9a-f） ─────────────────────────
# 设计与"必须一眼区别于突刺剑"的判据（docs/4 R-28 的同类盲区）：
#   突刺剑 = 细刺剑、斜向、窄护手、灰刃；
#   照夜   = **中国直刃剑**：竖直、白亮剑身 + 鎏金护手 + 玉饰剑首，轮廓明显更宽。
#   竖排本身也是一条区分特征（原版剑类图标多为斜向）。
ICONS = {
    # 照夜（ITEM_SHANHE_ZHAOYE，0xCF）—— 守鼎人信物，第 17 章觉醒为明烛
    "shanhe_zhaoye": [
        "0000000440000000",
        "0000004119000000",
        "0000004119000000",
        "0000004119000000",
        "0000004119000000",
        "0000004119000000",
        "0000004119000000",
        "0000004119000000",
        "0000004119000000",
        "0000004119000000",
        "0000455555540000",
        "00004ffaaff40000",
        "0000045f54000000",
        "0000045f54000000",
        "0000045f54000000",
        "000004aaa4000000",
    ],
}

W = H = 16


# ── PNG 写入（纯标准库；与 tools/gen-spell-package.py 同风格） ────────────────
def _chunk(tag, payload):
    return (struct.pack(">I", len(payload)) + tag + payload
            + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF))


def write_indexed_png(path, rows, palette):
    """rows: 16x16 的索引矩阵；输出 4bpp 索引色 PNG（PLTE，无 tRNS）。"""
    assert len(palette) == 16
    # PNG 的 4bpp 打包是**高半字节在前**（与 GBA 的 .4bpp 正好相反）
    raw = b""
    for row in rows:
        line = bytearray()
        for x in range(0, W, 2):
            line.append((row[x] << 4) | row[x + 1])
        raw += b"\x00" + bytes(line)          # 每行前缀 filter 字节 0
    ihdr = struct.pack(">IIBBBBB", W, H, 4, 3, 0, 0, 0)
    plte = b"".join(bytes(c) for c in palette)
    data = (b"\x89PNG\r\n\x1a\n" + _chunk(b"IHDR", ihdr)
            + _chunk(b"PLTE", plte) + _chunk(b"IDAT", zlib.compress(raw, 9))
            + _chunk(b"IEND", b""))
    with open(path, "wb") as fh:
        fh.write(data)
    return len(data)


def write_rgb_preview_png(path, rows, palette, scale):
    """仅供目视：真彩 PNG，最近邻放大（索引 0 画成棋盘格底色以示意透明）。"""
    big = []
    for y in range(H):
        line = bytearray()
        for x in range(W):
            idx = rows[y][x]
            rgb = (0x20, 0x20, 0x28) if idx == 0 else palette[idx]
            line += bytes(rgb) * scale
        for _ in range(scale):          # 竖向重复：每行各输出 scale 行
            big.append(bytes(line))
    raw = b"".join(b"\x00" + ln for ln in big)
    ihdr = struct.pack(">IIBBBBB", W * scale, H * scale, 8, 2, 0, 0, 0)
    data = (b"\x89PNG\r\n\x1a\n" + _chunk(b"IHDR", ihdr)
            + _chunk(b"IDAT", zlib.compress(raw, 9)) + _chunk(b"IEND", b""))
    with open(path, "wb") as fh:
        fh.write(data)


# ── 4bpp（GBA 平铺顺序）编解码：低半字节在前，且按 8x8 图块分块 ────────────────
def to_gba_4bpp(rows):
    out = bytearray()
    for ty in range(H // 8):
        for tx in range(W // 8):
            for y in range(8):
                for x in range(0, 8, 2):
                    a = rows[ty * 8 + y][tx * 8 + x]
                    b = rows[ty * 8 + y][tx * 8 + x + 1]
                    out.append(a | (b << 4))
    return bytes(out)


def from_gba_4bpp(data):
    rows = [[0] * W for _ in range(H)]
    pos = 0
    for ty in range(H // 8):
        for tx in range(W // 8):
            for y in range(8):
                for x in range(0, 8, 2):
                    byte = data[pos]
                    pos += 1
                    rows[ty * 8 + y][tx * 8 + x] = byte & 0x0F
                    rows[ty * 8 + y][tx * 8 + x + 1] = (byte >> 4) & 0x0F
    return rows


def parse_grid(lines):
    assert len(lines) == H, "需要 %d 行，得到 %d" % (H, len(lines))
    rows = []
    for i, line in enumerate(lines):
        assert len(line) == W, "第 %d 行应为 %d 列，得到 %d" % (i, W, len(line))
        rows.append([int(ch, 16) for ch in line])
    return rows


def read_png_plte(path):
    data = open(path, "rb").read()
    pos, out = 8, None
    while pos < len(data):
        (ln,) = struct.unpack(">I", data[pos:pos + 4])
        tag = data[pos + 4:pos + 8]
        if tag == b"PLTE":
            pl = data[pos + 8:pos + 8 + ln]
            out = [tuple(pl[i:i + 3]) for i in range(0, len(pl), 3)]
            break
        pos += 12 + ln
    return out


def read_agbpal(path):
    data = open(path, "rb").read()
    out = []
    for i in range(len(data) // 2):
        v = data[2 * i] | (data[2 * i + 1] << 8)
        r, g, b = v & 31, (v >> 5) & 31, (v >> 10) & 31
        out.append(((r << 3) | (r >> 2), (g << 3) | (g >> 2), (b << 3) | (b >> 2)))
    return out


def read_icon_names(source):
    """data_item_icon.c 里 INCBIN_U8(".4bpp") 的声明顺序 → [图标名]，下标即 iconId。"""
    import re
    text = open(source, encoding="utf-8").read()
    return re.findall(r'item_icon_([A-Za-z0-9_]+)\[\]\s*=\s*INCBIN_U8\("[^"]*\.4bpp"\)',
                      text)


def cmd_write():
    os.makedirs(OUTDIR, exist_ok=True)
    for name, lines in sorted(ICONS.items()):
        rows = parse_grid(lines)
        path = os.path.join(OUTDIR, "item_icon_%s.png" % name)
        size = write_indexed_png(path, rows, PALETTE)
        print("写出 %s（%d 字节，16x16 4bpp 索引色）" % (path, size))
    return 0


def cmd_preview(argv):
    if not argv:
        print("用法: preview <图标名> [倍率]", file=sys.stderr)
        return 2
    name = argv[0]
    scale = int(argv[1]) if len(argv) > 1 else 14
    rows = parse_grid(ICONS[name])
    path = os.path.join(os.environ.get("SHANHE_PREVIEW_DIR", "/tmp"),
                        "preview_%s_x%d.png" % (name, scale))
    write_rgb_preview_png(path, rows, PALETTE, scale)
    print(path)
    return 0


def read_indexed_png_rows(path):
    """读回本脚本写出的 4bpp 索引色 PNG -> 16x16 索引矩阵（只支持 filter 0）。

    注意 PNG 的 4bpp 是**高半字节在前**，与 GBA .4bpp 相反；这里按 PNG 自己的
    约定解，所以读回的结果应当与源矩阵**逐格相等**（这正是要断言的）。"""
    data = open(path, "rb").read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", path
    pos, idat = 8, b""
    w = h = bitdepth = colortype = None
    while pos < len(data):
        (ln,) = struct.unpack(">I", data[pos:pos + 4])
        tag = data[pos + 4:pos + 8]
        payload = data[pos + 8:pos + 8 + ln]
        if tag == b"IHDR":
            w, h, bitdepth, colortype = struct.unpack(">IIBB", payload[:10])
        elif tag == b"IDAT":
            idat += payload
        pos += 12 + ln
    assert (w, h, bitdepth, colortype) == (W, H, 4, 3), (w, h, bitdepth, colortype)
    raw = zlib.decompress(idat)
    stride = w // 2
    rows = []
    for y in range(h):
        line = raw[y * (stride + 1):(y + 1) * (stride + 1)]
        assert line[0] == 0, "只支持 filter 0"
        px = []
        for b in line[1:]:
            px.append((b >> 4) & 0x0F)
            px.append(b & 0x0F)
        rows.append(px)
    return rows


def cmd_verify():
    bad = []
    for name, lines in sorted(ICONS.items()):
        want = parse_grid(lines)
        path = os.path.join(OUTDIR, "item_icon_%s.png" % name)
        if not os.path.exists(path):
            bad.append("%s：交付 PNG 不存在（先跑 write）" % name)
            continue
        got = read_indexed_png_rows(path)
        if got != want:
            bad.append("%s：读回的交付 PNG 与源矩阵不一致" % name)
        print("=== %s：4bpp 索引图（读回交付文件）%s ==="
              % (name, "" if got == want else "  ★不一致★"))
        for row in got:
            print("   " + "".join("%x" % v for v in row))
        used = sorted(set(v for row in got for v in row))
        print("   用到索引: %r   非透明像素: %d"
              % (used, sum(1 for row in got for v in row if v != 0)))
    if bad:
        for b in bad:
            print("!! " + b, file=sys.stderr)
        return 1
    print("verify 通过：交付 PNG 与源矩阵逐格一致，且 nibble 顺序正确")
    return 0


def cmd_preview_fw(argv):
    """预览框架既有图标的索引图（用来确认某个 iconId 现在长什么样）。"""
    if not argv:
        print("用法: preview-fw <iconId>", file=sys.stderr)
        return 2
    idx = int(argv[0], 0)
    names = read_icon_names(FW_ICON_SRC)
    if not (0 <= idx < len(names)):
        print("iconId %d 越界（现有 %d 项）" % (idx, len(names)), file=sys.stderr)
        return 1
    nm = names[idx]
    path = os.path.join(FW_ICON_DIR, "item_icon_%s.4bpp" % nm)
    if not os.path.exists(path):
        print("找不到 %s（框架未构建？）" % path, file=sys.stderr)
        return 1
    rows = from_gba_4bpp(open(path, "rb").read())
    print("=== iconId %d -> item_icon_%s.4bpp ===" % (idx, nm))
    for row in rows:
        print("   " + "".join("%x" % v for v in row))
    nz = sum(1 for row in rows for v in row if v != 0)
    print("   非透明像素: %d / 256" % nz)
    return 0


def cmd_check():
    fails = []

    # ① 共享调色板一致性：既有图标 PNG 的 PLTE 与本脚本的 PALETTE 必须同序同色
    ref = os.path.join(FW_ICON_DIR, "item_icon_sword_rapier.png")
    if os.path.exists(ref):
        pl = read_png_plte(ref)
        if pl is None or len(pl) != 16:
            fails.append("参照图标 PLTE 不是 16 项")
        else:
            bad = [i for i in range(16)
                   if max(abs(pl[i][k] - PALETTE[i][k]) for k in range(3)) > 0]
            if bad:
                fails.append("PLTE 与本脚本 PALETTE 不一致的索引: %r" % bad)
            else:
                print("① 共享调色板：与既有图标 PLTE 逐项一致（16 项）")
    else:
        print("① 跳过：找不到参照图标（框架未就位）")

    # ② 与 .agbpal 前 16 项比（允许 5bit 量化误差 <= 8）
    pal = os.path.join(FW_ICON_DIR, "item_icon_palette.agbpal")
    if os.path.exists(pal):
        agb = read_agbpal(pal)[:16]
        bad = [i for i in range(16)
               if max(abs(agb[i][k] - PALETTE[i][k]) for k in range(3)) > 8]
        if bad:
            fails.append("与 .agbpal 前 16 项超出量化误差的索引: %r" % bad)
        else:
            print("② 共享调色板：与 item_icon_palette.agbpal 前 16 项差 <= 8（5bit 量化）")

    # ③ 索引往返：矩阵 -> GBA 4bpp -> 矩阵 必须恒等
    for name, lines in sorted(ICONS.items()):
        rows = parse_grid(lines)
        back = from_gba_4bpp(to_gba_4bpp(rows))
        if back != rows:
            fails.append("%s：4bpp 往返不一致" % name)
    if not fails:
        print("③ 4bpp 往返：%d 个图标全部恒等" % len(ICONS))

    # ④ 索引映射：证明"追加即新索引"，并把关键索引翻成图标名
    if os.path.exists(FW_ICON_SRC):
        names = read_icon_names(FW_ICON_SRC)
        print("④ 框架图标 blob：现有 %d 项（索引 0..%d）⇒ 追加后的新索引 = %d"
              % (len(names), len(names) - 1, len(names)))
        for probe in (8, 222, len(names)):
            label = names[probe] if probe < len(names) else "<本次追加的新槽位>"
            print("     iconId %-3d -> %s" % (probe, label))
        if len(names) < 1:
            fails.append("图标计数异常")
    else:
        print("④ 跳过：找不到 data_item_icon.c（框架未就位）")

    if fails:
        for f in fails:
            print("!! " + f, file=sys.stderr)
        return 1
    print("check 通过")
    return 0


def main(argv):
    if not argv or argv[0] not in ("write", "preview", "check", "verify", "preview-fw"):
        print(__doc__)
        return 2
    cmd, rest = argv[0], argv[1:]
    if cmd == "write":
        return cmd_write()
    if cmd == "preview":
        return cmd_preview(rest)
    if cmd == "verify":
        return cmd_verify()
    if cmd == "preview-fw":
        return cmd_preview_fw(rest)
    return cmd_check()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
