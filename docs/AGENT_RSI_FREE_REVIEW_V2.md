# P4b 免费原生审查输出验证

当前功能版本：1.421.0-rc1 / build 921。此入口仅限 `offline_mock_only`，实际模型调用授权为 0。不改变原 `native-trial-control.v1`、批准实验定义、付费代理入口、正在使用的冻结 App 或客户配置。

## 原生执行与证据

`AgentRSIFreeReview.run` 从固定的共享公共 manifest 选择任务，只把原始 fixture 字节写为随机工作区中的 `fixture.txt`。Worker 的普通只读执行路径实际调用 `read_file`；专用进程内 `URLProtocol` 拦截所有 URL，未知请求本地拒绝，不转发、不回退、不重试。传输身份必须同时满足显式注入的 session 和注册上下文，配置相同 host 的普通 Provider 不能自称 mock。

原注册表 baseline 定义保持原 SHA，专业指令和权限不变；共享 `contract.instructions` 追加在本次任务文本后，不保存为新定义或激活。观察记录分别保存实际加载 revision、原定义指令哈希、共享指令哈希、首请求哈希和进入真实请求的检查结果。`effective_prompt_sha256` 仍是生产 Worker 的系统提示哈希；共享任务指令由首请求另行绑定，不将其冒充为系统提示的全部内容，也不声称两端内部系统提示完全相同。

文件读取证据交叉绑定实际成功的工具事件、精确 `fixture.txt` 参数、真实工具结果哈希与后续有效 mock 请求中收到的结果；fixture 执行前后字节不变。输出给独立宿主的证据精确四字段为 `fixture_sha256`、`read_observed`、`delivered_to_model`、`fixture_unchanged`。不能从模型正文自证这些事实。

## 格式与语义边界

模型输出只能是一个完整 JSON 对象，精确四字段：`has_defect`、`line`、`reason`、`reproduction`；不接受代码围栏、前后说明、多个对象、未知或重复字段。缺陷 witness 只能是 `input`、`expected`、`actual` 数据；clean 的 line 与 reproduction 必须显式 null。

共享原字节契约规定：报文至多 16384 UTF-8 字节，root depth 为 1 且全树深度至多 8，object 每成员/array 每元素各计 1、全树合计至多 128；所有键和值字符串至多 4096 UTF-8 字节。只允许非负规范十进制 safe 整数，拒绝 float、指数、负零与 boolean 冒充数字；仅对象键禁止 `__proto__`、`prototype`、`constructor`，普通 reason 文本中的同名单词允许。

原生结果保持 `unverified`，`host_reproduction_verdict` 为 `pending_shared_host_grader`。原生格式验证与最小 witness 不是独立复现通过。共享宿主评分器会执行冻结的公共 fixture 与 reference，模型只能提供输入及期望/实际值数据，不能提供被执行的代码。reason 只校验非空，不作语义评分。

## 免费复验入口

```sh
ruby scripts/agent_rsi_free_review.rb --offline-mock-only
```

只接受该模式参数，没有模型、服务地址、密钥或付费 capability 参数。默认使用独立 `/private/tmp/xedit-rsi-terminal-cache`，可通过 `WILLDEEP_XCODE_CACHE_ROOT` 指定另一个临时缓存目录；所有派生输出路径随之绑定，禁止落入旧冻结缓存。每两秒监视可用空间，低于 6 GiB 正常中断本次进程组，不删除用户文件。已有结果目录不覆盖，保留先前证据。

原生测试产生 `build/rsi-free-review-v2/{case_id}/`，内含 `raw_model_content.json`、`host_evidence.json`、`first_request.json`、`events.json` 与 `observation.json`；总报告为同目录 `report.json` 和 `report.md`。共享宿主 CLI 的用法为：

```sh
ruby /path/to/willdeep-rs/scripts/lib/agent_rsi_reproduction_eval.rb \
  --task count-zero-bug \
  --report build/rsi-free-review-v2/count-zero-bug/raw_model_content.json \
  --evidence build/rsi-free-review-v2/count-zero-bug/host_evidence.json \
  --output-prefix /private/tmp/new-mac-count-zero-host-report
```

公共套件含 count-zero、copy-boundary、duplicate-first 三家族的 bug/clean 六题，用来检查工程链路。它们已经公开，不是新盲测，不能用其 mock 成绩声称模型提升或版本晋升。独立的新盲测方案与真实模型运行仍由主方案另行批准。

## 本轮验收

独立工程构建成功后，仅 `test-without-building` 执行定向测试：14 项/4 套通过，其中旧 host-control 入口无控制文件直接返回占 1 项，其余 13 项包含断言。新入口实际执行 6 个公共 fixture/12 次 mock 请求；共享原始 JSON 的 12 条正反例与格式、资源、模式、权限、路径门禁通过。Ruby 免费入口保护另有 5 项/25 断言通过。

共享 Node 宿主对本次原生原件验收 6/6，实际执行 fixture/reference 20 次；独立复核又完成 78 项绑定检查。原生观察状态不改成 passed。首次 CLI 限长读取的编码标记问题修正后，用新目录重验，旧失败与原始文件保留。追踪的脱敏 [JSON](verification/2026-10-15-p4b-free-review-v2.json) 和 [Markdown](verification/2026-10-15-p4b-free-review-v2.md) 记录构建退出、磁盘阈值中断、实际测试计数与声明边界。
