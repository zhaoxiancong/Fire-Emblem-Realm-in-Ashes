#!/usr/bin/env bash
# ============================================================
# 《山河烬》环境自检脚本
# 用途：确认 WSL 环境、工具链、框架、构建产物是否齐全
# 用法：bash 3-verify-env.sh
# ============================================================

FRAMEWORK_DIR="$HOME/projects/fireemblem8-expansion"

c_cyan='\033[0;36m'; c_green='\033[0;32m'; c_yellow='\033[1;33m'; c_red='\033[0;31m'; c_off='\033[0m'
pass=0; fail=0; warns=0

chk() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf "  ${c_green}✓${c_off} %s\n" "$label"; pass=$((pass+1))
  else
    printf "  ${c_red}✗${c_off} %s\n" "$label"; fail=$((fail+1))
  fi
}

chkver() {
  local label="$1" cmd="$2"
  if command -v "$cmd" >/dev/null 2>&1; then
    local v; v=$("$cmd" --version 2>&1 | head -1)
    printf "  ${c_green}✓${c_off} %-22s %s\n" "$label" "$v"; pass=$((pass+1))
  else
    printf "  ${c_red}✗${c_off} %-22s 未安装\n" "$label"; fail=$((fail+1))
  fi
}

printf "\n${c_cyan}=== 1. 运行环境 ===${c_off}\n"
if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
  printf "  ${c_green}✓${c_off} 运行在 WSL 中\n"; pass=$((pass+1))
else
  printf "  ${c_yellow}!${c_off} 不在 WSL 中（原生 Linux 也可）\n"; warns=$((warns+1))
fi
[ -f /etc/os-release ] && { . /etc/os-release; printf "     发行版：%s\n" "$PRETTY_NAME"; }

avail_gb=$(( $(df -Pk "$HOME" | awk 'NR==2 {print $4}') / 1024 / 1024 ))
if [ "$avail_gb" -ge 5 ]; then
  printf "  ${c_green}✓${c_off} 磁盘可用 %s GB\n" "$avail_gb"; pass=$((pass+1))
else
  printf "  ${c_red}✗${c_off} 磁盘仅 %s GB（建议 ≥5 GB）\n" "$avail_gb"; fail=$((fail+1))
fi

printf "\n${c_cyan}=== 2. 必需工具链 ===${c_off}\n"
chkver "arm-none-eabi-gcc"    arm-none-eabi-gcc
chkver "arm-none-eabi-ld"     arm-none-eabi-ld
chkver "arm-none-eabi-objcopy" arm-none-eabi-objcopy
chkver "make"                 make
chkver "git"                  git
chkver "python3"              python3

printf "\n${c_cyan}=== 3. Python 依赖 ===${c_off}\n"
chk "numpy"      python3 -c "import numpy"
chk "PIL/Pillow" python3 -c "import PIL"

printf "\n${c_cyan}=== 4. 调试与模拟（可选）===${c_off}\n"
for t in gdb-multiarch arm-none-eabi-gdb mgba mgba-sdl; do
  if command -v "$t" >/dev/null 2>&1; then
    printf "  ${c_green}✓${c_off} %s\n" "$t"; pass=$((pass+1))
  else
    printf "  ${c_yellow}!${c_off} %s 未安装（可选）\n" "$t"; warns=$((warns+1))
  fi
done

printf "\n${c_cyan}=== 5. 框架仓库 ===${c_off}\n"
if [ -d "$FRAMEWORK_DIR/.git" ]; then
  printf "  ${c_green}✓${c_off} 仓库存在：%s\n" "$FRAMEWORK_DIR"; pass=$((pass+1))
  printf "     分支：%s\n" "$(git -C "$FRAMEWORK_DIR" rev-parse --abbrev-ref HEAD)"
  printf "     提交：%s\n" "$(git -C "$FRAMEWORK_DIR" log -1 --format='%h %s')"
  sub=$(git -C "$FRAMEWORK_DIR" submodule status 2>/dev/null | wc -l)
  printf "     子模块：%s 个\n" "$sub"
else
  printf "  ${c_red}✗${c_off} 未找到框架仓库：%s\n" "$FRAMEWORK_DIR"; fail=$((fail+1))
fi

printf "\n${c_cyan}=== 6. 构建产物 ===${c_off}\n"
if [ -d "$FRAMEWORK_DIR" ]; then
  found=$(find "$FRAMEWORK_DIR/build" -name '*.gba' 2>/dev/null || true)
  if [ -n "$found" ]; then
    echo "$found" | while read -r f; do ls -lh "$f" | awk '{printf "  ✓ %s  (%s)\n", $9, $5}'; done
    pass=$((pass+1))
  else
    printf "  ${c_yellow}!${c_off} 尚未构建出 ROM（运行 make）\n"; warns=$((warns+1))
  fi
fi

printf "\n${c_cyan}=== 7. 中文支持检查 ===${c_off}\n"
if [ -d "$FRAMEWORK_DIR" ]; then
  if [ -f "$FRAMEWORK_DIR/texts/locales/zh-Hans/indexed.txt" ]; then
    lines=$(wc -l < "$FRAMEWORK_DIR/texts/locales/zh-Hans/indexed.txt")
    printf "  ${c_green}✓${c_off} zh-Hans 文本存在（%s 行）\n" "$lines"; pass=$((pass+1))
  else
    printf "  ${c_yellow}!${c_off} 未找到 texts/locales/zh-Hans/indexed.txt\n"; warns=$((warns+1))
  fi
  if [ -f "$FRAMEWORK_DIR/texts/expansion/catalog.zh-Hans.json" ]; then
    printf "  ${c_green}✓${c_off} zh-Hans 扩展目录存在\n"; pass=$((pass+1))
  fi
fi

printf "\n${c_green}============================================${c_off}\n"
printf "  通过 %d 项　失败 %d 项　提示 %d 项\n" "$pass" "$fail" "$warns"
printf "${c_green}============================================${c_off}\n\n"

if [ "$fail" -gt 0 ]; then
  printf "${c_red}存在失败项，请检查上方 ✗ 标记。${c_off}\n\n"
  exit 1
fi
printf "${c_green}环境就绪。${c_off}\n\n"
