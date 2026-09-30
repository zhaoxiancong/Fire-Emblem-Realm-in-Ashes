# content/data/febuilder/ —— FEBuilder 主链路数据

> FEBuilder 主链路的**数据 JSON** 存放目录（见 `docs/5.开发总SSOT.md`）。

## 目录约定

| 文件/目录 | 用途 | 是否入库 |
|---|---|---|
| `<表名>_<内容>.json` | FEBuilder 格式数据（FE 原生字段名 + hex 值） | ✅ git 追踪 |
| `shanhe-data-work.gba` | 官方 baserom 的**工作副本**（导入目标） | ❌ 忽略（16MB） |

## 数据 JSON 命名规则

- `<表名>_<内容>.json`，如 `classes_peijianlang.json`（职业表·佩剑郎）、`units_yucong.json`（角色表·虞聪）。
- 表名 = FEBuilder 的 40 张表名（`classes`/`units`/`items`/`item_weapon_triangle` 等）。

## 工作流（闭环）

```bash
# 1. 写 JSON（FE 原生字段名 + hex 值，只写要改的行）
# 2. 复制官方 baserom 为工作副本（若尚未有）
#    cp "<官方baserom>" shanhe-data-work.gba
# 3. 导入
#    FEBuilderGBA.CLI --import-data --rom=shanhe-data-work.gba --table=classes --in=classes_xxx.json
# 4. 校验
#    FEBuilderGBA.CLI --lint --rom=shanhe-data-work.gba
#    FEBuilderGBA.CLI --data-roundtrip --rom=shanhe-data-work.gba --table=classes
```

> 官方 baserom 路径：`D:/workbuddy/2026-09-29-1533_FireEmblem项目调研/改版补丁/可玩gba/Fire Emblem - The Sacred Stones (USA, Australia).gba`（SHA1 `C25B145E…`）。
