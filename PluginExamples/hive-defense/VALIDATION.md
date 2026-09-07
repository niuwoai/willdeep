# 蜂巢防线验收

## 1.336.0-rc1：维修与蜂蜜反馈

- 15 项 Node 回归通过：逐点维修、扣费、受击半速、停止/缺蜜保留进度、满血结束、游戏暂停和重开、所有虫类击杀飘字、连续收支计数与减少动态效果。
- 9 项 Chromium 动效回归通过，使用可控时钟检查维修在 3 秒前不恢复、满 3 秒仅恢复一点；检查真实余额立即变化但显示数字逐步变化，以及连续奖励后买塔、缺蜜恢复维修、CSP 和减少动态效果。
- 完整页面烟测通过，13 张素材加载成功、建塔升级及战斗正常；`hive.html` 已同步并备份上一版页面与资源。
- 版本一致性检查通过，版本为 1.336.0-rc1，构建号 655。新增维修蜂图片由内置 imagegen 生成并编辑，保留透明通道。
- 本轮验证针对游戏与插件资源，没有重新编译或安装整个 macOS App；下方 48 项宿主回归是 1.335.0-rc1 的历史结果。

## 1.335.0-rc1：首次集成

日期：2026-09-07；版本：1.335.0-rc1（宿主构建 654）。

- 12 张独立 PNG 均为 1254×1254 RGBA；ImageMagick 检查 alpha 最小值 0、最大值 1，确认真正透明。
- `node --test PluginExamples/hive-defense/tests/game.test.cjs`：4 项全部通过，覆盖建塔扣费/占位、全部塔和敌人及蜂巢绘制、蜘蛛分裂与重复击杀奖励、暂停/加速/波次推进。
- 无头 Chrome 实测插件页面及更新后的 `~/Sites/pylearn/hive.html`：12 张图片全部加载，建塔、升级、暂停/继续、加速、第一波战斗正常，无 JavaScript 运行错误；浅色/深色截图位于 `build/ci/hive-defense`。
- `ruby scripts/run_tests_fast.rb -only-testing:XeditTests/AgentPluginSystemTests`：48 项全部通过，进程退出 0，报告与日志一致；包含新增插件的生产加载器校验及内置资源打包检查。初次沙箱执行因缓存权限失败，最终在获准环境重跑通过。
- 构建产物 `WillDeep.app/Contents/Resources/BundledPlugins/hive-defense` 的 20 个运行时文件与源码 SHA-256 一致。最后的样式调整已同步到本次 Debug 产物。
- `ruby scripts/version_consistency.rb`：通过；App、Go agent、帮助、Helper、浏览器扩展和文档版本一致。
- `ruby PluginExamples/hive-defense/package.rb`：生成 ZIP 与 SHA-256 文件；ZIP 完整性检查通过，不包含 macOS 资源叉、测试依赖或网络资源。

原始 HTML 修改前备份：`~/Sites/pylearn/hive.before-willdeep-20260907.html`。更新后的 HTML 使用同目录 `hive-defense-resources` 中的本地资源。

本次没有替换 `/Applications` 中已安装的 WillDeep，也没有执行签名发布、推送或 Git 主分支集成。宿主验证范围为插件系统定向回归，不代表全 App 全套回归。
