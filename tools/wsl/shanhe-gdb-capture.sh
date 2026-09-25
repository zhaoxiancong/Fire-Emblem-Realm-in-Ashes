#!/bin/bash
# ============================================================
# 山河烬 崩溃现场抓取
#   连接 mGBA 的 GDB server，dump PC/LR/SP/全部寄存器/栈
# 用法: bash shanhe-gdb-capture.sh [port] [outfile]
# ============================================================
PORT="${1:-2345}"
OUT="${2:-/tmp/shanhe-crash/capture.txt}"
mkdir -p "$(dirname "$OUT")"

gdb-multiarch -q -batch \
  -ex "set pagination off" \
  -ex "set confirm off" \
  -ex "set architecture arm" \
  -ex "target remote localhost:$PORT" \
  -ex 'printf "=== 崩溃现场 ===\n"' \
  -ex 'printf "PC  = 0x%08x\n", $pc' \
  -ex 'printf "LR  = 0x%08x\n", $lr' \
  -ex 'printf "SP  = 0x%08x\n", $sp' \
  -ex 'printf "CPSR= 0x%08x\n", $cpsr' \
  -ex 'printf "\n--- 通用寄存器 ---\n"' \
  -ex 'printf "R0 =0x%08x  R1 =0x%08x  R2 =0x%08x  R3 =0x%08x\n", $r0,$r1,$r2,$r3' \
  -ex 'printf "R4 =0x%08x  R5 =0x%08x  R6 =0x%08x  R7 =0x%08x\n", $r4,$r5,$r6,$r7' \
  -ex 'printf "R8 =0x%08x  R9 =0x%08x  R10=0x%08x  R11=0x%08x  R12=0x%08x\n", $r8,$r9,$r10,$r11,$r12' \
  -ex 'printf "\n--- 栈内容 (SP 起 48 字) ---\n"' \
  -ex 'x/48wx $sp' \
  -ex 'printf "\n--- 调用栈 ---\n"' \
  -ex 'bt' \
  -ex 'detach' 2>&1 | tee "$OUT"

echo
echo "已保存: $OUT"
