import Foundation

/// Compiled together with the production terminal type, without linking or
/// rebuilding the App. End-to-end Worker tests remain in the native suite.
@main struct AgentRSITerminalReasonTests {
    static func main() throws {
        let cases: [(AgentSubagentTerminationReason, Bool?, String)] = [
            (.finalResponse, nil, "unverified"),
            (.finalResponse, true, "unverified"),
            (.finalResponse, false, "failed"),
            (.maxRounds, nil, "budget_exhausted"),
            (.maxRounds, true, "budget_exhausted"),
            (.maxRounds, false, "budget_exhausted")
        ]
        let checks = cases.map { reason, verifier, expected in
            let actual = reason.evidenceStatus(verifierPassed: verifier)
            return ["termination_reason": reason.rawValue, "verifier": verifier.map(String.init) ?? "absent",
                    "expected": expected, "actual": actual, "passed": actual == expected ? "true" : "false"]
        }
        let passed = checks.allSatisfy { $0["passed"] == "true" }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let report: [String: Any] = ["passed": passed, "checks": checks, "test_count": cases.count,
            "production_type_compiled": true, "app_build_performed": false, "provider_requests": 0,
            "scope": "Production terminal classification only; native Worker end-to-end tests are not executed here."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("report.json"), options: .atomic)
        let markdown = "# Worker 终态分类免费回归\n\n通过：\(passed)，检查：\(cases.count)。\n\n直接编译并调用生产终态类型；未构建 App、未调用模型。覆盖最终答复和预算耗尽与三种 verifier 结果的组合。原生 Worker 四轮与第五请求上限回归在工程测试中，未由此报告代替。\n"
        try Data(markdown.utf8).write(to: directory.appendingPathComponent("report.md"), options: .atomic)
        guard passed else { throw NSError(domain: "AgentRSITerminalReasonTests", code: 1) }
        print("Passed \(cases.count) production terminal checks; 0 provider requests.")
    }
}
