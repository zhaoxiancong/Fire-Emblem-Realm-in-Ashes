#include "global.h"

/*
 * 《山河烬》原创神器机制（M3② 本体）。
 *
 * 首个落地神器：破军（ITEM_SHANHE_POJUN，枪，秦红缨第 3 章继承）。
 * 设计数值见 docs/3 §3.2 ——
 *   对甲士系：必杀 +20 且无视其 50% 防御
 *   对骑乘：  追击伤害 +3
 *
 * ── 实现通道（为什么这样写是对的） ─────────────────────────────
 * 前两个效果通过**框架公开的机制钩子**（include/expansion_mechanics.h）实现：
 *   ComputeBattleUnitStats() 在算完本方全部基础战斗数值后、且在
 *   ComputeBattleUnitEffectiveStats() 之前，调用一次
 *   ExpansionMechanicsApplyBattleStats(subject, opponent, cfg)。
 * 该 seam 的能力边界（详见 docs/5 §5.8 与 include/expansion_mechanics.h 的
 * "Apply order" 说明）：
 *   · 可改 subject 自己的 battle*（本文件改 battleCritRate）
 *   · opponent 的 battle* **不可读**（apply #1 时尚未算完）
 *   · 但 opponent 的 `unit` 层**可读**（职业/等级/状态/位置/HP）
 * 破军的条件判定只需 opponent 的**职业属性**（CA_*），落在可读范围内。
 *
 * 「无视其 50% 防御」的数学等价变换（避免读对手的 battle*）：
 *   原伤害 = myAttack - defenderDefense
 *   要的是  = myAttack - defenderDefense / 2
 *          = (myAttack + defenderDefense / 2) - defenderDefense
 * ⇒ 只需给**自己**加 defenderDefense / 2 点攻击。
 *   而 defenderDefense = defender->terrainDefense + GetUnitDefense(&defender->unit)
 *   正是 src/bmbattle.c:553 的 ComputeBattleUnitDefense 公式；其中
 *   terrainDefense 由 SetBattleUnitTerrainBonusesAuto() 设置，而它在
 *   BattleGenerate()（→ ComputeBattleUnitStats）**之前**就已调用完毕
 *   （src/bmbattle.c:159-160 与 162），故此处读到的是最终值。
 *   ⚠️ 魔法武器走 res 的那一支（bmbattle.c:548-551）在此一并复现。
 *
 * 「追击伤害 +3」不在本 seam 上（它一次只给"本次战斗的一组数值"），
 * 走第二个 seam：见 content/framework-patch/shanhe-shenqi-followup.patch
 * （用框架预留的 BATTLE_HIT_ATTR_FOLLOWUP 标记）。
 *
 * 内存：本文件无 EWRAM/BSS/rodata —— 全部是代码与常量，零 RAM 占用。
 * 兼容：C89 风格，不依赖任何 C99 特性（框架现代车道与归档车道都编译它）。
 */

#if FE8_EXPANSION_MECHANICS_HOOKS

#include "bmitem.h"
#include "bmbattle.h"
#include "bmunit.h"
#include "expansion_mechanics.h"
#include "constants/items_expansion.h"

/* 本机制在钩子注册表里的键（唯一，≤ EXPANSION_MECHANICS_KEY_SIZE-1 字符）。 */
#define SHANHE_POJUN_KEY   "shanhe.shenqi_pojun"
#define SHANHE_POJUN_LABEL "Pojun: anti-armor"

/* 数值（唯一事实来源 = docs/3 §3.2；改数值先改文档）。 */
#define SHANHE_POJUN_ARMOR_CRIT_BONUS      20  /* 对甲士系 必杀 +20 */
#define SHANHE_POJUN_ARMOR_DEF_PIERCE_DIV   2  /* 无视 50% 防御 = 减去 defenderDef / 2 */

/* subject 是否正握着破军？ */
static int ShanhePojunIsWielding(struct BattleUnit* subject)
{
    return GetItemIndex(subject->weapon) == ITEM_SHANHE_POJUN;
}

/* 对手是否是「甲士系」（对应用 CA_TRIANGLEATTACK_ARMORS 判定，见 docs/5 §5.8）。 */
static int ShanhePojunTargetIsArmor(const struct BattleUnit* opponent)
{
    if (opponent == NULL)
        return 0;

    return (UNIT_CATTRIBUTES(&opponent->unit) & CA_TRIANGLEATTACK_ARMORS) != 0;
}

/*
 * 复现 ComputeBattleUnitDefense()（src/bmbattle.c:547-554）的防御取值：
 * 魔法武器 / 魔法伤害武器按 res 计，其余按 def 计。
 * 之所以要看 subject 的武器（而非对手的），是因为原函数签名是
 * ComputeBattleUnitDefense(attacker, defender) —— 它用 defender->weapon 判断
 * "打过来的是不是魔法"，此处 subject 就是那个 attacker。
 *
 * ⚠️ 必须用**裸** unit.def / unit.res（不加道具加成）：原实现第 553 行写的正是
 *    `attacker->terrainDefense + attacker->unit.def`，**不是** GetUnitDefense()
 *    （后者会额外加 GetItemDefBonus，与原实现不一致 ⇒ 会多扣血）。
 *    这里逐字对齐原实现，保证"无视 50%"扣掉的正是对手实际承受的那份防御。
 */
static int ShanhePojunTargetDefense(struct BattleUnit* subject, const struct BattleUnit* opponent)
{
    int terrain = opponent->terrainDefense;
    int unitValue;

    (void)subject; /* 保留参数以便日后按 subject 的魔法属性分支；当前与原实现一致 */

    if ((GetItemAttributes(opponent->weapon) & IA_MAGICDAMAGE)
        || (GetItemAttributes(opponent->weapon) & IA_MAGIC))
        unitValue = opponent->unit.res;
    else
        unitValue = opponent->unit.def;

    return terrain + unitValue;
}

/*
 * 破军的战斗数值机制。在两种 apply 顺序下都必须正确 —— 本函数**只读**
 * opponent 的 unit 层字段，从不读 opponent 的 battle*，故天然满足。
 */
static void ShanhePojunApplyBattleStats(
    struct BattleUnit* subject,
    const struct ExpansionMechanicsContext* context)
{
    int defPierce;

    /* 没握破军（或对手缺席）→ 什么都不做。 */
    if (!ShanhePojunIsWielding(subject))
        return;

    if (!ShanhePojunTargetIsArmor(context->opponent))
        return;

    /* ① 对甲士系：必杀 +20（clamp 到 100，避免面板溢出显示）。 */
    subject->battleCritRate += SHANHE_POJUN_ARMOR_CRIT_BONUS;

    if (subject->battleCritRate > 100)
        subject->battleCritRate = 100;

    /* ② 对甲士系：无视其 50% 防御（等价变换为给自己加 defenderDef/2 攻击）。 */
    defPierce = ShanhePojunTargetDefense(subject, context->opponent)
              / SHANHE_POJUN_ARMOR_DEF_PIERCE_DIV;

    subject->battleAttack += (short)defPierce;
}

/*
 * 安装入口。由框架的 ExpansionMechanicsInstallBuiltins() 调用
 * （见 content/framework-patch/shanhe-shenqi-install.patch）——
 * 那条补丁是本项目对框架的唯一挂载点。
 */
void ShanheShenqiInstallMechanics(void)
{
    ExpansionMechanicsRegister(
        SHANHE_POJUN_KEY,
        SHANHE_POJUN_LABEL,
        ShanhePojunApplyBattleStats);
}

#else /* !FE8_EXPANSION_MECHANICS_HOOKS */

/* 与框架惯例一致：禁用时保持符号存在，细节编译掉。 */
void ShanheShenqiInstallMechanics(void)
{
}

#endif /* FE8_EXPANSION_MECHANICS_HOOKS */
