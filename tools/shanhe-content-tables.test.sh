#!/usr/bin/env bash
# ============================================================
# 《山河烬》· content 自有表实例通道 · 隔离测试
#   （被测对象：tools/shanhe-content-tables.sh）
# ------------------------------------------------------------
# 为什么是"端到端对着真框架跑"而不是抽函数体单测：
#   本通道的全部风险都在**落点**（写到哪、有没有连带改到框架 tracked 文件），
#   而这些只有对着真框架 + 真 git 仓库才看得见。mktemp 造一个假框架反而
#   测不到仓库状态污染。
#
# 覆盖：
#   正向 ① 新表铺设 + 三步门禁全绿 + 产物存在且含期望符号
#       ② banner 用**框架内相对路径**（产物可复现，不泄绝对路径）
#       ③ 幂等：二次运行两处"跳过"，且两个文件的 **mtime 真不变**
#       ④ 框架 tracked 文件零改动：reports/ 的 units 报告未被覆写；
#          src/events_udefs.c（partial-file）sha1 不变
#       ⑤ ★ 断言非真空：手改生成文件后，③ 用的那条 round-trip 断言**真的会失败**
#   负向 ⑥ 目标指向 src/events_udefs.c ⇒ rc=2（硬拦 partial-file 落点）
#       ⑦ B3_INSTANCES 两字段（缺第三段）⇒ rc=2
#       ⑧ 未登记的新表 ⇒ rc=2
#       ⑨ CONTENT_TABLES=0 ⇒ rc=0（按开关跳过）
#
# ★ 纪律备忘（R-30）：本测试自己也可能"恒绿" —— 故所有断言走 `expect()`，
#   并在开头做一次**非真空证明**（故意喂一个假条件，必须看到 ✗ 且计数 +1）。
#
# 用法：bash tools/shanhe-content-tables.test.sh [--framework /path]
# 退出码：0 全绿 / 2 有失败 / 3 前置缺失（框架不可用）
# ============================================================

set +e
export LANG=C.UTF-8 LC_ALL=C.UTF-8

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRAMEWORK_DIR="${FRAMEWORK_DIR:-$HOME/projects/fireemblem8-expansion}"
while [ $# -gt 0 ]; do
  case "$1" in
    --framework) FRAMEWORK_DIR="$2"; shift 2 ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
done

TOOL="$REPO_ROOT/tools/shanhe-content-tables.sh"
if [ ! -f "$TOOL" ]; then printf 'missing %s\n' "$TOOL" >&2; exit 3; fi
if [ ! -d "$FRAMEWORK_DIR/scripts/generated_data" ]; then
  printf '前置缺失：框架不可用（%s）—— 跳过\n' "$FRAMEWORK_DIR" >&2
  exit 3
fi

# 探针命名：带 ctprobe 前缀，绝无可能与真内容撞名
PROBE_JSON="shanhe_ctprobe_units.json"
PROBE_OUT="src/shanhe_ctprobe_udefs.c"

green=$'\033[0;32m'; red=$'\033[0;31m'; dim_=$'\033[2m'; off=$'\033[0m'
n_ok=0; n_bad=0
expect() {   # expect <描述> <0=通过>
  if [ "$2" = "0" ]; then
    n_ok=$((n_ok+1)); printf "  %s✓%s %s\n" "$green" "$off" "$1"
  else
    n_bad=$((n_bad+1)); printf "  %s✗%s %s\n" "$red" "$off" "$1"
  fi
}

TMP="$(mktemp -d)"
FW_JSON="$FRAMEWORK_DIR/src/data/$PROBE_JSON"
FW_OUT="$FRAMEWORK_DIR/$PROBE_OUT"
ORIG_UDEFS_SHA="$(sha1sum "$FRAMEWORK_DIR/src/events_udefs.c" | cut -d' ' -f1)"

cleanup() {
  rm -f "$FW_JSON" "$FW_OUT" 2>/dev/null
  rm -rf "$TMP" 2>/dev/null
}
trap cleanup EXIT

run_tool() {  # run_tool <CONTENT_DIR> <B3_INSTANCES> <B3_NEW_DATA> [extra env...]
  local cdir="$1" inst="$2" ndata="$3"; shift 3
  env CONTENT_DIR="$cdir" B3_INSTANCES="$inst" B3_NEW_DATA="$ndata" "$@" \
      bash "$TOOL" > "$TMP/last.log" 2>&1
  return $?
}

printf '\n%s━━━ content 自有表实例通道 · 隔离测试 ━━━%s\n' "$dim_" "$off"

# ── 0) 非真空证明（R-30）─────────────────────────────
n_ok=0; n_bad=0
expect "非真空证明（本行**必须**报 ✗）" 1
if [ "$n_bad" = "1" ]; then
  printf "  %s· 非真空 OK：故意为假 ⇒ n_bad=1（断言真的能失败）%s\n" "$dim_" "$off"
else
  printf '  %s✗ 自测恒绿！expect() 没在计数 —— 后续所有结果不可信%s\n' "$red" "$off"
  exit 2
fi
n_ok=0; n_bad=0

# ── 夹具：content/data/ 里放一份最小 units JSON ────────
mkdir -p "$TMP/content/data"
cat > "$TMP/content/data/$PROBE_JSON" <<'JSON'
{
  "$schema": "fe8.units.v1",
  "groups": [
    {
      "symbol": "UnitDef_CtProbe",
      "units": [
        {
          "charIndex": "CHARACTER_EIRIKA",
          "classIndex": "CLASS_EIRIKA_LORD",
          "allegiance": "FACTION_ID_BLUE",
          "level": 1,
          "xPosition": 3,
          "yPosition": 4,
          "redas": [ { "x": 3, "y": 4, "b": 65535 } ],
          "items": ["ITEM_SWORD_RAPIER"]
        },
        {
          "charIndex": "CHARACTER_SETH",
          "classIndex": "CLASS_PALADIN",
          "allegiance": "FACTION_ID_GREEN",
          "level": 2,
          "xPosition": 5,
          "yPosition": 6,
          "items": ["ITEM_LANCE_IRON"]
        }
      ]
    }
  ]
}
JSON
rm -f "$FW_JSON" "$FW_OUT"

# ── 1) 正向：一次跑通 ─────────────────────────────────
run_tool "$TMP/content" "units:$PROBE_JSON:$PROBE_OUT" "$PROBE_JSON"
expect "① 通道退出码 = 0" "$([ $? -eq 0 ] && echo 0 || echo 1)"
expect "① 新表已铺到框架 src/data/$PROBE_JSON" "$([ -f "$FW_JSON" ] && echo 0 || echo 1)"
expect "① 生成目标已落盘 $PROBE_OUT" "$([ -f "$FW_OUT" ] && echo 0 || echo 1)"
expect "① 产物含期望符号 UnitDef_CtProbe" \
  "$(grep -q 'UnitDef_CtProbe\[\] = {' "$FW_OUT" 2>/dev/null && echo 0 || echo 1)"
expect "① 产物含 REDA 子数组（两趟发射顺序的前提）" \
  "$(grep -q 'REDA_UnitDef_CtProbe_0\[\] = {' "$FW_OUT" 2>/dev/null && echo 0 || echo 1)"
# ★ 注意：`✓` 与方括号之间夹着 ANSI 复位码，不能用 '✓ \[units/' 当判据
#   （实测恒不匹配 ⇒ 假红）。改为按三步各自的**文案**断言。
expect "① 第 1 步：JSON 合法"      "$(grep -q 'JSON 合法' "$TMP/last.log" && echo 0 || echo 1)"
expect "① 第 2 步：回填完成"        "$(grep -q '② 回填完成' "$TMP/last.log" && echo 0 || echo 1)"
expect "① 第 3 步：round-trip 复核通过" "$(grep -q '③ round-trip 复核通过' "$TMP/last.log" && echo 0 || echo 1)"
expect "② banner 用框架内相对路径（产物可复现）" \
  "$(grep -q "^ \* Source: src/data/$PROBE_JSON\$" "$FW_OUT" 2>/dev/null && echo 0 || echo 1)"
expect "④ 框架 reports/ 的 units 报告未被覆写" \
  "$(git -C "$FRAMEWORK_DIR" status --porcelain -- reports/generated_data_units_inventory.md 2>/dev/null | grep -q . && echo 1 || echo 0)"
expect "④ src/events_udefs.c（partial-file）逐字节未变" \
  "$([ "$(sha1sum "$FRAMEWORK_DIR/src/events_udefs.c" | cut -d' ' -f1)" = "$ORIG_UDEFS_SHA" ] && echo 0 || echo 1)"
expect "④ 框架侧新增 untracked 只有探针那 2 项" \
  "$([ "$(git -C "$FRAMEWORK_DIR" status --porcelain --untracked-files=all 2>/dev/null \
        | grep '^??' | grep -c 'shanhe_ctprobe')" = "2" ] && echo 0 || echo 1)"

# ── 2) 幂等 + mtime 真断言 ────────────────────────────
m1="$(stat -c %Y "$FW_OUT" 2>/dev/null)/$(stat -c %Y "$FW_JSON" 2>/dev/null)"
sleep 1
run_tool "$TMP/content" "units:$PROBE_JSON:$PROBE_OUT" "$PROBE_JSON"
rc2=$?
m2="$(stat -c %Y "$FW_OUT" 2>/dev/null)/$(stat -c %Y "$FW_JSON" 2>/dev/null)"
expect "③ 二次运行仍退出码 0" "$([ "$rc2" -eq 0 ] && echo 0 || echo 1)"
expect "③ 二次运行两处都判「已逐字节一致，跳过」" \
  "$([ "$(grep -c '已逐字节一致，跳过' "$TMP/last.log")" = "2" ] && echo 0 || echo 1)"
expect "③ mtime 真不变（两次读数须为 <数字>/<数字> 且相同：$m1）" \
  "$(printf '%s' "$m1" | grep -qE '^[0-9]+/[0-9]+$' && [ "$m1" = "$m2" ] && echo 0 || echo 1)"

# ── 3) 断言非真空：③ 用的 round-trip 真能红 ────────────
sed -i 's/\.xPosition = 3,/.xPosition = 9,/' "$FW_OUT"
( cd "$FRAMEWORK_DIR" && python3 -m scripts.generated_data validate \
    --table units --source "src/data/$PROBE_JSON" --hand-source "$PROBE_OUT" ) \
    > "$TMP/rt.log" 2>&1
expect "⑤ 手改生成文件后 round-trip **必须**失败（③ 不是同义反复）" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"
expect "⑤ 失败信息指名 xPosition 不一致" \
  "$(grep -q 'xPosition mismatch' "$TMP/rt.log" && echo 0 || echo 1)"
run_tool "$TMP/content" "units:$PROBE_JSON:$PROBE_OUT" "$PROBE_JSON"
expect "⑤ 重跑通道把被手改的文件回填回 JSON 模型" \
  "$(grep -q '\.xPosition = 3,' "$FW_OUT" && echo 0 || echo 1)"

# ── 4) 负向 ───────────────────────────────────────────
run_tool "$TMP/content" "units:$PROBE_JSON:src/events_udefs.c" "$PROBE_JSON"
expect "⑥ 目标指向 src/events_udefs.c ⇒ rc=2（硬拦 partial-file 落点）" \
  "$([ $? -eq 2 ] && echo 0 || echo 1)"
expect "⑥ 报错文案说明了 partial-file 理由" \
  "$(grep -q 'partial-file' "$TMP/last.log" && echo 0 || echo 1)"

run_tool "$TMP/content" "units:$PROBE_JSON" ""
expect "⑦ 两字段条目 ⇒ rc=2（格式硬拦）" "$([ $? -eq 2 ] && echo 0 || echo 1)"

run_tool "$TMP/content" "units:$PROBE_JSON:$PROBE_OUT" "other_missing.json"
expect "⑧ 未登记/不存在的表 ⇒ rc=2" "$([ $? -eq 2 ] && echo 0 || echo 1)"

run_tool "$TMP/content" "units:$PROBE_JSON:$PROBE_OUT" "$PROBE_JSON" CONTENT_TABLES=0
expect "⑨ CONTENT_TABLES=0 ⇒ rc=0（按开关跳过）" "$([ $? -eq 0 ] && echo 0 || echo 1)"

# ── 汇总 ─────────────────────────────────────────────
printf '\n  %s结果：%d 通过 / %d 失败%s\n' \
  "$([ "$n_bad" -eq 0 ] && echo "$green" || echo "$red")" "$n_ok" "$n_bad" "$off"
[ "$n_bad" -eq 0 ] || exit 2
exit 0
