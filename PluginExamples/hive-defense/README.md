# 蜂巢防线

WillDeep 内置本地塔防插件，版本 1.336.0-rc1。原始玩法来自 `~/Sites/pylearn/hive.html`，修改前文件备份为 `hive.before-willdeep-20260907.html`；整合版本位于 `ui/index.html`，可直接在浏览器打开，或由 WillDeep 插件中心加载此目录。构建 App 时，Xcode 自动复制至 `BundledPlugins/hive-defense`。

5 种防御塔、6 种虫群、蜂巢基地和维修蜂共 13 张独立透明 PNG，均位于 `ui/assets`。图片使用内置 imagegen 生成并保留原生 alpha；前 12 张为 1254×1254，维修蜂为 1536×1024。没有外链资源和运行权限。蜘蛛分裂后的幼体复用蜘蛛图并按原规则缩小。

维修：派出维修蜂，每 3 个游戏秒修复 1 点生命，每点花费 4 蜂蜜。受击后 3 秒内以半速维修，进度保留；缺蜜时等待、满血时自动结束。维修随游戏暂停和倍速运行；波间有 13 秒休整，可提前叫波换取蜂蜜。

蜂蜜反馈：击杀飘出「+N 蜂蜜」，顶部余额在 0.65 秒内平滑追上真实余额，配合收支数字和轻微弹跳。连续变化从当前显示值衔接；购买判断和扣款始终使用即时真实余额。系统要求减少动态效果时直接显示准确数字。

玩法：点击「开始防守」，选塔后点击非道路格建造，点击已有塔升级或出售。数字键 1–5 选塔，空格暂停，F 加速，N 提前下一波，Esc 取消选择。

生成提示词记录见 `ART_PROMPTS.md`。游戏保持原版中文界面，插件导航包含英文和简体中文资源。

验证：`node --test PluginExamples/hive-defense/tests/*.test.cjs`；浏览器动效与维修回归：`node PluginExamples/hive-defense/tests/feedback.browser.cjs`。测试复用游戏厅的 jsdom/Playwright 依赖。宿主插件验证使用 `ruby scripts/run_tests_fast.rb -only-testing:XeditTests/AgentPluginSystemTests`。
