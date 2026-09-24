#!/usr/bin/env bash
# ============================================================
# 《山河烬》FE8 改版 —— 构建失败诊断脚本（在 WSL 内运行）
# ------------------------------------------------------------
# 用法：
#   bash ~/6-diagnose-build.sh
#
# 作用：构建报错时，一次性把「子模块 / 工具链 / 依赖 / 日志错误 / 产物」
#       全部体检一遍，直接给出「最可能根因」。
# ============================================================

set +e

c_cyan=$'\033[0;36m'; c_green=$'\033[0;32m'; c_yellow=$'\033[1;33m'; c_red=$'\033[0;31m'; c_off=$'\033[0m'
step() { printf "\n%s=== %s ===%s\n" "$c_cyan" "$1" "$c_off"; }
ok()   { printf "%s[OK] %s%s\n" "$c_green" "$1" "$c_off"; }
warn() { printf "%s[!] %s%s\n" "$c_yellow" "$1" "$c_off"; }
err()  { printf "%s[X] %s%s\n" "$c_red" "$1" "$c_off"; }

FRAMEWORK_DIR="${FRAMEWORK_DIR:-$HOME/projects/fireemblem8-expansion}"
LOG_GLOB="$HOME/shanhe-logs/build-*.log"

printf "${c_cyan}========================================%s\n" "$c_off"
printf "${c_cyan}  《山河烬》构建诊断报告%s\n" "$c_off"
printf "${c_cyan}  时间：%s%s\n" "$(date '+%F %T')" "$c_off"
printf "${c_cyan}========================================%s\n" "$c_off"

# ---------- 1. 框架目录 ----------
step "1. 框架目录"
if [ -d "$FRAMEWORK_DIR/.git" ]; then
  ok "存在：$FRAMEWORK_DIR"
  echo "    分支：$(git -C "$FRAMEWORK_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  echo "    提交：$(git -C "$FRAMEWORK_DIR" log --oneline -1 2>/dev/null)"
else
  err "不存在或不是 git 仓库：$FRAMEWORK_DIR"
  echo "    → 需要先跑 2-setup-project.sh 完成克隆"
  exit 1
fi

# ---------- 2. 子模块完整性（最高频根因）----------
step "2. 子模块完整性"
sub_all="$(git -C "$FRAMEWORK_DIR" submodule status --recursive 2>/dev/null)"
sub_missing="$(echo "$sub_all" | grep -E '^-' || true)"
sub_count="$(echo "$sub_all" | grep -c . || true)"

if [ "$sub_count" -eq 0 ]; then
  warn "没有检测到任何子模块（若框架本无子模块则正常）"
elif [ -n "$sub_missing" ]; then
  err "有 $(( $(echo "$sub_missing" | grep -c .) )) 个子模块未初始化（'-' 前缀）："
  echo "$sub_missing" | sed 's/^/    /'
  echo ""
  echo "    → 这就是构建失败的最可能根因。修复："
  echo "        git config --global http.proxy http://127.0.0.1:7897"
  echo "        git -C \"$FRAMEWORK_DIR\" submodule update --init --recursive --depth 1"
else
  ok "全部 $sub_count 个子模块已初始化"
fi

# ---------- 3. 关键工具源码是否在盘 ----------
step "3. 关键构建工具源码"
for f in tools/gbagfx/gbagfx.s tools/gbagfx/Makefile; do
  if [ -e "$FRAMEWORK_DIR/$f" ]; then
    printf "  %s%-34s 在盘%s\n" "$c_green" "$f" "$c_off"
  else
    printf "  %s%-34s 缺失%s\n" "$c_red" "$f" "$c_off"
  fi
done

# ---------- 4. 工具链 ----------
step "4. ARM 工具链"
for t in arm-none-eabi-gcc arm-none-eabi-as arm-none-eabi-ld arm-none-eabi-objcopy make python3 git; do
  if command -v "$t" >/dev/null 2>&1; then
    printf "  %s%-24s %s%s\n" "$c_green" "$t" "$(command -v "$t")" "$c_off"
  else
    printf "  %s%-24s 缺失%s\n" "$c_red" "$t" "$c_off"
  fi
done
command -v arm-none-eabi-gcc >/dev/null 2>&1 && echo "    版本：$(arm-none-eabi-gcc --version | head -1)"

# ---------- 5. Python 依赖 ----------
step "5. Python 依赖"
for m in numpy PIL; do
  if python3 -c "import $m" >/dev/null 2>&1; then
    ok "python3 -c 'import $m'"
  else
    err "缺少 Python 模块：$m（sudo apt install python3-$([ "$m" = PIL ] && echo pil || echo ${m,,})）"
  fi
done

# ---------- 6. 构建配置 ----------
step "6. 构建配置"
[ -f "$FRAMEWORK_DIR/config.autotools.mk" ] && {
  echo "  config.autotools.mk 存在，关键项："
  grep -iE 'LOCALE|ROM_SIZE|PROFILE|CONFIG' "$FRAMEWORK_DIR/config.autotools.mk" 2>/dev/null | sed 's/^/    /'
} || warn "config.autotools.mk 不存在（尚未 configure 过）"

# ---------- 7. 日志中的真实错误 ----------
step "7. 最近构建日志中的错误"
latest_log="$(ls -t $LOG_GLOB 2>/dev/null | head -1)"
if [ -n "$latest_log" ]; then
  echo "  日志：$latest_log"
  echo ""
  errs="$(grep -nE 'error:|Error [0-9]+|fatal error|undefined reference|No such file|overflowed' "$latest_log" | head -25)"
  if [ -n "$errs" ]; then
    echo "$errs" | sed 's/^/    /'
  else
    ok "日志中未匹配到典型错误关键字"
  fi
else
  warn "未找到构建日志（$LOG_GLOB）"
fi

# ---------- 8. 产物 ----------
step "8. 构建产物"
gbas="$(find "$FRAMEWORK_DIR/build" -name '*.gba' 2>/dev/null)"
if [ -n "$gbas" ]; then
  echo "$gbas" | while read -r f; do ls -lh "$f"; done
  ok "有产物"
else
  warn "没有 .gba 产物"
fi

# ---------- 9. 结论 ----------
step "9. 结论"
if [ -n "$sub_missing" ]; then
  err "最可能根因：子模块未初始化 → 先跑第 2 步给的修复命令"
elif [ ! -e "$FRAMEWORK_DIR/tools/gbagfx/gbagfx.s" ]; then
  err "最可能根因：tools/gbagfx 源码缺失（子模块问题）"
elif [ -n "$errs" ]; then
  warn "请看第 7 步的错误行，据此定位"
else
  ok "未发现明显问题；若仍失败，把本报告全文发出来"
fi

echo ""
echo "诊断完成。把上面完整输出发出来即可。"
