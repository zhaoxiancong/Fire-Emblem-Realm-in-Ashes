#!/bin/bash
cd ~/projects/fireemblem8-expansion || exit 1
ELF=build/expansion-modern/release/aapcs/fireemblem8.elf
T=0x080BF0F7

echo "=== 命中 0x080BF0F7 的符号（按地址+大小）==="
arm-none-eabi-nm -S -n "$ELF" 2>/dev/null | awk -v t=$((T)) '
  NF>=4 { a=strtonum("0x"$1); s=strtonum("0x"$2); if (a<=t && t<a+s) print "命中:", $0 }
  NF==3 { a=strtonum("0x"$1); lasta=a; lastn=$3 }
'

echo
echo "=== uimenu.c 相关符号（0x080BE600 ~ 0x080BF600）==="
arm-none-eabi-nm -S -n "$ELF" 2>/dev/null | awk 'strtonum("0x"$1)>=0x080BE600 && strtonum("0x"$1)<=0x080BF600'

echo
echo "=== 用 objdump 反汇编 0x080BF0D0~0x080BF110 ==="
arm-none-eabi-objdump -d --start-address=0x080BF0D0 --stop-address=0x080BF112 "$ELF" 2>/dev/null | tail -25
