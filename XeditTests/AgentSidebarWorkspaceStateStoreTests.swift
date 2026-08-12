import Foundation
import Testing
@testable import WillDeep

struct AgentSidebarWorkspaceStateStoreTests {
    @Test("workspace sidebar state persists, clears, and prunes stale keys")
    func stateStorePersistsAndPrunesKeys() throws {
        let suiteName = "willdeep-agent-sidebar-state-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            TestDefaultsHygiene.cleanup(suite: defaults, named: suiteName)
        }

        AgentSidebarWorkspaceStateStore.save(
            ["/tmp/project-b", "/tmp/project-a"],
            kind: .collapsedWorkspaces,
            defaults: defaults
        )

        #expect(AgentSidebarWorkspaceStateStore.load(.collapsedWorkspaces, defaults: defaults) == [
            "/tmp/project-a",
            "/tmp/project-b",
        ])

        let pruned = AgentSidebarWorkspaceStateStore.prune(
            ["/tmp/project-a", "/tmp/project-b", "/tmp/removed"],
            to: ["/tmp/project-a"],
            kind: .collapsedWorkspaces,
            defaults: defaults
        )

        #expect(pruned == ["/tmp/project-a"])
        #expect(AgentSidebarWorkspaceStateStore.load(.collapsedWorkspaces, defaults: defaults) == ["/tmp/project-a"])

        AgentSidebarWorkspaceStateStore.save([], kind: .collapsedWorkspaces, defaults: defaults)
        #expect(defaults.object(forKey: AgentSidebarWorkspaceStateStore.Kind.collapsedWorkspaces.defaultsKey) == nil)
    }
}
