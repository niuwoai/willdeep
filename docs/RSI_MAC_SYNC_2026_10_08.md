# Mac RSI 同步与输入交互改进

版本：1.414.0-rc1，build 891。工作分支：codex/mac-rsi-confirmation。

## 执行命令被 Goal 闸门阻止

复现状态为 Goal 交互模式、已完成的 currentPlan、缺失 currentGoal 和 goalPlanningState。旧逻辑仍要求计划阶段，而规划入口要求 currentGoal，导致 run_command 与工具派发持续被拒。

修复仅放行上述无有效 Goal 的已完成计划。有效 Goal、未完成计划、没有计划的 Goal 会话仍遵守原有闸门。AgentGoalTeamsTests 覆盖这些状态。

## 本地交互

- `/goal` 在斜杠菜单中可选，Enter 或 Tab 确认后就地切换 Goal 模式；不调用模型、不新建会话。输入前缀仍保留菜单过滤行为。
- 灰字建议在打字时隐藏，删空后恢复；Tab 采用但不自动发送，Esc 明确放弃。ComposerTextInputTests 覆盖实际 NSTextView 和协调器。
- 确认卡片支持 Y 同意、N 拒绝；只有既有持久授权允许时才支持 A。问答卡片支持 1–9 选择/切换选项、Y 提交已选择答案，超过九个选项使用鼠标。
- 仅当前窗口、活动会话首个待处理卡片接收快捷键。已有草稿、其他文本框、输入法组字、组合修饰键及按键重复均保留原行为。危险确认沿用既有授权路径。
- 提示文案进入六语言资源；不把实现细节写进产品文案。

## 本机反馈

默认写入 `~/Library/Application Support/WillDeep/feedback/*.jsonl`，schema 为 willdeep.feedback.v1。目录 0700、文件 0600。UserDefaults 的 com.willdeep.feedback.enabled=false 可关闭；目前没有设置界面。

后台串行写入、有界 512 队列、单条上限 4096 字节；失败/丢弃仅计数，不阻塞交互。测试写临时目录。文本不落正文，记录截断 SHA-256、Unicode scalar 长度和有界编辑距离。不会记录工具参数、凭据或错误原文。

覆盖 run_started/run_finished、工具完成/失败、用户追问的保守分类、授权结果，以及建议请求、生成结果、展示、采用、发送后的原样/编辑/重写、忽略、放弃/失效。run/turn/suggestion 标识用于关联；已完成历史工具与预览不进入新 run 分母。

普通追问保持 other；排队输入记录 queued_behind。运行结束明确 unverified，不能等价于独立验证通过。授权同意和建议采用也不能等价于质量改善。

`ruby scripts/feedback_health.rb --home <目录> --out <前缀>` 输出 JSON 和 Markdown。报告区分缺失数据与零，展示运行、工具、建议分母及生成延迟。生产数据只有升级运行后才会新增。

## 限制与验收入口

- 本次没有自动修改提示词或晋升候选；Rust 评估仍须满足任务集完整性、独立基线和验证覆盖率。
- Mac 尚未接入独立 verifier，因此质量验证覆盖率未知。写入丢弃计数尚未持久化，健康报告不能声称丢弃率为零。
- 工具按 call ID 首次终态去重，同 ID 重试不另计；尚无反馈保留期清理或用户设置 UI。
- 建议生成暂未记录独立 request_id，跨轮次晚到结果不能用作按 run 的质量归因；当前健康报告只汇总生成次数和耗时。
- Ruby：scripts/test/feedback_health_test.rb；版本：scripts/version_consistency.rb。
- 原生回归：AgentFeedbackLedgerTests、AgentConfirmationKeyboardTests、AgentInputSuggestionTests、ComposerTextInputTests、AgentGoalTeamsTests；完整测试统一 scripts/run_tests_fast.rb，报告保存 build/fast-tests。
- 安装和发布是单独动作。本文件描述代码范围，不代表已安装运行、收到真实新反馈或完成独立审查。

## Rust 同步交付

对应 Rust 版本最终为 0.91.0-rc2；main/develop 和发布 tag 指向 aaf9239050322dfafed4b6620ec232cd16e9a10f。rc1 保留第一批 RSI 实现，rc2 追加真实 CI 复现的 MCP 已退出进程请求竞态修复。

[公开 Release](https://github.com/niuwoai/willdeep-rs/releases/tag/v0.91.0-rc2) 四个平台产物及主分支完整 CI 均成功。cargo、Homebrew、Runtime 实测版本均为 0.91.0-rc2，Homebrew 二进制包含 x86_64/arm64，公式提交 22b0711。官网 CLI 入口指向 GitHub Releases，无需改版本数据。

Rust 全工作区 1388 个测试通过、7 个既有 ignored；Clippy 全 targets 通过。Web 101 个测试、构建及 lint 通过。取消的是同一提交的重复分支/tag CI，保留的 main CI 完整执行，不以取消代替验证。

## Mac 验证结果

- 首批原生回归 53 个测试 / 5 个套件通过；确认卡片渲染、MCP 和 Goal 长流程专项 37 个测试 / 4 个套件通过。
- 最终完整单测 4939 个测试 / 473 个套件通过，零失败。使用当前源码指纹匹配的构建，关闭 Xcode 并行测试后完整执行，未跳过任何套件；报告位于 build/fast-tests/report.json 和 report.md。
- Goal 长流程实际完成 257 次读取、4 次压缩、4 次自动续跑，267 个模型请求替身全部结算；这验证控制流，不是线上模型质量提升证据。
- 首次完整回归发现确认卡片高度回归，已修复多余间距并通过真实渲染测试；既有工具 schema 上限更新为圆桌加入后的 51815 实测基线，保留 52000 的窄幅上限。并发负载下 MCP/Goal 耗时失败在专项及最终完整串行测试中通过，未降低超时断言。
- Ruby 健康报告 4 个测试 / 21 个断言通过；版本一致性 1.414.0-rc1、源码复杂度检查及 git diff --check 均通过。
- Mac 改动保存在独立分支，未合入共享主分支、未安装或发布；没有宣称已收集新版生产反馈。
