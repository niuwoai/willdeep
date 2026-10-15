# 原生 RSI P4a/P4b 离线验收

当前版本：1.420.0-rc1（build 918）。实现候选与证据基础设施，不自动晋升版本，不进行真实模型评测。候选保存与安装/选择/私有定义同步完全分开。官方定义必须先派生为用户副本。

运行 `ruby scripts/agent_rsi_acceptance.rb`，无需解锁界面或安装应用。脚本复用既有 Xcode 缓存并串行运行契约、版本库及 Goal 证据测试。原生配对 runner 对 validation/regression/holdout 各运行 baseline/candidate，共六个独立 trial；每个有独立数据目录、工作区、请求 SQLite 账本和事件目录，不覆盖进程 HOME。传输只使用会拒绝全部外部地址的 URLProtocol mock；正常 Worker 工具链实际读取 fixture.txt，并由固定 grep 命令验证。两臂不得接触用户普通会话、已安装定义或账号数据。

需要跨端 HTTP 验收时运行 `ruby scripts/agent_rsi_acceptance.rb --service-receipt /private/tmp/someim-rsi-p4ab-reviewed-receipt.json`。只接受显式 mock_only 的 localhost 假会话回执，脚本不会打印令牌。真实 HTTP 服务必须由统一验收控制器启动，数据库、会话及会员关系全部隔离。上传后同时保留 local_mock 原件和服务端 client_reported 回执，其 canonical hash 不同是正常信任降级。

输出位于 `build/rsi-offline-acceptance/acceptance.json`、`acceptance.md` 和每次执行子目录的 `report.json`、`report.md`；详细 Xcode 回归结果位于 `build/fast-tests/report.json`、`report.md`。目标未执行、验证不通过、终态缺失或证据丢失都不能通过。普通运行只使用独立 runtime-event schema，不伪造实验或任务集哈希。历史恢复扫描按会话隔离且每个进程只执行一次，孤立开始记录明确标记中断。

编译产物哈希按实际 App 主可执行文件计算。未注入的源码 commit 显示 unavailable-local-build；这样的记录不能作为正式模型比较或晋升证据。本阶段没有付费预算授权、晋升、灰度应用、撤销已安装版本或自动回滚入口。

共享字段、数值词法、不可变性、权限边界及 HTTP 协议见 [AGENT_RSI_CONTRACT.md](AGENT_RSI_CONTRACT.md)。33 个共享反例同时验证 raw tokenizer、shape、语义与跨对象绑定，不能用 Foundation 自动解码代替。

中途停止会保留不可变 trial 原件，并写出 `complete=false`、`halt_reason` 的 JSON/Markdown 汇总；预算耗尽、阶段门禁拒绝、中断或证据不完整不会被补成成功。预算反例报告保存在 `build/rsi-partial-acceptance`，不混入六条完整验收样本。版本库的既有单元测试使用临时磁盘、UserDefaults 和 URLProtocol 假会话；单靠这些不能证明双端并发冲突或 GUI 账号切换。真实客户端联合 HTTP 验收单独记录如下。

追加 `--registry-binary /absolute/path/to/willdeep` 可执行独立的双端注册表验收：原生 Mac 服务层与冻结的 Rust CLI 经真实 localhost HTTP，以同一语义版本、不同内容制造并解决双向冲突；保本机时显式生成新版本，保远端时归档旧分支。另检查固定/回滚、合成客户和租户切换、旧会话拒绝及删除记录不复活。报告位于 `build/rsi-registry-interop`；该测试不操作 GUI、不使用生产账号，不能表述为 GUI 真账号切换验收。

2026-10-15 最终验收：六套定向原生测试 **54/54 通过，0 跳过**，付费 Provider 请求为 0。原生 runner 的六次实际 Worker 执行已上传隔离服务；原生 API 客户端同时严格读取 Rust peer 的 48 条证据并校验 canonical SHA、候选/实验绑定及 client_reported 信任级别。另以冻结的 Rust CLI 实跑四轮双方同语义版本、不同 SHA 的冲突，双端各验证保本机新版本/CAS 与保远端；合成不同客户/租户切换、恢复账号、拒绝旧会话、历史固定/回滚保护和 Rust 删除后 Mac 接收 tombstone、重复同步不复活均通过。合成注册表测试条目已经正常删除并同步，RSI 证据保留供另一端复核。

上述结果证明免费执行链、契约与真实双端服务层互通，不代表真实模型质量、真实用户账号 GUI 切换或候选晋升已验收。SwiftUI 实验和冲突版本输入界面已编译，当前没有安装或操作发布应用。完整测试证据和临时会话留在忽略的 `build` 目录；提交内容不包含会话回执、令牌、测试数据库或构建产物。
