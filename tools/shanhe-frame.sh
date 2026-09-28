#!/usr/bin/env bash
# ============================================================================
#  shanhe-frame.sh —— 《山河烬》取帧工具（把游戏画面落成 PNG）
# ============================================================================
#
#  用途：D-7 交付纪律里的「**可在游戏内看到**」那一半。
#        L0 的内存探针能证明"某个数变成了某个值"，但证明不了"屏幕上是什么"。
#        本工具用上游无头采集器的**逐像素探针**把整屏取回来，落成 PNG 供目视核对。
#
#  用法（开关**一律环境变量** —— 位置参数会被硬拦，与 shanhe-verify.sh 同规则）：
#
#      FRAME=1500 bash tools/shanhe-frame.sh
#
#  环境变量：
#      FRAME     必填。要取的那一帧。
#      BASE      可选。按键脚本来源场景，默认 shanhe-boot
#                （读 content/verify/scenarios/<BASE>.json，只取它的 frames）。
#                ★ `SCENARIO=` 是它的别名（与 shanhe-verify.sh 的叫法一致 ——
#                  本工具原先只认 BASE，实测有人（我）按 SCENARIO= 传参被静默忽略，
#                  结果取了 boot 场景的帧、看到的是另一段画面）。
#      SCALE     可选。PNG 放大倍数，默认 3（=720x480）。
#      OUT       可选。PNG 落点，默认 $HOME/shanhe-logs/frames/<BASE>-<FRAME>.png
#
#  保留策略：$OUT_DIR 里形如 `<BASE>-<帧号>.png` 的文件**只保留最近 20 份**
#      （`SHANHE_FRAME_KEEP` 可调；只扫该目录一层、只删本工具自己的命名，别处一律不动）。
#      与 shanhe-build.sh 的日志保留同一纪律 —— 长期目录不许无限膨胀。
#
#   ★★ 最重要的使用前提：**窗口必须是静止画面** ★★
#      上游每检查点最多 256 个像素探针，且**不允许两个检查点用同一帧**，
#      所以整屏只能由 150 个**连续帧**各取一块拼出来。画面一旦在动，
#      拼出来的是若干张不同画面的**混合体** —— 而且它往往看起来还挺整齐，
#      极具误导性（本项目实测踩过：一张"上半是模式选择、下半是存档槽"的图）。
#      ⇒ 本脚本会**跑两遍**（forward 把第 i 块取第 N+i 帧、reverse 取第 N+149-i 帧），
#        再把两张图逐像素比较，落成**四档**结论：
#
#          像素级完全静止   → 就是这一帧的精确截图
#          视觉上静止       → 差异全在 ±8 通道内（GBA 抖动噪声），可当截图用
#          基本静止         → **文字与版面可信**，只能用来辨认屏幕 / 读文本
#          画面在动         → 混合体，连文字都不可信，改用探针 / 区块哈希
#
#        这也比"看 framebuffer 哈希是否一致"更准 —— 整屏哈希含背景美术，
#        而菜单背景常是滚动/渐隐的，用哈希判会把静止菜单误判成"在动"。
#
#  隔离测试：python3 tools/shanhe-frame.test.py（合成采集，不依赖 ROM，覆盖四档）
#
#  产物（都不在仓库内）：PNG 落 ~/shanhe-logs/frames/，临时场景用后即删。
# ============================================================================
set -euo pipefail

for _arg in "$@"; do
  case "$_arg" in
    [A-Za-z_]*=*)
      printf '\n  \033[0;31m✗\033[0m 位置参数 "%s" 不会被识别 —— 本脚本的开关都是**环境变量**。\n' "$_arg" >&2
      printf '    正确写法： \033[0;36m%s %s\033[0m\n\n' "$_arg" "$0" >&2
      exit 2 ;;
  esac
done
unset _arg

FRAME="${FRAME:-}"
BASE="${BASE:-${SCENARIO:-shanhe-boot}}"   # ★ SCENARIO= 是 BASE= 的别名（见头注释）
SCALE="${SCALE:-3}"
[ -n "$FRAME" ] || { printf '\n  \033[0;31m✗\033[0m 必须给 FRAME=<帧号>\n\n' >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCK="$REPO_ROOT/framework.lock"
die() { printf '\n  \033[0;31m✗\033[0m %s\n\n' "$1" >&2; exit 1; }
ok()  { printf '  \033[0;32m✓\033[0m %s\n' "$1"; }

lock_get() {
  local section="$1" key="$2"
  awk -v sec="[$section]" -v k="$key" '
    $0 == sec { insec = 1; next }
    /^\[/     { insec = 0 }
    insec && $1 == k { sub(/^[^=]*=[ \t]*/, ""); sub(/[ \t\r]+$/, ""); print; exit }
  ' "$LOCK"
}

FW_REL="$(lock_get framework path)"
ABI="$(lock_get build modern_abi)"
ROM_LABEL="$(lock_get build rom_size_label)"
[ -n "$FW_REL" ] && [ -n "$ABI" ] && [ -n "$ROM_LABEL" ] || die "framework.lock 缺项"

FRAMEWORK_DIR="$HOME/$FW_REL"
PLAYTEST="$FRAMEWORK_DIR/tools/gba-playtest/gba_playtest.py"
ROM_FILE="$REPO_ROOT/shanhe-rom/shanhe-cn-$(printf '%s' "$ROM_LABEL" | tr '[:upper:]' '[:lower:]').gba"
ELF_FILE="$FRAMEWORK_DIR/build/expansion-modern/release/$ABI/fireemblem8.elf"
BASE_FILE="$REPO_ROOT/content/verify/scenarios/$BASE.json"

[ -f "$ROM_FILE" ] || die "找不到 ROM：$ROM_FILE（先跑 tools/shanhe-build.sh）"
[ -f "$ELF_FILE" ] || die "找不到 ELF：$ELF_FILE"
[ -f "$BASE_FILE" ] || die "找不到基础场景：$BASE_FILE"

OUT_DIR="${SHANHE_LOGS:-$HOME/shanhe-logs}/frames"
mkdir -p "$OUT_DIR"
OUT="${OUT:-$OUT_DIR/$BASE-$FRAME.png}"

# 保留策略（与 shanhe-build.sh 的日志保留同一纪律：长期目录不许无限膨胀）
#   安全边界：只删**本工具自己写出的** `<BASE>-<帧号>.png`（名字必须严格匹配），
#   只扫 $OUT_DIR 一层，OUT= 指向别处时一律不动。
prune_frames() {
  local keep="${SHANHE_FRAME_KEEP:-20}" total n=0 f
  total=$(find "$OUT_DIR" -maxdepth 1 -type f -name '*-[0-9]*.png' 2>/dev/null | wc -l)
  [ "$total" -le "$keep" ] && return 0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    [ "$f" = "$OUT" ] && continue
    rm -f -- "$f" || return 1
    n=$((n + 1))
  done < <(find "$OUT_DIR" -maxdepth 1 -type f -name '*-[0-9]*.png' -printf '%T@ %p\n' 2>/dev/null \
             | sort -rn | tail -n +$((keep + 1)) | cut -d' ' -f2-)
  [ "$n" -gt 0 ] && printf '  \033[0;2m取帧清理：%s 保留最近 %s 份（删除 %d 份）\033[0m\n' \
                          "$OUT_DIR" "$keep" "$n"
  return 0
}
prune_frames

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

printf '\n  \033[0;36m▶\033[0m 取帧：%s 的第 %s 帧（按键脚本来源：%s）\n' "$BASE" "$FRAME" "$BASE_FILE"
for ORDER in forward reverse; do
  python3 "$SCRIPT_DIR/shanhe-frame.py" gen "$BASE_FILE" "$FRAME" "$TMPD/scn-$ORDER.json" "$ORDER" >/dev/null
  python3 "$PLAYTEST" capture \
    --rom "$ROM_FILE" --elf "$ELF_FILE" --nm arm-none-eabi-nm \
    --scenario "$TMPD/scn-$ORDER.json" --output "$TMPD/cap-$ORDER.json" >/dev/null \
    || die "采集失败（帧号是否超出该场景的按键脚本范围？）"
done
python3 "$SCRIPT_DIR/shanhe-frame.py" render "$TMPD/cap-forward.json" "$TMPD/cap-reverse.json" "$OUT" "$SCALE"
ok "PNG：$OUT"
printf '\n'
