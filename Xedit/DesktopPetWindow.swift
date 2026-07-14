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
    let status: String
    let mood: DesktopPetMood

    static let empty = DesktopPetPresentation(
        sessionID: nil,
        sessionTitle: L10n.DesktopPet.emptySessionTitle,
        message: L10n.DesktopPet.emptyMessage,
        messagePreviews: [],
        outputSessionCount: 0,
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
        guard let sessionID = presentation.messagePreviews.first?.sessionID ?? presentation.sessionID else { return }
        AgentNotificationResponder.reveal(runtimeID: sessionID)
    }

    func openSession(_ sessionID: AgentSession.ID) {
        AgentNotificationResponder.reveal(runtimeID: sessionID)
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
        let outputPreviews = Self.outputPreviews(from: appState, now: now)
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
        let host = NSHostingView(rootView: DesktopPetOverlayView(manager: self))
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

private struct DesktopPetOverlayView: View {
    @ObservedObject var manager: DesktopPetWindowManager
    @State private var lastDragTranslation: CGSize = .zero

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
                if manager.isMessageBubbleCollapsed {
                    collapsedMessageIndicator
                        .offset(x: 4, y: -82)
                } else {
                    messageBubble
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
                .disabled(manager.presentation.sessionID == nil)
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
        ZStack(alignment: .bottom) {
            Image(manager.appearance.assetName)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .frame(width: 132, height: 132)
                .scaleEffect(x: animation.facesRight ? 1 : -1, y: animation.scale)
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
        }
        .frame(width: 140, height: 148, alignment: .bottom)
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

struct DesktopPetAnimationValues {
    private static let walkingSwayRate = 0.85
    private static let walkingStepRate = 2.2

    let horizontalOffset: CGFloat
    let verticalOffset: CGFloat
    let rotation: Double
    let yawRotation: Double
    let scale: CGFloat
    let facesRight: Bool

    init(mood: DesktopPetMood, date: Date) {
        let t = date.timeIntervalSinceReferenceDate
        switch mood {
        case .idle:
            horizontalOffset = 0
            verticalOffset = CGFloat(sin(t * 2.1)) * 2
            rotation = CGFloat(sin(t * 1.4)) * 1.5
            yawRotation = 0
            scale = 1
            facesRight = true
        case .walking:
            horizontalOffset = CGFloat(sin(t * Self.walkingSwayRate)) * 11
            verticalOffset = CGFloat(abs(sin(t * Self.walkingStepRate))) * 4
            rotation = CGFloat(sin(t * Self.walkingStepRate)) * 3
            yawRotation = 0
            scale = 1
            facesRight = sin(t * Self.walkingSwayRate) >= 0
        case .typing:
            let keystroke = CGFloat(sin(t * 11.5))
            horizontalOffset = keystroke * 1.2
            verticalOffset = abs(keystroke) * 2
            rotation = keystroke * 1.2
            yawRotation = 0
            scale = 1
            facesRight = true
        case .jumping:
            horizontalOffset = CGFloat(sin(t * 1.3)) * 4
            verticalOffset = CGFloat(abs(sin(t * 3.5))) * 18
            rotation = CGFloat(sin(t * 3.5)) * 7
            yawRotation = 0
            scale = 1
            facesRight = true
        case .spinning:
            horizontalOffset = 0
            verticalOffset = CGFloat(sin(t * 2.4)) * 3
            rotation = 0
            yawRotation = (t * 135).truncatingRemainder(dividingBy: 360)
            scale = 0.96 + CGFloat(sin(t * 4.8)) * 0.04
            facesRight = true
        case .attention:
            horizontalOffset = CGFloat(sin(t * 12)) * 5
            verticalOffset = 0
            rotation = CGFloat(sin(t * 12)) * 4
            yawRotation = 0
            scale = 1
            facesRight = true
        case .celebrating:
            horizontalOffset = CGFloat(sin(t * 7)) * 9
            verticalOffset = CGFloat(abs(sin(t * 3.8))) * 14
            rotation = CGFloat(sin(t * 7)) * 10
            yawRotation = 0
            scale = 1.04
            facesRight = true
        }
    }
}
