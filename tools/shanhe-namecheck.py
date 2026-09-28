#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""山河烬 · 扩展道具「显示名」可达性断言（构建第 5 步检查 ⑥ 的实现）。

════════════════════════════════════════════════════════════════════════
为什么要这个工具
════════════════════════════════════════════════════════════════════════
2026-09-29 玩家实测缺陷：「主角背包里面没有照夜，而且突刺剑名字还没了」。
根因：扩展槽道具（item >= 0xCE）**没有任何可达的显示名** ——
框架的既定策略是扩展道具不绑共享消息表，`ItemData.nameTextId` 一律 0；
项目此前把名字写在 `authoringName`（只在不开启的 EXPANSION_STARTER_CONTENT
档才被消费）⇒ `GetItemName()` 的 vanilla 回落落到 `GetStringFromIndex(0)`
⇒ 界面上是一片空白。

而当时的验收网**只断言数值字段**（.number/.maxUses/.might/...），
正好从 nameTextId（u16 = 0）上读过去 ⇒ 数值全对、玩家什么都看不到。

所以本工具只做一件事：把「玩家在背包里看到的那几个字」从
**内容声明 → 扩展文本目录 → 生成的 C 表 → ROM 里的字节** 全链路钉死，
任何一环断开都以定位信息硬失败。它同时是 D-7 纪律
（机制类交付必须「可在游戏内看到 **或** 可被断言」）的执行体。

════════════════════════════════════════════════════════════════════════
被断言的链路（A→E）
════════════════════════════════════════════════════════════════════════
  A 内容声明     content/data/items_expansion.json 里的道具符号 → 数值 id
  B seam 映射    framework src/shanhe_item_names.c 的 { item, EXP_MSG_* } 表
                 （构建第 3c 步从 content/src/ 铺设的内容层源文件）
  C 扩展文本目录 framework texts/expansion/{registry,catalog.*}.json
                 （框架为「新增本地化玩家可见文本」准备的专用通道）
  D ROM 字节     gItemData[item] 的 .number / .nameTextId，以及名字的 UTF-8
                 字节**真的在 ROM 里**（中文名必须含非 ASCII 字符）
  E 调用点       framework src/bmitem.c（GetItemName + 英文语法判定）
                 与 src/msg.c（对话 [Item] 控制码 0x22）

⚠️ 探针只读 ROM/RAM 的**字节**，不执行游戏逻辑；「实机目视」仍是 D-7 的另一半，
   见 docs/5 §5.12 的验证阶梯 L0-L3。

退出码：0 = 全部通过；2 = 有断言失败（构建脚本据此 die）。
"""

import argparse
import io
import json
import os
import re
import struct
import subprocess
import sys
import unicodedata

# ── 与框架 / 项目约定的常量（改动需同步 docs/5 §5.14）────────────────────
ROM_BASE = 0x08000000
ITEMDATA_STRIDE = 0x24          # sizeof(struct ItemData)，含对齐填充
OFF_ITEM_NAMETEXTID = 0x00      # u16
OFF_ITEM_NUMBER = 0x06          # u8
ITEM_ID_EXPANSION_FIRST = 0xCE
SEAM_SOURCE_REL = "src/shanhe_item_names.c"
SEAM_NAME_BUFFER_DEFAULT = 32   # 与 seam 源文件里的 SHANHE_ITEM_NAME_BUFFER 对齐
NM = "arm-none-eabi-nm"

C_OK = "  \u2713"
C_BAD = "  \u2717"


class Checker:
    def __init__(self):
        self.n_ok = 0
        self.n_bad = 0

    def ok(self, msg):
        self.n_ok += 1
        print("%s %s" % (C_OK, msg))
        sys.stdout.flush()

    def bad(self, msg):
        self.n_bad += 1
        print("%s %s" % (C_BAD, msg))
        sys.stdout.flush()

    def die(self, msg):
        self.bad(msg)
        print("\n断言结果：%d 通过 / %d 失败" % (self.n_ok, self.n_bad))
        sys.exit(2)


def read_text(path):
    with io.open(path, encoding="utf-8") as fh:
        return fh.read()


def key_to_ident(key):
    """与 scripts/localization/generate.py 的 EXP_MSG_ 宏名规则一致。"""
    return re.sub(r"[^A-Za-z0-9]", "_", key).strip("_").upper()


def display_width(text):
    """框架 catalog.py 的宽度口径：东亚 W/F 记 2，其余记 1。"""
    return sum(2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
               for ch in text)


def enabled_locales(content_dir, fallback=("en", "zh-Hans")):
    """从 framework.lock 读 [features].enabled；读不到就用默认。"""
    lock = os.path.join(os.path.dirname(os.path.abspath(content_dir)), "framework.lock")
    if os.path.isfile(lock):
        for line in read_text(lock).splitlines():
            m = re.match(r"\s*enabled\s*=\s*(.+?)\s*$", line)
            if m:
                names = [x.strip() for x in m.group(1).split(",") if x.strip()]
                if names:
                    return names
    return list(fallback)


ITEM_ID_RE = re.compile(r"\s*(ITEM_[A-Za-z0-9_]+)\s*=\s*(0x[0-9A-Fa-f]+|\d+)\s*,?")
SEAM_PAIR_RE = re.compile(r"\{\s*(ITEM_[A-Za-z0-9_]+)\s*,\s*(EXP_MSG_[A-Za-z0-9_]+)\s*\}")


def parse_item_id_table_str(text):
    """include/constants/items_expansion.h 的正文 -> {符号名: 数值}"""
    table = {}
    for line in text.splitlines():
        m = ITEM_ID_RE.match(line)
        if m:
            table[m.group(1)] = int(m.group(2), 0)
    return table


def parse_item_id_table(path):
    return parse_item_id_table_str(read_text(path))


def parse_seam_table_str(text):
    """src/shanhe_item_names.c 的正文 -> [(item_symbol, msg_ident)]

    注意：正则不剥注释 —— 表体内**不要**写含 `{ ITEM_*, EXP_MSG_* }` 形态的注释，
    否则会被当成分支。表体外（文件头大段说明）随便写。
    """
    body = text.split("sShanheItemNames[]", 1)
    if len(body) < 2:
        return []
    body = body[1].split("};", 1)[0]
    return [(m.group(1), m.group(2)) for m in SEAM_PAIR_RE.finditer(body)]


def parse_seam_table(path):
    return parse_seam_table_str(read_text(path))


def nm_symbol(elf, name):
    """arm-none-eabi-nm -S -> (addr, size)；符号不存在返回 None。"""
    try:
        out = subprocess.run([NM, "-S", elf], capture_output=True)
    except OSError:
        return "NO_TOOL", None
    if out.returncode != 0:
        return "NO_TOOL", None
    for line in out.stdout.decode("utf-8", "replace").splitlines():
        parts = line.split()
        if len(parts) == 4 and parts[3] == name:
            return int(parts[0], 16), int(parts[1], 16)
    return None, None


def self_test():
    """隔离自测：只测不依赖框架/RAM/ROM 的纯函数与解析器。

    项目纪律：新增函数要配隔离测试，不接受"看起来没问题"。
    端到端的负向测试（喂旧 ROM → D6、移走 seam 源 → B0、清空正文 → C6）
    见 docs/5 §5.14 记录的实测结果。
    """
    cases = []

    # key_to_ident 必须与 scripts/localization/generate.py 的规则一致
    cases.append(("key_to_ident 点号→下划线",
                  key_to_ident("shanhe.item.zhaoye.name") == "SHANHE_ITEM_ZHAOYE_NAME"))
    cases.append(("key_to_ident 连字符与大小写",
                  key_to_ident("danger-overlay.HELP") == "DANGER_OVERLAY_HELP"))

    # display_width：东亚 W/F 记 2
    cases.append(("display_width 中文 2 字 = 4", display_width("照夜") == 4))
    cases.append(("display_width 英文 Zhaoye = 6", display_width("Zhaoye") == 6))

    # parse_item_id_table
    ids = parse_item_id_table_str("enum {\n"
                                  "    ITEM_SHANHE_POJUN = 0xCE,\n"
                                  "    ITEM_SHANHE_ZHAOYE = 0xCF,\n"
                                  "};\n")
    cases.append(("parse_item_id_table 两行",
                  ids == {"ITEM_SHANHE_POJUN": 0xCE, "ITEM_SHANHE_ZHAOYE": 0xCF}))

    # parse_seam_table（★ 表体内不要写含 { ITEM_*, EXP_MSG_* } 形态的注释）
    seam = parse_seam_table_str(
        "static const struct ShanheItemNameEntry\n"
        "{\n    ItemId item;\n    ExpansionMsgId msgId;\n} sShanheItemNames[] =\n"
        "{\n"
        "    /* 破军（枪，0xCE）。注册表 key: shanhe.item.pojun.name */\n"
        "    { ITEM_SHANHE_POJUN,  EXP_MSG_SHANHE_ITEM_POJUN_NAME  },\n"
        "    { ITEM_SHANHE_ZHAOYE, EXP_MSG_SHANHE_ITEM_ZHAOYE_NAME },\n"
        "};\n")
    cases.append(("parse_seam_table 恰好 2 条且首条正确",
                  len(seam) == 2
                  and seam[0] == ("ITEM_SHANHE_POJUN", "EXP_MSG_SHANHE_ITEM_POJUN_NAME")))
    cases.append(("parse_seam_table 无表时返回空表（不抛异常）",
                  parse_seam_table_str("int main(void) { return 0; }\n") == []))

    # 布局常量自洽
    cases.append(("ItemData 字段在 stride 内",
                  OFF_ITEM_NUMBER + 1 <= ITEMDATA_STRIDE
                  and OFF_ITEM_NAMETEXTID + 2 <= ITEMDATA_STRIDE))
    cases.append(("扩展槽起点 = 0xCE", ITEM_ID_EXPANSION_FIRST == 0xCE))
    cases.append(("stride 0x24 能整除 gItemData 实际尺寸 0x1D40",
                  0x1D40 % ITEMDATA_STRIDE == 0 and 0x1D40 // ITEMDATA_STRIDE == 208))

    n_bad = 0
    for name, good in cases:
        print("%s self-test %s" % (C_OK if good else C_BAD, name))
        if not good:
            n_bad += 1
    print("self-test：%d 通过 / %d 失败" % (len(cases) - n_bad, n_bad))
    return 0 if n_bad == 0 else 2



def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--self-test", action="store_true",
                    help="只跑纯函数隔离自测（不读框架 / ROM）")
    ap.add_argument("--content", help="content/ 目录")
    ap.add_argument("--framework", help="框架仓库根（已应用内容）")
    ap.add_argument("--rom", help="构建出的 ROM（.gba）")
    ap.add_argument("--elf", default=None, help="默认由 --rom 推导（.gba -> .elf）")
    ap.add_argument("--locales", default=None,
                    help="要求名字齐全的语言；默认读 framework.lock 的 enabled")
    args = ap.parse_args()

    if args.self_test:
        return self_test()
    for required in ("content", "framework", "rom"):
        if not getattr(args, required):
            print("缺少 --%s（或改用 --self-test）" % required)
            return 2

    ck = Checker()
    content = os.path.abspath(args.content)
    framework = os.path.abspath(args.framework)
    rom_path = os.path.abspath(args.rom)
    elf_path = os.path.abspath(args.elf) if args.elf else re.sub(r"\.gba$", ".elf", rom_path)
    locales = ([x.strip() for x in args.locales.split(",") if x.strip()]
               if args.locales else enabled_locales(content))

    print("=" * 72)
    print("山河烬 · 扩展道具显示名断言")
    print("  content   : %s" % content)
    print("  framework : %s" % framework)
    print("  rom       : %s" % rom_path)
    print("  elf       : %s" % elf_path)
    print("  locales   : %s" % ",".join(locales))
    print("=" * 72)

    # ── A. 内容声明 ───────────────────────────────────────────────────
    ids_path = os.path.join(framework, "include/constants/items_expansion.h")
    if not os.path.isfile(ids_path):
        ck.die("A0 找不到 %s（扩展道具 id 常量表缺失）" % ids_path)
    item_ids = parse_item_id_table(ids_path)

    items_json_path = os.path.join(content, "data/items_expansion.json")
    if not os.path.isfile(items_json_path):
        ck.die("A0 找不到 %s" % items_json_path)
    records = json.loads(read_text(items_json_path)).get("items", [])
    if not records:
        ck.die("A1 content/data/items_expansion.json 的 items[] 为空")

    declared = {}       # 数值 id -> 符号名
    for rec in records:
        sym = rec.get("item")
        if sym not in item_ids:
            ck.die("A1 内容里的道具符号 %r 不在 include/constants/items_expansion.h 里" % sym)
        declared[item_ids[sym]] = sym
    for item_id in sorted(declared):
        if item_id < ITEM_ID_EXPANSION_FIRST:
            ck.die("A2 %s = 0x%02X 落在原版 id 空间（< 0x%02X）—— 扩展道具名通道只覆盖扩展槽"
                   % (declared[item_id], item_id, ITEM_ID_EXPANSION_FIRST))
    ck.ok("A 内容声明：%d 个扩展道具 %s"
          % (len(declared),
             ", ".join("%s=0x%02X" % (declared[i], i) for i in sorted(declared))))

    # ── B. seam 映射（内容层源文件里的表）────────────────────────────
    seam_path = os.path.join(framework, SEAM_SOURCE_REL)
    if not os.path.isfile(seam_path):
        ck.die("B0 找不到 %s —— 构建第 3c 步没把 content/src/ 铺过来？"
               "（该文件是名字映射的唯一来源）" % seam_path)
    seam = parse_seam_table(seam_path)
    if not seam:
        ck.die("B1 从 %s 解析不出 sShanheItemNames[] 里的 { ITEM_*, EXP_MSG_* } 映射"
               % SEAM_SOURCE_REL)

    buf = re.search(r"#define\s+SHANHE_ITEM_NAME_BUFFER\s+(\d+)", read_text(seam_path))
    buf_size = int(buf.group(1)) if buf else SEAM_NAME_BUFFER_DEFAULT

    seam_by_item = {}
    for sym, ident in seam:
        if sym not in item_ids:
            ck.die("B2 seam 表里的 %s 不在 include/constants/items_expansion.h 里" % sym)
        seam_by_item[item_ids[sym]] = ident

    missing = sorted(set(declared) - set(seam_by_item))
    extra = sorted(set(seam_by_item) - set(declared))
    if missing:
        ck.die("B3 内容里有 0x%02X（%s）但 %s 的 seam 表没给它名字 —— 实机里它会是一片空白"
               % (missing[0], declared[missing[0]], SEAM_SOURCE_REL))
    if extra:
        ck.die("B3 seam 表给了 0x%02X 名字，但 content/data/items_expansion.json 里没有这条道具"
               % extra[0])
    ck.ok("B seam 映射：%d 条，与内容声明一一对应" % len(seam_by_item))

    # ── C. 扩展文本目录 ──────────────────────────────────────────────
    reg_path = os.path.join(framework, "texts/expansion/registry.json")
    if not os.path.isfile(reg_path):
        ck.die("C0 找不到 %s" % reg_path)
    registry = json.loads(read_text(reg_path)).get("messages", [])
    by_key = {e.get("key"): e for e in registry if e.get("key")}
    by_ident = {key_to_ident(k): k for k in by_key}

    active_ids = [e["id"] for e in registry if e.get("status") == "active"]
    if len(active_ids) != len(set(active_ids)):
        ck.die("C1 注册表里 active 条目的 id 有重复")
    if active_ids != sorted(active_ids):
        ck.die("C1 注册表里 active 条目的 id 不是严格升序（id 是 append-only 契约）")

    catalogs = {}
    for loc in locales:
        cat_path = os.path.join(framework, "texts/expansion/catalog.%s.json" % loc)
        if not os.path.isfile(cat_path):
            ck.die("C2 找不到 %s（语言 %s 的目录正文）" % (cat_path, loc))
        doc = json.loads(read_text(cat_path))
        if doc.get("locale") != loc:
            ck.die("C2 %s 里的 locale 字段是 %r，与文件名不符"
                   % (cat_path, doc.get("locale")))
        strings = doc.get("strings")
        if not isinstance(strings, dict):
            ck.die("C2 %s 没有 strings 对象（键值对正文）" % cat_path)
        catalogs[loc] = strings

    names = {}   # item_id -> {locale: text}
    for item_id, ident in sorted(seam_by_item.items()):
        key = by_ident.get(ident.replace("EXP_MSG_", "", 1))
        if key is None:
            ck.die("C3 seam 表用了 %s，但 texts/expansion/registry.json 里没有任何 key 映射到它"
                   "（key 改名后此处必须同步）" % ident)
        entry = by_key[key]
        if entry.get("status") != "active":
            ck.die("C3 key %s 的 status 不是 active（%r）" % (key, entry.get("status")))
        if not isinstance(entry.get("id"), int):
            ck.die("C3 key %s 没有显式整数 id（registry 的 id 必须显式钉死）" % key)
        max_bytes = entry.get("max_decoded_bytes")
        max_width = entry.get("max_width")
        if not isinstance(max_bytes, int) or not isinstance(max_width, int):
            ck.die("C4 key %s 缺 max_decoded_bytes / max_width" % key)
        if max_bytes > buf_size:
            ck.die("C5 key %s 的 max_decoded_bytes=%d 超过 seam 的 %d 字节缓冲 —— 拷贝会被截断"
                   % (key, max_bytes, buf_size))

        names[item_id] = {}
        for loc in locales:
            text = catalogs[loc].get(key)
            if not isinstance(text, str) or not text.strip():
                ck.die("C6 %s 在 catalog.%s.json 里没有非空正文（回退到别的语言也算不合格）"
                       % (key, loc))
            blen = len(text.encode("utf-8")) + 1
            wlen = display_width(text)
            if blen > max_bytes:
                ck.die("C7 %s 的 %s 正文 %r 解码后 %d 字节 > max_decoded_bytes=%d"
                       % (key, loc, text, blen, max_bytes))
            if wlen > max_width:
                ck.die("C7 %s 的 %s 正文 %r 显示宽 %d > max_width=%d"
                       % (key, loc, text, wlen, max_width))
            names[item_id][loc] = text

    # CJK 语言下的名字必须真的是非 ASCII（否则等于又贴了个英文占位符）
    for item_id, per_loc in sorted(names.items()):
        for loc in locales:
            if loc.lower() in ("en", "ja"):
                continue
            if all(ord(ch) < 128 for ch in per_loc[loc]):
                ck.die("C8 0x%02X 在 %s 下的名字 %r 全是 ASCII —— %s 档会显示英文占位符"
                       % (item_id, loc, per_loc[loc], loc))
    ck.ok("C 扩展文本目录：%d 个 key / %d 个语言正文齐全，且在宽度与字节上界内"
          % (len(seam_by_item), len(locales)))
    for item_id in sorted(names):
        ck.ok("C  0x%02X = %s" % (item_id,
                                  " / ".join("%s:%s" % (l, names[item_id][l]) for l in locales)))

    # ── D. ROM 字节 ───────────────────────────────────────────────────
    if not os.path.isfile(rom_path):
        ck.die("D0 找不到 ROM：%s" % rom_path)
    blob = open(rom_path, "rb").read()

    if not os.path.isfile(elf_path):
        ck.die("D0 找不到 ELF：%s（--elf 可显式指定）" % elf_path)
    addr, size = nm_symbol(elf_path, "gItemData")
    if addr == "NO_TOOL":
        ck.die("D1 跑不了 %s（没装 arm-none-eabi 工具链？）" % NM)
    if addr is None:
        ck.die("D1 ELF 里没有 gItemData 符号（%s）" % elf_path)
    if size % ITEMDATA_STRIDE != 0:
        ck.die("D2 gItemData 尺寸 0x%X 不是 stride 0x%X 的整数倍 —— ItemData 布局变了？"
               % (size, ITEMDATA_STRIDE))
    n_records = size // ITEMDATA_STRIDE
    base = addr - ROM_BASE
    if base < 0 or base + size > len(blob):
        ck.die("D2 gItemData（0x%08X）不在 ROM 的 0x%08X..0x%08X 范围内"
               % (addr, ROM_BASE, ROM_BASE + len(blob)))

    # D3 全表自洽：record[i].number == i。这条同时**证明** stride 与字段偏移是对的 ——
    #    否则下面按偏移读出来的 nameTextId 也是不可信的。
    mismatch = [i for i in range(n_records)
                if blob[base + i * ITEMDATA_STRIDE + OFF_ITEM_NUMBER] != i]
    if mismatch:
        ck.die("D3 gItemData 表自洽性失败：%d/%d 条记录的 .number != 自身下标（首例 %d）——"
               " stride/偏移假设已失效，后续名字断言不可信" % (len(mismatch), n_records, mismatch[0]))
    ck.ok("D ROM：gItemData @0x%08X，%d 条记录，全表 .number == 下标（布局假设成立）"
          % (addr, n_records))

    for item_id in sorted(seam_by_item):
        if item_id >= n_records:
            ck.die("D4 道具 0x%02X 超出 gItemData 的 %d 条记录" % (item_id, n_records))
        off = base + item_id * ITEMDATA_STRIDE
        number = blob[off + OFF_ITEM_NUMBER]
        name_id = struct.unpack_from("<H", blob, off + OFF_ITEM_NAMETEXTID)[0]
        if number != item_id:
            ck.die("D4 gItemData[0x%02X].number = 0x%02X，与下标不符" % (item_id, number))
        if name_id != 0:
            ck.die("D5 gItemData[0x%02X].nameTextId = 0x%04X ≠ 0 —— 扩展道具按框架策略必须"
                   "不绑共享消息表；绑上会取到无关的 FE8U 消息" % (item_id, name_id))
        # 名字的字节必须真的在 ROM 里（这是"玩家能看到这几个字"的**字节级**证据）
        for loc, text in sorted(names[item_id].items()):
            raw = text.encode("utf-8")
            hits = blob.count(raw)
            if hits < 1:
                ck.die("D6 0x%02X 的 %s 名字 %r（utf8 %s）在 ROM 里一个字节都找不到 ——"
                       " 说明它没被链进 ROM，实机必然是空白"
                       % (item_id, loc, text, raw.hex(" ")))
        ck.ok("D  0x%02X %-22s number=0x%02X nameTextId=0x0000  字节在 ROM：%s"
              % (item_id, declared[item_id], number,
                 " / ".join("%s×%d" % (loc, blob.count(names[item_id][loc].encode("utf-8")))
                            for loc in locales)))

    # ── E. 调用点 ─────────────────────────────────────────────────────
    bmitem = os.path.join(framework, "src/bmitem.c")
    msg = os.path.join(framework, "src/msg.c")
    for required_path, need, label in (
        (bmitem, 3, "src/bmitem.c（1 处声明 + GetItemName + 英文语法判定）"),
        (msg, 1, "src/msg.c（对话 [Item] 控制码 0x22）"),
    ):
        if not os.path.isfile(required_path):
            ck.die("E0 找不到 %s" % required_path)
        count = read_text(required_path).count("ShanheItemName(")
        if count < need:
            ck.die("E1 %s 里 ShanheItemName( 只出现 %d 次（要求 ≥%d）—— 补丁没应用或被人删了"
                   % (os.path.basename(required_path), count, need))
        ck.ok("E 调用点 %s：%d 处" % (label, count))

    print("-" * 72)
    print("断言结果：%d 通过 / %d 失败 —— 扩展道具显示名链路（内容→目录→C 表→ROM 字节）完整"
          % (ck.n_ok, ck.n_bad))
    return 0


if __name__ == "__main__":
    sys.exit(main())
