#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成《山河烬》惊雷引（符箓·天道）自定义法术特效包。

产出（全部入库，可复现）：
    content/assets/spells/jingleiyin/spell.json
    content/assets/spells/jingleiyin/animation.txt
    content/assets/spells/jingleiyin/images/jingleiyin_obj_{00,01}.png
    content/assets/spells/jingleiyin/images/jingleiyin_bg_{00,01}.png

格式契约 = 框架 `feditor-magic-v1`（docs/custom_spell_effects.md）：
  · OBJ 必须是**索引色 4bpp 480x160**；左 240 列为 front 平面、右 240 列为 back 平面。
  · BG  必须是**索引色 4bpp 240x64**（生成器会竖向最近邻放大到 240x160 再切 30x20 图块）。
  · 每张 PNG：单个 IHDR、单个 PLTE、tRNS 在 PLTE 之后且在连续 IDAT 之前、零负载 IEND。
  · PLTE 1..16 项；tRNS 长度 == 调色板项数；**索引 0 必须透明**；
    凡被实际使用到的非零索引必须不透明（本脚本把非零项一律设为 alpha=255）。

设计意图（docs/8 §7.2.4 第 7 项）：符箓·天道 → ITYPE_ANIMA → MCOLOR_NORMAL；
特效 = 「雷光链」——一束自天而降的折线闪电 + 分叉电枝 + 暴风背景带。

⚠️ 本脚本只写 PNG/JSON/TXT，**不碰框架**。铺进框架由 tools/shanhe-build.sh 负责。
"""

import json
import os
import struct
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
PKG = os.path.join(REPO, "content", "assets", "spells", "jingleiyin")
IMG = os.path.join(PKG, "images")

OBJ_W, OBJ_H = 480, 160          # front(240) + back(240)
BG_W, BG_H = 240, 64

# ── 调色板（索引 0 恒为透明占位；其余色值仅供 PLTE，透明度由 tRNS 决定） ──
OBJ_PALETTE = [
    (0x00, 0x00, 0x00),   # 0 transparent placeholder
    (0x10, 0x18, 0x30),   # 1 夜蓝（暗）
    (0x2A, 0x4A, 0x8A),   # 2 风暴蓝（外辉）
    (0x4F, 0xC3, 0xF7),   # 3 青（电光晕）
    (0xB3, 0xE5, 0xFC),   # 4 淡青（次亮芯）
    (0xFF, 0xFF, 0xFF),   # 5 白（电芯）
]
BG_PALETTE = [
    (0x00, 0x00, 0x00),   # 0 transparent
    (0x08, 0x0C, 0x1C),   # 1 近黑
    (0x14, 0x22, 0x42),   # 2 深蓝
    (0x24, 0x44, 0x74),   # 3 中蓝
    (0x3E, 0x74, 0xB4),   # 4 亮蓝
    (0x6E, 0xBE, 0xF0),   # 5 青蓝（暴风高光）
]


def _chunk(typ, data):
    return (struct.pack(">I", len(data)) + typ + data
            + struct.pack(">I", zlib.crc32(typ + data) & 0xFFFFFFFF))


def write_indexed_png(path, width, height, rows, palette):
    """rows: list[height] of list[width] palette indices."""
    if len(palette) < 1 or len(palette) > 16:
        raise ValueError("palette must have 1..16 entries")
    for r in rows:
        if len(r) != width:
            raise ValueError("row width mismatch")
    ihdr = struct.pack(">IIBBBBB", width, height, 4, 3, 0, 0, 0)
    plte = b"".join(struct.pack(">BBB", *c) for c in palette)
    trns = bytes([0] + [255] * (len(palette) - 1))
    raw = bytearray()
    for r in rows:
        raw.append(0)                       # filter type 0 (None)
        for x in range(0, width, 2):
            hi = r[x] & 0x0F
            lo = (r[x + 1] & 0x0F) if (x + 1) < width else 0
            raw.append((hi << 4) | lo)
    blob = (b"\x89PNG\r\n\x1a\n"
            + _chunk(b"IHDR", ihdr)
            + _chunk(b"PLTE", plte)
            + _chunk(b"tRNS", trns)
            + _chunk(b"IDAT", zlib.compress(bytes(raw), 9))
            + _chunk(b"IEND", b""))
    with open(path, "wb") as fh:
        fh.write(blob)


# ───────────────────────── 绘图原语 ─────────────────────────

def blank(w, h):
    return [[0] * w for _ in range(h)]


def dot(canvas, x, y, idx, radius=0):
    h = len(canvas)
    w = len(canvas[0])
    for dy in range(-radius, radius + 1):
        for dx in range(-radius, radius + 1):
            cx, cy = x + dx, y + dy
            if 0 <= cx < w and 0 <= cy < h:
                canvas[cy][cx] = idx


def stroke(canvas, x0, y0, x1, y1, idx, radius=0):
    """Bresenham 段 + 圆形笔刷。"""
    dx = abs(x1 - x0)
    dy = -abs(y1 - y0)
    sx = 1 if x0 < x1 else -1
    sy = 1 if y0 < y1 else -1
    err = dx + dy
    x, y = x0, y0
    while True:
        dot(canvas, x, y, idx, radius)
        if x == x1 and y == y1:
            break
        e2 = 2 * err
        if e2 >= dy:
            err += dy
            x += sx
        if e2 <= dx:
            err += dx
            y += sy


def polyline(canvas, pts, idx, radius=0):
    for i in range(len(pts) - 1):
        stroke(canvas, pts[i][0], pts[i][1], pts[i + 1][0], pts[i + 1][1],
               idx, radius)


# 闪电主干（front 平面坐标；240 宽 x 160 高）
# ⚠️ OBJ 有两条硬约束（框架 docs/custom_spell_effects.md）：
#   ① 只有 0x1000 字节 **tile 座位**（32x4 = 128 块 8x8）；
#   ② 每帧 **OAM 条目 ≤ 16**。
#   细长斜线会被贪心打包拆成一堆 1x1/2x1 小矩形 ⇒ 条目爆表（实测 23）。
#   故画**粗壮、近垂直**的电柱（振幅 ±4，front 半径 2 / back 半径 3），
#   不画分叉 —— 占用区接近实心矩形，几块 4x4 就装完。「雷光链」的视觉
#   交给 BG 的暴风带 + 两帧节拍承担。
BOLT_FULL = [(120, 30), (124, 52), (116, 70), (124, 90), (116, 108), (120, 130)]
BOLT_HEAD = [(120, 30), (124, 52), (116, 70)]
BRANCHES = []


def draw_obj_back(plane):
    """back 平面：略宽的辉光（半径 3，仍保持实心矩形轮廓）。"""
    polyline(plane, BOLT_FULL, 1, radius=3)
    polyline(plane, BOLT_FULL, 2, radius=1)


def draw_obj_front(plane, full):
    """front 平面：电芯。full=False 时只画上半段且偏暗（起手帧）。"""
    path = BOLT_FULL if full else BOLT_HEAD
    polyline(plane, path, 3, radius=2)
    polyline(plane, path, 4, radius=1)
    if full:
        polyline(plane, path, 5, radius=0)
    for b in BRANCHES:
        polyline(plane, b, 3, radius=0)


def make_obj(full):
    canvas = blank(OBJ_W, OBJ_H)
    front = blank(240, OBJ_H)
    back = blank(240, OBJ_H)
    draw_obj_back(back)
    draw_obj_front(front, full)
    for y in range(OBJ_H):
        canvas[y][0:240] = front[y]
        canvas[y][240:480] = back[y]
    return canvas


def make_bg(frame):
    """暴风带：**逐行纯色**（同列同色 ⇒ 竖向切块后图块去重率极高，bgBytes 很小）。"""
    rows = blank(BG_W, BG_H)
    for y in range(BG_H):
        if y < 8:
            c = 1
        elif y < 16:
            c = 2
        elif y < 24:
            c = 3
        elif y < 30:
            c = 4
        elif y < 34:
            c = 5            # 一道贯穿全宽的高光带
        elif y < 44:
            c = 3
        elif y < 54:
            c = 2
        else:
            c = 1
        # 起手帧整体压暗一档，形成"酝酿 → 爆发"的两帧节拍
        if not frame and c > 1:
            c -= 1
        for x in range(BG_W):
            rows[y][x] = c
    return rows


SPELL_JSON = {
    "schemaVersion": 1,
    "soundTable": [{"id": "F1", "song": "SONG_F1"}],
}

ANIMATION_TXT = """# 《山河烬》惊雷引 —— 雷光链（feditor-magic-v1）
# 帧 0：蓄势（半截电枝）；帧 1：全链爆发。两帧各停 2 tick ⇒ totalFrames = 4。
# 音效 SF1 属于紧随其后那一帧的边界（即帧 1 起始）。
/// - Start Animation
O p- jingleiyin_obj_00.png
B p- jingleiyin_bg_00.png
2
SF1
O p- jingleiyin_obj_01.png
B p- jingleiyin_bg_01.png
2
~~~
"""


def main():
    os.makedirs(IMG, exist_ok=True)

    write_indexed_png(os.path.join(IMG, "jingleiyin_obj_00.png"),
                      OBJ_W, OBJ_H, make_obj(False), OBJ_PALETTE)
    write_indexed_png(os.path.join(IMG, "jingleiyin_obj_01.png"),
                      OBJ_W, OBJ_H, make_obj(True), OBJ_PALETTE)
    write_indexed_png(os.path.join(IMG, "jingleiyin_bg_00.png"),
                      BG_W, BG_H, make_bg(False), BG_PALETTE)
    write_indexed_png(os.path.join(IMG, "jingleiyin_bg_01.png"),
                      BG_W, BG_H, make_bg(True), BG_PALETTE)

    with open(os.path.join(PKG, "spell.json"), "w", encoding="utf-8") as fh:
        json.dump(SPELL_JSON, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    with open(os.path.join(PKG, "animation.txt"), "w", encoding="utf-8") as fh:
        fh.write(ANIMATION_TXT)

    for name in sorted(os.listdir(IMG)):
        print("  {:<28} {:>6} B".format(name,
              os.path.getsize(os.path.join(IMG, name))))


if __name__ == "__main__":
    sys.exit(main())
