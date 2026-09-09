# 内置发行验证

- 宿主版本：1.357.0-rc1（706）；游戏版本：0.1.0。
- 验证日期：2026-09-09。
- `ruby scripts/workshop_bundle_test.rb`：通过。执行真实 Xcode 内置插件打包阶段，核对全部 13 个运行文件及 SHA-256，排除开发源码、依赖与服务端产物。
- `ruby scripts/run_tests_fast.rb -only-testing:XeditTests/WorkshopRunBundledPluginTests`：合入前的 1.343.0-rc1 基线有 3 项通过、0 失败，结果来自 xcresult。最新 main 基线的 1.357.0-rc1 原生复验仍在运行，按用户要求由独立测试会话接手，不能将旧结果视为本版本已通过。
- 最新 main 基线已重跑游戏 18 项测试和真实打包阶段校验，全部通过。
- 游戏运行代码未改变，原有游戏逻辑与浏览器验收见 `ui/design-qa.md`。

这次验证为 macOS Debug App 构建及宿主加载测试，不代表已合并发行分支、签名发布、安装到 `/Applications` 或完成实际 WKWebView 人工试玩。Rust Web 与 Android 内置分发不在本次范围。
