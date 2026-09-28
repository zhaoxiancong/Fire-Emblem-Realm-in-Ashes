#!/usr/bin/env bash
# ============================================================================
#  _font_render_from_corpora.sh —— 从语料渲染字库（土办法的"后半段"）
# ============================================================================
#
#  配套 tools/wsl/_font_add_needed.py（前半段：算需求 → 改语料 → 改清单 sha）。
#
#  ★ 为什么不用框架的 `generate-inventory`：它被**上游 ja 侧**的 alias 缺失挡死
#    （`ja/character_name_40/... 46px exceeds 40px without a display alias`），
#    而 ja 不是本项目启用的语言（framework.lock `[locales] enabled = en,zh-Hans`）。
#    ⇒ 我们直接给 FEBuilder 喂语料，绕开那一步。
#
#  前置：
#    · 工具链在 WSL 用户态：~/.dotnet（dotnet SDK）+ ~/FEBuilderGBA（自建 CLI）
#    · 上游 FEHRR 仓库：~/fehrr-upstream（`--fehrr-root` **必须**是它，
#      不是本项目仓库的符号链接 —— 它会校验 origin 且要求工作区干净）
#
#  步骤（顺序不能乱）：
#    dry-run → generate → validate → roundtrip → record-gates → archive-package
#    → import-package（写 graphics/fonts/cjk 真字形）
#    → 提升冻结基线（**推导式**：把 runtime 里有、baseline 里没有的字并入）
#    → cp manifest → baseline-manifest
#    → split-runtime-corpora（FEHRR 宽度优先覆盖 —— 不跑它名字宽度会变、构建报溢出）
#    → 重打包 content/fonts/shanhe-font-patch.tar.gz
#
#  用法（在本仓库根目录）：bash tools/wsl/_font_render_from_corpora.sh
#  环境变量：KEEP_PACKAGE=1 保留 build/tmp/cjk-fonts 里的中间产物
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FRAMEWORK_DIR="${FRAMEWORK_DIR:-$HOME/projects/fireemblem8-expansion}"
FEHRR_UPSTREAM="${FEHRR_UPSTREAM:-$HOME/fehrr-upstream}"
FEBBUILDER_DIR="${FEBBUILDER_DIR:-$HOME/FEBuilderGBA}"
DOTNET="${DOTNET:-$HOME/.dotnet/dotnet}"

cd "$FRAMEWORK_DIR"

CLI="$DOTNET $FEBBUILDER_DIR/FEBuilderGBA.CLI/bin/Release/net10.0/FEBuilderGBA.CLI.dll"
PY="python3 -m scripts.fonttools.cjk"
M=fonts/cjk/febuilder-manifest.json
BD=build/tmp/cjk-fonts
TARBALL="$REPO_ROOT/content/fonts/shanhe-font-patch.tar.gz"

ok()   { printf '  \033[0;32m✓\033[0m %s\n' "$1"; }
step() { printf '\n  \033[0;36m▶\033[0m %s\n' "$1"; }
die()  { printf '\n  \033[0;31m✗\033[0m %s\n\n' "$1" >&2; exit 1; }

[ -x "$DOTNET" ] || die "找不到 dotnet：$DOTNET（见 docs/5 §5.18.11 的工具链重建）"
[ -f "$FEBBUILDER_DIR/FEBuilderGBA.CLI/bin/Release/net10.0/FEBuilderGBA.CLI.dll" ] \
  || die "找不到 FEBuilderGBA.CLI（在 $FEBBUILDER_DIR 构造）"
[ -d "$FEHRR_UPSTREAM/.git" ] || die "找不到上游 FEHRR 仓库：$FEHRR_UPSTREAM"
[ -f "$TARBALL" ] || die "找不到字库补丁：$TARBALL"

mkdir -p "$BD"
cleanup() { [ "${KEEP_PACKAGE:-0}" = "1" ] || rm -rf "$BD/package" "$BD/dry-run-package" "$BD/febuilder-schema-v1.zip"; }
trap cleanup EXIT

step "1/9 FEBuilder dry-run"
rm -rf "$BD/dry-run-package" "$BD/dry-run-report.json"
$CLI --build-font-library --manifest="$M" --out="$BD/dry-run-package" --mode=dry-run \
     --report="$BD/dry-run-report.json" >/dev/null || die "dry-run 失败"

step "2/9 FEBuilder generate"
rm -rf "$BD/package" "$BD/generation-report.json"
$CLI --build-font-library --manifest="$M" --out="$BD/package" --mode=generate \
     --report="$BD/generation-report.json" >/dev/null || die "generate 失败"

step "3/9 FEBuilder validate"
$CLI --build-font-library --manifest="$M" --out="$BD/package" --mode=validate \
     --report="$BD/generation-report.json" >/dev/null || die "validate 失败"

step "4/9 FEBuilder roundtrip"
$CLI --build-font-library --manifest="$M" --out="$BD/package" --mode=roundtrip \
     --report="$BD/generation-report.json" >/dev/null || die "roundtrip 失败"

step "5/9 record-gates（不记会让 split-runtime 报 provenance drifted）"
$PY record-gates \
  --dry-run-report "$BD/dry-run-report.json" \
  --generation-report "$BD/generation-report.json" \
  --output-report fonts/cjk/reports/febuilder-generation-report.json \
  --gate-report fonts/cjk/reports/febuilder-gates.json \
  --cli-command "FEBuilderGBA.CLI --build-font-library" \
  --commit "$(git -C "$FEBBUILDER_DIR" rev-parse HEAD)" \
  --dotnet-sdk "$("$DOTNET" --version)" \
  --repository https://github.com/laqieer/FEBuilderGBA >/dev/null || die "record-gates 失败"

step "6/9 archive-package"
$PY archive-package --package-dir "$BD/package" --output "$BD/febuilder-schema-v1.zip" >/dev/null \
  || die "archive-package 失败"

step "7/9 import-package（写运行时真字形）"
$PY import-package --package "$BD/febuilder-schema-v1.zip" --report "$BD/generation-report.json" >/dev/null \
  || die "import-package 失败"

step "8/9 提升冻结基线 + split-runtime-corpora（推导式，无手抄名单）"
python3 - "$FRAMEWORK_DIR" <<'PY' || die "提升基线失败"
import io, json, struct, sys, os
FW = sys.argv[1]
BASE = os.path.join(FW, "fonts/cjk/febuilder-baseline")
SRC = os.path.join(FW, "graphics/fonts/cjk")
promoted = 0
for style in ("system", "talk"):
    p = "zh-Hans.%s" % style

    def load(d):
        cp = io.open(os.path.join(d, p + ".codepoints.u32le"), "rb").read()
        return (list(struct.unpack("<%dI" % (len(cp) // 4), cp)),
                list(io.open(os.path.join(d, p + ".widths.u8"), "rb").read()),
                io.open(os.path.join(d, p + ".glyphs.2bpp"), "rb").read())

    sa, sw, sg = load(SRC)      # 本次渲染产物
    ba, bw, bg = load(BASE)     # 冻结基线
    have = set(ba)
    idx = {cp: i for i, cp in enumerate(sa)}
    add = []
    for cp in sa:
        if cp in have:
            continue
        blob = sg[idx[cp] * 64:(idx[cp] + 1) * 64]
        if not any(blob):
            continue            # 空字形不并入基线
        add.append((cp, sw[idx[cp]], blob))
    if not add:
        print("  [%s] 基线已覆盖，跳过" % p)
        continue
    rows = [(cp, bw[i], bg[i * 64:(i + 1) * 64]) for i, cp in enumerate(ba)] + add
    rows.sort(key=lambda r: r[0])
    na = [r[0] for r in rows]
    assert len(na) == len(set(na)), "重复 scalar"
    io.open(os.path.join(BASE, p + ".codepoints.u32le"), "wb").write(
        struct.pack("<%dI" % len(na), *na))
    io.open(os.path.join(BASE, p + ".widths.u8"), "wb").write(bytes(r[1] for r in rows))
    io.open(os.path.join(BASE, p + ".glyphs.2bpp"), "wb").write(b"".join(r[2] for r in rows))
    promoted += len(add)
    print("  [%s] 基线 %d -> %d (+%d)" % (p, len(ba), len(na), len(add)))

# 重算基线 manifest 的 sha256/byte_count
mp = os.path.join(BASE, "manifest.json")
mf = json.load(io.open(mp, encoding="utf-8"))
import hashlib
for prefix, files in mf["assets"].items():
    for suffix, rec in files.items():
        payload = io.open(os.path.join(BASE, "%s.%s" % (prefix, suffix)), "rb").read()
        rec["byte_count"] = len(payload)
        rec["sha256"] = hashlib.sha256(payload).hexdigest()
io.open(mp, "wb").write(json.dumps(mf, ensure_ascii=False, indent=2).encode("utf-8") + b"\n")
print("  基线 manifest 已重算（本次并入 %d 个字形）" % promoted)
PY

cp fonts/cjk/febuilder-manifest.json fonts/cjk/febuilder-baseline-manifest.json
$PY split-runtime-corpora --fehrr-root "$FEHRR_UPSTREAM" || die "split-runtime-corpora 失败"

step "9/9 重打包 content 侧字库补丁"
tar -tzf "$TARBALL" | sort > /tmp/_font_tar_list.txt
tar -czf /tmp/_font_patch.new -T /tmp/_font_tar_list.txt
cp -f /tmp/_font_patch.new "$TARBALL"
rm -f /tmp/_font_tar_list.txt /tmp/_font_patch.new
ok "字库补丁已重打包：$(tar -tzf "$TARBALL" | wc -l) 项"
ok "完成。接着跑 SKIP_BUILD=1 的构建做快速验证（或整轮构建）"
