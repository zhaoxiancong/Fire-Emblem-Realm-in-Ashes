#!/usr/bin/env bash
# ============================================================
#  文档健康体检 —— 识别「格式化伪 diff」与「内容损坏」
#
#  用法：  bash tools/git-health.sh
#  性质：  只读检查，绝不修改任何文件
#  还原：  脚本只给命令，由你手动执行（避免误伤）
# ============================================================
set -u

cd "$(dirname "$0")/.." || exit 1

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "❌ 当前目录不是 git 仓库"
  exit 1
fi

echo "=================================================="
echo "  文档健康体检    $(date '+%Y-%m-%d %H:%M:%S')"
echo "=================================================="
echo ""

# ---- 0. 行尾规范（CRLF 检测）—— 独立检查，总是执行 ----
# 背景（2026-09-25 实测）：`.gitattributes` 规定 `* text=auto eol=lf`，
# 但若本地 `core.autocrlf=true`，Windows 侧某些文件会被写成 CRLF。后果：
#   ① git status 出现「假 modified」（git diff 为空却报改动）
#   ② 未来编辑该文件时产生「整文件伪 diff」，掩盖真实改动
echo "--- 0. 行尾规范（CRLF 检测）---"
CR="$(printf '\r')"
CRLF_FOUND=0
while IFS= read -r f; do
  n="$(grep -c "$CR" "$f" 2>/dev/null)"
  n="${n:-0}"
  if [ "$n" != "0" ]; then
    printf '  ⚠️  %-46s CR行=%s\n' "$f" "$n"
    CRLF_FOUND=$((CRLF_FOUND+1))
  fi
done < <(git ls-files | grep -vE '\.(png|jpg|jpeg|gif|ogg|wav|mp3|ttf|otf|psd|gba|bin|sav|o|a)$')

if [ "$CRLF_FOUND" -eq 0 ]; then
  echo "  ✅ 所有受版本控制的文本文件都是 LF（符合 .gitattributes）"
else
  echo ""
  echo "  ⚠️  发现 $CRLF_FOUND 个含 CRLF 的文件 —— 修复方法："
  echo "      git config core.autocrlf false            # 让 .gitattributes(eol=lf) 独占控制"
  echo "      rm -f <文件> && git checkout -- <文件>     # 重新检出为 LF"
fi
echo ""

PORCELAIN="$(git status --porcelain)"

if [ -z "$PORCELAIN" ]; then
  if [ "$CRLF_FOUND" -eq 0 ]; then
    echo "✅ 工作区干净，且行尾规范 —— 一切正常。"
  else
    echo "⚠️  工作区无内容改动，但有 $CRLF_FOUND 个文件行尾不规范（见上）。"
  fi
  exit 0
fi

echo "--- 1. 工作区状态 ---"
git status --short
echo ""

echo "--- 2. 逐个文件：真实差异（已忽略换行与空白）---"
printf '%-5s %-50s %s\n' "状态" "文件" "真实差异(增/删行)"
printf '%-5s %-50s %s\n' "-----" "--------------------------------------------------" "----------------"

echo "$PORCELAIN" | while IFS= read -r line; do
  [ -z "$line" ] && continue
  st="${line:0:2}"
  path="${line:3}"
  path="${path#\"}"; path="${path%\"}"

  if [ "$st" = "??" ]; then
    printf '%-5s %-50s %s\n' "??" "$path" "（新文件，未追踪）"
    continue
  fi

  numstat="$(git diff --ignore-all-space --numstat -- "$path" 2>/dev/null | head -1)"
  if [ -z "$numstat" ]; then
    printf '%-5s %-50s %s\n' "$st" "$path" "无内容差异（纯格式/换行）"
  else
    add="$(printf '%s' "$numstat" | awk '{print $1}')"
    del="$(printf '%s' "$numstat" | awk '{print $2}')"
    printf '%-5s %-50s %s\n' "$st" "$path" "+${add} / -${del}"
  fi
done

echo ""
echo "--- 3. 怎么判断 ---"
cat <<'HINT'
  ·「无内容差异」   → 只是格式化伪 diff（表格对齐 / 补空行），可保留也可还原
  ·「有 +N / -M」   → 有真实改动，需人工看一眼：
        - 是你自己改的   → 正常，提交即可
        - 你没动过       → 警惕「内容损坏」，重点查这三类：
            ① 中文被转成 HTML 实体    例如  打开 → &#x5F00;
            ② Markdown 强调符 * 被挪位 / 列表符号错乱
            ③ 表格被空行从中间切断
HINT
echo ""
echo "--- 4. 还原命令（脚本不会自动执行）---"
cat <<'HINT'
  看单个文件的详细差异：   git diff --ignore-all-space -- <文件>
  还原单个文件：           git checkout HEAD -- <文件>
  还原全部改动：           git checkout HEAD -- .
HINT
echo ""
echo "⚠️  内容损坏（① ② ③ 类）一律还原，不要提交。详见 GIT_WORKFLOW.md §6"
