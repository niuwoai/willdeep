import Foundation
import Testing
@testable import WillDeep

@MainActor
@Suite("Editor AppState registry", .serialized)
struct EditorAppStateRegistryTests {
    @Test("runtime lookup includes Agent-only headless AppState")
    func runtimeLookupIncludesHeadlessAppState() throws {
        let registry = EditorAppStateRegistry()
        registry.ensureHeadlessFallback()

        let appState = try #require(registry.current)
        let runtime = AgentRuntime(session: AgentSession(title: "Headless Agent"))
        appState.agentRuntimes[runtime.id] = runtime

        #expect(registry.appState(forRuntime: runtime.id) === appState)
    }

    @Test("runtime lookup includes orphan retained after last editor closes")
    func runtimeLookupIncludesRetainedOrphan() {
        let registry = EditorAppStateRegistry()
        let appState = AppState()
        let runtime = AgentRuntime(session: AgentSession(title: "Closed editor"))
        appState.agentRuntimes[runtime.id] = runtime

        registry.register(appState)
        registry.unregister(appState)

        #expect(registry.current === appState)
        #expect(registry.appState(forRuntime: runtime.id) === appState)
    }

    @Test("runtime lookup still returns nil for unknown runtime")
    func runtimeLookupRejectsUnknownRuntime() {
        let registry = EditorAppStateRegistry()
        registry.ensureHeadlessFallback()

        #expect(registry.appState(forRuntime: UUID()) == nil)
    }
}
