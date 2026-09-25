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

# ── 5. README 文档表：版本号核对 ──────────────────────────────
# 背景：README.md 的「设计文档」表里写着每份文档的版本号，但**它不会自动跟着文档走**。
#       2026-09-25 实测：6 处版本号集体过期（docs/3 写 v0.2 实际 v0.5、docs/5 写 v0.7 实际 v0.17 …）。
#       本节把「README 表」与「各文档头部」逐项对拍，不一致就报出来。
echo ""
echo "--- 5. README 文档表：版本号核对 ---"
PYBIN="$(command -v python3 2>/dev/null || command -v python 2>/dev/null)"
if [ -z "$PYBIN" ]; then
  echo "  （未找到 python，跳过本节）"
else
  "$PYBIN" - <<'PYCHECK'
import os, re, subprocess, sys

root = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                      capture_output=True, text=True).stdout.strip() or "."
readme = os.path.join(root, "README.md")
if not os.path.isfile(readme):
    print("  （找不到 README.md，跳过）"); sys.exit(0)

# README 表里的 路径 -> 版本
rows = {}
for ln in open(readme, encoding="utf-8"):
    m = re.match(r"^\|\s*\[`([^`]+)`\]\(([^)]+)\)\s*\|.*\|\s*(v\d+\.\d+)\s*\|\s*$", ln)
    if m:
        rows[m.group(2)] = m.group(3)

def doc_version(path):
    """从文档头部取版本号。
    优先匹配『版本声明行』（形如 `> 版本：v0.5` / `**文档版本**：v1.2` / `# … v0.5`），
    取不到再退化到「前 12 行里任意 vN.N」。
    返回 (版本, 状态)：状态 ∈ {ok, 文件缺失, 未识别版本}
    """
    p = None
    for cand in (os.path.join(root, path), path, os.path.join(".", path)):
        if os.path.isfile(cand):
            p = cand
            break
    if p is None:
        return None, "文件缺失"
    try:
        head = [ln.rstrip("\n") for ln in list(open(p, encoding="utf-8"))[:40]]
    except Exception:
        return None, "未识别版本"
    # ① 版本声明行（最可靠）—— 头部块可能到 20 行左右（如 `**文档版本**：v1.17`）
    for ln in head[:25]:
        if re.search(r"(版本|version|Version)", ln):
            m = re.search(r"v?(\d+\.\d+)", ln)
            if m:
                return "v" + m.group(1), "ok"
    # ② 退化：标题行里的 vN.N
    for ln in head[:12]:
        if ln.startswith("#"):
            m = re.search(r"v(\d+\.\d+)", ln)
            if m:
                return "v" + m.group(1), "ok"
    # ③ 再退化：前 12 行任意 vN.N
    for ln in head[:12]:
        m = re.search(r"v(\d+\.\d+)", ln)
        if m:
            return "v" + m.group(1), "ok"
    return None, "未识别版本"

bad, missing = [], []
for path, ver in sorted(rows.items()):
    real, why = doc_version(path)
    if real is None:
        bad.append((path, ver, why))
    elif real != ver:
        bad.append((path, ver, real))

# docs/ 下有、README 表里没有
docs = sorted(f for f in os.listdir(os.path.join(root, "docs"))
              if f.endswith(".md"))
for f in docs:
    rel = "docs/" + f
    if rel not in rows:
        missing.append(rel)

if not bad and not missing:
    print("  ✅ README 文档表与各文档头部一致（共 %d 份）" % len(rows))
else:
    for path, ver, real in bad:
        if real in ("文件缺失", "未识别版本"):
            print("  ⚠️ %s：%-40s（README 写 %s）⇒ 建议给该文档头部补一行「> 版本：vX.Y」" % (real, path, ver))
        else:
            print("  ⚠️ 版本号过期：%-40s README=%s  实际=%s" % (path, ver, real))
    for rel in missing:
        print("  ⚠️ README 表缺行：%s" % rel)
    print("  ⇒ 请同步 README.md 的「设计文档」表后再提交")
PYCHECK
fi

echo ""
echo "⚠️  内容损坏（① ② ③ 类）一律还原，不要提交。详见 GIT_WORKFLOW.md §6"
