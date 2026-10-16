import SwiftUI
import AppKit
import Combine

@MainActor enum AgentWorkspaceSection: String, CaseIterable, Identifiable {
    case library, experiments
    var id: String { rawValue }
    var title: String {
        switch self {
        case .library: String(localized: "智能体库", table: "AgentWorkspace")
        case .experiments: String(localized: "RSI 实验", table: "AgentWorkspace")
        }
    }
    var symbol: String { self == .library ? "square.grid.2x2" : "flask" }
}

@MainActor final class AgentWorkspaceNavigation: ObservableObject {
    static let shared = AgentWorkspaceNavigation()
    @Published var section: AgentWorkspaceSection = .library
    @Published var baseline: AgentPackageV1?
    @Published var pending: AgentWorkspaceTransition?
    @Published private(set) var accountEpoch = UUID()
    @Published var closeIntent = AgentWorkspaceCloseIntent()
    var closeWorkspaceWindow: ((UUID) -> Void)?
    var dirtySections: Set<AgentWorkspaceSection> = []
    private var accountChanges: AnyCancellable?
    init() {
        accountChanges = NotificationCenter.default.publisher(for: SomeIMIntegrationStore.sessionDidChangeNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.accountChanged() } }
    }
    func select(_ section: AgentWorkspaceSection, baseline: AgentPackageV1? = nil) {
        let target = AgentWorkspaceTransition(section: section, baseline: baseline ?? self.baseline)
        guard section != self.section || target.baseline?.sha256 != self.baseline?.sha256 else { return }
        if dirtySections.contains(self.section) { pending = target; return }
        apply(target)
    }
    func discardAndContinue() {
        guard let pending else { return }
        dirtySections.remove(section); apply(pending)
    }
    func accountChanged() {
        accountEpoch = UUID()
        closeIntent.continueEditing()
        baseline = nil; pending = nil; dirtySections.removeAll()
    }
    func discardAndClose(requestID: UUID) {
        guard closeIntent.confirmDiscard(requestID: requestID) else { return }
        guard let closeWorkspaceWindow else { closeIntent.abandonApprovedClose(requestID); return }
        closeWorkspaceWindow(requestID)
    }
    func didLoadCandidateBaseline(_ package: AgentPackageV1) {
        baseline = package
    }
    private func apply(_ target: AgentWorkspaceTransition) {
        baseline = target.baseline; section = target.section; pending = nil
    }
}

struct AgentWorkspaceTransition: Identifiable {
    let id = UUID()
    let section: AgentWorkspaceSection
    let baseline: AgentPackageV1?
}

enum AgentWorkspaceWindowID { static let value = "agent-workspace" }

@MainActor struct AgentWorkspaceSceneRoot: View {
    @ObservedObject private var registry = EditorAppStateRegistry.shared
    var body: some View {
        Group {
            if let appState = registry.current {
                AgentWorkspaceLiveRoot(appState: appState)
            } else { ProgressView() }
        }.onAppear { registry.ensureHeadlessFallback() }
    }
}

private struct AgentWorkspaceLiveRoot: View {
    @ObservedObject var appState: AppState
    var body: some View { AgentWorkspaceView(providerEntries: appState.agentProviderLibrary.entries) }
}

/// Main-window companion, deliberately independent from Settings sheets.
struct AgentWorkspaceView: View {
    @ObservedObject private var navigation = AgentWorkspaceNavigation.shared
    private let library: AgentDefinitionLibrary
    private let rsiRoot: URL?
    private let preview: Bool
    private let providerEntries: [AgentProviderEntry]
    init(library: AgentDefinitionLibrary = AgentDefinitionLibrary(), rsiRoot: URL? = nil, preview: Bool = false, providerEntries: [AgentProviderEntry] = []) {
        self.library = library; self.rsiRoot = rsiRoot; self.preview = preview; self.providerEntries = providerEntries
    }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 9) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 32, height: 32)
                    Text("WillDeep").font(.system(size: 22, weight: .bold))
                }.padding(.top, 26).padding(.bottom, 14)
                Text(String(localized: "智能体工作区", table: "AgentWorkspace")).font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
                VStack(spacing: 6) {
                    ForEach(AgentWorkspaceSection.allCases) { section in
                        Button { navigation.select(section) } label: {
                            Label(section.title, systemImage: section.symbol)
                                .font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14).padding(.vertical, 12)
                                .foregroundStyle(navigation.section == section ? Color.blue : Color.primary)
                                .background(navigation.section == section ? Color.blue.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain).accessibilityIdentifier("agent-workspace-" + section.rawValue)
                    }
                }
                Spacer()
                Label(String(localized: "离线验证，不调用付费模型", table: "AgentWorkspace"), systemImage: "checkmark.shield")
                    .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(.horizontal, 18).padding(.bottom, 24).frame(width: 218)
                .background(Color(red: 0.955, green: 0.965, blue: 0.98))
            Divider()
            Group {
                switch navigation.section {
                case .library:
                    AgentRegistrySettingsView(library: library, embedded: true, allowsRemote: !preview, providerEntries: providerEntries) { package in
                        navigation.select(.experiments, baseline: package)
                    }
                case .experiments:
                    AgentRSIExperimentsView(baseline: navigation.baseline, library: library, root: rsiRoot, embedded: true, allowsRemote: !preview)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(minWidth: 1120, minHeight: 760)
            .background(Color(red: 0.975, green: 0.982, blue: 0.992))
            .font(.system(size: 15)).tint(.blue).preferredColorScheme(.light)
            .disabled(navigation.closeIntent.approvedRequestID != nil)
            .background(AgentWorkspaceWindowCloseGuard(navigation: navigation).frame(width: 0, height: 0))
            .confirmationDialog(String(localized: "有尚未保存的修改", table: "AgentWorkspace"), isPresented: Binding(
                get: { navigation.closeIntent.requiresConfirmation },
                set: { if !$0 { navigation.closeIntent.dismissPresentation() } })) {
                    if let requestID = navigation.closeIntent.requestID {
                        Button(String(localized: "放弃修改并关闭", table: "AgentWorkspace"), role: .destructive) { navigation.discardAndClose(requestID: requestID) }
                    }
                    Button(String(localized: "继续编辑", table: "AgentWorkspace"), role: .cancel) { navigation.closeIntent.continueEditing() }
                } message: { Text(String(localized: "先保存当前修改，或明确放弃后关闭工作区。", table: "AgentWorkspace")) }
            .confirmationDialog(String(localized: "有尚未保存的修改", table: "AgentWorkspace"), isPresented: Binding(
                get: { navigation.pending != nil }, set: { if !$0 { navigation.pending = nil } })) {
                Button(String(localized: "放弃修改并继续", table: "AgentWorkspace"), role: .destructive) { navigation.discardAndContinue() }
                Button(String(localized: "继续编辑", table: "AgentWorkspace"), role: .cancel) { navigation.pending = nil }
            } message: { Text(String(localized: "先保存当前修改，或明确放弃后切换。", table: "AgentWorkspace")) }
    }
}

struct AgentWorkspaceCard<Content: View>: View {
    let highlighted: Bool
    let content: Content
    init(highlighted: Bool = false, @ViewBuilder content: () -> Content) {
        self.highlighted = highlighted; self.content = content()
    }
    var body: some View {
        content.padding(16).frame(maxWidth: .infinity, alignment: .topLeading)
            .background(.white, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(highlighted ? Color.blue : Color.gray.opacity(0.18), lineWidth: 1))
    }
}
