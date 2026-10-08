import Foundation
import CryptoKit
import Darwin

/// 本机旁路账本：只写计数、标识和文本 hash，不写正文、工具参数或错误原文。
nonisolated struct AgentFeedbackEvent: Codable, Sendable {
    private static let maxDistanceScalars = 600
    var schema = "willdeep.feedback.v1"
    var id = UUID()
    var ts = ISO8601DateFormatter().string(from: Date())
    var client = "macos"
    var sessionID: UUID
    var signal: String
    var runID: UUID?
    var turnID: UUID?
    var prevTurnID: UUID?
    var suggestionID: UUID?
    var provider: String?
    var model: String?
    var tool: String?
    var errorClass: String?
    var textHash: String?
    var textLen: Int?
    var sentHash: String?
    var sentLen: Int?
    var editDistance: Int?
    var dwellMS: Int?
    var elapsedMS: Int?
    var followupHint: String?
    var verification: String?
    var stopReason: String?
    var decision: String?
    var queuedBehind: Bool?
    var promptBundle: String?

    static func hash(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return SHA256.hash(data: Data(trimmed.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func distance(_ left: String, _ right: String) -> Int? {
        let left = Array(left.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars)
        let right = Array(right.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars)
        guard left.count <= maxDistanceScalars, right.count <= maxDistanceScalars else { return nil }
        var previous = Array(0...right.count)
        for (row, character) in left.enumerated() {
            var current = [row + 1]
            for (column, other) in right.enumerated() {
                current.append(min(previous[column] + (character == other ? 0 : 1), current[column] + 1, previous[column + 1] + 1))
            }
            previous = current
        }
        return previous.last
    }
}

nonisolated final class AgentFeedbackLedger: @unchecked Sendable {
    static let shared: AgentFeedbackLedger = {
        let environment = ProcessInfo.processInfo.environment
        let testing = NSClassFromString("XCTestCase") != nil || NSClassFromString("XCTest") != nil
            || environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
        let base = testing ? FileManager.default.temporaryDirectory
            .appendingPathComponent("WillDeepTests-\(ProcessInfo.processInfo.processIdentifier)")
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("WillDeep")
        return AgentFeedbackLedger(directory: base.appendingPathComponent("feedback", isDirectory: true))
    }()
    static let enabledKey = "com.willdeep.feedback.enabled"
    private let directory: URL
    private let queue = DispatchQueue(label: "com.willdeep.feedback.writer", qos: .utility)
    private let lock = NSLock()
    private var pending = 0
    private var dropped = 0
    private var writeFailures = 0
    private static let capacity = 512
    private static let maxRecordBytes = 4096

    init(directory: URL) { self.directory = directory }

    func record(_ event: AgentFeedbackEvent) {
        guard UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool != false else { return }
        let admitted = lock.withLock {
            guard pending < Self.capacity else { dropped += 1; return false }
            pending += 1
            return true
        }
        guard admitted else { return }
        queue.async { [self] in
            defer { lock.withLock { pending -= 1 } }
            do { try append(event) }
            catch { lock.withLock { writeFailures += 1 } }
        }
    }

    func health() -> (dropped: Int, writeFailures: Int) {
        lock.withLock { (dropped, writeFailures) }
    }

    /// 仅供测试和显式导出收尾使用，热路径不等待 IO。
    func flush() { queue.sync {} }

    private func append(_ event: AgentFeedbackEvent) throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        var data = try encoder.encode(event)
        data.append(0x0a)
        guard data.count <= Self.maxRecordBytes else {
            lock.withLock { dropped += 1 }
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let month = String(event.ts.prefix(7))
        let path = directory.appendingPathComponent("\(month).jsonl").path
        let descriptor = Darwin.open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(descriptor) }
        let written = data.withUnsafeBytes { bytes in
            Darwin.write(descriptor, bytes.baseAddress, bytes.count)
        }
        guard written == data.count else { throw CocoaError(.fileWriteUnknown) }
    }
}

nonisolated enum AgentFeedbackClassification {
    static func hint(_ input: String) -> String {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["不是", "不对", "错了", "不应该", "that's wrong", "incorrect"].contains(where: text.hasPrefix) { return "correction" }
        if ["重做", "重新", "再试", "redo", "try again"].contains(where: text.hasPrefix) { return "redo" }
        if ["补充", "另外", "还有", "also", "additionally"].contains(where: text.hasPrefix) { return "supplement" }
        if ["好的", "可以", "同意", "ok", "yes"].contains(text) { return "approval" }
        return "other"
    }
}
