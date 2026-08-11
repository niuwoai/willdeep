# Design QA：设置导航与子 Agent 配置

## Source truth

- 子 Agent 参考截图：`/var/folders/np/rjc0y5w52x324x21pv6g33440000gp/T/codex-clipboard-1e933de5-6d73-4077-b96e-10fa4c160fd5.png`
- 设置导航参考截图：`/var/folders/np/rjc0y5w52x324x21pv6g33440000gp/T/codex-clipboard-d5336aca-e4ba-4101-ac82-e8beb9bcd516.png`
- 目标：子 Agent 成为 AI Agents 下的子标签；设置侧栏按用户指定顺序重排，并将工作区并入编辑器。

## Rendered implementation

- 设置侧栏验收应用：`/private/tmp/xedit-subagents-qa-20260811-1246/Build/Products/Debug/WillDeep.app`
- 子 Agent 直达验收应用：`/private/tmp/xedit-subagents-visual-20260811/Build/Products/Debug/WillDeep.app`（仅将初始设置标签切到子 Agent，正式源码已还原为“更新”）
- 子 Agent 实现截图：`design-qa-evidence/subagent-settings-implementation-1.242.0.png`
- 参考图与实现图同画布对照：`design-qa-evidence/subagent-settings-reference-vs-implementation-1.242.0.png`
- 真实 SwiftUI 设置侧栏已通过 macOS 辅助功能树和应用截图检查。
- 实际顺序：账户与设备、AI Agents、Agent 工具、运行时、集成、终端、语音、桌面宠物、编辑器、更新。
- “工作区”已从一级侧栏移除，并成为“编辑器”的最后一个子标签。
- AI Agents 子标签顺序：AI 服务商、子 Agent、记忆、规则。

## Functional coverage

- 每个子 Agent 可独立选择具体 Provider 实例。
- 每个子 Agent 可手写模型名，也可从选中 Provider 的 `/v1/models` 拉取并选择模型。
- Provider 默认优先使用 some.im；未配置 some.im 时回退到默认启用 Provider，再回退到首个 Provider。
- 兼容同一 Provider 预设存在多个配置实例的场景，通过配置 UUID 精确绑定。
- 旧版仅保存 Provider ID 的配置仍可读取。

## Visual findings

1. 设置侧栏的名称、顺序、图标与合并关系已在真实应用中通过检查，未发现 P0、P1 或 P2 问题。
2. 首轮检查发现 Provider Picker 在视图加载前可能出现空选择警告；已为相关 Picker 设置合法初始值，并对缺失绑定增加默认 Provider 回退。
3. 修复后系统日志未再出现对应 SwiftUI fault。
4. 用户确认首次读取中断源于设置窗口被关闭。重新打开后，AI 服务商页的辅助功能树仍会使 Computer Use 通道中断，因此使用只改变初始选中标签的临时验收构建，直接打开生产子 Agent 视图；该临时初始值已从正式源码还原。
5. 参考图与实现图已放入同一画布检查。实现延续现有设置页的字号、圆角卡片、分隔线和信息密度；新增 Provider 行、自由输入模型、模型菜单和拉取按钮均对齐现有表单网格，未发现文字裁切、控件重叠或错误间距。
6. 验收环境未配置 some.im，四个工种均回退到默认 DeepSeek Provider，符合指定的默认策略。

## Verification

- `AgentSubagentProfileTests` 与 `SettingsInformationArchitectureTests`：21/21 通过。
- Debug 应用编译、签名并可启动。
- 版本一致性、国际化覆盖率、复杂度门禁与 String Catalog JSON 校验通过。
- 当前版本：`1.243.0`（build 342；视觉证据采集于版本位更新前的同代码验收构建）。

final result: passed
