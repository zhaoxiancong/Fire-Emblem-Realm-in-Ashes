/* 山河烬 · 序章事件脚本（自家 TU）
 *
 * 为什么是**独立 TU** 而不是改框架的 src/events/prologue-eventscript.h：
 *   框架 modern 构建的 C 源集合是 `MODERN_ALL_C_SOURCES ?= $(wildcard src/*.c)`
 *   ⇒ 新增一个 src/*.c **自动进构建**，既不改 Makefile、也不用发补丁
 *   （与 3a'' 章节表通道是同一策略，见 docs/5 §5.18）。
 *   本文件由构建 3c 步从 content/src/shanhe_p_events.c 铺到 src/shanhe_p_events.c。
 *
 * 谁引用这些符号（接线在别处）：
 *   · src/events/prologue-eventinfo.h 的 `PrologueEvents`
 *     （补丁 shanhe-prologue-wiring.patch：turn/misc/tutorial/playerUnits/beginning/ending 字段）
 *   · 上面的 extern 声明在 include/eventcall.h（同一个补丁）
 *
 * ★ 本竖切的**有意简化**（不是遗漏，勿当 bug）：
 *   · 教学链先关掉（.tutorialEvents 指向「只有 NULL 哨兵」的数组）——
 *     上游那 15 个教学脚本按 Seth / Eirika 写死，换单位后会错位。
 *   · 开场不做上游的「RenaisThroneCutscene」前置演出（那是原版的序章剧情）；
 *     山河烬的序章演出待「文案 + 分镜」定稿后单独做。
 *   · 文本一律**暂用上游 message id** —— 山河烬的台词要走文本通道替换
 *     （新增可见文本只能走 texts/expansion/；改写已有段用 indexed_overrides，
 *      见 docs/6 §3.4d/§3.4e）。
 *   · 站位是占位值（章节表里已标注），等 ShanheP.tmx 定案后复位。
 */

#include "global.h"
#include "bmguide.h"
#include "bmunit.h"
#include "event.h"
#include "eventinfo.h"
#include "eventcall.h"
#include "EAstdlib.h"
#include "constants/characters.h"
#include "constants/backgrounds.h"
#include "constants/items.h"
#include "constants/items_expansion.h"   /* ITEM_SHANHE_ZHAOYE(0xCF) */
#include "constants/songs.h"
#include "constants/chapters.h"

CONST_DATA EventListScr EventScr_ShanheP_BeginningScene[] = {
    /* 四组单位都来自章节表通道生成的 UnitDef_ShanheP_*
     * （content/data/shanhe_p_units.json → src/shanhe_p_udefs.c） */
    LOAD1(1, UnitDef_ShanheP_Ally)       /* 虞聪 */
    LOAD1(2, UnitDef_ShanheP_Npc)        /* 虞旻（强力 NPC）+ 云虚（客串） */
    LOAD1(3, UnitDef_ShanheP_Enemy)      /* 尸傀 ×3 */
    LOAD1(4, UnitDef_ShanheP_Boss)       /* 瘸爷 */
    ENUN

    /* 虞聪的初始武器「照夜」（docs/3 §3.2：序章持有，第 17 章觉醒）
     * ★ 为什么在事件里发而不是写进 units 表的 items[]：
     *   扩展道具的符号在 include/constants/items_expansion.h，而 units 表的
     *   items[] 只认 include/constants/items.h（units/schema.py:65）⇒
     *   扩展道具**不能进表**，只能经事件发放。见 docs/5 §5.18.7 边界 ①。 */
    SVAL(EVT_SLOT_3, ITEM_SHANHE_ZHAOYE)
    GIVEITEMTO(CHARACTER_EIRIKA)

    /* ★ 序章开场旁白位 —— **当前仍显示上游文本**（FE8U target 0x090D ↔ FE8J source 0x08CD）。
     *   山河烬自己的旁白**已写好、也跑通过构建**，但卡在**字库补字**（见下）。
     *   ★ 字库缺口：圭 U+572D / 州 U+5DDE / 曰 U+66F0 / 煞 U+715E / 熙 U+7199 / 疫 U+75AB
     *     （大熙/豫州/史官记曰/煞疫/玉圭 —— 设定核心词，绕不开）
     *   ★ 补字进展（2026-09-28）：FEBuilderGBA 工具链**已在 WSL 重建完成**
     *     （.NET SDK 10.0.401 + 自建 FEBuilderGBA.CLI），但正式管线仍卡在
     *     `generate-inventory` 的 ja 宽度校验：
     *       error: ja/character_name_40/0x0212: canonical width 46px exceeds 40px without a display alias
     *     —— 该步**不属于** shanhe-build.sh，故不影响本构建；详见 docs/5 §5.18.11。
     *   ★ 显示调用用 `Text_BG(BG_PLAIN_2, …)` —— 上游对这一段就是这么显示的（多页长文本）；
     *     早先一版写成 `BROWNBOXTEXT`（棕色小框）是错的，装不下长文本。 */
    Text_BG(BG_PLAIN_2, 0x90D)

    NoFade
    ENDA
};

/* 结局：击退瘸爷 → 进行战后演出 → 收章。
 * `MNC2(0x1)` 是收章指令（原版序章同样用法）。 */
CONST_DATA EventListScr EventScr_ShanheP_EndingScene[] = {
    MUSC(SONG_VICTORY)
    SetBackground(BG_PLAIN_2)
    TEXTSHOW(0x918)
    TEXTEND
    FADI(16)
    REMA
    MNC2(0x1)
    ENDA
};
