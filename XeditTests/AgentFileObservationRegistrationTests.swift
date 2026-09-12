import Foundation
import Testing
@testable import WillDeep

/// 台账的登记侧：哪些路径算「这次观察到的」。判据本身在 WillDeepCore 里
/// （见 Packages/WillDeepCore 与 docs/BUILD_MODULARIZATION_DESIGN.md），
/// 这两条依赖 AppState 与 AgentToolResult，留在 App 测试目标。
@Suite
struct AgentFileObservationRegistrationTests {
    @Test("搜索结果里按第一个冒号切路径，片段里的冒号不参与")
    func parsesSearchResultPaths() {
        let result = AgentToolResult(
            summary: "3 matches",
            payload: "a.swift:12: let x = foo(bar: 1)\nb/c.swift:3: // note: here\na.swift:44: again"
        )
        let paths = AppState.observedPaths(toolName: "grep_files", arguments: [:], result: result)
        #expect(paths == ["a.swift", "b/c.swift"])
    }

    @Test("有 path 参数时直接用它，不去解析正文")
    func prefersThePathArgument() {
        let paths = AppState.observedPaths(
            toolName: "read_file",
            arguments: ["path": .string("Xedit/A.swift")],
            result: AgentToolResult(summary: "", payload: "irrelevant:1: x")
        )
        #expect(paths == ["Xedit/A.swift"])
    }
}
