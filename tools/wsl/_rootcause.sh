#!/bin/bash
cd /home/shanhe/projects/fireemblem8-expansion || exit 1

echo "=== ① AttackCommandUsability 实现 ==="
grep -n -A30 "u8 AttackCommandUsability" src/bmmenu.c 2>/dev/null | head -40

echo
echo "=== ② 它依赖的 CanUnitAttack / 射程判定 ==="
grep -n -A20 "CanUnitAttack" src/bmmenu.c 2>/dev/null | head -30

echo
echo "=== ③ Prologue 里 ~ATTACK 那段上下文（DISABLEOPTIONS 前后）==="
sed -n '135,175p' src/events/prologue-tutorials.h

echo
echo "=== ④ 该段事件脚本的完整内容（看是否有"移动到敌人旁再开菜单"）==="
sed -n '100,160p' src/events/prologue-tutorials.h
