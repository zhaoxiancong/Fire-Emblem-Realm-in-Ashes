#!/bin/bash
# M3⑤ 瓦片集攻坚 · 第一步：摸清原版瓦片集清单 + 章节映射
cd /home/shanhe/projects/fireemblem8-expansion || exit 1

echo "=== ① 瓦片集相关资源清单 ==="
for pat in "ObjectType*" "MapPalette*" "TileConfiguration*"; do
  echo "--- $pat ---"
  find graphics -name "${pat}*.png" -o -name "${pat}*.pal" -o -name "${pat}*.bin" 2>/dev/null | sort | head -24
done

echo
echo "=== ② graphics/map 下的目录结构 ==="
ls -d graphics/*/ 2>/dev/null | head -20

echo
echo "=== ③ 章节资产表 gChapterDataAssetTable 定义位置 ==="
grep -rn "gChapterDataAssetTable" src/ include/ 2>/dev/null | head -8

echo
echo "=== ④ 该表的前若干条内容（看字段：map/tileset/palette/config 索引）==="
grep -rn -A24 "gChapterDataAssetTable\[\] *=\|gChapterDataAssetTable *=" src/*.c 2>/dev/null | head -32

echo
echo "=== ⑤ 是否走 generated-data（chapter_settings.json）==="
ls -la src/data/chapter_settings.json 2>/dev/null
python3 - <<'PY'
import json, os
p = "src/data/chapter_settings.json"
if os.path.isfile(p):
    d = json.load(open(p, encoding="utf-8"))
    print("顶层键:", list(d.keys())[:12])
    arr = d.get("chapters") or d.get("settings") or []
    print("条目数:", len(arr) if isinstance(arr, list) else "?")
    if isinstance(arr, list) and arr:
        print("首条键:", list(arr[0].keys()))
        print("首条样例:", json.dumps(arr[0], ensure_ascii=False)[:400])
PY
