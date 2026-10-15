# 受批准的原生审查实验入口

版本：1.420.0-rc2 / build 919。此入口补齐原 P4b 已批准的独立审查实验，不实现动态定义/自动晋升。普通 `AgentRSIContract.offline` 和服务端 mock-only 门禁保持不变。

只有外部宿主预算 broker 的活动 trial capability 才能授权实际请求；在 JSON 中写 approved 不能获得权限。仅支持 `http://127.0.0.1:<port>/v1/chat/completions`，禁止代理、重定向、内部重试、Provider 回退、升级和摘要辅助调用。模型固定 deepseek-v4-flash；stream=false、temperature=0、max_tokens=4000，最多四次请求、120 秒。统一可信 broker 按本 trial 剩余 16000 token 和全批 $5 预算准入、降低输出上限、记账；本机 ledger 保留真实 usage，不使用 bytes 估算再误拒。未知用量、路由变化、回执缺失均停止，不能补成零成本。

控制文件必须为 0600，字段与 Rust 共用：

```json
{
  "schema": "willdeep.agent-rsi.native-trial-control.v1",
  "proposal_sha256": "a3ae36e96d268f8aaab8a02efacea61cb68f58c1d3bf812b9a38311890736606",
  "experiment_id": "host-assigned-experiment",
  "trial_id": "host-assigned-trial",
  "arm": "baseline",
  "repetition": 1,
  "attempt": 1,
  "resume_of": null,
  "agent_package": "/private/tmp/host/baseline.json",
  "agent_revision": "51b79a923ceceeae80a7cc6e20f2f0dbdfdb136f1bc516b895450ea633273bdd",
  "suite": "/private/tmp/willdeep-agent-registry/bench/agent-rsi/reviewer-original-24-v1/suite.json",
  "suite_sha256": "281f7dadf99f4cf86c4de5a922cdac7531c933654f878bb6b8f532d502a96575",
  "task_id": "loop-bound-bug",
  "broker_origin": "http://127.0.0.1:1",
  "capability": "HOST_SUPPLIES_EPHEMERAL_CAPABILITY",
  "output_directory": "/private/tmp/host/new-trial-directory"
}
```

`ruby scripts/agent_rsi_approved_trial.rb --control /absolute/control.json` 默认让真实 Worker 组装首请求后在本地停止，不联网；预览写到忽略的 `build/rsi-approved-review-preview.json` 及该次输出目录的 `first_request.json`，不含凭据。外部可信宿主明确选择 `--execute` 才运行该 trial，不在命令行传递 capability。输出目录必须是新目录，原件不覆盖，预览和实际执行使用不同目录。控制中的 task_id 只作宿主关联，只有原 suite.prompt 和 fixture.txt 进入独立系统临时随机工作区；路径不继承宿主输出目录中的题目名称，不向模型提供题目标签、oracle 或 expected_output。结束后删除随机工作区，保留宿主事件及观察原件。

免费编译测试通过后，运行 `ruby scripts/agent_rsi_approved_trial.rb --freeze-runner /private/tmp/native-runner.json` 冻结整个 App（包含实际 debug dylib、嵌入测试包和资源）及适配 Ruby 脚本的哈希。之后每次加 `--frozen-runner /private/tmp/native-runner.json` 只调用 `xcodebuild test-without-building`，不再编译；执行前后均验证冻结文件，发现变更或编译动作即拒绝。真实批次由外部可信宿主使用 `--control ... --execute --frozen-runner ...` 串行启动，不能在批次中重编译或替换缓存中的 App。冻结、默认预览本身均不调用模型。

`observation.json` 使用 `willdeep.agent-rsi.native-trial-observation.v1`，保留 raw_model_content、完整 worker_report、实际 loaded_revision、prompt/fixture/task/event 哈希、逐请求真实 usage/request ID/模型路由/broker 回执、只读完整性验证以及中断/基础设施状态。X-RSI-Approved-Model 必须匹配逻辑模型；实际 X-Routed-Model 可以是 opaque 上游标识，与响应 body.model 分别保留原值，由可信 broker 核对固定路线，不能把两者改写成逻辑名。provider 原始正文取自最后没有工具调用的轮次，不用宿主包装后的报告冒充 JSON。质量评分由 root 的同一 Ruby host grader 完成，分别报告 schema/classification/localization/read，四项全满足才 passed；不评价 reason 的语义，不调用 LLM judge。

免费回归只注入拒绝全部网络的 URLProtocol fixture，实际经过原生 Worker、read_file 和此非流式适配；不向预算 broker 或真实模型发送请求。SwiftUI、发布包、生产实验/用户账号和现有选择均不操作。

2026-10-15 免费门禁结果：原生五套回归 57/57 通过，冻结脚本安全回归 5/5 通过。精确单入口 `hostControlledNativeEntry()` 已实际运行一项测试并生成新观察原件，禁止将 0-test 的 Xcode 成功标记当验收。冻结产物的真实首请求预览为 5497 UTF-8 字节，参数 stream=false/temperature=0/max_tokens=4000，未泄露 task ID、oracle 或 capability，HTTP/模型请求为 0。随后统一宿主通过真实 localhost 假 broker 分别验证 Rust 与 Mac：每端两轮模拟响应、真实 read_file、loaded revision、任务及 lineage 哈希、原生/代理回执集合和独立 grader 均通过。该联合验收仍为 **0 次真实模型调用**；实际费率的补充确认和正式 grant 是独立门禁，不能由免费回归替代。
