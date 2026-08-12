import Testing
@testable import WillDeep

@Suite("Agent 工具参数预检")
struct AgentToolArgumentValidationTests {
    @Test("缺少终端命令时直接报告参数错误")
    func missingTerminalCommandIsRejectedBeforeApproval() {
        let error = AgentToolRegistry.argumentValidationError(
            for: "terminal_send_command",
            arguments: [:]
        )

        #expect(error == "Invalid tool arguments for terminal_send_command: missing required argument(s): command.")
    }

    @Test("必填参数类型错误时直接报告参数错误")
    func wrongRequiredArgumentTypeIsRejectedBeforeApproval() {
        let error = AgentToolRegistry.argumentValidationError(
            for: "terminal_send_command",
            arguments: ["command": .bool(true)]
        )

        #expect(error == "Invalid tool arguments for terminal_send_command: wrong type for required argument(s): command.")
    }

    @Test("合法参数和未登记的兼容工具不被拦截")
    func validAndCompatibilityToolArgumentsPass() {
        #expect(AgentToolRegistry.argumentValidationError(
            for: "terminal_send_command",
            arguments: ["command": .string("git status")]
        ) == nil)
        #expect(AgentToolRegistry.argumentValidationError(
            for: "glob",
            arguments: [:]
        ) == nil)
    }
}
