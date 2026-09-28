#include "global.h"

/*
 * 《山河烬》原创神器的**显示名**（内容层 C）。
 *
 * 由 tools/shanhe-build.sh 的第 3c 步铺为框架 `src/shanhe_item_names.c`
 * （统一 `shanhe_` 前缀；集合变化时脚本会 touch Makefile 以让
 * `$(wildcard src/*.c)` 在解析期重新展开）。
 *
 * ── 为什么需要这个文件（2026-09-29，玩家实测缺陷复盘）────────────────
 * 玩家原话：「主角背包里面没有照夜，而且突刺剑名字还没了」。
 * 根因：扩展槽道具（item >= ITEM_ID_EXPANSION_FIRST = 0xCE）**没有任何
 * 可达的显示名**——框架的既定策略是扩展道具不绑共享消息表，
 * `ItemData.nameTextId/descTextId/useDescTextId` 一律 0；此前项目把名字写在
 * `authoringName` 里，而那条通道**只在 EXPANSION_STARTER_CONTENT=1 档**
 * 才生成可得名字表，本项目不开该开关 ⇒ `GetItemName()` 最终落到
 * `GetStringFromIndex(0)`，界面上就是**一片空白**。
 * 更糟的是当时的验收网只断言道具的**数值**字段（.number/.maxUses），
 * 正好从 `nameTextId`（u16 = 0）上读过去了 ⇒ 缺陷顺利通过验收。
 *
 * ── 三条被否决的通道（都是实测结论，别回头再试）────────────────────
 * A. `texts/locales/<locale>/indexed.txt`（游戏文本目录）：
 *    按 **FE8U 消息 target id** 寻址，无法表达一条**全新**消息；
 *    扩展道具在映射表里根本没有 target id。
 * B. 往 `texts/texts.txt` 追加消息：
 *    会让 `fe8u_target_map.json` 的行数与消息总数**不再相等**，
 *    构建在 modern.mk:2399 → localized_game_text_data.h 处硬失败
 *    （scripts/localization/game_catalog/build.py:274）；
 *    修它要重跑整条本地化哈希链（shard → catalog → map，且 map 的 sha 自指）。
 * C. 把扩展目录的消息 id 塞进 `ItemData.nameTextId`：
 *    该字段是 u16 且语义是「共享消息表索引」，id 空间与 FE8U 消息
 *    （0x1..0xD55）**重叠**，任何直读 `nameTextId` 的代码都会取到
 *    无关字符串；而且 schema 只接受整数或 `msg.h` 里的 `MSG_*` 符号。
 *
 * ── 采用的通道：框架的「扩展文本目录」────────────────────────────────
 *   texts/expansion/registry.json     —— key → **显式钉死**的 id（append-only、
 *                                        墓碑制），含 max_width / max_decoded_bytes
 *   texts/expansion/catalog.<locale>.json —— 各语言的正文（en 必须全键，
 *                                        其余语言允许缺键并回退英文）
 *   构建生成 EXP_MSG_<KEY> 宏（build/.../generated/expansion_msg_ids.h）
 *   运行时解析 ExpansionLocale_ResolveCurrentPersistent(ExpansionMsgId)
 * 这是框架为「新增本地化玩家可见文本」准备的**专用**通道，没有 A/B 的连带成本，
 * 且自带多语言 / 宽度 / 字节数校验（scripts/localization/catalog.py）。
 *
 * ── 与道具的对接方式：**按 item id 查名**，不碰 nameTextId ──────────
 * 与框架自身的 starter-content seam（ExpansionStarterContentItemName）同形：
 * 调用方给 item id，本文件查表 → 解析 → 返回**可写**缓冲（NULL = 不是本项目道具）。
 * `nameTextId` 因此保持框架要求的 0，语义零污染。
 * 下方 `sShanheItemNames[]` 用的是 `EXP_MSG_*` 宏 ⇒ 注册表里 key 一旦改名，
 * 这里**编译期**就报错，不会静默指向别的文本。
 *
 * ── 调用点（都在 content/framework-patch/ 下的补丁里）──────────────
 *   · shanhe-item-name-seam.patch     → src/bmitem.c
 *       ① `GetItemName()`：道具菜单 / 交易 / 商店 / 状态页 / 弹窗的**唯一**
 *          生产取名入口（框架自己的注释就是这么写的）。
 *       ② `ItemNameUsesEnglishGrammar()`：返回 FALSE，避免 CJK 下被
 *          `InsertPrefix` 加上英文冠词（否则会看到 "the 照夜"）。
 *   · shanhe-item-name-seam-msg.patch → src/msg.c
 *       ③ 对话里 `[Item]`（控制码 0x22）的文本替换：不挂这里，
 *          对话内嵌的道具名会走 `GetStringFromIndex(nameTextId=0)` 变空白。
 *
 * ── 上界约定 ────────────────────────────────────────────────────────
 * 注册表里两个 key 的 max_decoded_bytes = 24 < 本缓冲 32 ⇒ 拷贝不截断。
 * 该不等式由 tools/shanhe-namecheck.py 断言（构建第 5 步检查 ⑥）。
 *
 * ── 内存 / 兼容 ────────────────────────────────────────────────────
 * 零 EWRAM / 零 BSS 之外的常驻：只有一块 32 字节的静态缓冲（.bss）与一张
 * 常量表（.rodata）；EWRAM 余量在 release 档仅 976 字节，故此处刻意不发散。
 * C89 风格，不依赖任何 C99 特性（框架的现代车道与归档车道都会编译本文件，
 * 只有现代车道会链接它）。
 */

/* ★ id_space.h 必须在下面那条 `#if` **之前**包含：它才定义 ITEM_ID_CONFIGURED_CAP /
 * ITEM_ID_EXPANSION_FIRST。若等到 `#if` 之后再包含，两个宏在预处理表达式里都是
 * 未定义标识符（按 0 处理）⇒ `0 >= 0` 恒真 ⇒ 会静默走进扩展分支并在
 * 关闭扩展的构建里引用不存在的 ITEM_SHANHE_*。item id 类型 ItemId 亦由此而来。 */
#include "id_space.h"
#include "bmitem.h"

#if defined(MODERN) && ITEM_ID_CONFIGURED_CAP >= ITEM_ID_EXPANSION_FIRST

#include "expansion_locale.h"
#include "expansion_msg_ids.h"
#include "constants/items_expansion.h"

/* 运行时解析出的名字是只读的（在 ROM / 目录视图里），而生产调用方
 * （GetItemNameWithArticle → InsertPrefix）会**就地改写**拿到的字符串，
 * 所以这里拷进一块可写缓冲再交出去 —— 与框架 starter-content 的做法一致。 */
#define SHANHE_ITEM_NAME_BUFFER 32

static const struct ShanheItemNameEntry
{
    ItemId item;
    ExpansionMsgId msgId;
} sShanheItemNames[] =
{
    /* 破军（枪，0xCE）。注册表 key: shanhe.item.pojun.name */
    { ITEM_SHANHE_POJUN,  EXP_MSG_SHANHE_ITEM_POJUN_NAME  },
    /* 照夜（剑，0xCF）。注册表 key: shanhe.item.zhaoye.name */
    { ITEM_SHANHE_ZHAOYE, EXP_MSG_SHANHE_ITEM_ZHAOYE_NAME },
};

static char sShanheItemNameBuffer[SHANHE_ITEM_NAME_BUFFER];

/*
 * 返回本项目道具的显示名（当前语言，缺键回退英文），否则 NULL。
 * 返回的指针指向本文件内的静态缓冲 —— 只在「取到名字 → 立刻用掉」的
 * 生产路径上使用，与框架 vanilla 取名路径（返回文本系统缓冲）的时效性同形。
 */
char* ShanheItemName(ItemId item)
{
    const char* resolved;
    u32 k;
    u32 i;

    for (k = 0; k < (u32)(sizeof(sShanheItemNames) / sizeof(sShanheItemNames[0])); k++)
    {
        if (sShanheItemNames[k].item != item)
            continue;

        resolved = ExpansionLocale_ResolveCurrentPersistent(sShanheItemNames[k].msgId);

        /* 目录实现按框架惯例是「取不到就返回可见的 missing 标记」而不是 NULL；
         * NULL 只是防御性判断，保留以便调用方安全回落到 vanilla 路径。 */
        if (resolved == NULL)
            return NULL;

        for (i = 0; i + 1 < SHANHE_ITEM_NAME_BUFFER; i++)
        {
            sShanheItemNameBuffer[i] = resolved[i];
            if (resolved[i] == '\0')
                break;
        }
        sShanheItemNameBuffer[SHANHE_ITEM_NAME_BUFFER - 1] = '\0';

        return sShanheItemNameBuffer;
    }

    return NULL;
}

#else /* !MODERN || 未扩道具槽 —— 与框架惯例一致：保持符号存在，恒返回 NULL */

char* ShanheItemName(ItemId item)
{
    (void)item;
    return NULL;
}

#endif /* MODERN && ITEM_ID_CONFIGURED_CAP >= ITEM_ID_EXPANSION_FIRST */
