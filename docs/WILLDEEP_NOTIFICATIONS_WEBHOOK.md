# WillDeep 通知与 Webhook 使用指南

本文对应 WillDeep 设置中的：

`设置 → AI Agents → 通知`

这里有两套互不依赖的提醒方式：

- **声音**：WillDeep 在后台等待你授权、确认或回答时，通过 macOS 系统通知播放声音。
- **Webhook**：WillDeep 向你配置的 HTTP(S) 地址发送 JSON 事件，适合接入自建服务、消息机器人或自动化流程。

## 1. 配置通知声音

1. 在“声音”下拉框中选择系统默认声音、`Glass`、`Ping`、`Pop`、`Submarine`、无声音或自定义声音。
2. 点击“试听”检查音量和效果。
3. 使用自定义声音时，选择 MP3、AIFF、AIF、WAV、CAF 或 M4A 文件。
4. 点击“保存”。

自定义音频必须非空且不超过 30 秒。WillDeep 会将它转换为 macOS 通知兼容的 CAF 文件，并保存到用户的 `~/Library/Sounds/` 目录。

> 声音依赖 macOS 通知权限。如果没有声音，请到“系统设置 → 通知 → WillDeep”中允许通知和声音。WillDeep 位于前台时通常不会重复弹出系统通知，因为需要处理的卡片已经显示在界面中。

## 2. 配置 Webhook

### 2.1 先准备接收地址

Webhook 接收端必须满足以下条件：

- 接受 `POST` 请求；
- 接受 `Content-Type: application/json`；
- 地址使用 `http://` 或 `https://`；
- 收到请求后尽快返回任意 `2xx` 状态码。

本机调试可使用：

```text
http://127.0.0.1:8787/willdeep
```

`127.0.0.1` 只代表运行 WillDeep 的这台 Mac。若接收程序部署在另一台机器上，请填写 WillDeep 能访问到的 HTTPS 地址。

### 2.2 在 WillDeep 中启用

1. 打开“发送 Webhook 事件”。
2. 在“Webhook 地址”中填写接收地址。
3. 按需启用事件：
   - **外部执行器任务完成**：Codex CLI、Claude Code 等外部执行器的后台任务结束时发送。
   - **需要授权、确认或回答**：Agent 等待工具授权、高风险确认或用户回答时发送。
4. 点击“保存”。
5. 点击“发送测试”。界面显示“测试已送达”即表示接收端返回了 `2xx`。

“发送测试”只要求地址有效，不要求“发送 Webhook 事件”开关已经打开；正式事件则必须打开总开关和对应的事件开关。

## 3. 用 Ruby 在本机快速接收

下面的示例只使用 Ruby 标准库，并且仅监听本机回环地址。将代码保存为 `willdeep_webhook_receiver.rb`：

```ruby
require "json"
require "socket"

HOST = "127.0.0.1"
PORT = 8787
PATH = "/willdeep"

server = TCPServer.new(HOST, PORT)
puts "WillDeep Webhook receiver: http://#{HOST}:#{PORT}#{PATH}"

loop do
  client = server.accept

  begin
    request_line = client.gets&.strip
    headers = {}

    while (line = client.gets)
      line = line.strip
      break if line.empty?

      name, value = line.split(":", 2)
      headers[name.downcase] = value.to_s.strip
    end

    method, request_path = request_line.to_s.split(" ", 3)
    unless method == "POST" && request_path == PATH
      client.write "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"
      next
    end

    content_length = headers.fetch("content-length", "0").to_i
    body = client.read(content_length)
    payload = JSON.parse(body)

    puts JSON.pretty_generate(payload)
    client.write "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n"
  rescue JSON::ParserError => error
    warn "JSON 解析失败：#{error.message}"
    client.write "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n"
  ensure
    client.close
  end
end
```

启动接收端：

```bash
ruby willdeep_webhook_receiver.rb
```

然后在 WillDeep 中填写 `http://127.0.0.1:8787/willdeep`，点击“发送测试”。终端应打印收到的 JSON。

## 4. 请求格式

### 4.1 请求头

WillDeep 会发送以下主要请求头：

| 请求头 | 示例 | 说明 |
|---|---|---|
| `Content-Type` | `application/json` | 请求体格式 |
| `User-Agent` | `WillDeep Desktop (some.im) 1.315.0-rc5 (macOS)` | WillDeep 客户端及版本（1.315.0-rc5 起；此前为 `some.im/WillDeep-{版本} (macOS)`） |
| `X-App-Version` | `1.270.0-rc1` | App 版本 |
| `X-Agent-Source` | `willdeep` | 事件发送方 |
| `X-Agent-Executor` | `codex` | 实际执行器类型 |
| `X-Webhook-Schema` | `willdeep.webhook.v1` | Webhook Schema 版本 |
| `X-Agent-Event` | `attention_required` | WillDeep 原生事件名 |

接收端优先使用 `X-Webhook-Schema` 和 `event` 判断事件，不要只依赖兼容字段。

### 4.2 测试事件示例

时间、版本等值以实际请求为准。没有值的可选字段不会出现在 JSON 中。

```json
{
  "schema_version": "willdeep.webhook.v1",
  "source": "willdeep",
  "event": "test",
  "type": "test",
  "hook_event_name": "Notification",
  "occurred_at": "2026-08-17T08:00:00Z",
  "application": "WillDeep",
  "app_version": "1.270.0-rc1",
  "executor_kind": "willdeep",
  "status": "test",
  "summary": "WillDeep webhook test"
}
```

### 4.3 事件类型

| `event` | 触发条件 | `type` 兼容值 | `hook_event_name` 兼容值 |
|---|---|---|---|
| `test` | 点击“发送测试” | `test` | `Notification` |
| `task_completed` | 外部执行器后台任务结束 | `agent-turn-complete` | `Stop` |
| `attention_required` | 等待授权、确认或回答 | `approval-requested` | Codex 为 `PermissionRequest`，其他执行器通常为 `Notification` |

`attention_required` 的 `notification_type` 常见值：

- `permission_prompt`：等待工具授权或高风险确认；
- `elicitation_dialog`：等待用户回答；
- `idle_prompt`：其他需要用户处理的状态。

### 4.4 主要 JSON 字段

| 字段 | 是否总有 | 说明 |
|---|---:|---|
| `schema_version` | 是 | 当前为 `willdeep.webhook.v1` |
| `source` | 是 | 固定为 `willdeep` |
| `event` | 是 | WillDeep 原生事件名 |
| `type` | 是 | 兼容 Codex 风格的事件类型 |
| `hook_event_name` | 是 | 兼容 Claude Code/Codex Hook 的事件名 |
| `occurred_at` | 是 | ISO 8601 UTC 时间 |
| `application` | 是 | 固定为 `WillDeep` |
| `app_version` | 是 | WillDeep 版本 |
| `runtime_id` | 否 | WillDeep 运行会话 ID |
| `session_id` | 否 | 与 `runtime_id` 相同的兼容字段 |
| `thread-id` | 否 | 与 `runtime_id` 相同的 Codex 旧兼容字段 |
| `session_title` | 否 | 会话标题 |
| `executor` | 否 | 执行器显示名称，例如 `Codex CLI` |
| `executor_kind` | 是 | 标准化执行器类型，如 `codex`、`claude-code` 或 `willdeep` |
| `status` | 是 | 任务或交互状态 |
| `task_id` | 否 | 后台任务句柄，例如 `job_ab12cd` |
| `attention_kind` | 否 | 需要处理的工具类型 |
| `notification_type` | 否 | 授权、确认或问答的兼容分类 |
| `message` | 否 | 等待处理事件的简短描述 |
| `summary` | 否 | 事件摘要 |

## 5. 接收端处理建议

接收端可以按下面的顺序处理：

1. 验证 HTTP 方法和 JSON 格式。
2. 检查 `X-Webhook-Schema` 是否为支持的版本。
3. 读取 `event` 并路由到对应处理逻辑。
4. 先返回 `2xx`，再异步发送机器人消息或执行其他耗时操作。
5. 使用 `runtime_id`、`task_id`、`event` 和 `occurred_at` 组合去重。

示例伪代码：

```text
if event == "attention_required"
  通知用户回到 WillDeep 处理
else if event == "task_completed"
  更新任务状态或发送完成提醒
else if event == "test"
  只记录连通性测试
end
```

Webhook 只是“通知”，不能直接在接收端替用户批准工具调用或填写回答。

## 6. 配置文件

界面配置保存在：

```text
~/.willdeep/config.toml
```

对应的 TOML 内容类似：

```toml
[notifications]
sound = "glass"
custom_sound_file = ""
custom_sound_display_name = ""
webhook_enabled = true
webhook_url = "http://127.0.0.1:8787/willdeep"
webhook_on_task_completed = true
webhook_on_attention_required = true
```

建议优先通过界面修改，尤其是自定义声音；界面会负责格式转换和路径管理。

## 7. 隐私与安全

- Webhook 不发送模型完整输出、用户回答或完整命令参数。
- 等待处理事件可能包含简短工具描述，例如命令程序名与子命令、MCP 工具名或文件名；接收端仍应按敏感数据管理。
- 当前 Webhook 没有签名，也不支持在界面中配置自定义鉴权请求头，因此接收端不能把请求本身当成高权限授权凭证。
- 公网接收端应使用 HTTPS，并在反向代理或网络层限制访问；不要把 Token、密码或 Webhook Secret 直接放进 URL。
- `~/.willdeep/config.toml` 中的 Webhook 地址是本地明文配置，不应提交到 Git。
- 接收端日志应设置保留期限，并避免记录不必要的会话信息。

## 8. 常见问题

### “发送测试”失败或没有收到请求

依次检查：

1. URL 是否以 `http://` 或 `https://` 开头，并包含有效主机名。
2. 本地接收程序是否正在监听填写的端口和路径。
3. 接收端是否确实处理 `POST`，而不是只支持浏览器访问的 `GET`。
4. 接收端是否在约 15 秒内返回 `2xx`。
5. 端口是否被防火墙、VPN、代理或容器网络隔离。
6. 远端 HTTPS 证书是否有效。

### 测试成功，但正式事件没有收到

检查“发送 Webhook 事件”总开关以及对应的两个事件开关是否已经打开并保存。任务完成事件只针对带有外部执行器信息的后台任务；普通本地 shell 任务不一定触发该事件。

### Webhook 会自动重试吗？

当前正式事件采用一次性异步投递，没有持久化队列和自动重试。接收端应保持高可用，并尽快返回 `2xx`。

### 为什么有声音，但没有 Webhook？

声音与 Webhook 是两套独立配置。请确认 Webhook 总开关、地址和对应事件开关均已保存。

### 为什么有 Webhook，但没有声音？

Webhook 不依赖 WillDeep 是否位于前台；系统声音则受 App 前后台状态、macOS 通知权限、专注模式和系统音量影响。
