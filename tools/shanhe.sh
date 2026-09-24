#!/usr/bin/env bash
# ============================================================
# 《山河烬》FE8 改版 —— 一键诊断 / 修复 / 构建
# ------------------------------------------------------------
# 只跑这一条，别的一律不用记：
#
#   bash ~/shanhe.sh
#
# 首次使用（从 GitHub 拉取，WSL 内任意目录可用）：
#   curl -fsSL https://raw.githubusercontent.com/zhaoxiancong/Fire-Emblem-Realm-in-Ashes/main/tools/wsl/shanhe.sh -o ~/shanhe.sh && bash ~/shanhe.sh
#
# 环境变量可覆盖：
#   FRAMEWORK_DIR=/path  CLASH_PORT=7897  SKIP_BUILD=1  AUTO=1  bash ~/shanhe.sh
#     SKIP_BUILD=1  只诊断不构建
#     AUTO=1        全程不询问，自动做所有能做的修复
# ============================================================

set +e
export LANG=C.UTF-8 LC_ALL=C.UTF-8

FRAMEWORK_DIR="${FRAMEWORK_DIR:-$HOME/projects/fireemblem8-expansion}"
FRAMEWORK_REPO="${FRAMEWORK_REPO:-https://github.com/laqieer/fireemblem8-expansion.git}"
CLASH_PORT="${CLASH_PORT:-7897}"
LOG_DIR="$HOME/shanhe-logs"
MARKER="/tmp/.shanhe-step"
mkdir -p "$LOG_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$LOG_DIR/shanhe-$STAMP.log"

c_cyan=$'\033[0;36m'; c_green=$'\033[0;32m'; c_yellow=$'\033[1;33m'
c_red=$'\033[0;31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'

# ── 输出：屏幕为主，同时把「去色版」追加进报告文件 ──
# 不用 exec 劫持 stdout（进程替换在各 bash 版本下行为不一），改为每个输出函数各写两处
_plain() { sed -e 's/\x1b\[[0-9;]*m//g'; }
H() { printf "\n%s━━━━━━ %s ━━━━━━%s\n" "$c_cyan" "$1" "$c_off"
      printf "\n===== %s =====\n" "$1" >> "$REPORT"; }
ok()   { printf "  %s✓%s %s\n" "$c_green" "$c_off" "$1";   printf "  [OK] %s\n" "$1" >> "$REPORT"; }
bad()  { printf "  %s✗%s %s\n" "$c_red" "$c_off" "$1";     printf "  [X]  %s\n" "$1" >> "$REPORT"; }
warn() { printf "  %s!%s %s\n" "$c_yellow" "$c_off" "$1";  printf "  [!]  %s\n" "$1" >> "$REPORT"; }
dim()  { printf "  %s%s%s\n" "$c_dim" "$1" "$c_off";       printf "       %s\n" "$1" >> "$REPORT"; }
raw()  { printf '%s\n' "$1"; printf '%s\n' "$1" >> "$REPORT"; }
ask()  { # $1=提示
  if [ "${AUTO:-0}" = "1" ]; then ok "AUTO 模式：自动回答「是」"; return 0; fi
  printf "  %s→ %s (y/N) %s" "$c_yellow" "$1" "$c_off"
  local a; read -r a; case "$a" in y|Y) return 0 ;; *) return 1 ;; esac
}

H() { printf "\n%s━━━━━━ %s ━━━━━━%s\n" "$c_cyan" "$1" "$c_off"; echo "### $1" >> "$REPORT"; }
ok()   { printf "  %s✓%s %s\n" "$c_green" "$c_off" "$1"; }
bad()  { printf "  %s✗%s %s\n" "$c_red" "$c_off" "$1"; }
warn() { printf "  %s!%s %s\n" "$c_yellow" "$c_off" "$1"; }
dim()  { printf "  %s%s%s\n" "$c_dim" "$1" "$c_off"; }
ask()  { # $1=提示 $2=默认(y/N → N)
  if [ "${AUTO:-0}" = "1" ]; then ok "AUTO 模式：自动回答「是」"; return 0; fi
  printf "  %s→ %s (y/N) %s" "$c_yellow" "$1" "$c_off"
  local a; read -r a; case "$a" in y|Y) return 0 ;; *) return 1 ;; esac
}

printf "%s╔══════════════════════════════════════════════════════╗%s\n" "$c_cyan" "$c_off"
printf "%s║        《山河烬》一键诊断 / 修复 / 构建              ║%s\n" "$c_cyan" "$c_off"
printf "%s╚══════════════════════════════════════════════════════╝%s\n" "$c_cyan" "$c_off"
printf "  时间：%s\n" "$(date '+%F %T')"
printf "  报告：%s\n" "$REPORT"
printf "  跑完后如需反馈，执行：%s cat %s %s\n" "$c_dim" "$REPORT" "$c_off"

# ══════════════════════════════════════════
# 1. 前置
# ══════════════════════════════════════════
H "1 / 8  前置检查"

if [ -d "$FRAMEWORK_DIR/.git" ]; then
  cd "$FRAMEWORK_DIR" || exit 1
  ok "框架目录 $FRAMEWORK_DIR"
  dim "分支 $(git rev-parse --abbrev-ref HEAD 2>/dev/null) · 提交 $(git log --oneline -1 2>/dev/null)"
else
  warn "框架不存在，需要克隆"
  if ask "现在克隆框架到 $FRAMEWORK_DIR ？（含子模块）"; then
    mkdir -p "$(dirname "$FRAMEWORK_DIR")"
    git clone --recursive "$FRAMEWORK_REPO" "$FRAMEWORK_DIR" && cd "$FRAMEWORK_DIR" \
      && { [ -f .gitmodules ] && git submodule update --init --recursive 2>&1 | tail -10 | sed 's/^/      /'; ok "克隆完成（含子模块）"; }
  else
    bad "已中止"; exit 1
  fi
fi

# ══════════════════════════════════════════
# 2. 代理
# ══════════════════════════════════════════
H "2 / 8  网络与代理"

PROXY_OK=0
for p in "${https_proxy:-}" "http://127.0.0.1:${CLASH_PORT}" "http://$(ip route show default 2>/dev/null | awk '{print $3}' | head -1):${CLASH_PORT}"; do
  [ -z "$p" ] && continue
  if curl -sI --max-time 8 -x "$p" https://github.com >/dev/null 2>&1; then
    export http_proxy="$p" https_proxy="$p" all_proxy="$p"
    git config --global http.proxy "$p" 2>/dev/null
    git config --global https.proxy "$p" 2>/dev/null
    ok "代理可用并已配置：$p"
    PROXY_OK=1; break
  fi
done
[ "$PROXY_OK" -eq 0 ] && warn "未找到可用代理 —— git 拉取可能失败（apt 走国内源不受影响）"
# 国内镜像永远直连
export no_proxy="mirrors.tuna.tsinghua.edu.cn,mirrors.aliyun.com,localhost,127.0.0.1"
export NO_PROXY="$no_proxy"

# ══════════════════════════════════════════
# 3. 工作区完整性 —— 差集法（核心）
# ══════════════════════════════════════════
H "3 / 8  工作区完整性（上游 vs 本地差集）"

git rev-parse HEAD >/dev/null 2>&1 || { bad "不是有效的 git 仓库"; exit 1; }

UP="$(mktemp)"; LO="$(mktemp)"
git ls-tree -r HEAD --name-only 2>/dev/null | sort > "$UP"
find . -type f -not -path './.git/*' 2>/dev/null | sed 's|^\./||' | sort > "$LO"
up_n=$(wc -l < "$UP"); lo_n=$(wc -l < "$LO")
missing="$(comm -23 "$UP" "$LO")"
miss_n=$(printf '%s' "$missing" | grep -c . 2>/dev/null); miss_n=${miss_n:-0}

dim "上游跟踪 $up_n 个文件 · 本地存在 $lo_n 个文件 · 缺失 $miss_n 个"

FIXED=0
if [ "$miss_n" -gt 0 ]; then
  bad "本地缺失 $miss_n 个被跟踪的文件，前 30 个："
  raw "$(printf '%s\n' "$missing" | head -30 | sed 's/^/      /')"
  [ "$miss_n" -gt 30 ] && dim "      …… 其余 $((miss_n - 30)) 个略"
  raw ""
  dim "── 这说明工作区不完整，而不是某个文件单独出问题 ──"

  # 三级递进重检出
  dim "尝试重检出（三级递进）…"
  git checkout HEAD -- . 2>/dev/null
  git restore --source=HEAD --staged --worktree . 2>/dev/null
  # 把被标记为 skip-worktree / assume-unchanged 的文件解标记（它们会阻止检出）
  git ls-files -v 2>/dev/null | awk '/^[a-z]/ {print $2}' | while read -r p; do
    [ -n "$p" ] && git update-index --no-skip-worktree --no-assume-unchanged "$p" 2>/dev/null
  done
  git checkout HEAD -- . 2>/dev/null

  find . -type f -not -path './.git/*' 2>/dev/null | sed 's|^\./||' | sort > "$LO"
  miss_n2=$(comm -23 "$UP" "$LO" | grep -c . 2>/dev/null); miss_n2=${miss_n2:-0}
  if [ "$miss_n2" -eq 0 ]; then
    ok "重检出成功，工作区已完整"
    FIXED=1
  else
    bad "重检出后仍缺 $miss_n2 个文件"
    dim "前 15 个仍缺："
    raw "$(comm -23 "$UP" "$LO" | head -15 | sed 's/^/      /')"
    raw ""
    warn "仓库副本可能已损坏。最稳妥是重新克隆（旧目录会保留为 .broken 后缀）"
    if ask "现在重新克隆？"; then
      cd "$(dirname "$FRAMEWORK_DIR")" || exit 1
      mv "$FRAMEWORK_DIR" "${FRAMEWORK_DIR}.broken.$(date +%s)"
      # 关键：用 --recursive 一次拉全，避免克隆后子模块仍为空
      if git clone --recursive "$FRAMEWORK_REPO" "$FRAMEWORK_DIR"; then
        cd "$FRAMEWORK_DIR" || exit 1
        ok "重克隆完成（含子模块）"
      else
        bad "重克隆失败"
        cd "$FRAMEWORK_DIR" 2>/dev/null || true
      fi
      # 二次保险：显式再拉一次子模块
      [ -f .gitmodules ] && git submodule update --init --recursive 2>&1 | tail -10 | sed 's/^/      /'
      find . -type f -not -path './.git/*' 2>/dev/null | sed 's|^\./||' | sort > "$LO"
      miss_n2=$(comm -23 "$UP" "$LO" | grep -c . 2>/dev/null); miss_n2=${miss_n2:-0}
      [ "$miss_n2" -eq 0 ] && { ok "重克隆后工作区完整"; FIXED=1; } || bad "仍缺 $miss_n2 个"
    fi
  fi
else
  ok "工作区完整（无缺失文件）"
fi
rm -f "$UP" "$LO"

# ══════════════════════════════════════════
# 4. 关键构建依赖
# ══════════════════════════════════════════
H "4 / 8  构建依赖"

need_install=0
for t in arm-none-eabi-gcc arm-none-eabi-as arm-none-eabi-ld arm-none-eabi-objcopy make python3 git; do
  command -v "$t" >/dev/null 2>&1 && ok "$t" || { bad "$t 缺失"; need_install=1; }
done
for m in numpy PIL; do
  python3 -c "import $m" >/dev/null 2>&1 && ok "python3 $m" || { bad "python3 $m 缺失"; need_install=1; }
done

if [ "$need_install" -eq 1 ]; then
  warn "有依赖缺失，尝试安装（改用清华源 + 不走代理）"
  if ask "现在安装缺失依赖？（会要 sudo 密码）"; then
    sudo rm -f /etc/apt/apt.conf.d/95proxy 2>/dev/null
    sudo env no_proxy="$no_proxy" NO_PROXY="$no_proxy" https_proxy= http_proxy= \
      apt-get update -qq
    sudo env no_proxy="$no_proxy" NO_PROXY="$no_proxy" https_proxy= http_proxy= \
      apt-get install -y --fix-missing \
      build-essential git gcc-arm-none-eabi binutils-arm-none-eabi \
      libnewlib-arm-none-eabi gdb-multiarch pkg-config libpng-dev \
      python3 python3-pip python3-numpy python3-pil && ok "依赖安装完成"
  fi
fi

# ══════════════════════════════════════════
# 5. 子模块（若确实存在）
# ══════════════════════════════════════════
H "5 / 8  子模块"

if [ -f .gitmodules ]; then
  dim ".gitmodules 声明的子模块："
  grep -E '^\s*path' .gitmodules 2>/dev/null | sed 's/^/      /'
  raw "$(grep -E '^\s*path' .gitmodules 2>/dev/null | sed 's/^/      /')"

  uninit="$(git submodule status --recursive 2>/dev/null | grep -c '^-')"
  uninit=${uninit:-0}

  if [ "$uninit" -gt 0 ]; then
    warn "有 $uninit 个子模块未初始化，拉取中（这一步国内网络下容易失败，会重试）…"
    git submodule sync --recursive >/dev/null 2>&1

    # 第一次：完整拉取（不要 --depth 1 —— 构建需要子模块内的数据文件如 data/*.bin）
    if ! git submodule update --init --recursive 2>&1 | tail -20 | sed 's/^/      /'; then
      warn "完整拉取失败，改用逐个子模块拉取…"
      git config -f .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null | awk '{print $2}' | while read -r sp; do
        [ -z "$sp" ] && continue
        dim "拉取 $sp …"
        git submodule update --init --recursive -- "$sp" 2>&1 | tail -8 | sed 's/^/      /'
      done
    fi
  else
    ok "子模块均已初始化"
  fi

  # 校验：逐个检查子模块目录是否真的有内容（git 返回 0 不代表拉到了）
  raw ""
  dim "子模块目录实况校验："
  sub_ok=1
  while read -r sp; do
    [ -z "$sp" ] && continue
    if [ -d "$sp" ]; then
      n=$(find "$sp" -type f -not -path '*/.git/*' 2>/dev/null | head -1 | wc -l)
      if [ "$n" -gt 0 ]; then
        ok "  $sp"
      else
        bad "  $sp 目录为空（拉取未成功）"
        sub_ok=0
      fi
    else
      bad "  $sp 目录不存在"
      sub_ok=0
    fi
  done < <(git config -f .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null | awk '{print $2}')

  if [ "$sub_ok" -eq 0 ]; then
    raw ""
    warn "子模块未拉全，构建必然失败。手动修复："
    raw "      cd $(pwd)"
    raw "      git config --global http.proxy ${https_proxy:-http://127.0.0.1:7897}"
    raw "      git submodule update --init --recursive"
    raw "      # 若子模块用 git:// 协议（代理不生效）："
    raw "      git config --global url.\"https://github.com/\".insteadOf \"git://github.com/\""
    raw "      git submodule sync --recursive && git submodule update --init --recursive"
    raw ""
    if ! ask "仍要继续尝试构建？"; then
      bad "已中止"; exit 1
    fi
  else
    ok "子模块完整"
  fi
else
  dim "无 .gitmodules（本仓库无需子模块）"
fi

# ══════════════════════════════════════════
# 5.5 构建宿主机工具（关键！框架的 Makefile 依赖链未覆盖它）
# ══════════════════════════════════════════
H "6 / 8  宿主机工具（tools/*）"

# 框架的 Makefile 引用了 tools/gbagfx/gbagfx、tools/jsonproc/jsonproc 等可执行文件，
# 但「如何构建它们」的规则没有挂进正常依赖链（只在 codeql-* 测试目标里出现）。
# 缺了它们，make 会退化到内置隐式规则，报出 "can't open tools/gbagfx/gbagfx.s" 这类
# 具有误导性的错误。所以必须在这里显式预构建。
HOST_TOOLS="aif2pcm bin2c gbagfx jsonproc mid2agb preproc scaninc textencode"
tool_missing=0

for t in $HOST_TOOLS; do
  [ -d "tools/$t" ] || continue
  [ -f "tools/$t/Makefile" ] || continue
  exe="tools/$t/$t"
  if [ -x "$exe" ]; then
    ok "$t"
  else
    dim "构建 $t …"
    if make -C "tools/$t" >/dev/null 2>&1 && [ -x "$exe" ]; then
      ok "$t（已构建）"
    else
      bad "$t 构建失败"
      tool_missing=1
    fi
  fi
done

if [ "$tool_missing" -eq 0 ]; then
  ok "宿主机工具齐备"
else
  warn "有工具构建失败，构建大概率会失败。手动排查："
  raw "      cd $(pwd)"
  raw "      for d in tools/*/; do make -C \"\$d\"; done"
fi

# ══════════════════════════════════════════
# 6. 构建
# ══════════════════════════════════════════
H "7 / 8  构建 ROM"

gbas="$(find build -name '*.gba' 2>/dev/null | head -1)"
if [ "${SKIP_BUILD:-0}" = "1" ]; then
  warn "SKIP_BUILD=1，跳过构建"
  rc=0
else
  dim "构建输出同时写入 $LOG_DIR/build-latest.log"
  dim "首次构建约 5~15 分钟，请耐心等待（期间无输出是正常的）"
  raw ""
  set +e
  make -j"$(nproc 2>/dev/null || echo 4)" > >(tee "$LOG_DIR/build-latest.log") 2>&1
  rc=$?
  set -e
  raw ""
  [ "$rc" -eq 0 ] && ok "make 返回 0" || bad "make 返回 $rc"
fi

# ══════════════════════════════════════════
# 7. 结论
# ══════════════════════════════════════════
H "8 / 8  结论"

gbas="$(find build -name '*.gba' 2>/dev/null)"
if [ -n "$gbas" ]; then
  raw ""
  printf "  %s🎮 构建产物：%s\n" "$c_green" "$c_off"
  printf '%s\n' "$gbas" | while read -r f; do
    sz=$(du -h "$f" 2>/dev/null | cut -f1)
    printf "      %s  (%s)\n" "$f" "$sz"
    printf "      %s  (%s)\n" "$f" "$sz" >> "$REPORT"
  done
  raw ""
  ok "构建成功！"
  raw ""
  dim "Windows 侧打开方式（资源管理器地址栏粘贴）："
  dim "  \\\\wsl\$\\Ubuntu\\home\\$(whoami)\\projects\\fireemblem8-expansion\\build\\"
  dim "用 mGBA 打开 .gba 文件即可试玩。"
  raw ""
  raw "下一步：验证 P0 中文字库容量（见工程手册 §5.1 / §8）"
  printf "  %s下一步：验证 P0 中文字库容量%s（见工程手册 §5.1 / §8）\n" "$c_cyan" "$c_off"
  printf "\n报告：%s\n" "$REPORT" >> "$REPORT"
  exit 0
fi

bad "没有生成 .gba 产物"
raw ""
errs="$(grep -nE 'error:|Error [0-9]+|fatal error|undefined reference|No such file|overflowed|cannot find' "$LOG_DIR/build-latest.log" 2>/dev/null | head -25)"
if [ -n "$errs" ]; then
  printf "  %s构建日志中的关键错误：%s\n" "$c_yellow" "$c_off"
  raw "$(printf '%s\n' "$errs" | sed 's/^/      /')"
else
  dim "日志中未匹配到典型错误关键字"
fi
raw ""
if [ "$FIXED" -eq 1 ]; then
  dim "本次修复过工作区缺失文件，若仍失败可能是更深层问题。"
fi
printf "  %s把下面命令的输出发出来即可反馈：%s\n" "$c_yellow" "$c_off"
printf "      cat %s\n" "$REPORT"
exit 1
