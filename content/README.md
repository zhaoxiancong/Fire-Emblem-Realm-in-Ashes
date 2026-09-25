# content/ —— 《山河烬》全部原创内容

> **这一条规则最重要**：**框架仓库里永远不出现手改。** 任何改动都先写进这里，再由
> `tools/shanhe-build.sh` 铺过去。养成习惯后你根本不会去碰框架。

## 目录职责

| 目录 | 放什么 | 铺到框架哪里 | 合并方式 |
|---|---|---|---|
| `data/` | 原创 JSON 内容（角色/职业/道具/支援/章节 bundle…） | `src/data/` | ★ **按键/槽位增量合并**，不是文件覆盖 |
| `texts/` | 中文文本 | `texts/` | 合并 + 追加 |
| `src/` | 原创 C 代码（**统一 `shanhe_` 前缀**） | `src/shanhe_*.c` | 新增文件 |
| `assets/` | 原创美术/音频/地图资产 | `assets/`、`graphics/`、`sound/` | 按各自拥有缝登记 |

## ⚠️ 写 `data/characters.json` 前必读（2026-09-26 实测）

框架的 `src/data/characters.json` 是 **256 槽全满**的整表，分**两套互斥的键方案**：

| 形态 | 条数 | 定位键 |
|---|---|---|
| 具名角色 | 94 | `"character": "CHARACTER_EIRIKA"` |
| 无名杂兵模板 | 162 | `"characterId": 27`（**1-based 槽位号**） |

**两个坑**：
1. 用 `c["character"]` 取键 → 那 162 条没这个键 → **KeyError 崩溃**
2. `characterId == 数组下标 + 1` → **按下标定位会整体偏移一格**

**所以本目录的 `characters.json` 只写原创角色，且每条必须自带 `characterId`（你要顶替的槽位号）。**
同步脚本会断言 `idx + 1 == characterId` 才做替换，不符即中止。

详见 `docs/6.方案B内容外置规划.md` §3.4。

## 章节内容怎么加

一个章节 = **5 张叶子表 + 1 个 bundle**：

```
data/chN_units.json        单位组
data/chN_shops.json        商店
data/chN_traps.json        陷阱
data/chN_eventscripts.json 事件脚本符号
data/chN_eventlists.json   事件列表
data/chN_bundle.json       ★ 章节目录（引用上面 5 张 + 依赖声明）
```

bundle 走「**新增文件 + 追加记录**」路线，零冲突。但 `dependencies` 是**精确声明**，
必须一次把该章用到的全部 `characters`/`classes`/`items` 列全（漏一个就 validate 失败）。

**章节的事件脚本实现**（`EventScr_*` 的实际内容）要写 C，放 `content/src/`，
落点是框架的 `src/events/` —— 这是**章节制作中唯一需要写代码的环节**。

参考范例：框架的 `ch2_*` 系列。

## 不要做的事

- ❌ 不要在这里放框架的副本或备份
- ❌ 不要在这里放构建产物（`.gba`/`.elf`/`.map`）
- ❌ 不要直接把框架的文件整份拷过来改（会丢上游更新）
