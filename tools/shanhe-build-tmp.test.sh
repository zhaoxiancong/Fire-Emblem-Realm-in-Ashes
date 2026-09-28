#!/usr/bin/env bash
# 隔离测试：shanhe-build.sh 的临时文件登记制（tmp_track / cleanup_tmp）
#
# 从**真实脚本**里抽出函数体再测（不接受抄一份副本 —— 副本会漂移）。
# 用法： bash tools/shanhe-build-tmp.test.sh [shanhe-build.sh 路径]
#
# 背景（2026-09-29）：第 2 / 6 步的 mktemp 此前**从不回收**，/tmp 里累积 605 B 残留。
# 修法是"父 shell 两行式"登记（`VAR="$(mktemp)"; tmp_track "$VAR"`）——
# 之所以不能做成一步封装，是因为命令替换 `$( )` 在**子 shell** 里执行，
# 函数内的数组追加不会传回父 shell。T2 就是这个陷阱的**反面证据**。
set +e
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:-$HERE/shanhe-build.sh}"

if [ ! -f "$SRC" ]; then
  echo "!! 找不到被测脚本：$SRC" >&2
  exit 1
fi

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# 抽出 SHANHE_TMP_PATHS=() 起、到第一个列首 "}" 止的函数块
sed -n '/^SHANHE_TMP_PATHS=()/,/^}$/p' "$SRC" > "$TMPD/funcs.sh"
if ! grep -q '^cleanup_tmp() {' "$TMPD/funcs.sh"; then
  echo "!! 抽取失败：未取到 cleanup_tmp"; cat "$TMPD/funcs.sh"; exit 1
fi
echo "抽取到的函数块（$(wc -l < "$TMPD/funcs.sh") 行）:"
sed 's/^/    /' "$TMPD/funcs.sh"
echo

PASS=0; FAIL=0
ck() { # ck <描述> <实际> <期望>
  if [ "$2" = "$3" ]; then printf '  ✓ %s\n' "$1"; PASS=$((PASS+1))
  else printf '  ✗ %s（实际=%s 期望=%s）\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}

# shellcheck disable=SC1090
. "$TMPD/funcs.sh"

echo "T1 · 两行式登记**真的**写进父 shell 的数组（子 shell 陷阱的正面证据）"
A="$(mktemp)"; tmp_track "$A"
B="$(mktemp -d)"; tmp_track "$B"
C="$(mktemp -t shanhe-tmp-test-XXXXXX.zz)"; tmp_track "$C"
ck "登记了 3 条" "${#SHANHE_TMP_PATHS[@]}" "3"

echo "T2 · 反面证据：一步封装 \$( ) 形式确实**失效**（复现子 shell 陷阱）"
bad_mktemp_tracked() { local f; f="$(mktemp)"; SHANHE_TMP_PATHS+=("$f"); printf '%s' "$f"; }
D="$(bad_mktemp_tracked)"; D_COUNT="${#SHANHE_TMP_PATHS[@]}"
ck "一步封装后数组仍是 3（追加丢失）" "$D_COUNT" "3"
rm -f "$D"   # 手动收尾，避免测试自己漏文件

echo "T3 · 空参数是 no-op，不产生幽灵条目"
tmp_track ""
ck "空串被忽略" "${#SHANHE_TMP_PATHS[@]}" "3"

echo "T4 · cleanup_tmp 真的删掉两条文件 + 一条目录"
cleanup_tmp
LEFT=0
[ -e "$A" ] && LEFT=$((LEFT+1))
[ -e "$B" ] && LEFT=$((LEFT+1))
[ -e "$C" ] && LEFT=$((LEFT+1))
ck "三者均已消失" "$LEFT" "0"
ck "数组已清空" "${#SHANHE_TMP_PATHS[@]}" "0"

echo "T5 · cleanup_tmp 可重复调用（幂等，空数组不报错）"
cleanup_tmp; RC=$?
ck "第二次 rc" "$RC" "0"

echo "T6 · cleanup_tmp 对已不存在的路径不报错（rm -rf 语义）"
E="$(mktemp)"; tmp_track "$E"; rm -f "$E"
cleanup_tmp; RC=$?
ck "目标已先被删，rc 仍为 0" "$RC" "0"

echo "T7 · die() 会调用 cleanup_tmp（脚本里确有该调用）"
if grep -q 'die() { bad "$1"; cleanup_tmp;' "$SRC"; then
  printf '  ✓ die 定义里含 cleanup_tmp\n'; PASS=$((PASS+1))
else
  printf '  ✗ die 定义里没有 cleanup_tmp 调用\n'; FAIL=$((FAIL+1))
fi

echo "T8 · 脚本里所有 mktemp 落点要么登记、要么自回收（防回归）"
# write_if_changed 是唯一允许的裸 mktemp（它自己 rm）；其余必须 tmp_track
BARE="$(grep -n 'mktemp' "$SRC" | grep -v '^\s*[0-9]*:#' | grep -v 'tmp_track' | grep -v 'shanhe-wic-XXXXXX')"
if [ -z "$BARE" ]; then
  printf '  ✓ 无未登记的裸 mktemp\n'; PASS=$((PASS+1))
else
  printf '  ✗ 存在未登记的裸 mktemp：\n%s\n' "$BARE"; FAIL=$((FAIL+1))
fi

printf '\n结果：%d 通过 / %d 失败\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
