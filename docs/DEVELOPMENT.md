# WillDeep 开发指南

面向从源码构建、测试和贡献代码的开发者。产品介绍与下载入口见 [README](../README.md)。

## 从源码构建

```bash
git clone https://github.com/niuwoai/willdeep.git
cd willdeep
open Xedit.xcodeproj
# ⌘R
```

需要 Xcode。产物名为 **WillDeep.app**。

日常命令行编译走共享热缓存入口：

```bash
ruby scripts/build_fast.rb             # Debug 增量编译，默认不生成索引、不签名
ruby scripts/build_fast.rb --release   # Release 编译
ruby scripts/build_fast.rb --sign      # 需要走签名链路时
```

缓存默认在 `~/Library/Caches/WillDeep/Xcode/Xedit`，DerivedData、SwiftPM checkout 与 Xcode compilation cache 跨终端复用；构建报告写到 `build/local/build_report.md`。完整的缓存布局、测试入口与 CI 边界见 [本地构建与测试提速](BUILD_TEST_ACCELERATION.md)。

跑测试优先用快速入口，避免多个 Agent 或 worktree 同时冷构建：

```bash
ruby scripts/run_tests_fast.rb -only-testing:XeditTests/YourTestSuite
scripts/run_tests.sh                   # 完整本地门禁
```

要把当前 worktree 的 Debug 版直接装进 `/Applications`，先在不会提交的 `.env.local` 里配好登录密钥：

```dotenv
WILLDEEP_CLIENT_LOGIN_SECRET=你的本地开发密钥
```

然后：

```bash
ruby dev_install.rb --dry-run
ruby dev_install.rb
```

脚本不打印密钥，会完成干净构建、签名、原子安装，以及版本、签名和密钥注入校验。已经在跑的 WillDeep 不会自动重载，请彻底退出后重开。


## 贡献代码

先阅读仓库 [CLAUDE.md](../CLAUDE.md) 中的分支和测试规则。请围绕一个清晰的问题提交改动，说明使用场景、实现方式和验证结果。

- 代码改动按仓库规则同步版本号和 [CHANGELOG](../CHANGELOG.md)。
- 界面文案使用本地化资源，保持各语言体验一致。
- 涉及启动、输入和长会话的改动应检查性能影响。
- 不提交 API Key、登录密钥、环境配置或真实用户数据。
- 测试失败或没有完成验证时，明确标注，不将其描述为可发布结果。

## 源码入口

- [AgentModeView.swift](../Xedit/AgentModeView.swift)：Agent 主界面。
- [AppStateAgentLoop.swift](../Xedit/AppStateAgentLoop.swift)：回合循环、工具决策与上下文压缩。
- [AgentToolRegistry.swift](../Xedit/AgentToolRegistry.swift)：工具目录。
- [AgentContextBuilder.swift](../Xedit/AgentContextBuilder.swift)：上下文组装。

完整能力状态及未决问题见 [Product Overview](../product-overview.md)。公开发布范围以对应发行版本为准，开发分支和测试报告不代表已发布能力。
