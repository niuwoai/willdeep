# WillDeep Video Studio

Video Studio 是一个完整的本地 WillDeep 插件：聊天模型负责把创意整理成镜头方案，视频 Provider 负责异步生成，Ruby MCP 服务负责保存任务、轮询状态和下载成品。

## 能力

- 文生视频：不提供参考图时提交 `t2va`。
- 首帧图生视频：提供本地 PNG、JPEG 或 WebP 时提交 `fl2va` 与 `input_reference`。
- AI 导演：读取 WillDeep 已启用的聊天 Provider 和模型；默认沿用当前 Provider 的 Flash 档，也可在页面中固定 Provider/模型。
- 异步任务：保存本地 ID 与远端任务 ID，区分草稿、提交、排队、生成、完成和失败；页面有活动任务时在上一批请求结束 5 秒后再轮询。
- 成品管理：完成后默认流式下载 MP4，也支持关闭自动下载后手动下载或重试下载；可在访达中定位，移除任务记录不会删除视频文件。
- 聊天接力：选中聊天文本执行“发送到视频工坊”，先保存为可编辑草稿，不会直接产生费用。

## 安装与配置

1. 运行 `ruby scripts/package_video_studio.rb`，在 WillDeep 插件中心选择生成的 `build/plugins/willdeep-video-studio-0.1.0.zip`。安装包只包含运行文件，不含前端开发依赖。未安装过前端依赖时也可直接选择源码目录。
2. 审核插件声明的进程、网络、凭据、AI 聊天和 Provider 读取权限后安装。
3. 在插件设置中填写 `Video API Key`。该字段为 `secret`，由宿主安全存储，不写入任务文件或页面。
4. 默认 API Base 为 `https://hub.tsingfly.com`，默认视频模型为 `MiniMax-H3`，默认输出目录为 `~/Movies/WillDeep Video Studio`。

聊天模型的密钥仍由 WillDeep 宿主管理。插件页面只选择 Provider ID 与模型名，并通过 `window.willdeep.ai.complete` 发起创意整理，不接触聊天凭据。

## Provider 抽象

页面和任务存储只依赖统一的异步生命周期：

1. `create(request)` 返回远端任务 ID、状态和可选输出地址；
2. `retrieve(remoteID)` 返回标准状态 `queued / in_progress / completed / failed`；
3. `download(url, remoteID)` 把成品流式保存到本地。

默认 `OpenAIVideosAsyncAdapter` 对接 Tsingfly Hub：以 multipart 请求 `POST /v1/videos`，通过 `GET /v1/videos/{id}` 查询。FPS 固定 24，时长支持 2、4、6 秒。后续接入其他视频服务时，只需实现同一适配器边界，不必改 React 页面或任务仓库。

创建请求若发生网络超时、返回非法 JSON 或缺少任务 ID，任务会标记为“提交结果不明确”，插件不会自动重新 POST。MCP 重启后也会恢复中断的提交为不明确状态。用户核对服务端后才能经页面确认显式重试。查询阶段的 429 会保留任务及 `Retry-After` 并退避，既不误判生成失败，也不重叠堆积轮询请求。

## 本地开发

前端使用 Yarn：

```bash
cd PluginExamples/video-studio/ui
yarn install
yarn test
yarn build
```

服务端闭环测试使用本地假网关，不访问真实视频服务，并生成 Markdown 与 JSON 报告：

```bash
ruby scripts/video_studio_server_test.rb build/ci/video_studio_server_report.md build/ci/video_studio_server_report.json
```

插件提交中包含 `ui/dist`，安装器无需现场安装依赖或运行构建。

## 数据与安全边界

- 任务默认保存在 `~/Library/Application Support/WillDeep/plugin-data/video-studio/jobs.json`，最多保留 500 条。
- API Key 只通过插件 secret 设置注入 MCP 进程，状态接口和持久化文件均不返回它。
- API Base 只接受 HTTPS；仅测试时允许 localhost HTTP。
- 参考图限制为 PNG/JPEG/WebP 且不超过 32 MiB；单个视频下载上限 1 GiB。
- 输出下载地址必须使用 HTTPS；本地集成测试只放行 localhost HTTP。
- 插件不会创建后台定时任务。只有页面打开且存在活动任务时才会轮询。
