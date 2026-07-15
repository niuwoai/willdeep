//
//  DesktopPetWindow.swift
//  WillDeep
//
//  A small, independent desktop companion for Agent work. It deliberately
//  observes the existing per-session runtime instead of creating a duplicate
//  task model, so its status and latest reply cannot drift from the transcript.
//

import AppKit
import Combine
import SwiftUI

enum DesktopPetMood: Equatable {
    case idle
    case walking
    case typing
    case jumping
    case spinning
    case attention
    case celebrating
}

enum DesktopPetAppearance: String, CaseIterable, Identifiable {
    case robotFox
    case penguin
    case fluffyBear
    case kungFuPanda
    case spaceSage
    case bearGirl
    case starRaccoon
    case seaSinger
    case apeCommander
    case relicExplorer
    case neonDetective
    case desertOracle
    case webInventor
    case paranormalTech
    case cyberDrifter
    case whistleCaptain
    case antennaBotanist
    case cosmicScholar
    case feralMechanic
    case plantRobot
    case cloudForge
    case helpdeskHero
    case codeShiba
    case moonRabbit

    var id: String { rawValue }

    var assetName: String {
        switch self {
        case .robotFox: "DesktopPet"
        case .penguin: "DesktopPetPenguin"
        case .fluffyBear: "DesktopPetBear"
        case .kungFuPanda: "DesktopPetKungFuPanda"
        case .spaceSage: "DesktopPetSpaceSage"
        case .bearGirl: "DesktopPetBearGirl"
        case .starRaccoon: "DesktopPetStarRaccoon"
        case .seaSinger: "DesktopPetSeaSinger"
        case .apeCommander: "DesktopPetApeCommander"
        case .relicExplorer: "DesktopPetRelicExplorer"
        case .neonDetective: "DesktopPetNeonDetective"
        case .desertOracle: "DesktopPetDesertOracle"
        case .webInventor: "DesktopPetWebHero"
        case .paranormalTech: "DesktopPetParanormalTech"
        case .cyberDrifter: "DesktopPetCyberDrifter"
        case .whistleCaptain: "DesktopPetWhistleCaptain"
        case .antennaBotanist: "DesktopPetAntennaBotanist"
        case .cosmicScholar: "DesktopPetCosmicScholar"
        case .feralMechanic: "DesktopPetFeralMechanic"
        case .plantRobot: "DesktopPetPlantRobot"
        case .cloudForge: "DesktopPetCloudForge"
        case .helpdeskHero: "DesktopPetHelpdesk"
        case .codeShiba: "DesktopPetCodeShiba"
        case .moonRabbit: "DesktopPetMoonRabbit"
        }
    }

    var displayName: String {
        switch self {
        case .robotFox: L10n.DesktopPet.appearanceRobotFox
        case .penguin: L10n.DesktopPet.appearancePenguin
        case .fluffyBear: L10n.DesktopPet.appearanceFluffyBear
        case .kungFuPanda: L10n.DesktopPet.appearanceKungFuPanda
        case .spaceSage: L10n.DesktopPet.appearanceSpaceSage
        case .bearGirl: L10n.DesktopPet.appearanceBearGirl
        case .starRaccoon: L10n.DesktopPet.appearanceStarRaccoon
        case .seaSinger: L10n.DesktopPet.appearanceSeaSinger
        case .apeCommander: L10n.DesktopPet.appearanceApeCommander
        case .relicExplorer: L10n.DesktopPet.appearanceRelicExplorer
        case .neonDetective: L10n.DesktopPet.appearanceNeonDetective
        case .desertOracle: L10n.DesktopPet.appearanceDesertOracle
        case .webInventor: L10n.DesktopPet.appearanceWebInventor
        case .paranormalTech: L10n.DesktopPet.appearanceParanormalTech
        case .cyberDrifter: L10n.DesktopPet.appearanceCyberDrifter
        case .whistleCaptain: L10n.DesktopPet.appearanceWhistleCaptain
        case .antennaBotanist: L10n.DesktopPet.appearanceAntennaBotanist
        case .cosmicScholar: L10n.DesktopPet.appearanceCosmicScholar
        case .feralMechanic: L10n.DesktopPet.appearanceFeralMechanic
        case .plantRobot: L10n.DesktopPet.appearancePlantRobot
        case .cloudForge: L10n.DesktopPet.appearanceCloudForge
        case .helpdeskHero: L10n.DesktopPet.appearanceHelpdeskHero
        case .codeShiba: L10n.DesktopPet.appearanceCodeShiba
        case .moonRabbit: L10n.DesktopPet.appearanceMoonRabbit
        }
    }
}

struct DesktopPetMessagePreview: Identifiable, Equatable {
    let sessionID: AgentSession.ID
    let sessionTitle: String
    let message: String
    let updatedAt: Date

    var id: AgentSession.ID { sessionID }
}

struct DesktopPetPresentation: Equatable {
    let sessionID: AgentSession.ID?
    let sessionTitle: String
    let message: String
    let messagePreviews: [DesktopPetMessagePreview]
    let outputSessionCount: Int
    let isMessageBubbleVisible: Bool
    let status: String
    let mood: DesktopPetMood

    static let empty = DesktopPetPresentation(
        sessionID: nil,
        sessionTitle: L10n.DesktopPet.emptySessionTitle,
        message: L10n.DesktopPet.emptyMessage,
        messagePreviews: [],
        outputSessionCount: 0,
        isMessageBubbleVisible: false,
        status: L10n.DesktopPet.statusIdle,
        mood: .idle
    )
}

enum DesktopPetMessageFormatter {
    nonisolated static let maximumCharacters = 180

    nonisolated static func makePreview(_ text: String) -> String {
        let compact = text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        guard compact.count > maximumCharacters else { return compact }
        return String(compact.prefix(maximumCharacters)) + "…"
    }
}

enum DesktopPetOutputFreshness {
    nonisolated static let maximumAge: TimeInterval = 60

    nonisolated static func isFresh(updatedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(updatedAt) <= maximumAge
    }
}

enum DesktopPetMessageCardVisibility {
    nonisolated static func shouldShowMessageCards(
        appIsActive: Bool,
        outputSessionCount: Int
    ) -> Bool {
        !appIsActive && outputSessionCount > 0
    }
}

/// A non-activating panel normally drops the first mouse-down delivered while
/// its owning app is inactive. The desktop pet must stay non-activating so it
/// does not steal focus, but it still needs that first event to begin a drag.
///
/// Deliberately non-generic: the generic `NSHostingView<Content>` subclass makes
/// swift-frontend 6.3.1 segfault in the `EarlyPerfInliner` SIL pass while
/// specializing the synthesized deinit for the Release x86_64 slice.
enum DesktopPetFirstMousePolicy {
    nonisolated static func accepts(_ event: NSEvent?) -> Bool {
        true
    }
}

private final class DesktopPetFirstMouseHostingView: NSHostingView<DesktopPetOverlayView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        DesktopPetFirstMousePolicy.accepts(event)
    }
}

@MainActor
final class DesktopPetWindowManager: ObservableObject {
    static let shared = DesktopPetWindowManager()

    private enum DefaultsKey {
        static let isEnabled = "com.willdeep.desktop-pet.enabled.v1"
        static let appearance = "com.willdeep.desktop-pet.appearance.v1"
        static let originX = "com.willdeep.desktop-pet.origin-x.v1"
        static let originY = "com.willdeep.desktop-pet.origin-y.v1"
    }

    @Published private(set) var presentation = DesktopPetPresentation.empty
    @Published private(set) var isEnabled: Bool
    @Published private(set) var appearance: DesktopPetAppearance
    @Published private(set) var isDraggingPet = false
    @Published private(set) var isMessageBubbleCollapsed = false

    private weak var appState: AppState?
    private var window: NSPanel?
    private var pollingTimer: Timer?
    private var wasBusy = false
    private var celebrationEndsAt: Date?
    private var manualJumpEndsAt: Date?

    private init() {
        // 默认开启桌面宠物:首次启动即陪伴,用户可随时在右键菜单 /
        // 设置里关闭(关闭状态会写回 UserDefaults,不会被这个默认值覆盖)。
        isEnabled = UserDefaults.standard.object(forKey: DefaultsKey.isEnabled) as? Bool ?? true
        appearance = UserDefaults.standard.string(forKey: DefaultsKey.appearance)
            .flatMap(DesktopPetAppearance.init(rawValue:)) ?? .robotFox
    }

    func attach(to appState: AppState) {
        self.appState = appState
        startPollingIfNeeded()
        refresh()
    }

    func toggle() {
        setEnabled(!isEnabled)
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: DefaultsKey.isEnabled)
        if enabled {
            showIfNeeded()
            refresh()
        } else {
            hide()
        }
    }

    func selectAppearance(_ selectedAppearance: DesktopPetAppearance) {
        appearance = selectedAppearance
        UserDefaults.standard.set(selectedAppearance.rawValue, forKey: DefaultsKey.appearance)
    }

    func openCurrentSession() {
        guard let sessionID = presentation.messagePreviews.first?.sessionID ?? presentation.sessionID else {
            openNewChat()
            return
        }
        AgentNotificationResponder.reveal(runtimeID: sessionID)
    }

    func openSession(_ sessionID: AgentSession.ID) {
        AgentNotificationResponder.reveal(runtimeID: sessionID)
    }

    func openNewChat() {
        let registry = EditorAppStateRegistry.shared
        let target = appState ?? registry.current ?? AppState()
        registry.register(target)
        registry.setCurrent(target)
        target.setAppMode(.agent)
        target.startNewAgentSession()
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .willDeepRevealAgentSession, object: nil)
    }

    func collapseMessageBubble() {
        isMessageBubbleCollapsed = true
    }

    func expandMessageBubble() {
        isMessageBubbleCollapsed = false
    }

    /// 打开设置窗口并跳到「桌面宠物」标签(右键菜单入口)。
    func openSettings() {
        EditorSettingsNavigation.shared.open(.pet, appState: appState)
    }

    func jumpOnce() {
        manualJumpEndsAt = Date().addingTimeInterval(0.9)
        refresh()
    }

    func beginDraggingPet() {
        isDraggingPet = true
    }

    /// 按增量位移拖动宠物窗口。SwiftUI 的 y 轴向下、AppKit 向上,
    /// 所以纵向取反。
    func moveWindow(by delta: CGSize) {
        guard let window else { return }
        var origin = window.frame.origin
        origin.x += delta.width
        origin.y -= delta.height
        window.setFrameOrigin(origin)
    }

    func finishDraggingPet() {
        defer { isDraggingPet = false }
        persistWindowPosition()
    }

    /// 拖动结束后把当前位置写回 UserDefaults,下次显示时恢复。
    func persistWindowPosition() {
        guard let window else { return }
        let origin = window.frame.origin
        UserDefaults.standard.set(Double(origin.x), forKey: DefaultsKey.originX)
        UserDefaults.standard.set(Double(origin.y), forKey: DefaultsKey.originY)
    }

    private func startPollingIfNeeded() {
        guard pollingTimer == nil else { return }
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        pollingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func refresh() {
        guard isEnabled else { return }
        showIfNeeded()
        let now = Date()
        let isManualJumping = manualJumpIsActive(at: now)

        guard let appState else {
            presentation = DesktopPetPresentation(
                sessionID: nil,
                sessionTitle: DesktopPetPresentation.empty.sessionTitle,
                message: DesktopPetPresentation.empty.message,
                messagePreviews: [],
                outputSessionCount: 0,
                isMessageBubbleVisible: false,
                status: DesktopPetPresentation.empty.status,
                mood: isManualJumping ? .jumping : .idle
            )
            return
        }

        let runtimes = Array(appState.agentRuntimes.values)
        let runtime = appState.activeRuntime
        let isBusy = runtimes.contains { $0.isResponding || $0.isAwaitingProviderSlot }
        if wasBusy && !isBusy {
            celebrationEndsAt = now.addingTimeInterval(6)
        }
        wasBusy = isBusy

        let needsAttention = runtimes.contains { runtime in
            runtime.toolCalls.contains { $0.status.isBlockingForUserDecision }
        }
        let isRunningTool = runtimes.contains { runtime in
            runtime.toolCalls.contains { $0.status == .running }
        }
        let appIsActive = NSApplication.shared.isActive
        let outputPreviews = appIsActive ? [] : Self.outputPreviews(from: appState, now: now)
        let shouldShowMessageCards = DesktopPetMessageCardVisibility.shouldShowMessageCards(
            appIsActive: appIsActive,
            outputSessionCount: outputPreviews.count
        )
        let visiblePreviews = Array(outputPreviews.prefix(Self.maximumVisibleOutputPreviews))
        let latestPreview = visiblePreviews.first
        let hasCelebration = celebrationEndsAt.map { $0 > now } ?? false
        let isUserTyping = !appState.agentInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        let baseMood: DesktopPetMood
        let status: String
        if isUserTyping {
            baseMood = .typing
            status = L10n.DesktopPet.statusTyping
        } else if needsAttention {
            baseMood = .attention
            status = L10n.DesktopPet.statusNeedsAttention
        } else if isBusy, isRunningTool {
            baseMood = .walking
            status = L10n.DesktopPet.statusWorking
        } else if isBusy {
            baseMood = .jumping
            status = L10n.DesktopPet.statusThinking
        } else if hasCelebration {
            baseMood = .celebrating
            status = L10n.DesktopPet.statusComplete
        } else if latestPreview != nil {
            baseMood = .spinning
            status = L10n.DesktopPet.statusReady
        } else {
            baseMood = .idle
            status = L10n.DesktopPet.statusIdle
        }

        presentation = DesktopPetPresentation(
            sessionID: latestPreview?.sessionID ?? runtime?.id,
            sessionTitle: latestPreview?.sessionTitle ?? runtime?.session.title ?? L10n.DesktopPet.emptySessionTitle,
            message: latestPreview?.message ?? L10n.DesktopPet.emptyMessage,
            messagePreviews: visiblePreviews,
            outputSessionCount: outputPreviews.count,
            isMessageBubbleVisible: shouldShowMessageCards,
            status: status,
            mood: isManualJumping ? .jumping : baseMood
        )
    }

    private func manualJumpIsActive(at date: Date) -> Bool {
        guard let manualJumpEndsAt else { return false }
        if manualJumpEndsAt > date { return true }
        self.manualJumpEndsAt = nil
        return false
    }

    private static let maximumVisibleOutputPreviews = 3

    private static func outputPreviews(from appState: AppState, now: Date) -> [DesktopPetMessagePreview] {
        var previewsByID: [AgentSession.ID: DesktopPetMessagePreview] = [:]

        for runtime in appState.agentRuntimes.values {
            if let preview = outputPreview(session: runtime.session, messages: runtime.messages) {
                previewsByID[runtime.id] = preview
            }
        }

        for session in appState.agentSessions where previewsByID[session.id] == nil {
            if let preview = outputPreview(session: session, messages: session.messages) {
                previewsByID[session.id] = preview
            }
        }

        return previewsByID.values.filter { preview in
            DesktopPetOutputFreshness.isFresh(updatedAt: preview.updatedAt, now: now)
        }.sorted { lhs, rhs in
            lhs.updatedAt > rhs.updatedAt
        }
    }

    private static func outputPreview(
        session: AgentSession,
        messages: [AgentMessage]
    ) -> DesktopPetMessagePreview? {
        guard session.archivedAt == nil,
              let latestOutput = messages.reversed().first(where: isVisibleOutputMessage) else {
            return nil
        }
        let message = DesktopPetMessageFormatter.makePreview(latestOutput.content)
        guard !message.isEmpty else { return nil }
        return DesktopPetMessagePreview(
            sessionID: session.id,
            sessionTitle: session.title,
            message: message,
            updatedAt: latestOutput.createdAt
        )
    }

    private static func isVisibleOutputMessage(_ message: AgentMessage) -> Bool {
        message.role == .assistant && !DesktopPetMessageFormatter.makePreview(message.content).isEmpty
    }

    private func showIfNeeded() {
        guard window == nil else { return }

        let size = NSSize(width: 360, height: 260)
        let host = DesktopPetFirstMouseHostingView(rootView: DesktopPetOverlayView(manager: self))
        host.frame = NSRect(origin: .zero, size: size)

        let panel = NSPanel(
            contentRect: Self.savedOrDefaultFrame(for: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = host
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        window = panel
        panel.orderFrontRegardless()
    }

    private func hide() {
        pollingTimer?.invalidate()
        pollingTimer = nil
        window?.orderOut(nil)
        window?.contentView = nil
        window?.close()
        window = nil
    }

    /// 优先用用户拖动后保存的位置;没有保存值、或保存的位置落在
    /// 已断开的显示器上(不与任何屏幕相交)时,退回右下角默认位。
    private static func savedOrDefaultFrame(for size: NSSize) -> NSRect {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: DefaultsKey.originX) != nil,
              defaults.object(forKey: DefaultsKey.originY) != nil else {
            return defaultFrame(for: size)
        }
        let rect = NSRect(
            x: defaults.double(forKey: DefaultsKey.originX),
            y: defaults.double(forKey: DefaultsKey.originY),
            width: size.width,
            height: size.height
        )
        guard NSScreen.screens.contains(where: { $0.frame.intersects(rect) }) else {
            return defaultFrame(for: size)
        }
        return rect
    }

    private static func defaultFrame(for size: NSSize) -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return NSRect(origin: .zero, size: size) }
        let frame = screen.visibleFrame
        let margin: CGFloat = 22
        return NSRect(
            x: frame.maxX - size.width - margin,
            y: frame.minY + margin,
            width: size.width,
            height: size.height
        )
    }

}

struct DesktopPetOverlayView: View {
    @ObservedObject var manager: DesktopPetWindowManager
    @State private var lastDragTranslation: CGSize = .zero

    // 显式 init:私有的 @State 存储会把 memberwise init 降级成
    // private,跨文件(单测)构造需要这个。
    init(manager: DesktopPetWindowManager) {
        self.manager = manager
    }

    private var displayMood: DesktopPetMood {
        manager.isDraggingPet ? .walking : manager.presentation.mood
    }

    /// DragGesture 报告的是自手势开始起的累计位移;这里缓存上一帧的
    /// 累计值,每帧只把「增量」喂给窗口,实现跟手拖动。
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                manager.beginDraggingPet()
                let delta = CGSize(
                    width: value.translation.width - lastDragTranslation.width,
                    height: value.translation.height - lastDragTranslation.height
                )
                lastDragTranslation = value.translation
                manager.moveWindow(by: delta)
            }
            .onEnded { _ in
                lastDragTranslation = .zero
                manager.finishDraggingPet()
            }
    }

    var body: some View {
        TimelineView(.animation) { context in
            let animation = DesktopPetAnimationValues(
                mood: displayMood,
                date: context.date
            )

            HStack(alignment: .bottom, spacing: -4) {
                if manager.presentation.isMessageBubbleVisible {
                    if manager.isMessageBubbleCollapsed {
                        collapsedMessageIndicator
                            .offset(x: 4, y: -82)
                    } else {
                        messageBubble
                    }
                }

                petScene(animation: animation)
                    .accessibilityLabel(L10n.DesktopPet.accessibilityLabel)
            }
            .frame(width: 360, height: 260, alignment: .bottomTrailing)
            .contentShape(Rectangle())
            .gesture(dragGesture)
            .contextMenu {
                Button(L10n.DesktopPet.settingsAction) {
                    manager.openSettings()
                }
                Button(L10n.DesktopPet.hideAction) {
                    manager.setEnabled(false)
                }
            }
        }
    }

    private var messageBubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(manager.presentation.status)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(action: manager.collapseMessageBubble) {
                    Image(systemName: "chevron.right.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L10n.DesktopPet.collapseMessages)
                .accessibilityLabel(L10n.DesktopPet.collapseMessages)
            }

            if manager.presentation.messagePreviews.isEmpty {
                Button(action: manager.openCurrentSession) {
                    messageRow(
                        title: manager.presentation.sessionTitle,
                        message: manager.presentation.message
                    )
                }
                .buttonStyle(.plain)
                .focusable(false)
            } else {
                ForEach(Array(manager.presentation.messagePreviews.enumerated()), id: \.element.id) { index, preview in
                    if index > 0 {
                        Divider()
                            .opacity(0.45)
                    }
                    Button {
                        manager.openSession(preview.sessionID)
                    } label: {
                        messageRow(title: preview.sessionTitle, message: preview.message)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(width: 220, alignment: .leading)
        // The bubble floats over the desktop wallpaper, so `.ultraThinMaterial`
        // let a dark wallpaper bleed through and washed out the `.secondary`
        // status / session labels until they were unreadable. `.regularMaterial`
        // is opaque enough to be its own contrast substrate — the semantic text
        // colors stay legible on any wallpaper, light or dark.
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.26), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }

    private var collapsedMessageIndicator: some View {
        Button(action: manager.expandMessageBubble) {
            ZStack {
                Circle()
                    .fill(.regularMaterial)
                    .overlay {
                        Circle()
                            .strokeBorder(.white.opacity(0.32), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.16), radius: 12, y: 5)

                Text("\(manager.presentation.outputSessionCount)")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .frame(width: 38, height: 38)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(L10n.DesktopPet.expandMessages)
        .accessibilityLabel(L10n.DesktopPet.expandMessages)
    }

    private func messageRow(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func petScene(animation: DesktopPetAnimationValues) -> some View {
        DesktopPetSceneView(
            appearance: manager.appearance,
            animation: animation
        )
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture(count: 2)
                .onEnded { manager.jumpOnce() }
        )
    }

    private var statusColor: Color {
        switch displayMood {
        case .attention:
            return .orange
        case .walking, .typing, .jumping:
            return .mint
        case .celebrating, .spinning:
            return .cyan
        case .idle:
            return .secondary
        }
    }
}

struct DesktopPetSceneView: View {
    private enum Layout {
        static let sceneWidth: CGFloat = 140
        static let sceneHeight: CGFloat = 148
        static let petSize: CGFloat = 132
        static let laptopWidth: CGFloat = 96
        static let laptopHeight: CGFloat = 90
        static let laptopHorizontalOffset: CGFloat = 10
        static let laptopBaseVerticalOffset: CGFloat = 9
        static let heartHorizontalOffset: CGFloat = -45
        static let heartVerticalOffset: CGFloat = -94
        static let sparkleHorizontalOffset: CGFloat = 45
        static let sparkleVerticalOffset: CGFloat = -83
    }

    let appearance: DesktopPetAppearance
    let animation: DesktopPetAnimationValues

    var body: some View {
        ZStack(alignment: .bottom) {
            cuteEffectLayer

            Image(appearance.assetName)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .frame(width: Layout.petSize, height: Layout.petSize)
                .scaleEffect(
                    x: (animation.facesRight ? 1 : -1) * animation.scale * animation.horizontalScale,
                    y: animation.scale * animation.verticalScale
                )
                .rotationEffect(.degrees(animation.rotation))
                .rotation3DEffect(
                    .degrees(animation.yawRotation),
                    axis: (x: 0, y: 1, z: 0),
                    perspective: 0.35
                )
                .offset(
                    x: animation.horizontalOffset,
                    y: animation.verticalOffset
                )
                .shadow(color: .black.opacity(0.24), radius: 7, y: 5)

            Image("DesktopPetLaptop")
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .frame(width: Layout.laptopWidth, height: Layout.laptopHeight)
                .rotationEffect(.degrees(animation.laptopRotation))
                .offset(
                    x: Layout.laptopHorizontalOffset,
                    y: Layout.laptopBaseVerticalOffset + animation.laptopVerticalOffset
                )
                .shadow(
                    color: .cyan.opacity(animation.laptopGlowOpacity),
                    radius: 7,
                    y: 2
                )
                .opacity(animation.laptopOpacity)
                .accessibilityHidden(animation.laptopOpacity < 0.01)
        }
        .frame(
            width: Layout.sceneWidth,
            height: Layout.sceneHeight,
            alignment: .bottom
        )
    }

    private var cuteEffectLayer: some View {
        ZStack {
            Image(systemName: "heart.fill")
                .font(.system(size: 19, weight: .bold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.pink, .white)
                .offset(
                    x: Layout.heartHorizontalOffset,
                    y: Layout.heartVerticalOffset + animation.cuteEffectVerticalOffset
                )

            Image(systemName: "sparkles")
                .font(.system(size: 24, weight: .bold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.yellow, .mint)
                .rotationEffect(.degrees(animation.cuteEffectRotation))
                .offset(
                    x: Layout.sparkleHorizontalOffset,
                    y: Layout.sparkleVerticalOffset + animation.cuteEffectVerticalOffset
                )
        }
        .opacity(animation.cuteEffectOpacity)
        .accessibilityHidden(true)
    }
}

struct DesktopPetAnimationValues {
    private static let walkingSwayRate = 0.85
    private static let walkingStepRate = 2.2
    private static let idleCuteCycleDuration = 11.0
    private static let idleCuteStart = 6.0
    private static let idleCuteDuration = 3.0
    private static let typingStrokeRate = 13.2

    let horizontalOffset: CGFloat
    let verticalOffset: CGFloat
    let rotation: Double
    let yawRotation: Double
    let scale: CGFloat
    let horizontalScale: CGFloat
    let verticalScale: CGFloat
    let facesRight: Bool
    let laptopOpacity: Double
    let laptopVerticalOffset: CGFloat
    let laptopRotation: Double
    let laptopGlowOpacity: Double
    let cuteEffectOpacity: Double
    let cuteEffectVerticalOffset: CGFloat
    let cuteEffectRotation: Double

    init(mood: DesktopPetMood, date: Date) {
        let t = date.timeIntervalSinceReferenceDate
        var horizontalOffset: CGFloat = 0
        var verticalOffset: CGFloat = 0
        var rotation = 0.0
        var yawRotation = 0.0
        var scale: CGFloat = 1
        var horizontalScale: CGFloat = 1
        var verticalScale: CGFloat = 1
        var facesRight = true
        var laptopOpacity = 0.0
        var laptopVerticalOffset: CGFloat = 0
        var laptopRotation = 0.0
        var laptopGlowOpacity = 0.0
        var cuteEffectOpacity = 0.0
        var cuteEffectVerticalOffset: CGFloat = 0
        var cuteEffectRotation = 0.0

        switch mood {
        case .idle:
            let breathing = CGFloat(sin(t * 2.1))
            let cycleTime = t.truncatingRemainder(dividingBy: Self.idleCuteCycleDuration)
            let isPerformingCuteAction = cycleTime >= Self.idleCuteStart
                && cycleTime <= Self.idleCuteStart + Self.idleCuteDuration
            let cuteProgress = isPerformingCuteAction
                ? (cycleTime - Self.idleCuteStart) / Self.idleCuteDuration
                : 0
            let cuteEnvelope = CGFloat(sin(cuteProgress * .pi))
            let cuteWiggle = CGFloat(sin(cuteProgress * .pi * 4))

            horizontalOffset = cuteEnvelope * cuteWiggle * 3
            verticalOffset = breathing * 2 - cuteEnvelope * (3 + abs(cuteWiggle) * 3)
            rotation = Double(breathing * 1.5 + cuteEnvelope * (4 + cuteWiggle * 3))
            horizontalScale = 1 + cuteEnvelope * 0.035
            verticalScale = 1 - cuteEnvelope * 0.025
            cuteEffectOpacity = Double(cuteEnvelope)
            cuteEffectVerticalOffset = -cuteEnvelope * 8
            cuteEffectRotation = Double(cuteWiggle * 10)
        case .walking:
            horizontalOffset = CGFloat(sin(t * Self.walkingSwayRate)) * 11
            verticalOffset = -CGFloat(abs(sin(t * Self.walkingStepRate))) * 4
            rotation = sin(t * Self.walkingStepRate) * 3
            facesRight = sin(t * Self.walkingSwayRate) >= 0
        case .typing:
            let leftStroke = CGFloat(sin(t * Self.typingStrokeRate))
            let rightStroke = CGFloat(sin(t * Self.typingStrokeRate + .pi))
            let bodyRhythm = CGFloat(sin(t * Self.typingStrokeRate / 2))
            horizontalOffset = -7 + bodyRhythm * 1.8
            verticalOffset = -11 - abs(leftStroke) * 1.8
            rotation = Double(bodyRhythm * 1.7)
            horizontalScale = 1 + abs(rightStroke) * 0.018
            verticalScale = 1 - abs(leftStroke) * 0.014
            laptopOpacity = 1
            laptopVerticalOffset = -abs(rightStroke) * 1.5
            laptopRotation = sin(t * 4.6) * 0.8
            laptopGlowOpacity = 0.58 + (sin(t * 3.2) + 1) * 0.12
        case .jumping:
            horizontalOffset = CGFloat(sin(t * 1.3)) * 4
            let jump = CGFloat(abs(sin(t * 3.5)))
            verticalOffset = -jump * 18
            rotation = sin(t * 3.5) * 7
            horizontalScale = 1 + jump * 0.04
            verticalScale = 1 - jump * 0.03
        case .spinning:
            verticalOffset = CGFloat(sin(t * 2.4)) * 3
            yawRotation = (t * 135).truncatingRemainder(dividingBy: 360)
            scale = 0.96 + CGFloat(sin(t * 4.8)) * 0.04
        case .attention:
            horizontalOffset = CGFloat(sin(t * 12)) * 5
            rotation = sin(t * 12) * 4
        case .celebrating:
            horizontalOffset = CGFloat(sin(t * 7)) * 9
            verticalOffset = -CGFloat(abs(sin(t * 3.8))) * 14
            rotation = sin(t * 7) * 10
            scale = 1.04
            cuteEffectOpacity = 1
            cuteEffectVerticalOffset = CGFloat(sin(t * 4.2)) * -5
            cuteEffectRotation = sin(t * 6) * 12
        }

        self.horizontalOffset = horizontalOffset
        self.verticalOffset = verticalOffset
        self.rotation = rotation
        self.yawRotation = yawRotation
        self.scale = scale
        self.horizontalScale = horizontalScale
        self.verticalScale = verticalScale
        self.facesRight = facesRight
        self.laptopOpacity = laptopOpacity
        self.laptopVerticalOffset = laptopVerticalOffset
        self.laptopRotation = laptopRotation
        self.laptopGlowOpacity = laptopGlowOpacity
        self.cuteEffectOpacity = cuteEffectOpacity
        self.cuteEffectVerticalOffset = cuteEffectVerticalOffset
        self.cuteEffectRotation = cuteEffectRotation
    }
}
