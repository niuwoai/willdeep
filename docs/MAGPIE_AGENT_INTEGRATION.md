# Magpie 社区 Agent：Desktop 集成与双端边界

> Last updated: 2026-11-04 | Desktop 1.427.0-rc1 / Build 941 | 状态：本地实现并通过桌面验收，未发布

这是既有 Provider/会话能力的窄接入，不新增共享凭据后端。跨端契约唯一事实来源为 willdeep-rs 的 `docs/MAGPIE_AGENT_REQUIREMENTS.md`、`docs/MAGPIE_AGENT_DESIGN.md` 和 `docs/MAGPIE_AGENT_PLAN.md`；机器可读输入为该仓的 `docs/schemas/magpie-agent.v1.schema.json` 与 `docs/fixtures/magpie-agent-v1/cases.json`。本文件记录 Desktop 的生产接入点，不复制或改写 canonical。

## 配置与所有权

- Desktop 只读用户 Home 下 `.willdeep/integrations/magpie/desktop/connection.json`。`client_id` 为 `willdeep`，公开归因标记为 `magpie-willdeep`，临时 Provider UUID 为 `70D7B194-6038-4B32-8195-84F25E1648A3`。
- 启动时只在自己的 Desktop 目录写 `client.json` 支持标记，记录客户端身份、契约版本和 App 版本；不创建或修改 Magpie 托管的 `connection.json`。Desktop 插件据此检测至少启动过一次支持版本的客户端，不依赖可选的命令行启动器。
- CLI 使用独立的 `cli/connection.json`、`willdeep-cli` / `magpie-willdeep-cli` 身份和 `magpie-cli` Profile。标准目录相邻不表示共享开关、连接、账号、控制面或运行时。自定义 CLI 根不影响 Desktop Home。
- `effectiveAgentProviderLibrary` 只在内存投影用户库与临时条目。设置页、`saveProviderLibrary` 与钥匙串保持使用原库；冲突的用户 UUID 报错并保留原条目。

## 读取与传输

`AgentMagpieIntegration` 严格读取 v1：文件上限 65,536 字节，拒绝重复键、未知字段、错误类型、跨客户端身份、非整数数字 token；模型非 blank、无 C0/C1 控制、最多 1,024 UTF-8 字节。窗口为 4,000..1,048,576，输出为 1..1,048,576，二者均已知时输出不得超过窗口。

回环 URL 仅接受小写 http(s)、规范四段 127/8 IPv4、localhost 或 [::1]，可选端口 1..65535，路径精确 `/v1`。拒绝认证、query、fragment、非规范主机与其他路径；localhost 在实际请求前替换为 127.0.0.1。`AgentMagpieTransport` 使用无 Cookie/凭据存储的 ephemeral URLSession，关闭 HTTP/HTTPS/SOCKS/PAC 代理并拒绝跳转。模型目录、主请求和辅助请求沿同样的来源校验与传输。

目录按句柄逐层 `openat`，拒绝符号链接；连接文件以 `O_NOFOLLOW | O_NONBLOCK` 打开，对同一描述符执行普通文件检查和有界读取，读取前后比较 size/mtime。仅可重试 I/O 或截断在异步路径延后 100ms 重读一次。磁盘工作运行于 utility detached task，不阻塞 UI 主线程。

缺失、空对象、合法 `enabled:false`、仅有合法 `model` 均为断开；已提供的所有字段仍先校验。原生 model-only 恢复结果不成为 Desktop 的新模型配置。错误只显示分类，不回显 JSON 或连接标记。

## 会话与界面

新会话创建后异步读取，派发等待准备完成，再固定 Provider 与完整模型 ID。后续执行刷新端点，但固定模型 A 不随外部 B 改写；B 的窗口/输出元数据不套到旧 A。运行中回合持有已构建配置快照，连接变化不取消当前任务。

只有新创建且未被用户显式改选的会话拥有默认采用资格；恢复的旧无绑定会话沿原有用户配置解析。用户选择其他 Provider/模型取消该资格，无关 invalid 文件不阻止其执行。明确绑定集成的会话在断开或无效时返回可恢复错误，禁止回退到其他供应商。审批档位、沙箱、工具权限、Worker 的明确配置保持独立。

模型选择器显示临时 Magpie 条目、管理来源、刷新和配置错误状态；普通设置页不编辑此临时条目。App 回到前台和打开模型选择器会刷新。新增反馈使用 `MagpieIntegration.xcstrings` 的中文、英文、日文资源。工程使用文件系统同步组，新增 Swift、测试和 string catalog 自动纳入相应 target。

## 本地验证入口

基础契约测试不启动 App、不读用户配置、不调用真实模型：

```sh
ruby scripts/run_magpie_integration_tests.rb /absolute/path/to/willdeep-rs/docs/fixtures/magpie-agent-v1/cases.json
```

生产 AppState 与 AgentClient 的测试为 `AppStateMagpieIntegrationTests`；使用临时 Home、测试 Provider 库和 XCTest 内存钥匙串，真实 HTTP 只连接随机本机端口的 `MagpieFakeUpstream`，覆盖目录、流式和辅助请求。Xcode 测试按 `TESTING.md` 经仓库构建锁执行，不能把仅 Foundation 测试通过当作整套 App 验收通过。

本轮实际结果：独立 Swift 契约测试 14 项通过，消费 27 个共享 fixture 且输入 SHA-256 不变；Xcode 原生测试 19/19 通过（2 个 suite）；隔离 Debug 构建成功（arm64、无签名）。未运行全仓完整测试集，未做真实 App 前台点击 Magpie 的组合验收，未签名、公证或安装。CLI/Runtime/插件侧证据见 willdeep-rs 仓 `docs/verification/0.142.0-rc1/magpie-agents/README.md`（本轮工作尚未提交，该路径以本地分支为准）。

隔离 App 构建传入 `WILLDEEP_BUILD_ENV_FILE=/dev/null` 并清空四个可选构建凭据环境变量（`WILLDEEP_CLIENT_LOGIN_SECRET`、`AIPIPE_API_KEY`、`AIPIPE_ENDPOINT`、`AIPIPE_TOPIC`），使用工作树专属 DerivedData，不进行安装或启动用户正在使用的 App。构建所需插件子模块必须检出锁定提交；不可省略缺失插件后把不完整 bundle 声称为通过。

未获授权前不提交、合并、推送、打 tag、签名发布或提交社区收录；本地包和构建成功不表示已上架。手动 App 前台刷新、真实 Magpie 宿主点击连接的组合验收与发布分别记录，不能从单端单测推断。
