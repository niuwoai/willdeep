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
///
/// 设置页（`MobileGatewaySettingsView`）也必须经由这里拿 coordinator：
/// 设置窗口注入的是「当前聚焦 editor」的 `AppState`，它未必是 owner。
/// 以前设置页直接用自己那份 coordinator，于是「重新生成二维码」只把设置页
/// 那个窗口的连接挪到新 room/token，常驻连接还停在旧 room；设置页窗口一关，
/// 新 room 里就没有任何桌面端了——手机扫新码后连上中继却永远等不到 Mac 回话。
@MainActor
final class MobileGatewayAutostart {
    static let shared = MobileGatewayAutostart()

    private let registry: EditorAppStateRegistry

    /// 常驻中继连接的 owner `AppState`。第一次 `startIfNeeded()` 或
    /// `relayOwner(adopting:)` 时锁定，之后不再更换。强引用：owner 可能是
    /// 一个 editor 窗口的 `AppState`，窗口关闭后 registry 不再持有它，
    /// 这里不留住它的话中继连接会跟着窗口一起消失。
    private(set) var ownerAppState: AppState?
    private var didStart = false

    /// Internal so unit tests can use an isolated registry instead of the
    /// process-wide one.
    init(registry: EditorAppStateRegistry? = nil) {
        self.registry = registry ?? .shared
    }

    /// 幂等：第一次调用锁定一个 owner `AppState` 并拉起中继；之后的调用
    /// 直接返回（`MobileGatewayCoordinator.start()` 本身也幂等，这里再加一道
    /// 单点守卫，避免多窗口 / 多次 onAppear 触发重复连接）。
    func startIfNeeded() {
        guard !didStart else { return }
        let owner: AppState
        if let ownerAppState {
            owner = ownerAppState
        } else {
            // 冷启动可能还没有任何 editor 窗口注册；惰性 mint 一个 headless
            // fallback，保证一定有一个 owner 可用。
            registry.ensureHeadlessFallback()
            guard let current = registry.current else { return }
            owner = relayOwner(adopting: current)
        }
        didStart = true
        Task { @MainActor in
            await owner.mobileGatewayCoordinator.start()
        }
    }

    /// 返回常驻中继的 owner。尚未锁定时（例如自动启动还没跑到）把
    /// `candidate` 收为 owner，保证全进程只有一份中继连接、一份二维码来源。
    @discardableResult
    func relayOwner(adopting candidate: AppState) -> AppState {
        if let ownerAppState { return ownerAppState }
        ownerAppState = candidate
        return candidate
    }
}
