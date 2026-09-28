#!/usr/bin/env python3
"""《山河烬》取帧工具的底层实现 —— 两个子命令：

  gen    <基础场景.json> <帧号> <输出场景.json> <forward|reverse>
         把「某个已有场景的按键脚本」与「从第 N 帧起 150 个连续帧、每帧一块 16x16 像素」
         组合成临时场景。forward = 第 i 块取第 N+i 帧；reverse = 第 i 块取第 N+149-i 帧。

  render <采集A.json> <采集B.json> <输出.png> [放大倍数]
         还原 PNG，并做**「拼接顺序无关性」**判定：把 forward / reverse 两份采集按同一
         块坐标还原成两张图，逐像素比较，落进**四档**结论之一：

             像素级完全静止 / 视觉上静止 / 基本静止（文字版面可信）/ 画面在动（混合体）

         前两档可当截图用，第三档只能用来读文字，第四档连文字都不可信。

--------------------------------------------------------------------------
为什么不直接比 framebuffer 哈希：整屏哈希把**背景美术**也算进去，而 FE8 的菜单
背景常常是滚动/渐隐的 —— 哈希每帧都变，但菜单面板本身是静止的。用哈希判静止会
**误报**（本项目实测：一张完整的存档槽选择画面被判成"96 段不同画面"）。
「正序 vs 逆序拼出来一样」则只关心**内容是否随时序变化**，正是我们需要的判据。
--------------------------------------------------------------------------
"""
from __future__ import annotations

import json
import struct
import sys
import zlib

SCREEN_W, SCREEN_H = 240, 160
BLOCK_W, BLOCK_H = 16, 16
BLOCK_PIXELS = BLOCK_W * BLOCK_H          # 256 = 上游每检查点上限
COLS = SCREEN_W // BLOCK_W                # 15
ROWS = SCREEN_H // BLOCK_H                # 10
BLOCKS = COLS * ROWS                      # 150 ⇒ 需要 150 个连续帧

# 单通道差值超过该值才算「可见差异」。GBA 的 dither / 调色板抖动会让同一块静止
# 版面在相邻帧间产生 ±1~2 的通道噪声，直接用 `d != 0` 会把静止画面误判成"在动"。
VISIBLE_DELTA = 8

# 可见差异占比低于该百分比即判「基本静止」——文字与版面可信，只有背景纹理在动。
STATIC_PCT_LIMIT = 10.0


def cmd_gen(argv: list[str]) -> int:
    base_path, start_frame, out_path = argv[0], int(argv[1]), argv[2]
    order = argv[3] if len(argv) > 3 else "forward"
    if order not in ("forward", "reverse"):
        print("order 只支持 forward / reverse，收到 %r" % order, file=sys.stderr)
        return 2
    base = json.load(open(base_path, encoding="utf-8"))

    last = start_frame + BLOCKS - 1
    # harness 硬约束：最后一个按键帧必须 <= 最后一个检查点帧
    frames = [f for f in base.get("frames", []) if f["end"] <= last]

    checkpoints = []
    for i in range(BLOCKS):
        src = i if order == "forward" else (BLOCKS - 1 - i)
        r, c = divmod(i, COLS)
        px = [
            {"x": c * BLOCK_W + x, "y": r * BLOCK_H + y}
            for y in range(BLOCK_H)
            for x in range(BLOCK_W)
        ]
        checkpoints.append({
            "name": "blk%03d" % i,
            "frame": start_frame + src,
            "framebuffer": True,
            "probes": [],
            "pixel_probes": px,
        })

    doc = {
        "schema_version": 1,
        "name": "shanhe-frame-tmp",
        "description": (
            "由 tools/shanhe-frame.sh 自动生成的临时场景（勿提交）：按键脚本取自 %s，"
            "order=%s，窗口 %d..%d。" % (base.get("name"), order, start_frame, last)
        ),
        "frames": frames,
        "checkpoints": checkpoints,
    }
    json.dump(doc, open(out_path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print("gen[%s]: 按键 %d 条，窗口 %d..%d -> %s" % (order, len(frames), start_frame, last, out_path))
    return 0


def _png(path: str, width: int, height: int, rows: list[bytes]) -> None:
    raw = b"".join(b"\x00" + r for r in rows)

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    blob = b"\x89PNG\r\n\x1a\n"
    blob += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    blob += chunk(b"IDAT", zlib.compress(raw, 9))
    blob += chunk(b"IEND", b"")
    open(path, "wb").write(blob)


def _grid(cap_path: str) -> list[list[tuple[int, int, int]]]:
    cap = json.load(open(cap_path, encoding="utf-8"))
    img = [[(0, 0, 0)] * SCREEN_W for _ in range(SCREEN_H)]
    for cp in cap["checkpoints"]:
        for pp in cp.get("pixel_probes", []):
            v = int(pp.get("value") or pp.get("rgb"), 16)
            img[pp["y"]][pp["x"]] = ((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF)
    return img


def cmd_render(argv: list[str]) -> int:
    cap_a, cap_b, out_path = argv[0], argv[1], argv[2]
    scale = int(argv[3]) if len(argv) > 3 else 3

    a = _grid(cap_a)
    b = _grid(cap_b)

    diff_px = 0
    vis_px = 0
    max_delta = 0
    first = None
    for y in range(SCREEN_H):
        for x in range(SCREEN_W):
            pa, pb = a[y][x], b[y][x]
            d = max(abs(pa[i] - pb[i]) for i in range(3))
            max_delta = max(max_delta, d)
            if d:
                diff_px += 1
                if d > VISIBLE_DELTA:
                    vis_px += 1
            if d and first is None:
                first = (x, y)

    total = SCREEN_W * SCREEN_H
    pct = 100.0 * vis_px / total
    print("拼接可信度：forward / reverse 两份采集逐像素比较（阈值：通道差 > %d 记可见）"
          % VISIBLE_DELTA)
    print("  有差异 %d/%d（%.1f%%）  可见差异 %d（%.2f%%）  最大通道差 %d"
          % (diff_px, total, 100.0 * diff_px / total, vis_px, pct, max_delta))
    if diff_px == 0:
        print("  \033[0;32m✓ 像素级完全静止\033[0m —— 该图就是这一帧的精确截图")
    elif vis_px == 0:
        print("  \033[0;32m✓ 视觉上静止\033[0m —— 全部 %d 个差异像素都在 ±%d 通道以内"
              "（GBA 调色板抖动噪声级别，肉眼不可分辨）" % (diff_px, VISIBLE_DELTA))
        print("     该图可当作这一帧的截图用；但**不要**据此断言「像素零差异」"
              "（真要零差异请用区块哈希或内存探针）")
    elif pct < STATIC_PCT_LIMIT:
        print("  \033[0;33m△ 基本静止\033[0m —— **文字与版面可信，可用于辨认屏幕 / 读文本**；")
        print("     但 %.1f%% 的像素（多半是背景纹理、内框动效）取自相邻帧，"
              "**不要当像素级截图用**" % pct)
    else:
        print("  \033[0;31m✗ 画面在动\033[0m（可见差异 %.1f%%，首个差异 @ (%d,%d)）—— "
              "拼出来的是**多画面混合体**" % (pct, first[0], first[1]))
        print("     ⇒ 它往往看起来还挺整齐，极具误导性（本项目实测踩过：")
        print("        「上半是模式选择、下半是存档槽」的伪截图）。")
        print("        此时只能谨慎用于**识别是哪块屏幕**，文字与数字都可能已是别帧的。")
        print("        要断言这类画面请改用内存探针或区块哈希（对某一具体帧）。")

    rows = []
    for y in range(SCREEN_H):
        row = bytearray()
        for x in range(SCREEN_W):
            r, g, bl = a[y][x]
            row += bytes((r, g, bl)) * scale
        for _ in range(scale):
            rows.append(bytes(row))
    _png(out_path, SCREEN_W * scale, SCREEN_H * scale, rows)
    print("render: %s (%dx%d)" % (out_path, SCREEN_W * scale, SCREEN_H * scale))
    return 0


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    mode, rest = sys.argv[1], sys.argv[2:]
    if mode == "gen":
        return cmd_gen(rest)
    if mode == "render":
        return cmd_render(rest)
    print("未知模式：%s" % mode, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
