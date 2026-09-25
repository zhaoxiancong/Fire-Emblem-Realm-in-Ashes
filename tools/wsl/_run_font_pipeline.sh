#!/bin/bash
# 字库补字完整流程（扩冻结基线路线）
# 顺序：占位破环 -> generate-inventory -> FEBuilder 全链 -> import
#      -> 提升冻结基线(含8字) -> cp baseline-manifest -> split-runtime(FEHRR覆盖) -> generate-inventory
set -u
cd "$HOME/projects/fireemblem8-expansion" || exit 1
export DOTNET_ROOT="$HOME/.dotnet"
export PATH="$PATH:$HOME/.dotnet"
CLI="dotnet $HOME/FEBuilderGBA/FEBuilderGBA.CLI/bin/Release/net10.0/FEBuilderGBA.CLI.dll"
PY="python3 -m scripts.fonttools.cjk"
M=fonts/cjk/febuilder-manifest.json
BD=build/tmp/cjk-fonts
W=/mnt/d/workbuddy/FireEmblem\ Realm-in-Ashes/tools/wsl
LOG="$HOME/shanhe-logs/font-fix.log"
mkdir -p "$HOME/shanhe-logs"

step() { echo ""; echo "########## $* ##########"; }

exec > "$LOG" 2>&1

step "0. 注入 8 占位字形"
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
  --commit c1700532b27c579511585ca63e2d63222b9ea646 \
  --dotnet-sdk 10.0.302 \
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

echo ""
echo "########## ALL DONE ##########"
