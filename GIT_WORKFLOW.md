# Git 提交与推送规范（山河烬）

> 本文件是项目级强制约定。任何一次改动——哪怕只改一个字——都要走完「改 → 提交 → 推送」闭环。

## 0. 仓库信息

| 项 | 值 |
| --- | --- |
| 远端 | `https://github.com/zhaoxiancong/Fire-Emblem-Realm-in-Ashes` |
| 远端名 | `origin` |
| 主分支 | `main`（唯一长期分支） |
| 本地路径 | `D:\workbuddy\FireEmblem Realm-in-Ashes` |
| 提交身份 | `Supreme <1507300057@qq.com>` |

## 1. 核心铁律

1. **一次改动 = 一次提交 = 一次推送。** 不允许积攒多个逻辑改动到一次提交里，也不允许本地有未推送的提交过夜。
2. **改完立刻提交。** 文档改动在编辑完成、自检通过（无断链、无版本号遗漏）后立即 commit + push。
3. **禁止 `--force` 推送到 `main`**（除本人明确要求且知晓风险）。
4. **提交前必看 diff。** `git diff` / `git status` 确认没有夹带无关文件或误删。
5. **文档版本号必须同步 +1。** 改了哪份文档，就把该文档头部的版本号递增，并在提交信息里写明（如 `docs(剧情): v1.3 → v1.4`）。

## 2. 提交信息规范（Conventional Commits）

格式：

```
<type>(<scope>): <中文简述>
```

### type

| type | 用途 |
| --- | --- |
| `docs` | 文档（设计文档 / 剧情 / 数值 / README） |
| `feat` | 新功能（引擎代码、玩法系统） |
| `fix` | 修复（Bug、数值错误、断链） |
| `refactor` | 重构、结构调整（不改变行为） |
| `chore` | 工程杂项（.gitignore、配置、依赖） |
| `art` | 美术资源 |
| `audio` | 音频资源 |
| `test` | 测试 |

### scope

`剧情` `数值` `设计` `调研` `工程` `关卡` `美术` `音频` `流程`

### 示例

```
docs(剧情): v1.3 → v1.4 补全第5章 BOSS 战前对话
docs(数值): 修正追击阈值 AS 差≥4 的表述并补 Demo 五章敌兵模板
feat(工程): 接入战斗预测面板原型
fix(数值): 2RN 命中公式取整方向写反
chore(流程): 新增 .gitignore 与提交规范
```

## 3. 分支策略

- 日常文档改动：**直接在 `main` 上提交**。
- 成块的新系统 / 实验性改动：开 `feat/xxx`、`exp/xxx` 分支，完成后合并回 `main` 并删除分支。
- 分支命名：`feat/combat-forecast`、`docs/character-stats`、`exp/hex-grid`。

## 4. 标准操作序列

```bash
cd "D:/workbuddy/FireEmblem Realm-in-Ashes"

# 1. 看清楚改了什么
git status
git diff

# 2. 暂存（明确列出文件，少用 -A 偷懒）
git add docs/3.游戏数值设定.md

# 3. 提交
git commit -m "docs(数值): 补全 Demo 五章商店解锁曲线"

# 4. 立刻推送
git push origin main
```

首次推送 / 换分支时用 `git push -u origin <分支>`。

## 5. 提交前自检清单

- [ ] `git status` 里没有 `?? ` 的垃圾文件（有的话补进 `.gitignore`）
- [ ] diff 里没有误删大段内容
- [ ] 改动涉及的文档头部版本号已 +1
- [ ] 跨文档引用没写死绝对路径（一律用相对路径，如 `docs/3.游戏数值设定.md`）
- [ ] 数值类改动只改 `3.游戏数值设定.md`，没在设计文档里复制数值

## 6. 凭据

Push 走 Git Credential Manager。若推送报 `Authentication failed`：

```bash
git credential-manager github login   # 或
git credential-manager erase https://github.com   # 清掉旧凭据后重来
```

也可在 GitHub → Settings → Developer settings → Personal access tokens 生成 classic token（`repo` 权限），推送时用户名填 GitHub 账号、密码填 token。

## 7. 敏感信息

- 不提交 `export_presets.cfg`（含签名密钥）、`export_credentials.cfg`、任何 token / 密钥文件。
- 这些已在 `.gitignore` 中屏蔽；若发现被误提交，立刻改密并从历史中清理，通知协作者。
