# Design QA：Goal 续跑与吸附目标条播放/暂停

## Source truth

- 用户参考截图：`artifacts/design-qa/goal-execution-control-rc4/reference-full.png`（1057 × 512）。
- 同状态目标条裁切：`artifacts/design-qa/goal-execution-control-rc4/reference-goal-bar.png`（1057 × 32）。
- 参考状态：Goal 尚未完成但执行已停；吸附目标条显示目标摘要、阶段 2/3 和编辑入口。
- 目标：未完成 Goal 不再因计划状态格式漏报而提前停止；目标条提供类似 Codex 的播放/暂停入口，并真正控制同一个 Goal 的执行。

## Rendered implementation

- 空闲／可继续状态：`artifacts/design-qa/goal-execution-control-rc4/implementation-idle.png`（1057 × 32）。
- 运行／可暂停状态：`artifacts/design-qa/goal-execution-control-rc4/implementation-active.png`（1057 × 32）。
- 同画布对照：`artifacts/design-qa/goal-execution-control-rc4/reference-vs-idle.png`（左侧参考，右侧实现）。
- 原始 2x SwiftUI 渲染一并保存在同目录，避免缩放图替代真实实现证据。

## Functional findings

1. 原停止点来自普通计划的“连续缺少机器可读状态”保护，不是实际 blocker。未完成 Goal 现在完成一次只读状态校准后会恢复完整执行，不再因此直接暂停。
2. 普通计划继续使用 8 轮安全上限；未完成 Goal 使用独立的 24 轮有界续跑预算，既减少误停，也保留防空转边界。
3. 空闲 Goal 显示 `play.fill`。点击后清除旧的非阻塞提示，沿用当前路线图、计划、验收清单与证据继续，不重启 Goal Teams、不重复已完成实现。
4. 运行或等待 Provider 槽位时显示 `pause.fill`。点击后停止当前 Goal 回合；待停止完成后按钮回到播放状态。
5. Goal 全部验收项完成后不再显示播放/暂停按钮，避免对已完成目标产生错误动作暗示。

## Visual findings

1. 播放/暂停使用系统 SF Symbols，与现有目标、阶段和铅笔图标保持同一 macOS 视觉语言。
2. 控件放在阶段信息与编辑按钮之间，右侧操作区顺序稳定；目标摘要仍会优先截断，不挤压阶段或两个操作按钮。
3. 空闲状态继续使用“已吸附目标”，运行状态切换为“进行中的目标”；蓝色描边、浅色底、24 pt 卡片高度与参考保持一致。
4. 同视口对照未发现文字裁切、控件重叠、错误间距或图标模糊等 P0、P1、P2 问题。

## Verification

- `AgentPlanProgressTests`：37/37 通过。
- 覆盖 Goal 状态漏报继续执行、Goal 独立续跑上限、普通计划原有限制、播放/暂停图标、继续提示词及空闲/运行双状态真实渲染。
- String Catalog JSON、版本一致性和 `git diff --check` 通过。
- 当前版本：`1.245.0-rc4`。

final result: passed
