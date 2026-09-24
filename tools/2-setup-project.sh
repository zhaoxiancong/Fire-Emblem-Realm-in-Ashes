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

# ---------- 1. 网络与代理 ----------
step "1. 网络与代理配置"

# WSL 内的 apt / git 默认不走 Windows 的 Clash 代理，中国大陆环境下会极慢或超时。
# 本步骤会：先试直连 → 不行再逐个候选代理探测 → 命中则自动配置环境变量与 apt。
CLASH_PORT="${CLASH_PORT:-7897}"   # Clash Verge 默认混合端口

# 候选代理地址：
#   镜像网络（networkingMode=mirrored）→ WSL 与 Windows 共用网络栈，用 127.0.0.1
#   NAT 模式 → 需用默认网关（Windows 宿主）地址
GW="$(ip route show default 2>/dev/null | awk '{print $3}' | head -1)"
CANDIDATES="http://127.0.0.1:${CLASH_PORT}"
[ -n "$GW" ] && CANDIDATES="$CANDIDATES http://${GW}:${CLASH_PORT}"

http_code() {  # $1=url  $2=可选代理
  if [ -n "${2:-}" ]; then
    curl -s -o /dev/null -w '%{http_code}' --max-time 10 -x "$2" "$1" 2>/dev/null || echo "000"
  else
    curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$1" 2>/dev/null || echo "000"
  fi
}
is_ok() { case "$1" in 200|301|302|307|308) return 0 ;; *) return 1 ;; esac; }

if ! command -v curl >/dev/null 2>&1; then
  warn "未安装 curl，跳过网络探测（apt 安装后会自动具备）"
else
  [ -n "$GW" ] && echo "  默认网关（Windows 宿主）= $GW"
  direct="$(http_code https://github.com)"
  echo "  直连 github.com → HTTP $direct"

  if is_ok "$direct"; then
    ok "直连可用，无需代理"
  else
    chosen=""
    for p in $CANDIDATES; do
      code="$(http_code https://github.com "$p")"
      echo "  经 $p → HTTP $code"
      if is_ok "$code"; then chosen="$p"; break; fi
    done

    if [ -n "$chosen" ]; then
      export http_proxy="$chosen"
      export https_proxy="$chosen"
      ok "已启用代理：$chosen"

      # 写入 ~/.bashrc（幂等）
      if ! grep -q "山河烬代理配置" "$HOME/.bashrc" 2>/dev/null; then
        {
          echo ""
          echo "# === 山河烬代理配置 ==="
          echo "export http_proxy=\"$chosen\""
          echo "export https_proxy=\"$chosen\""
        } >> "$HOME/.bashrc"
        ok "已写入 ~/.bashrc（下次登录自动生效）"
      fi

      # apt 不继承用户环境变量，需单独配置
      sudo tee /etc/apt/apt.conf.d/95proxy >/dev/null <<EOT
Acquire::http::Proxy "$chosen";
Acquire::https::Proxy "$chosen";
EOT
      ok "已配置 apt 代理"
    else
      warn "未找到可用代理（尝试过：$CANDIDATES）"
      cat <<'EOT'

    请检查：
      1) Clash 是否在运行？混合端口是否为 7897？（设置里可见，可改）
      2) 是否已开启「系统代理」或「虚拟网卡(TUN)」？
      3) 若用 NAT 网络模式，需在 Clash 里打开「允许局域网连接」
      4) 端口不是 7897 时，用环境变量指定后重跑：
           CLASH_PORT=你的端口 bash 2-setup-project.sh
      5) 确认 Windows 侧已有 %USERPROFILE%\.wslconfig 且含：
           [wsl2]
           networkingMode=mirrored
         改完执行  wsl --shutdown  再重进

EOT
      read -r -p "    仍要继续？(y/N) " cont
      case "$cont" in y|Y) ;; *) err "已中止。配置好代理后重跑本脚本。"; exit 1 ;; esac
    fi
  fi
fi

step "2. 克隆 FE8 扩展框架"

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
step "3. 安装构建依赖"

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
step "3.1 验证工具链"
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
step "4. 首次构建（默认 release ROM）"
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
step "5. 构建中文版 ROM（32M）"
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
step "6. 构建产物"
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
