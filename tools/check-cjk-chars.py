#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""缺字检查：给定中文文本，报出不在运行时字库里的字。

背景（《山河烬》）：
  框架的中文字库是「冻结全联合基线 + FEHRR 覆盖」的产物，zh-Hans 只覆盖
  system 1468 / talk 2385 个码点（其中汉字约 1441 / 2360）。
  **写原创剧情/菜单文本时，凡用到字库外的汉字，屏幕上就会出现空白/豆腐块。**
  框架的 `cjk-fonts-check` 会在构建期拦截（每一用到的码点必须在图集内），
  但那个报错发生在构建后；本工具用于**动笔时/提交前**快速自查。

用法：
  python3 tools/check-cjk-chars.py "守鼎世家虞家次子"          # 检查一段文本
  python3 tools/check-cjk-chars.py -f content/texts/*.json      # 检查文件（自动忽略非中文）
  python3 tools/check-cjk-chars.py --list-han                   # 打印全部可用汉字

字库来源（按顺序取第一个存在的）：
  $SHANHE_FRAMEWORK/graphics/fonts/cjk/zh-Hans.{system,talk}.codepoints.u32le
"""
import argparse
import glob
import os
import struct
import sys

DEFAULT_FRAMEWORKS = [
    os.environ.get("SHANHE_FRAMEWORK", ""),
    os.path.expanduser("~/projects/fireemblem8-expansion"),
    "/home/shanhe/projects/fireemblem8-expansion",
]

PREFIXES = ["zh-Hans.system", "zh-Hans.talk"]


def load_codepoints(prefix):
    for root in DEFAULT_FRAMEWORKS:
        if not root:
            continue
        path = os.path.join(root, "graphics", "fonts", "cjk", prefix + ".codepoints.u32le")
        if os.path.isfile(path):
            data = open(path, "rb").read()
            n = len(data) // 4
            return set(struct.unpack("<%dI" % n, data)), path
    return None, None


def main():
    ap = argparse.ArgumentParser(description="检查文本中不在运行时中文字库里的字")
    ap.add_argument("text", nargs="*", help="要检查的文本（可多个）")
    ap.add_argument("-f", "--files", nargs="*", default=[], help="要检查的文件（支持通配）")
    ap.add_argument("--list-han", action="store_true", help="打印全部可用汉字（按码点排序）")
    args = ap.parse_args()

    covered = set()
    srcs = []
    for p in PREFIXES:
        cps, path = load_codepoints(p)
        if cps is not None:
            covered |= cps
            srcs.append((p, len(cps), path))

    if not covered:
        print("❌ 找不到字库码点文件。请设置 SHANHE_FRAMEWORK 指向框架仓库根。", file=sys.stderr)
        return 2

    for p, n, path in srcs:
        print("字库 %-18s %5d 码点  <- %s" % (p, n, path))
    han = sorted(c for c in covered if 0x4E00 <= c <= 0x9FFF)   # covered 里是码点(int)
    print("合并后可用汉字 %d 个\n" % len(han))

    if args.list_han:
        print("".join(chr(c) for c in han))
        return 0

    # 收集输入
    chunks = list(args.text)
    for pat in args.files:
        for f in glob.glob(pat):
            try:
                raw = open(f, encoding="utf-8").read()
            except Exception as e:
                print("  (跳过 %s: %s)" % (f, e))
                continue
            if f.endswith(".json"):
                # 只检查真正会进游戏的文本，避免把 _comment/provenance 等元数据当内容
                try:
                    obj = json.loads(raw)
                except Exception:
                    chunks.append(raw); continue
                picked = []
                def walk(o):
                    if isinstance(o, dict):
                        for k, v in o.items():
                            if k in ("replacement_text", "text") and isinstance(v, str):
                                picked.append(v)
                            else:
                                walk(v)
                    elif isinstance(o, list):
                        for v in o: walk(v)
                walk(obj)
                if picked:
                    chunks.append(chr(10).join(picked))
                    print("  (%s: 仅检查 %d 条 replacement_text)" % (os.path.basename(f), len(picked)))
                else:
                    print("  (%s: 未找到 replacement_text，跳过元数据)" % os.path.basename(f))
            else:
                chunks.append(raw)
    if not chunks:
        print("（没有输入。用位置参数传文本，或 -f 传文件；--list-han 打印全表）")
        return 0

    total_missing = set()
    total_han = set()
    for i, txt in enumerate(chunks):
        used = set(txt)
        used_han = {c for c in used if 0x4E00 <= ord(c) <= 0x9FFF}   # used 里是字符(str)
        missing = sorted(used_han - {chr(c) for c in covered})
        total_han |= used_han
        total_missing |= set(missing)
        label = "输入 %d" % (i + 1)
        if len(chunks) == 1:
            label = "文本"
        if missing:
            print("❌ %s：用到汉字 %d 个，其中 %d 个不在字库：" % (label, len(used_han), len(missing)))
            print("   " + "".join(missing))
            print("   " + " ".join("U+%04X" % ord(c) for c in missing))
        else:
            print("✅ %s：用到汉字 %d 个，全部在字库内" % (label, len(used_han)))

    print()
    print("—— 合计：用到汉字 %d 个，缺 %d 个 ——" % (len(total_han), len(total_missing)))
    if total_missing:
        print("缺字：" + "".join(sorted(total_missing)))
        print("\n补字流程见 docs/5 §3.7（插占位 -> FEBuilder 渲染 -> 扩冻结基线 -> FEHRR 覆盖，产出 content/fonts/shanhe-font-patch.tar.gz）")
    return 1 if total_missing else 0


if __name__ == "__main__":
    sys.exit(main())
