# RSI 运行参数与反馈验证记录

日期：2026-10-08。

版本：Mac 1.415.0-rc1 / build 892；Rust 0.92.0-rc1。

两端在独立的 codex/rsi-runtime-contract 工作分支实现。Mac 基线为 00698ac0，Rust 基线为 aaf9239。保留原工作树及其他任务的未提交文件；本次未合并、推送、安装或发布。

## 最终验证

| 端 | 验证 | 结果 |
| --- | --- | --- |
| Mac | ruby scripts/run_tests_fast.rb | 完整单元测试通过；Swift Testing 4949 项 / 474 套，Xcode 总计 4955 通过、0 失败、1 跳过 |
| Mac | ruby scripts/version_consistency.rb | 通过，版本 1.415.0-rc1 |
| Rust | cargo test --workspace --offline | 完整工作区测试通过，1394 项通过、7 项忽略；另有子进程测试辅助用例通过 |
| Rust | cargo clippy --workspace --all-targets --offline -- -D warnings | 通过 |
| Rust | cargo fmt --all --check | 通过 |
| Rust | ruby scripts/test/prompt_rsi_test.rb | 22 用例、188 断言通过 |
| Rust | ruby scripts/test/model_eval_test.rb | 28 用例、310 断言通过 |
| Rust | ruby scripts/test/eval_execution_test.rb | 5 用例、46 断言通过 |
| Rust Web | yarn build | 通过 |
| 两端 | git diff --check、共享示例及规范文档 cmp | 通过 |

Rust 完整测试后只有等价的 Clippy 风格修正；对应运行参数集成用例与反馈队列用例再次通过。Mac 最后一轮完整测试包含最终的旧 Goal 限额导出兼容修正。

## 覆盖的行为

- 两端默认规范 JSON 的 SHA-256 一致；字段齐全、显式 null、整数类型和范围、重复或未知字段、损坏文件与缺失文件分别验证。
- 有限 token 预算耗尽或 usage 缺失时，真实主循环拒绝响应提出的写工具，不创建审批卡，也不继续购买自动请求；重复流式累计用量不重复计费。
- Goal 在工具段边界自动交接，保留目标、已完成工具回执和累计消费；跨压缩继续运行；暂停不计时，续跑请求只获得剩余执行时间。
- Mac 的既有更紧 owner 限额继续执行；超出 v1 表示范围的宿主限额不会生成无法重新加载的共享 JSON。
- 建议在键入时隐藏、删空后恢复；Tab 填入但不发送，Esc 放弃；恢复不重复记录展示或误记忽略。
- 模型预判与人工结论分别归档；模型无 accepted / verified 输出能力，模型反馈不能使运行退出人工待审队列，也不能增加 RSI 的人工判断覆盖率。
- RSI 门禁拒绝缺失、被篡改或与实验出处不一致的参数快照和指纹。
- MCP 反向出图测试使用同步信号确认其他应答可在出图未完成时送达，避免固定等待窗口受整套测试负载影响。

## 验证边界

模型请求使用离线 fixture 或 URLProtocol 替身，没有发起付费 provider 请求。未执行真实 provider 的辅助审阅，也未将这次 Mac 构建安装到 /Applications。

输入建议和反馈的交互以原生单元测试验证，本次没有操纵已安装应用做人工 UI 验收。Mac Worker 仍使用工种 profile；根 Agent 的 v1 配置不能单独代表所有 Worker 或 owner ledger 状态。

协议与使用方式见 [RSI 运行参数 v1](RSI_RUNTIME_PARAMETERS_V1.md)。原始 Mac 报告位于工作树 build/fast-tests/report.md、report.json 和 XeditFastTests.xcresult；这些生成文件不提交。
