#!/usr/bin/env bash
# ============================================================
#  shanhe-verify.sh —— 《山河烬》机制验证脚手架（验证阶梯 L0）
# ============================================================
#
#  作用：把上游框架的 tools/gba-playtest/（无头 libmGBA + 按键脚本 +
#        按帧号内存探针）接到**本项目**的 ROM 与 ELF 上，使「机制是否
#        真的在跑」变成**机器断言**，而不是人眼观察。
#
#  设计依据：docs/5 §5.12（验证阶梯）
#            docs/4 §8.2（可演示入口交付纪律）
#  上游契约：框架 tools/gba-playtest/README.md §"Scenario format"
#
#  ── 开关（一律环境变量；写成位置参数会被拒绝并退出 2）──
#    MODE      capture | verify | backend-check     默认 verify
#    PROFILE   release | debug                      默认 release
#    SCENARIO  content/verify/scenarios/<名>.json   默认 shanhe-boot
#    POLICY    behavior | exact                     默认 behavior
#    UPDATE    1 = 用 capture 结果刷新 fingerprint  默认 0
#
#  ── 为什么有 POLICY=behavior 这个默认 ──
#  精确策略（exact）会连 ROM 身份（SHA1/尺寸）一起比。本项目中文改造后
#  ROM 必然变，精确策略毫无意义。behavior 只比行为：framebuffer 哈希、
#  SRAM 哈希、探针值。这与 framework.lock 的 [verify] 段同一理由。
#
#  ── 探针是 RAM-only（上游硬约束，勿试 ROM 地址）──
#  合法范围：EWRAM 0x02000000-0x0203ffff / IWRAM 0x03000000-0x03007fff，
#  宽度 1/2/4 字节且对齐。想断言「表被编进去了」的 ROM 常量（例如
#  sWeaponTriangleRules）**不能**用探针，只能改用运行态 RAM 字段。
# ============================================================

set +e

export LANG=C.UTF-8
export LC_ALL=C.UTF-8

# ── 位置参数防呆（2026-09-29 实测：位置参数会被 make/脚本静默忽略）──
for _arg in "$@"; do
  case "$_arg" in
    [A-Za-z_]*=*)
      printf '\n  \033[0;31m✗\033[0m 位置参数 "%s" 不会被识别 —— 本脚本的开关都是**环境变量**。\n' "$_arg" >&2
      printf '    正确写法： \033[0;36m%s %s\033[0m\n\n' "$_arg" "$0" >&2
      exit 2 ;;
  esac
done
unset _arg

MODE="${MODE:-verify}"
PROFILE="${PROFILE:-release}"
SCENARIO="${SCENARIO:-shanhe-boot}"
POLICY="${POLICY:-behavior}"
UPDATE="${UPDATE:-0}"

# ── 定位仓库根（本脚本在 <仓库>/tools/ 下）──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCK="$REPO_ROOT/framework.lock"

die() { printf '\n  \033[0;31m✗\033[0m %s\n\n' "$1" >&2; exit 1; }
ok()  { printf '  \033[0;32m✓\033[0m %s\n' "$1"; }
act() { printf '\n  \033[0;36m▶\033[0m %s\n' "$1"; }

[ -f "$LOCK" ] || die "找不到 framework.lock：$LOCK"

# ── 从 framework.lock 读配置（不硬编码，单一事实来源）──
lock_get() {
  local section="$1" key="$2"
  awk -v sec="[$section]" -v k="$key" '
    $0 == sec { insec = 1; next }
    /^\[/     { insec = 0 }
    insec && $1 == k { sub(/^[^=]*=[ \t]*/, ""); sub(/[ \t\r]+$/, ""); print; exit }
  ' "$LOCK"
}

FW_REL_RAW="$(lock_get framework path)"
ABI="$(lock_get build modern_abi)"
ROM_LABEL="$(lock_get build rom_size_label)"
[ -n "$FW_REL_RAW" ] || die "framework.lock 缺少 framework.path"
[ -n "$ABI" ]        || die "framework.lock 缺少 build.modern_abi"
[ -n "$ROM_LABEL" ]  || die "framework.lock 缺少 build.rom_size_label"

FRAMEWORK_DIR="$HOME/$FW_REL_RAW"
PLAYTEST="$FRAMEWORK_DIR/tools/gba-playtest/gba_playtest.py"

case "$PROFILE" in
  release) CONF_DIR="release" ;;
  debug)   CONF_DIR="debug"   ;;
  *) die "PROFILE 只支持 release / debug，收到 '$PROFILE'" ;;
esac

LABEL_LC="$(printf '%s' "$ROM_LABEL" | tr '[:upper:]' '[:lower:]')"
ROM_BASE="shanhe-cn-$LABEL_LC"
if [ "$PROFILE" = "debug" ]; then
  ROM_FILE="$REPO_ROOT/shanhe-rom/$ROM_BASE-debug.gba"
else
  ROM_FILE="$REPO_ROOT/shanhe-rom/$ROM_BASE.gba"
fi
ELF_FILE="$FRAMEWORK_DIR/build/expansion-modern/$CONF_DIR/$ABI/fireemblem8.elf"

SCENARIO_FILE="$REPO_ROOT/content/verify/scenarios/$SCENARIO.json"
FINGERPRINT_DIR="$REPO_ROOT/content/verify/fingerprints"
FINGERPRINT_FILE="$FINGERPRINT_DIR/$SCENARIO.$PROFILE.json"

VERIFY_ROOT="${SHANHE_VERIFY_ROOT:-$HOME/shanhe-logs}"
TMPDIR="$VERIFY_ROOT/verify-tmp"
mkdir -p "$TMPDIR" "$FINGERPRINT_DIR" || die "无法建立临时/指纹目录"

act "配置解析（来源 framework.lock）"
printf '      框架路径   : %s\n' "$FRAMEWORK_DIR"
printf '      构建档位   : %s / %s\n' "$PROFILE" "$ABI"
printf '      ROM        : %s\n' "$ROM_FILE"
printf '      ELF        : %s\n' "$ELF_FILE"
printf '      场景       : %s\n' "$SCENARIO_FILE"
printf '      策略       : %s\n' "$POLICY"

# ── 前置检查：缺什么就明确说缺什么，绝不静默降级 ──
[ -f "$PLAYTEST" ]      || die "找不到上游 harness：$PLAYTEST
      → 框架依赖是否就位？见 framework.lock [framework] path"
[ -f "$ROM_FILE" ]      || die "找不到 ROM：$ROM_FILE
      → 先跑 tools/shanhe-build.sh（release）
      → debug 档需 MODERN_CONFIG=debug 构建后拷入"
[ -f "$ELF_FILE" ]      || die "找不到 ELF：$ELF_FILE
      → 探针用符号表达式解析地址，**必须**有与 ROM 同一次构建的 ELF。
      → release：cd $FRAMEWORK_DIR && make expansion-modern-rom MODERN_CONFIG=release MODERN_ABI=$ABI"
[ -f "$SCENARIO_FILE" ] || die "找不到场景：$SCENARIO_FILE"

if grep -q '"' "$SCENARIO_FILE" 2>/dev/null && grep -qE '"[A-Za-z_][A-Za-z0-9_]*(\+0x[0-9a-fA-F]+)?"' "$SCENARIO_FILE"; then
  command -v arm-none-eabi-nm >/dev/null 2>&1 \
    || die "场景含符号探针，但找不到 arm-none-eabi-nm"
fi

# ── 分派 ──
case "$MODE" in
  backend-check)
    act "检查 libmGBA 后端（不加载 ROM）"
    TMPDIR="$TMPDIR" python3 "$PLAYTEST" backend-check
    rc=$?
    [ "$rc" -eq 0 ] && ok "libmGBA 后端可用" || die "libmGBA 后端不可用（rc=$rc）"
    ;;

  capture)
    OUT="${OUT:-$VERIFY_ROOT/verify-out/$SCENARIO.$PROFILE.capture.json}"
    mkdir -p "$(dirname "$OUT")"
    act "capture：跑判定基准"
    TMPDIR="$TMPDIR" python3 "$PLAYTEST" capture \
      --rom "$ROM_FILE" --elf "$ELF_FILE" --nm arm-none-eabi-nm \
      --scenario "$SCENARIO_FILE" --output "$OUT"
    rc=$?
    [ "$rc" -eq 0 ] || die "capture 失败（rc=$rc）"
    ok "capture 完成：$OUT"
    if [ "$UPDATE" = "1" ]; then
      cp "$OUT" "$FINGERPRINT_FILE" || die "写指纹失败：$FINGERPRINT_FILE"
      ok "指纹已更新：$FINGERPRINT_FILE"
    else
      printf '      （UPDATE=1 可把本次结果落成指纹）\n'
    fi
    ;;

  verify)
    [ -f "$FINGERPRINT_FILE" ] || die "找不到指纹：$FINGERPRINT_FILE
      → 首次建立基准： MODE=capture UPDATE=1 bash tools/shanhe-verify.sh"
    act "verify：回归比对"
    TMPDIR="$TMPDIR" python3 "$PLAYTEST" verify \
      --policy "$POLICY" \
      --rom "$ROM_FILE" --elf "$ELF_FILE" --nm arm-none-eabi-nm \
      --scenario "$SCENARIO_FILE" --expected "$FINGERPRINT_FILE"
    rc=$?
    case "$rc" in
      0) ok "验证通过：$SCENARIO（$PROFILE）" ;;
      1) printf '\n  \033[0;31m✗\033[0m 行为与指纹不一致 —— 若本次是**有意**变更，用 MODE=capture UPDATE=1 更新指纹并说明原因\n\n' >&2; exit 1 ;;
      *) die "验证无法执行（rc=$rc）" ;;
    esac
    ;;

  *)
    die "MODE 只支持 capture / verify / backend-check，收到 '$MODE'" ;;
esac

printf '\n'
