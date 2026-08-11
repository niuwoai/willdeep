# Design QA：用量日历（第 4 版）

## Source truth

- 用户选定的第 4 版视觉稿：`artifacts/design-qa/usage-calendar-1.246.0-rc1/reference.png`（1536 × 1024）。
- 同区域标准化参考图：`artifacts/design-qa/usage-calendar-1.246.0-rc1/reference-calendar.png`（1400 × 1300）。
- 参考状态：2026 年 8 月，周日至周六排列；8 月 11 日为今日；日期格展示 Token、花费和会话数。
- 目标：从“Token 活动”进入月历，可查看真实逐日数据、切换月份，并返回概览；视觉只使用黑、白、灰层级。

## Rendered implementation

- 生产 SwiftUI 实现：`artifacts/design-qa/usage-calendar-1.246.0-rc1/implementation.png`（1400 × 1300，2x，逻辑视口 700 × 650）。
- 同视口对照：`artifacts/design-qa/usage-calendar-1.246.0-rc1/reference-vs-implementation.png`（左侧参考，右侧实现）。
- 渲染数据固定为 2026 年 8 月，今日固定为 8 月 11 日；实现侧使用真实聚合路径生成 24.61M Token、$22.64、42 个会话的测试快照。

## Functional findings

1. “Token 活动”整块区域可点击进入用量日历，保留每日／每周／累计子按钮的原有行为。
2. 月历固定按周日至周六排列，补齐月初、月末的相邻月份日期，覆盖四至六周月份。
3. 每日 Token 优先使用 Provider 上报值，缺失时沿用现有估算逻辑；会话数按当天不同会话去重。
4. 花费沿用模型用量页的定价逻辑；当天存在无法定价的助手用量时显示未知，不用不完整金额冒充准确结果。
5. 左右箭头切换上一个月／下一个月；左上“概览”返回原统计概览，三处均为真实 SwiftUI 控件并带无障碍标识。

## Visual findings

1. 月份、汇总、星期标题和日期格层级与第 4 版一致；月份切换采用细边框按钮，日期内容居中。
2. 今日使用近黑底和白字，其余内容只使用主文字、次文字、细边框和透明灰底，不引入强调色。
3. 日期格高度、圆角、列间距和六周网格密度已按同画布对照调整；相邻月份只显示弱化日期。
4. 中性系统皮肤同视口对照未发现文字裁切、控件重叠、错误周序或难以辨认的 P0、P1、P2 问题。

## Verification

- 用量日历定向测试：3/3 通过。
- 覆盖逐日 Token／花费／会话聚合、2026 年 8 月周日开头的 42 格网格，以及生产 SwiftUI 页面渲染。
- String Catalog 同时提供英文和简体中文资源；版本已同步为 `1.246.0-rc1`。
- 版本一致性、Go Agent 测试、String Catalog JSON 和 `git diff --check` 作为最终交付检查执行。

final result: passed
