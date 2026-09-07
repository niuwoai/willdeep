# 蜂巢防线验收

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
