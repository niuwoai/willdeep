---
title: 附录 A 快捷键与斜杠命令速查
order: 101
description: 实际生效的全部快捷键，以及斜杠命令、@ 引用、$ 技能的完整清单。
---

# 附录 A 快捷键与斜杠命令速查

## A.1 快捷键

### 全局

| 快捷键 | 作用 |
|---|---|
| **⌘N** | 新聊天 |
| **⌘,** | 打开设置 |
| **⌘?** | WillDeep 帮助（应用内置帮助书） |
| **⌘\\** | 显示 / 隐藏会话侧栏 |
| **⇧⌘P** | 搜索会话与项目（按标题） |

### 对话区

| 快捷键 | 作用 |
|---|---|
| **⌘F** | 在当前会话的正文里搜索 |
| **Esc** | 关闭搜索条 / 关闭浮动面板 / 取消 `/`、`@`、`$` 选择器 |
| **Return** | 发送消息 |
| **⇧Return** / **⌥Return** / **⌃Return** | 换行不发送 |
| **↑ / ↓**（输入框为空时） | 翻出自己发过的历史消息 |
| **↑ / ↓ / Return / Tab**（选择器打开时） | 在 `/`、`@`、`$` 面板里移动与确认 |

### 面板与窗口

| 快捷键 | 作用 |
|---|---|
| **⌘↩** | 审阅面板：提交并推送；干预子代理：下轮生效发送 |
| **⌘S** | 保存终端捷径（在捷径编辑器窗口里） |
| **⌘W** / **⌥W** | 关闭辅助窗口（转录阅读窗口、设置窗口等） |

其余是 macOS 默认项（⌘Z 撤销、⌘C 复制、⌃⌘F 全屏、⌘M 最小化……）。这一版没有编辑器，所以没有"打开文件""保存文件""分屏"这类快捷键。

## A.1.1 命令行工具

「设置 → Agent 工具 → 工具」里可以安装 `willdeep-app` 命令，装在 `~/.local/bin`（必要时自己加进 PATH）。装完之后：

```bash
willdeep-app .
```

在当前目录打开 WillDeep。安装过程不需要管理员权限。

## A.2 斜杠命令

在输入框里打 `/` 唤起。光标停在以 `/` 开头的词上就会弹出面板，这个词不一定要在句首。

### 会话控制

| 命令 | 作用 |
|---|---|
| `/new` | 在当前工作区新开一个会话 |
| `/clear` | 清空当前会话的消息 |
| `/compress` | 摘要较早的对话，腾出上下文空间 |
| `/stop` | 停止当前回复与工作流 |
| `/clear-queue` | 清空排队中的消息 |
| `/copy-last` | 复制最后一条 Agent 消息到剪贴板 |

### 沙箱与委派

| 命令 | 作用 |
|---|---|
| `/sandbox [消息]` | 开启本会话沙箱 |
| `/no-sandbox [消息]` | 关闭本会话沙箱 |
| `/subagent <要子代理调查什么>` | 本回合强制委派给子 Agent（正文必填） |
| `/no-subagent <要主代理独立完成什么>` | 本回合直接摘掉派子 Agent 的能力（正文必填） |

后两条可以写在句尾：`把这批测试跑一遍 /no-subagent`。

### 研究与代码

| 命令 | 参数 |
|---|---|
| `/research` | 研究问题 |
| `/code-review` | 可选：`--pr <#>` 或关注点 |
| `/bug-hunt` | 可选：范围提示 |
| `/competitor` | 产品名，逗号分隔 |
| `/pr-review` | PR 号 |
| `/release-notes` | 起始 tag，例如 `v1.80.0-rc1` |
| `/issue-triage` | 可选：标签过滤 |

### 数据库与表格

| 命令 | 参数 |
|---|---|
| `/csv-ask` | `<路径> <自然语言问题>` |
| `/db-explore` | `<连接串> <问题>`（只读） |
| `/db-schema-doc` | `<连接串>` |

### 图片（本机处理，不调模型）

`/image-convert`、`/image-resize`、`/image-crop`、`/image-compress`、`/image-bg-remove`、`/image-trim-pad`、`/image-watermark`、`/image-ocr`、`/image-redact`、`/image-contact-sheet`、`/image-palette`、`/image-compare`、`/image-alt-text`

常用参数示例：

```
/image-resize photo.png size=1200x800 format=png
/image-crop shot.png preset=16:9
/image-compress shot.png target-kb=512 format=jpeg quality=82
/image-redact screenshot.png faces=true text=true patterns=email,phone,token
/image-watermark cover.jpg "内部资料" position=br opacity=0.55
```

### 视频（ffmpeg，产物落在 ~/Downloads/）

`/video-compress`、`/video-extract`、`/video-thumbnail`、`/video-merge`、`/video-watermark`、`/video-speedup`

### 界面实现

| 命令 | 参数 |
|---|---|
| `/screenshot-to-code` | `<图片路径> [framework=react] [context="这个界面在哪出现"]` |

### 自定义

放在 `~/.willdeep/skills/<名字>/workflow.yaml` 的工作流会自动出现在这个列表里，改完 yaml 立即生效。不能覆盖内置命令的名字。

## A.3 `@` 引用

在输入框开头或空格之后打 `@` 唤起。

| 写法 | 作用 |
|---|---|
| `@workspace` | 把工作区根目录和文件列表带上 |
| `@<文件名或相对路径>` | 引用某个文件 |
| `@scout` `@generalist` `@implementer` `@tester` `@reviewer` `@ops-runner` | 点名一个 Worker 来做这一轮 |

选中之后 `@token` 会从输入框消失，变成上方的一个 chip。Worker 只有一个槽位，再点一个就换人。

## A.4 `$` 技能

打 `$` 唤起技能面板，搜索支持中文关键词。选中后同样变成 chip，点 × 可以移除。

## A.5 三种触发符对照

| 符号 | 面板 | 选中后 |
|---|---|---|
| `/` | 斜杠命令 | 命令留在输入框里，作为这一轮的指令 |
| `@` | 文件 / 工作区 / Worker | token 消失，变成 chip |
| `$` | 技能 | token 消失，变成 chip |

---

← 返回 [目录](README.md)
