#!/usr/bin/env python3
"""shanhe-frame.py 的隔离测试 —— 只测 cmd_render 的**三档可信度判据**。

不依赖 ROM / 采集器：手工合成两份捕获 JSON（格式与上游 capture 输出同形），
按构造好的像素差喂进 cmd_render，断言它落进正确的分支。

跑法（无需 sudo、无需构建）：
    python3 tools/shanhe-frame.test.py
"""
from __future__ import annotations

import io
import json
import os
import re
import subprocess
import sys
import tempfile
from contextlib import redirect_stdout

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import importlib.util

_spec = importlib.util.spec_from_file_location(
    "shanhe_frame", os.path.join(os.path.dirname(os.path.abspath(__file__)), "shanhe-frame.py"))
sf = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sf)

W, H = sf.SCREEN_W, sf.SCREEN_H
FAILURES: list[str] = []


def _base_rgb(x: int, y: int) -> tuple[int, int, int]:
    return ((x * 7 + y * 3) & 0xFF, (x * 5) & 0xFF, (y * 11) & 0xFF)


def _write_cap(path: str, mutate=None) -> None:
    probes = []
    for y in range(H):
        for x in range(W):
            r, g, b = _base_rgb(x, y)
            if mutate is not None:
                r, g, b = mutate(x, y, r, g, b)
            probes.append({"x": x, "y": y, "value": "0x%02X%02X%02X" % (r, g, b)})
    json.dump({"checkpoints": [{"name": "all", "framebuffer": False, "probes": [],
                               "pixel_probes": probes}]},
              open(path, "w", encoding="utf-8"))


def _render(cap_a: str, cap_b: str, tmp: str) -> str:
    out = os.path.join(tmp, "out.png")
    buf = io.StringIO()
    with redirect_stdout(buf):
        rc = sf.cmd_render([cap_a, cap_b, out, "1"])
    assert rc == 0, "cmd_render 退出码 %d" % rc
    assert os.path.getsize(out) > 0, "PNG 未生成"
    return buf.getvalue()


def check(label: str, cond: bool, detail: str = "") -> None:
    if cond:
        print("  \033[0;32m✓\033[0m %s" % label)
    else:
        print("  \033[0;31m✗\033[0m %s%s" % (label, ("  —— " + detail) if detail else ""))
        FAILURES.append(label)


def check_prune() -> None:
    """prune_frames（shanhe-frame.sh）的隔离测试。

    **不复制函数体** —— 从 shanhe-frame.sh 里按行区间抽取 `prune_frames()` 再在
    临时目录里真跑一遍，这样源文件改了实现，测试跟着变，不会变成"测一个副本"。
    """
    sh = os.path.join(os.path.dirname(os.path.abspath(__file__)), "shanhe-frame.sh")
    src = open(sh, encoding="utf-8").read()
    m = re.search(r"^prune_frames\(\) \{\n(?:.*\n)*?^\}\n", src, re.M)
    if not m:
        check("能抽出 prune_frames()", False, sh)
        return
    check("能抽出 prune_frames()", True)

    tmp = tempfile.mkdtemp(prefix="shanhe-prune-test-")
    try:
        out = os.path.join(tmp, "out")
        os.makedirs(out)
        # 25 份「本工具命名」的文件，mtime 递增（1001 最老 … 1025 最新）
        for i in range(1, 26):
            p = os.path.join(out, "shanhe-boot-%d.png" % (1000 + i))
            open(p, "w").close()
            os.utime(p, (1759000000 + i, 1759000000 + i))
        # 两个**不该被碰**的文件
        open(os.path.join(out, "other-notes.txt"), "w").close()
        open(os.path.join(out, "shanhe-boot-nonnum.png"), "w").close()

        fn = os.path.join(tmp, "fn.sh")
        open(fn, "w", encoding="utf-8").write(m.group(0))
        script = (
            'set -euo pipefail\n'
            'OUT_DIR=%s\nOUT=%s\nSHANHE_FRAME_KEEP=20\n'
            '. %s\nprune_frames\n' % (out, os.path.join(out, "shanhe-boot-1025.png"), fn)
        )
        r = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
        check("prune_frames 正常退出", r.returncode == 0, r.stderr[:200])

        def exists(name):
            return os.path.exists(os.path.join(out, name))

        numbered = [f for f in os.listdir(out) if re.search(r"-\d+\.png$", f)]
        check("编号 PNG 恰保留 20 份", len(numbered) == 20, str(len(numbered)))
        check("保留的是**最新** 20 份（1006..1025）",
              all(exists("shanhe-boot-%d.png" % n) for n in range(1006, 1026)))
        check("删的是**最老** 5 份（1001..1005）",
              not any(exists("shanhe-boot-%d.png" % n) for n in range(1001, 1006)))
        check("非本工具命名的文件未被删", exists("other-notes.txt"))
        check("非数字后缀未被删", exists("shanhe-boot-nonnum.png"))

        # 幂等：再跑一次不该再删
        r2 = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
        check("prune_frames 幂等（再跑无删除输出）", r2.stdout.strip() == "", r2.stdout)
        check("幂等后仍是 20 份",
              len([f for f in os.listdir(out) if re.search(r"-\d+\.png$", f)]) == 20)
    finally:
        for f in os.listdir(tmp):
            p = os.path.join(tmp, f)
            if os.path.isdir(p):
                for g in os.listdir(p):
                    os.remove(os.path.join(p, g))
                os.rmdir(p)
            else:
                os.remove(p)
        os.rmdir(tmp)


def main() -> int:
    print("shanhe-frame.py 隔离测试（阈值 VISIBLE_DELTA=%d, STATIC_PCT_LIMIT=%.1f%%）\n"
          % (sf.VISIBLE_DELTA, sf.STATIC_PCT_LIMIT))
    tmp = tempfile.mkdtemp(prefix="shanhe-frame-test-")
    try:
        a = os.path.join(tmp, "a.json")
        _write_cap(a)

        # 档 1：两份完全一致 ⇒ 像素级完全静止（可当精确截图）
        b1 = os.path.join(tmp, "b1.json")
        _write_cap(b1)
        out1 = _render(a, b1, tmp)
        check("档1 完全相同 → 「像素级完全静止」", "像素级完全静止" in out1, out1)
        check("档1 有差异计数为 0", "有差异 0/" in out1, out1)

        # 档 2：2% 像素差 ±3（低于 VISIBLE_DELTA 的抖动噪声）⇒ 视觉上静止（不等于零差异！）
        def jitter(x, y, r, g, b):
            if (x + y) % 50 == 0:
                return (max(0, r - 3), g, b)
            return (r, g, b)
        b2 = os.path.join(tmp, "b2.json")
        _write_cap(b2, jitter)
        out2 = _render(a, b2, tmp)
        check("档2 亚阈值抖动 → 「视觉上静止」", "视觉上静止" in out2, out2)
        check("档2 **不**谎称零差异", "有差异 0/" not in out2, out2)
        check("档2 提示零差异要靠哈希/探针", "区块哈希" in out2, out2)

        # 档 3：50% 像素大幅改变 ⇒ 混合体
        def heavy(x, y, r, g, b):
            if x < W // 2:
                return (255 - r, 255 - g, 255 - b)
            return (r, g, b)
        b3 = os.path.join(tmp, "b3.json")
        _write_cap(b3, heavy)
        out3 = _render(a, b3, tmp)
        check("档3 半屏大改 → 「画面在动 / 混合体」", "混合体" in out3, out3)
        check("档3 给出首个差异坐标", "首个差异 @" in out3, out3)
        check("档3 不误报为静止", "静止" not in out3, out3)

        # 档 4：可见差异 9%（低于 STATIC_PCT_LIMIT）⇒ 基本静止，文字可信
        n_vis = int(W * H * 0.09)

        def edge(x, y, r, g, b):
            if y * W + x < n_vis:
                return (min(255, r + 40), g, b)
            return (r, g, b)
        b4 = os.path.join(tmp, "b4.json")
        _write_cap(b4, edge)
        out4 = _render(a, b4, tmp)
        check("档4 可见差异 9% → 「基本静止」", "基本静止" in out4, out4)
        check("档4 声明文字版面可信", "文字与版面可信" in out4, out4)
    finally:
        for f in os.listdir(tmp):
            os.remove(os.path.join(tmp, f))
        os.rmdir(tmp)

    print()
    print("prune_frames（shanhe-frame.sh 的取帧保留策略）隔离测试\n")
    check_prune()

    print()
    if FAILURES:
        print("\033[0;31m%d 项失败：%s\033[0m" % (len(FAILURES), ", ".join(FAILURES)))
        return 1
    print("\033[0;32m全部通过\033[0m")
    return 0


if __name__ == "__main__":
    sys.exit(main())
