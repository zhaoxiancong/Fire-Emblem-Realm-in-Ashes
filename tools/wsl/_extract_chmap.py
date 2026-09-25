#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""M3⑤ 瓦片集攻坚：从 chapter_settings.json 提取「章节 -> 地图资源」映射"""
import json, os, sys

p = "src/data/chapter_settings.json"
d = json.load(open(p, encoding="utf-8"))

print("顶层键:", list(d.keys())[:15])
arr = None
for k in ("chapters", "settings", "chapterSettings", "list"):
    if isinstance(d.get(k), list):
        arr = d[k]; print("条目数组键 = %s，条数 = %d" % (k, len(arr))); break
if arr is None:
    print("!! 找不到条目数组，转储首层结构：")
    for k, v in list(d.items())[:10]:
        print("  %s: %s" % (k, type(v).__name__))
    sys.exit(0)

print("首条键:", list(arr[0].keys()))
print()
first = arr[0]
for k in list(first.keys()):
    v = first[k]
    if isinstance(v, dict):
        print("  %-22s (dict) %s" % (k, {kk: vv for kk, vv in list(v.items())[:10]}))
    else:
        print("  %-22s %s" % (k, str(v)[:60]))

# 提取 map.* 索引
print()
print("=== 章节 -> 地图资源索引（前 30 条）===")
print("  %-6s %-22s %6s %6s %6s %8s %8s" % ("idx", "name/id", "main", "objAn", "palAn", "tileCf", "change"))
n = 0
for i, c in enumerate(arr):
    m = c.get("map")
    if not isinstance(m, dict):
        continue
    n += 1
    if n > 30:
        break
    name = c.get("name") or c.get("id") or c.get("chapterId") or ("#%d" % i)
    print("  %-6d %-22s %6s %6s %6s %8s %8s" % (
        i, str(name)[:22],
        m.get("mainLayerId"), m.get("objAnimId"), m.get("paletteAnimId"),
        m.get("tileConfigId"), m.get("changeLayerId")))

# 统计：哪些瓦片集被用了多少次
from collections import Counter
for key in ("objAnimId", "paletteAnimId", "tileConfigId"):
    cnt = Counter(c["map"].get(key) for c in arr if isinstance(c.get("map"), dict))
    used = {k: v for k, v in sorted(cnt.items(), key=lambda x: (x[0] is None, x[0])) if k is not None}
    print("\n%s 使用分布（值:次数）：" % key)
    print("  " + ", ".join("%s:%d" % (k, v) for k, v in used.items()))
