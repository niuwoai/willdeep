# Structured Agent Executors

> Last updated: 2026-07-29 | Current version: v1.213.0-rc1

## 目标

外部编码 Agent 不应被当成一条超长 shell 命令。WillDeep 把执行边界拆成三层：

1. `AgentExecutorProcessSpecification` 描述 executable、argv、stdin、工作目录、sandbox 和事件 decoder。
2. `AgentExecutorEvent` 统一会话、消息、思考、工具、文件、权限、用量、警告和完成事件。
3. `AgentExecutorCapabilityResolver` 显式选择 ACP、Codex app-server、结构化进程、daemon、可见终端或兼容 shell。
4. transport 负责本机 `Process`、JSON-RPC stdio 或远端 daemon，UI、任务生命周期和脱敏不依赖 provider JSON。

## 当前能力矩阵

| 执行器 / transport | 启动方式 | 实时事件 | 会话续接 | 宿主审批 |
| --- | --- | --- | --- | --- |
| 本机 Claude Code + ACP adapter | ACP JSON-RPC 2.0 over stdio | `session/update` | 同一 adapter 进程持续 `session/prompt`，空闲连接池 | 命令、文件、终端与权限均回到 WillDeep |
| 本机 Claude Code 兼容 | `Process` argv + prompt stdin | `stream-json` | `--resume`，每轮新进程 | Claude CLI 策略 + WillDeep 外层 sandbox |
| 本机 Codex | `app-server --stdio` | 双向 JSONL | thread resume | 命令、文件、扩展权限均回到 WillDeep |
| 本机 Codex 兼容 | `codex exec --json -` | JSONL | `exec resume` | Codex CLI 策略 + WillDeep 外层 sandbox |
| 远端 daemon Claude/Codex | HTTP `executable + arguments + stdin_base64` + SSE | 前后台均实时归一并注册本地任务 | provider 原生 resume | daemon 工作区边界；尚无反向审批通道 |
| SSH / 可见终端 | shell / 用户可见终端 | 文本 | provider 兼容参数 | 原有审批与终端可见性 |
| Cursor / Cline | 兼容 CLI 路径 | 文本或 provider 自有格式 | 未承诺 | 原有 CLI 权限模式 |

## Codex app-server

`AgentCodexAppServerTurn` 通过 stdio 完成：

1. `initialize` / `initialized`
2. `thread/start` 或 `thread/resume`
3. `turn/start`
4. 消费 thread、item、delta、token usage 和 turn 完成通知
5. 响应 command execution、file change 和 permissions approval 请求

审批请求会转换成 `AgentDelegatedApprovalRequest`，继续复用 WillDeep 的严格模式、智能审批、工作区访问、Always Allow 和用户审批卡。停止或超时终止整个进程组。

## Claude Code ACP

本机 Claude Code 在检测到 ACP adapter 且宿主审批可用时，优先启动 ACP：

1. `initialize` 声明编辑器文件系统和终端能力。
2. `session/new` 或 `session/load` 建立会话。
3. `session/prompt` 发送文本和图片 content blocks。
4. `session/update` 归一为统一任务事件。
5. `session/request_permission` 回到 WillDeep 审批。
6. `fs/read_text_file` 读取编辑器未保存缓冲区，`fs/write_text_file` 通过宿主原子写入并同步已打开文档。
7. `terminal/*` 由宿主在工作区 sandbox 内创建、读取、等待、停止和释放。

已完成一轮的连接按 session ID 暂存；后续携带该 ID 的提示直接在同一 adapter 进程发送新的 `session/prompt`，会话级授权也随连接保留。连接空闲 15 分钟淘汰，最多保留 8 个；停止、异常退出和淘汰均终止进程树与反向终端。

## Claude Code 降级边界

ACP adapter 不可用、没有宿主审批回调或用户选择非本机 transport 时，Claude 回退到原生 `stream-json`。该路径可以用 session ID resume，但不宣称权限已回到宿主：

- 在结构化任务事件中展示 capability note；
- 继续使用 Claude CLI `permission-mode` 与 WillDeep 外层 sandbox；
- 不用 HTTP hook 模拟强审批。

## 远端 daemon 契约

`POST /v1/run/start` 和 WebSocket `run.start` 保留旧的：

```json
{"command":"git status","cwd":".","timeout_seconds":60}
```

结构化进程使用：

```json
{
  "executable":"codex",
  "arguments":["-a","never","exec","--json","-"],
  "stdin_base64":"...",
  "cwd":".",
  "timeout_seconds":3600
}
```

约束：

- `command` 与 `executable` 必须且只能提供一个；
- `arguments` 只能与 `executable` 同用；
- stdin 解码后最多 1 MiB；
- prompt 只在 stdin 中，不进入 shell 或 argv；
- HTTP 请求返回后 job 继续运行，直到完成、超时或被 kill；
- `GET /v1/run/jobs/{id}/events` 通过 SSE 实时返回 stdout、stderr 和 exit；Swift adapter 逐事件解码 provider JSONL，并把远端任务注册为可查看、可停止的本地 managed job；
- cwd 仍由 workspace root resolver 限制。

## 后续路线

1. 给远端 daemon 增加双向审批通道；当前 SSE 是 daemon 到宿主的单向事件流。
2. Cursor/Cline 在稳定 schema 可用后迁入统一事件模型。
3. 可见终端路径长期保留，作为用户主动观察真实 CLI 的独立模式。
