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

## 4. 自动推送钩子（一次安装，永久生效）

仓库内带了 `post-commit` 钩子，**每次 `git commit` 成功后自动 `git push`**，把「必推送」从人肉纪律变成机械动作。（本机已启用。）

```bash
# 安装（每个克隆执行一次）
git config core.hooksPath .githooks
```

Windows 下确认钩子可执行：

```bash
chmod +x .githooks/post-commit
```

- 钩子逻辑：读当前分支 → 若无上游则跳过并提示 → 否则 `git push origin <分支>`。
- 推送失败**不会**回滚本地提交，但会在终端红字报错，此时必须手动补推。
- 卸载：`git config --unset core.hooksPath`。

## 5. 标准操作序列

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

## 6. 提交前自检清单

- [ ] `git status` 里没有 `?? ` 的垃圾文件（有的话补进 `.gitignore`）
- [ ] diff 里没有误删大段内容
- [ ] 改动涉及的文档头部版本号已 +1
- [ ] 跨文档引用没写死绝对路径（一律用相对路径，如 `docs/3.游戏数值设定.md`）
- [ ] 数值类改动只改 `3.游戏数值设定.md`，没在设计文档里复制数值

## 7. 凭据（已配置 PAT 静默鉴权）

本机已用 Personal Access Token 完成鉴权，推送全程无弹窗。Token 存在 Windows 凭据库中，不落盘到仓库。

### 若换机器 / token 过期

1. GitHub → Settings → Developer settings → Personal access tokens → **Tokens (classic)** → Generate new token，勾选 `repo`。
2. 写入本机凭据库（token 从 stdin 读，不会留在命令行历史里）：

```bash
printf 'protocol=https\nhost=github.com\nusername=zhaoxiancong\npassword=你的TOKEN\n' | git credential-manager store --no-ui
```

3. 验证：`git push origin main` 应立刻返回 `Everything up-to-date`，无弹窗。

### 已知坑：推送无限卡住 / 反复弹登录窗

**症状**：`git push` 一直不返回，或反复弹出 GitHub 登录窗口。

**原因**：PortableGit 的 system 配置默认 `credential.helper=helper-selector`，它在无人值守环境（无 TTY）会尝试弹 UI 并死等。

**修复**（已在本机执行过）：

```bash
# 1. 把 system 级的 selector 换成标准的 GCM
rm -f "<PortableGit>/etc/gitconfig.lock"   # 先清掉残留锁，否则改配置报 "File exists"
git config --system credential.helper manager

# 2. 写入 PAT（见上）
```

排查时可用 `GIT_TERMINAL_PROMPT=0 timeout 45 git push origin main` 让失败快速暴露，而不是无限等待。

## 8. 敏感信息

- 不提交 `export_presets.cfg`（含签名密钥）、`export_credentials.cfg`、任何 token / 密钥文件。
- 这些已在 `.gitignore` 中屏蔽；若发现被误提交，立刻改密并从历史中清理，通知协作者。
