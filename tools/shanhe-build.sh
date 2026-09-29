#!/usr/bin/env bash
# ============================================================
# 《山河烬》方案 B —— 内容同步 + 构建（六步）
# ------------------------------------------------------------
# 本仓库（内容）→ 框架（只读依赖）→ 可玩 ROM
#
# 用法（在本仓库根目录跑）：
#   bash tools/shanhe-build.sh                 # 完整：预检→校验→快照→铺设→构建→验产物→导出→反查
#   DRY_RUN=1 bash tools/shanhe-build.sh       # 预演：只打印将要做什么，不落盘、不构建
#   STATUS=1  bash tools/shanhe-build.sh       # 查看框架侧当前被改了什么（只读）
#   RESTORE=1 bash tools/shanhe-build.sh       # 一键还原框架到 framework.lock 的上游状态
#   SKIP_BUILD=1 bash tools/shanhe-build.sh    # 只铺设不构建（调试合并逻辑用）
#   PRUNE_ONLY=1 bash tools/shanhe-build.sh    # 只跑日志清理（见下方「日志保留策略」），不构建
#   ASSUME_YES=1 bash tools/shanhe-build.sh    # ★ 非交互运行（AI/CI/管道）**必须**加
#                                              #   否则遇到「框架不干净，继续？」这类
#                                              #   确认会**永久挂起**（stdin 非 TTY 时
#                                              #   `read` 不返回 EOF，实测白等 16 分钟）
#
# 环境变量可覆盖：
#   FRAMEWORK_DIR=/path   框架位置（默认 $HOME/projects/fireemblem8-expansion）
#   CONTENT_DIR=/path     内容位置（默认本仓库的 content/）
#   SHANHE_ROM_DIR=/path  导出目录（默认 <仓库>/shanhe-rom，见第 5b 步）
#   CLASH_PORT=7897       代理端口
#   BUILD_TIMEOUT=1800    第 4 步 make 的硬超时秒数（默认 30 分钟；超时即中止，防无限悬挂）
#   SHANHE_LOG_KEEP_BUILD=5   日志保留：build-*.log 份数（每次 3~5 MB，唯一的大件）
#   SHANHE_LOG_KEEP_SMALL=20  日志保留：sync-/prewrite-/validate-/content-table- 各份数（KB 级）
#
# 山河烬自有章节表的登记（3a'' 步；详见 tools/shanhe-content-tables.sh 头注释）
#   B3_NEW_DATA="shanhe_units.json"                         # content/data 里的**框架侧不存在**的新表
#   B3_INSTANCES="units:shanhe_units.json:src/shanhe_udefs.c"  # <表>:<JSON>:<框架内相对路径>
#   CONTENT_TABLES=0                                        # 跳过整段
#
# 规范：docs/6.方案B内容外置规划.md §3
# 依赖声明：framework.lock
# ============================================================

set +e
export LANG=C.UTF-8 LC_ALL=C.UTF-8

# ── 位置参数防呆（2026-09-29 加）──
# 本脚本的开关**全部是环境变量**。若写成位置参数（`bash tools/shanhe-build.sh RESTORE=1`）
# 会被**静默忽略** —— 脚本照常跑完整构建："以为在还原/清理，其实在构建"。
# 这个坑已踩过两次（`PRUNE_ONLY=1`、`RESTORE=1`），故在此硬拦，给出正确写法。
for _arg in "$@"; do
  case "$_arg" in
    [A-Za-z_]*=*)
      printf '\n  \033[0;31m✗\033[0m 位置参数 "%s" 不会被识别 —— 本脚本的开关都是**环境变量**。\n' "$_arg" >&2
      printf '    正确写法： \033[0;36m%s bash %s\033[0m\n\n' "$_arg" "$0" >&2
      exit 2 ;;
  esac
done
unset _arg

# ─────────────────────────── 配置 ───────────────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK_FILE="$REPO_ROOT/framework.lock"
CONTENT_DIR="${CONTENT_DIR:-$REPO_ROOT/content}"
FRAMEWORK_DIR="${FRAMEWORK_DIR:-$HOME/projects/fireemblem8-expansion}"
CLASH_PORT="${CLASH_PORT:-7897}"
LOG_DIR="$HOME/shanhe-logs"
mkdir -p "$LOG_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$LOG_DIR/sync-$STAMP.log"
PREWRITE_SNAPSHOT="$LOG_DIR/prewrite-$STAMP.sha1"

DRY_RUN="${DRY_RUN:-0}"
STATUS="${STATUS:-0}"
RESTORE="${RESTORE:-0}"
SKIP_BUILD="${SKIP_BUILD:-0}"

c_cyan=$'\033[0;36m'; c_green=$'\033[0;32m'; c_yellow=$'\033[1;33m'
c_red=$'\033[0;31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'

_plain() { sed -e 's/\x1b\[[0-9;]*m//g'; }
H()    { printf "\n%s━━━━━━ %s ━━━━━━%s\n" "$c_cyan" "$1" "$c_off"
         printf "\n===== %s =====\n" "$1" >> "$REPORT"; }
ok()   { printf "  %s✓%s %s\n" "$c_green" "$c_off" "$1";  printf "  [OK] %s\n" "$1" >> "$REPORT"; }
bad()  { printf "  %s✗%s %s\n" "$c_red" "$c_off" "$1";    printf "  [X]  %s\n" "$1" >> "$REPORT"; }
warn() { printf "  %s!%s %s\n" "$c_yellow" "$c_off" "$1"; printf "  [!]  %s\n" "$1" >> "$REPORT"; }
dim()  { printf "  %s%s%s\n" "$c_dim" "$1" "$c_off";      printf "       %s\n" "$1" >> "$REPORT"; }
act()  { printf "  %s→%s %s\n" "$c_cyan" "$c_off" "$1";   printf "  [>]  %s\n" "$1" >> "$REPORT"; }

# ── 临时文件登记制（2026-09-29 加）──
#   缺陷现场：第 2 步的 TARGETS_FILE 与第 6 步的 PATCH_TARGETS_FILE 用 `mktemp`
#   建于 /tmp 却**从不回收**，脚本正常跑完在 /tmp 留下两个 605 B 的 tmp.XXXXXX
#   残留（与「调试产物当轮清掉」的纪律相违）。同段的 CUR / BOOT_JSON / FONT_TMP
#   都有显式 rm，唯独这两处漏了。
#   两处都属"用完即弃"，正确做法就是最后一次使用后 rm；但 `die` 可能落在
#   创建与回收**之间**（如 5b 步 ROM SHA1 不符），那样照样漏。故同时把回收
#   挂到 die() 上 —— 显式 rm + die 兜底 两层都在，才算真的不漏。
#   为什么用"登记制"而不是全局 trap：脚本第 4 步的心跳**已经**在用自己的
#   `trap ... EXIT`（装于 :1394、撤于 :1482）。全局 trap 会被它覆盖或清除，
#   靠不住；登记制不依赖 trap 语义。
#   ⚠️ 新增 mktemp 一律照两行式登记（见下）；仍用裸 mktemp 的（如 write_if_changed）
#      必须在**所有**返回路径上自行 rm（那是它已经在做的事）。
SHANHE_TMP_PATHS=()
# 登记一个**已由父 shell 创建**的临时路径，供 cleanup_tmp / die 兜底回收。
# 为什么不做成 `VAR="$(mktemp_tracked)"` 这种一步封装：命令替换 `$( )` 在**子 shell**
# 里执行，函数内的数组追加**不会传回父 shell**（实测会静默失效 —— 数组看着有元素，
# 父 shell 里永远是空）。所以登记必须发生在**父 shell 的语句**里，统一写成两行：
#     VAR="$(mktemp)"; tmp_track "$VAR"
tmp_track() { [ -n "$1" ] && SHANHE_TMP_PATHS+=("$1"); return 0; }
cleanup_tmp() {
  local f
  for f in "${SHANHE_TMP_PATHS[@]}"; do
    [ -n "$f" ] && rm -rf "$f" 2>/dev/null
  done
  SHANHE_TMP_PATHS=()
}

die() { bad "$1"; cleanup_tmp; printf "\n  日志：%s\n" "$REPORT"; exit 1; }

# ── 非交互保护（2026-09-29 实测新增）──
#   缺陷现场：框架工作区「不干净」时会弹「继续？(y/N)」，而 `read -r` 在
#   **stdin 不是 TTY** 时不会返回 EOF 就退出，而是永久阻塞 —— 表现为
#   「脚本活着但没有任何子进程」，白等 16 分钟才被发现（wchan=anon_pipe_read）。
#   这也解释了为什么在 AI/CI/管道里驱动它必须显式给输入。
#   对策三步：① 加 ASSUME_YES=1 开关自动确认；
#            ② stdin 非 TTY 且未开开关 → **立刻 exit 2**，绝不静默等待；
#            ③ 交互时保持原样（默认 N，回车即安全中止）。
ASSUME_YES="${ASSUME_YES:-0}"
ask_confirm() {  # $1 = 提示语（不含 "(y/N)"）
  if [ "$ASSUME_YES" = "1" ]; then
    printf "\n  %s→ %s (y/N) %s\n" "$c_yellow" "$1" "$c_off"
    printf "    %s[ASSUME_YES=1] 自动确认 y%s\n" "$c_dim" "$c_off"
    printf "  [>] LIVE 确认：%s → ASSUME_YES=1 自动 y\n" "$1" >> "$REPORT"
    return 0
  fi
  if [ ! -t 0 ]; then
    printf "\n  %s✗%s 需要交互确认，但 stdin 不是 TTY —— 拒绝静默等待。\n" "$c_red" "$c_off" >&2
    printf "    待确认：%s\n" "$1" >&2
    printf "    非交互运行请显式加： %sASSUME_YES=1 bash tools/shanhe-build.sh%s\n\n" "$c_cyan" "$c_off" >&2
    printf "  [X] 非交互且需确认（%s）→ exit 2\n" "$1" >> "$REPORT"
    exit 2
  fi
  printf "\n  %s→ %s (y/N) %s" "$c_yellow" "$1" "$c_off"
  read -r ans
  case "$ans" in y|Y) return 0 ;; *) return 1 ;; esac
}

# ── 日志保留策略（防止 $LOG_DIR 无限膨胀，2026-09-28 新增）──
#   实测：build-*.log 每次构建 3~5 MB，是这里唯一的大件（17 份 = 45 MB）；
#   sync-/prewrite-/validate- 都是 KB 级。所以按前缀分别设保留份数。
#   安全边界：只匹配本脚本自己写出的 5 个前缀 + 只扫 $LOG_DIR 一层，
#   目录下其它文件一律不动；本轮正在写的 $REPORT 也显式跳过。
SHANHE_LOG_KEEP_BUILD="${SHANHE_LOG_KEEP_BUILD:-5}"
SHANHE_LOG_KEEP_SMALL="${SHANHE_LOG_KEEP_SMALL:-20}"

prune_logs() {
  local keep="$1" pat="$2" total removed=0 f
  total=$(ls -1 "$LOG_DIR/$pat"* 2>/dev/null | wc -l)
  [ "$total" -le "$keep" ] && return 0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    [ "$f" = "$REPORT" ] && continue          # 绝不删本轮正在写的报告
    [ "$f" = "$PREWRITE_SNAPSHOT" ] && continue
    rm -f -- "$f" || return 1
    removed=$((removed + 1))
  done < <(ls -1t "$LOG_DIR/$pat"* 2>/dev/null | tail -n +$((keep + 1)))
  printf "  %s日志清理：%s* 保留最近 %s 份（删除 %d 份）%s\n" \
         "$c_dim" "$pat" "$keep" "$removed" "$c_off"
}

# ─────────────────────────── 头 ───────────────────────────
printf "%s╔══════════════════════════════════════════════════════╗%s\n" "$c_cyan" "$c_off"
printf "%s║   《山河烬》方案 B · 内容同步 + 构建                  ║%s\n" "$c_cyan" "$c_off"
printf "%s╚══════════════════════════════════════════════════════╝%s\n" "$c_cyan" "$c_off"
printf "  时间：%s\n" "$(date '+%F %T')"
printf "  本仓库：%s\n" "$REPO_ROOT"
printf "  内容：  %s\n" "$CONTENT_DIR"
printf "  框架：  %s\n" "$FRAMEWORK_DIR"
printf "  日志：  %s\n" "$REPORT"
if [ "$DRY_RUN" = "1" ]; then printf "  %s模式：DRY_RUN（预演，不落盘不构建）%s\n" "$c_yellow" "$c_off"; fi
if [ "$STATUS"  = "1" ]; then printf "  %s模式：STATUS（只读）%s\n" "$c_yellow" "$c_off"; fi
if [ "$RESTORE" = "1" ]; then printf "  %s模式：RESTORE（一键还原框架）%s\n" "$c_yellow" "$c_off"; fi

# 日志保留（放在任何 dim()/H() 之前：此时 $REPORT 尚不存在，prune 不可能碰到它）
prune_logs "$SHANHE_LOG_KEEP_BUILD" "build-"
prune_logs "$SHANHE_LOG_KEEP_SMALL" "sync-"
prune_logs "$SHANHE_LOG_KEEP_SMALL" "prewrite-"
prune_logs "$SHANHE_LOG_KEEP_SMALL" "validate-"
prune_logs "$SHANHE_LOG_KEEP_SMALL" "content-table-"

if [ "${PRUNE_ONLY:-0}" = "1" ]; then
  printf "  日志目录：%s\n" "$LOG_DIR"
  printf "  清理后：%s 个文件 / %s\n" "$(ls -1 "$LOG_DIR" | wc -l)" "$(du -sh "$LOG_DIR" 2>/dev/null | cut -f1)"
  exit 0
fi

# ─────────────────────────── 工具 ───────────────────────────
# 从 framework.lock 读一个键：lock_get <section> <key>
lock_get() {
  awk -v sec="$1" -v key="$2" '
    /^\[/ { cur = $0; gsub(/[][]/, "", cur) }
    cur == sec && $0 ~ "^[ \t]*" key "[ \t]*=" {
      sub(/^[^=]*=[ \t]*/, ""); sub(/[ \t]+$/, ""); print; exit
    }
  ' "$LOCK_FILE"
}

# ── 内容感知写入（幂等写入，2026-09-27 新增） ──
# 用法：write_if_changed <目标文件>   （新内容从 stdin 读）
#   返回 0 = 本次真的写了（内容变了）   返回 1 = 内容一致，未写
#
# 为什么必须有它：铺设步骤若"无论内容变没变都重写一遍"，会把框架侧被覆盖文件的
# mtime 全部刷新 —— 制造大量**无意义的写入事件**（下游噪音、diff 幻影）。
# 所以凡是由脚本写入框架的生成物，一律先比内容；一致就**不落盘**，让 mtime 保持不动。
#
# ⚠️ 这**不足以**换来"增量构建"。框架侧 5 组生成物挂在 phony `FORCE_*` 目标上，
# GNU Make 认的是"该先决条件本轮被重新生成过"这一**事件**，而不是时间戳比较 ——
# 故 492 个 .c 每轮仍全量重编（2026-09-27 实测，真因见 docs/5 §9.0 第 10 条）。
# write_if_changed 的价值在**幂等**与"不制造无谓写入"，不在加速编译。
# 用 mv 而非 cp：同目录内 mv 是原子的，且天然赋予"内容已变"的新 mtime。
write_if_changed() {
  local dst="$1" tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/shanhe-wic-XXXXXX")" || return 0
  cat > "$tmp"
  if [ -f "$dst" ] && cmp -s "$tmp" "$dst"; then
    rm -f "$tmp"; return 1
  fi
  mkdir -p "$(dirname "$dst")" 2>/dev/null
  if mv -f "$tmp" "$dst" 2>/dev/null; then return 0; fi
  # 跨文件系统（/tmp → /mnt/d 等）时 mv 会退化为 copy+unlink，仍然可行；
  # 真失败则兜底 cp：
  if cp -f "$tmp" "$dst" 2>/dev/null; then rm -f "$tmp"; return 0; fi
  rm -f "$tmp"; return 2
}

FRAMEWORK_REPO="$(lock_get framework repo)"
FRAMEWORK_COMMIT="$(lock_get framework commit)"
FRAMEWORK_BRANCH="$(lock_get framework branch)"
FRAMEWORK_SUBJECT="$(lock_get framework commit_subject)"
MG_COMMIT="$(lock_get submodule.mgfembp commit)"
MG_PROBE="$(lock_get submodule.mgfembp probe_file)"
MAKE_TARGET="$(lock_get build make_target)"
ROM_REL="$(lock_get build rom_path)"
ROM_BYTES="$(lock_get build rom_size_bytes)"
TITLE_EXPECT="$(lock_get build rom_header_game_title)"
CODE_EXPECT="$(lock_get build rom_header_game_code)"

# ── [features]：构建开关（单一事实来源 = framework.lock） ──
# 铁律之六：能从单一来源派生的必须派生。这些值**只在这里读一次**，
# 再统一拼成 make 变量；不在构建命令里硬编码。
FEAT_ITEM_CAP="$(lock_get features item_id_cap)"
FEAT_MECH_HOOKS="$(lock_get features mechanics_hooks)"
# 自定义法术特效（框架 issue #77/#78）—— M3④ 惊雷引「雷光链」。1 = 启用。
# ⚠️ 会改变现代构建的**配置指纹**，并把 assets 的 profile 目录由 …-custom0-… 变为
#    …-custom1-…（首次切换触发生成全部资产 + 一次全量重编，正常）。
FEAT_SPELL="$(lock_get features custom_spell_effects)"

# ── [locales] + [build].rom_size_label：本地化 + ROM 尺寸（同一单一事实来源） ──
# ⚠️ 2026-09-27 换机实测教训（真凶，非 config.autotools.mk）：
#   本机框架是**全新浅克隆**，不存在旧机遗留的 config.autotools.mk（那是 `./configure`
#   的产物，git 里没有，clone 更不会带来）。而旧文档把「切中文」指向
#   `./configure --with-enabled-locales=... --with-rom-size=32M`。
#   只传 FE8_ITEM_ID_CAP / EXPANSION_MECHANICS_HOOKS 时，make 落回 config.mk 默认
#   `EXPANSION_ENABLED_LOCALES ?= en`（config.mk:87）、`MODERN_ROM_SIZE ?= 16M`
#   ⇒ 静默产出 **16M 英文 ROM**，直到第 5 步 ② 尺寸断言才炸（16777216 vs 33554432）。
#   修法（铁律之六「能派生的必须派生」）：locale 与尺寸这两组值**同样从
#   framework.lock 派生**，作为 make 命令行变量下发 —— 不依赖任何机器本地生成物，
#   也不再需要跑 ./configure。这同时让「lock 是唯一依赖声明」在本脚本内自洽。
LOCALES_ENABLED="$(lock_get locales enabled)"
LOCALE_DEFAULT="$(lock_get locales default)"
ROM_SIZE_LABEL="$(lock_get build rom_size_label)"

# 拼装 make 命令行变量（空值 = 不传，用框架默认）
MAKE_VARS=""
[ -n "$FEAT_ITEM_CAP" ] && MAKE_VARS="$MAKE_VARS FE8_ITEM_ID_CAP=$FEAT_ITEM_CAP"
[ -n "$FEAT_MECH_HOOKS" ] && MAKE_VARS="$MAKE_VARS EXPANSION_MECHANICS_HOOKS=$FEAT_MECH_HOOKS"
[ -n "$FEAT_SPELL" ] && MAKE_VARS="$MAKE_VARS EXPANSION_CUSTOM_SPELL_EFFECTS=$FEAT_SPELL"
[ -n "$ROM_SIZE_LABEL" ] && MAKE_VARS="$MAKE_VARS MODERN_ROM_SIZE=$ROM_SIZE_LABEL"
[ -n "$LOCALES_ENABLED" ] && MAKE_VARS="$MAKE_VARS EXPANSION_ENABLED_LOCALES=$LOCALES_ENABLED"
[ -n "$LOCALE_DEFAULT" ] && MAKE_VARS="$MAKE_VARS EXPANSION_DEFAULT_LOCALE=$LOCALE_DEFAULT"
MAKE_VARS="${MAKE_VARS# }"

# ⚠️ 同时 export：generated_data 的 Python 工具链（validate/generate/idspace）
#    也从**环境变量**读同一批配置。不 export 会导致：
#      · 3a' 的 validate 以默认 cap 0xCD 判定 ⇒ overlay 道具被判「超 cap」⇒ 中止
#      · generate 产出与 make 不一致的表
#    export 后，shell 子进程与 make 看到的是同一组值（单一事实来源）。
if [ -n "$FEAT_ITEM_CAP" ]; then
  export FE8_ITEM_ID_CAP="$FEAT_ITEM_CAP"
fi
if [ -n "$FEAT_MECH_HOOKS" ]; then
  export EXPANSION_MECHANICS_HOOKS="$FEAT_MECH_HOOKS"
fi
# 法术特效开关同样 export：scripts/assets 的 CLI 从环境变量读同一值
# （assets.mk 的 ASSET_PROFILE_KEY 用它拼 profile 目录名；不 export 会让
#  make 侧按 custom1 生成、而某些 python 侧动作按默认 custom0 判定）。
if [ -n "$FEAT_SPELL" ]; then
  export EXPANSION_CUSTOM_SPELL_EFFECTS="$FEAT_SPELL"
fi
# locale / ROM 尺寸同样 export：scripts/modernize/expansion_config.py 的
# validate_locale_rom_size() 会读环境变量做「真实 locale 必须 32M」的硬校验。
# 不 export 的后果：make 侧按 zh-Hans+32M 编译，而某些 python 侧动作仍按
# en+16M 判定 ⇒ 两边看到不同的配置身份，报错或产出不一致的表。
[ -n "$ROM_SIZE_LABEL" ] && export MODERN_ROM_SIZE="$ROM_SIZE_LABEL"
[ -n "$LOCALES_ENABLED" ] && export EXPANSION_ENABLED_LOCALES="$LOCALES_ENABLED"
[ -n "$LOCALE_DEFAULT" ] && export EXPANSION_DEFAULT_LOCALE="$LOCALE_DEFAULT"

# ── 派生气味自检 ①：locale 与 ROM 尺寸的硬约束（框架侧同样会硬失败，这里提前一步） ──
# 依据：scripts/modernize/expansion_config.py:validate_locale_rom_size()
#   任何**真实**非英语 locale（zh-Hans 属之）都要求 ROM = 32M。
# 提前拦下的价值：报错发生在第 1 步而不是编译 10 分钟后。
REAL_LOCALE_HIT=0
case ",$LOCALES_ENABLED," in
  *,zh-Hans,*|*,ja,*|*,fr,*|*,de,*|*,es,*|*,it,*) REAL_LOCALE_HIT=1 ;;
esac
if [ "$REAL_LOCALE_HIT" = "1" ] && [ "$ROM_BYTES" != "33554432" ]; then
  die "locales.enabled='$LOCALES_ENABLED' 含真实本地化语言，但 build.rom_size_label='$ROM_SIZE_LABEL'（$ROM_BYTES 字节）。框架要求二者同为 32M —— 请改 framework.lock。"
fi

# ── 派生气味自检 ②：lock 的 modern_config/modern_abi 与 `all` 目标的实际行为是否一致 ──
# Makefile 的 `all:` 目标是**硬编码** `$(MAKE) expansion-modern-boot-check
# MODERN_CONFIG=release MODERN_ABI=aapcs`（Makefile:262-277）——配方里显式赋值的
# 命令行变量会**覆盖**外层经 MAKEFLAGS 传下去的值，所以把 M_CFG/M_ABI 塞进
# MAKE_VARS 是自欺欺人（会被静默忽略）。正确做法是**断言**二者一致：
# 不一致就早告警，而不是等拿到错的车道产物。
M_CFG="$(lock_get build modern_config)"
M_ABI="$(lock_get build modern_abi)"
ALL_LINE="$(grep -m1 'expansion-modern-boot-check MODERN_CONFIG=' "$FRAMEWORK_DIR/Makefile" 2>/dev/null)"
if [ -n "$ALL_LINE" ]; then
  case "$ALL_LINE" in
    *"MODERN_CONFIG=$M_CFG MODERN_ABI=$M_ABI"*) : ;;
    *) warn "派生气味：framework.lock 的 modern_config/abi = $M_CFG/$M_ABI，"
       warn "       但 Makefile 的 \`all\` 目标硬编码为另一组 —— lock 该段已失真，请同步。" ;;
  esac
fi

FRAMEWORK_ROM="$FRAMEWORK_DIR/$ROM_REL"

# 框架是否就绪
framework_ready() { [ -d "$FRAMEWORK_DIR/.git" ]; }

# ─────────────────────────── RESTORE 模式 ───────────────────────────
if [ "$RESTORE" = "1" ]; then
  H "RESTORE · 一键还原框架"
  framework_ready || die "框架目录不存在：$FRAMEWORK_DIR"

  DIRTY="$(git -C "$FRAMEWORK_DIR" status --porcelain)"
  if [ -z "$DIRTY" ]; then
    ok "框架工作区本来就是干净的，无需还原"
    printf "\n  日志：%s\n" "$REPORT"; exit 0
  fi

  warn "以下文件将被还原到 framework.lock 的上游状态（丢弃本地改动）："
  printf '%s\n' "$DIRTY" | sed 's/^/      /' | tee -a "$REPORT"
  printf "\n"
  if ! ask_confirm "确认还原？（将丢弃框架侧本地改动）"; then
    bad "已取消，未做任何改动"; exit 0
  fi

  # 三级递进还原（对 skip-worktree/assume-unchanged 也有效）
  act "git checkout HEAD -- ."
  git -C "$FRAMEWORK_DIR" checkout HEAD -- . 2>&1 | sed 's/^/      /' | tee -a "$REPORT"
  act "git restore --source=HEAD --staged --worktree ."
  git -C "$FRAMEWORK_DIR" restore --source=HEAD --staged --worktree . 2>&1 | sed 's/^/      /' | tee -a "$REPORT"

  # ★ 2026-09-29 勘误 + 补既有缺口（隔离仓库实测过，别再凭直觉改）：
  #   ① 法术特效包（3d 步 `git add` 的"索引里新增、HEAD 里没有"的文件）**不需要**额外处理 ——
  #      上面那句 `git restore --source=HEAD --staged --worktree .` **本身就会**
  #      把它们从索引与工作区一并删除。
  #      （所以**不要**再写 `git reset -q` / 按包 `rm -rf`：那是冗余，且曾让我误判。）
  #   ② 真正缺的是 `git restore` 管不到的 **untracked** 文件 —— 3b'' 铺的
  #      `texts/msg_overrides.*.json` 与 3c 铺的 `src/shanhe_*.c` 都是 untracked，
  #      于是旧实现永远停在"仍有未还原项"，与 M1 验收第 3 条"逐字节还原"不符。
  #   ⚠️ 只点名这两类**本脚本自己的**产物；绝不 `git clean -fdx` —— build/ 与框架
  #      自身的未追踪文件都在那儿，一刀切会误删。
  act "清理本脚本铺设的未追踪残留（3b''/3c 产物）"
  git -C "$FRAMEWORK_DIR" clean -fdq -- 'src/shanhe_*.c' 'texts/msg_overrides.*.json'
  git -C "$FRAMEWORK_DIR" clean -nd -- 'src/shanhe_*.c' 'texts/msg_overrides.*.json' \
    | sed 's/^/      /' | tee -a "$REPORT"

  LEFT="$(git -C "$FRAMEWORK_DIR" status --porcelain)"
  if [ -z "$LEFT" ]; then
    ok "框架已逐字节还原到上游状态"
    # 与 lock 里记录的 SHA1 对照（强化核验）
    CJ="$FRAMEWORK_DIR/src/data/characters.json"
    EXP="$(lock_get baseline framework_src_data_characters_json_sha1)"
    [ -f "$CJ" ] && GOT="$(sha1sum "$CJ" | cut -d' ' -f1)" || GOT=""
    if [ -n "$EXP" ] && [ "$GOT" = "$EXP" ]; then
      ok "characters.json SHA1 与 lock 记录一致（$GOT）"
    elif [ -n "$EXP" ]; then
      warn "characters.json SHA1 = $GOT，lock 记录 = $EXP（可能上游已前进，请核对）"
    fi
  else
    warn "仍有未还原项："
    printf '%s\n' "$LEFT" | sed 's/^/      /'
    warn "如仍不干净，手动执行：git -C \"$FRAMEWORK_DIR\" update-index --no-skip-worktree --no-assume-unchanged -r ."
  fi
  printf "\n  日志：%s\n" "$REPORT"; exit 0
fi

# ─────────────────────────── STATUS 模式 ───────────────────────────
if [ "$STATUS" = "1" ]; then
  H "STATUS · 框架侧当前改动（只读）"
  framework_ready || die "框架目录不存在：$FRAMEWORK_DIR"

  printf "  框架 commit：%s\n" "$(git -C "$FRAMEWORK_DIR" rev-parse HEAD 2>/dev/null)"
  printf "  lock 约定：  %s\n" "$FRAMEWORK_COMMIT"
  printf "\n"

  DIRTY="$(git -C "$FRAMEWORK_DIR" status --porcelain)"
  if [ -z "$DIRTY" ]; then
    ok "框架工作区干净 —— 当前没有任何被脚本写入的内容"
  else
    N="$(printf '%s\n' "$DIRTY" | wc -l)"
    act "共 $N 项改动："
    printf '%s\n' "$DIRTY" | sed 's/^/      /'
    printf "\n"
    dim "M=已修改  A=新增(已暂存)  ??=未追踪"
    dim "提示：未追踪项如果是 build/ 下的产物，属正常（框架 .gitignore 已忽略 build/）"
  fi

  # 最近一次写前快照
  LAST_SNAP="$(ls -1t "$LOG_DIR"/prewrite-*.sha1 2>/dev/null | head -1)"
  if [ -n "$LAST_SNAP" ]; then
    printf "\n"
    act "最近一次写前快照：$LAST_SNAP"
    head -20 "$LAST_SNAP" | sed 's/^/      /'
  fi
  printf "\n  日志：%s\n" "$REPORT"; exit 0
fi

# ══════════════════════════════════════════
# 第 0 步 · 安全预检
# ══════════════════════════════════════════
H "第 0 步 / 安全预检"

[ -f "$LOCK_FILE" ] || die "找不到 framework.lock（应在 $LOCK_FILE）"
ok "framework.lock 已加载"
[ -d "$CONTENT_DIR" ] || die "找不到 content/（应在 $CONTENT_DIR）"
ok "content/ 已加载"

framework_ready || die "框架目录不存在：$FRAMEWORK_DIR
      先克隆：git clone --recursive $FRAMEWORK_REPO \"$FRAMEWORK_DIR\""

DIRTY="$(git -C "$FRAMEWORK_DIR" status --porcelain)"
if [ -n "$DIRTY" ]; then
  warn "框架工作区**不干净** —— 可能有未纳管的手改："
  printf '%s\n' "$DIRTY" | sed 's/^/      /'
  printf "\n"
  dim "如果是上次脚本铺的内容 → 正常，继续即可（本次会重新铺一遍）"
  dim "如果多数文件你没印象 → 警惕，先跑 RESTORE=1 归零再重来"
  ask_confirm "继续？" || { bad "已中止"; exit 1; }
else
  ok "框架工作区干净"
fi

# ══════════════════════════════════════════
# 第 1 步 · 校验 commit
# ══════════════════════════════════════════
H "第 1 步 / 校验框架 commit（对照 framework.lock）"

REAL_COMMIT="$(git -C "$FRAMEWORK_DIR" rev-parse HEAD 2>/dev/null)"
printf "  lock 约定：%s\n" "$FRAMEWORK_COMMIT"
printf "  实际：    %s\n" "$REAL_COMMIT"

if [ "$REAL_COMMIT" = "$FRAMEWORK_COMMIT" ]; then
  ok "commit 匹配（$FRAMEWORK_SUBJECT）"
else
  bad "commit 不匹配！"
  dim "若需升级：cd $FRAMEWORK_DIR && git fetch origin && git checkout $FRAMEWORK_COMMIT"
  dim "  然后同步改 framework.lock 的 [framework] commit 才继续"
  dim "若需回退到 lock 版本：在上述命令基础上加 git submodule update --init --recursive"
  die "框架版本与 lock 不一致，已中止（防止内容铺到未知版本上）"
fi

# 子模块校验
if [ -f "$FRAMEWORK_DIR/.gitmodules" ]; then
  MG_STATUS="$(git -C "$FRAMEWORK_DIR" submodule status --recursive 2>/dev/null | head -1)"
  MG_GOT="$(printf '%s' "$MG_STATUS" | awk '{print $1}' | tr -d '+-')"
  printf "  子模块 mgfembp：lock=%s 实际=%s\n" "$MG_COMMIT" "$MG_GOT"
  if [ "$MG_GOT" = "$MG_COMMIT" ]; then
    ok "子模块 commit 匹配"
  else
    warn "子模块 commit 不匹配（可能未拉取或已漂移）"
    dim "修复：git -C $FRAMEWORK_DIR submodule update --init --recursive"
  fi
  if [ -f "$FRAMEWORK_DIR/$MG_PROBE" ]; then
    ok "子模块探针文件存在（$MG_PROBE）"
  else
    bad "子模块探针缺失（$MG_PROBE）→ 子模块未真正拉下来"
    dim "修复：git -C $FRAMEWORK_DIR submodule update --init --recursive"
    die "子模块未就绪，构建必然失败"
  fi
fi

# ══════════════════════════════════════════
# 第 2 步 · 写前快照
# ══════════════════════════════════════════
H "第 2 步 / 写前快照（记录将被改写文件的 SHA1）"

# 将被改写的路径（相对框架根）
TARGETS_FILE="$(mktemp)"; tmp_track "$TARGETS_FILE"
{
  # data/ 下所有同名 JSON（合并目标）
  if [ -d "$CONTENT_DIR/data" ]; then
    find "$CONTENT_DIR/data" -maxdepth 1 -name '*.json' -printf '%f\n' 2>/dev/null \
      | while read -r f; do [ -f "$FRAMEWORK_DIR/src/data/$f" ] && printf 'src/data/%s\n' "$f"; done
  fi
  # src/ 下将新增的 .c
  if [ -d "$CONTENT_DIR/src" ]; then
    find "$CONTENT_DIR/src" -maxdepth 1 -name '*.c' -printf 'src/shanhe_%f\n' 2>/dev/null
  fi
  # 3c''：框架补丁的目标文件（会被覆写，必须先快照）
  if [ -d "$CONTENT_DIR/framework-patch" ]; then
    find "$CONTENT_DIR/framework-patch" -maxdepth 1 -type f -name '*.patch' 2>/dev/null \
      | while read -r p; do
          t="$(grep -m1 '^+++ b/' "$p" | sed 's|^+++ b/||')"
          [ -n "$t" ] && printf '%s\n' "$t"
        done
  fi
  # 3b''：消息表补丁目标（会被改写，必须先快照）
  if find "$CONTENT_DIR/texts" -type f -name 'msg_overrides.*.json' 2>/dev/null | grep -q .; then
    printf 'texts/texts.txt\n'
  fi
} | sort -u > "$TARGETS_FILE"

if [ "$DRY_RUN" = "1" ]; then
  act "[预演] 将记录以下文件的 SHA1 快照："
  sed 's/^/      /' "$TARGETS_FILE"
else
  : > "$PREWRITE_SNAPSHOT"
  while read -r rel; do
    [ -z "$rel" ] && continue
    if [ -f "$FRAMEWORK_DIR/$rel" ]; then
      ( cd "$FRAMEWORK_DIR" && sha1sum "$rel" ) >> "$PREWRITE_SNAPSHOT"
    else
      printf 'MISSING  %s\n' "$rel" >> "$PREWRITE_SNAPSHOT"
    fi
  done < "$TARGETS_FILE"
  ok "快照已写入 $PREWRITE_SNAPSHOT（$(wc -l < "$PREWRITE_SNAPSHOT") 行）"
fi

rm -f "$TARGETS_FILE"   # 用完即弃（2026-09-29 补：此前漏回收，/tmp 里累积 605 B 残留）

# ══════════════════════════════════════════
# 第 3 步 · 铺设
# ══════════════════════════════════════════
H "第 3 步 / 铺设（合并 content/ → 框架）"

MERGED_COUNT=0
SKIPPED_COUNT=0
DATA_WRITTEN=0      # 只统计 data/*.json 的**实际写入数**（3a' 的门禁用它，不用 MERGED_COUNT）

# ── 3a'' 的登记（声明提前到此处：3a 的「不在自动处理名单」warn 要用它）──
#   详细设计见 3a'' 段与 tools/shanhe-content-tables.sh 头注释 / docs/5 §5.18。
# ★ 2026-09-29（T4）：登记面从「序章」扩到「序章 + 第 1~4 章」。
#   一条实例 = 一个 JSON → 一个自有整文件；同一张 `units` 表可以有多条实例。
B3_NEW_DATA="${B3_NEW_DATA:-shanhe_p_units.json shanhe_01_units.json shanhe_02_units.json shanhe_03_units.json shanhe_04_units.json}"
B3_INSTANCES="${B3_INSTANCES:-units:shanhe_p_units.json:src/shanhe_p_udefs.c units:shanhe_01_units.json:src/shanhe_01_udefs.c units:shanhe_02_units.json:src/shanhe_02_udefs.c units:shanhe_03_units.json:src/shanhe_03_udefs.c units:shanhe_04_units.json:src/shanhe_04_udefs.c}"

# ── 3a. data/*.json 按语义合并 ──
merge_json() {
  local name="$1" src="$CONTENT_DIR/data/$1" dst="$FRAMEWORK_DIR/src/data/$1"
  if [ ! -f "$dst" ]; then
    warn "[$name] 框架侧无此文件，跳过（原创新表需人工确认落点）"
    SKIPPED_COUNT=$((SKIPPED_COUNT+1)); return 0
  fi
  python3 - "$src" "$dst" "$name" "$DRY_RUN" <<'PY'
import json, sys, copy, os
src, dst, name, dry = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"

with open(src, encoding="utf-8") as f: patch = json.load(f)
with open(dst, encoding="utf-8") as f: base  = json.load(f)

def die(msg):
    print(f"  \033[0;31m✗\033[0m [{name}] {msg}"); sys.exit(2)

# ---------- characters.json 专用：符号名/槽位号 双键合并 ----------
if name == "characters.json":
    if "characters" not in base or not isinstance(base["characters"], list):
        die("框架表结构异常：缺 characters 数组")
    slots = base["characters"]

    # 权威槽位模型（scripts/generated_data/characters/schema.py docstring）：
    #   · 1-based designator 1..256 → 槽位 [designator - 1]
    #   · 具名记录（character 键）→ designator = characters.h 里该常量的数值
    #   · 原始记录（characterId 键）→ designator = 该整数本身
    #   · ★ 两者互斥：一条记录只能有其中一个（schema.py:533 硬校验）
    def key_of(rec):
        if "character" in rec and "characterId" in rec:
            die("记录同时有 character 与 characterId —— schema 要求「exactly one」")
        if "character" in rec:   return ("character", rec["character"])
        if "characterId" in rec: return ("characterId", rec["characterId"])
        return None

    # 建索引（用框架原表的键，保证替换时键类型一致）
    idx_by_key = {}
    for i, rec in enumerate(slots):
        k = key_of(rec)
        if k is None:
            die(f"框架槽位 {i} 键缺失（既无 character 也无 characterId）")
        idx_by_key[k] = i
    # 冗余校验：characterId 是否恒等于下标 + 1（形态 B 的 1-based 约定）
    for k, i in idx_by_key.items():
        if k[0] == "characterId" and k[1] != i + 1:
            die(f"槽位断言失败：下标 {i} 的 characterId={k[1]}，期望 {i+1}（表结构已变，中止以防静默错位）")

    # 应用补丁：按「同键类型 + 同键值」替换
    applied = []
    for entry in patch.get("characters", []):
        if not isinstance(entry, dict):
            die("补丁条目不是对象")
        k = key_of(entry)
        if k is None:
            die("补丁条目缺 character / characterId（无法定位槽位）")
        if k not in idx_by_key:
            # 不在原表里 → 是新增。但 characters 是 256 全满表，新增无处可放
            die(f"补丁键 {k[0]}={k[1]} 不在框架原表中 —— "
                f"characters.json 是 256 槽全满表，原创角色应『复用被顶替者的符号名』，不能新增键")
        i = idx_by_key[k]
        old = slots[i].get("character") or f"<characterId={slots[i].get('characterId')}>"
        slots[i] = copy.deepcopy(entry)
        applied.append(f"{old}（槽位 {i+1}）→ 已替换")
    print(f"  \033[0;32m✓\033[0m [merge] {name} 替换 {len(applied)} 条（256 槽保持全覆盖）")
    for a in applied[:20]: print(f"        · {a}")
    if len(applied) > 20: print(f"        … 其余 {len(applied)-20} 条略")
    result = base

# ---------- 通用：数组表按定位键合并 ----------
else:
    # 找出补丁与基底共有的「数组字段」
    def find_list(d):
        for k, v in d.items():
            if isinstance(v, list) and v and isinstance(v[0], dict):
                return k
        return None
    lk = find_list(patch) or find_list(base)
    if lk is None:
        die("无法识别数组字段（patch 与 base 都没有对象数组）")
    lst = base.get(lk, [])
    # 定位键：优先同名字段
    def key_of(rec):
        for cand in ("character","class","item","support","id","name","symbol"):
            if cand in rec: return cand
        return None
    applied = 0
    # ── 显式声明的「整表替换」表 ──
    # 适用：**无标识键的纯规则表**（如 weapontriangle 的 rules —— 每项只有
    #       attacker/defender/hitBonus/atkBonus，没有可定位的键）。
    #       这类表无法「按条匹配」，只能整体覆盖；因此**必须显式列出**，
    #       以免把"定位键写错"静默当成整表替换。
    #
    # ★ items_expansion.json 也在列（2026-09-25，M3③）——理由与纯规则表不同但结论相同：
    #   它是**扩展 overlay 表**（只含 ID >= 0xCE 的《山河烬》原创道具），
    #   **不曾承载任何原版内容**（原版 206 条在 items.json，不在本表）。
    #   框架自带一条样例记录 ITEM_EXPANSION_CE，本项目已用补丁把该符号改名
    #   （shanhe-item-ids.patch，0xCE 破军 / 0xCF 照夜）⇒ 若走"按键追加"，
    #   框架那条样例会**残留**一个指向已不存在符号的记录 ⇒ 编译失败。整表替换让它被自然覆盖，零孤儿。
    WHOLE_TABLE_REPLACE = ("weapontriangle.json", "items_expansion.json")
    if name in WHOLE_TABLE_REPLACE:
        new_list = patch.get(lk)
        if not isinstance(new_list, list) or not new_list:
            die(f"{name}：整表替换要求补丁含非空数组字段 '{lk}'")
        print(f"  \033[0;32m✓\033[0m [merge] {name} 【整表替换】字段 '{lk}'：{len(lst)} 条 → {len(new_list)} 条"
              f"（显式声明；该表无标识键，不按键匹配）")
        lst = copy.deepcopy(new_list)
        applied = len(lst)
    else:
        for entry in patch.get(lk, []):
            k = key_of(entry)
            if k is None:
                die(f"补丁条目无可用定位键（试过 character/class/item/support/id/name/symbol）；"
                    f"若该表本就无标识键（纯规则表），请把 '{name}' 加入 WHOLE_TABLE_REPLACE 走整表替换")
            found = False
            for i, rec in enumerate(lst):
                if rec.get(k) == entry[k]:
                    lst[i] = copy.deepcopy(entry); applied += 1; found = True; break
            if not found:
                lst.append(copy.deepcopy(entry)); applied += 1
    base[lk] = lst
    print(f"  \033[0;32m✓\033[0m [merge] {name} 列表 '{lk}' 应用 {applied} 条")
    result = base

# ---------- 写回（含框架自身的 4 空格缩进风格） ----------
out = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
if dry:
    print(f"        [预演] 未写入 {dst}")
else:
    # 内容感知写入（2026-09-27）：一致就**不落盘**。落盘会刷新 mtime ⇒
    # generated_data 全表重生成 ⇒ 全量重编。退出码 3 = "无变化"（区别于 2 = 错误）。
    old = ""
    if os.path.exists(dst):
        with open(dst, encoding="utf-8") as f: old = f.read()
    if old == out:
        print(f"        \033[2m[unchanged]\033[0m src/data/{name} 内容未变，跳过写入（保 mtime）")
        sys.exit(3)
    with open(dst, "w", encoding="utf-8") as f: f.write(out)
PY
}

if [ -d "$CONTENT_DIR/data" ] && [ -n "$(ls -A "$CONTENT_DIR/data" 2>/dev/null)" ]; then
  for f in "$CONTENT_DIR/data"/*.json; do
    [ -f "$f" ] || continue
    name="$(basename "$f")"
    if [ "$DRY_RUN" = "1" ]; then
      act "[预演] 合并 data/$name → src/data/$name"
      MERGED_COUNT=$((MERGED_COUNT+1))
    else
      merge_json "$name"; RC=$?
      case "$RC" in
        0) MERGED_COUNT=$((MERGED_COUNT+1)); DATA_WRITTEN=$((DATA_WRITTEN+1)) ;;
        3) SKIPPED_COUNT=$((SKIPPED_COUNT+1)) ;;          # 内容未变，未落盘（幂等关键）
        *) die "合并 $name 失败" ;;
      esac
    fi
  done
else
  dim "content/data/ 为空 —— 无非原创数据可合并（M1 阶段正常）"
fi

# ── 3a'. 锁定表处理：数据校验 → B' 回填 → round-trip 复核 ──
#
# 背景（见 docs/6 §3.4a/§3.4b）：框架对若干 generated-data 表**强制 round-trip**
# ——`generate` 会把「JSON 生成的模型」与「手写 src/data_<表>.c 解析出的模型」
# 逐字段比对，不一致就拒绝产出 C，导致 make 报 generated_data.mk:685 Error 1。
#
# 解法（B'：生成产物回填）：
#   用 generate --no-roundtrip 先产出 C，再用它**覆盖**手写参考，
#   使「参考 == 生成」，round-trip 自然逐字段一致。
#
# ★ 边界：只对「hand source 是**整文件**」的 4 张全局锁定表回填。
#   章节/机制表（units/shops/traps/eventlists/terrainstats/movecost/weapontriangle）
#   的 hand source 是 **partial-file**（只 round-trip 某个前缀或块，其余部分是
#   别的章节的数据）——整文件回填会**抹掉其它章节**，故不在此处理（留给 M4）。
B2_TABLES="characters classes items supports"
B2_TOUCHED=""

if [ "$DRY_RUN" != "1" ] && [ "$DATA_WRITTEN" -gt 0 ] && [ -d "$FRAMEWORK_DIR/scripts/generated_data" ]; then
  act "锁定表处理（数据校验 → B' 回填 → round-trip 复核）…"

  for t in $B2_TABLES; do
    [ -f "$CONTENT_DIR/data/$t.json" ] || continue      # 只处理 content/ 里确实有的表
    B2_TOUCHED="$B2_TOUCHED $t"
    VD_LOG="$LOG_DIR/validate-$STAMP-$t.log"
    HAND="src/data_$t.c"
    GEN="build/generated/data/data_$t.c"

    # ① 数据本身是否合法？（不带 round-trip —— 这一关失败 = 真错误）
    if ( cd "$FRAMEWORK_DIR" && python3 -m scripts.generated_data validate \
          --table "$t" --no-roundtrip ) > "$VD_LOG" 2>&1; then
      ok "[$t] ① 数据合法"
    else
      bad "[$t] ① 数据非法 —— 常见原因："
      dim "· 一条记录同时有 character 与 characterId（schema 要求 exactly one）"
      dim "· 用了 characters.h 未定义的符号名（原创须复用被顶替者的符号名）"
      dim "· baseRanks 的键不是 ITYPE_* / 值不是 WPN_EXP_* 字符串"
      dim "· attributes 不是字符串数组；affinity 不是 UNIT_AFFIN_*"
      dim "· defaultClass 不是已定义的 CLASS_*（跨表引用会校验）"
      printf "\n"
      tail -15 "$VD_LOG" | sed 's/^/      /'
      dim "完整日志：$VD_LOG"
      die "[$t] 数据校验未通过，未进行构建"
    fi

    # ② B' 回填：generate --no-roundtrip → 覆盖手写参考
    if ( cd "$FRAMEWORK_DIR" && python3 -m scripts.generated_data generate \
          --table "$t" --no-roundtrip --out-dir build/generated/data ) >> "$VD_LOG" 2>&1; then
      if [ -f "$FRAMEWORK_DIR/$HAND" ] && cmp -s "$FRAMEWORK_DIR/$GEN" "$FRAMEWORK_DIR/$HAND"; then
        # 内容感知（2026-09-27）：一致就不 cp。cp 会刷新 mtime ⇒ 该表的 .o 重编。
        dim "[$t] ② B' 回填：与生成产物已逐字节一致，跳过（保 mtime ⇒ 不触发重编）"
      elif cp -f "$FRAMEWORK_DIR/$GEN" "$FRAMEWORK_DIR/$HAND" 2>/dev/null; then
        ok "[$t] ② B' 回填完成（$HAND ← $GEN）"
      else
        die "[$t] ② 回填失败：无法写入 $HAND"
      fi
    else
      bad "[$t] ② 生成产物失败（非 round-trip 原因）"
      tail -10 "$VD_LOG" | sed 's/^/      /'
      dim "完整日志：$VD_LOG"
      die "[$t] 生成失败，未进行构建"
    fi

    # ③ round-trip 复核 —— 回填后必须通过，这是「make 不会因它卡住」的证明
    if ( cd "$FRAMEWORK_DIR" && python3 -m scripts.generated_data validate \
          --table "$t" ) > "$VD_LOG" 2>&1; then
      ok "[$t] ③ round-trip 复核通过"
    else
      bad "[$t] ③ round-trip 复核失败 —— 回填未生效？"
      tail -10 "$VD_LOG" | sed 's/^/      /'
      dim "完整日志：$VD_LOG"
      die "[$t] round-trip 复核未通过"
    fi
  done

  if [ -z "$B2_TOUCHED" ]; then
    dim "content/data/ 里没有受 round-trip 约束的表 —— 跳过（M1 阶段正常）"
  else
    dim "已处理：$B2_TOUCHED"
    dim "边界：章节表（units/shops/…）的 hand source 是 partial-file，不在此回填（M4 专门设计）"
  fi

  # 提示：content/data/ 里有、但不在 B2 名单的表（可能是章节表，需人工确认）
  for f in "$CONTENT_DIR/data"/*.json; do
    [ -f "$f" ] || continue
    base="$(basename "$f" .json)"
    case " $B2_TABLES " in
      *" $base "*) continue ;;
    esac
    # 已由 3a'' 通道登记的新表不该再报"需人工确认"（登记本身就是那道人工闸）
    case " $B3_NEW_DATA " in
      *" $base.json "*) continue ;;
    esac
    warn "content/data/$base.json 不在自动处理名单（可能是章节表/新表）—— 请确认其落点与 round-trip 策略"
  done
else
  # 2026-09-27 新增：内容一致时**整块跳过**。这不是"偷懒不做校验"，而是：
  # 校验的对象是"本次改动"，没有改动就没有新对象；而跑 generate 会刷新
  # build/generated/data/*.c 的 mtime 一旦刷新，会在框架侧制造无谓的写入事件（下游噪音）。
  [ "$DRY_RUN" = "1" ] || dim "锁定表处理：content/data 与框架逐字节一致（0 项写入）—— 跳过校验/回填（不落盘 ⇒ mtime 不动）"
fi

# ── 3a''. content 自有表实例（山河烬自己的章节表）──
#
# 与 3a' 的分工：
#   3a'  管**框架共用的整文件全局表**（characters/classes/items/supports），
#        目标是框架里**已经存在**的 src/data_<表>.c（整文件回填安全）。
#   3a'' 管**山河烬自有的章节表**，目标是**新建立**的 src/shanhe_*.c。
#
# 为什么章节表走 3a'' 而不是塞进 3a'（2026-09-28 勘察，两条实测硬证据）：
#   ① units/shops/traps 的 hand source 是 **partial-file** —— src/events_udefs.c
#      75154 行里 Ch2 只是一个前缀切片，同一个文件还坐着 Ch3..Ch8/塔/遗迹。
#      3a' 的整文件 `cp` 会把那些章节**全部抹掉**，所以 3a' 白名单只放 4 张整文件表。
#   ② 但框架 modern 构建的 C 源集合是 `$(wildcard src/*.c)`（modern.mk:359）
#      ⇒ 新增一个 `src/<名字>.c` **自动进构建**，无需改 Makefile、无需发框架补丁；
#      而上游自己给章节单位用的就是**每章一个整文件**
#      （src/events/prologue-eventudefs.h / ch1-eventudefs.h）。
#   ⇒ 「partial-file」不是框架硬约束，只是 Ch2 那次迁移的实现选择。山河烬自己的
#      章节表不必去挤它：直接「JSON → 100% 生成的自有整文件 src/shanhe_*.c」。
#
# ★ 登记是两处（少一处即不生效；3a 的「不在自动处理名单」warn 会提醒）：
#     B3_NEW_DATA   原创新表（框架侧不存在的 JSON）—— 这道人工闸对应
#                   merge_json 里那句「原创新表需人工确认落点」
#     B3_INSTANCES  <表>:<JSON 文件名>:<框架内相对路径>
# ★ 门禁与硬拦（落点写错=静默灾难）见 tools/shanhe-content-tables.sh 头注释；
#   设计取舍与那个 inventory 坑见 docs/5 §5.18。
# ★ 命名规则（2026-09-28 定）：章节内部名取自 docs/10 §3.2（序章 `ShanheP`、第 N 章
#   `ShanheNN`），落盘时**全小写**并加下划线：`shanhe_p_units.json` → `src/shanhe_p_udefs.c`。
#   之所以不是 docs/10 举例的 `ch0_units.json`：本项目的 C 落点统一走 `src/shanhe_*.c`
#   前缀（工具的白名单硬拦 + 第 6 步反查白名单都认它），加前缀才不会与框架文件混淆。
#
# ⚠️ 与 3c 的耦合（2026-09-28 实测）：3c 会用「框架侧 `src/shanhe_*.c` 集合」与
#    「`content/src/*.c` 映射后的集合」比对，不一致就 touch Makefile（重扫 wildcard）。
#    本通道新增的 `src/shanhe_*.c` **不是** content/src 来的 ⇒ 若不把实例目标并进
#    3c 的期望集合，会**每一轮都判定"集合有变化"⇒ 每轮全量重编**。已在 3c 处并入。
# ★ 2026-09-29（T4）：登记面从「序章」扩到「序章 + 第 1~4 章」。
#   一条实例 = 一个 JSON → 一个自有整文件；同一张 `units` 表可以有多条实例。
B3_NEW_DATA="${B3_NEW_DATA:-shanhe_p_units.json shanhe_01_units.json shanhe_02_units.json shanhe_03_units.json shanhe_04_units.json}"
B3_INSTANCES="${B3_INSTANCES:-units:shanhe_p_units.json:src/shanhe_p_udefs.c units:shanhe_01_units.json:src/shanhe_01_udefs.c units:shanhe_02_units.json:src/shanhe_02_udefs.c units:shanhe_03_units.json:src/shanhe_03_udefs.c units:shanhe_04_units.json:src/shanhe_04_udefs.c}"
# （B3_NEW_DATA / B3_INSTANCES 的声明见第 3 步开头 —— 提前到那里是因为 3a 的
#   「不在自动处理名单」warn 需要它）
if [ "${CONTENT_TABLES:-1}" != "1" ]; then
  dim "content 自有表实例：CONTENT_TABLES=0，按开关跳过"
else
  act "content 自有表实例（山河烬章节表）…"
  B3_LOG="$LOG_DIR/content-table-$STAMP-run.log"
  env CONTENT_TABLES=1 B3_NEW_DATA="$B3_NEW_DATA" B3_INSTANCES="$B3_INSTANCES" \
      REPO_ROOT="$REPO_ROOT" CONTENT_DIR="$CONTENT_DIR" FRAMEWORK_DIR="$FRAMEWORK_DIR" \
      LOG_DIR="$LOG_DIR" STAMP="$STAMP" DRY_RUN="$DRY_RUN" \
      bash "$REPO_ROOT/tools/shanhe-content-tables.sh" > "$B3_LOG" 2>&1
  B3_RC=$?
  cat "$B3_LOG"                       # 控制台：原样（保留颜色）
  _plain < "$B3_LOG" >> "$REPORT"     # 日志：去色
  case "$B3_RC" in
    0) ;;
    3) warn "content 自有表实例：前置缺失，已跳过（不影响产物正确性）" ;;
    *) bad "content 自有表实例失败（rc=$B3_RC）"
       die "章节表未通过门禁 —— 修法见 tools/shanhe-content-tables.sh 头注释与 docs/5 §5.18" ;;
  esac
fi

# ── 3b. texts/ 合并 ──
#
# ★ indexed_overrides.*.json 不入 3b 的文件级拷贝 —— 它们是**补丁**，由 3b' 走
#   「合并进框架 indexed_overrides.json → regenerate 重生成 indexed.txt」的通道。
#   直接 cp 会覆盖框架自带的 156 条官方覆盖。
# ⚠️ 仓库路径含空格（FireEmblem Realm-in-Ashes）→ 文件清单一律用
#    `while IFS= read -r` 逐行读，**不能**裸 `for x in $(find …)`（会被词分割）。
TEXT_OVERRIDE_PATCHES="$(find "$CONTENT_DIR/texts" -type f -name 'indexed_overrides.*.json' 2>/dev/null)"
if [ -d "$CONTENT_DIR/texts" ] && [ -n "$(find "$CONTENT_DIR/texts" -type f -not -name '.gitkeep' -not -name 'indexed_overrides.*.json' 2>/dev/null)" ]; then
  while IFS= read -r rel; do
    case "$rel" in indexed_overrides.*.json) continue ;; esac
    src="$CONTENT_DIR/texts/$rel"; dst="$FRAMEWORK_DIR/texts/$rel"
    if [ "$DRY_RUN" = "1" ]; then
      act "[预演] 铺设 texts/$rel → texts/$rel"
      MERGED_COUNT=$((MERGED_COUNT+1))
    elif write_if_changed "$dst" < "$src"; then
      act "[copy] texts/$rel（内容有变，已更新）"
      MERGED_COUNT=$((MERGED_COUNT+1))
    else
      dim "[unchanged] texts/$rel 内容未变，跳过写入（保 mtime）"
      SKIPPED_COUNT=$((SKIPPED_COUNT+1))
    fi
  done < <(cd "$CONTENT_DIR/texts" && find . -type f -not -name '.gitkeep' -not -name 'indexed_overrides.*.json' | sed 's|^\./||')
else
  dim "content/texts/ 无整体铺设文件（M1 阶段正常）"
fi

# ── 3b'. 中文文本覆盖补丁（indexed_overrides）──
#
# 背景（见 docs/6 §3.4d）：框架的 texts/locales/zh-Hans/indexed.txt **不是手写的**，
# 而是由 importer 从 pinned 原始快照 + texts/locales/indexed_overrides.json 生成的。
# 因此原创中文文本的正确姿势**不是**改 indexed.txt（会被下次 regenerate 冲掉），
# 而是：把补丁合并进框架的 indexed_overrides.json → 跑 regenerate 重生成。
#
#   content/texts/locales/indexed_overrides.zh-Hans.json   ← 你写这个（补丁）
#      ↓ 合并（按 source_key）
#   框架 texts/locales/indexed_overrides.json              ← 156 条官方 + 你的
#      ↓ python3 -m scripts.localization.game_locales regenerate
#   框架 texts/locales/zh-Hans/indexed.txt                 ← 重生成，含你的文本
#      ↓ python3 -m scripts.localization.game_locales.text_edit_ledger generate
#   框架 texts/locales/mapping/game_locale_text_edits.json ← 台账（改动必须有 provenance）
#
# 定位键 = FE8J source index（#0xNNNN），非 FE8U target id。
# ⚠️ 路径含空格 → 用 `while IFS= read -r` 逐行读，禁用裸 `for x in $VAR`。
if [ -n "$TEXT_OVERRIDE_PATCHES" ]; then
  TEXT_OVR_N=0
  while IFS= read -r patch; do
    [ -n "$patch" ] || continue
    [ -f "$patch" ] || continue
    name="$(basename "$patch")"
    if [ "$DRY_RUN" = "1" ]; then
      act "[预演] 合并文本覆盖补丁 $name → texts/locales/indexed_overrides.json"
      TEXT_OVR_N=$((TEXT_OVR_N+1)); MERGED_COUNT=$((MERGED_COUNT+1))
      continue
    fi
    python3 - "$patch" "$FRAMEWORK_DIR" <<'PY' >> "$REPORT" 2>&1
import json, sys, os
patch_path, fw = sys.argv[1], sys.argv[2]
patch = json.load(open(patch_path, encoding="utf-8"))
dst = os.path.join(fw, "texts/locales/indexed_overrides.json")
base = json.load(open(dst, encoding="utf-8"))
sk = patch.get("source_key", "fe8cn_source")
if sk not in base.get("sources", {}):
    print(f"  framework overrides missing sources.{sk}"); sys.exit(2)
entries = base["sources"][sk]["entries"]
# ★ 2026-09-28 修正：原先只放行 4 个字段（expected_text/provenance/reason/replacement_text），
#   把框架 overrides.py 支持的 expected_text_sha256 / preserve_structure / replacements
#   **静默丢弃** ⇒ 一旦用到「有意变更控制码结构」的合法写法
#   （preserve_structure=false + expected_text_sha256），本层就会先报
#   "missing fields: ['expected_text']" 且原因藏在别处。
#   修法：① 放行框架 schema 里的全部字段；② 未知字段**硬拦**（防下次再静默丢字段）。
#   ⚠️ 框架规则见 scripts/localization/game_locales/overrides.py:
#      expected_text 与 expected_text_sha256 **互斥**；
#      preserve_structure=false 时**必须**给 sha256（"audited control changes"）。
PASS_FIELDS = ("expected_text", "expected_text_sha256", "preserve_structure",
               "provenance", "reason", "replacement_text", "replacements")
n = 0
for sid, rec in patch.get("overrides", {}).items():
    key = "0x%04X" % int(sid, 16)
    unknown = sorted(set(rec) - set(PASS_FIELDS))
    if unknown:
        print("  override %s has unsupported field(s): %s" % (sid, unknown)); sys.exit(2)
    missing = [k for k in ("provenance", "reason") if k not in rec]
    if missing:
        print(f"  override {sid} missing fields: {missing}"); sys.exit(2)
    if ("expected_text" in rec) == ("expected_text_sha256" in rec):
        print("  override %s must have exactly one of expected_text / expected_text_sha256" % sid); sys.exit(2)
    if ("replacement_text" in rec) == ("replacements" in rec):
        print("  override %s must have exactly one of replacement_text / replacements" % sid); sys.exit(2)
    if rec.get("preserve_structure") is False and "expected_text_sha256" not in rec:
        print("  override %s: preserve_structure=false 需要 expected_text_sha256（框架规则同此）" % sid); sys.exit(2)
    entries[key] = {k: rec[k] for k in PASS_FIELDS if k in rec}
    n += 1
# 内容感知（2026-09-27）：合并结果与现有文件一致 ⇒ 不落盘、退出码 3。
# 落盘会刷新 indexed_overrides.json 的 mtime，进而让下面的 regenerate 每次都跑、
# 把 1.3MB 的 indexed.txt 重写一遍 ⇒ 上游 locale 资源整体重编。
out = json.dumps(base, ensure_ascii=False, indent=2)
old = ""
if os.path.exists(dst):
    with open(dst, encoding="utf-8") as f: old = f.read()
if old == out:
    print(f"  [unchanged] indexed_overrides.json 合并后无变化（{n} 条覆盖已在内）")
    sys.exit(3)
with open(dst, "w", encoding="utf-8") as f:
    f.write(out)
print(f"  merged {n} overrides from {os.path.basename(patch_path)}")
PY
    RC=$?
    case "$RC" in
      0) ok "[文本] $name 合并入 indexed_overrides.json"
         TEXT_OVR_N=$((TEXT_OVR_N+1)); MERGED_COUNT=$((MERGED_COUNT+1)) ;;
      3) dim "[文本] $name 的覆盖已在框架中（内容未变），跳过写入（保 mtime）"
         SKIPPED_COUNT=$((SKIPPED_COUNT+1)) ;;
      *) bad "[文本] $name 合并失败"; tail -10 "$REPORT" | sed 's/^/      /'
         die "[文本] 覆盖补丁合并失败" ;;
    esac
  done < <(printf '%s\n' "$TEXT_OVERRIDE_PATCHES")

  if [ "$TEXT_OVR_N" -gt 0 ] && [ "$DRY_RUN" != "1" ]; then
    # regenerate：从 pinned 快照 + overrides 重生成 indexed.txt / manifest
    if ( cd "$FRAMEWORK_DIR" && python3 -m scripts.localization.game_locales regenerate ) >> "$REPORT" 2>&1; then
      ok "[文本] regenerate 重生成 indexed.txt 完成"
    else
      bad "[文本] regenerate 失败"; tail -15 "$REPORT" | sed 's/^/      /'
      die "[文本] regenerate 失败（覆盖补丁格式或 source index 有误）"
    fi
    # ledger generate：刷新「文本改动台账」（改动必须有 provenance）
    if ( cd "$FRAMEWORK_DIR" && python3 -m scripts.localization.game_locales.text_edit_ledger generate ) >> "$REPORT" 2>&1; then
      ok "[文本] text-edit 台账已刷新"
    else
      bad "[文本] text-edit 台账生成失败（多为「改了文本但缺 provenance」）"
      tail -15 "$REPORT" | sed 's/^/      /'
      die "[文本] 台账生成失败 —— 给每条覆盖补 provenance（audit/context/target_ids）"
    fi
  fi
else
  dim "content/texts/ 无 indexed_overrides 补丁 —— 跳过中文文本覆盖（正常）"
fi

# ── 3b''. ROM 消息表覆盖补丁（msg_overrides）──
# ⚠️ 关键：框架有两条文本通道，别混：
#     (A) texts/locales/<locale>/indexed.txt —— 审计/宽度/台账（3b' 处理）
#     (B) texts/texts.txt                    —— 【真正编译进 ROM 的消息表】
#         （Makefile:562 → src/msg_data.c → src/msg_data.o）
#   只做 (A) 会出现「审计全绿但 ROM 里仍是英文」。本步补 (B)。
#   定位键 = FE8U target id（texts.txt 的 ## MSG_<HEX>）。
#   ⚠️ 本通道只能【改已有段的正文】。2026-09-29 实测：想「新增消息」走不通 ——
#      框架 game_catalog/build.py 要求 fe8u_target_map.json 行数与消息总数严格相等，
#      加消息就要重跑整条本地化哈希链。扩展道具的名字因此改走 texts/expansion/。
MSG_OVERRIDE_PATCHES="$(find "$CONTENT_DIR/texts" -type f -name 'msg_overrides.*.json' 2>/dev/null)"
if [ -n "$MSG_OVERRIDE_PATCHES" ]; then
  MSG_OVR_N=0
  while IFS= read -r patch; do
    [ -z "$patch" ] && continue
    [ -f "$patch" ] || continue
    MSG_OVR_N=$((MSG_OVR_N+1))
    if [ "$DRY_RUN" = "1" ]; then
      act "[预演] 合并 ROM 消息表补丁：$(basename "$patch") → texts/texts.txt"
    else
      # ⚠️ 幂等 + 内容感知（2026-09-27 加强）
      #   旧实现：每次先 `git checkout HEAD -- texts/texts.txt` 再打补丁。幂等确实做到了
      #     （否则第二次运行补丁里的 expected_text 对不上 —— 2026-09-25 实机踩到
      #     「## MSG_030A 期望与实际不符」），但 checkout 会**无条件刷新 mtime**，
      #     于是 src/msg_data.c → ROM 每次都重编。
      #   新实现：基底不再靠 checkout，而是 `git show HEAD:texts/texts.txt` 读进内存；
      #     打补丁后的结果与磁盘现内容逐字节比较 —— 一致就既不落盘也不动 mtime（退出码 3）。
      #     "幂等"因此成立，且去掉了"先还原"这个有副作用的动作。
      python3 - "$patch" "$FRAMEWORK_DIR/texts/texts.txt" "$DRY_RUN" <<'PYMSG' >> "$REPORT" 2>&1
import json, re, subprocess, sys, os
patch_path, target_path, dry = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
with open(patch_path, encoding="utf-8") as f:
    patch = json.load(f)
msgs = patch.get("messages") or {}
if not msgs:
    print("msg_overrides: 无 messages，跳过"); sys.exit(0)

# 基底 = git 里的钉住版本（HEAD）。用 git show 读进内存，**不** checkout（保 mtime）。
fw = os.path.dirname(os.path.dirname(target_path))
rel = os.path.relpath(target_path, fw)
try:
    pristine = subprocess.run(["git", "-C", fw, "show", "HEAD:" + rel],
                              capture_output=True, text=True, check=True).stdout
except subprocess.CalledProcessError:
    print(f"msg_overrides: 无法从 git 读取 HEAD:{rel}（文件不在追踪内？）"); sys.exit(2)
lines = pristine.split("\n")

# 建索引：## MSG_<HEX> → 其后正文行区间 [start, end)
idx = {}
i = 0
while i < len(lines):
    m = re.match(r"^## MSG_([0-9A-Fa-f]+)\s*$", lines[i])
    if m:
        key = int(m.group(1), 16)
        j = i + 1
        while j < len(lines) and not lines[j].startswith("## MSG_") and not lines[j].startswith("#0x"):
            j += 1
        idx[key] = (i, j)
    i += 1

applied = 0
# ⚠️ 必须倒序处理：替换会改变行数，正序会让后续索引错位（实测 ## MSG_26E 取到下一段）
for hexkey in sorted(msgs.keys(), key=lambda k: int(k, 16), reverse=True):
    rec = msgs[hexkey]
    key = int(hexkey, 16)
    if key not in idx:
        print(f"msg_overrides: ## MSG_{hexkey[2:].upper()} 不存在，跳过")
        continue
    start, end = idx[key]
    # 正文 = start+1 .. end，去掉尾部空行
    body = lines[start+1:end]
    while body and body[-1].strip() == "":
        body.pop()
    current = "\n".join(body)
    exp = rec.get("expected_text")
    if exp is not None and current != exp:
        print(f"msg_overrides: ## MSG_{hexkey[2:].upper()} 期望与实际不符")
        print(f"  期望: {exp!r}")
        print(f"  实际: {current!r}")
        sys.exit(2)
    new_text = rec["replacement_text"]
    # 保留原有尾随空行结构，避免改变区块分隔
    tail = lines[start+1+len(body):end]
    lines[start+1:end] = new_text.split("\n") + tail
    applied += 1
    print(f"msg_overrides: ## MSG_{hexkey[2:].upper()} 已覆盖")

new_content = "\n".join(lines)
cur = ""
if os.path.exists(target_path):
    with open(target_path, encoding="utf-8") as f:
        cur = f.read()
if cur == new_content:
    print(f"msg_overrides: 共 {applied} 条 —— 与磁盘现内容一致，跳过写入（保 mtime）")
    sys.exit(3)
if dry:
    print("[预演] 未写入 texts.txt"); sys.exit(0)
with open(target_path, "w", encoding="utf-8") as f:
    f.write(new_content)
print(f"msg_overrides: 共 {applied} 条")
PYMSG
      RC=$?
      case "$RC" in
        0) ok "[消息表] $(basename "$patch") 已合并进 texts/texts.txt" ;;
        3) dim "[消息表] $(basename "$patch") 已在位（内容未变），跳过写入（保 mtime）" ;;
        *) bad "[消息表] 合并失败：$(basename "$patch")"
           tail -20 "$REPORT" | sed 's/^/      /'
           die "[消息表] texts.txt 覆盖失败（expected_text 不符或 target id 有误）" ;;
      esac
    fi
  done < <(printf '%s\n' "$MSG_OVERRIDE_PATCHES")
  [ "$DRY_RUN" = "1" ] && [ "$MSG_OVR_N" -gt 0 ] && dim "共 $MSG_OVR_N 个消息表补丁待合并"
else
  dim "content/texts/ 无 msg_overrides 补丁 —— ROM 消息表保持上游原文"
fi

# ── 3c. src/*.c 铺为 src/shanhe_*.c ──
SRC_ADDED=0
SRC_NAMES=""
if [ -d "$CONTENT_DIR/src" ] && [ -n "$(ls -A "$CONTENT_DIR/src" 2>/dev/null | grep -v '^\.gitkeep$')" ]; then
  for f in "$CONTENT_DIR/src"/*.c; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    # 铁律：统一 shanhe_ 前缀（防同名静默替换上游 expansion_*.c）
    case "$base" in
      shanhe_*) out="$base" ;;
      *)        out="shanhe_$base" ;;
    esac
    # 排除清单（Makefile:132-137 明确排除的 6 名，同名会被剔除）
    case "$out" in
      action_semantics.c|expansion_log.c|expansion_autoplay.c|expansion_chapter_objectives.c|expansion_autoplay_strategies.c|expansion_blue_phase_delegate.c)
        bad "src/$out 与框架排除清单冲突，跳过"; continue ;;
    esac
    SRC_NAMES="$SRC_NAMES $out"
    if [ "$DRY_RUN" = "1" ]; then
      act "[预演] 铺设 src/$base → src/$out"
    elif write_if_changed "$FRAMEWORK_DIR/src/$out" < "$f"; then
      act "[copy] src/$base → src/$out（内容有变）"
      SRC_ADDED=$((SRC_ADDED+1))
    else
      dim "[unchanged] src/$out 内容未变，跳过写入（保 mtime）"
    fi
  done
  # ★ 只在「框架侧 shanhe_*.c 集合」真的变化时才 touch Makefile（2026-09-27 修正）
  #   为什么（本机实测）：Makefile 一被 touch，几乎所有依赖它的目标全部重编 ——
  #   零内容变更也要赔上约 6 分钟。而 touch 的目的**仅仅**是让 make 在解析期
  #   重新展开 `$(wildcard src/*.c)`（只有**新增/删除** .c 才需要触发那个生成器）；
  #   文件**内容**变化已经由 write_if_changed 落盘时的新 mtime 自然触发，不需要动 Makefile。
  # ★ 3a'' 生成的章节表 C 也落在 src/shanhe_*.c —— 必须一并计入「期望集合」，
  #   否则每轮都会判定「集合有变化」⇒ 每轮 touch Makefile ⇒ 每轮全量重编（实测）。
  #   只计入**框架侧确实存在**的目标（若 CONTENT_TABLES=0 且文件从未生成过，
  #   就不该把它算进期望，否则同样会每轮误判）。
  for _b3 in $B3_INSTANCES; do
    _b3out="${_b3##*:}"
    case "$_b3out" in
      src/shanhe_*.c)
        [ -f "$FRAMEWORK_DIR/$_b3out" ] && SRC_NAMES="$SRC_NAMES $(basename "$_b3out")" ;;
    esac
  done
  unset _b3 _b3out

  HAVE_SRC="$(cd "$FRAMEWORK_DIR" && ls src/shanhe_*.c 2>/dev/null | sed 's|.*/||' | sort | tr '\n' ' ')"
  WANT_SRC="$(printf '%s\n' $SRC_NAMES | sed '/^$/d' | sort | tr '\n' ' ')"
  if [ "$DRY_RUN" = "1" ]; then
    dim "共 $(printf '%s\n' $SRC_NAMES | sed '/^$/d' | wc -l | tr -d ' ') 个 .c 待铺设"
  elif [ "$HAVE_SRC" != "$WANT_SRC" ]; then
    touch "$FRAMEWORK_DIR/Makefile"
    ok "$SRC_ADDED 个 .c 内容更新；集合有变化 → 已 touch Makefile（wildcard 解析期展开，必须触发生成器重扫）"
  else
    ok "$SRC_ADDED 个 .c 内容更新；集合未变 → 不 touch Makefile（避免全量重编）"
  fi
else
  dim "content/src/ 为空 —— 无原创 C 代码可铺设（M1 阶段正常）"
fi

# ── 3c'. 字库补丁铺设（原创汉字的 CJK 字库扩展）──
# 背景：框架 CJK 字库 = 「冻结全联合基线」+ FEHRR 源优先覆盖，二者均不含项目新造字。
#       框架无「新增字」官方入口 → 本项目走「扩冻结基线」路线，产物以单个归档纳管。
#       归档内容（26 项）：
#         fonts/cjk/febuilder-baseline/*      —— 扩增后的冻结基线（含新字真字形）
#         fonts/cjk/corpora/ maps/ *.json     —— 重算后的语料/映射/清单/报告
#         graphics/fonts/cjk/zh-Hans.*        —— 运行时字库（FEHRR 覆盖后）
#       归档由 tools/wsl/_run_font_pipeline.sh 六步流程产出，可逐字节复现。
FONT_PATCH="$(find "$CONTENT_DIR/fonts" -maxdepth 1 -type f -name '*.tar.gz' 2>/dev/null | head -1)"
if [ -n "$FONT_PATCH" ]; then
  if [ "$DRY_RUN" = "1" ]; then
    act "[预演] 解包字库补丁 → 框架：$(basename "$FONT_PATCH")"
  else
    # 内容感知同步（2026-09-27）：旧实现 `tar xzf … -C 框架` 会**无条件重写 26 个文件**，
    # 其中含 graphics/fonts/cjk/*（CJK 字库 .2bpp/.u8）—— mtime 一变，字库对象全量重编。
    # 现在先解到临时目录，逐文件比对，只有真的不同才落盘。
    FONT_TMP="$(mktemp -d)"; tmp_track "$FONT_TMP"
    if tar xzf "$FONT_PATCH" -C "$FONT_TMP" 2>/dev/null; then
      FONT_N=0; FONT_SAME=0
      while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        if [ -f "$FRAMEWORK_DIR/$rel" ] && cmp -s "$FONT_TMP/$rel" "$FRAMEWORK_DIR/$rel"; then
          FONT_SAME=$((FONT_SAME+1)); continue
        fi
        mkdir -p "$(dirname "$FRAMEWORK_DIR/$rel")" 2>/dev/null
        cp -f "$FONT_TMP/$rel" "$FRAMEWORK_DIR/$rel" && FONT_N=$((FONT_N+1))
      done < <(cd "$FONT_TMP" && find . -type f | sed 's|^\./||')
      rm -rf "$FONT_TMP"
      if [ "$FONT_N" -eq 0 ]; then
        ok "字库补丁：$FONT_SAME 项全部与框架一致 → 0 项落盘（保 mtime，不触发重编）"
      else
        ok "字库补丁已铺设：$FONT_N 项变更 / $FONT_SAME 项一致（$(basename "$FONT_PATCH")）"
      fi
    else
      rm -rf "$FONT_TMP"
      bad "字库补丁解包失败：$FONT_PATCH"
    fi
  fi
else
  dim "content/fonts/ 无字库补丁 —— 沿用框架上游字库"
fi

# ── 3c''. 框架补丁（★ 已知偏离：本通道会覆写框架文件）──
# 仅用于「框架缺陷、且数据层修不了」的情形。当前补丁：
#   prologue/ch1-tutorial-keep-wait —— 教学关 DISABLEOPTIONS 关掉了「待機」，
#     可见菜单项归零 → Menu_OnInit 读未初始化 menuItems[] 野指针崩溃（实机已复现）。
#   weapontriangle-magic-ring —— 魔法环的【手写参考块】需与三才法环一致，
#     否则 round-trip 报 6 diagnostics。
#   shenqi-* —— 神器「不入三环」所需的属性位与三角守卫（见 docs/5 §5.8）。
#   shanhe-spell-manifest —— 往 assets/manifest.json 追加 M3④ 惊雷引的法术特效记录
#     （框架要求"清单里声明"，而清单在框架仓库内 ⇒ 只能走补丁；见 docs/5 §5.11）。
# 形式：unified diff，基线 = framework.lock 钉住的 commit。
#
# 幂等：**两阶段** —— ① 先把所有目标文件各还原一次；② 再按文件名顺序 apply。
#   ⚠️⚠️ 不能"每个补丁前各自 checkout"：同一文件有多个补丁时，后者的 checkout
#      会把前一个补丁的成果**整个抹掉**，而日志上看是"两个都成功"（静默丢补）。
#      —— 这是 2026-09-25 加第二个 bmbattle.c 补丁时实测发现的缺陷，已修。
#   apply 失败即中止（宁可不构建，也不要静默漏补）。
#   末尾校验「实际应用数 == 预期数」，避免循环体某次 continue 静默漏掉补丁。
FRAMEWORK_PATCHES="$(find "$CONTENT_DIR/framework-patch" -maxdepth 1 -type f -name '*.patch' 2>/dev/null | sort)"
if [ -n "$FRAMEWORK_PATCHES" ]; then
  PATCH_N=0
  # ★★ 硬拦：一个补丁文件只能有**一个**目标文件（2026-09-28 实测缺陷后新增）
  #   本脚本在 **5 处**用 `grep -m1 '^+++ b/'` 取补丁目标（写前快照 / 这里的还原清单 /
  #   阶段 3 的逐补丁目标 / 第 6 步反查白名单）—— `-m1` 只取**第一个**目标。
  #   ⇒ 写一个改两个文件的补丁**不会报错**，只会**静默漏掉第二个目标**：
  #      快照少记一个、RESTORE 不还原它、反查把它报成"预期外改动"（三条同时失效）。
  #   实测现场：shanhe-prologue-wiring.patch（改 eventcall.h + prologue-eventinfo.h）
  #   在反查里报 `⚠ 预期外改动：src/events/prologue-eventinfo.h`。
  #   修法 = 拆成两个单目标补丁；本闸保证下次不会再踩（把静默失败变成响亮失败）。
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    # ⚠️ grep -c 在"0 匹配"时也打印 0（只是退出码为 1）⇒ 不能写 `|| echo 0`，
    #    否则 n_t 变成 "0\n0" 让下面 -ne 比较报 "integer expression expected"
    n_t="$(grep -c '^+++ b/' "$p" 2>/dev/null)"
    [ -n "$n_t" ] || n_t=0
    if [ "$n_t" -ne 1 ]; then
      bad "[补丁] $(basename "$p") 有 $n_t 个目标文件 —— 本机制**只支持单目标补丁**"
      dim "原因：脚本 5 处用 \`grep -m1 '^+++ b/'\` 取目标，多目标会被静默漏掉"
      dim "      （快照少记 / RESTORE 不还原 / 反查误报「预期外改动」）"
      dim "修法：把该补丁按目标文件拆成多个 .patch（每个一个 '+++ b/' 行）"
      die "补丁格式不合规：$(basename "$p")（见 docs/5 §5.18.9 / docs/6 §3.4g）"
    fi
  done <<< "$FRAMEWORK_PATCHES"

  # 去重后的目标清单（同一文件多个补丁只还原一次）
  PATCH_TARGETS="$(while IFS= read -r p; do
      [ -n "$p" ] || continue
      grep -m1 '^+++ b/' "$p" 2>/dev/null | sed 's|^+++ b/||'
    done <<< "$FRAMEWORK_PATCHES" | sed '/^$/d' | sort -u)"
  n_patches=$(printf '%s\n' "$FRAMEWORK_PATCHES" | sed '/^$/d' | wc -l | tr -d ' ')
  n_targets=$(printf '%s\n' "$PATCH_TARGETS" | sed '/^$/d' | wc -l | tr -d ' ')

  if [ "$DRY_RUN" = "1" ]; then
    act "[预演] 框架补丁 $n_patches 个 → 目标文件 $n_targets 个"
    printf '%s\n' "$PATCH_TARGETS" | sed '/^$/d;s|^|      → |'
  else
    # 阶段 0：清障 —— 删掉 patch(1) 可能留下的 .rej / .orig 残留物。
    # 为什么必须做（2026-09-25 实测）：任何一次手工 `patch` 尝试（或带 fuzz 的
    # 成功应用）都会在框架侧留下 *.rej / *.orig，它们是**未被 .gitignore 覆盖的
    # 未追踪文件** ⇒ 第 6 步反查必然报「预期外改动」，训练出"忽略告警"的习惯。
    # 本步骤让"每次构建的起点"确定，反查才继续可信。
    # ⚠️ 只清 git 已追踪目录下的残留（限定到补丁目标所在目录），不碰 build/。
    while IFS= read -r junk; do
      [ -n "$junk" ] || continue
      rm -f "$junk" && dim "清障：已删除残留 ${junk#$FRAMEWORK_DIR/}"
    done < <(cd "$FRAMEWORK_DIR" && find include src tools -type f \( -name '*.rej' -o -name '*.orig' \) 2>/dev/null | sed "s|^|$FRAMEWORK_DIR/|")

    # 阶段 1：判定每个补丁的**当前状态**（只做 dry-run，不碰框架文件）
    #   · 正向可应用（patch --dry-run 成功）    → 待应用 PENDING
    #   · 反向可应用（patch -R --dry-run 成功） → 已在位（上次构建的成果还在）
    #   · 两者都失败                            → 上下文已变，必须人工 rebase
    # ★ 2026-09-27 新增这条"已在位"快路径：旧实现每次都 checkout + apply，
    #   目标文件（含 include/bmitem.h 这类被广泛包含的头）mtime 一刷新就全量重编。
    #   零内容变更的二次构建因此也要 6 分钟 —— 这是本次提速的两大来源之一
    #   （另一个是 3c 的 touch Makefile）。
    PENDING=""
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      name="$(basename "$p")"
      if ( cd "$FRAMEWORK_DIR" && patch -p1 -N --dry-run --no-backup-if-mismatch -i "$p" ) >/dev/null 2>&1; then
        PENDING="$PENDING$p"$'\n'
      elif ( cd "$FRAMEWORK_DIR" && patch -p1 -R --dry-run --no-backup-if-mismatch -i "$p" ) >/dev/null 2>&1; then
        dim "[补丁] $name 已在位（反向 dry-run 通过）"
      else
        bad "[补丁] $name 既不能正向应用、也不能反向应用"
        dim "· 上游上下文可能已变（框架 commit 漂移？）"
        dim "· 或与同文件其它补丁的上下文重叠"
        die "框架补丁状态无法判定，需人工 rebase（见 docs/6 §3.4g）"
      fi
    done <<< "$FRAMEWORK_PATCHES"

    n_pending="$(printf '%s' "$PENDING" | sed '/^$/d' | wc -l | tr -d ' ')"
    if [ "$n_pending" -eq 0 ]; then
      ok "全部 $n_patches 个框架补丁已在位 → 跳过 checkout/apply（保 mtime ⇒ 不触发重编）"
      PATCH_N=$n_patches
    else
      # 阶段 2：只还原「有待应用补丁的目标文件」，每个目标只还原一次
      RESTORE_TARGETS="$(printf '%s' "$PENDING" | sed '/^$/d' | while IFS= read -r p; do
          grep -m1 '^+++ b/' "$p" 2>/dev/null | sed 's|^+++ b/||'
        done | sed '/^$/d' | sort -u)"
      while IFS= read -r t; do
        [ -n "$t" ] || continue
        ( cd "$FRAMEWORK_DIR" && git checkout HEAD -- "$t" ) 2>/dev/null \
          || die "[补丁] 无法还原 $t（文件不存在或不在 git 追踪内）"
        dim "[补丁] 已还原 $t（确定 apply 起点）"
      done <<< "$RESTORE_TARGETS"

      # 阶段 3：重放**这些目标上的全部补丁** —— 含阶段 1 判为"已在位"的那些：
      #   它们刚被阶段 2 的还原抹掉了，不重放就会**静默丢补**。
      #   （这正是"两阶段"设计的核心：不能只重放 PENDING 的那几个。）
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        name="$(basename "$p")"
        target="$(grep -m1 '^+++ b/' "$p" 2>/dev/null | sed 's|^+++ b/||')"
        [ -n "$target" ] || die "[补丁] $name 解析不出目标文件（缺 '+++ b/<path>' 行）"
        case "$(printf '%s\n' "$RESTORE_TARGETS")" in
          *"$target"*) ;;                 # 该目标被还原过 → 必须重放
          *) continue ;;                  # 目标未动 → 保持"已在位"
        esac
        if ( cd "$FRAMEWORK_DIR" && patch -p1 -N --no-backup-if-mismatch -i "$p" ) >> "$REPORT" 2>&1; then
          ok "[补丁] $name 已重放 → $target"
        else
          bad "[补丁] $name 重放失败 —— 上游可能已改动该文件上下文，或与同文件其它补丁的上下文重叠"
          die "框架补丁无法应用，需人工 rebase（见 docs/6 §3.4g）"
        fi
      done <<< "$FRAMEWORK_PATCHES"
    fi

    # 阶段 4：**终态复核**（比"数数"更强的门禁）
    #   旧实现只校验「应用数 == 预期数」——但计数由循环自己维护，
    #   一旦某次 continue 静默跳过，计数与事实同时错、互相掩盖。
    #   改为对每个补丁跑**反向 dry-run**：能反向应用 ⇔ 确认它确实在位。
    n_notinplace=0
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      if ! ( cd "$FRAMEWORK_DIR" && patch -p1 -R --dry-run --no-backup-if-mismatch -i "$p" ) >/dev/null 2>&1; then
        bad "[补丁] $(basename "$p") 终态复核失败：不在位"
        n_notinplace=$((n_notinplace+1))
      fi
    done <<< "$FRAMEWORK_PATCHES"
    [ "$n_notinplace" -eq 0 ] || die "[补丁] $n_notinplace 个补丁未处于「已应用」终态 —— 有补丁被静默丢弃"
    PATCH_N=$n_patches
  fi
  [ "$DRY_RUN" = "1" ] || warn "★ 已应用 $PATCH_N 个框架补丁 / $n_targets 个目标文件 —— 本项目【已知偏离】，升级框架时必须重新评估"
else
  dim "content/framework-patch/ 无补丁 —— 框架保持只读（正常状态）"
fi

# ── 3d. 自定义法术特效资产铺设（M3④；★ 第 4 类已知偏离：会 git add 进框架索引）──
# 为什么必须 git add（2026-09-29 实测）：
#   框架的 custom-spell-effect 清单校验要求每个 source 被**框架仓库的 git 追踪** ——
#   scripts/assets/manifest.py:_validate_tracked_paths() 走的是
#   `git -C <框架根> ls-files`，看的是**索引**（不是提交树）。
#   而方案 B 的铺设产物天生是未追踪文件 ⇒ 会被判 "is not a tracked committed source"。
#   解法：铺完后补一次 `git add`（只动索引、不动内容），并做「追踪数 == 文件数」的终态复核。
#   详见 docs/5 §5.11。
SPELL_SRC="$CONTENT_DIR/assets/spells"
SPELL_DST_REL="graphics/custom_spell"
SPELL_PKGS="$(find "$SPELL_SRC" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)"
n_spell_pkgs=$(printf '%s\n' "$SPELL_PKGS" | sed '/^$/d' | wc -l | tr -d ' ')
if [ "$n_spell_pkgs" -gt 0 ]; then
  if [ "$DRY_RUN" = "1" ]; then
    act "[预演] 铺设 $n_spell_pkgs 个法术特效包 → $SPELL_DST_REL/<包名>/ 并 git add 进框架索引"
    printf '%s\n' "$SPELL_PKGS" | sed 's|^|      → |'
  else
    SPELL_N=0
    while IFS= read -r pkgdir; do
      [ -n "$pkgdir" ] || continue
      pkg="$(basename "$pkgdir")"
      dst="$FRAMEWORK_DIR/$SPELL_DST_REL/$pkg"

      # ① 逐文件**幂等**写入（内容一致不落盘 ⇒ mtime 不动，与 3a/3c 同一纪律）
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        rel="${f#"$pkgdir"/}"
        mkdir -p "$dst/$(dirname "$rel")"
        if write_if_changed "$dst/$rel" < "$f"; then
          dim "法术包 $pkg：写入 $rel"
        fi
      done < <(find "$pkgdir" -type f | sort)

      # ② 清掉源里已不存在的框架侧残留（保证"框架侧 == 源"严格一致）
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        rel="${f#"$dst"/}"
        if [ ! -f "$pkgdir/$rel" ]; then
          rm -f "$f" && dim "法术包 $pkg：清除残留 $rel"
        fi
      done < <(find "$dst" -type f 2>/dev/null)

      # ③ ★ 关键：让框架的 `git ls-files` 认到这些文件（清单校验的硬要求）
      ( cd "$FRAMEWORK_DIR" && git add -A "$SPELL_DST_REL/$pkg" ) \
        || die "法术包 $pkg：git add 失败（框架索引不可写）"

      # ④ 终态复核：清单校验真正看的就是 ls-files 的输出
      n_tracked="$( cd "$FRAMEWORK_DIR" && git ls-files "$SPELL_DST_REL/$pkg" | wc -l | tr -d ' ' )"
      n_files="$(find "$dst" -type f | wc -l | tr -d ' ')"
      [ "$n_tracked" = "$n_files" ] \
        || die "法术包 $pkg：框架侧追踪数 $n_tracked ≠ 文件数 $n_files（清单 sources 校验会失败）"
      SPELL_N=$((SPELL_N+1))
    done <<< "$SPELL_PKGS"
    ok "$SPELL_N 个法术特效包已铺设并登记进框架索引（$SPELL_DST_REL/；追踪数 == 文件数）"
  fi
fi

# ── 3e. 原创道具图标铺设（P0a；★ 第 5 类已知偏离：会 git add 进框架索引）──
# 机制（2026-09-29 实测，别凭直觉猜"要不要自己转 4bpp"）：
#   框架的道具图标 `graphics/item_icon/*.4bpp` **不是提交物**，而是由
#   Makefile:599 的通用模式规则 `%.4bpp: %.png  ; $(GBAGFX) $< $@` 从同名 PNG 生成，
#   且 `.gitignore:86` 忽略 `*.4bpp`。
#   仓库真正追踪的是 **PNG 源**：实测 `graphics/item_icon/` 下追踪 224 个 .png
#   + 1 个 .agbpal、**0 个 .4bpp**。
#   ⇒ 本步骤只需把内容层的 PNG 幂等铺进框架并 `git add` —— 不需要本脚本自己转
#     .4bpp，也不要往仓库里提交 .4bpp（那会与既有 224 个的来源不一致）。
#   为什么必须 git add：同法术包 —— 框架的清单/追踪校验走 `git ls-files`，
#   看的是**索引**（scripts/assets/manifest.py:_validate_tracked_paths）。
#   ⚠️ 4bpp 编码与调色板正确性由两端保证（都已实测）：
#     ① 内容层 tools/shanhe-item-icon.py 的 check/verify：PLTE 与共享调色板逐项一致、
#        4bpp 往返恒等、交付 PNG 读回索引矩阵与原矩阵逐格一致；
#     ② 构建期用框架自己的 gbagfx 转出的 .4bpp 与工具预期**逐字节一致**，
#        且对既有 item_icon_sword_rapier.png 复现出仓库既有的 .4bpp（对照组）。
#   ⚠️ 新增图标是**追加**在 4bpp 声明块末尾 ⇒ 只有新道具的 iconId 会变，
#      既有 224 个索引一个都不动（插入中间会让其后图标集体错位）。
#   RESTORE 无需为本步骤额外写清理：`git restore --source=HEAD --staged --worktree .`
#   本身就会把"索引里新增、HEAD 里没有"的 PNG 一并删掉（同法术包，见 RESTORE 段的勘误）。
ICON_SRC="$CONTENT_DIR/assets/icons"
ICON_DST_REL="graphics/item_icon"
ICON_PNGS="$(find "$ICON_SRC" -maxdepth 1 -type f -name '*.png' 2>/dev/null | sort)"
n_icons=$(printf '%s\n' "$ICON_PNGS" | sed '/^$/d' | wc -l | tr -d ' ')
if [ "$n_icons" -gt 0 ]; then
  if [ "$DRY_RUN" = "1" ]; then
    act "[预演] 铺设 $n_icons 个道具图标 PNG → $ICON_DST_REL/ 并 git add 进框架索引"
    printf '%s\n' "$ICON_PNGS" | sed 's|^|      → |'
  else
    ICON_N=0
    while IFS= read -r srcpng; do
      [ -n "$srcpng" ] || continue
      base="$(basename "$srcpng")"
      if write_if_changed "$FRAMEWORK_DIR/$ICON_DST_REL/$base" < "$srcpng"; then
        dim "图标：写入 $base"
      fi
      # ★ 让框架的 `git ls-files` 认到它（追踪校验的硬要求）
      ( cd "$FRAMEWORK_DIR" && git add "$ICON_DST_REL/$base" ) \
        || die "图标 $base：git add 失败（框架索引不可写）"
      ( cd "$FRAMEWORK_DIR" && git ls-files --error-unmatch "$ICON_DST_REL/$base" ) >/dev/null 2>&1 \
        || die "图标 $base：git ls-files 不认识它（框架追踪校验会失败）"
      ICON_N=$((ICON_N+1))
    done <<< "$ICON_PNGS"
    ok "$ICON_N 个道具图标已铺设并登记进框架索引（$ICON_DST_REL/；.4bpp 由 make 从 PNG 生成）"
  fi
fi

# ── 3f. 章节地图 TMX 铺设（T3；★ 会 git add 进框架索引）──
# 机制（2026-09-29，框架 docs/tmx_map_layouts.md / Issue #64 `tiled-tmx-map-layout`）：
#   章节地图走**编译期 TMX 适配器**：`assets/tmx/<名>.tmx` 必须满足 `tmx-safe-v1`
#   （单图层 `id=1 name="Main"`、CSV 无压缩、内联 tileset
#     `firstgid=1 name="fe8-metatiles-16px-4096" tilecount=4096 columns=64`、
#     GID 1..4096 且 `gid-1` = FE8 13 位元瓦片 id、禁对象层/属性/外部 TSX）。
#   注册面**只有** `assets/manifest.json` 的 `tiled-tmx-map-layout` 记录
#   （框架原话 "The manifest is the only registration surface"）——
#   由 `content/framework-patch/shanhe-prologue-map.patch` 提供。
#   ⚠️ 必须 git add：manifest 的 `sources` 要能被 `git ls-files` 追踪
#      （与法术包 / 道具图标同一类已知偏离）。
TMX_SRC="$CONTENT_DIR/assets/tmx"
TMX_DST_REL="assets/tmx"
TMX_FILES="$(find "$TMX_SRC" -maxdepth 1 -type f -name '*.tmx' 2>/dev/null | sort)"
n_tmx=$(printf '%s\n' "$TMX_FILES" | sed '/^$/d' | wc -l | tr -d ' ')
if [ "$n_tmx" -gt 0 ]; then
  if [ "$DRY_RUN" = "1" ]; then
    act "[预演] 铺设 $n_tmx 个章节地图 TMX → $TMX_DST_REL/ 并 git add 进框架索引"
    printf '%s\n' "$TMX_FILES" | sed 's|^|      → |'
  else
    TMX_N=0
    TMX_CHANGED=0
    while IFS= read -r ts; do
      [ -n "$ts" ] || continue
      base="$(basename "$ts")"
      if write_if_changed "$FRAMEWORK_DIR/$TMX_DST_REL/$base" < "$ts"; then
        dim "地图：写入 $base"
        TMX_CHANGED=1
      fi
      ( cd "$FRAMEWORK_DIR" && git add -- "$TMX_DST_REL/$base" ) 2>/dev/null \
        || die "地图 TMX 无法 git add：$TMX_DST_REL/$base"
      TMX_N=$((TMX_N+1))
    done <<< "$TMX_FILES"
    # ★ TMX 变了就必须重跑框架的资产四动词（2026-09-29 实测踩到）：
    #   `build/generated/assets/tmx/<id>.mar` 是由 `make assets-generate` 生成的，
    #   而 `const_data_chapter_maps.c` 里的 `INCBIN_U8` 指向由它转出的 `.bin.lz`。
    #   只改 TMX 不重跑 ⇒ 内嵌的还是**上一次**的 payload ⇒ 地图看起来没变/花屏。
    #   框架文档的原话工作流就是「Run make assets-validate assets-generate assets-check
    #   assets-test, then the supported modern build profile」。
    #   ⚠️ 跳过 assets-test：它断言的是**未改动的默认 manifest**，我们改 manifest 接入地图
    #      必然让它红（实测 126 项里 11 失败/3 错误，全部在 test_custom_spell / test_manifest），
    #      属预期副作用，且它不在构建链上。
    if [ "$TMX_CHANGED" = "1" ] && [ "$SKIP_BUILD" != "1" ]; then
      act "地图 TMX 有变化 → 重跑框架资产管线（assets-validate/generate/check）…"
      if ( cd "$FRAMEWORK_DIR" && make assets-validate assets-generate assets-check \
             ${MAKE_VARS:+$MAKE_VARS} ) > "$LOG_DIR/assets-$STAMP.log" 2>&1; then
        ok "地图资产已重新生成（日志：$LOG_DIR/assets-$STAMP.log）"
      else
        bad "地图资产重新生成失败"
        tail -12 "$LOG_DIR/assets-$STAMP.log" | sed 's/^/      /'
        die "TMX 变更未落地（见上方 make 输出）"
      fi
    elif [ "$TMX_CHANGED" = "1" ]; then
      warn "地图 TMX 有变化，但 SKIP_BUILD=1 ⇒ 跳过资产重新生成（下次完整构建会做）"
    fi
    if git -C "$FRAMEWORK_DIR" diff --cached --quiet -- "$TMX_DST_REL"; then
      dim "地图：$TMX_N 个 TMX 已在框架索引中（内容未变）"
    else
      ok "地图：$TMX_N 个 TMX 已铺设并登记进框架索引（$TMX_DST_REL/）"
    fi
  fi
else
  dim "content/assets/tmx/ 为空 —— 无自绘章节地图（可选）"
fi

# ── 3d'. 其它资产提示（未接线的资产种类）──
if [ -d "$CONTENT_DIR/assets" ] \
   && [ -n "$(find "$CONTENT_DIR/assets" -type f -not -path '*/spells/*' -not -path '*/icons/*' -not -name '.gitkeep' 2>/dev/null)" ]; then
  warn "content/assets/ 下还有非 spells/ 、非 icons/ 的资产 —— 需按其「拥有缝」登记（见 docs/8），"
  dim "当前脚本只铺 spells/（自定义法术特效）与 icons/（原创道具图标）；其余仍走四动词管线：make assets-validate/-generate/-check/-test"
fi

act "铺设完成：合并/铺设 $MERGED_COUNT 项，跳过 $SKIPPED_COUNT 项"

# ══════════════════════════════════════════
# 第 4 步 · 构建
# ══════════════════════════════════════════
H "第 4 步 / 构建"

if [ "$DRY_RUN" = "1" ]; then
  act "[预演] 将执行：cd $FRAMEWORK_DIR && make $MAKE_TARGET ${MAKE_VARS:+$MAKE_VARS }"
  dim "（含宿主机工具保障：tools/{aif2pcm,bin2c,gbagfx,jsonproc,mid2agb,preproc,scaninc,textencode}）"
elif [ "$SKIP_BUILD" = "1" ]; then
  warn "SKIP_BUILD=1 —— 跳过构建"
else
  # 宿主机工具预构建（头号真凶，见 docs/7）
  act "预构建宿主机工具（8 个）…"
  for d in aif2pcm bin2c gbagfx jsonproc mid2agb preproc scaninc textencode; do
    if [ -d "$FRAMEWORK_DIR/tools/$d" ] && [ ! -x "$FRAMEWORK_DIR/tools/$d/$d" ]; then
      make -C "$FRAMEWORK_DIR/tools/$d" >/dev/null 2>&1 \
        && dim "tools/$d ✓" || warn "tools/$d 构建失败（可能不影响）"
    fi
  done
  ok "宿主机工具就绪"

  BUILD_LOG="$LOG_DIR/build-$STAMP.log"
  PROG_FILE="$LOG_DIR/.build-progress"
  : > "$BUILD_LOG"
  : > "$PROG_FILE"

  if [ -n "$MAKE_VARS" ]; then
    act "make $MAKE_TARGET $MAKE_VARS"
  else
    act "make $MAKE_TARGET"
  fi
  dim "完整日志：$BUILD_LOG"
  dim "实时进度档：$PROG_FILE"
  dim "          ↑ 另开终端 tail -f $PROG_FILE 可实时跟（本终端不刷屏时用这个）"
  dim "控制台只显示进度里程碑 + 编译计数（每 25 个源文件）+ 警告/错误，其余过滤"
  dim "⚠️ 进度打到**运行本脚本的终端**的 stdout；若被 > file / | tee 重定向走，终端就只剩最后一行"
  dim "⚠️ 前 ~60 秒无 [编译 N]：那是 locale 目录/资源生成阶段（心跳只显示「日志静默 Ns」，不是卡死）"
  dim "每 20 秒一次心跳：已运行时长 / 日志静默时长 / 当前进度"
  dim "背景知识：框架自身**没有**任何 (n/m) 进度输出（实测原始日志仅 1 条计数行），"
  dim "          所以编译器调用次数是我们自己合成的进度信号（全量约 492 个 .c）"
  dim "每次完整构建都会全量重编 492 个 .c（≈220s）。原因已查明但**未修复**："
  dim "          框架 5 组生成物挂在 phony FORCE_* 目标上，见 docs/5 §9.0 第 10 条"

  # 超时兜底（2026-09-27 新增）：构建**不许无限期挂着**。
  #   教训：第 5 步 ④ 曾因 `timeout` 不带 `-k` 而无限等待（mgba 捕获 SIGTERM 不退出），
  #   实测卡 16 分钟。此处对 make 也上双保险：`-k 15` 保证 15 秒后 SIGKILL 收尾。
  #   默认 30 分钟，可用 BUILD_TIMEOUT=<秒> 覆盖。
  BUILD_TIMEOUT="${BUILD_TIMEOUT:-1800}"
  BUILD_START="$(date +%s)"

  # 心跳：日志静默时长是区分「在跑」与「卡住」的唯一客观判据。
  #   进度来源是 awk 阶段写出的 $PROG_FILE（不能 tail 原始日志：末行常是
  #   gcc 命令行或箭头行，对用户没有任何信息量）。
  (
    while sleep 20; do
      _now="$(date +%s)"; _el=$((_now - BUILD_START))
      _last="$(stat -c %Y "$BUILD_LOG" 2>/dev/null || echo "$_now")"
      _quiet=$((_now - _last))
      _mark=""
      if [ "$_quiet" -ge 180 ]; then _mark="  ${c_red}← 疑似卡死（${_quiet}s 无输出）${c_off}"; fi
      printf "      %s[%4ds] 构建中… 日志静默 %ss │ %s%s%s\n" \
        "$c_dim" "$_el" "$_quiet" \
        "$(tail -n1 "$PROG_FILE" 2>/dev/null | tr -d '\r' | cut -c1-72)" "$_mark" "$c_off"
    done
  ) &
  HB_PID=$!
  trap 'kill "$HB_PID" 2>/dev/null' EXIT

  ( cd "$FRAMEWORK_DIR" && timeout -k 15 "$BUILD_TIMEOUT" make "$MAKE_TARGET" $MAKE_VARS ) 2>&1 \
    | stdbuf -oL -eL tee "$BUILD_LOG" \
    | awk -v prog="$PROG_FILE" '
        # 显式 fflush：awk 的 stdout 是管道（非 tty）时默认**块缓冲**，
        # 实测进度要到 60s 后首块满 4KB 才出现，心跳因此一直读到空进度。
        function emit(s)  { printf "  %s\n", s; fflush() }
        function emitp(s) { printf "  %s\n", s; printf "%s\n", substr(s, 1, 110) > prog; fflush() }
        {
          line = $0
          sub(/\r$/, "", line)

          # ① 编译器调用行：既是噪声（一次全量构建 492 条，每条约 1.5KB）也是
          #    **唯一的进度信号**（框架不发 (n/m)）。抽源文件名，每 25 条打一次。
          if (line ~ /^"?(\/usr\/bin\/env )?arm-none-eabi-(gcc|g\+\+)/) {
            cc++
            want = ""
            # 注意：这里**不能**用 \b 收尾——gawk 会把 \b 解释成退格符 0x08，
            # 导致所有匹配失败（实测踩过，表现为全部输出 "(源文件未知)"）。
            if (match(line, /[A-Za-z0-9_\/.-]*\/[A-Za-z0-9_.-]+\.c/)) {
              want = substr(line, RSTART, RLENGTH); sub(/^.*\//, "", want)
            }
            if (want == "") want = "(源文件未知)"
            if (cc == 1 || cc % 25 == 0) emitp(sprintf("[编译 %d] %s", cc, want))
            next
          }
          # 其它工具调用行：纯噪声
          if (line ~ /^"?(\/usr\/bin\/env )?(arm-none-eabi-|python3|\.\/tools\/)/) next

          # ② make 目录进出 / 循环依赖 / 子 make 提示：纯噪声
          if (line ~ /^make(\[[0-9]+\])?: (Entering|Leaving) directory/) next

          # ③ 形如 (1234/1481) 的计数行：若上游某天加了进度输出，每 50 条或末条打一次
          if (match(line, /\(([0-9]+)\/([0-9]+)\)/)) {
            seg = substr(line, RSTART+1, RLENGTH-2)
            split(seg, a, "/")
            n = a[1] + 0; m = a[2] + 0
            if (m > 0 && (n == m || n % 50 == 0)) emit(sprintf("[%d/%d] %s", n, m, substr(line, 1, 118)))
            next
          }

          # ④ warning / error：必须排在"诊断上下文行"规则之前，否则 warning 正文
          #    行（形如 src/x.c:39:19: warning: ...）会先被当作诊断行丢掉。
          if (line ~ /warning:/) { w++; if (w <= 6) emit(sprintf("! %s", substr(line, 1, 138))); next }
          if (line ~ /error:|Error [0-9]+|\*\*\* \[/) { e++; emit(sprintf("X %s", substr(line, 1, 158))); next }

          # ⑤ "已是最新 / 跳过"：计数，不打行（实测一次全量构建 ~500 行）
          if (line ~ /(^up to date: |^up-to-date |)is up to date\.$/) { upto++; next }
          if (line ~ /^up to date: /) { upto++; next }
          if (line ~ /^up-to-date /) { upto++; next }
          if (line ~ /Circular .* dependency dropped\.$/) { circ++; next }
          if (line ~ /^make\[[0-9]+\]: /) next

          # ⑥ 编译器诊断的上下文/引用行：整类丢弃。GCC 13/14 的现代诊断格式会成片
          #    输出（实测一次全量构建 ~5000 行），它们不提供进度信息：
          #      "In file included from ..."      / "In function 'x',"
          #      "    inlined from ..."           / "src/x.c: In function 'y':"
          #      "src/x.c: At top level:"         / "include/z.h:869:61: note: ..."
          #      "   13 |  code"  / "      |  ^~~" / "                   from x.h:8,"
          if (line ~ /^In (function|file|member|constructor|destructor|lambda) /) next
          if (line ~ /^ *inlined from /) next
          if (line ~ /note:/) next
          if (line ~ /: In function /) next
          if (line ~ /: At top level:$/) next
          if (line ~ /^ *from [A-Za-z0-9_\/.-]+:[0-9]/) next
          if (line ~ /Assembler messages:$/) next
          if (line ~ /^ *[0-9]+ \|/) next
          if (line ~ /^ *\|/) next
          if (line ~ /^ *\^/) next
          if (line ~ /^ *~/) next
          if (line ~ /^[A-Za-z0-9_.\/-]+\.(c|h|cc|cpp|S|s):[0-9]+(:[0-9]+)?:/) next
          # 生成器多行参数续行（以 Tab 或对齐空格起首的 --xxx 参数）
          if (line ~ /^[ \t]+--[a-z-]+ /) next
          if (line ~ /^[ \t]+--[a-z-]+$/) next

          # ⑦ 其余（阶段里程碑 / OK: / 链接 / ROM 头 / 其它）：原样但截断
          if (line ~ /^[ \t]*$/) next
          emitp(substr(line, 1, 160))
        }
        END {
          emit(sprintf("---- 编译汇总：%d 个 .c 已编译、%d 个目标已最新、%d 条循环依赖、%d 条警告、%d 条错误 ----", cc + 0, upto + 0, circ + 0, w + 0, e + 0))
          printf "[完成] 编译 %d 个 .c / 警告 %d / 错误 %d\n", cc + 0, w + 0, e + 0 > prog
          fflush()
        }'
  RC=${PIPESTATUS[0]}

  kill "$HB_PID" 2>/dev/null
  trap - EXIT
  BUILD_SECS=$(( $(date +%s) - BUILD_START ))

  if [ $RC -eq 0 ]; then
    ok "构建成功（耗时 ${BUILD_SECS}s）"
  elif [ $RC -eq 124 ] || [ $RC -eq 137 ]; then
    bad "构建超时（exit $RC，上限 ${BUILD_TIMEOUT}s）—— 疑似卡死"
    dim "最后 25 行日志："
    tail -25 "$BUILD_LOG" | sed 's/^/      /'
    dim "完整日志：$BUILD_LOG"
    die "构建超时，未进行后续验证（可加大 BUILD_TIMEOUT=<秒> 后重试）"
  else
    bad "构建失败（exit $RC，耗时 ${BUILD_SECS}s）"
    # 失败时先给"可读的失败摘要"，再给原始尾部（原始尾部常是箭头行/命令行，不可读）
    _ERRS="$(grep -nE 'error:|\*\*\* |Error [0-9]+|undefined reference|No rule to make' "$BUILD_LOG" | tail -25)"
    if [ -n "$_ERRS" ]; then
      dim "错误相关行（最多 25 条）："
      printf '%s\n' "$_ERRS" | sed 's/^/      /'
    fi
    dim "原始日志最后 25 行："
    tail -25 "$BUILD_LOG" | sed 's/^/      /'
    dim "完整日志：$BUILD_LOG"
    die "构建失败"
  fi
fi

# ══════════════════════════════════════════
# 第 5 步 · 验产物（自建五项，不用上游 boot-check）
# ══════════════════════════════════════════
H "第 5 步 / 验产物（自建校验）"

if [ "$DRY_RUN" = "1" ] || [ "$SKIP_BUILD" = "1" ]; then
  act "[跳过] 未构建，不验产物"
else
  # ① ROM 存在
  if [ -f "$FRAMEWORK_ROM" ]; then
    ok "① ROM 存在：$FRAMEWORK_ROM"
  else
    die "① ROM 不存在：$FRAMEWORK_ROM"
  fi

  # ② 尺寸
  SIZE="$(stat -c %s "$FRAMEWORK_ROM" 2>/dev/null)"
  if [ "$SIZE" = "$ROM_BYTES" ]; then
    ok "② 尺寸正确：$SIZE 字节（$(lock_get build rom_size_label)）"
  else
    die "② 尺寸错误：$SIZE（期望 $ROM_BYTES）"
  fi

  # ③ header
  TITLE="$(dd if="$FRAMEWORK_ROM" bs=1 skip=160 count=12 2>/dev/null | tr -d '\0')"
  CODE="$(dd if="$FRAMEWORK_ROM" bs=1 skip=172 count=4 2>/dev/null | tr -d '\0')"
  if [ "$TITLE" = "$TITLE_EXPECT" ] && [ "$CODE" = "$CODE_EXPECT" ]; then
    ok "③ header 正确：'$TITLE' / '$CODE'"
  else
    die "③ header 错误：'$TITLE' / '$CODE'（期望 '$TITLE_EXPECT' / '$CODE_EXPECT'）"
  fi

  # ④ 可引导（无头采集，不比对像素）
  # ⚠️ 2026-09-27 **二次**修正 —— 本项前后踩了同一个坑的两层：
  #   1) Ubuntu 24.04 的 apt 包 `mgba-sdl` 提供的二进制名是 **`mgba`**（不叫 `mgba-sdl`），
  #      旧写法 `command -v mgba-sdl` 永远落空 ⇒ 本项被静默跳过，"五项自检"实际只跑四项。
  #   2) 修好探测后暴露更严重的：`timeout 12 mgba -l 0 -C frames=60 <rom>` **永久挂起**。
  #      根因（实测）：mgba 注册了 SIGTERM 处理器（/proc/<pid>/status 的 SigCgt 含 bit15），
  #      收到 TERM 后不退出，而 `timeout` **不带 `-k`** 就无限期等下去。
  #      实测对照：`timeout 12 …` 卡住 16 分钟未返回；`timeout -k 3 10 …` 10 秒按时结束。
  #      且 `-C frames=60` 对 mgba-sdl 无效（它不会跑满 60 帧自己退出）——
  #      这条路径无论如何都只能靠超时强杀，**"跑完了没有"根本没有证据**。
  #   3) 因此改用**框架自带的无头通道** `tools/gba-playtest/gba_playtest.py capture`
  #      —— 与上游 boot-check 同一后端：真无头、约 2 秒完成、rc=0 才算数。
  #      它**只采集不比对**指纹，所以不会因中文化而误报（这正是第 5 步不用
  #      `expansion-modern-boot-check` 的原因，见 docs/6 §3.1）。
  #   4) 附带好处：采集 JSON 里带模拟器**自读**的 rom.sha1/size/title/game_code，
  #      可交叉核对 ②③ —— 比 `dd` 读头上更强（那是另一条独立路径的读数）。
  BOOT_JSON="$(mktemp -t shanhe-boot-XXXXXX.json 2>/dev/null)"; tmp_track "$BOOT_JSON"
  BOOT_RC=127
  if [ -f "$FRAMEWORK_DIR/tools/gba-playtest/gba_playtest.py" ] && \
     [ -f "$FRAMEWORK_DIR/tools/gba-playtest/scenarios/boot.json" ]; then
    ( cd "$FRAMEWORK_DIR" && timeout -k 5 120 python3 tools/gba-playtest/gba_playtest.py capture \
        --rom "$ROM_REL" \
        --scenario tools/gba-playtest/scenarios/boot.json \
        --output "$BOOT_JSON" ) >/dev/null 2>&1
    BOOT_RC=$?
  fi
  BOOT_SUM=""; PY_RC=0
  if [ "$BOOT_RC" = "0" ] && [ -s "$BOOT_JSON" ]; then
    # 退出码语义：3=检查点不足 4=尺寸不符 5=title/game_code 不符 6=三帧画面全同
    BOOT_SUM="$(python3 - "$BOOT_JSON" "$ROM_BYTES" "$TITLE_EXPECT" "$CODE_EXPECT" <<'PY' 2>/dev/null
import json, sys
path, want_size, want_title, want_code = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
d = json.load(open(path))
rom, cps = d.get("rom", {}), d.get("checkpoints", [])
if len(cps) < 3: sys.exit(3)
if rom.get("size") != want_size: sys.exit(4)
if rom.get("title") != want_title or rom.get("game_code") != want_code: sys.exit(5)
# 负向测试发现（2026-09-27）：截断成 1MB 的 ROM 喂给 capture 仍返回 rc=0，
# 三个检查点的 framebuffer_hash 全部相同（画面从未推进）。只信 rc 会被骗过。
if cps[0].get("framebuffer_hash") == cps[-1].get("framebuffer_hash"): sys.exit(6)
print("%s|%d" % (str(rom.get("sha1", "?"))[:8], len(cps)))
PY
)"
    PY_RC=$?
  fi
  if [ -n "$BOOT_SUM" ]; then
    ok "④ 可引导（官方无头采集：${BOOT_SUM##*|} 个检查点跑通、画面确有推进，ROM ${BOOT_SUM%%|*}；模拟器自读 size/title/code 与 ②③ 一致；不比对像素）"
  elif [ "$BOOT_RC" = "127" ]; then
    warn "④ 未找到框架无头采集工具（tools/gba-playtest/…）—— 跳过（Windows 侧用 mGBA 目视）"
  elif [ "$BOOT_RC" != "0" ]; then
    warn "④ 无头采集未通过（rc=$BOOT_RC）—— 建议 Windows 侧用 mGBA 目视确认"
  else
    warn "④ 采集输出校验失败（python rc=$PY_RC：3=检查点不足 4=尺寸不符 5=header 不符 6=三帧画面全同/疑似卡死）"
  fi
  rm -f "$BOOT_JSON" 2>/dev/null

  # ⑤ 中文 locale 资源**真的**进 ROM 了吗
  # ⚠️ 2026-09-27 加强：旧写法只断言 `ROM 尺寸 > 20000000` —— 但 ② 已经断言过尺寸，
  #    于是 ⑤ 变成同义反复（"32M ⇒ 一定有中文"是**推断**，不是**证据**：
  #    只要 pad 到 32M 就会通过，哪怕 locale 资源一个字都没链进去）。
  #    改为直接查 ELF 的 `.locale_data` 段，并回到 ROM 里读该偏移的字节：
  #    该段落在 0x09000000（= 16MB 边界之后的上位 ROM bank，即框架所说的
  #    "dedicated upper-ROM locale bank"），用 0xFF 填充的空 bank 与真资源可区分。
  #    实测本机：.locale_data @0x1001000，1,407,972 字节（≈1.4MB，与 docs/5 §3.5 相符）。
  ELF_PATH="${FRAMEWORK_DIR}/${ROM_REL%.gba}.elf"
  LOC_SEC=""
  if [ -f "$ELF_PATH" ] && command -v arm-none-eabi-readelf >/dev/null 2>&1; then
    LOC_SEC="$(arm-none-eabi-readelf -S "$ELF_PATH" 2>/dev/null | awk '$2==".locale_data"{print $5" "$6; exit}')"
  fi
  if [ -n "$LOC_SEC" ]; then
    LOC_OFF="${LOC_SEC%% *}"; LOC_LEN="${LOC_SEC##* }"
    LOC_HEAD="$(dd if="$FRAMEWORK_ROM" bs=1 skip=$((16#$LOC_OFF)) count=16 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    if [ -z "$LOC_HEAD" ] || [ "$LOC_HEAD" = "ffffffffffffffffffffffffffffffff" ]; then
      warn "⑤ .locale_data 段在 ROM 里是空的（$LOC_LEN 字节全 0xFF）—— 中文本地化资源没链进去，请检查 EXPANSION_ENABLED_LOCALES"
    else
      ok "⑤ 中文本地化资源已进 ROM：.locale_data @0x$LOC_OFF，$((16#$LOC_LEN)) 字节（首 16 字节 ${LOC_HEAD}）—— 可用 mGBA 目视确认汉字"
    fi
  else
    warn "⑤ 读不到 .locale_data 段（缺 ELF 或缺 arm-none-eabi-readelf）—— 跳过；建议用 mGBA 目视确认汉字"
  fi

  # ⑥ 扩展道具的显示名必须真实可达（2026-09-29 新增）
  # ⚠️ 这条断言是为一个**已发生**的实机缺陷加的，不是预防性完备：
  #    玩家原话："主角背包里面没有照夜，而且突刺剑名字还没了"。
  #    根因：扩展槽道具（0xCE/0xCF）当时只有 authoringName —— 而那条通道
  #    **只在 EXPANSION_STARTER_CONTENT=1 档**才生成可得名字表，本项目不开该开关；
  #    实测 gItemData[0xCE/0xCF].nameTextId 都是 0x0000 ⇒ GetItemName() 的 vanilla
  #    回落取到空消息 ⇒ 背包里一片空白（原突刺剑槽位现在装着照夜，两个都空白）。
  #    当时的验收只核对**数值字段**（might/hit/uses/…），正好从 nameTextId
  #    （u16 = 0）上读过去 —— 数值全对，玩家什么都看不到。
  #
  #    这条断言把「玩家看到的那几个字」全链路钉死（详见工具头注释的 A–E）：
  #      A 内容声明(items_expansion.json) → B seam 映射(src/shanhe_item_names.c)
  #      → C 扩展文本目录(texts/expansion/*) → D ROM 字节(gItemData + 名字 utf8)
  #      → E 调用点(bmitem.c 两处 + msg.c 一处)
  #    其中 D3「gItemData 全表 .number == 下标」同时**证明** stride/字段偏移可信，
  #    避免用错的偏移去读 nameTextId 而自证清白。D6 要求名字的 UTF-8 字节真的
  #    出现在 ROM 里（CJK 语言下还要求名字含非 ASCII 字符，防止用英文占位符蒙混）。
  #
  #    负向测试（2026-09-29）：喂「只有 authoringName、没有 seam 表」→ 精确报
  #    B0/B3；喂「注册表缺 key」→ 报 C3；喂旧 ROM（名字未链接）→ 报 D6。均 rc=2。
  if [ -f "$REPO_ROOT/tools/shanhe-namecheck.py" ]; then
    if python3 "$REPO_ROOT/tools/shanhe-namecheck.py" \
         --content "$CONTENT_DIR" --framework "$FRAMEWORK_DIR" --rom "$FRAMEWORK_ROM" \
         >> "$REPORT" 2>&1; then
      ok "⑥ 扩展道具显示名已断言（内容 → seam 表 → 扩展文本目录 → ROM 字节，含 gItemData 布局自证）"
    else
      bad "⑥ 扩展道具显示名断言失败"
      grep -E '✗|断言 ' "$REPORT" | tail -8 | sed 's/^/      /'
      die "⑥ 扩展道具必须有真实可达的显示名（见 tools/shanhe-namecheck.py 头注释）"
    fi
  else
    warn "⑥ 缺 tools/shanhe-namecheck.py —— 跳过（不建议：这类缺陷数值检查抓不到）"
  fi

  # ⑦ HOOKS seam 回归（2026-09-28 新增，M3 验收第 4 条的结项依据）
  # ⚠️ 这条断言替换的是验收表里那句**不成立**的措辞「HOOKS=0 时战斗数学与原版
  #    **字节一致**」。两处硬证据推翻了它：
  #      ① 上游 src/bmbattle.c:514-523 的注释自己写着 "stat identity, **not a
  #         ROM-byte claim**" —— 框架承诺的是数值恒等，并明确否认字节口径；
  #      ② 本项目对 bmbattle.c 有**永久**补丁（IA_SHENQI 守卫、破军追击 +3），
  #         由 HOOKS 开关管不到 ⇒ "与上游字节一致"逻辑上不可能。
  #    所以改成三条可断言命题（工具头注释有完整推导）：
  #      A 门在工作：HOOKS=1 时 seam 只在 ComputeBattleUnitStats 里被调 1 次；
  #      B 门关得死：HOOKS=0 时全表对 ExpansionMechanics* 零引用；
  #      C 偏离可枚举：HOOKS=0 与**钉住上游**同档编译后，
  #        C1 ComputeBattleUnitStats 逐字节相同（数值恒等的直接证据）、
  #        C2 变化的节**恰好等于补丁文件自己声明的那些函数**（双向吻合）。
  #    取证方式不是重跑构建，而是**重放**日志里那条真实的 arm-none-eabi-gcc
  #    命令行，并先用 R1「重放对象 == 真实 bmbattle.o 逐字节」自校验配方保真。
  #    （R-29 的教训：读源码常量不算数，要读构建产物。）
  #    缺前置（无构建日志 / 无 ARM 工具链）时只 warn 不阻断 —— 本机是有的；
  #    显式关闭：HOOKS_REGRESSION=0。
  if [ "${HOOKS_REGRESSION:-1}" = "1" ] && [ -f "$REPO_ROOT/tools/shanhe-hooks-regression.py" ]; then
    HOOKS_RC=0
    python3 "$REPO_ROOT/tools/shanhe-hooks-regression.py" \
      --repo "$REPO_ROOT" --framework "$FRAMEWORK_DIR" --logs-dir "$LOG_DIR" \
      >> "$REPORT" 2>&1 || HOOKS_RC=$?
    case "$HOOKS_RC" in
      0)
        ok "⑦ HOOKS seam 回归全绿（重放保真 / 门在工作 / 门关得死 / 战斗数值恒等 / 偏离可枚举）"
        ;;
      3)
        warn "⑦ HOOKS seam 回归前置缺失（缺构建日志或 ARM 工具链）—— 跳过；不影响产物正确性"
        ;;
      *)
        bad "⑦ HOOKS seam 回归失败（rc=$HOOKS_RC）"
        grep -E '✗' "$REPORT" | tail -6 | sed 's/^/      /'
        die "⑦ 战斗数值恒等的门禁被破坏（见 tools/shanhe-hooks-regression.py 头注释）"
        ;;
    esac
  else
    warn "⑦ HOOKS seam 回归被跳过（HOOKS_REGRESSION=0 或缺工具）—— M3 验收第 4 条将无凭据"
  fi

  ROM_SHA1="$(sha1sum "$FRAMEWORK_ROM" | cut -c1-8)"
  act "产物 SHA1（前 8 位）：$ROM_SHA1  ·  基线中文版：$(lock_get baseline baseline_cn_rom_sha1)"
  dim "改内容后 SHA1 本就该变 —— 这一步是记录，不是门禁"
fi

# ══════════════════════════════════════════
# 第 5b 步 · 导出 ROM 到 Windows 侧（方便直接试玩）
# ══════════════════════════════════════════
H "第 5b 步 / 导出 ROM 到 Windows 侧"

# 目标目录：本仓库内的 shanhe-rom/（2026-09-27 起 ROM 产物收进任务根内）
#   Windows 视角：D:\workbuddy\Fire-Emblem-Realm-in-Ashes\shanhe-rom
#   WSL   视角：/mnt/d/workbuddy/Fire-Emblem-Realm-in-Ashes/shanhe-rom
# 写绝对路径而非 $REPO_ROOT，是为了让导出不依赖 ~/FEHRR 符号链接是否存在。
EXPORT_DIR="${SHANHE_ROM_DIR:-/mnt/d/workbuddy/Fire-Emblem-Realm-in-Ashes/shanhe-rom}"
# Windows 视角路径：自动换算，避免提示文案与实际目录漂移
EXPORT_DIR_WIN="$(wslpath -w "$EXPORT_DIR" 2>/dev/null || printf '%s' "$EXPORT_DIR")"
# 文件名派生自 lock 的 rom_size_label（32M → shanhe-cn-32m.gba），
# 与 `启动山河烬中文版.cmd` 里写死的路径保持一致。
ROM_LABEL="$(lock_get build rom_size_label)"; ROM_LABEL="${ROM_LABEL:-32M}"
EXPORT_NAME="shanhe-cn-$(printf '%s' "$ROM_LABEL" | tr 'A-Z' 'a-z').gba"
EXPORT_PATH="$EXPORT_DIR/$EXPORT_NAME"

if [ "$DRY_RUN" = "1" ]; then
  act "[预演] 将复制产物 → $EXPORT_PATH"
elif [ ! -f "$FRAMEWORK_ROM" ]; then
  warn "产物不存在，跳过导出"
elif ! mkdir -p "$EXPORT_DIR" 2>/dev/null; then
  warn "无法创建导出目录：$EXPORT_DIR（跳过导出）"
else
  # ⚠️ 2026-09-25 实机教训：mGBA 开着会独占锁住 .gba，`cp` 静默失败；
  #    旧逻辑只 warn，于是「完成」照打，而试玩目录留着**上一版 ROM** ——
  #    后续所有「实机验证」都变成对旧版的验证（白白浪费一轮）。
  #    ⇒ 重试 + 校验 SHA1 + 失败即中止构建（宁可不"完成"，也不要假验证）。
  EXPORT_OK=0
  for attempt in 1 2 3; do
    rm -f "$EXPORT_PATH" 2>/dev/null
    if cp -f "$FRAMEWORK_ROM" "$EXPORT_PATH" 2>/dev/null; then EXPORT_OK=1; break; fi
    [ "$attempt" -lt 3 ] && { dim "第 $attempt 次导出失败（可能被占用），2 秒后重试…"; sleep 2; }
  done

  if [ "$EXPORT_OK" != "1" ]; then
    bad "导出失败：$EXPORT_PATH"
    dim "手动复制：cp \"$FRAMEWORK_ROM\" \"$EXPORT_PATH\""
    die "试玩目录 ROM 未更新 —— 很可能 mGBA 正开着锁住文件。请关闭 mGBA 后重跑，否则你会拿旧 ROM 做验证。"
  fi

  EXPORT_SHA1="$(sha1sum "$EXPORT_PATH" | cut -c1-8)"
  if [ "$EXPORT_SHA1" != "$ROM_SHA1" ]; then
    die "导出 ROM 的 SHA1 与产物不一致（产物 $ROM_SHA1 vs 导出 $EXPORT_SHA1）—— 复制被截断，不要拿它试玩。"
  fi
  ok "已导出：$EXPORT_PATH"
  dim "Windows 路径：$EXPORT_DIR_WIN\\$EXPORT_NAME"
  dim "SHA1 校验一致（$EXPORT_SHA1）✓ —— 试玩目录与本次产物是同一个 ROM"
  dim "双击启动：$EXPORT_DIR_WIN\\启动山河烬中文版.cmd"
fi

# ══════════════════════════════════════════
# 第 6 步 · 反查
# ══════════════════════════════════════════
H "第 6 步 / 反查框架侧改动（防呆关键）"

if [ "$DRY_RUN" = "1" ]; then
  act "[预演] 将比对 git status 与第 2 步快照，高亮「预期外」改动"
else
  CUR="$(mktemp)"; tmp_track "$CUR"
  git -C "$FRAMEWORK_DIR" status --porcelain > "$CUR"

  # ★ 框架补丁的目标文件：**从 content/framework-patch/*.patch 实时解析**，不写死在白名单里。
  #   原因（2026-09-25 实测）：白名单是本文件里的第二个硬编码表，
  #   每加一个改「新文件」的补丁就得手改一次；漏改的表现是"误报预期外"（噪声），
  #   而噪声会训练出"忽略告警"的习惯 —— 那这条防线就废了。
  PATCH_TARGETS_FILE="$(mktemp)"; tmp_track "$PATCH_TARGETS_FILE"
  if [ -d "$CONTENT_DIR/framework-patch" ]; then
    find "$CONTENT_DIR/framework-patch" -maxdepth 1 -type f -name '*.patch' 2>/dev/null \
      | while IFS= read -r p; do
          grep -m1 '^+++ b/' "$p" 2>/dev/null | sed 's|^+++ b/||'
        done | sed '/^$/d' | sort -u > "$PATCH_TARGETS_FILE"
  fi

  if [ ! -s "$CUR" ]; then
    warn "框架侧无任何改动 —— 若你确实铺了内容，说明铺设没生效（检查 content/ 是否为空）"
  else
    act "框架侧改动清单："
    sed 's/^/      /' "$CUR"
    printf "\n"

    # 与快照对比：快照里没有的 = 预期外
    # git porcelain 格式：XY<空格>path（X/Y 各 1 列，可能是空格）
    # ⚠️ 必须用 `IFS= read` —— 否则行首的 X 列若是空格会被 read 吃掉，
    #    导致 ${line:3} 切片整体左移 2 位（实测：src/data/… 被切成 rc/data/…）
    UNEXPECTED=0
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      # 从第 4 个字符起取路径（XY + 空格 = 3 字符前缀）
      path="${line:3}"
      case "$path" in
        src/data/*|texts/*|src/shanhe_*.c|Makefile) ;;            # 预期（脚本铺设目标）
        src/data_characters.c|src/data_classes.c|src/data_items.c|src/data_supports.c) ;;  # ★ 预期（B' 回填目标，见 3a'）
        docs/game_locale_text_edits.md) ;;                        # ★ 预期（文本台账，见 3b'）
        fonts/cjk/*|graphics/fonts/cjk/*) ;;                      # ★ 预期（字库补丁，见 3c'）
        graphics/custom_spell/*) ;;                               # ★ 预期（法术特效包，见 3d；含 git add 的暂存新增）
        graphics/item_icon/*) ;;                                  # ★ 预期（原创道具图标 PNG，见 3e；含 git add 的暂存新增；同名 .4bpp 由 make 生成且被 .gitignore 忽略，不进 status）
        assets/tmx/*) ;;                                          # ★ 预期（章节地图 TMX，见 3f；含 git add 的暂存新增）
        reports/*) ;;                                             # ★ 预期（generated-data 的 inventory/审计报告是 generate 的正常副产物）
        build/*|*/build/*) ;;                                     # 构建产物，正常
        *)
          # ★★ 框架补丁目标：动态判定（白名单不再需要手跟，见上面 PATCH_TARGETS_FILE 的说明）
          if [ -s "$PATCH_TARGETS_FILE" ] && grep -qxF "$path" "$PATCH_TARGETS_FILE"; then
            :
          else
            # .rej/.orig 单独指名 —— 它们是 patch(1) 的失败/备份残留，
            # 含义与"手滑改了框架"不同（虽同为预期外），要给出可执行的处置指示。
            case "$path" in
              *.rej|*.orig)
                printf "  %s⚠ patch 残留物：%s%s（补丁曾失败或带 fuzz；3c'' 阶段 0 的清障会在下次构建自动删除）\n" \
                  "$c_yellow" "$path" "$c_off"
                ;;
            esac
            printf "  %s⚠ 预期外改动：%s%s\n" "$c_yellow" "$path" "$c_off"
            UNEXPECTED=$((UNEXPECTED+1))
          fi
          ;;
      esac
    done < "$CUR"

    if [ "$UNEXPECTED" -eq 0 ]; then
      ok "反查通过：所有改动都在预期范围内（src/data/、src/data_*.c(回填)、texts/、docs/game_locale_text_edits.md(台账)、fonts/cjk/(字库补丁)、graphics/custom_spell/(法术特效包)、graphics/item_icon/(道具图标)、src/shanhe_*.c、Makefile、build/，以及 content/framework-patch/ 声明的全部补丁目标）"
    else
      warn "发现 $UNEXPECTED 项预期外改动 —— 请人工确认是否为手滑直接改了框架"
      dim "如确认是误改：bash tools/shanhe-build.sh RESTORE=1"
    fi
  fi
  rm -f "$CUR"
  rm -f "$PATCH_TARGETS_FILE"   # 2026-09-29 补：此前漏回收（与 CUR 同段，唯独它没有 rm）
fi

# ─────────────────────────── 收尾 ───────────────────────────
printf "\n%s━━━━━━ 完成 ━━━━━━%s\n" "$c_green" "$c_off"
if [ "$DRY_RUN" = "1" ]; then
  printf "  %s预演结束，未落盘%s\n" "$c_yellow" "$c_off"
else
  printf "  产物：%s\n" "$FRAMEWORK_ROM"
  printf "  导出：%s\n" "$EXPORT_PATH"
  printf "  日志：%s\n" "$REPORT"
  printf "  快照：%s\n" "$PREWRITE_SNAPSHOT"
  printf "\n  下一步：\n"
  printf "    · 查看框架被改了什么   → bash tools/shanhe-build.sh STATUS=1\n"
  printf "    · 一键还原框架         → bash tools/shanhe-build.sh RESTORE=1\n"
  printf "    · 实机试玩             → 双击 %s\\启动山河烬中文版.cmd\n" "$EXPORT_DIR_WIN"
fi
exit 0
