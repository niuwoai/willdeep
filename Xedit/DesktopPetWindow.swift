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

struct DesktopPetPresentation: Equatable {
    let sessionID: AgentSession.ID?
    let sessionTitle: String
    let message: String
    let status: String
    let mood: DesktopPetMood

    static let empty = DesktopPetPresentation(
        sessionID: nil,
        sessionTitle: L10n.DesktopPet.emptySessionTitle,
        message: L10n.DesktopPet.emptyMessage,
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

@MainActor
final class DesktopPetWindowManager: ObservableObject {
    static let shared = DesktopPetWindowManager()

    private enum DefaultsKey {
        static let isEnabled = "com.willdeep.desktop-pet.enabled.v1"
        static let appearance = "com.willdeep.desktop-pet.appearance.v1"
    }

    @Published private(set) var presentation = DesktopPetPresentation.empty
    @Published private(set) var isEnabled: Bool
    @Published private(set) var appearance: DesktopPetAppearance

    private weak var appState: AppState?
    private var window: NSPanel?
    private var pollingTimer: Timer?
    private var wasBusy = false
    private var celebrationEndsAt: Date?

    private init() {
        isEnabled = UserDefaults.standard.object(forKey: DefaultsKey.isEnabled) as? Bool ?? false
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
        guard let sessionID = presentation.sessionID else { return }
        AgentNotificationResponder.reveal(runtimeID: sessionID)
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

        guard let appState else {
            presentation = .empty
            return
        }

        let runtime = appState.activeRuntime
        let isBusy = runtime?.isResponding == true || runtime?.isAwaitingProviderSlot == true
        if wasBusy && !isBusy {
            celebrationEndsAt = Date().addingTimeInterval(6)
        }
        wasBusy = isBusy

        let needsAttention = runtime?.toolCalls.contains { $0.status.isBlockingForUserDecision } == true
        let isRunningTool = runtime?.toolCalls.contains { $0.status == .running } == true
        let latestMessage = runtime?.messages.reversed().first(where: Self.isVisibleConversationMessage)
        let latestContent = latestMessage.map { DesktopPetMessageFormatter.makePreview($0.content) }
        let hasCelebration = celebrationEndsAt.map { $0 > Date() } ?? false

        let mood: DesktopPetMood
        let status: String
        if needsAttention {
            mood = .attention
            status = L10n.DesktopPet.statusNeedsAttention
        } else if isBusy, isRunningTool {
            mood = .walking
            status = L10n.DesktopPet.statusWorking
        } else if isBusy {
            mood = .jumping
            status = L10n.DesktopPet.statusThinking
        } else if hasCelebration {
            mood = .celebrating
            status = L10n.DesktopPet.statusComplete
        } else if latestMessage?.role == .assistant {
            mood = .spinning
            status = L10n.DesktopPet.statusReady
        } else {
            mood = .idle
            status = L10n.DesktopPet.statusIdle
        }

        presentation = DesktopPetPresentation(
            sessionID: runtime?.id,
            sessionTitle: runtime?.session.title ?? L10n.DesktopPet.emptySessionTitle,
            message: latestContent?.isEmpty == false ? latestContent! : L10n.DesktopPet.emptyMessage,
            status: status,
            mood: mood
        )
    }

    private static func isVisibleConversationMessage(_ message: AgentMessage) -> Bool {
        guard !DesktopPetMessageFormatter.makePreview(message.content).isEmpty else { return false }
        switch message.role {
        case .user, .assistant:
            return true
        default:
            return false
        }
    }

    private func showIfNeeded() {
        guard window == nil else { return }

        let size = NSSize(width: 360, height: 190)
        let host = NSHostingView(rootView: DesktopPetOverlayView(manager: self))
        host.frame = NSRect(origin: .zero, size: size)

        let panel = NSPanel(
            contentRect: Self.defaultFrame(for: size),
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

    var body: some View {
        TimelineView(.animation) { context in
            let animation = DesktopPetAnimationValues(
                mood: manager.presentation.mood,
                date: context.date
            )

            HStack(alignment: .bottom, spacing: -4) {
                Button(action: manager.openCurrentSession) {
                    messageBubble
                }
                .buttonStyle(.plain)
                .disabled(manager.presentation.sessionID == nil)

                petImage(animation: animation)
                    .accessibilityLabel(L10n.DesktopPet.accessibilityLabel)
            }
            .frame(width: 360, height: 190, alignment: .bottomTrailing)
            .contentShape(Rectangle())
            .contextMenu {
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
            }

            Text(manager.presentation.message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)

            Text(manager.presentation.sessionTitle)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
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

    private func petImage(animation: DesktopPetAnimationValues) -> some View {
        Image(manager.appearance.assetName)
            .resizable()
            .interpolation(.none)
            .scaledToFit()
            .frame(width: 132, height: 132)
            .scaleEffect(x: animation.facesRight ? 1 : -1, y: animation.scale)
            .rotationEffect(.degrees(animation.rotation))
            .offset(x: animation.horizontalOffset, y: animation.verticalOffset)
            .shadow(color: .black.opacity(0.24), radius: 7, y: 5)
    }

    private var statusColor: Color {
        switch manager.presentation.mood {
        case .attention:
            return .orange
        case .walking, .jumping:
            return .mint
        case .celebrating, .spinning:
            return .cyan
        case .idle:
            return .secondary
        }
    }
}

private struct DesktopPetAnimationValues {
    let horizontalOffset: CGFloat
    let verticalOffset: CGFloat
    let rotation: Double
    let scale: CGFloat
    let facesRight: Bool

    init(mood: DesktopPetMood, date: Date) {
        let t = date.timeIntervalSinceReferenceDate
        switch mood {
        case .idle:
            horizontalOffset = 0
            verticalOffset = CGFloat(sin(t * 2.1)) * 2
            rotation = CGFloat(sin(t * 1.4)) * 1.5
            scale = 1
            facesRight = true
        case .walking:
            horizontalOffset = CGFloat(sin(t * 2.0)) * 11
            verticalOffset = CGFloat(abs(sin(t * 5.6))) * 4
            rotation = CGFloat(sin(t * 5.6)) * 3
            scale = 1
            facesRight = sin(t * 2.0) >= 0
        case .jumping:
            horizontalOffset = CGFloat(sin(t * 1.3)) * 4
            verticalOffset = CGFloat(abs(sin(t * 3.5))) * 18
            rotation = CGFloat(sin(t * 3.5)) * 7
            scale = 1
            facesRight = true
        case .spinning:
            horizontalOffset = 0
            verticalOffset = CGFloat(sin(t * 2.4)) * 3
            rotation = (t * 135).truncatingRemainder(dividingBy: 360)
            scale = 0.96 + CGFloat(sin(t * 4.8)) * 0.04
            facesRight = true
        case .attention:
            horizontalOffset = CGFloat(sin(t * 12)) * 5
            verticalOffset = 0
            rotation = CGFloat(sin(t * 12)) * 4
            scale = 1
            facesRight = true
        case .celebrating:
            horizontalOffset = CGFloat(sin(t * 7)) * 9
            verticalOffset = CGFloat(abs(sin(t * 3.8))) * 14
            rotation = CGFloat(sin(t * 7)) * 10
            scale = 1.04
            facesRight = true
        }
    }
}
