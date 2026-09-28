#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""山河烬 · HOOKS seam 回归门禁 —— 把「HOOKS=0 时战斗数值恒等」变成可断言的门禁。

════════════════════════════════════════════════════════════════════════
为什么需要这个工具（M3 验收第 4 条的结项依据）
════════════════════════════════════════════════════════════════════════
M3 验收第 4 条原话是「`HOOKS=0` 时战斗数学与原版**字节一致**（回归）」。
2026-09-28 复核发现该措辞**不成立**，有两条硬证据：

  ① 上游 `src/bmbattle.c:514-523` 的注释自己写了 ——
     "the default and legacy builds hold zero references to the seam and
      compute vanilla battle stats identically (**stat identity, not a
      ROM-byte claim** -- the modern path carries no byte-identical-ROM
      requirement; see docs/issue-resolution-policy.md)"。
     ⇒ 框架承诺的是**数值恒等**，而且**明确否认** ROM 逐字节一致这个口径。

  ② 本项目对 `src/bmbattle.c` 有**两条永久补丁**（不由 HOOKS 开关控制）：
       - `shenqi-no-weapon-triangle.patch`：`BattleApplyWeaponTriangleEffect()`
         开头加 `IA_SHENQI` 守卫（6 行）—— **参与编译**，是永久特性；
       - `weapontriangle-magic-ring.patch`：改 `#if !GENERATED_DATA_WEAPONTRIANGLE_LINKED`
         里的**手写参考块**（6 行）—— **不参与编译**，只为了让 round-trip 校验闭嘴。
     ⇒ 「与上游字节一致」对一个带永久特性补丁的构建**逻辑上不可能**。

所以判据改成三条**可断言**的命题（本工具就是它们的执行体）：

  A. **门在工作**：`HOOKS=1` 时机制 seam 有且只有**一个**调用点，
     且就在 `ComputeBattleUnitStats` 里（正向对照）。
  B. **门关得死**：`HOOKS=0` 时整个目标文件对 `ExpansionMechanics*`
     **零引用**（不是"不生效"，是"不存在"）。
  C. **偏离可枚举**：`HOOKS=0` 下与**钉住的上游源码**（`framework.lock [framework] commit`）
     同档编译的结果相比 ——
       C1 `ComputeBattleUnitStats` 的函数体**逐字节相同**（数值恒等的直接证据）；
       C2 整个目标文件里**发生差异的节，只有** `BattleApplyWeaponTriangleEffect`
          （即"永久偏离"恰好等于我们声明的那一条；多一条就红）。

════════════════════════════════════════════════════════════════════════
怎么做的（为什么这样取证是可信的）
════════════════════════════════════════════════════════════════════════
★ 不重跑整条 ROM 构建（那要 ~15 分钟且只能证明"能链接"），而是**重放**
  `~/shanhe-logs/build-*.log` 里那条**真实的** `src/bmbattle.c` 编译命令行
  （日志逐字记录了 arm-none-eabi-gcc 的完整参数）。

  R1 **重放保真**：把重放得到的对象与构建目录里**真实**的 `bmbattle.o`
  逐字节比对。相同 ⇒ 证明"我验证时用的编译配置 = 实际构建用的配置"，
  后面所有结论才成立。这一条是**自校验**，防止拿一个偷偷用了不同 flag
  的编译结果去宣称门禁全绿（R-29 的教训：读源码常量不算，要读产物）。

  ⚠️ 因此本工具**只读**构建产物、**不写**构建目录：重放时剥掉 `-MMD/-MP/-MF/-MQ`
  （只影响 .d 依赖文件，不改 .o 字节），输出全部落进 `mktemp -d`。

用法：
  python3 tools/shanhe-hooks-regression.py                  # 全量门禁
  python3 tools/shanhe-hooks-regression.py --self-test      # 纯单元自测（不需编译器）
  python3 tools/shanhe-hooks-regression.py --mutation-test  # 负向测试（故意破坏门，必须转红）
退出码：0 = 全绿；2 = 有断言失败；3 = 前置缺失（调用方可据此 warn 而非 fail）。
"""

from __future__ import print_function

import argparse
import glob
import hashlib
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

C_OK = "\033[0;32m\u2714\033[0m"
C_BAD = "\033[0;31m\u2717\033[0m"
C_WARN = "\033[0;33m\u25b2\033[0m"

CC = "arm-none-eabi-gcc"
OBJCOPY = "arm-none-eabi-objcopy"
NM = "arm-none-eabi-nm"
OBJDUMP = "arm-none-eabi-objdump"
READELF = "arm-none-eabi-readelf"

HOOKS_TOKEN = "-DFE8_EXPANSION_MECHANICS_HOOKS="
SEAM_PREFIX = "ExpansionMechanics"
SEAM_APPLY = "ExpansionMechanicsApplyBattleStats"
STATS_FN = "ComputeBattleUnitStats"

BMBATTLE_REL = "src/bmbattle.c"
SHENQI_STAGED_REL = "src/shanhe_shenqi.c"
SHENQI_CONTENT_REL = "content/src/shanhe_shenqi.c"

# 不参与内容比对的节：符号表 / 重定位 / 调试 / 属性 / 注释。
# 注意**不排除** .text / .data / .rodata —— 万一某段代码没被 FFS 拆出来，
# 那正是最需要看见的差异；宁可多比一节，也不要漏掉一处未声明的改动。
_SKIP_SECTION_RE = re.compile(
    r"^(\.rel|\.debug|\.note|\.group|\.llvm_addrsig|\.comment$|\.ARM\.attributes$"
    r"|\.symtab$|\.strtab$|\.shstrtab$|\.ARM\.exidx)")

# FFS = function/data sections：加上它以后每个函数/只读数据各自成节，
# 于是"哪个函数变了"可以**按节逐字节**判定，不受字面池位移干扰。
FFS_FLAGS = ["-ffunction-sections", "-fdata-sections"]


# ────────────────────────────────────────────────────────────────────────
# 断言记录器（与 tools/shanhe-namecheck.py 同形）
# ────────────────────────────────────────────────────────────────────────
class Checker(object):
    def __init__(self, quiet=False):
        self.n_ok = 0
        self.n_bad = 0
        self.failures = []
        self.quiet = quiet

    def ok(self, msg):
        self.n_ok += 1
        if not self.quiet:
            print("%s %s" % (C_OK, msg))
        sys.stdout.flush()

    def bad(self, msg):
        self.n_bad += 1
        self.failures.append(msg)
        print("%s %s" % (C_BAD, msg))
        sys.stdout.flush()

    def die(self, msg):
        self.bad(msg)
        print("\n断言结果：%d 通过 / %d 失败" % (self.n_ok, self.n_bad))
        sys.exit(2)


# ────────────────────────────────────────────────────────────────────────
# 纯函数区（--self-test 直接覆盖这一层）
# ────────────────────────────────────────────────────────────────────────
def find_bmbattle_command(lines):
    """在构建日志的若干行里，找出那条真正编译 src/bmbattle.c 的命令行。

    判据必须**同时**满足三点，缺一不可（只按 "bmbattle" 匹配会命中
    `bmbattle.d`/`bmbattle.o` 之类的产物路径而挑到错误行）：
      1. 以 arm-none-eabi-gcc 开头（可能带引号）；
      2. 含 `-c "src/bmbattle.c"`（相对路径，日志里就是字面量）；
      3. 含 `-o "…/bmbattle.o"`。
    """
    for raw in lines:
        line = raw.rstrip("\n")
        stripped = line.lstrip()
        if not (stripped.startswith('"arm-none-eabi-gcc"')
                or stripped.startswith("arm-none-eabi-gcc")):
            continue
        if '-c "src/bmbattle.c"' not in line and "-c src/bmbattle.c" not in line:
            continue
        if "-o " not in line:
            continue
        return line.strip()
    return None


def split_command(line):
    return shlex.split(line)


def strip_dep_flags(cmd):
    """剥掉只影响 .d 依赖文件、不影响 .o 字节的那几个参数。

    必须剥 —— 日志里的 `-MF build/…/bmbattle.d` 若原样重放，会**覆写**
    构建目录里的真实依赖文件，把增量构建搞坏。
    """
    out = []
    i = 0
    while i < len(cmd):
        tok = cmd[i]
        if tok in ("-MMD", "-MP", "-MG", "-M", "-MM"):
            i += 1
            continue
        if tok in ("-MF", "-MQ", "-MT"):
            i += 2
            continue
        out.append(tok)
        i += 1
    return out


def split_compile_command(cmd):
    """把 `…flags… -c <src> -o <obj>` 拆成 (flags, src, obj)。

    找不到 `-c` 或 `-o` 就抛 ValueError —— 宁可硬失败，也不要静默拿一个
    半截命令去编译然后自证清白。
    """
    if "-c" not in cmd:
        raise ValueError("compile command has no -c")
    ci = cmd.index("-c")
    if ci + 1 >= len(cmd):
        raise ValueError("compile command has a dangling -c")
    src = cmd[ci + 1]
    flags = cmd[:ci]
    tail = cmd[ci + 2:]
    obj = None
    rest = []
    i = 0
    while i < len(tail):
        if tail[i] == "-o":
            if i + 1 >= len(tail):
                raise ValueError("compile command has a dangling -o")
            obj = tail[i + 1]
            i += 2
            continue
        rest.append(tail[i])
        i += 1
    if obj is None:
        raise ValueError("compile command has no -o")
    if rest:
        raise ValueError("unexpected tokens after -c/-o: %r" % rest)
    return flags, src, obj


def set_hooks(cmd, value):
    """把命令里的 HOOKS 宏定义改成 value（1 / 0）。

    找不到该 token 视为**硬错误**：说明日志不是本项目的配置，
    静默追加一个定义会得到"同宏重复定义"的微妙结果。
    """
    hits = 0
    out = []
    for tok in cmd:
        if tok.startswith(HOOKS_TOKEN):
            out.append(HOOKS_TOKEN + str(value))
            hits += 1
        else:
            out.append(tok)
    if hits != 1:
        raise ValueError(
            "expected exactly one %s* token in the compile command, found %d"
            % (HOOKS_TOKEN, hits))
    return out


def with_output(cmd, obj):
    """替换命令里的 -o 目标（用于把产物重定向进临时目录）。"""
    flags, src, _old = split_compile_command(cmd)
    return flags + ["-c", src, "-o", obj]


def with_source(cmd, src):
    """替换被编译的源文件（用于拿钉住上游的同名文件做对照编译）。"""
    flags, _old_src, obj = split_compile_command(cmd)
    return flags + ["-c", src, "-o", obj]


def with_extra_flags(cmd, extra):
    flags, src, obj = split_compile_command(cmd)
    return flags + list(extra) + ["-c", src, "-o", obj]


def hooks_value(cmd):
    for tok in cmd:
        if tok.startswith(HOOKS_TOKEN):
            return tok[len(HOOKS_TOKEN):]
    return None


def parse_symtab(nm_output):
    """解析 `arm-none-eabi-nm` 输出 → {symbol: (kind, size_or_None, addr)}。"""
    syms = {}
    for line in nm_output.splitlines():
        parts = line.split()
        if len(parts) >= 3:
            syms[parts[-1]] = (parts[-2], parts[0], parts[1])
        elif len(parts) == 2:
            syms[parts[1]] = ("U", parts[0], None)
    return syms


def referenced_symbols(nm_output):
    """对象引用到的全部符号名（定义或未定义）。"""
    names = set()
    for line in nm_output.splitlines():
        parts = line.split()
        if parts:
            names.add(parts[-1])
    return names


def parse_sections(readelf_output):
    """解析 `arm-none-eabi-readelf -S -W` → [(name, type, size, offset)]。"""
    out = []
    pat = re.compile(
        r"^\s*\[\s*\d+\]\s+(\S+)\s+(\S+)\s+([0-9a-fA-F]+)\s+([0-9a-fA-F]+)\s+([0-9a-fA-F]+)")
    for line in readelf_output.splitlines():
        m = pat.match(line)
        if not m:
            continue
        name, sec_type = m.group(1), m.group(2)
        size = int(m.group(5), 16)
        out.append((name, sec_type, size, m.group(4)))
    return out


def comparable_sections(sections):
    """挑出应当逐字节比对的内容节（跳开符号表/重定位/调试等元数据节）。"""
    keep = []
    for name, sec_type, size, _off in sections:
        if sec_type in ("NULL", "NOBITS"):
            continue
        if _SKIP_SECTION_RE.match(name):
            continue
        if size == 0:
            continue
        keep.append(name)
    return sorted(set(keep))


def diff_sections(hashes_a, hashes_b):
    """返回两个 {节名: 内容哈希} 的对称差（只在一边出现 / 哈希不同）。"""
    names = set(hashes_a) | set(hashes_b)
    return sorted(n for n in names if hashes_a.get(n) != hashes_b.get(n))


def sha1_file(path):
    h = hashlib.sha1()
    with open(path, "rb") as fh:
        while True:
            chunk = fh.read(1 << 16)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


# ────────────────────────────────────────────────────────────────────────
# 「声明偏离面」的推导（唯一事实源 = content/framework-patch/*.patch 自身）
#
# ★ 为什么不写死一张期望清单（R-28 教训）：
#   "与上游相比只准有这几个函数变化"如果写成常量列表，它就变成了一张**豁免
#   名单** —— 后人往列表里补一行就"合规"了，门禁退化成仪式。
#   所以这里改为**从补丁文件推导**：逐个 hunk 定位它在源码里落在哪个函数
#   （用补丁的**新增行号**去查源码的顶层函数定义行表，而不是用 hunk 头部的
#   context —— git 的 context 给的是**前一个**函数名，会张冠李戴）。
# ────────────────────────────────────────────────────────────────────────
IDENT_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
FUNC_DEF_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_ \t\*]*?([A-Za-z_][A-Za-z0-9_]*)\s*\([^;{]*\)\s*\{\s*$")


def function_line_map(src_path):
    """源码里每个顶层函数定义的起始行 → [(lineno, name)]（按行号升序）。"""
    out = []
    with open(src_path, encoding="utf-8") as fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.rstrip("\n")
            if not line or line[0] in " \t#}":
                continue
            m = FUNC_DEF_RE.match(line)
            if m:
                out.append((lineno, m.group(1)))
    return out


def enclosing_function(fmap, lineno):
    """lineno 落在哪个顶层函数里（找不到 ⇒ None，即"文件作用域"）。"""
    name = None
    for ln, nm in fmap:
        if ln <= lineno:
            name = nm
        else:
            break
    return name


def iter_hunks(text, target_rel):
    """逐 hunk 产出 {'old_start', 'old', 'changed', 'body'}。

    ★ 行号一律用**旧文件**（= 钉住上游）编号，不用 `+N`。原因是本项目的补丁是
      手写的，其 `+N` 偏移会**被其它补丁先插行而失效**：实测
      `shenqi-no-weapon-triangle.patch` 的 hunk 头写 `+1944`，而它实际落到新文件的
      第 **1963** 行（差值 19 = 另一个补丁在它前面插的 1 + 18 行）。
      拿 `+N` 去查行号，会把守卫"归属"给 19 行之前的另一个函数
      （实测误判成 `BattleUnitTargetCheckCanCounter`），门禁于是报出
      "声明了却没生效"这种**假红**。`-N` 相对被改文件是稳定的，而查表用的
      函数行号表也来自同一份旧文件 ⇒ 两边口径一致。
    """
    out = []
    active = False
    hunk = None

    def flush():
        if hunk is not None:
            out.append(hunk)

    for line in text.split("\n"):
        if line.startswith("diff --git"):
            # 一份补丁可含多个目标文件；遇到新文件头必须解除"正在解析"状态，
            # 否则紧随的 `--- a/…` 会被误当成一行删除行。
            flush()
            hunk = None
            active = False
            continue
        if line.startswith("+++ "):
            flush()
            hunk = None
            dest = line[4:].strip()
            active = dest in (target_rel, "b/" + target_rel, "a/" + target_rel)
            continue
        if not active:
            continue
        if line.startswith("@@ "):
            flush()
            m = re.match(r"^@@ -(\d+)(?:,\d+)? \+\d+(?:,\d+)? @@", line)
            start = int(m.group(1)) if m else None
            hunk = {"old_start": start, "old": start, "changed": [], "body": []}
            continue
        if hunk is None or line.startswith("\\"):
            continue
        hunk["body"].append(line)
        tag = line[:1]
        if tag == "+":
            hunk["changed"].append(hunk["old"])
        elif tag == "-":
            hunk["changed"].append(hunk["old"])
            hunk["old"] += 1
        else:
            hunk["old"] += 1
    flush()
    return out


def declared_surface_from_patches(patches, fmap, target_rel):
    """从补丁文本推导「声明偏离面」。

    patches: [(文件名, 文本)]；fmap: **旧文件（钉住上游）**的函数定义行表。
    返回 (函数名集合, 文件作用域标识符集合, 命中的补丁文件名列表)。

    规则：一个 hunk 的**变更行**若落在某函数内 ⇒ 该函数进入"应当变化的 .text.*"
    集合；整块都落在函数外（数据表 / include 等）⇒ 记为"文件作用域"，收集该
    hunk 内出现的全部标识符，供后续核对数据节变化时追溯。
    """
    funcs, idents, files = set(), set(), []
    for fname, text in patches:
        if ("+++ b/" + target_rel) not in text and ("+++ " + target_rel) not in text:
            continue
        if fname not in files:
            files.append(fname)
        for hunk in iter_hunks(text, target_rel):
            owners = set()
            for ln in hunk["changed"]:
                if ln is None:
                    continue
                owner = enclosing_function(fmap, ln)
                if owner:
                    owners.add(owner)
            if owners:
                funcs |= owners
            else:
                idents |= set(IDENT_RE.findall("\n".join(hunk["body"])))
    return funcs, idents, files


def declared_surface(patch_dir, src_path, target_rel):
    patches = []
    for path in sorted(glob.glob(os.path.join(patch_dir, "*.patch"))):
        with open(path, encoding="utf-8") as fh:
            patches.append((os.path.basename(path), fh.read()))
    return declared_surface_from_patches(patches, function_line_map(src_path), target_rel)


def lock_commit(lock_path):
    """从 framework.lock 读 [framework] commit。"""
    section = None
    with open(lock_path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("[") and line.endswith("]"):
                section = line[1:-1].strip()
                continue
            if section == "framework" and line.startswith("commit"):
                return line.split("=", 1)[1].strip()
    return None


def lock_framework_path(lock_path):
    section = None
    with open(lock_path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("[") and line.endswith("]"):
                section = line[1:-1].strip()
                continue
            if section == "framework" and line.startswith("path"):
                return line.split("=", 1)[1].strip()
    return None


# ────────────────────────────────────────────────────────────────────────
# 外部工具封装
# ────────────────────────────────────────────────────────────────────────
def run(cmd, cwd=None):
    proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    return proc.returncode, proc.stdout + proc.stderr


def have_tools():
    missing = [t for t in (CC, OBJCOPY, NM, OBJDUMP, READELF)
               if shutil.which(t) is None]
    return missing


def obj_sections(path):
    rc, out = run([READELF, "-S", "-W", path])
    if rc:
        raise RuntimeError("readelf -S failed on %s:\n%s" % (path, out))
    return comparable_sections(parse_sections(out))


def section_hashes(path, tmp_dir, tag):
    """把每个内容节 dump 成二进制再取哈希 → {节名: sha1}。"""
    hashes = {}
    for name in obj_sections(path):
        binp = os.path.join(tmp_dir, "sec_%s_%s.bin" % (tag, name.replace(".", "_")))
        rc, out = run([OBJCOPY, "-O", "binary", "--only-section=%s" % name, path, binp])
        if rc or not os.path.isfile(binp):
            hashes[name] = "OBJCOPY_FAILED:%s" % out.strip()[:60]
            continue
        hashes[name] = sha1_file(binp)
    return hashes


def section_bytes(path, section, tmp_dir, tag):
    binp = os.path.join(tmp_dir, "one_%s_%s.bin" % (tag, section.replace(".", "_")))
    rc, out = run([OBJCOPY, "-O", "binary", "--only-section=%s" % section, path, binp])
    if rc:
        return None
    with open(binp, "rb") as fh:
        return fh.read()


def reloc_sections_for(path, symbol):
    """`objdump -r` 里 symbol 出现在哪些节、各几次。"""
    rc, out = run([OBJDUMP, "-r", path])
    if rc:
        raise RuntimeError("objdump -r failed:\n" + out)
    section = None
    counts = {}
    for line in out.splitlines():
        m = re.match(r"RELOCATION RECORDS FOR \[(.+)\]:", line)
        if m:
            section = m.group(1)
            continue
        if section is not None and symbol in line:
            counts[section] = counts.get(section, 0) + 1
    return counts


# ────────────────────────────────────────────────────────────────────────
# 门禁主体
# ────────────────────────────────────────────────────────────────────────
class Suite(object):
    def __init__(self, ck, framework, base_cmd, payload_src, upstream_src, tmp,
                 patch_dir):
        self.ck = ck
        self.framework = framework
        self.base_cmd = base_cmd
        self.payload_src = payload_src   # 被验证的 bmbattle.c（工作区 / 变异副本）
        self.upstream_src = upstream_src  # 钉住上游的同名文件
        self.tmp = tmp
        self.patch_dir = patch_dir

    def _compile(self, name, hooks, ffs, src=None):
        """按日志配方编译一份变体。

        src=None ⇒ 完全沿用日志里的源文件路径（R1 的"逐字重放"必须走这条，
        否则就不是重放了）；其余断言显式传入要编译的源文件。
        """
        cmd = strip_dep_flags(self.base_cmd)
        cmd = set_hooks(cmd, hooks)
        if ffs:
            cmd = with_extra_flags(cmd, FFS_FLAGS)
        if src is not None:
            cmd = with_source(cmd, src)
        out = os.path.join(self.tmp, name)
        cmd = with_output(cmd, out)
        rc, log = run(cmd, cwd=self.framework)
        return rc, log, out

    def run(self):
        ck = self.ck
        real_obj = split_compile_command(strip_dep_flags(self.base_cmd))[2]
        real_obj_abs = real_obj if os.path.isabs(real_obj) \
            else os.path.join(self.framework, real_obj)

        # ── R1 重放保真 ──────────────────────────────────────────────
        rc, log, replay = self._compile("replay_ours_hooks1.o", 1, False)
        if rc:
            ck.bad("R1 重放编译失败（这道门自己也编不过，说明配方与当前框架不匹配）：\n%s"
                   % log.strip()[-1200:])
            return
        if not os.path.isfile(real_obj_abs):
            ck.bad("R1 找不到真实构建产物 %s —— 先跑一次 tools/shanhe-build.sh"
                   % real_obj_abs)
            return
        got, want = sha1_file(replay), sha1_file(real_obj_abs)
        if got != want:
            ck.bad("R1 重放保真失败：重放对象 %s ≠ 真实产物 %s\n"
                   "    ⇒ 我用的编译配置与实际构建不一致，后续结论无效。"
                   "（常见原因：构建后框架源码或生成物又变了）" % (got[:12], want[:12]))
            return
        ck.ok("R1 重放保真：重放 %s == 真实构建产物 %s（逐字节），"
              "⇒ 后续断言用的是**实际构建的编译配置**" % (got[:12], real_obj))

        # ── 正向对照：HOOKS=1 ───────────────────────────────────────
        rc, log, ours1 = self._compile("ours_hooks1.o", 1, True, src=self.payload_src)
        if rc:
            ck.bad("编译 HOOKS=1 变体失败：\n%s" % log.strip()[-1200:])
            return
        rc, log, ours0 = self._compile("ours_hooks0.o", 0, True, src=self.payload_src)
        if rc:
            ck.bad("编译 HOOKS=0 变体失败：\n%s" % log.strip()[-1200:])
            return

        _rc, nm1 = run([NM, ours1])
        _rc, nm0 = run([NM, ours0])
        refs1 = referenced_symbols(nm1)
        refs0 = referenced_symbols(nm0)

        seam1 = sorted(s for s in refs1 if SEAM_PREFIX in s)
        seam0 = sorted(s for s in refs0 if SEAM_PREFIX in s)
        if not seam1:
            ck.bad("R-A 正向对照失败：HOOKS=1 的对象里**没有**任何 %s* 符号 —— "
                   "门没接上（补丁丢了？seam 调用被删了？）" % SEAM_PREFIX)
        else:
            ck.ok("R-A 正向对照：HOOKS=1 的对象引用到 %s（共 %d 个 %s* 符号）"
                  % (SEAM_APPLY, len(seam1), SEAM_PREFIX))

        reld = reloc_sections_for(ours1, SEAM_APPLY)
        expect_reloc = {".text." + STATS_FN: 1}
        if reld != expect_reloc:
            ck.bad("R-A2 调用点不唯一：%s 的重定位分布为 %r，期望 %r"
                   " —— 机制 seam 只允许在 %s 里被调用一次"
                   % (SEAM_APPLY, reld, expect_reloc, STATS_FN))
        else:
            ck.ok("R-A2 调用点唯一：%s 恰好在 .text.%s 里出现 1 次重定位"
                  % (SEAM_APPLY, STATS_FN))

        # ── 反向：HOOKS=0 必须零引用 ─────────────────────────────────
        if seam0:
            ck.bad("R-B HOOKS=0 仍然引用机制 seam：%s —— 门没关死。"
                   "这会让「关掉机制」的构建照样被注册表改写战斗数值"
                   % ", ".join(seam0[:5]))
        else:
            ck.ok("R-B HOOKS=0 对 %s* 零引用（nm 全表扫描）—— "
                  "机制 seam 被整块编译掉，不是「注册了但不生效」" % SEAM_PREFIX)
        if STATS_FN not in refs0 and (".text." + STATS_FN) not in refs0:
            ck.bad("R-B2 HOOKS=0 对象里找不到 %s —— 不应该" % STATS_FN)

        # ── 与钉住上游的对照 ─────────────────────────────────────────
        rc, log, upstream0 = self._compile("upstream_hooks0.o", 0, True,
                                           src=self.upstream_src)
        if rc:
            ck.bad("编译钉住上游的 bmbattle.c 失败：\n%s" % log.strip()[-1200:])
            return

        stats_ours = section_bytes(ours0, ".text." + STATS_FN, self.tmp, "ours0")
        stats_up = section_bytes(upstream0, ".text." + STATS_FN, self.tmp, "up0")
        if stats_ours is None or stats_up is None:
            ck.bad("R-C1 取不到 .text.%s 的字节（FFS 未生效？）" % STATS_FN)
        elif stats_ours != stats_up:
            ck.bad("R-C1 %s 的函数体与钉住上游**不一致**（本侧 %d 字节 vs 上游 %d 字节）"
                   " —— 战斗数值恒等被破坏：有人把改动写进了这个函数（而不是走 seam）"
                   % (STATS_FN, len(stats_ours), len(stats_up)))
        else:
            ck.ok("R-C1 数值恒等：HOOKS=0 的 %s 与钉住上游**逐字节相同**（%d 字节）"
                  % (STATS_FN, len(stats_ours)))

        h_ours = section_hashes(ours0, self.tmp, "ours0")
        h_up = section_hashes(upstream0, self.tmp, "up0")
        changed = diff_sections(h_ours, h_up)
        changed_text = set(s for s in changed if s.startswith(".text."))
        changed_other = set(s for s in changed if not s.startswith(".text."))

        # ★ 期望值**从补丁文件推导**，不写死（详见 declared_surface 段注释）。
        # 行号表用**钉住上游**那份（补丁的 -N 就是相对它的），两边口径才一致。
        decl_funcs, decl_idents, decl_files = declared_surface(
            self.patch_dir, self.upstream_src, BMBATTLE_REL)
        expect_text = set(".text." + fn for fn in decl_funcs)
        if not decl_funcs:
            ck.bad("R-C2a 偏离面推导为空 —— 解析不出任何改过 %s 的函数（补丁目录不对？）"
                   % BMBATTLE_REL)
            return
        print("    声明偏离面（推导自 %s，行号按钉住上游）: 函数 %s"
              % (", ".join(decl_files) or "—", ", ".join(sorted(decl_funcs)) or "—"))

        missing = sorted(expect_text - changed_text)
        extra = sorted(changed_text - expect_text)
        if missing:
            ck.bad("R-C2a 声明了却没生效：%s 在补丁里被改过，产物却与上游相同"
                   " —— 补丁没落地，或者被别的东西覆盖了" % ", ".join(missing))
        elif extra:
            ck.bad("R-C2a 未声明的战斗数学改动：%s 与上游不同，但没有任何补丁声明改它"
                   "（多出来的节就是证据）" % ", ".join(extra))
        else:
            ck.ok("R-C2a 代码偏离可枚举且**双向吻合**：变化的 .text.* 恰为补丁声明的 %s"
                  % ", ".join(sorted(changed_text)))

        unknown_other = [s for s in sorted(changed_other)
                         if not any(i in s for i in decl_idents)]
        if changed_other and not unknown_other:
            ck.ok("R-C2b 数据/只读节的变化也能追溯到声明：%s"
                  % ", ".join(sorted(changed_other)))
        elif unknown_other:
            ck.bad("R-C2b 出现无法追溯的数据节变化：%s（补丁里找不到对应标识符）"
                   % ", ".join(unknown_other))
        else:
            ck.ok("R-C2b 数据/只读节零变化 —— 未参与编译的参考块"
                  "（weapontriangle-magic-ring）确实不在产物里")

    def shenqi(self):
        """内容层机制文件在 HOOKS=0 下必须退化成空实现（符号保留、细节编译掉）。"""
        ck = self.ck
        staged = os.path.join(self.framework, SHENQI_STAGED_REL)
        if not os.path.isfile(staged):
            ck.bad("R-D 框架里没有 %s —— 构建第 3c 步没铺内容层源文件？"
                   % SHENQI_STAGED_REL)
            return
        rc, log, o0 = self._compile("shenqi_hooks0.o", 0, True, src=SHENQI_STAGED_REL)
        if rc:
            ck.bad("R-D 以 HOOKS=0 编译 %s 失败：\n%s" % (SHENQI_STAGED_REL,
                                                        log.strip()[-1200:]))
            return
        _rc, nms = run([NM, o0])
        refs = referenced_symbols(nms)
        seam = sorted(s for s in refs if SEAM_PREFIX in s)
        if seam:
            ck.bad("R-D HOOKS=0 时内容层机制文件仍引用 %s —— 禁用档没有退化干净"
                   % ", ".join(seam[:4]))
        elif "ShanheShenqiInstallMechanics" not in refs:
            ck.bad("R-D HOOKS=0 时 ShanheShenqiInstallMechanics 的符号消失了"
                   "（框架惯例是「符号保留、细节编译掉」）")
        else:
            ck.ok("R-D HOOKS=0 时内容层机制文件零 seam 引用、安装符号保留"
                  "（与框架 `#else` 惯例一致）")

        rc, log, o1 = self._compile("shenqi_hooks1.o", 1, True, src=SHENQI_STAGED_REL)
        if rc:
            ck.bad("R-D2 以 HOOKS=1 编译 %s 失败：\n%s" % (SHENQI_STAGED_REL,
                                                         log.strip()[-1200:]))
            return
        _rc, nms1 = run([NM, o1])
        refs1 = referenced_symbols(nms1)
        if not any("ExpansionMechanicsRegister" in s for s in refs1):
            ck.bad("R-D2 HOOKS=1 时内容层机制文件没引用 ExpansionMechanicsRegister"
                   " —— 破军机制其实没挂上")
        else:
            ck.ok("R-D2 HOOKS=1 时内容层机制文件正常注册（ExpansionMechanicsRegister 在位）")


# ────────────────────────────────────────────────────────────────────────
# --self-test：纯单元测试（不碰编译器）
#
# ⚠️ 2026-09-28 自纠：本函数第一版把断言写成 `ck.ok("好" if cond else "坏")` ——
#    `ck.ok()` 无条件计数，于是**整个自测恒绿**（连"S17 hunk 数不对：0"都被
#    印成 ✔）。这正是 R-28 记下的那类缺陷：**断言必须真的能失败**。
#    现在统一走 expect()，条件为假时走 ck.bad()。
# ────────────────────────────────────────────────────────────────────────
def expect(ck, cond, good, bad=None):
    if cond:
        ck.ok(good)
    else:
        ck.bad(bad if bad is not None else good)


def self_test():
    ck = Checker()
    log_lines = [
        'python3 -m scripts.assets --item-id-cap "0xCF" generate',
        '"arm-none-eabi-gcc" -DMODERN=1 -DFE8_EXPANSION_MECHANICS_HOOKS=1 '
        '-DFE8_EXPANSION_VERSION_STRING=\'"0.1.0"\' -Iinclude -I. -O2 '
        '-MMD -MP -MF "build/x/bmbattle.d" -MQ "build/x/bmbattle.o" '
        '-c "src/bmbattle.c" -o "build/x/bmbattle.o"',
        '"arm-none-eabi-gcc" -Iinclude -c "src/bmbattlex.c" -o "build/x/bmbattlex.o"',
    ]

    line = find_bmbattle_command(log_lines)
    expect(ck, line is not None and "src/bmbattle.c" in line,
           "S1 只挑出真正编译 bmbattle.c 的那一行",
           "S1 挑行失败：%r" % line)
    if line is None:
        print("\n自测：%d 通过 / %d 失败" % (ck.n_ok, ck.n_bad))
        return 2

    cmd = split_command(line)
    expect(ck, '-DFE8_EXPANSION_VERSION_STRING="0.1.0"' in cmd,
           "S2 shlex 正确解析带引号的定义与内嵌单引号",
           "S2 解析结果不对：%r" % cmd[:4])

    no_dep = strip_dep_flags(cmd)
    expect(ck,
           "-MMD" not in no_dep and "-MP" not in no_dep and "-MF" not in no_dep
           and "-MQ" not in no_dep
           and not any(t.endswith("bmbattle.d") for t in no_dep),
           "S3 依赖参数（-MMD/-MP/-MF/-MQ）被剥净，不会覆写构建目录的 .d",
           "S3 仍有残留：%r" % no_dep)

    hooks1 = set_hooks(cmd, 0)
    expect(ck, hooks_value(hooks1) == "0" and hooks_value(cmd) == "1",
           "S4 HOOKS 换成 0 且只换一处",
           "S4 换值失败：原=%s 新=%s" % (hooks_value(cmd), hooks_value(hooks1)))

    try:
        flags, src, obj = split_compile_command(no_dep)
    except ValueError as exc:
        flags, src, obj = [], "SPLIT_FAILED:%s" % exc, None
    expect(ck, src == "src/bmbattle.c" and obj == "build/x/bmbattle.o",
           "S5 命令拆分：src=%s obj=%s flags=%d 项" % (src, obj, len(flags)),
           "S5 拆分结果不对：src=%r obj=%r" % (src, obj))

    try:
        out2 = with_output(no_dep, "/tmp/zz.o")
        got2 = split_compile_command(out2)[2]
    except ValueError as exc:
        got2 = "FAILED:%s" % exc
    expect(ck, got2 == "/tmp/zz.o", "S6 -o 被替换为目标路径",
           "S6 替换失败：%r" % got2)

    try:
        ext = with_extra_flags(no_dep, FFS_FLAGS)
        ok7 = (ext.index("-ffunction-sections") < ext.index("-c")
               and ext[-1] == "build/x/bmbattle.o")
    except (ValueError, IndexError) as exc:
        ok7 = False
        ext = ["FAILED:%s" % exc]
    expect(ck, ok7, "S7 追加 FFS 标志后仍在 -c 之前（不破坏输入次序）",
           "S7 次序不对：%r" % ext[:3])

    try:
        src2 = with_source(no_dep, "/tmp/up.c")
        f2, s2, o2 = split_compile_command(src2)
        ok8 = s2 == "/tmp/up.c" and o2 == "build/x/bmbattle.o"
    except ValueError as exc:
        ok8 = False
    expect(ck, ok8, "S8 源文件被替换、-o 保留", "S8 替换失败")

    def _raises(fn):
        try:
            fn()
            return False
        except ValueError:
            return True

    expect(ck, _raises(lambda: set_hooks(["-Iinclude", "-c", "x.c"], 0)),
           "S9 缺 HOOKS 定义时报硬错误（不静默追加）",
           "S9 未报错（危险：会静默产出错误配置的对象）")

    nm_out = ("         U ExpansionMechanicsApplyBattleStats\n"
              "00000000 T ComputeBattleUnitStats\n"
              "00000018 T BattleApplyWeaponTriangleEffect\n"
              "00000040 r sWeaponTriangleRules\n")
    refs = referenced_symbols(nm_out)
    syms = parse_symtab(nm_out)
    expect(ck, len(refs) == 4 and "ExpansionMechanicsApplyBattleStats" in refs,
           "S10 nm 解析出 4 个符号名", "S10 解析失败：%r" % sorted(refs))
    expect(ck, syms.get("ComputeBattleUnitStats", (None,))[0] == "T",
           "S11 nm 解析出尺寸/类型", "S11 类型解析失败：%r"
           % (syms.get("ComputeBattleUnitStats"),))

    readelf_out = (
        "There are 7 section headers, starting at offset 0x1234:\n"
        "\n"
        "Section Headers:\n"
        "  [Nr] Name              Type            Addr     Off    Size   ES Flg Lk Inf Al\n"
        "  [ 0]                   NULL            00000000 000000 000000 00      0   0  0\n"
        "  [ 1] .text.ComputeBattleUnitStats PROGBITS 00000000 000034 00005c 00  AX  0   0  4\n"
        "  [ 2] .text.BattleApplyWeaponTriangleEffect PROGBITS 00000000 000090 000048 00 AX 0 0 4\n"
        "  [ 3] .symtab           SYMTAB          00000000 0000d8 000140 10      4   3  4\n"
        "  [ 4] .rel.text.ComputeBattleUnitStats REL 00000000 000218 000008 08  I 6 1 4\n"
        "  [ 5] .bss              NOBITS          00000000 000220 000010 00  WA  0   0  4\n")
    comp = comparable_sections(parse_sections(readelf_out))
    expect(ck,
           comp == [".text.BattleApplyWeaponTriangleEffect",
                    ".text.ComputeBattleUnitStats"],
           "S12 内容节筛选：留下两个 .text.*，滤掉 symtab/rel/NOBITS/NULL",
           "S12 筛选结果意外：%r" % comp)

    expect(ck, diff_sections({"a": "1", "b": "2"}, {"a": "1", "c": "3"}) == ["b", "c"],
           "S13 对称差：只在一边出现的节算差异", "S13 差异计算错")
    expect(ck, diff_sections({"a": "1"}, {"a": "2"}) == ["a"],
           "S14 对称差：内容不同算差异", "S14 哈希比较错")
    expect(ck, diff_sections({"a": "1"}, {"a": "1"}) == [],
           "S15 对称差：全同为空", "S15 空差错")
    expect(ck,
           diff_sections({"a": "1", ".text.ComputeBattleUnitStats": "x"},
                         {"a": "1", ".text.ComputeBattleUnitStats": "y"})
           == [".text.ComputeBattleUnitStats"],
           "S16 变异源（改了 ComputeBattleUnitStats）会被 R-C1/C2 抓到",
           "S16 未抓到")

    # ── 声明偏离面的推导（S17–S21）────────────────────────────────
    fmap = [(100, "Foo"), (160, "Bar")]
    patch = "\n".join([
        "diff --git a/src/bmbattle.c b/src/bmbattle.c",
        "index 111..222 100644",
        "--- a/src/bmbattle.c",
        "+++ b/src/bmbattle.c",
        "@@ -2,3 +2,4 @@",
        ' #include "constants/items.h"',
        '+#include "constants/items_expansion.h"',
        ' #include "constants/classes.h"',
        "@@ -40,3 +41,3 @@",
        " static CONST_DATA struct WeaponTriangleRule sWeaponTriangleRules[] = {",
        "-    { ITYPE_ANIMA, ITYPE_DARK,  -15, -1 },",
        "+    { ITYPE_ANIMA, ITYPE_DARK,  +15, +1 },",
        "@@ -150,3 +151,4 @@ void Foo(void) {",
        "     int a = 1;",
        "+    a += 2;",
        " }",
        "diff --git a/other/thing.c b/other/thing.c",
        "index 333..444 100644",
        "--- a/other/thing.c",
        "+++ b/other/thing.c",
        "@@ -1,2 +1,3 @@",
        "+int unrelated(void) { return 1; }",
    ])

    hunks = iter_hunks(patch, "src/bmbattle.c")
    expect(ck, len(hunks) == 3,
           "S17 逐 hunk 切块：3 个 hunk（不把 other/thing.c 混进来）",
           "S17 hunk 数不对：%d" % len(hunks))

    funcs, idents, files = declared_surface_from_patches(
        [("unit.patch", patch)], fmap, "src/bmbattle.c")
    expect(ck, funcs == {"Foo"},
           "S18 只把变更行落在函数内的 hunk 算作函数偏离（Foo）",
           "S18 推导出 %r（期望 {'Foo'}）" % sorted(funcs))
    expect(ck, "sWeaponTriangleRules" in idents,
           "S19 文件作用域 hunk 的上下文标识符被收集（sWeaponTriangleRules）",
           "S19 未收集到数据表名；已收集 %d 个标识符" % len(idents))
    expect(ck, "unrelated" not in funcs and "unrelated" not in idents,
           "S20 另一目标文件的改动不参与推导（unrelated 不在函数集里）",
           "S20 串台了")
    expect(ck, files == ["unit.patch"],
           "S21 命中的补丁文件名被记录", "S21 文件名记录不对：%r" % files)

    # ── 变异语义：把"解析器退化成哑巴"也纳入自测 ──────────────────
    expect(ck, declared_surface_from_patches([("p.patch", patch)], fmap, "src/none.c")[0]
           == set(),
           "S22 目标文件不匹配时推导为空集（调用方据此硬失败，不放行）",
           "S22 不该推导出函数")

    # ★ S23 回归：`+N` 偏移**过期**时仍必须靠 `-N` 正确归属。
    #   真实案例：shenqi-no-weapon-triangle.patch 写 `+1944`，实际落在新文件 1963 行。
    stale = "\n".join([
        "--- a/src/bmbattle.c",
        "+++ b/src/bmbattle.c",
        "@@ -151,2 +5,3 @@",
        "     int a = 1;",
        "+    a += 2; /* stale +N */",
        " }",
    ])
    f2 = declared_surface_from_patches([("stale.patch", stale)], fmap, "src/bmbattle.c")[0]
    expect(ck, f2 == {"Foo"},
           "S23 `+N` 过期时靠 `-N` 正确归属（真实补丁里 +1944 实为 1963 就是这个坑）",
           "S23 误判为 %r（期望 {'Foo'}）" % sorted(f2))

    h_stale = iter_hunks(stale, "src/bmbattle.c")
    expect(ck,
           len(h_stale) == 1 and h_stale[0]["old_start"] == 151
           and h_stale[0]["old"] == 153 and set(h_stale[0]["changed"]) == {152},
           "S24 hunk 结构体字段（old_start / old 游标 / changed）各自独立，不被游标覆写",
           "S24 结构不对：%r" % (h_stale,))

    print("\n自测：%d 通过 / %d 失败" % (ck.n_ok, ck.n_bad))
    return 0 if ck.n_bad == 0 else 2


# ────────────────────────────────────────────────────────────────────────
# 环境准备
# ────────────────────────────────────────────────────────────────────────
def locate_build_command(logs_dir):
    logs = sorted(glob.glob(os.path.join(logs_dir, "build-*.log")), reverse=True)
    for path in logs:
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                line = find_bmbattle_command(fh.readlines())
        except OSError:
            continue
        if line:
            return path, line
    return None, None


def extract_upstream(framework, commit, rel, dest):
    rc, out = run(["git", "-C", framework, "show", "%s:%s" % (commit, rel)])
    if rc:
        raise RuntimeError("git show %s:%s failed:\n%s" % (commit, rel, out))
    with open(dest, "w", encoding="utf-8") as fh:
        fh.write(out)
    return dest


def main():
    ap = argparse.ArgumentParser(description="山河烬 HOOKS seam 回归门禁")
    ap.add_argument("--framework", default=None, help="框架工作区（默认取 framework.lock 的 path）")
    ap.add_argument("--repo", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                    help="本仓库根（默认取脚本所在目录的上一级）")
    ap.add_argument("--logs-dir", default=None, help="构建日志目录（默认 $HOME/shanhe-logs）")
    ap.add_argument("--build-log", default=None, help="显式指定一份构建日志")
    ap.add_argument("--self-test", action="store_true", help="纯单元自测，不碰编译器")
    ap.add_argument("--mutation-test", action="store_true",
                    help="负向测试：故意破坏门（改 ComputeBattleUnitStats / 删 HOOKS 门），必须转红")
    ap.add_argument("--keep", action="store_true", help="保留临时目录（调试用）")
    args = ap.parse_args()

    if args.self_test:
        return self_test()

    repo = os.path.abspath(args.repo)
    lock = os.path.join(repo, "framework.lock")
    framework = args.framework
    if framework is None:
        rel = lock_framework_path(lock)
        framework = os.path.join(os.path.expanduser("~"), rel) if rel else None
    if not framework or not os.path.isdir(framework):
        print("%s 前置缺失：框架工作区不存在（%s）" % (C_WARN, framework))
        return 3

    missing = have_tools()
    if missing:
        print("%s 前置缺失：缺工具 %s" % (C_WARN, ", ".join(missing)))
        return 3

    logs_dir = args.logs_dir or os.path.join(os.path.expanduser("~"), "shanhe-logs")
    if args.build_log:
        log_path, line = args.build_log, None
        with open(log_path, encoding="utf-8", errors="replace") as fh:
            line = find_bmbattle_command(fh.readlines())
    else:
        log_path, line = locate_build_command(logs_dir)
    if not line:
        print("%s 前置缺失：%s 里找不到编译 src/bmbattle.c 的命令行"
              "（需要至少一次全量构建的日志）" % (C_WARN, logs_dir))
        return 3

    base_cmd = split_command(line)
    if hooks_value(base_cmd) != "1":
        print("%s 前置缺失：日志里的 HOOKS=%s，本项目 framework.lock 应为 1"
              % (C_WARN, hooks_value(base_cmd)))
        return 3

    commit = lock_commit(lock)
    if not commit:
        print("%s 前置缺失：framework.lock 里读不到 [framework] commit" % C_WARN)
        return 3

    print("=" * 72)
    print("山河烬 · HOOKS seam 回归门禁（M3 验收第 4 条）")
    print("=" * 72)
    print("框架工作区 : %s" % framework)
    print("编译配方   : %s（重放自真实构建日志）" % os.path.basename(log_path))
    print("上游基线   : %s" % commit[:12])
    print("-" * 72)

    tmp = tempfile.mkdtemp(prefix="shanhe-hooks-")
    try:
        upstream_src = extract_upstream(framework, commit, BMBATTLE_REL,
                                        os.path.join(tmp, "upstream_bmbattle.c"))

        if args.mutation_test:
            # 变异 1：把改动写进 ComputeBattleUnitStats（绕过 seam）→ R-C1/C2 必须红
            with open(os.path.join(framework, BMBATTLE_REL), encoding="utf-8") as fh:
                src = fh.read()
            needle = ("void ComputeBattleUnitStats(struct BattleUnit* attacker, "
                      "struct BattleUnit* defender) {")
            if needle not in src:
                print("%s 变异测试：找不到函数头部，跳过" % C_WARN)
                return 3
            mutated = src.replace(
                needle,
                needle + "\n    attacker->battleAttack += 1; /* MUTATION */\n", 1)
            mut_path = os.path.join(tmp, "mutated_bmbattle.c")
            with open(mut_path, "w", encoding="utf-8") as fh:
                fh.write(mutated)

            ck = Checker(quiet=True)
            suite = Suite(ck, framework, base_cmd, mut_path, upstream_src, tmp,
                          os.path.join(repo, "content", "framework-patch"))
            suite.run()
            print("变异 1（在 %s 里加一句 attacker->battleAttack += 1）" % STATS_FN)
            print("  → %d 通过 / %d 失败" % (ck.n_ok, ck.n_bad))
            ok1 = ck.n_bad > 0
            print("%s 变异 1 被拦下（门有效）" % (C_OK if ok1 else C_BAD))
            if not ok1:
                print("      注：R-C1/R-C2a 应当转红 —— 这是门的核心断言")

            # 变异 2 / 对照：未变异的源码必须全绿（证明变异 1 的红是"因为变异"）
            ck2 = Checker(quiet=True)
            Suite(ck2, framework, base_cmd, BMBATTLE_REL, upstream_src, tmp,
                  os.path.join(repo, "content", "framework-patch")).run()
            ok2 = ck2.n_bad == 0
            print("%s 对照：未变异的源码全绿（%d 通过 / %d 失败）"
                  % (C_OK if ok2 else C_BAD, ck2.n_ok, ck2.n_bad))
            if not ok2:
                for f in ck2.failures:
                    print("      " + f.splitlines()[0])
            return 0 if (ok1 and ok2) else 2

        ck = Checker()
        suite = Suite(ck, framework, base_cmd, BMBATTLE_REL, upstream_src, tmp,
                      os.path.join(repo, "content", "framework-patch"))
        suite.run()
        suite.shenqi()

        # R-E 内容层源文件与框架里的铺设副本必须一致（否则验证的不是同一份）
        content_src = os.path.join(repo, SHENQI_CONTENT_REL)
        staged = os.path.join(framework, SHENQI_STAGED_REL)
        if os.path.isfile(content_src) and os.path.isfile(staged):
            if sha1_file(content_src) == sha1_file(staged):
                ck.ok("R-E 内容层 %s 与框架铺设副本逐字节一致" % SHENQI_CONTENT_REL)
            else:
                ck.bad("R-E %s 与框架 %s 不一致 —— 框架里跑的不是内容层的这份"
                       % (SHENQI_CONTENT_REL, SHENQI_STAGED_REL))

        print("-" * 72)
        print("断言结果：%d 通过 / %d 失败 —— HOOKS seam 回归"
              "（重放保真 / 门在工作 / 门关得死 / 数值恒等 / 偏离可枚举）"
              % (ck.n_ok, ck.n_bad))
        return 0 if ck.n_bad == 0 else 2
    finally:
        if args.keep:
            print("临时目录（已保留）：%s" % tmp)
        else:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
