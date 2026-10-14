# Mac 智能体版本库 v1

当前版本：1.419.0-rc1（build 916）。本次范围为 P0—P3，RSI 自动候选生成与评测晋升属于下一阶段。

## 用户入口

设置 → AI → Agent profiles →「智能体版本库与同步」。

- 创建：填写名称、用途、基础职责、工具请求、专业指令及语义版本；保存形成不可变 revision。
- 高级编辑：交换 JSON 中可内嵌锁定的技能正文及 UTF-8 SHA-256。必需技能为空或校验错误时拒绝保存；可选空技能显示降级。
- 导入 / 导出：使用与 Rust、some.im 相同的完整 v1 包。导入本地包只能使用 `user/` ID 且无官方签名。
- 官方目录：固定 hash 下载、校验可信服务公钥的 Ed25519 签名后安装。修改官方指令必须派生 `user/` 副本。
- 固定版本 / 回滚：切换选择后默认固定，旧正文保留；不会改变已经运行的实例快照。固定版本遇远端更新或删除会保留本机选择并显示冲突；取消固定可在下次同步跟随远端。更新定义不会自动重新启用已停用的安装。
- 本机模型：继承当前会话或绑定本机 Provider 条目，并可指定模型 ID。首次加入私有同步保留本机绑定；已有账号安装保留其自己的绑定。这些绑定不会上传。
- 私有同步：登录 some.im 客户账号后，将本地定义加入私有同步，再主动同步；不会上传会话、记忆、文件路径或 Provider Key。
- 冲突：本地与远端都保留，可选保留本地后再同步，或采纳远端。删除为 tombstone，保留历史包。

## 身份与执行

`definition_id` 与 `base_role` 分开。交换定义只投影到受控的五种原生职责，工具为代码职责允许集合与定义请求的交集；额外的写入或命令请求不授予权限，设置显示实际工具。有效工具集合为空的定义可保存交换但本期 Worker 不可运行。实现者仍需既有精确文件集授权；签名不提供额外权限。Goal Teams 角色只能继续缩小写工具与命令权限。

目前交换 v1 原生 Worker 只支持文本任务简报。首次用户图片模态或零有效工具定义可保存，但默认停用且明确显示不可运行；启用时重新校验。官方候选在写包、切换选择前检查签名、信任键和宿主兼容性，失败保留旧安装。不静默删除模态、不替换为默认工种。外部 CLI 保留其自身执行机制，不宣称应用原生指令与技能。

运行使用固定包中的指令及完整技能正文，不查找同名本地技能替换。输入超过模型上下文预算时沿用 Worker 预算拒绝，不裁掉这些指令。运行快照和持久化 transcript 记录定义 ID、revision、基础职责及锁定技能。

## 存储和账号切换

库位于 `Application Support/WillDeep/AgentRegistry/v1`，正文按 hash 保存，安装选择独立存储。目录 0700，文件及原子写临时文件 0600；写操作使用递归锁及跨进程 flock。

私有命名空间由可信服务的身份接口提供 user / tenant，并包含 service origin。已经确认的 session 仅保存 SHA-256 fingerprint，令牌正文仍属于现有 Keychain 会话系统。同已验证 session 可重启后离线启用缓存；退出、换 session 或换服务后立即隐藏私有定义，需重新从身份接口确认。旧 v2 profiles / overrides 保留，交换定义独立存储。

## 验证入口

```sh
swiftc -module-cache-path /private/tmp/xedit-agent-swift-cache \
  Xedit/AgentDefinitionPackage.swift scripts/agent_contract_golden.swift \
  -o /private/tmp/xedit-agent-golden
/private/tmp/xedit-agent-golden XeditTests/Fixtures/agent-contract-golden.json

ruby scripts/run_tests_fast.rb \
  -only-testing:XeditTests/AgentDefinitionRegistryTests \
  -only-testing:XeditTests/AgentProfileUnificationTests \
  -only-testing:XeditTests/AgentGoalTeamRoleTests
```

本次定向原生回归 38 项、3 个 suite 通过，报告位于 `build/fast-tests/report.md`。测试覆盖不可变包、篡改与签名、固定 / 回滚、技能正文、职责权限、条件同步、账号失效、冲突及 tombstone；实际 Native Worker 的请求捕获验证审查员与实现者两种职责的固定指令和完整技能。渲染产物位于 `build/agent-registry-visuals`。跨端真实 HTTP 验收由主任务统一执行；这些测试不代替全仓测试、生产发布或线上迁移证据。
