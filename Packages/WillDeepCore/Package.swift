// swift-tools-version: 6.0
//
//  WillDeepCore
//
//  不依赖 AppState / SwiftUI / AppKit 的纯逻辑。设计与实测口径见
//  docs/BUILD_MODULARIZATION_DESIGN.md。
//
//  存在的理由是编译与测试的成本：App 是单 target 678 个源文件，改一个被广泛
//  引用的类型就级联全表，而跑几条纯函数单测要先建整个 App，实测十几分钟。
//  这个包里的逻辑用 `swift test` 跑，秒级。
//
//  `swiftLanguageMode(.v5)` 是刻意的：主工程用的是 Swift 5 语言模式加
//  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，包里如果切到 v6 严格并发，
//  同一份源码在两处的编译结论会不一样，那这个包就不再是「主工程代码的一部分
//  换个地方编」，而是另一套语义。
//
import PackageDescription

let package = Package(
    name: "WillDeepCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "WillDeepCore", targets: ["WillDeepCore"])
    ],
    targets: [
        .target(
            name: "WillDeepCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "WillDeepCoreTests",
            dependencies: ["WillDeepCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
