#!/usr/bin/env bash
# ============================================================
# 《山河烬》FE8 改版环境搭建 —— 第二阶段（在 WSL/Ubuntu 内运行）
# ------------------------------------------------------------
# 前置：已完成 1-install-wsl.ps1 并重启，Ubuntu 已初始化。
#
# 用法：在 WSL 终端里执行
#   bash /mnt/d/workbuddy/FireEmblem\ Realm-in-Ashes/tools/2-setup-project.sh
#
# 或者先拷贝到 WSL 内再跑（推荐）：
#   cp "/mnt/d/workbuddy/FireEmblem Realm-in-Ashes/tools/2-setup-project.sh" ~/
#   bash ~/2-setup-project.sh
#
# 作用：克隆框架 → 安装依赖 → 构建 → 出中文版 ROM
# ============================================================

set -euo pipefail

# ---------- 配置 ----------
FRAMEWORK_REPO="https://github.com/laqieer/fireemblem8-expansion.git"
WORK_DIR="$HOME/projects"
FRAMEWORK_DIR="$WORK_DIR/fireemblem8-expansion"
ROM_SIZE="32M"
LOCALES="en,zh-Hans"

# ---------- 工具函数 ----------
c_cyan='\033[0;36m'; c_green='\033[0;32m'; c_yellow='\033[1;33m'; c_red='\033[0;31m'; c_off='\033[0m'
step() { printf "\n${c_cyan}=== %s ===${c_off}\n" "$1"; }
ok()   { printf "${c_green}[OK] %s${c_off}\n" "$1"; }
warn() { printf "${c_yellow}[!] %s${c_off}\n" "$1"; }
err()  { printf "${c_red}[X] %s${c_off}\n" "$1"; }

# ---------- 0. 环境自检 ----------
step "0. 环境自检"

if ! grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
  warn "似乎不在 WSL 中运行。若在原生 Linux 上，可继续（Ubuntu/Arch 支持）。"
fi

if [ "$(id -u)" -eq 0 ]; then
  err "请勿用 root 运行。请用普通用户（脚本会在需要时提示 sudo）。"
  exit 1
fi

echo "用户：$(whoami)"
echo "家目录：$HOME"

# 磁盘检查
avail_kb=$(df -Pk "$HOME" | awk 'NR==2 {print $4}')
avail_gb=$(( avail_kb / 1024 / 1024 ))
echo "可用磁盘：${avail_gb} GB"
if [ "$avail_gb" -lt 5 ]; then
  err "磁盘空间不足（需约 5 GB）。请先清理。"
  exit 1
fi
ok "磁盘空间充足"

# 警告：不要在 /mnt/ 下构建
case "$PWD" in
  /mnt/*) warn "当前目录在 /mnt/ 下，构建会极慢。建议 cd ~ 后再运行本脚本。" ;;
esac

# 发行版识别
if [ -f /etc/os-release ]; then
  . /etc/os-release
  echo "发行版：$PRETTY_NAME"
else
  warn "无法识别发行版"
fi

# ---------- 1. 克隆框架 ----------
step "1. 克隆 FE8 扩展框架"

mkdir -p "$WORK_DIR"

if [ -d "$FRAMEWORK_DIR/.git" ]; then
  ok "框架已存在：$FRAMEWORK_DIR"
  read -r -p "是否更新到最新？(y/N) " upd
  if [ "$upd" = "y" ] || [ "$upd" = "Y" ]; then
    git -C "$FRAMEWORK_DIR" pull --ff-only || warn "更新失败，继续用现有版本"
    git -C "$FRAMEWORK_DIR" submodule update --init --recursive
  fi
else
  echo "克隆到 $FRAMEWORK_DIR ..."
  git clone --recursive "$FRAMEWORK_REPO" "$FRAMEWORK_DIR"
  ok "克隆完成"
fi

cd "$FRAMEWORK_DIR"
ok "工作目录：$(pwd)"

# ---------- 2. 安装依赖 ----------
step "2. 安装构建依赖"

if command -v apt-get >/dev/null 2>&1; then
  echo "检测到 apt（Ubuntu/WSL），安装依赖..."
  sudo apt-get update -qq
  sudo apt-get install -y \
    build-essential git \
    gcc-arm-none-eabi binutils-arm-none-eabi libnewlib-arm-none-eabi \
    gdb-multiarch \
    libmgba-dev mgba-sdl \
    pkg-config libpng-dev python3 python3-pip python3-numpy python3-pil
  ok "apt 依赖安装完成"
elif command -v pacman >/dev/null 2>&1; then
  echo "检测到 pacman（Arch），安装依赖..."
  sudo pacman -S --needed --noconfirm \
    base-devel git arm-none-eabi-gcc arm-none-eabi-newlib arm-none-eabi-gdb \
    mgba pkgconf libpng python python-pip python-numpy python-pillow
  ok "pacman 依赖安装完成"
else
  warn "未识别的包管理器，请手动安装依赖后重跑本脚本"
fi

# 验证工具链
step "2.1 验证工具链"
missing=0
for tool in arm-none-eabi-gcc arm-none-eabi-ld arm-none-eabi-objcopy python3 make git; do
  if command -v "$tool" >/dev/null 2>&1; then
    printf "  %-24s %s\n" "$tool" "$(command -v "$tool")"
  else
    err "缺少：$tool"; missing=1
  fi
done
[ "$missing" -eq 0 ] && ok "工具链完整" || err "工具链不完整，请先补齐"

# 可选：调试器与模拟器
for tool in gdb-multiarch arm-none-eabi-gdb mgba mgba-sdl; do
  command -v "$tool" >/dev/null 2>&1 && printf "  %-24s %s\n" "$tool" "$(command -v "$tool")"
done

# ---------- 3. 首次构建 ----------
step "3. 首次构建（默认 release ROM）"
echo "这一步最长约 15 分钟，请耐心等待..."
make -j"$(nproc)"

if [ -f "build/expansion-modern/release/aapcs/fireemblem8.gba" ] || \
   [ -f "build/expansion-modern/release/aapcs/fireemblem8.gba" ]; then
  ok "默认构建成功"
else
  warn "未找到预期产物，检查 build/ 目录："
  find build -name '*.gba' 2>/dev/null || true
fi

# ---------- 4. 中文版构建 ----------
step "4. 构建中文版 ROM（32M）"
echo "配置：locales=$LOCALES, rom-size=$ROM_SIZE"

if ./configure --with-enabled-locales="$LOCALES" --with-default-locale=zh-Hans \
     --with-rom-size="$ROM_SIZE" 2>/dev/null; then
  ok "configure 完成"
  make -j"$(nproc)"
  ok "中文版构建完成"
else
  warn "configure 不支持这些参数，改用命名 profile"
  make expansion-modern-localization-profile-en-zh-hans -j"$(nproc)" || \
    err "中文版构建失败，请查看上方输出"
fi

# ---------- 5. 结果 ----------
step "5. 构建产物"
find build -name '*.gba' -exec ls -lh {} \; 2>/dev/null || echo "（未找到 .gba）"

cat <<EOF

${c_green}============================================${c_off}
${c_green}  环境搭建完成${c_off}
${c_green}============================================${c_off}

接下来：

1) 在 Windows 里玩：
   - 从 Windows 访问 WSL 文件路径：\\\\wsl\$\\Ubuntu\\home\\$(whoami)\\projects\\fireemblem8-expansion\\build\\
   - 用 mGBA 打开 .gba 文件

2) 用 VS Code 开发（推荐）：
   - 安装 VS Code + "WSL" 扩展
   - Ctrl+Shift+P → "WSL: Connect to WSL"
   - 打开 ~/projects/fireemblem8-expansion

3) 验证数据管线：
   cd ~/projects/fireemblem8-expansion
   make generated-data-check

4) 【本项目 P0 最高优先级】实测中文字库容量：
   见工程手册 §5.1 与 §8 待办

EOF

ok "全部完成"
