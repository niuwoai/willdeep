# 模型费用与短剧插件联合发布

状态：插件已发布；Rust 发行进行中；Mac 待最终定向复验后发布。下方最新进度优先于早期记录。

## 最终 Mac 候选验证（2026-10-26 22:15）

短剧子模块固定 rc9 后，插件、桥接、价格和统计四套件共 386 项通过，xcodebuild 与报告均退出 0；包含新增 Haiku 日期/latest 别名长上下文用例。候选版本 1.425.0-rc1 已具备提交与签名发布条件。

## Rust 发行验证修复

- rc1 Linux x86_64 的交付下载回归失败于测试读回：实读 160768 字节，预期 196625 字节，实际内容恰好是预期前缀。Tokio 文件 write_all 后缺少 flush，测试 drop 后立即同步读取存在异步落盘竞态。
- rc2 增加 flush 后再读回，断言长度及 SHA256，不再在失败日志输出完整媒体字节；产品交付逻辑未作绕过。相关测试正在重跑，已发布 rc1 标签不会移动。
- cargo 安装 rc1 已完成（早于修复完成），后续将安装最终通过发行验证的 rc2；未执行 Runtime 升级。

## Mac 全量验收完成（2026-10-26 22:03）

- 全量 xcodebuild 退出 0。Swift Testing 5086 项、492 套件通过；xcresult 汇总含 XCTest 为 5092 通过、1 项既有跳过、0 失败。
- 完整证据存于 `build/full-tests-passed-5086`，其 Markdown/JSON 已从归档 xcresult 重新生成。
- 全量完成后，短剧子模块固定为已发布的 `456ddca`（rc9）。最终定向复验覆盖插件宿主、Runtime 桥接、费用统计及 Haiku 日期/latest 别名长上下文修正。
- `version_consistency.rb` 通过，Mac 版本 `1.425.0-rc1`。

## 已发布及待发布状态（2026-10-26）

- 插件 `v0.53.0-rc9` 已正式发布：提交 `456ddca2cb1c809d883bff106e06eeed6b808d94`，main/develop/标签均已推送。GitHub 发行任务 `40334680751` 成功，Release：https://github.com/niuwoai/willdeep-video-studio/releases/tag/v0.53.0-rc9 。
- 下载的发行 ZIP 为 847111 字节，SHA256 `33193b0cfc01fbcb1ca3c47d33572a2623329d22ee158bb27b61c59982231b90`；校验文件匹配，展开后的 133 个文件逐个 SHA256 与本地候选相同。ZIP 时间戳导致本地产物与 CI 压缩包摘要不同，内容一致已实证。
- Rust `v0.122.0-rc1` 提交 `1606b4d5edd595c49c753fd91bb8d3c5f62779af` 已快进 main/develop 并推送标签。全工作区测试、最新制作 65 项、内置插件契约与 `cargo clippy --workspace --all-targets --locked -- -D warnings` 通过。跨平台发行任务 `40335138091` 正在运行；尚未验证发行资产或更新 Homebrew。
- Mac 全量测试仍在运行；插件子模块暂为前候选 06c46f0，rc9 已 fetch，待测试结束后切换到 456ddca 并复验插件套件。Mac 尚未提交、集成或发布。
- 实际 WebKit blob 下载及文件内容校验通过。来源站点 src/content 未找到固定旧版本或 dmg 下载路径。
- 本地 cargo install 正在构建新 CLI，没有执行 daemon upgrade。生产 Runtime 保持运行。

## 最新进度（2026-10-26 21:47）

- Rust 全工作区测试退出 0：CLI 995、detached jobs 18、headless Runtime 40、版本 1、core 811、provider contracts 5、client 7、protocol 41、doc-test 1 通过；已有忽略项保留。新增插件快照仍需重新验证内嵌包契约。
- Mac 定向复验退出 0：395 项、6 个套件通过，包含先前失败套件、定价、统计与桥接。完整全量已启动，仍以最终结果为发布门槛。
- 封版重新清点源目录发现新增旧问题独立复核与文字审核路由设置；源版本已经是 rc8。因此发布副本吸收差异并递增为 **0.53.0-rc9**，保留原有翻译和证据夹具修复。来源快照清单已更新；06c46f0 仍是先前候选提交，不是最终发布提交。
- rc9 UI 32 文件、385 项通过，TypeScript 与 Vite 构建通过；新增配置字段中文参数标签已补齐。服务端 52 个脚本正在完整复验。沙箱 loopback bind 被拒的运行已停止，已改为获准的隔离本机测试运行。
- Rust 已同步 rc9 的 133 个运行文件及 VERSION；Mac 子模块尚待 rc9 测试通过并提交后更新。
- 尚未上传插件、推送发布标签、生成签名 DMG 或修改生产 Runtime。
- 后续核对：源 Rust 制作调度将分集写作尝试上限同步为 24，已吸收 engine/tests 两处变动并重跑制作测试；其他阶段上限与累计预算限制保持源码规则。前述全工作区通过结果发生在这次同步之前。
- rc9 内置插件安装及版本契约单测已通过。原生交付真实源码的隔离夹具 5/5 通过（全文读取、Range、摘要/大小/路径拒绝），报告 `/private/tmp/native-production-delivery-report.json`；尚不代表 WebKit 播放及保存面板验收。
- release-macos-app plan 确认 universal 双架构，但因当前提交未进入 main 而退出 1；这是待测试通过后提交、集成的发布前置条件，未绕过 GitHub Release 检查。

当前候选：macOS 1.425.0-rc1，Rust 0.122.0-rc1；短剧插件已提交 06c46f0（0.53.0-rc8，基于 origin/main 重放，源码树与重放前相同），未推送/打标签。Mac 短剧子模块固定此提交，配置子模块固定 c17f639（已发布 0.6.0-rc2），包结构和页面校验通过。

2026-10-26 验证进度：
- Mac 首轮定向实际跑 71 项、3 个套件通过；旧统计测试属于 WillDeepTests 扩展，原指定文件名不会选中，现已启动全量测试。
- 全量测试已发现新版技能依赖断言过时（新增 production-repair），已修正；多项任务/进程测试同时触发 60 秒上限，还有 RSI fixture firstContactTimeout，尚需隔离并发影响并复验，不能据此发布。
- Rust 工作区 check 通过；新 plugin.workflow 两项权限边界单测通过；全工作区测试进行中。
- 真实隔离 Runtime 验收通过：未批准插件拒绝、两类工作流列表返回宿主工作区、私有 production.step 拒绝，临时 Runtime 已停止。报告 `/private/tmp/plugin-workflow-bridge-report.json`，无付费生成。
- WebKit 独立自定义协议夹具确认 secure context 与 crypto.subtle 均可用；实际成片 Range/保存及 blob 下载尚需进一步验收。
- 插件重放后 51/51 个服务端脚本通过；候选压缩包 SHA256 为 e7636ae7d64628c8e562f51278855e82a894b55f197a63535bd60e347712ad47。
- Mac 首轮全量失败报告保存在 build/full-tests-first-failure（3833 个记录、23 个失败、1 个跳过；包含超时退出后重启）。已用 -parallel-testing-enabled NO 对失败套件、新桥接与 WillDeepTests 实际统计套件复验；之后仍需完整全量通过。

## 发布要求

- Magpie 模型按首个 `/` 前缀分组，保留完整调用 ID。
- Magpie 网关归为远程推理；修正能够识别来源的历史请求统计。
- 按请求时间计算 DeepSeek 闲时/忙时费率，模型表覆盖主流 Codex、Claude；未知型号不得误匹配成旧型号。
- 桌面、CLI 账本和日历使用逐请求计价后的汇总；标明参考价、来源、核对日期和估算边界。
- 最新短剧插件完整打包；兼容它要求的 Runtime 控制接口、资源配置和交付文件访问。
- 定向验证、全量单测、版本一致性检查通过后提交；集成保留原提交历史。
- 发布签名、公证的 universal macOS 包；Rust 对应宿主能力发布时验证各平台资产与内置插件版本。

## 当前副本

- Xedit：`/private/tmp/xedit-model-pricing-release`，分支 `codex/model-pricing-plugin-release`，基线 `8580ebc3`。
- 插件：`/private/tmp/willdeep-video-studio-release`，来自 `65354d2` 加当前未提交文件的独立快照。捕获文件校验清单：`/private/tmp/video-studio-source-snapshot.json`。
- 插件快照版本 `0.53.0-rc7`；本发布副本修复工具标题及参数标签后为 `0.53.0-rc8`。封版前须重新比较源文件，吸收期间新增改动，并检查版本是否被其他任务使用。
- Rust 新插件宿主实现位于 `/Users/rocky/Sites/willdeep-video-studio/build/willdeep-rs-screenplay`，`549f8a71` 加未提交 production 实现。最新配置工作台位于主线 `40909171`（`0.121.0-rc5`）。集成前刷新远端引用。

## 尚需完成

- 已补齐 GPT-6 Sol、GPT-5.6 Sol 当前促销价、272k 长上下文规则。缓存写入时长尚未单独采集，界面明确短时标准费率假设；仍需复核历史别名适用时间。
- 已在费用面板增加来源/日期及估算边界的中英文说明；日历未知费用不再按零处理。需完成回归验证。
- Rust 已在 `/private/tmp/willdeep-rs-plugin-release` 合并配置基线 40909171 和自动制作源码快照，保留 deferred gates 与 production recovery 两条启动路径；候选 0.122.0-rc1。Magpie 账本、推理参数、配置本地标识已修正，插件 0.53.0-rc8 的 132 个运行文件已同步并校验。首次 cargo check 因缺少 web/dist 失败，正在构建 Web 资产后重试。
- macOS 新增受限工作流路由：在统一 MCP tools/call 入口仅转发公开 production/screenplay 工具到 Runtime `plugin.workflow`；不宣告本地不存在的反向控制能力。Runtime 通过已启用、已批准插件执行，工作区、预算与请求去重仍由内部控制实现负责，使用 Runtime 数据目录。代码已写，待端到端验证。
- 原生 `/plugin-production/<id>/<selector>` 已实现验收重查、路径/大小/SHA256 校验、分块预览、Range seek 和保存面板。待实际下载及取消验证。
- 插件 UI 385/385 通过，构建通过；工具标签 16/16、版本 4/4 通过。服务端全量已在获准 loopback 环境重跑；production_design 的夹具已同步新 sourceRef 协议并 6/6 通过，production_source_mcp 夹具已补 sourceDigest 待重试结果。
- Xcode 首次定向构建发现测试给只读 createdAt 赋值，已改为初始化传入；第二次定向测试进行中。日历未知成本修正发生在第二次构建启动后，最终需再全量复验。
- 发布前固定插件源码提交、包校验和、宿主内嵌版本，验证发行资产实际内容。

## 价格依据

- 核对日期：2026-10-26，币种 USD，每百万 Token。
- https://api-docs.deepseek.com/quick_start/pricing/
- https://api-docs.deepseek.com/updates/
- https://developers.openai.com/api/docs/pricing
- https://developers.openai.com/api/docs/models/gpt-6-sol.md
- https://developers.openai.com/api/docs/models/gpt-6.1-sol.md
- https://platform.claude.com/docs/en/about-claude/pricing
- 2026 节假日：国办发明电〔2025〕7号。未维护年份不推断节假日折扣。

运行中的真实制作任务、其账本和媒体文件属于生产现场。发布验收使用独立数据；Runtime 升级交接需独立核对，不能以安装了新 CLI 代替运行版本证据。
