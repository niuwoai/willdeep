# 本地构建与测试提速

## 目标

日常开发、Codex 任务和自托管 Runner 复用同一套持久缓存；测试构建与本地编译互相预热，同时保持正式发布的签名、公证、上传与 appcast 边界。

## 本地快速编译

默认 Debug 增量编译：

```bash
ruby scripts/build_fast.rb
```

常用变体：

```bash
ruby scripts/build_fast.rb --sign
ruby scripts/build_fast.rb --release
ruby scripts/build_fast.rb --index
ruby scripts/build_fast.rb --cache-remarks
ruby scripts/build_fast.rb --release --destination 'generic/platform=macOS'
```

脚本默认执行以下优化：

- DerivedData 固定到 `~/Library/Caches/WillDeep/Xcode/Xedit/DerivedData`；
- SwiftPM checkout 与 package 下载缓存分别保存到 `SourcePackages` 和 `PackageCache`；
- 启用 Xcode compilation cache；
- 跳过依赖更新并只使用 `Package.resolved`；
- CLI 构建默认关闭 index store 和主 App 签名；
- 通过项目构建协调器串行化同仓库重型构建；
- 输出 Markdown、JSON、原始日志和构建协调报告。

`--index` 只影响当前 CLI 构建，不修改 Xcode IDE 的索引配置。缓存位置可通过以下环境变量覆盖：

```text
WILLDEEP_XCODE_CACHE_ROOT
WILLDEEP_XCODE_DERIVED_DATA_PATH
WILLDEEP_XCODE_SOURCE_PACKAGES_DIR
WILLDEEP_XCODE_PACKAGE_CACHE_DIR
WILLDEEP_XCODE_COMPILATION_CACHE
WILLDEEP_XCODE_INDEX_STORE
WILLDEEP_XCODE_DESTINATION
```

报告位于：

```text
build/local/build_report.md
build/local/build_report.json
build/local/xcodebuild.log
build/local/project_build_guard_report.md
```

## 本地测试

定向测试：

```bash
ruby scripts/run_tests_fast.rb -only-testing:XeditTests/YourTestSuite
```

源码指纹未变化时，只执行已有测试产物：

```bash
ruby scripts/run_tests_fast.rb --without-building -only-testing:XeditTests/YourTestSuite
```

完整本地门禁：

```bash
scripts/run_tests.sh
```

三个入口共用相同的 DerivedData、SwiftPM 和 compilation cache。`--without-building` 仅在真实构建输入指纹一致时放行，避免为了快而执行过期二进制。

## CI 与 Runner

CI 将 Ruby quality、interaction、short-drama 守门、Go agent 测试和 macOS Xcode 单测拆成独立 Job。macOS Runner 先执行 `build-for-testing`，再执行 `test-without-building`，并将缓存固定在 checkout 之外，避免每次拉取代码后冷启动。

Runner 应保持：

- 同一 Runner 使用稳定且隔离的缓存根；
- DerivedData、SourcePackages 和 PackageCache 分开；
- 构建阶段启用 compilation cache、关闭 CI index store；
- 测试失败重跑优先复用 `build-for-testing` 产物；
- 多台机器按平台和测试组分工，不共享正在写入的本地缓存目录。

## 正式发布边界

`build_fast.rb` 可以为发布引擎预热 Release 编译，但不能替代正式发布：

1. 使用 `--release --destination 'generic/platform=macOS'`，并让预热与 archive 复用相同 DerivedData、SourcePackages、PackageCache 和 Swift 编译模式；
2. 快速构建保持无签名，只生成可复用编译产物；
3. new83d 发布引擎继续负责 archive、Developer ID 签名、导出、公证、装订、DMG、OSS/GitHub 上传和 some.im appcast；
4. `--clean` 仅用于缓存损坏或编译/链接异常，不作为每次发布的默认动作。

## 当前实测

在当前工作区和机器上：

| 场景 | 耗时 |
| --- | ---: |
| Debug 冷构建 | 683.9 秒 |
| 无变化热构建 | 24.8 秒 |
| 单 Swift 文件变化 | 124.7 秒 |
| 恢复已有源码内容并命中 compilation cache | 24.6 秒 |

单文件新内容仍需要约两分钟，主要瓶颈是超大单体 Swift target 的 `SwiftEmitModule`。继续提速应优先拆稳定模块，而不是盲目增加并行度。
