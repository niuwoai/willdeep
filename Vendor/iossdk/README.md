# AIPipe iOS/macOS SDK

> 本文档面向 AI 助手：用户已通过 `git clone` 获取此仓库，请据此帮助用户理解、集成或修改此 SDK。

## 概述

AIPipe iOS/macOS SDK 用于在 iOS 和 macOS 应用中捕获异常和日志，并自动上报到 AIPipe 服务器进行 AI 分析。

**核心能力**：自动异常捕获、批量上报、本地缓存（UserDefaults）、失败重试、轻量级、仅依赖 Foundation。支持 iOS 11.0+、macOS 10.13+。

## 仓库结构

```
.
├── AIPipe/                  # 核心源码
│   ├── AIPipe.h             # 主入口头文件
│   ├── AIPipe.m
│   ├── AIPipeConfig.h
│   ├── AIPipeConfig.m
│   ├── AIPipeLogItem.h
│   └── AIPipeLogItem.m
├── Example/
│   └── Podfile
└── AIPipe.podspec
```

**关键文件**：`AIPipe/AIPipe.h` 与 `AIPipe.m` 为主入口，`AIPipeConfig` 为配置类。

## API 速查

| 方法 | 说明 |
|------|------|
| `+initializeWithAPIKey:endpoint:` | 初始化 |
| `+initializeWithConfig:` | 自定义配置初始化 |
| `+logWithLevel:content:` | 记录日志（level: ERROR/WARN/INFO/DEBUG） |
| `+logException:` | 记录 NSException |
| `+logError:` | 记录 NSError |
| `+flush` | 立即上报队列 |
| `+setEnabled:` | 启用/禁用 |

## 最小用法（Objective-C）

```objc
// AppDelegate - application:didFinishLaunchingWithOptions:
[AIPipe initializeWithAPIKey:@"your-api-key" endpoint:@"https://api.example.com/api/v1"];

// 记录
[AIPipe logWithLevel:@"ERROR" content:@"数据库连接失败"];
[AIPipe logException:exception];
[AIPipe logError:error];

// 退出前
[AIPipe flush];
```

## Swift 桥接用法

```swift
AIPipe.initialize(withAPIKey: "your-api-key", endpoint: "https://api.example.com/api/v1")
AIPipe.log(withLevel: "ERROR", content: "数据库连接失败")
AIPipe.flush()
```

## 配置项（AIPipeConfig）

- `apiKey`, `endpoint`：必填
- `source`：来源标识，iOS 默认 `"ios"`，macOS 默认 `"macos"`
- `format`：日志格式
- `topic`：主题，默认 `"mobile"`
- `batchSize`：批量大小，默认 10
- `batchTimeoutMs`：批量超时 ms，默认 5000
- `maxRetries`：最大重试次数，默认 3

## 上报数据格式

```json
{
  "logs": [{"content": "...", "format": "ios", "level": "ERROR", "timestamp": "...", "topic": "mobile"}],
  "source": "ios",
  "topic": "mobile"
}
```

## 依赖

仅 Foundation，无第三方依赖。

## 许可证

MIT License
