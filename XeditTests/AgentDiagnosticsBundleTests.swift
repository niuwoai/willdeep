import Foundation
import Testing
@testable import WillDeep

/// 这个包是要交到别人手上的，所以两件事必须钉死：默认那一档**真的**不含
/// 用户内容，以及清单里报的数就是包里实际装的数——不能出现「屏幕上说 3 条、
/// 包里躺着 300 条」。
@Suite(.serialized)
struct AgentDiagnosticsBundleTests {
    private let sessionA = UUID()
    private let sessionB = UUID()
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    /// 清单用 ISO8601 编码日期，读回来必须用同一套策略，否则这些用例测的
    /// 就是解码器配置而不是打包行为。
    private var manifestDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: date)
    }

    private func timingLine(session: UUID, at date: Date) -> String {
        #"{"kind":"turn","sessionID":"\#(session.uuidString)","recordedAt":"\#(iso(date))","totalSeconds":12.5}"#
    }

    private func stampedLine(_ date: Date, command: String) -> String {
        #"{"timestamp":"\#(iso(date))","toolName":"run_command","summary":"\#(command)"}"#
    }

    private func fixture(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let audit = root.appendingPathComponent("AgentAudit", isDirectory: true)
        let sessions = root.appendingPathComponent("agent-sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: audit, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(audit, sessions)
    }

    private func input(
        audit: URL,
        sessions: URL,
        level: AgentDiagnosticsBundle.Level,
        refs: [AgentDiagnosticsBundle.SessionRef]
    ) -> AgentDiagnosticsBundle.Input {
        AgentDiagnosticsBundle.Input(
            sessions: refs,
            level: level,
            auditDirectory: audit,
            sessionsDirectory: sessions,
            appVersion: "1.358.0-rc3",
            appBuild: "716",
            systemVersion: "Version 15.0"
        )
    }

    // MARK: 纯过滤

    @Test("时间线按 sessionID 精确切，切不到的会话一行不带")
    func timingLinesAreCutBySessionID() {
        let lines = [
            timingLine(session: sessionA, at: base),
            timingLine(session: sessionB, at: base),
            timingLine(session: sessionA, at: base.addingTimeInterval(60)),
            "not json at all",
        ]
        let picked = AgentDiagnosticsBundle.timingLines(in: lines, sessionIDs: [sessionA])
        #expect(picked.count == 2)
        #expect(picked.allSatisfy { $0.contains(sessionA.uuidString) })
        // 解不出来的行一律丢掉，不能混进包里。
        #expect(!picked.contains("not json at all"))
        #expect(AgentDiagnosticsBundle.timingLines(in: lines, sessionIDs: []).isEmpty)
    }

    @Test("没有 sessionID 的日志按时间窗口切，两端都算在内")
    func windowedLinesIncludeBothEnds() {
        let window = base...base.addingTimeInterval(100)
        let lines = [
            stampedLine(base.addingTimeInterval(-1), command: "before"),
            stampedLine(base, command: "at-start"),
            stampedLine(base.addingTimeInterval(50), command: "inside"),
            stampedLine(base.addingTimeInterval(100), command: "at-end"),
            stampedLine(base.addingTimeInterval(101), command: "after"),
        ]
        let picked = AgentDiagnosticsBundle.windowedLines(in: lines, window: window)
        #expect(picked.count == 3)
        #expect(!picked.contains { $0.contains("before") || $0.contains("after") })
    }

    @Test("时间窗口两端各留一分钟，跨过回合结束的工具调用不会被切掉")
    func windowIsPadded() {
        let span = try? #require(AgentDiagnosticsBundle.window(
            createdAt: [base], updatedAt: [base.addingTimeInterval(300)]
        ))
        #expect(span?.lowerBound == base.addingTimeInterval(-60))
        #expect(span?.upperBound == base.addingTimeInterval(360))
        #expect(AgentDiagnosticsBundle.window(createdAt: [], updatedAt: []) == nil)
    }

    // MARK: 默认档的承诺

    /// 这一条是这个功能存在的前提：默认档可以直接交给别人，不用先信任某个
    /// 脱敏 pass。所以它必须在**文件层面**不含 sandbox/judge/会话正文。
    @Test("默认档只装时间线和清单，命令与会话正文一个都不进包")
    func timingOnlyLevelCarriesNoUserContent() throws {
        try fixture { audit, sessions in
            try (timingLine(session: sessionA, at: base) + "\n")
                .write(to: audit.appendingPathComponent(AgentDiagnosticsBundle.timingLogName),
                       atomically: true, encoding: .utf8)
            try (stampedLine(base, command: "cat ~/.ssh/id_rsa") + "\n")
                .write(to: audit.appendingPathComponent(AgentDiagnosticsBundle.sandboxLogName),
                       atomically: true, encoding: .utf8)
            try (stampedLine(base, command: "cat ~/.ssh/id_rsa") + "\n")
                .write(to: audit.appendingPathComponent(AgentDiagnosticsBundle.judgeLogName),
                       atomically: true, encoding: .utf8)
            try #"{"id":"\#(sessionA.uuidString)","messages":["secret talk"]}"#
                .write(to: sessions.appendingPathComponent("\(sessionA.uuidString).json"),
                       atomically: true, encoding: .utf8)

            let refs = [AgentDiagnosticsBundle.SessionRef(id: sessionA, createdAt: base, updatedAt: base)]
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: staging) }
            let written = try AgentDiagnosticsBundle.stage(
                input(audit: audit, sessions: sessions, level: .timingOnly, refs: refs), into: staging
            )
            #expect(written.sorted() == ["manifest.json", AgentDiagnosticsBundle.timingLogName])
            #expect(!written.contains(AgentDiagnosticsBundle.sandboxLogName))
            #expect(!written.contains(AgentDiagnosticsBundle.judgeLogName))
            #expect(!written.contains { $0.hasPrefix("sessions/") })

            // 逐字节确认：整个暂存目录里不该出现那条命令。
            for name in written {
                let text = (try? String(contentsOf: staging.appendingPathComponent(name), encoding: .utf8)) ?? ""
                #expect(!text.contains("id_rsa"), "\(name)")
                #expect(!text.contains("secret talk"), "\(name)")
            }
            let manifest = try manifestDecoder.decode(
                AgentDiagnosticsBundle.Manifest.self,
                from: Data(contentsOf: staging.appendingPathComponent("manifest.json"))
            )
            #expect(!manifest.includesUserContent)
            #expect(manifest.sandboxLineCount == 0)
            #expect(manifest.judgeLineCount == 0)
        }
    }

    @Test("完整档才带命令记录和会话正文，并如实标记")
    func fullLevelCarriesUserContentAndSaysSo() throws {
        try fixture { audit, sessions in
            try (timingLine(session: sessionA, at: base) + "\n")
                .write(to: audit.appendingPathComponent(AgentDiagnosticsBundle.timingLogName),
                       atomically: true, encoding: .utf8)
            try (stampedLine(base, command: "npm install") + "\n")
                .write(to: audit.appendingPathComponent(AgentDiagnosticsBundle.sandboxLogName),
                       atomically: true, encoding: .utf8)
            try #"{"id":"\#(sessionA.uuidString)"}"#
                .write(to: sessions.appendingPathComponent("\(sessionA.uuidString).json"),
                       atomically: true, encoding: .utf8)

            let refs = [AgentDiagnosticsBundle.SessionRef(id: sessionA, createdAt: base, updatedAt: base)]
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: staging) }
            let written = try AgentDiagnosticsBundle.stage(
                input(audit: audit, sessions: sessions, level: .full, refs: refs), into: staging
            )
            #expect(written.contains(AgentDiagnosticsBundle.sandboxLogName))
            #expect(written.contains("sessions/\(sessionA.uuidString).json"))
            let manifest = try manifestDecoder.decode(
                AgentDiagnosticsBundle.Manifest.self,
                from: Data(contentsOf: staging.appendingPathComponent("manifest.json"))
            )
            #expect(manifest.includesUserContent)
            #expect(manifest.sandboxLineCount == 1)
        }
    }

    /// 屏幕上报的数和包里实际的行数必须一致。不一致的话，用户是按一个假数字
    /// 决定要不要把日志发出去的。
    @Test("预览报的数就是包里实际的数")
    func previewMatchesWhatIsPacked() throws {
        try fixture { audit, sessions in
            let timing = [
                timingLine(session: sessionA, at: base),
                timingLine(session: sessionB, at: base),
                timingLine(session: sessionA, at: base.addingTimeInterval(30)),
            ]
            try (timing.joined(separator: "\n") + "\n")
                .write(to: audit.appendingPathComponent(AgentDiagnosticsBundle.timingLogName),
                       atomically: true, encoding: .utf8)
            try (stampedLine(base, command: "go build") + "\n")
                .write(to: audit.appendingPathComponent(AgentDiagnosticsBundle.sandboxLogName),
                       atomically: true, encoding: .utf8)

            let refs = [AgentDiagnosticsBundle.SessionRef(id: sessionA, createdAt: base, updatedAt: base)]
            let bundleInput = input(audit: audit, sessions: sessions, level: .full, refs: refs)
            let preview = AgentDiagnosticsBundle.preview(for: bundleInput)
            #expect(preview.sessionCount == 1)
            #expect(preview.timingLineCount == 2)
            #expect(preview.sandboxLineCount == 1)
            #expect(preview.includesUserContent)

            let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: staging) }
            try AgentDiagnosticsBundle.stage(bundleInput, into: staging)
            let manifest = try manifestDecoder.decode(
                AgentDiagnosticsBundle.Manifest.self,
                from: Data(contentsOf: staging.appendingPathComponent("manifest.json"))
            )
            #expect(manifest.timingLineCount == preview.timingLineCount)
            #expect(manifest.sandboxLineCount == preview.sandboxLineCount)
        }
    }

    /// 轮转过的那一份不读，早上那次慢回合就正好落在包外面——而用户拿到的是
    /// 一个"看起来成功了"的空包。
    @Test("轮转出去的时间线也要一并收进来")
    func rotatedTimingLogIsIncluded() throws {
        try fixture { audit, sessions in
            try (timingLine(session: sessionA, at: base) + "\n")
                .write(to: audit.appendingPathComponent(AgentDiagnosticsBundle.rotatedTimingLogName),
                       atomically: true, encoding: .utf8)
            try (timingLine(session: sessionA, at: base.addingTimeInterval(600)) + "\n")
                .write(to: audit.appendingPathComponent(AgentDiagnosticsBundle.timingLogName),
                       atomically: true, encoding: .utf8)
            let refs = [AgentDiagnosticsBundle.SessionRef(id: sessionA, createdAt: base, updatedAt: base)]
            let preview = AgentDiagnosticsBundle.preview(
                for: input(audit: audit, sessions: sessions, level: .timingOnly, refs: refs)
            )
            #expect(preview.timingLineCount == 2)
        }
    }

    @Test("日志缺失时导出空包而不是抛错")
    func missingLogsDegradeQuietly() throws {
        try fixture { audit, sessions in
            let refs = [AgentDiagnosticsBundle.SessionRef(id: sessionA, createdAt: base, updatedAt: base)]
            let bundleInput = input(audit: audit, sessions: sessions, level: .full, refs: refs)
            #expect(AgentDiagnosticsBundle.preview(for: bundleInput).timingLineCount == 0)
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: staging) }
            let written = try AgentDiagnosticsBundle.stage(bundleInput, into: staging)
            #expect(written == ["manifest.json"])
        }
    }

    @Test("文件名带档位和时间戳，两次导出不会同名")
    func suggestedFileNameIsDistinct() {
        let timing = AgentDiagnosticsBundle.suggestedFileName(level: .timingOnly, at: base)
        let full = AgentDiagnosticsBundle.suggestedFileName(level: .full, at: base)
        #expect(timing.hasSuffix(".zip"))
        #expect(timing.contains("timing"))
        #expect(full.contains("full"))
        #expect(timing != full)
        #expect(AgentDiagnosticsBundle.suggestedFileName(level: .full, at: base.addingTimeInterval(60)) != full)
    }
}
