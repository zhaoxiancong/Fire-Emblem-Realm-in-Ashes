#!/usr/bin/env bash
# ============================================================
# 《山河烬》· content 自有表实例通道（构建第 3 步的 3a''）
# ------------------------------------------------------------
# 解决的问题
#   框架里 `units`/`shops`/`traps` 的 hand source 是 **partial-file**
#   （`src/events_udefs.c` 75154 行，Ch2 只是其中一个前缀切片，同一个
#   文件里还混着 Ch3..Ch8/塔/遗迹）。所以 `shanhe-build.sh` 3a' 的整文件
#   回填（`cp -f $GEN $HAND`）白名单只敢放 4 张**整文件**全局表。
#
# 为什么不需要自研「符号作用域 splice」
#   两条实测硬证据（2026-09-28）：
#   ① 框架 modern 构建的 C 源集合是 `$(wildcard src/*.c)`
#      （`modern.mk:359`）⇒ 新增一个 `src/<名字>.c` **自动进构建**，
#      既不用改 Makefile，也不用发框架补丁。
#   ② 上游自己给章节单位用的就是**每章一个整文件**
#      （`src/events/prologue-eventudefs.h` / `ch1-eventudefs.h`，由
#      `events_udefs.c` 顶部 `#include`）。⇒「partial-file」不是框架的
#      硬约束，只是 Ch2 那次迁移的实现选择。
#   ⇒ 山河烬自己的章节表**不要去挤框架的 partial-file**，直接把
#     「JSON → 整文件 C」生成到一个我们自有的 `src/shanhe_<slug>.c`：
#     该文件 100% 由生成器产出 ⇒ 不存在「别的章节被抹掉」的前提。
#
# 本通道做什么（每个实例三步，与 3a' 同款纪律）
#   ① validate --no-roundtrip    —— JSON 本身是否合法（这一关失败 = 真错误）
#   ② generate --no-roundtrip    —— 产物；`cmp -s` 内容感知 ⇒ 一致就不 cp（保 mtime）
#   ③ validate（带 round-trip）  —— 证明「盘上的 C == JSON 所描述的模型」，
#                                   即没有人手改过那个生成文件
#
# ★ 三条硬拦（防的是"写错落点"这类静默灾难）
#   G-A 写入目标必须匹配 `src/shanhe_*.c`（我们自有的整文件）
#       —— 这一条同时封住"指向框架共用 partial-file（src/events_udefs.c 等）"
#   G-B 表 JSON 必须已在 `B3_NEW_DATA` 登记（原创新表的人工闸）
#   G-C B3_INSTANCES 条目必须是三字段 `<表>:<JSON>:<框架内相对路径>`
#
# ★ 一个必须知道的坑（2026-09-28 实测）
#   `generate` 默认会写 `reports/generated_data_<表>_inventory.md` —— 那是
#   **框架里被 git 追踪的文件**。对「源是山河烬自有 JSON」的实例，默认路径
#   会把框架的报告**用我们的内容覆写**（实测命中：units 报告 12 行改动）。
#   ⇒ 本通道一律显式 `--inventory` 到自己的临时目录。
#
# 用法（一般由 `shanhe-build.sh` 第 3 步调用；也可单独跑）
#   B3_INSTANCES="units:shanhe_units.json:shanhe_udefs.c" \
#   B3_NEW_DATA="shanhe_units.json" \
#   bash tools/shanhe-content-tables.sh
#
# 环境变量
#   REPO_ROOT      本仓库根（默认从脚本位置推断）
#   CONTENT_DIR    内容目录（默认 <仓库>/content）
#   FRAMEWORK_DIR  框架位置（默认 $HOME/projects/fireemblem8-expansion）
#   LOG_DIR        日志目录（默认 $HOME/shanhe-logs）
#   STAMP          日志戳（默认当前时间）
#   B3_INSTANCES   空格分隔；每项 `<表>:<content/data 里的 JSON 文件名>:<框架内相对路径>`
#                  第三字段形如 `src/shanhe_udefs.c`（★ 以 src/shanhe_ 开头的自有整文件）
#   B3_NEW_DATA    空格分隔；content/data 里**框架侧不存在**的新表 JSON 文件名
#   CONTENT_TABLES=0  整段跳过
#   DRY_RUN=1      预演，不落盘
#   KEEP=1         保留临时目录（调试用）
#
# 退出码：0 全过 / 2 断言失败 / 3 前置缺失（调用方据此 warn 而非 die）
# ============================================================

set +e
export LANG=C.UTF-8 LC_ALL=C.UTF-8

# ── 位置参数防呆（与 shanhe-build.sh 同一纪律：开关一律环境变量）──
for _arg in "$@"; do
  case "$_arg" in
    [A-Za-z_]*=*)
      printf '\n  \033[0;31m✗\033[0m 位置参数 "%s" 不会被识别 —— 本脚本的开关都是**环境变量**。\n' "$_arg" >&2
      printf '    正确写法： \033[0;36m%s bash %s\033[0m\n\n' "$_arg" "$0" >&2
      exit 2 ;;
  esac
done
unset _arg

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CONTENT_DIR="${CONTENT_DIR:-$REPO_ROOT/content}"
FRAMEWORK_DIR="${FRAMEWORK_DIR:-$HOME/projects/fireemblem8-expansion}"
LOG_DIR="${LOG_DIR:-$HOME/shanhe-logs}"
STAMP="${STAMP:-$(date +%Y%m%d-%H%M%S)}"
DRY_RUN="${DRY_RUN:-0}"
CONTENT_TABLES="${CONTENT_TABLES:-1}"

B3_INSTANCES="${B3_INSTANCES:-}"
B3_NEW_DATA="${B3_NEW_DATA:-}"

# ★ 写入目标白名单前缀：只允许落在我们自有的整文件上。
#   这一条同时封住了"指向框架共用 partial-file"这条路 —— 发现者实测：
#   若再加一份 PARTIAL_HAND 黑名单，在 `src/shanhe_*.c` 前缀约束下它**不可达**
#   （永远命中不了）= 假门禁。故只留一条真拦，并把理由写进报错。
OUT_PREFIX="src/shanhe_"

c_green=$'\033[0;32m'; c_yellow=$'\033[1;33m'; c_red=$'\033[0;31m'
c_dim=$'\033[2m'; c_off=$'\033[0m'
ok()   { printf "  %s✓%s %s\n" "$c_green" "$c_off" "$1"; }
warn() { printf "  %s⚠%s %s\n" "$c_yellow" "$c_off" "$1"; }
bad()  { printf "  %s✗%s %s\n" "$c_red" "$c_off" "$1"; }
dim()  { printf "  %s%s%s\n" "$c_dim" "$1" "$c_off"; }

mkdir -p "$LOG_DIR"

# ── 前置 ──
if [ "$CONTENT_TABLES" = "0" ]; then
  dim "content 自有表实例：CONTENT_TABLES=0，按开关跳过"
  exit 0
fi
if [ ! -d "$FRAMEWORK_DIR/scripts/generated_data" ]; then
  warn "content 自有表实例：框架目录不可用（$FRAMEWORK_DIR）—— 跳过（不影响产物正确性）"
  exit 3
fi
if [ -z "$B3_INSTANCES" ]; then
  dim "content 自有表实例：未声明任何实例（B3_INSTANCES 为空）—— 跳过"
  exit 0
fi

TMP_DIR="$(mktemp -d)"
cleanup() { [ "${KEEP:-0}" = "1" ] || rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# ══════════════════════════════════════════
# 函数层（可被 tools/shanhe-content-tables.test.sh 抽出来单跑）
# ══════════════════════════════════════════

# guard_out_path <目标相对路径>
#   0 = 合法（我们自有的整文件）；2 = 硬拦
guard_out_path() {
  local out_rel="$1"
  case "$out_rel" in
    "$OUT_PREFIX"*.c) return 0 ;;
    *)
      bad "写入目标必须匹配 '${OUT_PREFIX}*.c'（山河烬自有的整文件）：$out_rel"
      dim "本通道的目标文件是 100% 由生成器产出的整文件。"
      dim "而框架共用的数据文件是 partial-file —— 例如 src/events_udefs.c（75154 行）里"
      dim "Ch2 只是一个前缀切片，同一个文件里还坐着 Ch3..Ch8/塔/遗迹；"
      dim "src/events_shoplist.c、src/events_trapdata.c 同构。"
      dim "整文件覆盖会把那些章节**全部抹掉**（这正是 3a' 白名单只放 4 张整文件表的原因）。"
      dim "正确做法：像上游的 src/events/prologue-eventudefs.h 那样给山河烬的内容另立自有文件。"
      return 2 ;;
  esac
}

# stage_new_data <json 文件名>
#   0 = 已落盘（或预演将落盘）；3 = 内容未变，跳过写入（保 mtime）；2 = 未登记
stage_new_data() {
  local name="$1"
  local src="$CONTENT_DIR/data/$name" dst="$FRAMEWORK_DIR/src/data/$name"

  if [ ! -f "$src" ]; then
    bad "[$name] content/data 里没有这个文件 —— B3_NEW_DATA 登记与实物不符"
    return 2
  fi

  case " $B3_NEW_DATA " in
    *" $name "*) ;;
    *)
      bad "[$name] 是框架侧不存在的新表，但未在 B3_NEW_DATA 登记"
      dim "原创新表**必须显式登记**才会被铺设 —— 这是「原创新表需人工确认落点」的那道人工闸。"
      return 2 ;;
  esac

  if [ "$DRY_RUN" = "1" ]; then
    printf "  %s[预演]%s 铺设新表 content/data/%s → src/data/%s\n" "$c_yellow" "$c_off" "$name" "$name"
    return 0
  fi

  # 内容感知：一致就不落盘（与 3a/3c 同一纪律 —— 落盘会刷新 mtime 触发重编）
  if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
    dim "[$name] 新表已逐字节一致，跳过写入（保 mtime）"
    return 3
  fi
  if cp -f "$src" "$dst"; then
    ok "[$name] 新表铺设完成（src/data/$name，$(wc -c < "$dst" | tr -d ' ') 字节）"
    return 0
  fi
  bad "[$name] 新表铺设失败：无法写入 src/data/$name"
  return 2
}

# run_instance <表> <json 文件名> <框架 src/ 目标文件名>
#   0 = 通过；2 = 失败
run_instance() {
  local table="$1" json_name="$2" out_rel="$3"
  local out_name slug log out_dir
  out_name="$(basename "$out_rel")"
  slug="${out_name%.c}"

  guard_out_path "$out_rel" || return 2

  local src_rel="src/data/$json_name"
  local hand_abs="$FRAMEWORK_DIR/$out_rel"
  if [ ! -f "$FRAMEWORK_DIR/$src_rel" ]; then
    bad "[$table/$slug] 表 JSON 未就位（$src_rel）—— 需先由 B3_NEW_DATA 登记并铺设"
    return 2
  fi

  out_dir="$TMP_DIR/$slug"
  mkdir -p "$out_dir"
  log="$LOG_DIR/content-table-$STAMP-$slug.log"

  # ① JSON 合法性（不带 round-trip —— 这一关失败 = 真错误）
  if ( cd "$FRAMEWORK_DIR" && python3 -m scripts.generated_data validate \
        --table "$table" --source "$src_rel" --hand-source "$out_rel" --no-roundtrip ) \
        > "$log" 2>&1; then
    ok "[$table/$slug] ① JSON 合法"
  else
    bad "[$table/$slug] ① JSON 非法"
    tail -15 "$log" | sed 's/^/      /'
    dim "完整日志：$log"
    return 2
  fi

  # ② 生成产物 → 内容感知回填（★ --inventory 必须重定向，否则覆写框架 tracked 报告）
  if ( cd "$FRAMEWORK_DIR" && python3 -m scripts.generated_data generate \
        --table "$table" --source "$src_rel" --hand-source "$out_rel" \
        --no-roundtrip --out-dir "$out_dir" --inventory "$out_dir/inventory.md" ) \
        >> "$log" 2>&1; then
    local gen
    gen="$(find "$out_dir" -maxdepth 1 -type f -name '*.c' | head -1)"
    if [ -z "$gen" ]; then
      bad "[$table/$slug] ② 生成器没有产出任何 .c（schema 的 default_output_name 对不上？）"
      tail -10 "$log" | sed 's/^/      /'
      return 2
    fi
    # 生成器自带 banner 会写 `Source: <--source 原样>`。源路径是**框架内相对路径**
    # ⇒ banner 可复现（不含绝对路径）；若有人把 --source 改成绝对路径，
    #   这里会因 cmp 永远不等而每轮都 cp —— 故断言一次。
    if grep -q '^ \* Source: /' "$gen"; then
      bad "[$table/$slug] ② 产物 banner 含绝对源路径 ⇒ 产物不可复现（--source 必须传框架内相对路径）"
      return 2
    fi
    if [ -f "$hand_abs" ] && cmp -s "$gen" "$hand_abs"; then
      dim "[$table/$slug] ② 回填：与生成产物已逐字节一致，跳过（保 mtime）"
    elif [ "$DRY_RUN" = "1" ]; then
      printf "  %s[预演]%s [%s/%s] ② 将回填 %s ← %s\n" "$c_yellow" "$c_off" "$table" "$slug" "$out_rel" "$gen"
    elif cp -f "$gen" "$hand_abs"; then
      ok "[$table/$slug] ② 回填完成（$out_rel ← 生成产物，$(wc -c < "$hand_abs" | tr -d ' ') 字节）"
    else
      bad "[$table/$slug] ② 回填失败：无法写入 $out_rel"
      return 2
    fi
  else
    bad "[$table/$slug] ② 生成产物失败"
    tail -10 "$log" | sed 's/^/      /'
    dim "完整日志：$log"
    return 2
  fi

  # ③ round-trip 复核 —— 证明「盘上的 C == JSON 所描述的模型」
  #    （对本通道而言它近乎同义反复，却精确拦住唯一的真实失效模式：
  #      有人手改了那个生成文件，而不去改 JSON）
  if [ "$DRY_RUN" = "1" ]; then
    printf "  %s[预演]%s [%s/%s] ③ round-trip 复核\n" "$c_yellow" "$c_off" "$table" "$slug"
    return 0
  fi
  if ( cd "$FRAMEWORK_DIR" && python3 -m scripts.generated_data validate \
        --table "$table" --source "$src_rel" --hand-source "$out_rel" ) \
        > "$log" 2>&1; then
    ok "[$table/$slug] ③ round-trip 复核通过（盘上文件与 JSON 模型一致，无人手改）"
  else
    bad "[$table/$slug] ③ round-trip 复核失败 —— 回填未生效，或 $out_rel 被手工改过"
    tail -10 "$log" | sed 's/^/      /'
    dim "完整日志：$log"
    dim "修法：改 content/data/$json_name（唯一事实源），重跑构建；不要手改 $out_rel"
    return 2
  fi
  return 0
}

# ══════════════════════════════════════════
# 主流程
# ══════════════════════════════════════════
RC=0
STAGED=0
for name in $B3_NEW_DATA; do
  stage_new_data "$name"; rc=$?
  case "$rc" in
    0) STAGED=$((STAGED+1)) ;;
    3) ;;
    *) RC=2 ;;
  esac
done
[ "$RC" = "0" ] || exit 2

for item in $B3_INSTANCES; do
  table="${item%%:*}"
  rest="${item#*:}"
  json_name="${rest%%:*}"
  out_rel="${rest#*:}"
  if [ -z "$table" ] || [ -z "$json_name" ] || [ -z "$out_rel" ] \
     || [ "$out_rel" = "$rest" ]; then
    bad "B3_INSTANCES 条目格式错误：'$item'（应为 <表>:<JSON 文件名>:<框架内相对路径>，如 units:shanhe_units.json:src/shanhe_udefs.c）"
    RC=2; continue
  fi
  run_instance "$table" "$json_name" "$out_rel" || RC=2
done

if [ "$RC" = "0" ]; then
  dim "content 自有表实例：全部通过（新表铺设 $STAGED 项）"
fi
exit "$RC"
