# tools/ —— 工具索引与说明

> **这份文档回答**：`tools/` 下的 29 个文件分别是干什么的、**什么时候用哪个**、哪些是"一次性"、哪些是"每天用"。
>
> 配套：环境搭建的详细步骤见 `环境搭建指引.md`；日常构建流程见 `../docs/5.改版工程手册.md` §3.6。

---

## 0. 先看这张表（按"你此刻要做什么"索引）

| 我想… | 用哪个 | 在哪跑 |
|---|---|---|
| **改内容后出 ROM（日常唯一入口）** | **`shanhe-build.sh`** | WSL |
| 提交前 / 开工自检 | `git-health.sh` | Windows |
| 查中文有没有"打不出来的字" | `check-cjk-chars.py` | WSL |
| 第一次搭环境 | `1-install-wsl.ps1` → `2-setup-project.sh` → `3-verify-env.sh` | Windows → WSL |
| 环境坏了 / 构建报错 | `6-diagnose-build.sh`、`7-fix-and-build.sh` | WSL |
| 装不上 WSL（Store 被墙） | `4-install-wsl-manual.ps1` | Windows |
| 虚拟化（VT-x/Hyper-V）问题 | `5-fix-virtualization.ps1` | Windows |
| **游戏崩溃，要抓现场** | `wsl/shanhe-crash-catcher.py` | WSL |
| 给中文补字形（原创汉字） | `wsl/_run_font_pipeline.sh` | WSL |
| 确认中文/文本真的进了 ROM | `wsl/_verify_msg_rom.py` | WSL |
| 首次构建报 `can't open tools/gbagfx/...` | `wsl/build-host-tools.sh` | WSL |

---

## 1. 分类总览

### ① 日常主入口（**最重要**）

| 文件 | 说明 |
|---|---|
| **`shanhe-build.sh`** | **方案 B 的唯一日常入口**。六步：预检 → 校验 `framework.lock` 的 commit → 写前快照 → 铺设（3a' B' 回填 / 3b' 文本台账 / 3b'' 消息表 / 3c 原创 C / 3c'' 框架补丁 / 3c' 字库 / 3d 资产）→ 构建 → 自建五项验收 → **5b 导出 ROM** → 6 反查 |
| | 子命令：`DRY_RUN=1`（预演）/ `STATUS=1`（看框架被改了什么）/ `RESTORE=1`（一键还原框架）/ `SKIP_BUILD=1` |
| `git-health.sh` | 只读健康检查：行尾（CRLF 污染）、版本号倒退、索引漂移等。**提交前必跑** |
| `check-cjk-chars.py` | **缺字检查**：给定中文文本/文件，报出不在运行时字库里的字（退出码 0/1）。可用汉字约 2414 个。用法见 `../docs/5` §4.7 |

### ② 环境搭建（**一次性**，1~7 号）

| 文件 | 何时用 |
|---|---|
| `1-install-wsl.ps1` | 装 WSL2 + Ubuntu-24.04（Windows 侧） |
| `2-setup-project.sh` | 拉框架 + 装工具链 + 首次构建（WSL 内） |
| `3-verify-env.sh` | 环境自检（工具链/子模块/宿主机工具） |
| `4-install-wsl-manual.ps1` | **完全绕开 Microsoft Store** 手动装 WSL（Store 被墙时用） |
| `5-fix-virtualization.ps1` | WSL 虚拟化问题诊断与修复 |
| `6-diagnose-build.sh` | 构建失败时的分步诊断 |
| `7-fix-and-build.sh` | 一键修复 + 构建 |
| `shanhe.sh` | 上述流程的一次性入口（含 8 个宿主机工具预构建） |
| `环境搭建指引.md` | **环境搭建的完整说明**（中文，含排错） |

### ③ WSL 侧专有工具（`tools/wsl/`）

| 文件 | 说明 |
|---|---|
| `build-host-tools.sh` | 预构建 8 个宿主机工具（`aif2pcm bin2c gbagfx jsonproc mid2agb preproc scaninc textencode`）。**首次构建报 `can't open tools/gbagfx/gbagfx.s` 就是缺这步** |
| `shanhe.sh` | WSL 内一次性命令入口 |

### ④ 中文/文本验证

| 文件 | 说明 |
|---|---|
| `_verify_msg_rom.py` | **验证中文真的进了 ROM**：从 `texts/texts.txt` 复算 Huffman 码表 → 解压 `src/msg_data.c` → 与期望中文比对；再用压缩字节在最终 ROM 里命中（应 count=1）。**ROM 内文本是 Huffman 压缩的，搜明文必然搜不到**（见 `../docs/5` §5.4） |
| `_find_glyphs_in_shots.py` | 在 headless 截图里模板匹配字形。⚠️ **花屏背景假阳性多，需人工复核**，实际很少用得上 |

### ⑤ 字库补字管线（原创汉字）

| 文件 | 步骤 |
|---|---|
| `_run_font_pipeline.sh` | **全流程**（六步）：插占位 → FEBuilder 渲染 → 扩冻结基线 → FEHRR 覆盖 → 重算语料 → 产出归档 |
| `_inject_glyphs.py` | 第①步：插占位字形（scalar 升序插码位、宽 16、位图 64 字节零） |
| `_promote_baseline.py` | 第③步：把新字形并入冻结基线（否则 `split-runtime` 报 `no verified fallback`） |

> 细节与实测数据见 `../docs/5` §3.7；产出 `content/fonts/shanhe-font-patch.tar.gz`（26 项）。

### ⑥ 实机调试与崩溃定位

| 文件 | 说明 |
|---|---|
| **`shanhe-crash-catcher.py`** | ★ **崩溃捕手**。直连 mGBA 的 GDB remote 协议（**单 socket 常驻**），`continue` 让游戏跑起来后周期采样 PC，落入非法区即 dump 全寄存器 + 栈 + 疑似 `MenuProc` 字段。**必须单连接**（mGBA 的 stub 断开即卡死）。⚠️ 用时先核对试玩目录 ROM 的 SHA1 与本次产物一致 |
| `shanhe-gdb-capture.sh` | 一次性抓崩溃现场（抓完即弃，mGBA 需重启） |
| `shanhe-boot.c` / `shanhe-boot-range.c` | libmGBA **headless** 驱动（无头跑 ROM + 截图）。⚠️ 实测**不可靠**：战斗地图花屏、序章需约 10 万帧、插 Start 会崩。要"看屏幕效果"请用真 mGBA |
| `_ppm2png.py` / `_ppm2png_batch.py` | headless 截图 PPM → PNG（无第三方依赖） |

> 完整方法论见技能 `mgba-gdb-crash-debug`（含 `.cmd` 启动器的两个必踩坑）。

### ⑦ ⚠️ 冗余：与根级同名的副本

`wsl/` 下的这 5 个文件与根级**内容完全相同（逐字节）**：

```
tools/2-setup-project.sh      tools/3-verify-env.sh      tools/6-diagnose-build.sh
tools/7-fix-and-build.sh      tools/shanhe.sh
```

**现状**：历史原因留下的副本（早期 WSL 侧需要一份）。
**建议**：**保留根级，删除 `wsl/` 下的同名副本**（减少"改了一份忘另一份"的风险）。
⚠️ **需先确认没有脚本按 `tools/wsl/2-setup-project.sh` 这样的路径调用它们**，确认后再删。

---

## 2. 命名约定

| 前缀/位置 | 含义 |
|---|---|
| `1-` ~ `7-` | 环境搭建的**有序**步骤脚本 |
| `shanhe-*.py` / `shanhe-*.sh` | **本项目自建的、长期维护的**工具 |
| `_*.py` / `_*.sh` | **内部辅助脚本**（被上面的工具调用，或一次性诊断用） |
| `tools/wsl/` | **必须在 WSL 内运行**的工具（框架在 WSL 侧） |
| `*.ps1` | Windows PowerShell（环境搭建用） |

---

## 3. 与其他文档的对应关系

| 想知道 | 看 |
|---|---|
| 日常怎么构建、每步在干什么 | `../docs/5.改版工程手册.md` §3.6 |
| 方案 B 为什么这么设计 | `../docs/6.方案B内容外置规划.md` |
| 补字流程细节 | `../docs/5` §3.7 |
| ROM 内文本怎么验证 | `../docs/5` §5.4 |
| 崩溃怎么定位 | `../docs/5` §5.7、技能 `mgba-gdb-crash-debug` |
| 换机怎么重建 | `../docs/5` §9 |

---

## 附录：版本记录

| 版本 | 日期 | 变更 |
|---|---|---|
| v1.0 | 2026-09-25 | 首版。29 个文件的分类索引、命名约定、已知冗余（`wsl/` 同名副本）与文档对照 |
