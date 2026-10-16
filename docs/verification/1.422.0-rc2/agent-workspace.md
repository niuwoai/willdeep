# 智能体工作区免费验证

版本 1.422.0-rc2 / 构建 924；基线 `9b90a4689e5fee57ba223ce4f414cfae47bf8779`。本轮保存在隔离分支，未合并、推送、安装或发布。

## 原生回归

47/47 实际通过，0 失败、0 跳过，退出码 0。包含 12 项工作区新增测试与 35 项版本库、冲突及 RSI 相关测试。执行耗时 297.63 秒，最低空闲 7,327,182,848 字节。

操作门禁的关键回归验证：旧账号排队操作不会开始；悬停的成功或失败在 A → B → A 后不能覆盖新账号提示或清除新操作忙碌状态；当前账号的成功与失败会实际完成，避免全部丢弃造成假绿。其它新增覆盖本机备注隔离、候选与原定义哈希不变、官方先派生、搜索、来源筛选、未保存切换、历史基线回选和真实证据时间。

RSI 原生测试确实经过 Worker 与本机 mock：完整配对 6 条证据、中途中止 5 条证据；没有真实模型请求。本轮没有 HTTP fixture 配置，不将这些结果说成生产 some.im 跨端联验。

机器报告：`build/agent-workspace-verification/passed-47-fast-tests/report.json` 与 `passed-47.json`。先前 43/44 项通过记录和环境/编译修复诊断均保留，没有覆盖旧失败。

## 专用预览

专用 `AgentWorkspacePreviewApp` 编译退出码 0，实际 bundle identifier 为 `com.willdeep.workspace-preview`，入口符号已核实。预览完全绕开产品 AppDelegate/AppState、会话恢复、定时任务、插件任务与模型探测，注入独立库、RSI 目录与 UserDefaults。它未覆盖 `/Applications/WillDeep.app`。

为限制临时磁盘，仅此预览关闭 DWARF，仍使用 Debug 和原优化/断言。缓存迁移的两次 PCM 绝对路径拒绝分别保留诊断；只更新新预览自己的 SwiftPM/helper 模块缓存后完成首次构建。关闭保护与布局更新、随后关闭确认时序的两次同一 warm 增量构建分别为 172.18 秒与 47.39 秒；最终一次最低空闲 6,819,127,296 字节。没有同场景基准，不宣称提速倍数。

Debug 实际应用代码位于 `WillDeep.debug.dylib`，最终时序修复 SHA 为 `905b5c95f1bdd46f74ea09fe033a96ad303c7e94ecb50072532265b03e080745`；可执行 stub 的 SHA 保持相同，不能仅凭 stub 判定源码是否已更新。

实际视觉与保存/免费验证已通过，关闭保护另按下述实际行为通过；编译与测试没有替代视觉验收。实际品牌图标与 SF Symbols 沿用产品，未使用生成稿虚构的 W 标识。

## 真实预览发现与补验

第一次预览经实际输入、切页脏修改确认、取消后文字仍在，再关闭并以同一 fixture 重开，确认未保存文字丢失。按此证据新增工作区专用 close guard，保留转发原窗口委托；没有修改全局 AppDelegate。第二轮证实取消保文字通过，但同步放弃只收起确认框、没有关闭工作区，因此该轮关闭结论撤回并保留失败。再补独立确认令牌、sheet 收起后有界关闭、仅 windowWillClose 清脏标记，未关则撤销批准保持原保护。直接编译生产 `AgentWorkspaceCloseIntent` 的 18 条免费断言通过，涵盖 Binding 先消失再按钮、取消、旧令牌、账号切换、未闭恢复保护。可重复命令为 `ruby scripts/test_agent_workspace_close_guard.rb`，JSON/中文报告位于 `build/agent-workspace-close-guard`。这不是 AppKit 窗口交互替身。原 47 项测试保留，不冒称新 close guard 已重新执行全工程测试。

最终代码在原生预览 PID 44054 实测：输入唯一文字、关闭弹确认、继续编辑后 AX 精确保留同串；再次明确放弃后，独立全表面 inventory 从存在 `com.willdeep.workspace-preview` 变为空，期间没有调用会自动重开的 getApp。原 PID 已退出且未发现其崩溃报告；关闭判定以 inventory 为主，不能只凭点击成功或进程退出。证据位于 `/private/tmp/willdeep-agent-workspace-visual-20261016/mac-close-inventory.json`。关闭 P2 已通过，随后仅同 fixture 一次重启做其它验收。

首屏布局同步收紧：说明折叠、双卡上移、基线浅灰只读面、候选版本在卡头、205 点编辑框、标题「RSI 实验」、有修改时进入第二步骤。保存候选仍为原生蓝色 prominent 主按钮；截图须在工作区成为 key window 后判断系统颜色。

Root 已查看同屏 `mac-comparison-second.jpg`、库界面 `mac-library-final.png` 与实际免费结果 `mac-free-validation.png`，首屏、灰色基线/蓝色候选、步骤与标题通过；证据位于 `/private/tmp/willdeep-agent-workspace-visual-20261016/`，根 `design-qa.md` 保留失败历史及最终通过记录。

实际 GUI 保存「文档整理 · 引用检查」候选 `1.0.0-rc2` 并触发免费验证，生成 `exp-a8976586-93a1-4dfe-a1f4-a93fbe3d9f86`。只读检查真实 fixture 报告的 10 项绑定均通过：两臂各 3 条，全部 target executed、verifier 退出码 0 / passed、trust 为 local_mock，模型及所有路由均为 mock，合计费用为 0。事件确有 6 次工具完成、6 次 fixture 工具结果观察、12 次 mock 请求开始/结束，不是预填的展示结果。

原安装库仍只有基线一条 revision，selected SHA 为 `6ddd241408f13651d44b072e9d195605b8f07701af19688f0707fe23e62d6bfd`；候选 SHA 为 `968ef38bb8e8957f92d745f0a41353f562cf01f8541b4af952eec8ab4f304280`，仅保存在候选 store，没有替换基线。运行报告 SHA 为 `2d305d8288383665d95121763ca10d73c13c2a2cd5079a5e4bffac9eb0df1e84`。界面明确显示「离线执行证据完整 6/6」及不代表模型质量结论，近期记录来自这次真实 mock 执行；不将其报告为真实模型质量提升。

## 资源与保护

只对本轮自有 Go/SDK 缓存中 1,506 个逐文件 SHA 相同的普通文件做 clonefile 原子替换，无普通复制回退、无硬链接，参考目录只读。两组全文件内容哈希保持，观察到空闲增加 847,687,680 字节；系统并行写入也会影响瞬时空间，不能把所有后续变化归因于此操作。

47 项测试完成后，经明确授权，仅删除本轮测试 DD 及预览 clone 内无持有的测试对象，保留主 App 对象、Products、测试宿主、xcresult、日志、依赖与源码；可见回收 396,472,320 字节。清单与前后保护哈希保存在本轮 build 目录。

后续增量构建曾因 6 GiB 预留线正常中止，无遗留工程构建进程；只在追加精确授权后回收已完成 47 项的 testedDD 生成 App 对象（保产品与结果，可见回收 577,703,936 字节），以及已完成正式 Release 的非冻结 DerivedData（保完整 archive/export/dmg-src/最终 DMG，可见回收 684,601,344 字节）。独立正式产品签名与版本验证通过，六组保护目录前后全文件哈希及正式 DMG 哈希保持；未降低预留线或清理用户缓存。

旧付费冻结 Native/测试二进制、已安装 App、正式 DMG 的哈希保持。未修改任何付费账本、数据或原冻结源码；没有付费调用、生产上传或自动晋升。
