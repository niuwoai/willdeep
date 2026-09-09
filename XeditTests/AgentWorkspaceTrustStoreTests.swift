import Foundation
import Testing
@testable import WillDeep

/// 文件夹信任是"脚本能不能脱沙箱"的唯一开关，所以它的默认值必须是拒绝：
/// 没问过等于不信任，问过的两种答案都要留痕，不能只记"信任"那一半。
@Suite(.serialized)
struct AgentWorkspaceTrustStoreTests {
    private func withStore(_ body: (URL) throws -> Void) throws {
        let defaults = try #require(UserDefaults(suiteName: "willdeep-workspace-trust-\(UUID().uuidString)"))
        AgentWorkspaceTrustStore._setTestDefaultsOverride(defaults)
        defer { AgentWorkspaceTrustStore._setTestDefaultsOverride(nil) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    @Test("没问过的文件夹是 unknown，不是信任")
    func unansweredIsNotTrusted() throws {
        try withStore { root in
            #expect(AgentWorkspaceTrustStore.trust(for: root) == .unknown)
            #expect(!AgentWorkspaceTrustStore.isTrusted(root))
        }
    }

    @Test("两种答案都留痕，且覆盖整棵子树")
    func bothAnswersArePersistedAndCoverTheSubtree() throws {
        try withStore { root in
            let project = root.appendingPathComponent("project")
            let nested = project.appendingPathComponent("scripts/deep")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

            AgentWorkspaceTrustStore.record(true, for: project)
            #expect(AgentWorkspaceTrustStore.trust(for: project) == .trusted)
            #expect(AgentWorkspaceTrustStore.trust(for: nested) == .trusted)
            // 兄弟目录不沾光。
            #expect(AgentWorkspaceTrustStore.trust(for: root.appendingPathComponent("other")) == .unknown)

            let declined = root.appendingPathComponent("declined")
            try FileManager.default.createDirectory(at: declined, withIntermediateDirectories: true)
            AgentWorkspaceTrustStore.record(false, for: declined)
            #expect(AgentWorkspaceTrustStore.trust(for: declined) == .untrusted)
        }
    }

    @Test("最具体的那条记录说了算，重答只替换不叠加")
    func mostSpecificRecordWinsAndAnswersReplace() throws {
        try withStore { root in
            let inner = root.appendingPathComponent("vendor")
            try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
            AgentWorkspaceTrustStore.record(true, for: root)
            AgentWorkspaceTrustStore.record(false, for: inner)
            #expect(AgentWorkspaceTrustStore.trust(for: root) == .trusted)
            #expect(AgentWorkspaceTrustStore.trust(for: inner) == .untrusted)

            AgentWorkspaceTrustStore.record(true, for: inner)
            #expect(AgentWorkspaceTrustStore.trust(for: inner) == .trusted)
            #expect(AgentWorkspaceTrustStore.records().filter {
                $0.path == AgentWorkspaceTrustStore.normalizedPath(for: inner)
            }.count == 1)

            AgentWorkspaceTrustStore.forget(inner)
            // 忘掉自己的那条之后落回上级的答案，而不是落回 unknown。
            #expect(AgentWorkspaceTrustStore.trust(for: inner) == .trusted)
            AgentWorkspaceTrustStore.forget(root)
            #expect(AgentWorkspaceTrustStore.trust(for: inner) == .unknown)
        }
    }

    /// 测试进程里弹模态就是挂死。门禁必须在测试下什么都不问，并且把文件夹
    /// 留在 unknown（= 不信任），而不是替用户默认答"信任"。
    @Test("测试环境下不弹窗，也不悄悄授予信任")
    @MainActor
    func neverPromptsUnderTests() throws {
        try withStore { root in
            let app = AppState(
                runtimeKernel: AgentRuntimeKernel(loadPersisted: false, persistsEvents: false),
                loadSessionCatalog: false
            )
            #expect(app.confirmWorkspaceTrustIfNeeded(for: root) == .unknown)
            #expect(AgentWorkspaceTrustStore.trust(for: root) == .unknown)
            // 已经有答案的文件夹直接返回，不进弹窗路径。
            AgentWorkspaceTrustStore.record(true, for: root)
            #expect(app.confirmWorkspaceTrustIfNeeded(for: root) == .trusted)
            // 不存在的路径不算文件夹，也就没什么可问的。
            #expect(app.confirmWorkspaceTrustIfNeeded(for: root.appendingPathComponent("missing")) == .unknown)
        }
    }
}
