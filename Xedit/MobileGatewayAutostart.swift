//
//  MobileGatewayAutostart.swift
//  WillDeep
//
//  Keeps the mobile-gateway internet relay connected for the whole app
//  session, starting at launch instead of lazily when Settings opens.
//

import AppKit
import Foundation

/// Owns the single, app-wide relay connection for the Mobile Gateway.
///
/// 每个编辑器窗口都有自己的 `AppState`，各自带一个 `lazy`
/// `mobileGatewayCoordinator` / `mobileGatewayDesktopPeer`。如果让每个
/// `AppState` 各自开机自连中继，多开窗口就会向同一个 relay room 拨出 N 条
/// 连接，互相抢连、重复推送。所以「开机自连」必须是全局单点：整个进程只认
/// 一个 owner `AppState`，只维持一份中继连接。
///
/// 由 `WillDeepAppDelegate.applicationDidFinishLaunching` 在启动尾部调用
/// `startIfNeeded()`。中继一旦拉起就在本 app 会话内常驻——`AgentMobileGatewayDesktopPeer`
/// 负责断线重连（指数退避 + 网络恢复即时重连）。
@MainActor
final class MobileGatewayAutostart {
    static let shared = MobileGatewayAutostart()

    /// 被选为中继 owner 的 `AppState`。第一次 `startIfNeeded()` 时锁定，
    /// 之后不再更换——它由 `EditorAppStateRegistry` 强引用（真 editor 窗口，
    /// 或冷启动兜底 mint 的 headless fallback），不会在 owner 窗口关闭时释放，
    /// 所以中继连接不受窗口开关影响。
    private weak var ownerAppState: AppState?
    private var didStart = false

    private init() {}

    /// 幂等：第一次调用锁定一个 owner `AppState` 并拉起中继；之后的调用
    /// 直接返回（`MobileGatewayCoordinator.start()` 本身也幂等，这里再加一道
    /// 单点守卫，避免多窗口 / 多次 onAppear 触发重复连接）。
    func startIfNeeded() {
        guard !didStart else { return }
        let registry = EditorAppStateRegistry.shared
        // 冷启动可能还没有任何 editor 窗口注册；惰性 mint 一个 headless
        // fallback，保证一定有一个 owner 可用。
        registry.ensureHeadlessFallback()
        guard let owner = registry.current else { return }
        didStart = true
        ownerAppState = owner
        Task { @MainActor in
            await owner.mobileGatewayCoordinator.start()
        }
    }
}
