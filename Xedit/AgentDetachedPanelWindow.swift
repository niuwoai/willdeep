//
//  AgentDetachedPanelWindow.swift
//  WillDeep
//
//  1.202.0-rc1：侧边栏面板「分离成独立窗口」。点面板头部的分离按钮，
//  面板从侧栏搬进一个独立的 WindowGroup 窗口；窗口头部提供「放回
//  侧栏」。核心不变量：**同一种面板任何时刻只挂载在一处**（侧栏或
//  窗口），因为终端的 SwiftTerm NSView / 内嵌浏览器的 WKWebView 都是
//  model 层单实例，双宿主会互相抢 superview。
//
//  归位规则：侧栏重新选中某 kind 时（菜单、chat 文件 chip 的
//  OpenRequest 都会走 agentSidePanelKind），对应分离窗口观察到后自行
//  dismiss —— 内容自然回到侧栏，无需额外协调。
//

import SwiftUI
import AppKit
import Combine

/// 记录当前哪些面板种类已被分离到独立窗口（计数式：Files 窗口内部
/// 跳到 Diff 时可能与另一个 Diff 窗口短暂同 kind）。侧栏据此：
/// 1. 让出终端的常驻挂载（见 `AgentSidePanelHost.shouldKeepTerminalMounted`）；
/// 2. 资源回收 reaper 豁免分离中的面板 —— 分离窗口不更新任何 session
///    的 `lastViewedAt`，不豁免的话用户盯着看的终端 tab 会被回收。
@MainActor
final class AgentDetachedPanelRegistry: ObservableObject {
    static let shared = AgentDetachedPanelRegistry()

    @Published private(set) var counts: [AgentSidePanelKind: Int] = [:]

    func register(_ kind: AgentSidePanelKind) {
        counts[kind, default: 0] += 1
    }

    func unregister(_ kind: AgentSidePanelKind) {
        guard let current = counts[kind] else { return }
        if current <= 1 {
            counts.removeValue(forKey: kind)
        } else {
            counts[kind] = current - 1
        }
    }

    func isDetached(_ kind: AgentSidePanelKind) -> Bool {
        (counts[kind] ?? 0) > 0
    }
}

/// WindowGroup(for: AgentSidePanelKind.self) 的根视图。照
/// AgentWindowRootView / RoundtableWindowRootView 的既有约定：不自建
/// AppState，从 EditorAppStateRegistry.shared.current 取当前的注入，
/// AppState 切换时整棵重建（`.id(ObjectIdentifier(appState))`）。
struct AgentDetachedPanelRootView: View {
    @ObservedObject private var registry = EditorAppStateRegistry.shared
    @Binding var kind: AgentSidePanelKind?

    var body: some View {
        Group {
            if let appState = registry.current, let kind {
                AgentDetachedPanelContentView(initialKind: kind)
                    .environmentObject(appState)
                    .tint(appState.editorSettings.interfaceSkin.palette.accent)
                    .preferredColorScheme(appState.editorSettings.interfaceSkin.preferredColorScheme)
                    .id(ObjectIdentifier(appState))
            } else {
                Color.clear.onAppear {
                    EditorAppStateRegistry.shared.ensureHeadlessFallback()
                }
            }
        }
        .frame(minWidth: 360, minHeight: 320)
    }
}

private struct AgentDetachedPanelContentView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let initialKind: AgentSidePanelKind
    /// 窗口内允许面板自身跳转（如 Files → 查看某文件的 Diff），所以
    /// 真正展示的 kind 是本地 state；nil = 面板自己请求关闭 → 关窗口。
    /// 在 init 里初始化而不是 onAppear 赋值 —— 后者会让 onChange 把
    /// 首次赋值当成一次跳转、向 registry 重复注册。
    @State private var kind: AgentSidePanelKind?

    init(initialKind: AgentSidePanelKind) {
        self.initialKind = initialKind
        _kind = State(initialValue: initialKind)
    }

    private var displayedKind: AgentSidePanelKind { kind ?? initialKind }

    /// Files / Preview 的选中文件与侧栏共享同一份 per-session 状态，
    /// 分离/归位来回切时选中不丢。
    private var selectedFileBinding: Binding<URL?> {
        Binding(
            get: { appState.agentSidePanelSelectedFile },
            set: { appState.agentSidePanelSelectedFile = $0 }
        )
    }

    var body: some View {
        let palette = appState.editorSettings.interfaceSkin.palette
        GeometryReader { proxy in
            VStack(spacing: 0) {
                header
                Rectangle().fill(palette.hairline).frame(height: 1)
                AgentSidePanelKindContent(
                    kind: displayedKind,
                    kindSelection: $kind,
                    selectedFile: selectedFileBinding,
                    layoutWidth: proxy.size.width
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(palette.panelFill)
        .focusable(false)
        .navigationTitle(displayedKind.title)
        .onAppear {
            AgentDetachedPanelRegistry.shared.register(displayedKind)
        }
        .onDisappear {
            AgentDetachedPanelRegistry.shared.unregister(displayedKind)
        }
        .onCompatibleChange(of: kind) { oldKind, newKind in
            guard oldKind != newKind else { return }
            if let oldKind {
                AgentDetachedPanelRegistry.shared.unregister(oldKind)
            }
            if let newKind {
                AgentDetachedPanelRegistry.shared.register(newKind)
            } else {
                // 面板自己把 kind 清空（语义上等于「关闭面板」）→ 关窗口。
                // onDisappear 不再有已注册的 kind 需要退，注册数在上面
                // 的 unregister 已归零。
                dismiss()
            }
        }
        // 侧栏重新打开同一种面板 → 本窗口让位归位。覆盖两条路径：
        // 用户在 AgentChatHeader 菜单里点选，或 chat 里的文件 chip /
        // OpenRequest 把面板拉起来。
        .onCompatibleChange(of: appState.agentSidePanelKind) { _, sidebarKind in
            guard let sidebarKind, sidebarKind == displayedKind else { return }
            dismiss()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: displayedKind.systemImage)
                .foregroundStyle(.secondary)
            Text(displayedKind.title)
                .font(AgentDesign.titleFont)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Button {
                reattach()
            } label: {
                Image(systemName: "sidebar.trailing")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.78))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .layoutPriority(1)
            .help(L10n.AgentSidePanel.reattach)
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(height: AgentDesign.headerHeight)
    }

    /// 放回侧栏：把侧栏的当前面板切到本窗口的 kind，再关窗口。关窗
    /// 顺序不依赖 onChange 竞态 —— 即便 agentSidePanelKind 的 onChange
    /// 也触发 dismiss，重复 dismiss 无副作用。
    private func reattach() {
        appState.agentSidePanelKind = displayedKind
        dismiss()
    }
}
