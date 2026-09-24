#!/usr/bin/env bash
# ============================================================
# 《山河烬》一键排错 + 自动修复（在 WSL/Ubuntu 内运行）
# ------------------------------------------------------------
# 用法（只需一行）：
#   curl -fsSL https://raw.githubusercontent.com/zhaoxiancong/Fire-Emblem-Realm-in-Ashes/main/tools/wsl/7-fix-and-build.sh -o ~/7-fix.sh 2>/dev/null || cp "/mnt/d/workbuddy/FireEmblem Realm-in-Ashes/tools/wsl/7-fix-and-build.sh" ~/7-fix.sh; bash ~/7-fix.sh
#
# 或者更简单（已在 WSL 内、D 盘可见）：
#   bash "/mnt/d/workbuddy/FireEmblem Realm-in-Ashes/tools/wsl/7-fix-and-build.sh"
#
# 作用：
#   1. 查清 tools/gbagfx 到底是什么（子模块 / 普通目录 / 需生成）
#   2. 能自动修的自动修
#   3. 修完直接尝试构建，出 ROM
#   4. 全程日志落盘，失败时给出可直接粘贴的反馈块
# ============================================================

set +e
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

c_cyan=$'\033[0;36m'; c_green=$'\033[0;32m'; c_yellow=$'\033[1;33m'; c_red=$'\033[0;31m'; c_off=$'\033[0m'
step() { printf "\n%s========== %s ==========%s\n" "$c_cyan" "$1" "$c_off"; }
ok()   { printf "%s  [OK] %s%s\n" "$c_green" "$1" "$c_off"; }
warn() { printf "%s  [!]  %s%s\n" "$c_yellow" "$1" "$c_off"; }
err()  { printf "%s  [X]  %s%s\n" "$c_red" "$1" "$c_off"; }
info() { printf "       %s\n" "$1"; }

FRAMEWORK_DIR="${FRAMEWORK_DIR:-$HOME/projects/fireemblem8-expansion}"
FRAMEWORK_REPO_DEFAULT="https://github.com/laqieer/fireemblem8-expansion.git"
LOG_DIR="$HOME/shanhe-logs"
mkdir -p "$LOG_DIR"
REPORT="$LOG_DIR/fix-$(date +%Y%m%d-%H%M%S).log"
BUILD_LOG="$LOG_DIR/build-auto-$(date +%Y%m%d-%H%M%S).log"

# 全程双写：屏幕 + 报告文件
exec > >(tee -a "$REPORT") 2>&1

printf "%s========================================================%s\n" "$c_cyan" "$c_off"
printf "%s  《山河烬》一键排错 + 自动构建%s\n" "$c_cyan" "$c_off"
printf "%s  时间：%s%s\n" "$c_cyan" "$(date '+%F %T')" "$c_off"
printf "%s  报告：%s%s\n" "$c_cyan" "$REPORT" "$c_off"
printf "%s========================================================%s\n" "$c_cyan" "$c_off"

# ---------- 0. 前置 ----------
step "0. 前置检查"
if [ ! -d "$FRAMEWORK_DIR/.git" ]; then
  err "找不到框架仓库：$FRAMEWORK_DIR"
  info "先跑 2-setup-project.sh 完成克隆"
  exit 1
fi
cd "$FRAMEWORK_DIR" || exit 1
ok "框架目录：$(pwd)"
info "分支：$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
info "提交：$(git log --oneline -1 2>/dev/null)"

echo ""
info "远程仓库："
git remote -v | sed 's/^/         /'

# ---------- 1. 代理 ----------
step "1. 代理配置"
if [ -n "${https_proxy:-}" ]; then
  ok "已有 https_proxy=$https_proxy"
else
  warn "未检测到代理环境变量，尝试设置"
  export https_proxy="http://127.0.0.1:7897"
  export http_proxy="http://127.0.0.1:7897"
  if curl -sI --max-time 8 -x "$https_proxy" https://github.com >/dev/null 2>&1; then
    ok "代理可用：$https_proxy"
  else
    err "代理不可用，后续 git 操作可能失败"
  fi
fi
# git 也挂上（子模块/拉取需要）
git config --global http.proxy "${https_proxy:-http://127.0.0.1:7897}" 2>/dev/null
git config --global https.proxy "${https_proxy:-http://127.0.0.1:7897}" 2>/dev/null
ok "已为 git 配置代理"

# ---------- 2. 查清 gbagfx 到底是什么 ----------
step "2. 溯源：tools/gbagfx 从哪来"

GBAGFX_OK=0
[ -e "tools/gbagfx/gbagfx.s" ] && { ok "tools/gbagfx/gbagfx.s 已存在"; GBAGFX_OK=1; }

if [ "$GBAGFX_OK" -eq 0 ]; then
  # 2.1 是否子模块
  if [ -f .gitmodules ]; then
    info ".gitmodules 存在，内容："
    sed 's/^/         /' .gitmodules
    if grep -q 'gbagfx' .gitmodules; then
      warn "→ gbagfx 是子模块，执行拉取"
      git submodule sync --recursive >/dev/null 2>&1
      git submodule update --init --recursive --depth 1 || \
        git submodule update --init --recursive
    else
      info "→ gbagfx 不在 .gitmodules 中"
    fi
  else
    info "→ 没有 .gitmodules，不是子模块"
  fi

  # 2.2 上游是否跟踪该路径
  tracked="$(git ls-tree -r HEAD --name-only 2>/dev/null | grep -i gbagfx | head -20)"
  if [ -n "$tracked" ]; then
    warn "→ 上游仓库跟踪了这些路径，但本地缺失（工作区不完整）："
    echo "$tracked" | sed 's/^/         /'
    echo ""
    info "尝试从 git 恢复被删的跟踪文件..."
    git checkout -- . 2>/dev/null && ok "已执行 git checkout -- ."
    git status --short | head -10 | sed 's/^/         /'
  else
    warn "→ 上游 HEAD 未跟踪任何 gbagfx 路径"
  fi

  # 2.3 tools/ 实况
  echo ""
  info "tools/ 目录当前内容："
  if [ -d tools ]; then
    ls -la tools/ | head -25 | sed 's/^/         /'
  else
    info "（tools/ 目录不存在）"
  fi

  # 2.4 辅助工具构建脚本
  echo ""
  info "辅助工具构建脚本候选："
  bt_found=""
  for s in build_tools.sh scripts/build_tools.sh make_tools.sh tools/build.sh; do
    if [ -e "$s" ]; then
      info "找到：$s"
      bt_found="$s"
    fi
  done
  [ -z "$bt_found" ] && info "（未找到）"

  # 2.5 Makefile 里的引用规则
  echo ""
  info "Makefile 中 gbagfx 相关行："
  grep -n "gbagfx" Makefile 2>/dev/null | head -15 | sed 's/^/         /' || info "（无）"

  # 2.6 顶层文件清单（帮判断仓库类型）
  echo ""
  info "仓库顶层文件（前 30）："
  ls -a | head -30 | sed 's/^/         /'
fi

# ---------- 3. 尝试构建辅助工具 ----------
step "3. 构建辅助工具"
if [ -e "tools/gbagfx/gbagfx.s" ] && [ "$GBAGFX_OK" -eq 1 ]; then
  ok "gbagfx.s 本来就存在，跳过"
elif [ -n "${bt_found:-}" ]; then
  info "执行 bash $bt_found ..."
  bash "$bt_found" 2>&1 | tail -30 | sed 's/^/         /'
  [ -e "tools/gbagfx/gbagfx.s" ] && ok "gbagfx.s 已生成" || warn "仍未生成 gbagfx.s"
else
  # 没有专门的脚本时，试试 make 里的目标
  for tgt in build_tools tools gbagfx; do
    if make -n "$tgt" >/dev/null 2>&1; then
      info "尝试 make $tgt ..."
      make "$tgt" 2>&1 | tail -20 | sed 's/^/         /'
      break
    fi
  done
  [ -e "tools/gbagfx/gbagfx.s" ] && ok "gbagfx.s 已就位" || warn "gbagfx.s 仍缺失"
fi

# ---------- 4. 兜底：从上游单独拉 tools ----------
step "4. 兜底检查"
if [ ! -e "tools/gbagfx/gbagfx.s" ]; then
  warn "gbagfx.s 仍缺失，检查是否 worktree 被污染"
  info "git status（前 15 行）："
  git status --short | head -15 | sed 's/^/         /'
  echo ""
  info "建议：若是全新环境，最稳妥是删除重克隆（下面给出命令，本脚本不自动执行）："
  info "  rm -rf ~/projects/fireemblem8-expansion"
  info "  git clone https://github.com/laqieer/fireemblem8-expansion.git ~/projects/fireemblem8-expansion"
  echo ""
  read -r -p "  是否现在自动重克隆？会丢弃本地改动 (y/N) " do_reclone
  if [ "$do_reclone" = "y" ] || [ "$do_reclone" = "Y" ]; then
    cd "$HOME/projects" || exit 1
    rm -rf "$FRAMEWORK_DIR"
    git clone "$FRAMEWORK_REPO_DEFAULT" "$FRAMEWORK_DIR"
    cd "$FRAMEWORK_DIR" || exit 1
    git submodule update --init --recursive --depth 1
    ok "重克隆完成"
  fi
fi

# ---------- 5. 构建 ----------
step "5. 构建中文版 ROM"
if [ -e "tools/gbagfx/gbagfx.s" ]; then
  ok "辅助工具就绪，开始构建"
  info "构建日志：$BUILD_LOG"
  echo ""
  set +e
  make -j"$(nproc)" > >(tee -a "$BUILD_LOG") 2>&1
  rc=$?
  set -e
  echo ""
  if [ "$rc" -eq 0 ]; then
    ok "make 返回 0"
  else
    err "make 返回 $rc"
  fi
else
  err "辅助工具仍缺失，跳过构建"
  rc=1
fi

# ---------- 6. 产物 ----------
step "6. 构建产物"
gbas="$(find build -name '*.gba' 2>/dev/null)"
if [ -n "$gbas" ]; then
  echo "$gbas" | while read -r f; do ls -lh "$f" | sed 's/^/       /'; done
  ok "找到 ROM"
else
  warn "没有 .gba 产物"
fi

# ---------- 7. 错误摘要 ----------
step "7. 错误摘要"
errs="$(grep -nE 'error:|Error [0-9]+|fatal error|undefined reference|No such file|overflowed' "$BUILD_LOG" 2>/dev/null | head -30)"
if [ -n "$errs" ]; then
  echo "$errs" | sed 's/^/       /'
else
  ok "日志中未匹配到典型错误关键字"
fi

# ---------- 8. 结论 ----------
step "8. 结论"
if [ -n "$gbas" ] && [ "$rc" -eq 0 ]; then
  ok "构建成功！ROM 已生成"
  echo ""
  info "Windows 侧访问："
  info "  \\\\wsl\$\\Ubuntu\\home\\$(whoami)\\projects\\fireemblem8-expansion\\build\\"
  echo ""
  ok "下一步：用 mGBA 打开 ROM，验证 P0 中文字库容量"
elif [ -e "tools/gbagfx/gbagfx.s" ] && [ "$rc" -ne 0 ]; then
  warn "辅助工具已就绪，但 make 仍失败 → 请看第 7 段错误摘要"
else
  err "gbagfx 未能解决 → 请把本报告全文反馈"
fi

echo ""
echo "========================================================"
echo "  完整报告已保存："
echo "    $REPORT"
echo ""
echo "  直接把下面这行命令的输出发出来即可："
echo "    cat $REPORT"
echo "========================================================"
