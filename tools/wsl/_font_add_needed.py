#!/usr/bin/env python3
"""《山河烬》字库补字：把「我们自己的文本」用到的字补进运行时字库（土办法，可复用）。

★ 为什么需要它：框架的 `generate-inventory` 被**上游 ja 侧**的 alias 缺失挡死
  （`ja/character_name_40/... 46px exceeds 40px without a display alias`，ja 不是本项目语言）
  ⇒ 我们绕开它，改为"手工把字插进语料 + 直接跑 FEBuilder 渲染链"。
  本脚本做前半段（算需求 + 改语料 + 改清单 sha），后半段见 tools/wsl/_run_font_pipeline.sh。

★★ 判据是**可推导的**（承接项目纪律：判据不能是手抄名单）：
  需要的字 = **我们 authored 的文本里出现的所有字符** ——
  从 content/ 下的文本/覆盖文件里扫出来，而不是维护一份"要补哪些字"的清单。
  新加文案时自动带上新字。

★ 三个实测坑（本脚本按此设计，勿改）：
  1) 语料基准不能用 `set(现有语料文本)` —— 语料常比运行时**少字**，重建会**丢字**。
  2) 语料基准也不能只用"HEAD 的同风格字集" —— 上游把一些字只放在 **talk** 集里，
     而旁白走 **system** ⇒ 仍会漏。
  3) ⇒ 基准 = **HEAD 版运行时字集（同风格）∪ 我们需要的字**（永不缩水）。

用法：
    python3 tools/wsl/_font_add_needed.py            # 只算 + 改（默认 dry-run 打印）
    APPLY=1 python3 tools/wsl/_font_add_needed.py    # 真正改语料/清单
之后（在框架目录）跑渲染链，见 _run_font_pipeline.sh 的 1~5 步 + 提升基线 + split-runtime。
"""
import hashlib
import io
import json
import os
import re
import struct
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FW = os.environ.get("FRAMEWORK_DIR", os.path.expanduser("~/projects/fireemblem8-expansion"))
APPLY = os.environ.get("APPLY") == "1"

# 控制码/语法标记里出现的 ASCII 不算"文字用字"
CTRL_RE = re.compile(r"\[(?:CTRL:[0-9A-Fa-f]+|[A-Za-z_.]+)\]")
ASCII_RE = re.compile(r"[\x00-\x7F]")

TEXT_GLOBS = ("content/texts", "content/data")


def authored_texts():
    """扫 content/ 下我们 authored 的文本，yield 字符串值。"""
    out = []
    for root_rel in TEXT_GLOBS:
        root = os.path.join(REPO, root_rel)
        for dirpath, _dirs, files in os.walk(root):
            for name in files:
                if not name.endswith(".json"):
                    continue
                p = os.path.join(dirpath, name)
                try:
                    data = json.load(io.open(p, encoding="utf-8"))
                except Exception:
                    continue
                out.extend(_walk_strings(data))
    return out


KEEP_FIELDS = ("replacement_text", "text", "name", "desc", "title")


def _walk_strings(node, parent=None):
    """收集「正文」字段下的字符串。

    ★ 必须**递归进所有键**（只对白名单键递归是错的：覆盖文件的正文在
      `messages.<id>.replacement_text` 里，顶层没有白名单键 ⇒ 会扫出 0 个字）。
      白名单只用来判断"这个字符串是不是正文"。
    """
    if isinstance(node, str):
        return [node] if parent in KEEP_FIELDS else []
    if isinstance(node, dict):
        acc = []
        for k, v in node.items():
            acc.extend(_walk_strings(v, k))
        return acc
    if isinstance(node, list):
        acc = []
        for v in node:
            acc.extend(_walk_strings(v, parent))
        return acc
    return []


def need_scalars():
    chars = set()
    for s in authored_texts():
        s = CTRL_RE.sub("", s)
        s = ASCII_RE.sub("", s)
        chars.update(s)
    return chars


def head_runtime_cps(style):
    """HEAD 版 tarball 里的运行时字集（同风格）。"""
    tar = subprocess.run(["git", "-C", REPO, "show",
                          "HEAD:content/fonts/shanhe-font-patch.tar.gz"],
                         capture_output=True, check=False)
    if tar.returncode != 0 or len(tar.stdout) < 1000:
        sys.exit("取不到 HEAD 的 content/fonts/shanhe-font-patch.tar.gz")
    os.makedirs("/tmp/_fonthead", exist_ok=True)
    io.open("/tmp/_fonthead/p.tgz", "wb").write(tar.stdout)
    subprocess.run(["tar", "-xzf", "/tmp/_fonthead/p.tgz", "-C", "/tmp/_fonthead"], check=True)
    raw = io.open("/tmp/_fonthead/graphics/fonts/cjk/zh-Hans.%s.codepoints.u32le" % style, "rb").read()
    return set(struct.unpack("<%dI" % (len(raw) // 4), raw))


def main():
    need = need_scalars()
    print("从 content/ 推导出需要 %d 个字" % len(need))
    changed = {}
    for style in ("system", "talk"):
        base = head_runtime_cps(style)
        miss = sorted(c for c in need if ord(c) not in base)
        print("[%s] HEAD 基线 %d 字；缺 %d 个：%s"
              % (style, len(base), len(miss), u"".join(miss) or "无"))
        if not miss:
            continue
        chars = base | set(ord(c) for c in need)
        text = u"".join(chr(c) for c in sorted(chars))
        changed[style] = (text, hashlib.sha256(text.encode("utf-8")).hexdigest(), len(chars))

    if not changed:
        print("字库已覆盖，无需补字")
        return 0
    if not APPLY:
        print("\n[dry-run] 加 APPLY=1 才真正写入语料与清单")
        return 0

    for style, (text, sha, n) in changed.items():
        p = os.path.join(FW, "fonts/cjk/corpora/zh-Hans.%s.txt" % style)
        io.open(p, "w", encoding="utf-8", newline="").write(text)
        print("[corpus/%s] 写出 %d 字 sha=%s" % (style, n, sha[:12]))

    # union = 两者并集
    us = set()
    for style, (text, _sha, _n) in changed.items():
        us |= set(ord(c) for c in text)
    io.open(os.path.join(FW, "fonts/cjk/corpora/union.txt"), "w",
            encoding="utf-8", newline="").write(u"".join(chr(c) for c in sorted(us)))

    mpath = os.path.join(FW, "fonts/cjk/febuilder-manifest.json")
    m = json.load(io.open(mpath, encoding="utf-8"))
    for job in m["jobs"]:
        b = os.path.basename(job["corpus"]["path"])
        key = "system" if b == "zh-Hans.system.txt" else ("talk" if b == "zh-Hans.talk.txt" else None)
        if key and key in changed:
            job["corpus"]["sha256"] = changed[key][1]
            print("  job %-16s sha -> %s" % (job["id"], changed[key][1][:12]))
    io.open(mpath, "w", encoding="utf-8", newline="\n").write(
        json.dumps(m, ensure_ascii=False, indent=2) + "\n")
    print("清单已更新 —— 接着跑 FEBuilder 渲染链（见 _run_font_pipeline.sh）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
