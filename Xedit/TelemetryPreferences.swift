//
//  TelemetryPreferences.swift
//  WillDeep
//
//  遥测的开关与匿名安装标识。
//
//  安装标识是本地随机生成的 UUID，用户可以随时重置——它不是硬件序列号，
//  也不从任何设备指纹推导。重置等于换一个新安装：旧 ID 的数据由服务端的
//  删除入口清掉（见 TelemetryReporter.forgetCollectedData）。
//

import Foundation

/// 遥测偏好的持久化。默认写 `UserDefaults.standard`，测试注入独立 suite。
///
/// `@unchecked Sendable`：`UserDefaults` 自身线程安全，只是没被标注；这里
/// 除了一个 `UserDefaults` 引用没有别的状态。
struct TelemetryPreferences: @unchecked Sendable {
    /// 采集开关。默认开启，用户可在设置里关掉。
    static let enabledKey = "telemetry.enabled"
    /// 匿名安装 ID。
    static let installIDKey = "telemetry.install-id"
    /// 用户是否已经看过采集说明（首次启动时在设置里高亮一次）。
    static let noticeAcknowledgedKey = "telemetry.notice-acknowledged"
    /// 性能报告开关（CPU 持续高负载时自动上报调用栈，见 PerformanceWatchdog）。
    /// 与产品遥测开关相互独立，默认开启。
    static let performanceReportsEnabledKey = "telemetry.perf-reports.enabled"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 是否采集。默认 true——没有显式写过就当开启。
    var isEnabled: Bool {
        get {
            guard defaults.object(forKey: Self.enabledKey) != nil else { return true }
            return defaults.bool(forKey: Self.enabledKey)
        }
        nonmutating set {
            defaults.set(newValue, forKey: Self.enabledKey)
        }
    }

    /// 是否上报性能报告。默认 true——没有显式写过就当开启。
    var isPerformanceReportingEnabled: Bool {
        get {
            guard defaults.object(forKey: Self.performanceReportsEnabledKey) != nil else { return true }
            return defaults.bool(forKey: Self.performanceReportsEnabledKey)
        }
        nonmutating set {
            defaults.set(newValue, forKey: Self.performanceReportsEnabledKey)
        }
    }

    var hasAcknowledgedNotice: Bool {
        get { defaults.bool(forKey: Self.noticeAcknowledgedKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.noticeAcknowledgedKey) }
    }

    /// 当前安装 ID；没有就生成一个并落盘。
    ///
    /// 关闭遥测时刻意**不**删除它：用户重新打开开关后应该还是同一个安装，
    /// 否则每关一次开关就凭空多出一个「新用户」，装机数会虚高。要换 ID
    /// 得走 `resetInstallID()`。
    func installID() -> String {
        if let stored = defaults.string(forKey: Self.installIDKey),
           TelemetryPreferences.isValidInstallID(stored) {
            return stored
        }
        let fresh = UUID().uuidString.lowercased()
        defaults.set(fresh, forKey: Self.installIDKey)
        return fresh
    }

    /// 换一个新的安装 ID，返回旧 ID（如果有）——调用方拿它去请求服务端删除。
    @discardableResult
    func resetInstallID() -> String? {
        let previous = defaults.string(forKey: Self.installIDKey)
        defaults.set(UUID().uuidString.lowercased(), forKey: Self.installIDKey)
        return previous.flatMap { TelemetryPreferences.isValidInstallID($0) ? $0 : nil }
    }

    /// 已落盘的 ID，不做生成。用于「不想因为读一次就创建标识」的场景。
    func existingInstallID() -> String? {
        guard let stored = defaults.string(forKey: Self.installIDKey),
              TelemetryPreferences.isValidInstallID(stored) else { return nil }
        return stored
    }

    /// 服务端只认小写 UUID；历史脏值（手改过 plist、旧格式）一律当作无效重生成。
    static func isValidInstallID(_ value: String) -> Bool {
        guard value.count == 36, UUID(uuidString: value) != nil else { return false }
        return value == value.lowercased()
    }
}
