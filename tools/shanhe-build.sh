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
#
# 环境变量可覆盖：
#   FRAMEWORK_DIR=/path   框架位置（默认 $HOME/projects/fireemblem8-expansion）
#   CONTENT_DIR=/path     内容位置（默认本仓库的 content/）
#   SHANHE_ROM_DIR=/path  导出目录（默认 /mnt/d/workbuddy/shanhe-rom）
#   CLASH_PORT=7897       代理端口
#
# 规范：docs/6.方案B内容外置规划.md §3
# 依赖声明：framework.lock
# ============================================================

set +e
export LANG=C.UTF-8 LC_ALL=C.UTF-8

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

die() { bad "$1"; printf "\n  日志：%s\n" "$REPORT"; exit 1; }

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

FRAMEWORK_REPO="$(lock_get framework repo)"
FRAMEWORK_COMMIT="$(lock_get framework commit)"
FRAMEWORK_BRANCH="$(lock_get framework branch)"
FRAMEWORK_SUBJECT="$(lock_get framework commit_subject)"
MG_COMMIT="$(lock_get submodule.mgfembp commit)"
MG_PROBE="$(lock_get submodule.mgfembp probe_file)"
MAKE_TARGET="$(lock_get build make_target)"
M_CFG="$(lock_get build modern_config)"
M_ABI="$(lock_get build modern_abi)"
ROM_REL="$(lock_get build rom_path)"
ROM_BYTES="$(lock_get build rom_size_bytes)"
TITLE_EXPECT="$(lock_get build rom_header_game_title)"
CODE_EXPECT="$(lock_get build rom_header_game_code)"

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
  printf "  %s→ 确认还原？(y/N) %s" "$c_yellow" "$c_off"
  read -r ans
  case "$ans" in
    y|Y) ;;
    *) bad "已取消，未做任何改动"; exit 0 ;;
  esac

  # 三级递进还原（对 skip-worktree/assume-unchanged 也有效）
  act "git checkout HEAD -- ."
  git -C "$FRAMEWORK_DIR" checkout HEAD -- . 2>&1 | sed 's/^/      /' | tee -a "$REPORT"
  act "git restore --source=HEAD --staged --worktree ."
  git -C "$FRAMEWORK_DIR" restore --source=HEAD --staged --worktree . 2>&1 | sed 's/^/      /' | tee -a "$REPORT"

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
  printf "\n  %s→ 继续？(y/N) %s" "$c_yellow" "$c_off"
  read -r ans
  case "$ans" in y|Y) ;; *) bad "已中止"; exit 1 ;; esac
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
TARGETS_FILE="$(mktemp)"
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

# ══════════════════════════════════════════
# 第 3 步 · 铺设
# ══════════════════════════════════════════
H "第 3 步 / 铺设（合并 content/ → 框架）"

MERGED_COUNT=0
SKIPPED_COUNT=0

# ── 3a. data/*.json 按语义合并 ──
merge_json() {
  local name="$1" src="$CONTENT_DIR/data/$1" dst="$FRAMEWORK_DIR/src/data/$1"
  if [ ! -f "$dst" ]; then
    warn "[$name] 框架侧无此文件，跳过（原创新表需人工确认落点）"
    SKIPPED_COUNT=$((SKIPPED_COUNT+1)); return 0
  fi
  python3 - "$src" "$dst" "$name" "$DRY_RUN" <<'PY'
import json, sys, copy
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
    WHOLE_TABLE_REPLACE = ("weapontriangle.json",)
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
    with open(dst, "w", encoding="utf-8") as f: f.write(out)
PY
}

if [ -d "$CONTENT_DIR/data" ] && [ -n "$(ls -A "$CONTENT_DIR/data" 2>/dev/null)" ]; then
  for f in "$CONTENT_DIR/data"/*.json; do
    [ -f "$f" ] || continue
    name="$(basename "$f")"
    if [ "$DRY_RUN" = "1" ]; then
      act "[预演] 合并 data/$name → src/data/$name"
    else
      merge_json "$name" || die "合并 $name 失败"
    fi
    MERGED_COUNT=$((MERGED_COUNT+1))
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

if [ "$DRY_RUN" != "1" ] && [ "$MERGED_COUNT" -gt 0 ] && [ -d "$FRAMEWORK_DIR/scripts/generated_data" ]; then
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
      if cp -f "$FRAMEWORK_DIR/$GEN" "$FRAMEWORK_DIR/$HAND" 2>/dev/null; then
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
      *" $base "*) ;;
      *) warn "content/data/$base.json 不在自动处理名单（可能是章节表/新表）—— 请确认其落点与 round-trip 策略" ;;
    esac
  done
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
    else
      mkdir -p "$(dirname "$dst")"
      cp "$src" "$dst"
      act "[copy] texts/$rel"
    fi
    MERGED_COUNT=$((MERGED_COUNT+1))
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
    if python3 - "$patch" "$FRAMEWORK_DIR" <<'PY' >> "$REPORT" 2>&1
import json, sys, os
patch_path, fw = sys.argv[1], sys.argv[2]
patch = json.load(open(patch_path, encoding="utf-8"))
dst = os.path.join(fw, "texts/locales/indexed_overrides.json")
base = json.load(open(dst, encoding="utf-8"))
sk = patch.get("source_key", "fe8cn_source")
if sk not in base.get("sources", {}):
    print(f"  framework overrides missing sources.{sk}"); sys.exit(2)
entries = base["sources"][sk]["entries"]
n = 0
for sid, rec in patch.get("overrides", {}).items():
    key = "0x%04X" % int(sid, 16)
    missing = [k for k in ("expected_text", "provenance", "reason", "replacement_text") if k not in rec]
    if missing:
        print(f"  override {sid} missing fields: {missing}"); sys.exit(2)
    entries[key] = {k: rec[k] for k in ("expected_text", "provenance", "reason", "replacement_text")}
    n += 1
with open(dst, "w", encoding="utf-8") as f:
    json.dump(base, f, ensure_ascii=False, indent=2)
print(f"  merged {n} overrides from {os.path.basename(patch_path)}")
PY
    then
      ok "[文本] $name 合并入 indexed_overrides.json"
      TEXT_OVR_N=$((TEXT_OVR_N+1)); MERGED_COUNT=$((MERGED_COUNT+1))
    else
      bad "[文本] $name 合并失败"; tail -10 "$REPORT" | sed 's/^/      /'
      die "[文本] 覆盖补丁合并失败"
    fi
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
      # ⚠️ 幂等：先把 texts.txt 还原为钉住版本（HEAD）再打补丁。
      #    否则第二次运行时，当前内容已是上一次写入的中文，
      #    补丁里的 expected_text（英文原文）必然对不上 → 构建失败。
      #    （2026-09-25 实机踩到：## MSG_030A 期望与实际不符）
      if ! ( cd "$FRAMEWORK_DIR" && git checkout HEAD -- texts/texts.txt ) 2>/dev/null; then
        bad "[消息表] 无法还原 texts/texts.txt（文件不在 git 追踪内？）"
        continue
      fi
      if python3 - "$patch" "$FRAMEWORK_DIR/texts/texts.txt" "$DRY_RUN" <<'PYMSG' >> "$REPORT" 2>&1
import json, re, sys
patch_path, target_path = sys.argv[1], sys.argv[2]
with open(patch_path, encoding="utf-8") as f:
    patch = json.load(f)
msgs = patch.get("messages") or {}
if not msgs:
    print("msg_overrides: 无 messages，跳过"); sys.exit(0)
with open(target_path, encoding="utf-8") as f:
    lines = f.read().split("\n")

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

with open(target_path, "w", encoding="utf-8") as f:
    f.write("\n".join(lines))
print(f"msg_overrides: 共 {applied} 条")
PYMSG
      then
        ok "[消息表] $(basename "$patch") 已合并进 texts/texts.txt"
      else
        bad "[消息表] 合并失败：$(basename "$patch")"
        tail -20 "$REPORT" | sed 's/^/      /'
        die "[消息表] texts.txt 覆盖失败（expected_text 不符或 target id 有误）"
      fi
    fi
  done < <(printf '%s\n' "$MSG_OVERRIDE_PATCHES")
  [ "$DRY_RUN" = "1" ] && [ "$MSG_OVR_N" -gt 0 ] && dim "共 $MSG_OVR_N 个消息表补丁待合并"
else
  dim "content/texts/ 无 msg_overrides 补丁 —— ROM 消息表保持上游原文"
fi

# ── 3c. src/*.c 铺为 src/shanhe_*.c ──
SRC_ADDED=0
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
    if [ "$DRY_RUN" = "1" ]; then
      act "[预演] 铺设 src/$base → src/$out"
    else
      cp "$f" "$FRAMEWORK_DIR/src/$out"
      act "[copy] src/$base → src/$out"
    fi
    SRC_ADDED=$((SRC_ADDED+1))
  done > /dev/null 2>&1 || true
  # 重新打印（上面的 act 已写日志，这里补屏幕输出）
  SRCS="$(ls "$CONTENT_DIR/src"/*.c 2>/dev/null | wc -l)"
  if [ "$SRCS" -gt 0 ]; then
    if [ "$DRY_RUN" = "1" ]; then
      dim "共 $SRCS 个 .c 待铺设（上方已逐条列出）"
    else
      ok "共 $SRC_ADDED 个 .c 已铺入 src/"
      ok "已 touch Makefile（wildcard 解析期展开，必须触发生成器重扫）"
      touch "$FRAMEWORK_DIR/Makefile"
    fi
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
    if tar xzf "$FONT_PATCH" -C "$FRAMEWORK_DIR" 2>/dev/null; then
      FONT_N="$(tar tzf "$FONT_PATCH" 2>/dev/null | grep -c . || echo 0)"
      ok "字库补丁已铺设：$FONT_N 项（$(basename "$FONT_PATCH")）"
    else
      bad "字库补丁解包失败：$FONT_PATCH"
    fi
  fi
else
  dim "content/fonts/ 无字库补丁 —— 沿用框架上游字库"
fi

# ── 3c''. 框架补丁（★ 已知偏离：本通道会覆写框架文件）──
# 仅用于「框架缺陷、且数据层修不了」的情形。当前仅一个补丁：
#   uimenu-empty-menu-guard —— 教学关卡 Menu_OnInit 读未初始化 menuItems[] 导致
#   野指针跳转（实机复现 PC=0x708E02B4）。详见 docs/5 §5.7 / docs/6 §3.4g。
# 形式：unified diff，基线 = framework.lock 钉住的 commit。
# 幂等：先 `git checkout HEAD -- <目标>` 还原，再 apply；apply 失败即中止
#       （宁可不构建，也不要静默漏补 —— 漏补会退回"崩溃但没人知道"）。
FRAMEWORK_PATCHES="$(find "$CONTENT_DIR/framework-patch" -maxdepth 1 -type f -name '*.patch' 2>/dev/null | sort)"
if [ -n "$FRAMEWORK_PATCHES" ]; then
  PATCH_N=0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    name="$(basename "$p")"
    target="$(grep -m1 '^+++ b/' "$p" | sed 's|^+++ b/||')"
    if [ -z "$target" ]; then
      bad "[补丁] $name 解析不出目标文件（缺 '+++ b/<path>' 行）"; continue
    fi
    if [ "$DRY_RUN" = "1" ]; then
      act "[预演] 框架补丁 $name → $target"
    else
      if ! ( cd "$FRAMEWORK_DIR" && git checkout HEAD -- "$target" ) 2>/dev/null; then
        bad "[补丁] $name 无法还原 $target（文件不存在或不在 git 追踪内）"; continue
      fi
      if ( cd "$FRAMEWORK_DIR" && patch -p1 -N --no-backup-if-mismatch -i "$p" ) >> "$REPORT" 2>&1; then
        ok "[补丁] $name 已应用 → $target"
        PATCH_N=$((PATCH_N+1))
      else
        bad "[补丁] $name 应用失败 —— 上游可能已改动该文件上下文"
        die "框架补丁无法应用，需人工 rebase（见 docs/6 §3.4g）"
      fi
    fi
  done <<< "$FRAMEWORK_PATCHES"
  [ "$DRY_RUN" = "1" ] || warn "★ 已应用 $PATCH_N 个框架补丁 —— 本项目【已知偏离】，升级框架时必须重新评估"
else
  dim "content/framework-patch/ 无补丁 —— 框架保持只读（正常状态）"
fi

# ── 3d. assets 提示 ──
if [ -d "$CONTENT_DIR/assets" ] && [ -n "$(find "$CONTENT_DIR/assets" -type f -not -name '.gitkeep' 2>/dev/null)" ]; then
  warn "content/assets/ 有文件 —— 资产需按其「拥有缝」登记（见 docs/8），"
  dim "当前脚本只做提示，不做资产登记（四动词管线：make assets-validate/-generate/-check/-test）"
fi

act "铺设完成：合并/铺设 $MERGED_COUNT 项，跳过 $SKIPPED_COUNT 项"

# ══════════════════════════════════════════
# 第 4 步 · 构建
# ══════════════════════════════════════════
H "第 4 步 / 构建"

if [ "$DRY_RUN" = "1" ]; then
  act "[预演] 将执行：cd $FRAMEWORK_DIR && make $MAKE_TARGET"
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
  act "make $MAKE_TARGET（日志：$BUILD_LOG）"
  dim "首次/改表后编译较慢，请耐心…"
  ( cd "$FRAMEWORK_DIR" && make "$MAKE_TARGET" ) > "$BUILD_LOG" 2>&1
  RC=$?
  if [ $RC -eq 0 ]; then
    ok "构建成功"
  else
    bad "构建失败（exit $RC）"
    dim "最后 25 行日志："
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

  # ④ 可引导（mGBA 无头启动，不比对像素）
  if command -v mgba-sdl >/dev/null 2>&1 || [ -x /usr/games/mgba-sdl ]; then
    MG="$(command -v mgba-sdl || echo /usr/games/mgba-sdl)"
    timeout 12 "$MG" -l 0 -C "frames=60" "$FRAMEWORK_ROM" >/dev/null 2>&1
    RC=$?
    if [ $RC -eq 0 ] || [ $RC -eq 124 ]; then
      ok "④ 可引导（mGBA 跑 60 帧无崩溃）"
    else
      warn "④ mGBA 退出码 $RC（可能只是无头模式限制，建议人工目视确认）"
    fi
  else
    warn "④ 无 mgba-sdl，跳过可引导检查（Windows 侧用 mGBA 目视）"
  fi

  # ⑤ 中文字形（粗检：ROM 内应含字库段；精检需实机）
  CN_SIZE="$(stat -c %s "$FRAMEWORK_ROM")"
  if [ "$CN_SIZE" -gt 20000000 ]; then
    ok "⑤ 已启用中文（ROM ≥ 32M，含 locale bank）—— 请用 mGBA 目视确认汉字"
  else
    warn "⑤ ROM 偏小，可能未启用中文 locale（检查 config.autotools.mk）"
  fi

  ROM_SHA1="$(sha1sum "$FRAMEWORK_ROM" | cut -c1-8)"
  act "产物 SHA1（前 8 位）：$ROM_SHA1  ·  基线中文版：$(lock_get baseline baseline_cn_rom_sha1)"
  dim "改内容后 SHA1 本就该变 —— 这一步是记录，不是门禁"
fi

# ══════════════════════════════════════════
# 第 5b 步 · 导出 ROM 到 Windows 侧（方便直接试玩）
# ══════════════════════════════════════════
H "第 5b 步 / 导出 ROM 到 Windows 侧"

# 目标目录：Windows 的 D:\workbuddy\shanhe-rom 在 WSL 视角 = /mnt/d/workbuddy/shanhe-rom
EXPORT_DIR="${SHANHE_ROM_DIR:-/mnt/d/workbuddy/shanhe-rom}"
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
  dim "Windows 路径：D:\\workbuddy\\shanhe-rom\\$EXPORT_NAME"
  dim "SHA1 校验一致（$EXPORT_SHA1）✓ —— 试玩目录与本次产物是同一个 ROM"
  dim "双击启动：D:\\workbuddy\\shanhe-rom\\启动山河烬中文版.cmd"
fi

# ══════════════════════════════════════════
# 第 6 步 · 反查
# ══════════════════════════════════════════
H "第 6 步 / 反查框架侧改动（防呆关键）"

if [ "$DRY_RUN" = "1" ]; then
  act "[预演] 将比对 git status 与第 2 步快照，高亮「预期外」改动"
else
  CUR="$(mktemp)"
  git -C "$FRAMEWORK_DIR" status --porcelain > "$CUR"

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
        src/events/*.h) ;;                                        # ★★ 预期（框架补丁：教学脚本 keep-wait，见 3c''）
        src/bmbattle.c) ;;                                        # ★★ 预期（框架补丁：weapontriangle 参考块，见 3c''）
        reports/*) ;;                                             # ★ 预期（generated-data 的 inventory/审计报告是 generate 的正常副产物）
        src/uimenu.c) ;;                                          # ★★ 预期（框架补丁：历史目标，见 3c''）
        build/*|*/build/*) ;;                                     # 构建产物，正常
        *)
          printf "  %s⚠ 预期外改动：%s%s\n" "$c_yellow" "$path" "$c_off"
          UNEXPECTED=$((UNEXPECTED+1))
          ;;
      esac
    done < "$CUR"

    if [ "$UNEXPECTED" -eq 0 ]; then
      ok "反查通过：所有改动都在预期范围内（src/data/、src/data_*.c(回填)、texts/、docs/game_locale_text_edits.md(台账)、fonts/cjk/(字库补丁)、src/events/*.h(框架补丁:教学脚本)、src/shanhe_*.c、Makefile、build/）"
    else
      warn "发现 $UNEXPECTED 项预期外改动 —— 请人工确认是否为手滑直接改了框架"
      dim "如确认是误改：bash tools/shanhe-build.sh RESTORE=1"
    fi
  fi
  rm -f "$CUR"
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
  printf "    · 实机试玩             → 双击 D:\\workbuddy\\shanhe-rom\\启动山河烬中文版.cmd\n"
fi
exit 0
