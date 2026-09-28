#!/bin/bash
# 字库补字完整流程（扩冻结基线路线）
# 顺序：占位破环 -> generate-inventory -> FEBuilder 全链 -> import
#      -> 提升冻结基线(含新字) -> cp baseline-manifest -> split-runtime(FEHRR覆盖)
#      -> generate-inventory -> 重打包 content 侧字库补丁
#
# ★ 2026-09-28 参数化（原先硬编码首次那 8 个字与 dotnet-sdk/commit）：
#   SHANHE_FONT_CHARS   要补的字（默认 佩拗耳聪虞郎鸣鼎）
#   SHANHE_DOTNET_SDK   记录进 gate evidence 的 SDK 版本（默认 10.0.302）
#   SHANHE_FEB_COMMIT   记录进 gate evidence 的 FEBuilderGBA commit（默认首次那个）
#   例：SHANHE_FONT_CHARS="圭州曰煞熙疫" SHANHE_DOTNET_SDK="10.0.401" bash tools/wsl/_run_font_pipeline.sh
set -u
cd "$HOME/projects/fireemblem8-expansion" || exit 1
export DOTNET_ROOT="$HOME/.dotnet"
export PATH="$PATH:$HOME/.dotnet"
CLI="dotnet $HOME/FEBuilderGBA/FEBuilderGBA.CLI/bin/Release/net10.0/FEBuilderGBA.CLI.dll"
PY="python3 -m scripts.fonttools.cjk"
M=fonts/cjk/febuilder-manifest.json
BD=build/tmp/cjk-fonts
REPO="/mnt/d/workbuddy/Fire-Emblem-Realm-in-Ashes"
W="$REPO/tools/wsl"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$HOME/shanhe-logs/font-fix-$STAMP.log"
FONT_CHARS="${SHANHE_FONT_CHARS:-佩拗耳聪虞郎鸣鼎}"
DOTNET_SDK="${SHANHE_DOTNET_SDK:-10.0.302}"
FEB_COMMIT="${SHANHE_FEB_COMMIT:-c1700532b27c579511585ca63e2d63222b9ea646}"
export SHANHE_FONT_CHARS="$FONT_CHARS"
mkdir -p "$HOME/shanhe-logs"

step() { echo ""; echo "########## $* ##########"; }

exec > "$LOG" 2>&1
echo "本次补字：$FONT_CHARS"
echo "dotnet-sdk: $DOTNET_SDK   febuilder-commit: $FEB_COMMIT"
echo "日志：$LOG"

step "0. 注入占位字形（$FONT_CHARS）"
python3 "$W/_inject_glyphs.py" || { echo "FAIL@0"; exit 1; }

step "1. generate-inventory（占位宽度）"
$PY generate-inventory || { echo "FAIL@1"; exit 1; }

step "2. FEBuilder dry-run"
rm -rf "$BD/dry-run-package" "$BD/dry-run-report.json"; mkdir -p "$BD"
$CLI --build-font-library --manifest=$M --out="$BD/dry-run-package" --mode=dry-run --report="$BD/dry-run-report.json" || { echo "FAIL@2"; exit 1; }

step "3. FEBuilder generate"
rm -rf "$BD/package" "$BD/generation-report.json"; mkdir -p "$BD"
$CLI --build-font-library --manifest=$M --out="$BD/package" --mode=generate --report="$BD/generation-report.json" || { echo "FAIL@3"; exit 1; }

step "4. FEBuilder validate"
$CLI --build-font-library --manifest=$M --out="$BD/package" --mode=validate --report="$BD/generation-report.json" || { echo "FAIL@4"; exit 1; }

step "5. FEBuilder roundtrip"
$CLI --build-font-library --manifest=$M --out="$BD/package" --mode=roundtrip --report="$BD/generation-report.json" || { echo "FAIL@5"; exit 1; }

step "6. record-gates"
$PY record-gates \
  --dry-run-report "$BD/dry-run-report.json" \
  --generation-report "$BD/generation-report.json" \
  --output-report fonts/cjk/reports/febuilder-generation-report.json \
  --gate-report fonts/cjk/reports/febuilder-gates.json \
  --cli-command "FEBuilderGBA.CLI --build-font-library" \
  --commit "$FEB_COMMIT" \
  --dotnet-sdk "$DOTNET_SDK" \
  --repository https://github.com/laqieer/FEBuilderGBA || { echo "FAIL@6"; exit 1; }

step "7. archive-package"
$PY archive-package --package-dir "$BD/package" --output "$BD/febuilder-schema-v1.zip" || { echo "FAIL@7"; exit 1; }

step "8. import-package（写 graphics/fonts/cjk，含8字真字形）"
$PY import-package --package "$BD/febuilder-schema-v1.zip" --report "$BD/generation-report.json" || { echo "FAIL@8"; exit 1; }

step "9. 提升冻结基线（并入8字真字形）"
python3 "$W/_promote_baseline.py" || { echo "FAIL@9"; exit 1; }

step "10. cp manifest -> baseline-manifest"
cp fonts/cjk/febuilder-manifest.json fonts/cjk/febuilder-baseline-manifest.json || { echo "FAIL@10"; exit 1; }

step "11. split-runtime-corpora（FEHRR 优先覆盖，恢复 ja 假名宽度）"
$PY split-runtime-corpora --fehrr-root "$HOME/FEHRR" || { echo "FAIL@11"; exit 1; }

step "12. 最终 generate-inventory"
$PY generate-inventory || { echo "FAIL@12"; exit 1; }

# ★ 2026-09-28 新增（原先这一步是手做的，容易漏）：
#   把框架侧被改动的字库文件重新打包回 content 侧的字库补丁。
#   成员清单**直接沿用现有 tarball 的条目**（保成员集合不变），
#   只是内容换成这次的产物 ⇒ 不会因为手抄清单而漏文件。
step "13. 重打包 content/fonts/shanhe-font-patch.tar.gz"
TARBALL="$REPO/content/fonts/shanhe-font-patch.tar.gz"
[ -f "$TARBALL" ] || { echo "FAIL@13: 找不到 $TARBALL"; exit 1; }
LIST="$(mktemp)"
tar -tzf "$TARBALL" | sort > "$LIST"
echo "成员数（打包前）：$(wc -l < "$LIST")"
tar -czf "$TARBALL.new" -T "$LIST" || { echo "FAIL@13"; rm -f "$LIST"; exit 1; }
mv "$TARBALL.new" "$TARBALL"
rm -f "$LIST"
echo "已重打包：$(ls -l "$TARBALL")"
echo "成员数（打包后）：$(tar -tzf "$TARBALL" | wc -l)"

echo ""
echo "########## ALL DONE ##########"
