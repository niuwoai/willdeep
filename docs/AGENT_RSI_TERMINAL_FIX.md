# 原生 Worker 轮次终态修复

当前源码：1.420.0-rc3 / build 920。此修复在独立工作树中，未改变已冻结实验的 App、测试包、两份适配脚本或原始观察记录。

## 行为

`Outcome.terminationReason` 区分 `final_response` 与 `max_rounds`。普通最终答复仍按验证命令结果记录 `failed` 或 `unverified`；轮次耗尽统一记录 `budget_exhausted`，即使验证命令成功也不改成完成。

前后台 Worker 事件、批准实验 Root 终态与观察记录保留实际轮数和终止原因。真实用量、工具读取和部分报告保留；四请求上限、每请求参数、评分与重试权限不变，不追加第五次收尾请求。`did_truncate` 仍只描述转录字段裁剪。

## 已运行的免费检查

```sh
ruby scripts/test_agent_rsi_terminal_reason.rb
ruby scripts/version_consistency.rb
```

第一项直接用 Swift 编译生产 `AgentSubagentTerminationReason.swift`，覆盖两种终态与验证结果缺省、成功、失败共六种组合，输出 `build/rsi-terminal-reason/report.json` 与 `report.md`。它不构建 App、不执行模型请求，不能替代原生 Worker 端到端测试。

所有修改 Swift 文件另经 `swiftc -frontend -parse` 检查。其后在独立 APFS 写时复制缓存完成工程编译及原生回归：`build-for-testing` 退出 0，`test-without-building` 实际 9 项、2 套测试通过。无控制文件的宿主入口检查直接返回，占其中 1 项；其余 8 项包含断言，新增三项真实 Worker/假传输链路均执行通过。未发送真实模型请求。

原生观察原件确认：四轮工具调用返回 `budget_exhausted/max_rounds`、四个回执、最终内容 null、输入/输出 400/80；第四轮最终答复返回 `unverified/final_response`，不是预算耗尽；首请求缺用量返回 `infra_error`，不伪造预算终态。前后台 Worker 的既有验证与版本证据仍通过。

构建前用系统 `clonefile(2)` 逐文件克隆已有缓存，任何克隆失败均不退化普通复制、不使用硬链接；未使用会自动回退复制的 `cp -c`。原检出目录中已有插件运行文件也仅克隆到本工作树，没有 Git 元数据、凭据或网络更新。Go 缓存独立且 `GOPROXY=off`。SwiftPM 标准清单诊断缓存获本次协调授权使用系统默认位置，其余构建输出均独立。原冻结目录在构建、测试后均通过原 manifest 全量核验。

第一次工程构建因新工作树缺少插件运行文件退出 65；第二次因克隆的辅助程序模块缓存嵌入旧路径退出 65。补齐相同插件、仅将本次克隆中失效的辅助模块缓存改名保留后，第三次构建退出 0，用时 265.46 秒；测试执行退出 0，用时 10.06 秒。所有失败诊断保留。监视器每两秒检查磁盘，6 GiB 为停止阈值；成功构建最低余量约 9.24 GiB，测试最低余量约 8.80 GiB，未触发停止。不据此声称提速倍数。

## 后续隔离的原生回归

先确认独立冷编译空间充足，再在本独立工作树执行：

```sh
WILLDEEP_XCODE_CACHE_ROOT=/private/tmp/xedit-rsi-terminal-cache \
WILLDEEP_XCODE_DERIVED_DATA_PATH=/private/tmp/xedit-rsi-terminal-cache/DerivedData \
WILLDEEP_XCODE_SOURCE_PACKAGES_DIR=/private/tmp/xedit-rsi-terminal-cache/SourcePackages \
WILLDEEP_XCODE_PACKAGE_CACHE_DIR=/private/tmp/xedit-rsi-terminal-cache/PackageCache \
GOCACHE=/private/tmp/xedit-rsi-terminal-cache/GoBuildCache \
GOMODCACHE=/private/tmp/xedit-rsi-terminal-cache/GoModuleCache GOPROXY=off \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/xedit-rsi-terminal-cache/SwiftPMModuleCache \
ruby scripts/run_tests_fast.rb \
  -only-testing:XeditTests/AgentRSIApprovedTrialTests \
  -only-testing:XeditTests/AgentRSIWorkerEvidenceTests \
  -parallel-testing-enabled NO -jobs 2
```

不得省略路径覆盖或使用原冻结 DerivedData。本次实际调用由外置 `/private/tmp/mac-terminal-isolated-build.rb` 设置相同隔离路径、模块路径与六 GiB 监视器，依次执行 `build-for-testing` 和 `test-without-building`，可在本机直接复验；正式报告位于 `build/rsi-terminal-app-tests/native-report.json` 与 `native-report.md`。新增原生用例使用注入的 `URLProtocol` 假响应，覆盖四轮连续工具请求后预算耗尽、第四轮得到最终答复仍为正常终态，以及首请求缺用量仍为基础设施失败。它们断言恰四次请求、没有第五次请求、无最终内容时保持 null、用量与两个 finished 事件一致。已有正常双请求与第五次请求门禁用例保留。

`Xedit` 和 `XeditTests` 均为 Xcode 文件系统同步组，新增生产类型自动参与编译，无需手工文件引用。后续集成或交付须在独立工程测试通过后进行，不能替换当前批次冻结产物。
