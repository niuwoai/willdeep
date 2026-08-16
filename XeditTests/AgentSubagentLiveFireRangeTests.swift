//
//  AgentSubagentLiveFireRangeTests.swift
//  WillDeepTests
//
//  实弹靶场：把小上下文工种放到真实缺陷上打一轮，量出它们到底行不行。
//
//  Ported from willdeep-rs (`crates/willdeep-core/src/livefire.rs`). 缘由是
//  两边共有的一个空洞：单测里的 provider 全是桩，而**桩 provider 永远修得好**，
//  所以「可自动验证的小任务可以交给弱模型」这句话在仓库里无从证伪。靶场用真
//  Provider、真缺陷、真退出码跑一遍，产出的是数字，不是印象。
//
//  它**不进 CI**：需要真实凭据、需要网络、每跑一轮都花钱。没有
//  `XEDIT_RANGE_API_KEY` 时整个 suite 跳过。入口是
//  `scripts/skill_worker_range.rb`。
//
//  两条判定纪律（与 rs 侧逐字一致）：
//  1. 可验证样本的成功 = verifier 通过**且**没动测试。退出码只知道绿了，不
//     知道绿得干不干净；删掉断言是最省力的通关方式。
//  2. 只读样本没有退出码，量两件事：引用的地方**存不存在**（防编造）与
//     **是不是那个地方**（防答非所问）。分开算，混在一起的指标会自我恭维。
//

import Foundation
import Testing

@testable import WillDeep

@Suite(
    "Skill worker live-fire range",
    .enabled(if: ProcessInfo.processInfo.environment["XEDIT_RANGE_API_KEY"]?.isEmpty == false)
)
struct AgentSubagentLiveFireRangeTests {
    struct RangeCase {
        let id: String
        let profile: AgentSubagentProfile
        let goal: String
        let knownFacts: [String]
        let constraints: [String]
        /// nil 表示只读样本：它没有可判的退出码，假装有才是指标开始撒谎的地方。
        let verifier: String?
        let files: [String: String]
        /// 报告里必须出现的字符串——「答对了没有」是独立于「引用存不存在」的一问。
        let expect: [String]
        /// 播三个 commit 的历史，中间那个是真凶。
        let gitHistory: Bool
    }

    /// 缺陷样本。Swift 侧的可验证样本一律用 `swift build`：`swift test` 要拖进
    /// 整个测试框架，一个样本几十秒，而这一轮要量的是模型不是编译器。
    ///
    /// `--disable-sandbox` 不是图省事：SwiftPM 编译 manifest 时自己会调
    /// `sandbox-exec`，而 verifier 已经跑在 Agent 的 seatbelt 沙盒里了——
    /// 嵌套沙盒被内核直接拒（`sandbox_apply: Operation not permitted`），
    /// 报出来的失败与源码无关。靶场第一轮就是栽在这上面：三个样本全红，
    /// 而 Worker 的补丁其实每次都打对了。
    static let cases: [RangeCase] = [
        RangeCase(
            id: "build_missing_var",
            profile: AgentSubagentProfileCatalog.buildFixer,
            goal: "修复 count 被声明为 let 却被累加导致的编译错误",
            knownFacts: ["swiftc 报 cannot assign to value: 'total' is a 'let' constant"],
            constraints: ["最小改动"],
            verifier: "swift build --disable-sandbox",
            files: [
                "Sources/Range/Range.swift": """
                public func countWords(_ text: String) -> Int {
                    let total = 0
                    for _ in text.split(separator: " ") {
                        total += 1
                    }
                    return total
                }
                """
            ],
            expect: [],
            gitHistory: false
        ),
        RangeCase(
            id: "build_type_mismatch",
            profile: AgentSubagentProfileCatalog.buildFixer,
            goal: "修复返回类型与实际值不符的编译错误",
            knownFacts: ["函数声明返回 Int，实际返回 Double"],
            constraints: ["保持函数签名不变"],
            verifier: "swift build --disable-sandbox",
            files: [
                "Sources/Range/Range.swift": """
                public func halfLength(_ text: String) -> Int {
                    let length = Double(text.count) / 2.0
                    return length
                }
                """
            ],
            expect: [],
            gitHistory: false
        ),
        RangeCase(
            id: "build_non_exhaustive_switch",
            profile: AgentSubagentProfileCatalog.buildFixer,
            goal: "补齐 switch 的缺失分支",
            knownFacts: ["swiftc 报 switch must be exhaustive，缺 .error"],
            constraints: ["不要用 default 糊过去，逐个列出"],
            verifier: "swift build --disable-sandbox",
            files: [
                "Sources/Range/Range.swift": """
                public enum Level {
                    case info
                    case warn
                    case error
                }

                public func label(_ level: Level) -> String {
                    switch level {
                    case .info: return "info"
                    case .warn: return "warn"
                    }
                }
                """
            ],
            expect: [],
            gitHistory: false
        ),
        RangeCase(
            id: "scout_finds_the_symbol",
            profile: AgentSubagentProfileCatalog.scout,
            goal: "找出 retryBudget 这个函数定义在哪个文件的哪一行",
            knownFacts: ["仓库里有多个文件，只有一个定义了它"],
            constraints: ["报告要给出路径和行号"],
            verifier: nil,
            files: [
                "Sources/Range/Config.swift": "public func timeoutSeconds() -> Int { 30 }\n",
                "Sources/Range/Net.swift": "public func send() -> Int { retryBudget() }\n",
                "Sources/Range/Util.swift": "/// How many retries a request gets.\npublic func retryBudget() -> Int { 3 }\n",
            ],
            expect: ["Sources/Range/Util.swift"],
            gitHistory: false
        ),
        RangeCase(
            id: "git_detective_finds_the_commit",
            profile: AgentSubagentProfileCatalog.gitDetective,
            goal: "找出哪个 commit 把 retryBudget 的返回值从 3 改成了 0",
            knownFacts: ["仓库有三个 commit", "当前 retryBudget 返回 0"],
            constraints: ["报告要给出确切的 commit 哈希"],
            verifier: nil,
            files: [
                "Sources/Range/Util.swift": "public func retryBudget() -> Int { 0 }\n"
            ],
            expect: [],
            gitHistory: true
        ),
    ]

    @Test("每个工种在真实缺陷上跑一轮，产出可发布的数字")
    func range() async throws {
        let environment = ProcessInfo.processInfo.environment
        let apiKey = try #require(environment["XEDIT_RANGE_API_KEY"])
        let baseURL = environment["XEDIT_RANGE_API_BASE"] ?? "https://api.niuwoai.com/v1"
        let onlyCases = environment["XEDIT_RANGE_CASES"]?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        let rangeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("xedit-range-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rangeRoot, withIntermediateDirectories: true)

        var rows: [[String: Any]] = []
        for rangeCase in Self.cases where onlyCases?.contains(rangeCase.id) ?? true {
            let fixture = rangeRoot.appendingPathComponent(rangeCase.id)
            let culprit = try Self.seed(rangeCase, at: fixture)
            // 派工前确认靶子是红的。绿着的靶子测不出任何东西。
            let seededRed = rangeCase.verifier.map { !Self.commandSucceeds($0, in: fixture) } ?? true

            // 工种档位由目录决定，模型只在这里被换成靶场指定的那一个：
            // 量的是「这个档位的模型行不行」，不是「用户配了什么」。
            let configuration = AgentConfiguration(
                providerID: AgentProviderPreset.someIMID,
                baseURL: baseURL,
                model: environment["XEDIT_RANGE_MODEL"] ?? "glm-5",
                routingMode: .flash,
                apiKey: apiKey
            )
            let writeAccess = rangeCase.verifier == nil
                ? nil
                : AgentSubagentWriteAccess(targetRelativePaths: Array(rangeCase.files.keys))

            let startedAt = Date()
            var report = ""
            var verifierPassed: Bool?
            var attempts = 0
            var citationsChecked = 0
            var citationsUnverifiable = 0
            var failure: String?
            do {
                let outcome = try await AgentSubagentRunner.run(
                    prompt: Self.openingMessage(for: rangeCase, at: fixture),
                    configuration: configuration,
                    workspaceURL: fixture,
                    profile: rangeCase.profile,
                    writeAccess: writeAccess,
                    verifierCommand: rangeCase.verifier,
                    patchProposalSink: Self.patchSink(root: fixture)
                )
                report = outcome.report
                verifierPassed = outcome.verifierPassed
                attempts = outcome.verifierAttempts
                citationsChecked = outcome.citationsChecked
                citationsUnverifiable = outcome.citationsUnverifiable
            } catch {
                failure = "\(error)"
            }
            let seconds = Date().timeIntervalSince(startedAt)

            var expectations = rangeCase.expect
            if let culprit { expectations.append(String(culprit.prefix(7))) }
            let answered = expectations.allSatisfy { report.contains($0) }
            let untouchedFixture = rangeCase.verifier == nil || Self.sourcesStillCompileTheSameAPI(
                rangeCase,
                at: fixture
            )

            print("""
            [range] \(rangeCase.id) verdict=\(verifierPassed.map(String.init(describing:)) ?? "readonly") \
            attempts=\(attempts) citations=\(citationsChecked - citationsUnverifiable)/\(citationsChecked) \
            answer=\(answered) \(String(format: "%.1f", seconds))s \(failure ?? "")
            """)

            rows.append([
                "case": rangeCase.id,
                "profile": rangeCase.profile.id,
                "report_only": rangeCase.verifier == nil,
                "seeded_red": seededRed,
                "verifier_passed": verifierPassed as Any,
                "attempts": attempts,
                "api_intact": untouchedFixture,
                "claims_checked": citationsChecked,
                "claims_unverifiable": citationsUnverifiable,
                "expectation_met": answered,
                "seconds": (seconds * 10).rounded() / 10,
                // 报告原文进 JSON：判定告诉你成没成，报告告诉你为什么。
                // rs 侧靶场的头一发就是靠这个才看出失败在 Runtime 不在模型。
                "report": String(report.prefix(1200)),
                "error": failure as Any,
            ])
        }

        let reportPath = ProcessInfo.processInfo.environment["XEDIT_RANGE_OUT"]
            ?? rangeRoot.appendingPathComponent("range.json").path
        let payload: [String: Any] = [
            "model": ProcessInfo.processInfo.environment["XEDIT_RANGE_MODEL"] ?? "glm-5",
            "cases": rows,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: reportPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: URL(fileURLWithPath: reportPath))
        print("[range] report: \(reportPath)")
    }

    /// 补丁落盘通道。产线上 `apply_patch` 的补丁走父会话的补丁流水线（卡片、
    /// 产物账本、撤销栈都在那条路上）；靶场没有 UI，但**不能没有通道**——
    /// 没有它，`apply_patch` 直接报「只在交互式会话里可用」，Worker 诊断得
    /// 再准也落不了地，而报告读起来会像是模型不会修。解析与应用仍走产线的
    /// `AgentPatchApplier`：靶场自己写一套 diff 应用逻辑，量到的就会是那套。
    @MainActor
    private static func patchSink(
        root: URL
    ) -> @MainActor (String?, String, Bool, URL) async throws -> AgentPatchProposal {
        { title, diff, _, _ in
            let blocks = AgentPatchApplier.extractDiffBlocks(from: diff)
            let text = blocks.count == 1 ? blocks[0] : diff
            for change in try AgentPatchApplier.parse(text) {
                let target = root.appendingPathComponent(change.path)
                let original = change.isNewFile
                    ? ""
                    : (try? String(contentsOf: target, encoding: .utf8)) ?? ""
                let updated = try AgentPatchApplier.apply(change, to: original)
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try updated.write(to: target, atomically: true, encoding: .utf8)
            }
            return AgentPatchProposal(
                messageID: UUID(),
                title: title ?? "range patch",
                diff: text,
                workspaceRootPath: root.path,
                status: .applied
            )
        }
    }

    /// 与产线同一条路径：派工用的是 Task Packet 渲染出来的开场白，不是随手
    /// 拼的一段话。靶场如果自己编一套提示词，量到的就是那套提示词。
    private static func openingMessage(for rangeCase: RangeCase, at root: URL) -> String {
        let packet = AgentSubagentTaskPacket(
            goal: rangeCase.goal,
            // 只读工种刻意不给 relevantFiles：让它自己去找，测的才是「找」
            // 这门手艺；写入型工种的这份清单同时就是它的可写文件集。
            relevantFiles: rangeCase.verifier == nil ? [] : Array(rangeCase.files.keys).sorted(),
            knownFacts: rangeCase.knownFacts,
            constraints: rangeCase.constraints,
            verifierCommand: rangeCase.verifier
        )
        return packet.openingMessage(fallbackPrompt: prompt(for: rangeCase)) { path in
            try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
    }

    private static func prompt(for rangeCase: RangeCase) -> String {
        switch rangeCase.verifier {
        case .some:
            return "把编译错误修掉，让 swift build 通过。只做最小改动，不要改公开签名。"
        case .none:
            return "回答问题并给出确切位置。只报你亲眼看到的东西，找不到就直说，不要猜。"
        }
    }

    /// 建一个独立的 SwiftPM 仓库当靶子。必须是 Git 仓库：`repoCommit` 锚点与
    /// git_detective 样本都从这里来。
    private static func seed(_ rangeCase: RangeCase, at root: URL) throws -> String? {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = """
        // swift-tools-version:5.9
        import PackageDescription

        let package = Package(
            name: "Range",
            targets: [.target(name: "Range")]
        )
        """
        try manifest.write(
            to: root.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        try ".build\n".write(
            to: root.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        _ = AppState.runGitCommand(
            arguments: ["init", "--quiet", "--initial-branch=main"],
            in: root
        )

        func commit(_ message: String) {
            _ = AppState.runGitCommand(arguments: ["add", "."], in: root)
            _ = AppState.runGitCommand(
                arguments: [
                    "-c", "user.name=range", "-c", "user.email=range@local",
                    "commit", "--quiet", "-m", message,
                ],
                in: root
            )
        }
        func write(_ files: [String: String]) throws {
            for (path, body) in files {
                let target = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try body.write(to: target, atomically: true, encoding: .utf8)
            }
        }

        guard rangeCase.gitHistory else {
            try write(rangeCase.files)
            commit("seed")
            return nil
        }

        // 三个 commit，中间那个才是真凶：只有一个 commit 的历史里，
        // 「找出哪个 commit」这个问题根本无法答错，也就测不出任何东西。
        try write(["Sources/Range/Util.swift": "public func retryBudget() -> Int { 3 }\n"])
        commit("add retry budget")
        try write(rangeCase.files)
        commit("tune retry budget")
        let culprit = AppState.runGit(arguments: ["rev-parse", "HEAD"], in: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try "# range fixture\n".write(
            to: root.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        commit("document the crate")
        return culprit.isEmpty ? nil : culprit
    }

    /// 「绿得干不干净」的 Swift 版：公开函数名必须还在。删掉函数当然能让
    /// `swift build` 变绿，而那不是修复，是把靶子搬走。
    private static func sourcesStillCompileTheSameAPI(
        _ rangeCase: RangeCase,
        at root: URL
    ) -> Bool {
        for (path, original) in rangeCase.files {
            guard let current = try? String(
                contentsOf: root.appendingPathComponent(path),
                encoding: .utf8
            ) else { return false }
            for line in original.split(separator: "\n") where line.contains("public func ") {
                guard let name = line.split(separator: "(").first?
                    .replacingOccurrences(of: "public func ", with: "")
                    .trimmingCharacters(in: .whitespaces) else { continue }
                if !current.contains(name) { return false }
            }
        }
        return true
    }

    private static func commandSucceeds(_ command: String, in directory: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = directory
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
