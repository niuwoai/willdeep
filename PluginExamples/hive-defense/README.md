# 蜂巢防线

WillDeep 内置本地塔防插件，版本 1.335.0-rc1。原始玩法来自 `~/Sites/pylearn/hive.html`，修改前文件备份为 `hive.before-willdeep-20260907.html`；整合版本位于 `ui/index.html`，可直接在浏览器打开，或由 WillDeep 插件中心加载此目录。构建 App 时，Xcode 自动复制至 `BundledPlugins/hive-defense`。

5 种防御塔、6 种虫群和蜂巢基地共 12 张独立透明 PNG，均位于 `ui/assets`。图片使用内置 imagegen 生成，保留原生 alpha 和 1254×1254 分辨率；没有外链资源和运行权限。蜘蛛分裂后的幼体复用蜘蛛图并按原规则缩小。

玩法：点击「开始防守」，选塔后点击非道路格建造，点击已有塔升级或出售。数字键 1–5 选塔，空格暂停，F 加速，N 提前下一波，Esc 取消选择。

生成提示词记录见 `ART_PROMPTS.md`。游戏保持原版中文界面，插件导航包含英文和简体中文资源。

验证：`node --test PluginExamples/hive-defense/tests/game.test.cjs`；宿主插件验证使用 `ruby scripts/run_tests_fast.rb -only-testing:XeditTests/AgentPluginSystemTests`。
