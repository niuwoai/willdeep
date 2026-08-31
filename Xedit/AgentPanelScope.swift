import SwiftUI

private struct AgentPanelScopeKey: EnvironmentKey {
    static let defaultValue: AgentPanelScope? = nil
}

extension EnvironmentValues {
    var agentPanelScope: AgentPanelScope? {
        get { self[AgentPanelScopeKey.self] }
        set { self[AgentPanelScopeKey.self] = newValue }
    }
}

/// Captures a panel's owner once; opening another chat must not retarget a window.
@MainActor
struct AgentPanelScope {
    let appState: AppState
    let runtime: AgentRuntime?
    var tabID: UUID?

    var sessionID: UUID? { runtime?.id }
    var workspaceRoot: URL? { runtime?.workspaceRootPath.map { URL(fileURLWithPath: $0) } }
    var selectedFile: URL? {
        get {
            if let tabID { return runtime?.sidePanelState.openTabs.first { $0.id == tabID }?.file }
            return appState.agentSidePanelSelectedFile
        }
        nonmutating set {
            guard let runtime, let tabID else { appState.agentSidePanelSelectedFile = newValue; return }
            appState.updatePanelTabs(runtime: runtime) { $0.updateTabFile(newValue, tabID: tabID) }
        }
    }

    var input: String {
        get { runtime?.input ?? appState.agentInput }
        nonmutating set { if let runtime { runtime.input = newValue } else { appState.agentInput = newValue } }
    }

    var request: AgentSidePanelOpenRequest? {
        get { appState.activeAgentSessionID == sessionID ? appState.agentSidePanelRequest : nil }
        nonmutating set {
            guard let request = newValue else { return }
            if request.kind == .mediaTasks { mediaScope = request.mediaTaskScope }
            appState.openPanelTab(request.kind, file: request.file, runtime: runtime, exactFile: request.file != nil)
            if appState.activeAgentSessionID == sessionID { appState.agentSidePanelRequest = request }
        }
    }

    var kind: AgentSidePanelKind? {
        get { runtime?.sidePanelState.kind }
        nonmutating set { if let newValue { appState.openPanelTab(newValue, runtime: runtime) } }
    }

    func inspectJob(_ job: AgentBackgroundJob) {
        let prompt = L10n.AgentJobs.inspectOutputPrompt(job.displayHandle)
        if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { input = prompt }
        else if !input.contains(job.displayHandle) { input += "\n\n" + prompt }
        appState.agentComposerFocusRevision += 1
    }

    var mediaScope: AgentMediaTaskScope? {
        get { runtime?.sidePanelState.mediaTaskScope }
        nonmutating set {
            guard let runtime else { return }
            appState.updatePanelTabs(runtime: runtime) { $0.mediaTaskScope = newValue }
            if appState.activeAgentSessionID == runtime.id { appState.agentMediaTaskPanelScope = newValue }
        }
    }

    var imageURL: URL? {
        get { runtime?.sidePanelState.imageEditorImagePath.map { URL(fileURLWithPath: $0) } }
        nonmutating set { updateImageState { $0.imageEditorImagePath = newValue?.path } }
    }
    var maskURL: URL? {
        get { runtime?.sidePanelState.imageEditorMaskPath.map { URL(fileURLWithPath: $0) } }
        nonmutating set { updateImageState { $0.imageEditorMaskPath = newValue?.path } }
    }
    var imageOperation: AgentImageEditorOperationPreference? {
        get { runtime?.sidePanelState.imageEditorPreferredOperation }
        nonmutating set { updateImageState { $0.imageEditorPreferredOperation = newValue } }
    }
    var imageContext: AgentImageEditorContext? {
        get { runtime?.sidePanelState.imageEditorContext }
        nonmutating set { updateImageState { $0.imageEditorContext = newValue } }
    }
    private func updateImageState(_ mutate: (inout AgentSidePanelState) -> Void) {
        guard let runtime else { return }
        appState.updatePanelTabs(runtime: runtime, mutate)
        if appState.activeAgentSessionID == runtime.id { appState.restoreAgentSidePanelGlobals(from: runtime) }
    }
}

/// Shared retained root for both the dock and a native window. Its SwiftUI
/// identity is not recreated when the AppKit hosting view changes parent.
struct AgentPanelTabContent: View {
    @ObservedObject var appState: AppState
    @ObservedObject var runtime: AgentRuntime
    let tabID: UUID

    private var scope: AgentPanelScope { AgentPanelScope(appState: appState, runtime: runtime, tabID: tabID) }
    private var tab: AgentPanelTab? { runtime.sidePanelState.openTabs.first { $0.id == tabID } }

    var body: some View {
        GeometryReader { proxy in
            if let tab {
                AgentSidePanelKindContent(
                    kind: tab.kind,
                    kindSelection: Binding(get: { tab.kind }, set: {
                        if let kind = $0 { appState.openPanelTab(kind, file: scope.selectedFile, runtime: runtime, exactFile: true) }
                    }),
                    selectedFile: Binding(get: { scope.selectedFile }, set: { scope.selectedFile = $0 }),
                    layoutWidth: proxy.size.width
                )
                .environmentObject(appState)
                .environment(\.agentPanelScope, scope)
                .tint(appState.editorSettings.interfaceSkin.palette.accent)
                .preferredColorScheme(appState.editorSettings.interfaceSkin.preferredColorScheme)
            }
        }
        .background(appState.editorSettings.interfaceSkin.palette.panelFill)
    }
}
