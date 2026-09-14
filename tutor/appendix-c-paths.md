---
title: 附录 C 本机目录与日志位置
order: 103
description: WillDeep 在本机写了哪些目录、各存什么、排错时该看哪一个。
---

# 附录 C 本机目录与日志位置

排错、备份、迁移和取证时会用到。日常使用不需要动这些文件。

## C.1 主数据目录

`~/Library/Application Support/WillDeep/`

| 子目录 | 内容 | 什么时候看它 |
|---|---|---|
| `agent-sessions/` | 每个会话一个 JSON，消息、工具调用、结果全在里面 | 界面里找不到某次执行的细节，或要确认某条消息是否真的落盘 |
| `agent-events/` | 会话事件流 | 追一次执行的时间线 |
| `agent-routines/` | 定时任务定义与运行历史 | 定时任务没跑，先看这里有没有记录 |
| `AgentAudit/` | 审批与沙箱审计日志（见 C.3） | 排查"为什么又要我点确认" |
| `AgentMemory/` | 项目记忆 | 确认 Agent 记住了什么 |
| `subagent-transcripts/` | 子 Agent / 后台 Worker 的完整对话 | Worker 结果可疑时回看它究竟做了什么 |
| `media-tasks/` | 媒体任务与产物 | 找生成的图片、视频 |
| `agent-attachment-content/` | 附件正文缓存 | 附件显示异常 |
| `plugin-registry.json`、`plugin-data/` | 已安装插件与插件自己的数据 | 插件白屏、装了没反应 |
| `projects.json` | 项目与目录归属 | 同一路径同时出现在"项目"和裸文件夹里 |
| `roundtable-documents/` | 专家圆桌产出的文档 | 找圆桌结论 |
| `terminal-shortcuts/` | 终端快捷命令 | 备份自定义命令 |

## C.2 偏好与凭据

- 偏好设置：`~/Library/Preferences/com.willdeep.app.plist`
  用 `defaults read com.willdeep.app` 读，别直接编辑 plist 文件。
- API Key、登录令牌等凭据：**macOS 钥匙串**，不写进上面任何文件。
  这意味着复制 Application Support 目录到新机器，会话会过去，凭据不会。

## C.3 审计日志

在 `~/Library/Application Support/WillDeep/AgentAudit/` 下：

- `judge.jsonl` —— 智能审核裁判的每次判定。一条命令在这里查不到，说明裁判根本没上场，被前置门禁直接拦了。
- `sandbox.jsonl` —— 每次工具执行用的沙箱档位。"本机能跑、Agent 跑不了"先看这里的 mode 列。

两个文件都是一行一条 JSON，可以直接 `tail -n 50 xxx.jsonl | jq` 看。

统计的时候记得剔掉单测夹具产生的记录（含 `example.com`、`evil.example`、`FIXTURE_WORK_DIR` 这类字样的行），否则算出来的比例会和真实使用完全对不上。

## C.4 系统日志

App 自己的日志：`~/Library/Logs/WillDeep/`

系统统一日志（崩溃、权限拒绝、XPC 错误）：

```bash
/usr/bin/log show --predicate 'process == "WillDeep"' --last 30m --info
```

注意必须写 `/usr/bin/log` 的全路径。在 zsh 里直接敲 `log show` 会命中 shell 内建命令，报错还容易被 `2>/dev/null` 吞掉，看起来像"没有日志"。

## C.5 备份建议

要备份的最小集合：

```
~/Library/Application Support/WillDeep/agent-sessions/
~/Library/Application Support/WillDeep/agent-routines/
~/Library/Preferences/com.willdeep.app.plist
```

会话目录会随使用持续增长，几百个会话是常态。备份前可以先归档不再需要的会话，界面里归档比手工删文件安全——手工删文件时一旦删错，界面侧的索引和磁盘就对不上了。

---

← 返回 [目录](README.md)
