# AIPipe macOS SDK 使用指南

本文档专门介绍如何在 macOS 应用中使用 AIPipe SDK。

## macOS 与 iOS 的区别

虽然 AIPipe SDK 同时支持 iOS 和 macOS，但两者在应用架构上有一些重要区别：

### 1. 应用生命周期

**iOS**:
- 使用 `UIApplicationDelegate`
- 生命周期方法：`application:didFinishLaunchingWithOptions:`
- 终止方法：`applicationWillTerminate:`

**macOS**:
- 使用 `NSApplicationDelegate`
- 生命周期方法：`applicationDidFinishLaunching:`
- 终止方法：`applicationWillTerminate:` 或 `applicationShouldTerminate:`

### 2. 默认配置

SDK 会自动检测运行平台：
- **iOS**: `source = "ios"`, `format = "ios"`
- **macOS**: `source = "macos"`, `format = "macos"`

### 3. 框架依赖

两个平台都只依赖 Foundation 框架，不依赖 UIKit 或 AppKit。

## macOS 集成步骤

### 1. 安装 SDK

在 `Podfile` 中添加：

```ruby
platform :osx, '10.13'

target 'YourMacApp' do
  pod 'AIPipe', :path => '../sdk/ios'
end
```

运行：

```bash
pod install
```

### 2. 初始化 SDK

在 `AppDelegate.m` 中：

```objc
#import <Cocoa/Cocoa.h>
#import "AIPipe.h"

@interface AppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    // 初始化 AIPipe SDK
    [AIPipe initializeWithAPIKey:@"your-api-key" 
                        endpoint:@"https://api.example.com/api/v1"];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    // 应用退出时上报剩余日志
    [AIPipe flush];
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    // 在应用终止前上报日志
    [AIPipe flush];
    return NSTerminateNow;
}

@end
```

### 3. 在 main.m 中设置 AppDelegate

```objc
#import <Cocoa/Cocoa.h>
#import "AppDelegate.h"

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSApplication *application = [NSApplication sharedApplication];
        AppDelegate *appDelegate = [[AppDelegate alloc] init];
        [application setDelegate:appDelegate];
        [application run];
    }
    return NSApplicationMain(argc, argv);
}
```

## macOS 特定使用场景

### 1. 命令行工具集成

macOS 命令行工具也可以使用 SDK：

```objc
#import <Foundation/Foundation.h>
#import "AIPipe.h"

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        // 初始化 SDK（不需要 NSApplication）
        [AIPipe initializeWithAPIKey:@"your-api-key" 
                            endpoint:@"https://api.example.com/api/v1"];
        
        // 记录日志
        [AIPipe logWithLevel:@"INFO" content:@"命令行工具启动"];
        
        // 你的代码
        @try {
            // ...
        } @catch (NSException *exception) {
            [AIPipe logException:exception];
        }
        
        // 退出前上报
        [AIPipe flush];
    }
    return 0;
}
```

### 2. 后台服务集成

macOS 后台服务（Launch Agent/Daemon）：

```objc
#import <Foundation/Foundation.h>
#import "AIPipe.h"

@interface MyService : NSObject
@end

@implementation MyService

- (instancetype)init {
    self = [super init];
    if (self) {
        // 初始化 SDK
        [AIPipe initializeWithAPIKey:@"your-api-key" 
                            endpoint:@"https://api.example.com/api/v1"];
    }
    return self;
}

- (void)start {
    // 服务逻辑
    [AIPipe logWithLevel:@"INFO" content:@"服务启动"];
}

@end
```

### 3. 菜单栏应用

macOS 菜单栏应用（Menu Bar App）：

```objc
#import <Cocoa/Cocoa.h>
#import "AIPipe.h"

@interface StatusBarApp : NSObject <NSApplicationDelegate>
@property (nonatomic, strong) NSStatusItem *statusItem;
@end

@implementation StatusBarApp

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    // 初始化 SDK
    [AIPipe initializeWithAPIKey:@"your-api-key" 
                        endpoint:@"https://api.example.com/api/v1"];
    
    // 创建状态栏项
    self.statusItem = [[NSStatusBar systemStatusBar] 
                       statusItemWithLength:NSVariableStatusItemLength];
    
    // 你的应用逻辑
    [AIPipe logWithLevel:@"INFO" content:@"菜单栏应用启动"];
}

@end
```

## Swift 使用示例

```swift
import Cocoa
import AIPipe

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 初始化 SDK
        AIPipe.initialize(withAPIKey: "your-api-key", 
                         endpoint: "https://api.example.com/api/v1")
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // 应用退出时上报
        AIPipe.flush()
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 终止前上报
        AIPipe.flush()
        return .terminateNow
    }
}
```

## 配置说明

### macOS 特定配置

```objc
AIPipeConfig *config = [AIPipeConfig defaultConfig];
config.apiKey = @"your-api-key";
config.endpoint = @"https://api.example.com/api/v1";

// macOS 特定配置
config.source = @"macos-app";            // macOS 应用标识
config.format = @"macos";                // macOS 日志格式
config.topic = @"desktop";               // 日志主题

[AIPipe initializeWithConfig:config];
```

## 数据格式

macOS 应用上报的数据格式：

```json
{
  "logs": [
    {
      "content": "错误信息...",
      "format": "macos",
      "level": "ERROR",
      "timestamp": "2024-01-01T00:00:00.000Z",
      "topic": "desktop"
    }
  ],
  "source": "macos",
  "topic": "desktop"
}
```

## 常见问题

### Q: macOS 应用是否需要 AppKit？

A: 不需要。SDK 只依赖 Foundation 框架，可以在任何 macOS 应用中使用，包括命令行工具和后台服务。

### Q: 如何在 macOS 命令行工具中使用？

A: 直接调用初始化方法即可，不需要 NSApplication。参考上面的命令行工具集成示例。

### Q: macOS 和 iOS 的 API 是否相同？

A: 是的，API 完全相同。SDK 会自动检测平台并使用相应的默认配置。

### Q: 如何区分 macOS 和 iOS 的日志？

A: SDK 会自动设置 `source` 和 `format` 字段：
- macOS: `source = "macos"`, `format = "macos"`
- iOS: `source = "ios"`, `format = "ios"`

你也可以在配置中自定义这些值。

## 最佳实践

1. **在 applicationDidFinishLaunching 中初始化**：确保 SDK 在整个应用生命周期中可用
2. **在 applicationWillTerminate 中上报**：确保应用退出时日志不丢失
3. **使用 applicationShouldTerminate**：在应用终止前上报日志
4. **命令行工具**：在 main 函数开始时初始化，退出前调用 flush

## 许可证

MIT License

