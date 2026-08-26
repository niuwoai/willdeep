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
    case ready
    case attention
    case celebrating
}

enum DesktopPetAmbientEffectKind: Int, CaseIterable, Hashable {
    case lips
    case stars
    case hearts
    case bubbles
}

struct DesktopPetAmbientEffectPlan: Equatable {
    let kind: DesktopPetAmbientEffectKind
    let particleCount: Int
    let progress: Double
    let seed: UInt64

    static func make(cycleIndex: Int, progress: Double) -> Self {
        let seed = mixedSeed(for: cycleIndex)
        let kind = DesktopPetAmbientEffectKind(
            rawValue: Int(seed % UInt64(DesktopPetAmbientEffectKind.allCases.count))
        ) ?? .stars
        let particleCount: Int
        switch kind {
        case .lips:
            particleCount = ((seed >> 12) & 1) == 0 ? 1 : 3 + Int((seed >> 8) % 4)
        case .stars, .hearts:
            particleCount = 3 + Int((seed >> 8) % 5)
        case .bubbles:
            particleCount = 4 + Int((seed >> 8) % 5)
        }
        return Self(
            kind: kind,
            particleCount: particleCount,
            progress: min(max(progress, 0), 1),
            seed: seed
        )
    }

    func particleProgress(at index: Int) -> Double {
        let delay = min(Double(index) * 0.065, 0.4)
        return min(max((progress - delay) / (1 - delay), 0), 1)
    }

    func unitValue(particle index: Int, salt: UInt64) -> Double {
        let mixed = Self.mix(seed &+ UInt64(index + 1) &* 0x9E37_79B9_7F4A_7C15 &+ salt)
        return Double(mixed % 10_000) / 9_999
    }

    private static func mixedSeed(for cycleIndex: Int) -> UInt64 {
        mix(UInt64(bitPattern: Int64(cycleIndex)) &+ 0xD1B5_4A32_D192_ED03)
    }

    private static func mix(_ input: UInt64) -> UInt64 {
        var value = input
        value ^= value >> 30
        value &*= 0xBF58_476D_1CE4_E5B9
        value ^= value >> 27
        value &*= 0x94D0_49BB_1331_11EB
        value ^= value >> 31
        return value
    }
}

enum DesktopPetAutonomy {
    static let minimumJumpDelay: TimeInterval = 14
    static let maximumJumpDelay: TimeInterval = 32
    static let jumpDuration: TimeInterval = 1.15

    static func jumpDelay(unitInterval: Double) -> TimeInterval {
        let normalized = min(max(unitInterval, 0), 1)
        return minimumJumpDelay + (maximumJumpDelay - minimumJumpDelay) * normalized
    }
}

enum DesktopPetAppearance: String, CaseIterable, Identifiable {
    case bearGirl
    case robotFox
    case penguin
    case fluffyBear
    case kungFuPanda
    case spaceSage
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
    case cosmicDownsizer
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
        case .cosmicDownsizer: "DesktopPetCosmicDownsizer"
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
        case .cosmicDownsizer: L10n.DesktopPet.appearanceCosmicDownsizer
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

    static func userInputLabel(for messages: [AgentMessage]) -> String {
        AgentUserInputPreview.latest(in: messages) ?? L10n.DesktopPet.emptySessionTitle
    }
}

enum DesktopPetOutputFreshness {
    nonisolated static let maximumAge: TimeInterval = 60

    nonisolated static func isFresh(updatedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(updatedAt) <= maximumAge
    }
}

enum DesktopPetHibernation {
    nonisolated static let duration: TimeInterval = 5 * 60
    /// 「冬眠到明天」醒来的钟点(明早 9:00)。
    nonisolated static let wakeUpHour = 9

    nonisolated static func isActive(endsAt: Date?, now: Date) -> Bool {
        guard let endsAt else { return false }
        return endsAt > now
    }

    /// 明天早上 `wakeUpHour` 点的时间戳。日历算不出时(理论上不会发生)
    /// 退回「24 小时后」兜底,保证一定会醒。
    nonisolated static func nextMorning(after now: Date, calendar: Calendar = .current) -> Date {
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
              let wakeUp = calendar.date(
                  bySettingHour: wakeUpHour,
                  minute: 0,
                  second: 0,
                  of: tomorrow
              ) else {
            return now.addingTimeInterval(24 * 60 * 60)
        }
        return wakeUp
    }
}

enum DesktopPetAnimationCadence {
    /// The pet uses deliberately pixelated artwork and does not benefit enough
    /// from display-rate redraws to justify relaying out its hosting window on
    /// every frame.
    ///
    /// This cadence is not local to the pet panel. A CA transaction flush walks
    /// *every* window that has pending layout, so whichever timeline ticks
    /// fastest sets the display-cycle beat for the whole app — and the main
    /// window's view tree is orders of magnitude larger than the pet's. A
    /// sample of an otherwise idle 1.234.0-rc13 caught `DesktopPetSceneView`
    /// and `AgentBackgroundTasksPanel` inside the *same* `NSHostingView.layout()`
    /// stack, with ~20% of a core going to layout recursion and dirty-flag
    /// propagation that produced no visible change.
    ///
    /// The background cadence used to be *higher* than the foreground one (12 vs
    /// 8) on the theory that the pet is the primary visible surface while
    /// WillDeep is inactive. That reasoning holds for visibility but inverts the
    /// cost: being in the background is exactly when the expensive main window
    /// has nothing to show and the user is least likely to be watching.
    ///
    /// Both cadences are now 4fps. A sample of an idle 1.247.0-rc4 still found
    /// the whole of the app's residual main-thread time inside the CA flush this
    /// timeline drives. The animated poses are periodic over a ~3s breathing
    /// cycle and the artwork is pixelated, so halving the beat halves that cost
    /// without changing the shape of the motion.
    nonisolated static let foregroundFramesPerSecond: Double = 4
    nonisolated static let backgroundFramesPerSecond: Double = 4

    nonisolated static func framesPerSecond(appIsActive: Bool) -> Double {
        appIsActive ? foregroundFramesPerSecond : backgroundFramesPerSecond
    }

    nonisolated static func minimumInterval(appIsActive: Bool) -> TimeInterval {
        1.0 / framesPerSecond(appIsActive: appIsActive)
    }
}

/// Decides whether the pet's animation timeline should run at all.
///
/// `NSWindow.occlusionState` drops `.visible` when the panel is fully covered,
/// on an inactive Space, or hidden behind the screen saver / lock screen.
/// Animating there costs a full app-wide display cycle per frame and paints
/// nothing anyone can see.
enum DesktopPetAnimationGate {
    /// `.idle` is the resting mood the pet holds for the vast majority of a
    /// session, and its motion — a slow breath plus an 8s ambient flourish —
    /// is precisely the motion nobody is waiting on. Parking it trades that
    /// idle wiggle for the app-wide display cycle it would otherwise drive on
    /// every frame.
    ///
    /// `.ready` is also parked. It can remain selected as long as an unread
    /// output preview exists, so animating it kept an otherwise idle app on a
    /// permanent 4fps display cycle. The bubble and status text still carry the
    /// result; transient and actionable moods continue to animate.
    nonisolated static func requiresTimeline(mood: DesktopPetMood) -> Bool {
        switch mood {
        case .idle, .ready:
            return false
        case .walking, .typing, .jumping, .attention, .celebrating:
            return true
        }
    }

    nonisolated static func shouldAnimate(
        isEnabled: Bool,
        isWindowVisible: Bool,
        mood: DesktopPetMood
    ) -> Bool {
        isEnabled && isWindowVisible && requiresTimeline(mood: mood)
    }
}

/// Throttles the pet's per-tick scan of every session's messages.
///
/// `refresh()` runs on a 0.4s timer because busy/typing state must feel
/// immediate. The message previews it also computes do not: they walk every
/// runtime *and* every stored session and split message bodies, which is the
/// single most expensive thing on that timer. Recomputing them a fifth as
/// often keeps the cards fresh enough to read while removing four out of five
/// full scans.
enum DesktopPetOutputPreviewCadence {
    nonisolated static let refreshInterval: TimeInterval = 2

    nonisolated static func shouldRecompute(lastComputedAt: Date?, now: Date) -> Bool {
        guard let lastComputedAt else { return true }
        // A clock that moved backwards must not strand the cache forever.
        guard now >= lastComputedAt else { return true }
        return now.timeIntervalSince(lastComputedAt) >= refreshInterval
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

struct DesktopPetDragAnchor: Equatable {
    let mouseLocation: CGPoint
    let windowOrigin: CGPoint
}

enum DesktopPetDragPositioning {
    nonisolated static func windowOrigin(
        anchor: DesktopPetDragAnchor,
        currentMouseLocation: CGPoint
    ) -> CGPoint {
        CGPoint(
            x: anchor.windowOrigin.x + currentMouseLocation.x - anchor.mouseLocation.x,
            y: anchor.windowOrigin.y + currentMouseLocation.y - anchor.mouseLocation.y
        )
    }

    /// SwiftUI reports drag translation with a downward-positive y axis, while
    /// `NSEvent.mouseLocation` uses AppKit's upward-positive screen coordinates.
    nonisolated static func mouseDownLocation(
        currentMouseLocation: CGPoint,
        initialTranslation: CGSize
    ) -> CGPoint {
        CGPoint(
            x: currentMouseLocation.x - initialTranslation.width,
            y: currentMouseLocation.y + initialTranslation.height
        )
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
    @Published private(set) var appIsActive: Bool
    /// Mirrors the panel's `occlusionState`. Starts `false` because there is no
    /// window yet; `showIfNeeded()` seeds the real value once the panel exists.
    @Published private(set) var isWindowVisible = false

    private weak var appState: AppState?
    private var window: NSPanel?
    private var pollingTimer: Timer?
    private var appActivityCancellables = Set<AnyCancellable>()
    private var occlusionCancellable: AnyCancellable?
    private var wasBusy = false
    private var celebrationEndsAt: Date?
    private var jumpEndsAt: Date?
    private var nextAutomaticJumpAt: Date?
    private var hibernationEndsAt: Date?
    private var dragAnchor: DesktopPetDragAnchor?
    private var cachedOutputPreviews: [DesktopPetMessagePreview] = []
    private var outputPreviewsComputedAt: Date?

    private init() {
        // 默认开启桌面宠物:首次启动即陪伴,用户可随时在右键菜单 /
        // 设置里关闭(关闭状态会写回 UserDefaults,不会被这个默认值覆盖)。
        isEnabled = UserDefaults.standard.object(forKey: DefaultsKey.isEnabled) as? Bool ?? true
        appearance = UserDefaults.standard.string(forKey: DefaultsKey.appearance)
            .flatMap(DesktopPetAppearance.init(rawValue:)) ?? .robotFox
        appIsActive = NSApplication.shared.isActive
        observeApplicationActivity()
    }

    private func observeApplicationActivity() {
        let becameActive = NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .map { _ in true }
        let resignedActive = NotificationCenter.default
            .publisher(for: NSApplication.didResignActiveNotification)
            .map { _ in false }

        becameActive
            .merge(with: resignedActive)
            .sink { [weak self] isActive in
                Task { @MainActor [weak self] in
                    guard self?.updateApplicationActivity(isActive) == true else { return }
                    self?.refresh()
                }
            }
            .store(in: &appActivityCancellables)
    }

    @discardableResult
    private func updateApplicationActivity(_ isActive: Bool) -> Bool {
        guard appIsActive != isActive else { return false }
        appIsActive = isActive
        return true
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
        // 显式开关视为提前结束冬眠,避免"重新打开却看不见宠物"。
        hibernationEndsAt = nil
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: DefaultsKey.isEnabled)
        if enabled {
            scheduleNextAutomaticJump(after: Date())
            startPollingIfNeeded()
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
        let now = Date()
        jumpEndsAt = now.addingTimeInterval(DesktopPetAutonomy.jumpDuration)
        scheduleNextAutomaticJump(after: now)
        refresh()
    }

    /// 冬眠 5 分钟。
    func hibernate() {
        hibernate(until: Date().addingTimeInterval(DesktopPetHibernation.duration))
    }

    /// 冬眠到明天早上。
    func hibernateUntilTomorrow() {
        hibernate(until: DesktopPetHibernation.nextMorning(after: Date()))
    }

    /// 冬眠:窗口暂时隐藏,轮询照常跑,到点由下一次 refresh 自动唤醒。
    /// 与 `setEnabled(false)` 不同,不写 UserDefaults,重启 App 即恢复。
    private func hibernate(until endsAt: Date) {
        hibernationEndsAt = endsAt
        window?.orderOut(nil)
    }

    func beginDraggingPet(
        at mouseLocation: CGPoint,
        initialTranslation: CGSize
    ) {
        guard !isDraggingPet, let window else { return }
        let mouseDownLocation = DesktopPetDragPositioning.mouseDownLocation(
            currentMouseLocation: mouseLocation,
            initialTranslation: initialTranslation
        )
        dragAnchor = DesktopPetDragAnchor(
            mouseLocation: mouseDownLocation,
            windowOrigin: window.frame.origin
        )
        isDraggingPet = true
    }

    /// 以鼠标和窗口在按下时的全局坐标为锚点直接求当前位置。窗口移动
    /// 不会改变这个坐标基准，因此快速拖动时也不会累计误差或逐帧落后。
    func moveWindow(to mouseLocation: CGPoint) {
        guard let window, let dragAnchor else { return }
        let origin = DesktopPetDragPositioning.windowOrigin(
            anchor: dragAnchor,
            currentMouseLocation: mouseLocation
        )
        window.setFrameOrigin(origin)
    }

    func finishDraggingPet() {
        defer {
            dragAnchor = nil
            isDraggingPet = false
        }
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
        updateApplicationActivity(NSApplication.shared.isActive)
        let now = Date()
        if let hibernationEndsAt {
            guard !DesktopPetHibernation.isActive(endsAt: hibernationEndsAt, now: now) else { return }
            self.hibernationEndsAt = nil
            scheduleNextAutomaticJump(after: now)
            window?.orderFrontRegardless()
        }
        showIfNeeded()
        guard let appState else {
            updateAutomaticJump(at: now, isBusy: false)
            let isJumping = jumpIsActive(at: now)
            presentation = DesktopPetPresentation(
                sessionID: nil,
                sessionTitle: DesktopPetPresentation.empty.sessionTitle,
                message: DesktopPetPresentation.empty.message,
                messagePreviews: [],
                outputSessionCount: 0,
                isMessageBubbleVisible: false,
                status: DesktopPetPresentation.empty.status,
                mood: isJumping ? .jumping : .idle
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
        let outputPreviews = outputPreviews(from: appState, now: now)
        let shouldShowMessageCards = DesktopPetMessageCardVisibility.shouldShowMessageCards(
            appIsActive: appIsActive,
            outputSessionCount: outputPreviews.count
        )
        let visiblePreviews = Array(outputPreviews.prefix(Self.maximumVisibleOutputPreviews))
        let latestPreview = visiblePreviews.first
        let hasCelebration = celebrationEndsAt.map { $0 > now } ?? false
        let isUserTyping = !appState.agentInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        updateAutomaticJump(
            at: now,
            isBusy: isBusy || needsAttention || isUserTyping || hasCelebration
        )
        let isJumping = jumpIsActive(at: now)

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
            baseMood = .ready
            status = L10n.DesktopPet.statusReady
        } else {
            baseMood = .idle
            status = L10n.DesktopPet.statusIdle
        }

        let next = DesktopPetPresentation(
            sessionID: latestPreview?.sessionID ?? runtime?.id,
            sessionTitle: latestPreview?.sessionTitle
                ?? runtime.map { DesktopPetMessageFormatter.userInputLabel(for: $0.messages) }
                ?? L10n.DesktopPet.emptySessionTitle,
            message: latestPreview?.message ?? L10n.DesktopPet.emptyMessage,
            messagePreviews: visiblePreviews,
            outputSessionCount: outputPreviews.count,
            isMessageBubbleVisible: shouldShowMessageCards,
            status: status,
            mood: isJumping ? .jumping : baseMood
        )
        // @Published notifies even on same-value writes; this runs on a
        // 0.4s timer, so an unconditional write re-renders the overlay
        // 2.5×/s even when nothing changed.
        if next != presentation {
            presentation = next
        }
    }

    private func jumpIsActive(at date: Date) -> Bool {
        guard let jumpEndsAt else { return false }
        if jumpEndsAt > date { return true }
        self.jumpEndsAt = nil
        return false
    }

    private func updateAutomaticJump(at date: Date, isBusy: Bool) {
        guard !isBusy, !isDraggingPet else { return }
        guard let nextAutomaticJumpAt else {
            scheduleNextAutomaticJump(after: date)
            return
        }
        guard nextAutomaticJumpAt <= date, !jumpIsActive(at: date) else { return }
        jumpEndsAt = date.addingTimeInterval(DesktopPetAutonomy.jumpDuration)
        scheduleNextAutomaticJump(after: date)
    }

    private func scheduleNextAutomaticJump(after date: Date) {
        let delay = DesktopPetAutonomy.jumpDelay(unitInterval: Double.random(in: 0...1))
        nextAutomaticJumpAt = date.addingTimeInterval(delay)
    }

    /// Message previews on a slower beat than the rest of `refresh()`.
    ///
    /// The cache is keyed on nothing but time: `outputPreview` already gates on
    /// message freshness, so a preview that is up to `refreshInterval` stale
    /// still describes the same message. Going active clears it outright —
    /// previews are suppressed while the app is frontmost, and the next
    /// background tick must scan rather than serve an hours-old snapshot.
    private func outputPreviews(from appState: AppState, now: Date) -> [DesktopPetMessagePreview] {
        guard !appIsActive else {
            cachedOutputPreviews = []
            outputPreviewsComputedAt = nil
            return []
        }
        guard DesktopPetOutputPreviewCadence.shouldRecompute(
            lastComputedAt: outputPreviewsComputedAt,
            now: now
        ) else {
            return cachedOutputPreviews
        }
        let previews = Self.outputPreviews(from: appState, now: now)
        cachedOutputPreviews = previews
        outputPreviewsComputedAt = now
        return previews
    }

    private static let maximumVisibleOutputPreviews = 3

    private static func outputPreviews(from appState: AppState, now: Date) -> [DesktopPetMessagePreview] {
        var previewsByID: [AgentSession.ID: DesktopPetMessagePreview] = [:]

        for runtime in appState.agentRuntimes.values {
            if let preview = outputPreview(session: runtime.session, messages: runtime.messages, now: now) {
                previewsByID[runtime.id] = preview
            }
        }

        for session in appState.agentSessions where previewsByID[session.id] == nil {
            if let preview = outputPreview(session: session, messages: session.messages, now: now) {
                previewsByID[session.id] = preview
            }
        }

        return previewsByID.values.sorted { lhs, rhs in
            lhs.updatedAt > rhs.updatedAt
        }
    }

    private static func outputPreview(
        session: AgentSession,
        messages: [AgentMessage],
        now: Date
    ) -> DesktopPetMessagePreview? {
        guard session.archivedAt == nil else { return nil }
        // Freshness gate BEFORE any content work: this runs on a 0.4s
        // timer over every session, and makePreview splits the entire
        // message body. A stale latest message means everything earlier
        // is staler, so bail immediately.
        for message in messages.reversed() {
            guard message.role == .assistant else { continue }
            guard DesktopPetOutputFreshness.isFresh(updatedAt: message.createdAt, now: now) else {
                return nil
            }
            let preview = DesktopPetMessageFormatter.makePreview(message.content)
            guard !preview.isEmpty else { continue }
            return DesktopPetMessagePreview(
                sessionID: session.id,
                sessionTitle: DesktopPetMessageFormatter.userInputLabel(for: messages),
                message: preview,
                updatedAt: message.createdAt
            )
        }
        return nil
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
        observeOcclusion(of: panel)
    }

    /// Tracks whether the panel is actually on screen so the animation timeline
    /// can stop when nobody can see it. See `DesktopPetAnimationGate`.
    private func observeOcclusion(of panel: NSPanel) {
        occlusionCancellable = NotificationCenter.default
            .publisher(for: NSWindow.didChangeOcclusionStateNotification, object: panel)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateWindowVisibility()
                }
            }
        updateWindowVisibility()
    }

    private func updateWindowVisibility() {
        let visible = window?.occlusionState.contains(.visible) ?? false
        guard isWindowVisible != visible else { return }
        isWindowVisible = visible
        // Coming back on screen: the timeline was parked, so the pose and the
        // status card are both stale. Refresh once instead of waiting up to
        // 0.4s for the next poll tick.
        if visible {
            refresh()
        }
    }

    private func hide() {
        pollingTimer?.invalidate()
        pollingTimer = nil
        occlusionCancellable = nil
        isWindowVisible = false
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

    // 显式 init:私有的 @State 存储会把 memberwise init 降级成
    // private,跨文件(单测)构造需要这个。
    init(manager: DesktopPetWindowManager) {
        self.manager = manager
    }

    private var displayMood: DesktopPetMood {
        manager.isDraggingPet ? .walking : manager.presentation.mood
    }

    /// 窗口位置始终由全局鼠标坐标计算。宠物姿态可以保持柔和动画，
    /// 但窗口本身不参与插值，避免快速拖动时产生明显的滞后感。
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let mouseLocation = NSEvent.mouseLocation
                manager.beginDraggingPet(
                    at: mouseLocation,
                    initialTranslation: value.translation
                )
                manager.moveWindow(to: mouseLocation)
            }
            .onEnded { _ in
                manager.finishDraggingPet()
            }
    }

    var body: some View {
        HStack(alignment: .center, spacing: -4) {
            if manager.presentation.isMessageBubbleVisible {
                if manager.isMessageBubbleCollapsed {
                    collapsedMessageIndicator
                        .offset(x: 4)
                } else {
                    messageBubble
                }
            }

            petScene
                .accessibilityLabel(L10n.DesktopPet.accessibilityLabel)
        }
        .frame(width: 360, height: 260, alignment: .bottomTrailing)
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .contextMenu {
            Button(L10n.DesktopPet.settingsAction) {
                manager.openSettings()
            }
            Button(L10n.DesktopPet.hibernateAction) {
                manager.hibernate()
            }
            Button(L10n.DesktopPet.hibernateUntilTomorrowAction) {
                manager.hibernateUntilTomorrow()
            }
            Button(L10n.DesktopPet.hideAction) {
                manager.setEnabled(false)
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

    private var petScene: some View {
        DesktopPetAnimatedSceneView(
            appearance: manager.appearance,
            mood: displayMood,
            appIsActive: manager.appIsActive,
            isAnimating: DesktopPetAnimationGate.shouldAnimate(
                isEnabled: manager.isEnabled,
                isWindowVisible: manager.isWindowVisible,
                mood: displayMood
            )
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
        case .celebrating, .ready:
            return .cyan
        case .idle:
            return .secondary
        }
    }
}

/// Owns the high-frequency timeline so status cards, menus, gestures, and the
/// hosting window's outer layout remain stable between animation frames.
struct DesktopPetAnimatedSceneView: View {
    let appearance: DesktopPetAppearance
    let mood: DesktopPetMood
    let appIsActive: Bool
    let isAnimating: Bool

    /// Pose held while the timeline is parked. A fixed instant keeps the
    /// subtree's geometry constant, so an off-screen pet stops driving the
    /// app-wide display cycle entirely rather than merely ticking slower.
    private static let parkedInstant = Date(timeIntervalSinceReferenceDate: 0)

    var body: some View {
        if isAnimating {
            TimelineView(.animation(
                minimumInterval: DesktopPetAnimationCadence.minimumInterval(
                    appIsActive: appIsActive
                )
            )) { context in
                scene(at: context.date)
            }
        } else {
            scene(at: Self.parkedInstant)
        }
    }

    private func scene(at date: Date) -> some View {
        DesktopPetSceneView(
            appearance: appearance,
            animation: DesktopPetAnimationValues(
                mood: mood,
                date: date
            )
        )
    }
}

struct DesktopPetSceneView: View {
    private enum Layout {
        static let sceneWidth: CGFloat = 140
        static let sceneHeight: CGFloat = 148
        static let petSize: CGFloat = 132
        static let softHeartPrimary = Color(red: 1, green: 0.4, blue: 0.46)
        static let softHeartSecondary = Color(red: 1, green: 0.57, blue: 0.68)
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
                .offset(
                    x: animation.horizontalOffset,
                    y: animation.verticalOffset
                )
                .shadow(color: .black.opacity(0.24), radius: 7, y: 5)
        }
        .frame(
            width: Layout.sceneWidth,
            height: Layout.sceneHeight,
            alignment: .bottom
        )
    }

    private var cuteEffectLayer: some View {
        ZStack {
            if let plan = animation.ambientEffectPlan {
                ForEach(0..<plan.particleCount, id: \.self) { index in
                    ambientParticle(plan: plan, index: index)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func ambientParticle(plan: DesktopPetAmbientEffectPlan, index: Int) -> some View {
        let progress = plan.particleProgress(at: index)
        let envelope = sin(progress * .pi)
        let scale = 0.18 + envelope * (0.95 + plan.unitValue(particle: index, salt: 17) * 0.35)
        let horizontal = -48 + plan.unitValue(particle: index, salt: 31) * 96
        let initialHeight = 62 + plan.unitValue(particle: index, salt: 47) * 34
        let rise = progress * (24 + plan.unitValue(particle: index, salt: 59) * 26)
        let drift = sin(progress * .pi * 2 + Double(index)) * 7

        return effectSymbol(kind: plan.kind, index: index)
            .scaleEffect(scale)
            .rotationEffect(.degrees((plan.unitValue(particle: index, salt: 71) - 0.5) * 24))
            .offset(x: horizontal + drift, y: -(initialHeight + rise))
            .opacity(envelope)
    }

    @ViewBuilder
    private func effectSymbol(kind: DesktopPetAmbientEffectKind, index: Int) -> some View {
        switch kind {
        case .lips:
            Image(systemName: "mouth.fill")
                .font(.system(size: index == 0 ? 24 : 19, weight: .bold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.red)
        case .stars:
            Image(systemName: index.isMultiple(of: 2) ? "star.fill" : "sparkles")
                .font(.system(size: index.isMultiple(of: 2) ? 21 : 24, weight: .bold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(index.isMultiple(of: 2) ? Color.yellow : Color.mint)
        case .hearts:
            Image(systemName: "heart.fill")
                .font(.system(size: index.isMultiple(of: 2) ? 21 : 17, weight: .bold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(
                    index.isMultiple(of: 2)
                        ? Layout.softHeartPrimary
                        : Layout.softHeartSecondary
                )
        case .bubbles:
            Circle()
                .strokeBorder(index.isMultiple(of: 2) ? Color.cyan : Color.white, lineWidth: 2)
                .background(Circle().fill(Color.cyan.opacity(0.12)))
                .frame(width: index.isMultiple(of: 2) ? 22 : 15, height: index.isMultiple(of: 2) ? 22 : 15)
        }
    }
}

struct DesktopPetAnimationValues {
    private static let walkingSwayRate = 0.85
    private static let walkingStepRate = 2.2
    private static let ambientCycleDuration = 8.0
    private static let ambientEffectStart = 3.8
    private static let ambientEffectDuration = 2.8
    private static let typingStrokeRate = 13.2

    let horizontalOffset: CGFloat
    let verticalOffset: CGFloat
    let rotation: Double
    let scale: CGFloat
    let horizontalScale: CGFloat
    let verticalScale: CGFloat
    let facesRight: Bool
    let ambientEffectPlan: DesktopPetAmbientEffectPlan?

    init(mood: DesktopPetMood, date: Date) {
        let t = date.timeIntervalSinceReferenceDate
        var horizontalOffset: CGFloat = 0
        var verticalOffset: CGFloat = 0
        var rotation = 0.0
        var scale: CGFloat = 1
        var horizontalScale: CGFloat = 1
        var verticalScale: CGFloat = 1
        var facesRight = true
        var ambientEffectPlan: DesktopPetAmbientEffectPlan?

        switch mood {
        case .idle, .ready:
            let breathing = CGFloat(sin(t * 2.1))
            let cycleIndex = Int(floor(t / Self.ambientCycleDuration))
            let cycleTime = t - Double(cycleIndex) * Self.ambientCycleDuration
            let isPerformingCuteAction = cycleTime >= Self.ambientEffectStart
                && cycleTime <= Self.ambientEffectStart + Self.ambientEffectDuration
            let cuteProgress = isPerformingCuteAction
                ? (cycleTime - Self.ambientEffectStart) / Self.ambientEffectDuration
                : 0
            let cuteEnvelope = CGFloat(sin(cuteProgress * .pi))
            let cuteWiggle = CGFloat(sin(cuteProgress * .pi * 4))

            horizontalOffset = cuteEnvelope * cuteWiggle * 3
            verticalOffset = breathing * 2 - cuteEnvelope * (3 + abs(cuteWiggle) * 3)
            rotation = Double(breathing * 1.5 + cuteEnvelope * (4 + cuteWiggle * 3))
            horizontalScale = 1 + cuteEnvelope * 0.035
            verticalScale = 1 - cuteEnvelope * 0.025
            if isPerformingCuteAction {
                ambientEffectPlan = .make(cycleIndex: cycleIndex, progress: cuteProgress)
            }
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
        case .jumping:
            horizontalOffset = CGFloat(sin(t * 1.3)) * 4
            let jump = CGFloat(abs(sin(t * 3.5)))
            verticalOffset = -jump * 18
            rotation = sin(t * 3.5) * 7
            horizontalScale = 1 + jump * 0.04
            verticalScale = 1 - jump * 0.03
        case .attention:
            horizontalOffset = CGFloat(sin(t * 12)) * 5
            rotation = sin(t * 12) * 4
        case .celebrating:
            horizontalOffset = CGFloat(sin(t * 7)) * 9
            verticalOffset = -CGFloat(abs(sin(t * 3.8))) * 14
            rotation = sin(t * 7) * 10
            scale = 1.04
            let cycleIndex = Int(floor(t / Self.ambientCycleDuration))
            let progress = (sin(t * 2.4) + 1) / 2
            ambientEffectPlan = .make(cycleIndex: cycleIndex, progress: progress)
        }

        self.horizontalOffset = horizontalOffset
        self.verticalOffset = verticalOffset
        self.rotation = rotation
        self.scale = scale
        self.horizontalScale = horizontalScale
        self.verticalScale = verticalScale
        self.facesRight = facesRight
        self.ambientEffectPlan = ambientEffectPlan
    }
}
