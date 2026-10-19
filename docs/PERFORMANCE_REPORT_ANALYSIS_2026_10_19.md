# WillDeep macOS CPU 报告分析（2026-10-19）

## 证据范围

- 对 some.im 生产 `client_perf_reports` 执行只读查询，仅筛选 `app_id=willdeep`。
- 读取 18 份报告：934、933、932、931、930、929、928、926、925、924、917、906、904、903、901、900、899、892。
- 覆盖 `1.421.0-rc2`（Intel）和 `1.422.0-rc2`（Apple Silicon）。
- 使用与 Binary Images UUID 完全匹配的 dSYM 符号化：Intel 为 `A8E903DC-996D-3718-81B7-CD5A2EB0FADC`，Apple Silicon 为 `FC8AD8F7-246A-3FE5-8C0A-9B01C38E710C`。
- 原始调用栈仅存本机临时诊断目录，不入库、不提交用户数据或安装标识。本文件仅保留函数级证据。
- 采样是报告触发之后的短时间快照；触发 CPU 值与栈帧占比不是同一时间窗口。等待、睡眠和采样工具自身帧不算 CPU 热点。

## 已确认热点与本次修复

### MCP 大消息重复扫描

报告 899、900、901、903 的主线程几乎全部等待事件，但 `NSFileHandle.fd_monitoring` 线程持续执行：

`AgentPipeEOFReader.attach → MCPLineInbox.append → Collection.firstIndex(of:) → Data storage access`

`MCPLineInbox.append` 在每次收到分块时，都对完整累计缓冲区调用 `firstIndex`；尚未收到换行的大型 base64/JSON 行会重复扫描已检查过的前缀。在这四份报告中，该函数分别占相关线程 1283/1288、1254/1372、1096/1213、1356/1362 个采样。

修复：独立增量分帧器只扫描新增字节，通过连续字节视图访问，完成的行一次提取。保留半行、跨块 UTF-8、空行、CRLF 和多行顺序。MCP 收件箱的反向请求、条件变量和通知派发逻辑不变。

### 会话统计持久化

报告 892、917、929、934 的写队列反复出现：

`AgentSessionStore.saveAsync → writeUsageCatalogEntryBestEffort → AgentUsageDatabase.upsert → writeSession → executeBinding → sqlite3_prepare_v2 / sqlite3RunParser / sqlite3Insert`

例如报告 892 中该写队列全部 1457 个采样落在统计库更新，其中 1127 个位于逐消息写入循环。报告 929 中还出现 `UsageCatalogEntry.encode → AgentUsageSessionSnapshot.encode` 的统计 JSON 编码。

修复：固定写 SQL 按连接缓存预编译语句；每次执行后 reset、清空绑定，连接析构时 finalize。现有锁与事务边界不变。统计侧车 JSON 去掉 prettyPrinted/sortedKeys，只改派生缓存的存储格式，不改字段、时间精度或会话原文。

## 其他观察与边界

- 报告 932、933 还有聊天历史全文渲染、Markdown 格式化和 minimap 指纹计算；报告 926 出现用户消息分类和敏感信息脱敏。它们需要单独追踪触发频率，本次不凭短采样重写 UI 或统计口径。
- 部分报告如 931 在采样期间已回到等待状态，无法据此反推触发时的全部原因。
- SQLite 仍按既有契约重建当前会话统计；本次降低每行写入成本，没有引入历史增量缓存或改变一致性边界。

## 验证

- 原生构建及所选 6 个相关测试套件共 52 项全部通过，xcodebuild 退出码 0、`report.json.status=passed`，日志与结果计数一致。覆盖 `AgentMCPLineFramerTests`、`AgentMCPBridgeCoreTests`、`AgentMCPStdioEOFReaderTests`、`AgentMCPHostRequestsTests`、`AgentUsageSidecarTests`、`AgentSessionPersistenceTests`。不是全仓库全量单测。
- 首次构建因新工作树未初始化内置插件子模块失败，未执行测试；补齐仓库固定的 gitlink 后重新构建并完成上述测试，没有修改插件版本或绕过打包步骤。
- 原生测试覆盖大消息分块、跨字节 UTF-8、半行和切片数据；统计测试覆盖可选字段清空、工具列表替换、删除与重建，沿用侧车和数据库往返等价检查。
- `ruby scripts/benchmark_mcp_line_framer.rb` 用相同 Release 优化配置对比原始分帧算法和当前实现，4 KiB 分块、每档三次取中位数，逐字节检查输出。JSON 与 Markdown 输出在 `build/perf-line-framer/`。
- 首次基准：256 KiB 为 41.332 → 0.483 ms；1 MiB 为 1011.773 → 0.933 ms；4 MiB 为 15241.368 → 4.928 ms。
- 统计库独立基准使用修复前后实际 `AgentUsageDatabase.swift`，相同 2000 条消息、4000 个工具记录，7 次写入取中位数并检查往返一致性；替身仅用于未参与本次负载的嵌套记录类型。编译结束后在新临时库上交替运行三组，组中位数再次取中位数：31.038 → 16.725 ms（耗时下降约 46%）。修复前各组 30.987/31.038/31.338 ms，修复后 16.725/18.469/16.475 ms。
- 同一统计快照紧凑编码从约 1.146 MB 降至 0.760 MB，字节数下降约 34%；三组中格式化编码约 17–20 ms、紧凑编码约 14–15 ms。
- 上述为函数/存储层基准，不代表整个 App 的 CPU 降幅。需要安装后在相同插件大消息和长会话负载下重新采样，才能确认端到端收益。
