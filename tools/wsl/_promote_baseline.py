#!/usr/bin/env python3
"""把 8 个新汉字的真字形插入冻结基线 fonts/cjk/febuilder-baseline/（zh-Hans 两套）。

背景：
  - 框架运行时字库 graphics/fonts/cjk/ = 「冻结全联合基线」经 FEHRR 源优先覆盖后的产物。
  - 新造字既不在冻结基线、也不在 FEHRR → split-runtime-corpora 报 no verified fallback。
  - 解法（用户拍板：扩冻结基线）：把本次 FEBuilder 渲染出的真字形并入基线，使 fallback 存在。

输入：
  - graphics/fonts/cjk/zh-Hans.{system,talk}.{codepoints.u32le,widths.u8,glyphs.2bpp}
    （本次 FEBuilder import-package 的产物，已含 8 字真字形）
输出：
  - fonts/cjk/febuilder-baseline/zh-Hans.{system,talk}.* 原位扩增
  - fonts/cjk/febuilder-baseline/manifest.json 重算 sha256/byte_count
"""
import hashlib
import json
import struct
import sys
from pathlib import Path

ROOT = Path.home() / "projects" / "fireemblem8-expansion"
SRC = ROOT / "graphics" / "fonts" / "cjk"
BASE = ROOT / "fonts" / "cjk" / "febuilder-baseline"
NEED = [ord(c) for c in "佩拗耳聪虞郎鸣鼎"]
STRIDE = 64


def sha(b):
    return hashlib.sha256(b).hexdigest()


def load_dir(d, prefix):
    cps = (d / f"{prefix}.codepoints.u32le").read_bytes()
    arr = list(struct.unpack("<%dI" % (len(cps) // 4), cps))
    widths = list((d / f"{prefix}.widths.u8").read_bytes())
    glyphs = (d / f"{prefix}.glyphs.2bpp").read_bytes()
    assert len(widths) == len(arr), (prefix, len(widths), len(arr))
    assert len(glyphs) == len(arr) * STRIDE, (prefix, len(glyphs), len(arr) * STRIDE)
    return arr, widths, glyphs


def main():
    manifest_path = BASE / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    assert manifest["kind"] == "fe8u-febuilder-full-union-baseline"

    for style in ("system", "talk"):
        prefix = f"zh-Hans.{style}"
        # 源：本次 FEBuilder 产物（含 8 字真字形）
        s_arr, s_w, s_g = load_dir(SRC, prefix)
        # 目标：冻结基线（union 版）
        b_arr, b_w, b_g = load_dir(BASE, prefix)

        have = set(b_arr)
        todo = [cp for cp in NEED if cp not in have]
        if not todo:
            print(f"[{prefix}] 基线已含全部 8 字，跳过")
            continue

        # 从源里取这 8 字的 (width, glyph)
        idx = {cp: i for i, cp in enumerate(s_arr)}
        add = []
        for cp in todo:
            i = idx[cp]
            add.append((cp, s_w[i], s_g[i * STRIDE:(i + 1) * STRIDE]))
            if set(s_g[i * STRIDE:(i + 1) * STRIDE]) == {0}:
                raise SystemExit(f"[{prefix}] {chr(cp)} 源字形为空，拒绝并入基线")

        rows = [(cp, b_w[i], b_g[i * STRIDE:(i + 1) * STRIDE])
                for i, cp in enumerate(b_arr)] + add
        rows.sort(key=lambda r: r[0])
        new_arr = [r[0] for r in rows]
        assert len(new_arr) == len(set(new_arr)), "重复 scalar"
        new_w = bytes(r[1] for r in rows)
        new_g = b"".join(r[2] for r in rows)

        (BASE / f"{prefix}.codepoints.u32le").write_bytes(
            struct.pack("<%dI" % len(new_arr), *new_arr))
        (BASE / f"{prefix}.widths.u8").write_bytes(new_w)
        (BASE / f"{prefix}.glyphs.2bpp").write_bytes(new_g)
        print(f"[{prefix}] 基线 {len(b_arr)} => {len(new_arr)}（+{len(todo)}）")

    # 重算 manifest
    for prefix, files in manifest["assets"].items():
        for suffix, record in files.items():
            payload = (BASE / f"{prefix}.{suffix}").read_bytes()
            record["byte_count"] = len(payload)
            record["sha256"] = sha(payload)
    manifest_path.write_bytes(
        json.dumps(manifest, ensure_ascii=False, indent=2).encode("utf-8") + b"\n")
    print("manifest.json 已重算")

    # 自检：8 字俱在
    for style in ("system", "talk"):
        a, _, _ = load_dir(BASE, f"zh-Hans.{style}")
        missing = [c for c in NEED if c not in set(a)]
        print(f"[{prefix}] 自检缺字: {missing or '无'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
