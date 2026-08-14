import Foundation
import Testing
@testable import WillDeep

/// composer 上方那枚分支胶囊读 `agentWorkspaceGitStatus.branchName`。分支可以在
/// **路径不变**的情况下被换掉（Agent 跑 `git switch`、内置终端、外部终端），过去
/// 这些场合没有任何刷新入口，胶囊会一直显示旧分支。这里守住补录逻辑的边界。
struct AgentComposerBranchPillTests {
    @Test("同一个 workspace 换分支后，分支胶囊跟着更新")
    @MainActor
    func adoptsNewBranchForActiveWorkspace() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_branch_pill_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let appState = AppState(rootDirectory: workspace)
        let workspacePath = workspace.standardizedFileURL.path
        appState.agentWorkspaceGitStatus = GitRepositoryStatus(
            repositoryRoot: workspace,
            branchName: "develop",
            entries: [:]
        )

        appState.applyAgentWorkspaceGitIdentity(
            from: GitRepositoryStatus(
                repositoryRoot: workspace,
                branchName: "agent/golang-sdk-request-id-docs",
                entries: ["main.go": .modified]
            ),
            workspacePath: workspacePath
        )

        #expect(appState.agentWorkspaceGitStatus.branchName == "agent/golang-sdk-request-id-docs")
        // 身份视图只承载 root + 分支，不该把逐文件状态灌进来。
        #expect(appState.agentWorkspaceGitStatus.entries.isEmpty)
        #expect(appState.agentWorkspaceGitStatus.isRepository)
    }

    @Test("别的 workspace 的 git 快照不得改写当前分支胶囊")
    @MainActor
    func ignoresSnapshotFromOtherWorkspace() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_branch_pill_active_\(UUID().uuidString)", isDirectory: true)
        let other = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_branch_pill_other_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: other)
        }

        let appState = AppState(rootDirectory: workspace)
        appState.agentWorkspaceGitStatus = GitRepositoryStatus(
            repositoryRoot: workspace,
            branchName: "develop",
            entries: [:]
        )

        appState.applyAgentWorkspaceGitIdentity(
            from: GitRepositoryStatus(
                repositoryRoot: other,
                branchName: "codex/some-other-branch",
                entries: [:]
            ),
            workspacePath: other.standardizedFileURL.path
        )

        #expect(appState.agentWorkspaceGitStatus.branchName == "develop")
        #expect(appState.agentWorkspaceGitStatus.repositoryRoot == workspace)
    }
}
