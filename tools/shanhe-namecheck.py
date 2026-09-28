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
被断言的链路（A→E 名字 + E4b 链接期；F 描述；G 图标）
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
  E4b 链接期     ShanheItemName / ShanheItemDesc **必须在 ELF 符号表里**。
                 两个接缝整块包在 `#if defined(MODERN) &&
                 ITEM_ID_CONFIGURED_CAP >= ITEM_ID_EXPANSION_FIRST` 里
                 （src/bmitem.c / src/msg.c 也被 agbcc 车道编译，必须这样守）
                 ⇒ cap 配置一旦回退，**源码调用点还在（E1 照样绿）而代码整块
                 不编译**。只有查符号表才拦得住这类"静默消失"。

  F 描述链路     （2026-09-29 第二轮 P0b；玩家「帮助框下半一片空白」）
                 seam 的 sShanheItemDescs[] → 目录 key → 正文 → gItemData 的
                 descTextId 必须仍为 0（不绑共享消息表）→ 描述字节在 ROM 里。
                 描述是**逐行**校验宽度，且各语言的换行数必须一致
                 （独立复核框架 catalog.py 的 _check_width_and_bytes / _check_parity）。
  G 图标链路     （2026-09-29 第二轮 P0a；玩家「属性数值全是突刺剑的」）
                 content/assets/icons/*.png ↔ 框架 graphics/item_icon/ ↔
                 data_item_icon.c 的**第 iconId 条** .4bpp 声明 ↔ gItemData 的
                 iconId 字节。五条硬判据：
                   G-唯一   两个扩展道具不得共用 iconId，且**不得与原版道具撞**；
                   G4b      ROM 里 gItemData[item].iconId **真的等于**内容层声明
                            （声明没进 ROM 的话，前面几段会全绿而实机仍是旧图）；
                   G-专属   iconId 指向的那条声明必须叫 item_icon_shanhe_*；
                   G9b      ROM 里**第 iconId 个槽位**的 128 字节 == 我们的 PNG，
                            且该声明的符号**正好落在**这个槽位（G9 只证明字节在
                            ROM 某处存在，不证明位置对）；
                   G-唯一像 该图标的像素不得与**任何**其它图标完全相同；
                   G-可达   判据来自「被 src/events/ 授予玩家」——没被任何事件
                            脚本发放的道具不要求（也因此**不需要豁免名单**），
                            日后某章开始发放它，本检查自动升级要求。

★ 贯穿原则（R-28 纪律）：断言必须**读玩家界面真正读的那一格** ——
  E4b 读符号表、D/F 读 ROM 字节、G4b 读 ROM 的 iconId 字段、G9b 读 ROM 的图标槽位像素。
  "断言了所有存在的东西，却没人断言玩家真正看到的东西"是 2026-09-29 两次缺陷的共同形态。

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

# ── 第二轮新增（2026-09-29 P0a/P0b）：描述与图标链路的常量 ─────────────────
OFF_ITEM_DESCTEXTID = 0x02      # u16，紧跟 nameTextId（见 include/bmitem.h 的 ItemData）
OFF_ITEM_ICONID = 0x1D          # u8
SEAM_DESC_TABLE_MARKER = "sShanheItemDescs[]"
SEAM_DESC_BUFFER_DEFAULT = 96   # 与 seam 源里的 SHANHE_ITEM_DESC_BUFFER 对齐
ICON_SOURCE_REL = "src/data/data_item_icon.c"
ICON_ASSET_DIR_REL = "assets/icons"       # 内容层 PNG 源（相对 content/）
ICON_FW_DIR_REL = "graphics/item_icon"    # 框架侧 PNG 源；同名 .4bpp 由 make 用 gbagfx 生成
VANILLA_ITEMS_REL = "src/data/items.json"
EVENTS_DIR_REL = "src/events"             # 「已被发放」的可推导判据来源
ICON_BYTES = 128                          # 16x16 @ 4bpp
# ★ 与框架 scripts/generated_data/items/schema.py 的 _ITEM_ICON_ENTRY_RE **同口径**：
#   只匹配 .4bpp 的 INCBIN_U8 声明 ⇒ 天然排除 item_icon_palette[]（.agbpal）
#   与 item_icon_tiles（extern alias，不是自己的 INCBIN 声明）。
ICON_DECL_RE = re.compile(r'u8\s+(item_icon_\w+)\[\]\s*=\s*INCBIN_U8\("([^"]+\.4bpp)"\)\s*;')
ITEM_SYM_RE = re.compile(r"ITEM_SHANHE_[A-Za-z0-9_]+")

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


def parse_seam_desc_table_str(text):
    """src/shanhe_item_names.c 的 sShanheItemDescs[] -> [(item_symbol, msg_ident)]

    与 parse_seam_table_str 共用同一套 `{ ITEM_*, EXP_MSG_* }` 正则，只是换标记。
    同样的约束：**表体内不要写**含 `{ ITEM_*, EXP_MSG_* }` 形态的注释。
    """
    body = text.split(SEAM_DESC_TABLE_MARKER, 1)
    if len(body) < 2:
        return []
    body = body[1].split("};", 1)[0]
    return [(m.group(1), m.group(2)) for m in SEAM_PAIR_RE.finditer(body)]


def parse_seam_desc_table(path):
    return parse_seam_desc_table_str(read_text(path))


def parse_item_icon_decls_str(text):
    """data_item_icon.c 的正文 -> [(符号名, 图形路径)]，**按声明顺序**

    顺序即语义：这些数组按声明顺序连成图标 blob，`ItemData.iconId` 就是
    blob 内的下标（第 N 条声明 = 索引 N，每项 128 字节 = 16x16 @ 4bpp）。
    """
    return [(m.group(1), m.group(2)) for m in ICON_DECL_RE.finditer(text)]


def parse_item_icon_decls(path):
    return parse_item_icon_decls_str(read_text(path))


def icon_png_rel(decl_path):
    """`data_item_icon.c` 声明里的图形路径 -> **仓库追踪的 PNG 源**相对路径。

    ⚠️ 声明里写的是 `.4bpp`（交给 gbagfx 编译的中间物），而**仓库真正追踪的是同名
    `.png`** —— `Makefile` 有通用规则 `%.4bpp: %.png`、`.gitignore` 忽略 `*.4bpp`。
    两者搞混会让门禁去找一个**从来不会存在**的文件。

    （2026-09-29 实测踩过一次：G7 直接拿声明路径当 PNG 名 ⇒ 构建第 5 步 ⑥ 报
      `content/assets/icons/item_icon_shanhe_zhaoye.4bpp 不存在`。**解析器没错、
      消费方忘了转换** —— 这正是"单元自测通过 ≠ 集成正确"的典型形态。）
    """
    return os.path.splitext(decl_path)[0] + ".png"


def vanilla_icon_ids_from(text):
    """src/data/items.json 的正文 -> {iconId: [道具符号, ...]}"""
    out = {}
    for rec in json.loads(text).get("items", []):
        ic = rec.get("iconId")
        if isinstance(ic, int):
            out.setdefault(ic, []).append(rec.get("item"))
    return out


def vanilla_icon_ids(path):
    return vanilla_icon_ids_from(read_text(path))


def reachable_item_symbols(framework):
    """事件脚本层（src/events/）当前**授予玩家**的扩展道具符号集合。

    这是「必须在游戏内可见」的**可推导**判据 —— 刻意不用豁免名单：
      · 没被任何事件脚本引用的道具，玩家在已建成的章节里根本拿不到
        （当前 0xCE 破军即如此 —— 第 3 章尚未制作）；
      · 一旦某章的事件脚本开始发放它，本集合自动变大、本检查随即要求
        它有专属图标与描述，**不需要任何人回来改这个文件**。
    """
    found = set()
    root = os.path.join(framework, EVENTS_DIR_REL)
    if not os.path.isdir(root):
        return found
    for dirpath, _dirs, files in os.walk(root):
        for name in files:
            try:
                found.update(ITEM_SYM_RE.findall(read_text(os.path.join(dirpath, name))))
            except (OSError, UnicodeDecodeError):
                continue
    return found


def max_line_width(text):
    """逐行显示宽的最大值（描述是多行文本）。"""
    return max([display_width(ln) for ln in text.split("\n")] or [0])


def pseudo_module(framework):
    """取**框架自己**的伪语言模块，返回 (pseudo, schema) 或 (None, None)。

    刻意复用而不是自己重写一份：qps-ploc 是**从 en 派生**的，框架对它同样做
    逐行宽度校验 —— 规则必须与框架完全一致，各写一份迟早分叉。
    """
    if framework not in sys.path:
        sys.path.insert(0, framework)
    try:
        from scripts.localization import pseudo as _pseudo
        from scripts.localization import schema as _schema
    except Exception:
        return None, None
    return _pseudo, _schema


_NM_CACHE = {}


def nm_all(elf):
    """`arm-none-eabi-nm -S <elf>` -> {符号: (addr, size)}；工具缺失/失败返回 None。

    缓存整份符号表：图标链要按符号名逐个查（`item_icon_tiles` + 每个声明），
    每次重跑一遍 nm 在 G 段会明显变慢（实测 nm -S 整份 ELF 约 0.5 s）。
    """
    if elf in _NM_CACHE:
        return _NM_CACHE[elf]
    try:
        out = subprocess.run([NM, "-S", elf], capture_output=True)
    except OSError:
        return None
    if out.returncode != 0:
        return None
    table = {}
    for line in out.stdout.decode("utf-8", "replace").splitlines():
        parts = line.split()
        if len(parts) == 4:
            try:
                table[parts[3]] = (int(parts[0], 16), int(parts[1], 16))
            except ValueError:
                continue
    _NM_CACHE[elf] = table
    return table


def nm_symbol(elf, name):
    """arm-none-eabi-nm -S -> (addr, size)；符号不存在返回 None。

    ⚠️ 注意 `nm -S` **不报尺寸**的符号（例如 `gActiveUnit`）会拿不到 size ——
    本项目里这是有意的严格性：拿不到尺寸就不给用（见 docs/5 §5.14 的实测记录）。
    """
    table = nm_all(elf)
    if table is None:
        return "NO_TOOL", None
    return table.get(name, (None, None))


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

    # 描述表解析（与名字表共用正则、换标记）
    dseam = parse_seam_desc_table_str(
        "static const struct ShanheItemDescEntry\n"
        "{\n    ItemId item;\n    ExpansionMsgId msgId;\n} sShanheItemDescs[] =\n"
        "{\n"
        "    /* 照夜（剑，0xCF）。注册表 key: shanhe.item.zhaoye.desc（id 148） */\n"
        "    { ITEM_SHANHE_ZHAOYE, EXP_MSG_SHANHE_ITEM_ZHAOYE_DESC },\n"
        "};\n")
    cases.append(("parse_seam_desc_table 恰好 1 条且正确",
                  dseam == [("ITEM_SHANHE_ZHAOYE", "EXP_MSG_SHANHE_ITEM_ZHAOYE_DESC")]))
    cases.append(("parse_seam_desc_table 无表时返回空表",
                  parse_seam_desc_table_str("int main(void) { return 0; }\n") == []))
    cases.append(("名字表不会被当成描述表（标记不串）",
                  parse_seam_desc_table_str(
                      "} sShanheItemNames[] =\n{\n"
                      "    { ITEM_SHANHE_POJUN, EXP_MSG_A },\n};\n") == []))

    # 图标声明解析 —— 口径必须与框架 schema.py 的 read_item_icon_count 一致
    idecls = parse_item_icon_decls_str(
        '#include "global.h"\n'
        'u8 item_icon_sword_slim[] = INCBIN_U8("graphics/item_icon/item_icon_sword_slim.4bpp");\n'
        'extern u8 item_icon_tiles[1] __attribute__((alias("item_icon_sword_slim")));\n'
        'u8 item_icon_shanhe_zhaoye[] = INCBIN_U8("graphics/item_icon/item_icon_shanhe_zhaoye.4bpp");\n'
        'u8 item_icon_palette[] = INCBIN_U8("graphics/item_icon/item_icon_palette.agbpal");\n')
    cases.append(("parse_item_icon_decls 只数 .4bpp（排除 alias 与 palette）",
                  idecls == [("item_icon_sword_slim",
                              "graphics/item_icon/item_icon_sword_slim.4bpp"),
                             ("item_icon_shanhe_zhaoye",
                              "graphics/item_icon/item_icon_shanhe_zhaoye.4bpp")]))
    cases.append(("图标索引语义：第 N 条声明的下标就是 N",
                  idecls[1][0] == "item_icon_shanhe_zhaoye"))
    cases.append(("icon_png_rel：声明里的 .4bpp -> 仓库追踪的 .png",
                  icon_png_rel("graphics/item_icon/item_icon_sword_slim.4bpp")
                  == "graphics/item_icon/item_icon_sword_slim.png"
                  and icon_png_rel("/a/b/c.4bpp") == "/a/b/c.png"))

    # 原版 iconId 表解析
    vid = vanilla_icon_ids_from(
        '{"items":[{"item":"ITEM_NONE","iconId":0},'
        '{"item":"ITEM_SWORD_RAPIER","iconId":8},'
        '{"item":"ITEM_SWORD_IRON","iconId":8}]}')
    cases.append(("vanilla_icon_ids 同 iconId 归并",
                  vid[8] == ["ITEM_SWORD_RAPIER", "ITEM_SWORD_IRON"] and vid[0] == ["ITEM_NONE"]))

    # 多行文本的最大行宽（描述用）
    cases.append(("max_line_width 取最大行",
                  max_line_width("守鼎人信物，虞聪的佩剑\n神器，不可出售") == 22))
    cases.append(("max_line_width 单行 / 空串",
                  max_line_width("Yu Cong's heirloom sword") == 24
                  and max_line_width("") == 0))

    # 新字段偏移自洽 + 顺序未被写反
    cases.append(("描述/图标偏移在 stride 内且顺序正确",
                  OFF_ITEM_DESCTEXTID + 2 <= ITEMDATA_STRIDE
                  and OFF_ITEM_ICONID + 1 <= ITEMDATA_STRIDE
                  and OFF_ITEM_NAMETEXTID < OFF_ITEM_DESCTEXTID < OFF_ITEM_ICONID))
    cases.append(("图标尺寸常量 = 16x16 @ 4bpp", ICON_BYTES == 16 * 16 // 2))

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

    # ── 伪语言（qps-ploc）宽度：**从 en 派生**，框架对它同样逐行校验宽度 ──
    # 2026-09-29 实测教训：描述条目的默认策略 `transform` 会把 en 加长
    # （前后缀 + 字母风格化），"Yu Cong's heirloom sword" 伪化后宽 33 > max_width 24
    # ⇒ 构建在生成 expansion_msg_ids.h 时硬失败（modern.mk:2334）。
    # 宽度受限的表面应声明 `"pseudo_policy": "compact"` —— 这是框架自己的惯例。
    pmod, pschema = pseudo_module(framework)
    if pmod is None:
        ck.die("C0b 无法导入框架的 scripts/localization/pseudo —— qps-ploc 是从 en 派生的，"
               "本检查必须与框架同规则，不能各写一份")

    def check_pseudo_width(key, entry, label):
        policy = entry.get("pseudo_policy", pschema.DEFAULT_PSEUDO_POLICY)
        en_text = catalogs.get("en", {}).get(key)
        if not isinstance(en_text, str):
            return
        for ln in pmod.apply_pseudo_policy(en_text, policy).split("\n"):
            if display_width(ln) > entry["max_width"]:
                ck.die("%s key %s 声明 pseudo_policy=%r，伪化后（qps-ploc）行 %r 宽 %d > "
                       "max_width=%d —— 构建会在 expansion_msg_ids.h 生成阶段硬失败；"
                       "宽度受限的表面应声明 \"compact\""
                       % (label, key, policy, ln, display_width(ln), entry["max_width"]))

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
        check_pseudo_width(key, entry, "C9 名字")

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

    # ★★ E4b：**链接期**复核 —— 接缝函数必须真的在 ELF 里。
    #   为什么源码级 E1 不够：两个接缝整块都包在
    #     `#if defined(MODERN) && ITEM_ID_CONFIGURED_CAP >= ITEM_ID_EXPANSION_FIRST`
    #   里（src/bmitem.c / src/msg.c 同时被 agbcc 车道编译，必须这样守）。一旦那个
    #   条件因为 cap 配置回退而不再成立，**源码里的调用点还在**（E1 照样绿），
    #   但代码整块不编译 ⇒ 实机名字/描述又是空白。只有查符号表才拦得住。
    #   同理适用于 statscreen.c 的描述接缝：它调的是 ShanheItemDesc()，
    #   而 ShanheItemDesc 定义在内容层 src/shanhe_item_names.c 里。
    for fn in ("ShanheItemName", "ShanheItemDesc"):
        a, sz = nm_symbol(elf_path, fn)
        if a in ("NO_TOOL", None):
            ck.die("E4b ELF 里没有 %s 符号 —— 接缝被编译掉了（多半是"
                   " ITEM_ID_CONFIGURED_CAP < ITEM_ID_EXPANSION_FIRST）。"
                   "源码里的调用点还在，所以 E1 是绿的：这正是要靠符号表才能发现的失效" % fn)
        if sz == 0:
            ck.die("E4b %s 符号存在但尺寸为 0 —— 不是有效函数" % fn)
    ck.ok("E4b 链接期复核：ShanheItemName / ShanheItemDesc 都在 ELF 里（接缝没被编译门剪掉）")

    # ── F. 描述链路（2026-09-29 第二轮 P0b）────────────────────────────
    # 玩家原话「照夜武器出来了，但是属性和数值全部是突刺剑的，而且战斗的特效
    # 也没有出现」。"看着像突刺剑"的可见来源之一，就是物品帮助框**下半那片空白**。
    seam_text = read_text(seam_path)
    dbuf = re.search(r"#define\s+SHANHE_ITEM_DESC_BUFFER\s+(\d+)", seam_text)
    desc_buf_size = int(dbuf.group(1)) if dbuf else SEAM_DESC_BUFFER_DEFAULT
    desc_table = parse_seam_desc_table(seam_path)

    descs = {}      # item_id -> {locale: text}
    for sym, ident in desc_table:
        if sym not in item_ids:
            ck.die("F2 seam 描述表里的 %s 不在 include/constants/items_expansion.h 里" % sym)
        item_id = item_ids[sym]
        key = by_ident.get(ident.replace("EXP_MSG_", "", 1))
        if key is None:
            ck.die("F3 seam 描述表用了 %s，但 texts/expansion/registry.json 里没有任何 key"
                   " 映射到它（key 改名后此处必须同步）" % ident)
        entry = by_key[key]
        if entry.get("status") != "active":
            ck.die("F3 key %s 的 status 不是 active（%r）" % (key, entry.get("status")))
        max_bytes = entry.get("max_decoded_bytes")
        max_width = entry.get("max_width")
        if not isinstance(max_bytes, int) or not isinstance(max_width, int):
            ck.die("F4 key %s 缺 max_decoded_bytes / max_width" % key)
        if max_bytes > desc_buf_size:
            ck.die("F5 key %s 的 max_decoded_bytes=%d 超过 seam 的 %d 字节描述缓冲 —— 拷贝会被截断"
                   % (key, max_bytes, desc_buf_size))
        check_pseudo_width(key, entry, "F5b 描述")

        descs[item_id] = {}
        for loc in locales:
            text = catalogs[loc].get(key)
            if not isinstance(text, str) or not text.strip():
                ck.die("F6 %s 在 catalog.%s.json 里没有非空正文（回退到别的语言也算不合格）"
                       % (key, loc))
            # ★ 描述是**多行**文本（源里的 \n 会在生成期变成引擎的 0x01 换行码），
            #   所以宽度必须**逐行**校验 —— 与框架 catalog.py 的 _check_width_and_bytes 同口径。
            for ln in text.split("\n"):
                if display_width(ln) > max_width:
                    ck.die("F7 %s 的 %s 正文第 %r 行显示宽 %d > max_width=%d"
                           % (key, loc, ln, display_width(ln), max_width))
            blen = len(text.encode("utf-8")) + 1
            if blen > max_bytes:
                ck.die("F7 %s 的 %s 正文解码后 %d 字节（含 NUL）> max_decoded_bytes=%d"
                       % (key, loc, blen, max_bytes))
            descs[item_id][loc] = text

        # 独立复核框架 catalog.py 的 _check_parity：各语言的换行数必须一致
        nls = sorted(set(t.count("\n") for t in descs[item_id].values()))
        if len(nls) != 1:
            ck.die("F8 %s 各语言的换行数不一致：%s"
                   % (key, {l: descs[item_id][l].count("\n") for l in locales}))

    if desc_table:
        ck.ok("F 描述目录：%d 条（%s），逐行宽度 / 字节 / 换行数一致性均通过"
              % (len(descs), ", ".join("0x%02X" % i for i in sorted(descs))))
        for item_id in sorted(descs):
            off = base + item_id * ITEMDATA_STRIDE
            d_id = struct.unpack_from("<H", blob, off + OFF_ITEM_DESCTEXTID)[0]
            if d_id != 0:
                ck.die("F9 gItemData[0x%02X].descTextId = 0x%04X ≠ 0 —— 扩展道具按框架策略必须"
                       "不绑共享消息表（扩展目录 id 与 FE8U 消息 id 空间重叠）" % (item_id, d_id))
            # 描述字节必须真的在 ROM 里。注意：源里的 \n 在生成期被替换成 0x01，
            # 所以**逐行**找 UTF-8 字节，不能整串找。
            for loc, text in sorted(descs[item_id].items()):
                for ln in [x for x in text.split("\n") if x]:
                    if blob.count(ln.encode("utf-8")) < 1:
                        ck.die("FA 0x%02X 的 %s 描述行 %r 在 ROM 里一个字节都找不到 ——"
                               " 没被链进 ROM，实机帮助框仍是空白" % (item_id, loc, ln))
            ck.ok("F  0x%02X %-22s descTextId=0x0000  描述行在 ROM：%s"
                  % (item_id, declared[item_id],
                     " / ".join("%s×%d行" % (loc, len([x for x in descs[item_id][loc].split("\n") if x]))
                                for loc in locales)))
    else:
        ck.die("F1 %s 里没有 sShanheItemDescs[] 描述表 —— 扩展道具的帮助框会一直是空白"
               % SEAM_SOURCE_REL)

    # ── G. 图标链路（2026-09-29 第二轮 P0a）────────────────────────────
    icon_src_path = os.path.join(framework, ICON_SOURCE_REL)
    if not os.path.isfile(icon_src_path):
        ck.die("G0 找不到 %s" % icon_src_path)
    decls = parse_item_icon_decls(icon_src_path)
    if not decls:
        ck.die("G1 从 %s 解析不出任何 .4bpp 声明" % ICON_SOURCE_REL)

    vanilla_path = os.path.join(framework, VANILLA_ITEMS_REL)
    vanilla_icons = vanilla_icon_ids(vanilla_path) if os.path.isfile(vanilla_path) else {}

    icons = {}
    for rec in records:
        ic = rec.get("iconId")
        if not isinstance(ic, int):
            ck.die("G2 content/data/items_expansion.json 的 %s 没有整数 iconId" % rec.get("item"))
        icons[item_ids[rec["item"]]] = ic

    seen = {}
    for item_id in sorted(icons):
        ic = icons[item_id]
        if ic < 0 or ic >= len(decls):
            ck.die("G3 0x%02X 的 iconId=%d 超出 %s 的 %d 条 .4bpp 声明"
                   "（框架 schema.py 的 read_item_icon_count() 就是这个上界）"
                   % (item_id, ic, ICON_SOURCE_REL, len(decls)))
        if ic in seen:
            ck.die("G3 0x%02X 与 0x%02X 共用 iconId=%d —— 两个道具会画成同一张图"
                   % (item_id, seen[ic], ic))
        seen[ic] = item_id

    # ★ G-唯一：不得与原版道具撞 iconId。这条正是 2026-09-29 缺陷的**根因类型** ——
    #   照夜原先 iconId = 8，而 ITEM_SWORD_RAPIER 的 iconId 也正是 8。
    for item_id in sorted(icons):
        ic = icons[item_id]
        if ic in vanilla_icons:
            ck.die("G4 0x%02X（%s）的 iconId=%d 与原版道具 %s 撞车（原版 iconId 上界 %d）——"
                   " 玩家会看到那把武器的图，这正是「照夜看着像突刺剑」的根因类型"
                   % (item_id, declared[item_id], ic,
                      ", ".join(vanilla_icons[ic]), max(vanilla_icons)))
    # ⚠️ 这里比的是**不同 iconId 的个数**（实测 174），不是道具记录数（206）——
    #    原版 206 条记录里大量共用同一 iconId（iconId 0 就有 20 条）。
    ck.ok("G 图标槽位：%d 个扩展道具的 iconId %s 互不重复、且都不与原版 %d 个 iconId 撞车"
          % (len(icons), sorted(icons.values()), len(vanilla_icons)))

    # ★★ G4b：ROM 里 `gItemData[item].iconId` **真的等于**我们声明的值。
    #   这是 R-28 纪律的直接落地 —— 断言的必须是**玩家界面真正读的那一格**。
    #   上面 G3/G4 只证明了"声明了一个合法且不撞车的槽位"，但**没证明它被写进了 ROM**：
    #   `items_expansion.json` 的 iconId 要经过框架的生成链才进 `gItemData`，
    #   任何一环静默忽略该字段，前面几段会全绿而实机仍画成旧图（正是本轮缺陷的形态）。
    for item_id in sorted(icons):
        off = base + item_id * ITEMDATA_STRIDE
        rom_ic = blob[off + OFF_ITEM_ICONID]
        if rom_ic != icons[item_id]:
            ck.die("G4b gItemData[0x%02X].iconId = %d，而 content/data/items_expansion.json "
                   "声明的是 %d —— 声明没有进 ROM（实机仍会画成 iconId=%d 那张图）"
                   % (item_id, rom_ic, icons[item_id], rom_ic))
    ck.ok("G4b ROM 侧复核：%s 的 gItemData.iconId 与内容层声明完全一致"
          % ", ".join("0x%02X=%d" % (i, icons[i]) for i in sorted(icons)))

    # 预读全部既有 .4bpp 的字节，用于「像素唯一」判据
    fw_icon_dir = os.path.join(framework, ICON_FW_DIR_REL)
    tile_bytes = {}
    for sym, path in decls:
        p = os.path.join(framework, os.path.splitext(path)[0] + ".4bpp")
        if os.path.isfile(p):
            tile_bytes[sym] = open(p, "rb").read()

    reachable = reachable_item_symbols(framework)
    ck.ok("G 可达性：src/events/ 当前授予玩家的扩展道具 = %s"
          % (", ".join(sorted(reachable)) if reachable else "（无）"))

    # ★★ G9b 用的**图标表基址**：`item_icon_tiles` 就是"基址 + iconId×128"机制的锚点
    #   （它在 data_item_icon.c 里是 `extern u8 item_icon_tiles[1] __attribute__((alias("item_icon_sword_slim")))`）。
    tiles_addr, _tiles_size = nm_symbol(elf_path, "item_icon_tiles")
    if tiles_addr in ("NO_TOOL", None):
        ck.die("G9b ELF 里解析不到 item_icon_tiles（图标表基址）—— 无法验证槽位，拒绝放行")
    tiles_base = tiles_addr - ROM_BASE

    for sym in sorted(reachable):
        if sym not in item_ids:
            ck.die("G5 事件脚本引用了 %s，但它不在 include/constants/items_expansion.h 里" % sym)
        item_id = item_ids[sym]
        ic = icons.get(item_id)
        if ic is None:
            ck.die("G5 %s（0x%02X）已被事件脚本发放给玩家，但 items_expansion.json 里没有它的"
                   " iconId" % (sym, item_id))
        decl_sym, decl_path = decls[ic]
        if not decl_sym.startswith("item_icon_shanhe_"):
            ck.die("G6 %s（0x%02X）的 iconId=%d 指向 %s（%s）—— 玩家会看到**别的道具的图**"
                   "或占位图。修法：在 data_item_icon.c 的 .4bpp 声明块**末尾**追加一条"
                   " `u8 item_icon_shanhe_*.4bpp`，并把该道具的 iconId 指到新槽位"
                   % (sym, item_id, ic, decl_sym, decl_path))
        base_png = os.path.basename(icon_png_rel(decl_path))
        c_icon = os.path.join(content, ICON_ASSET_DIR_REL, base_png)
        f_icon = os.path.join(framework, ICON_FW_DIR_REL, base_png)
        if not os.path.isfile(c_icon):
            ck.die("G7 content/%s/%s 不存在（图标 PNG 源缺失）"
                   "—— 注意声明里写 .4bpp、仓库追踪的却是 .png" % (ICON_ASSET_DIR_REL, base_png))
        if not os.path.isfile(f_icon):
            ck.die("G7 framework %s/%s 不存在 —— 构建第 3e 步没把它铺进框架"
                   % (ICON_FW_DIR_REL, base_png))
        if open(c_icon, "rb").read() != open(f_icon, "rb").read():
            ck.die("G7 content/%s/%s 与框架侧同名文件**字节不同** —— 第 3e 步没跑，或有人只改了一边"
                   % (ICON_ASSET_DIR_REL, base_png))

        base_4bpp = os.path.splitext(base_png)[0] + ".4bpp"
        tb = tile_bytes.get(decl_sym)
        if tb is None:
            ck.die("G8 %s/%s 不存在 —— make 没有从 PNG 生成 4bpp（gbagfx 那一步没跑？）"
                   % (ICON_FW_DIR_REL, base_4bpp))
        if len(tb) != ICON_BYTES:
            ck.die("G8 %s 是 %d 字节，期望 %d（16x16 @ 4bpp）"
                   % (base_4bpp, len(tb), ICON_BYTES))
        if blob.count(tb) < 1:
            ck.die("G9 %s 的 %d 字节像素数据在 ROM 里找不到 —— 图标没被链进去，实机背包格是空的"
                   % (base_4bpp, ICON_BYTES))

        # ★★ G9b：ROM 里**第 iconId 个槽位**的 128 字节必须就是我们的 PNG。
        #   这是整条图标链最直接的一条断言 —— G9 只证明"这 128 字节在 ROM **某处**存在"，
        #   没证明它在**正确的位置**（放错位置玩家照样看到别人的图）。
        #   外加一条对偶断言：该声明的符号必须**正好落在**这个槽位上。
        slot = tiles_base + ic * ICON_BYTES
        if slot + ICON_BYTES > len(blob):
            ck.die("G9b 0x%02X 的 iconId=%d 算出的槽位（0x%X）越出 ROM" % (item_id, ic, slot))
        if blob[slot:slot + ICON_BYTES] != tb:
            ck.die("G9b ROM 里第 %d 个图标槽位（0x%06X）的像素与 %s 的 .4bpp **不一致** ——"
                   " iconId 与实际落位对不上，实机画出来的是别的图"
                   % (ic, slot, base_4bpp))
        sym_addr, _sym_size = nm_symbol(elf_path, decl_sym)
        if sym_addr in ("NO_TOOL", None):
            ck.die("G9b ELF 里解析不到 %s（声明存在却没被链接？）" % decl_sym)
        if sym_addr - ROM_BASE != slot:
            ck.die("G9b %s 链接在 0x%08X，而 iconId=%d 期望它落在 0x%08X"
                   "（基址 0x%08X + %d×%d）—— 声明顺序与 iconId 不对应"
                   % (decl_sym, sym_addr, ic, tiles_addr + ic * ICON_BYTES,
                      tiles_addr, ic, ICON_BYTES))

        # ★ G-唯一像：像素不得与任何其它图标完全相同。
        #   这是"照夜画成突刺剑"这一观感的**像素级反面断言**。
        dup = sorted(s for s, b in tile_bytes.items() if s != decl_sym and b == tb)
        if dup:
            ck.die("G10 %s 的像素与 %s 完全相同 —— 专属图标必须唯一，否则玩家又会看到"
                   "「别人的道具」" % (base_4bpp, ", ".join(dup[:3])))

        ck.ok("G  0x%02X %-22s iconId=%d → %s（PNG 已同步 / ROM 第 %d 槽位像素一致 / 符号落位一致 / 像素唯一）"
              % (item_id, sym, ic, decl_sym, ic))

    # 被声明但尚未在任何事件脚本里发放的道具：**不阻断**，但明确列出 ——
    # 这是"可推导"的结果，不是豁免名单：日后某章开始发放它，本清单自动变短、
    # 上面的 G5/G6 自动开始要求图标与描述。
    reachable_ids = set(item_ids[x] for x in reachable if x in item_ids)
    pending = sorted(declared[i] for i in sorted(declared) if i not in reachable_ids)
    if pending:
        ck.ok("G  （未阻断）尚未被任何事件脚本发放、因而本轮不要求图标/描述的扩展道具：%s"
              % ", ".join(pending))

    print("-" * 72)
    print("断言结果：%d 通过 / %d 失败 —— 扩展道具「显示名 + 描述 + 专属图标」链路"
          "（内容→目录→C 表→ROM 字节→调用点）完整" % (ck.n_ok, ck.n_bad))
    return 0


if __name__ == "__main__":
    sys.exit(main())
