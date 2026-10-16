import SwiftUI

/// Only compiled as the entry point of the explicit QA build. No production
/// AppDelegate, AppState, session restoration, scheduler or provider discovery.
#if AGENT_WORKSPACE_PREVIEW && DEBUG
@main struct AgentWorkspacePreviewApp: App {
    private let fixture: AgentWorkspacePreviewFixture
    init() {
        do {
            guard let path = ProcessInfo.processInfo.environment["WILLDEEP_AGENT_WORKSPACE_PREVIEW_ROOT"], path.hasPrefix("/private/tmp/") else {
                throw AgentRSIError.invalidContract
            }
            fixture = try AgentWorkspacePreviewFixture(root: URL(fileURLWithPath: path))
            AgentWorkspaceNavigation.shared.select(.experiments, baseline: fixture.baseline)
        } catch { fatalError("Isolated workspace preview initialization failed: \(error.localizedDescription)") }
    }
    var body: some Scene {
        Window(String(localized: "智能体工作区", table: "AgentWorkspace"), id: AgentWorkspaceWindowID.value) {
            AgentWorkspaceView(library: fixture.library, rsiRoot: fixture.rsiRoot, preview: true)
        }.defaultSize(width: 1380, height: 900)
    }
}
#endif

#if DEBUG
@MainActor struct AgentWorkspacePreviewFixture {
    let library: AgentDefinitionLibrary
    let rsiRoot: URL
    let baseline: AgentPackageV1
    init(root: URL) throws {
        let defaults = UserDefaults(suiteName: "com.willdeep.workspace-preview." + AgentPackageV1.hash(Data(root.path.utf8)))!
        library = AgentDefinitionLibrary(root: root.appendingPathComponent("registry"), defaults: defaults)
        library.activate(account: nil)
        rsiRoot = root.appendingPathComponent("rsi")
        baseline = try AgentPackageV1.unsigned(AgentDefinitionV1(schema: AgentDefinitionV1.schemaID,
            definition_id: "user/workspace-preview-document-review", version: "1.0.0-rc1",
            name: ["zh-Hans": "文档整理助手", "en": "Document review assistant"], purpose: "Inspect documents and report evidence.",
            base_role: "reviewer", instructions: "1. 阅读并理解用户提供的文档内容。\n2. 按主题组织核心要点，生成清晰的结构化摘要。\n3. 尽量保留重要的引用信息。\n4. 对于不确定或缺少上下文的内容，给出合理的提示。\n5. 以简洁、专业的语言输出结果。",
            input_modalities: ["text"], tools: ["workspace.read", "repository.inspect"], skills: [], forked_from: nil))
        _ = try library.install(baseline, source: .local)
    }
}
#endif
