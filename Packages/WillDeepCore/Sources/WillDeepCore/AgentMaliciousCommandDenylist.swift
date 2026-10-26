import Foundation

/// Detect high-impact command shapes, not intent. Unmatched commands remain
/// eligible for Full Access; unsupported syntax is reported separately.
nonisolated public enum AgentMaliciousCommandDenylist {
    public struct Match: Equatable, Sendable {
        public let ruleID: String
        public let reason: String
        public let segment: String
        public init(ruleID: String, reason: String, segment: String) {
            self.ruleID = ruleID; self.reason = reason; self.segment = segment
        }
    }
    public enum Assessment: Equatable, Sendable {
        case matched(Match)
        case notMatched
        case unsupportedSyntax([String])
    }
    private struct Scan {
        var match: Match?
        var unsupported: [String] = []
        var sensitiveOutput = false
    }
    private static let maximumDepth = 12

    public static func match(command: String) -> Match? {
        if case .matched(let match) = assess(command: command) { return match }
        return nil
    }

    public static func assess(command: String, workingDirectory: URL? = nil) -> Assessment {
        let scan = inspect(command, depth: 0, remote: false, workingDirectory: workingDirectory)
        if let match = scan.match { return .matched(match) }
        if !scan.unsupported.isEmpty { return .unsupportedSyntax(Array(Set(scan.unsupported)).sorted()) }
        return .notMatched
    }

    private static func inspect(_ command: String, depth: Int, remote: Bool, workingDirectory: URL?) -> Scan {
        guard depth < maximumDepth else { return Scan(unsupported: ["inspection depth exceeded"]) }
        if executableForkBomb(command) {
            return Scan(match: Match(ruleID: "fork-bomb", reason: "递归后台函数会耗尽进程资源", segment: command))
        }
        let parsed = AgentCommandInspection.parse(command)
        var result = Scan(unsupported: parsed.unsupported)
        var variables: [String: String] = [:]
        var pipelineSensitive = false
        var currentDirectory = workingDirectory
        for (index, commandNode) in parsed.commands.enumerated() {
            var original = commandNode
            let pipesToNext = index + 1 < parsed.commands.count && parsed.commands[index + 1].pipeFromPrevious
            if !original.pipeFromPrevious { pipelineSensitive = false }
            for (wordIndex, word) in (original.words + original.redirects.map(\.target)).enumerated() {
                for script in word.substitutions {
                    let child = inspect(script, depth: depth + 1, remote: remote, workingDirectory: currentDirectory)
                    if let match = child.match { result.match = match; return result }
                    result.unsupported += child.unsupported
                    if wordIndex < original.words.count, child.sensitiveOutput {
                        original.words[wordIndex].sensitiveContent = true
                    }
                }
            }
            if !original.pipeFromPrevious, !pipesToNext,
               original.words.allSatisfy({ AgentCommandInvocation.assignment($0) != nil }) {
                for word in original.words {
                    guard let (key, value) = AgentCommandInvocation.assignment(word) else { continue }
                    if !word.dynamic { variables[key] = value } else { variables.removeValue(forKey: key) }
                }
            }
            let invocation = AgentCommandInvocation.unwrap(original)
            if let match = AgentCommandRiskShapes.match(invocation, remote: remote, workingDirectory: currentDirectory) {
                result.match = match; return result
            }
            let child: Scan?
            if let payload = AgentCommandInvocation.sshPayload(invocation) {
                child = inspect(payload, depth: depth + 1, remote: true, workingDirectory: nil)
            } else if let payload = AgentCommandInvocation.shellPayload(invocation) {
                child = inspect(payload, depth: depth + 1, remote: remote, workingDirectory: currentDirectory)
            } else if invocation.name == "eval" {
                let payload = invocation.args.map { variables[variableName($0)] ?? $0 }.joined(separator: " ")
                if payload.contains("$") || payload.contains("__willdeep_substitution__") {
                    result.unsupported.append("dynamic eval payload"); child = nil
                } else { child = inspect(payload, depth: depth + 1, remote: remote, workingDirectory: currentDirectory) }
            } else { child = nil }
            if let child {
                if let match = child.match { result.match = match; return result }
                result.unsupported += child.unsupported
            }
            let flow = AgentCredentialCommandFlow.inspect(invocation, stdinSensitive: pipelineSensitive)
            if flow.exfiltrates {
                result.match = Match(ruleID: "credential-exfiltration", reason: "该网络命令从敏感文件、命令替换或同一管道读取并发送凭据内容", segment: invocation.source)
                return result
            }
            pipelineSensitive = flow.sensitiveOutput || (child?.sensitiveOutput ?? false)
            if invocation.redirects.contains(where: { $0.writes && !$0.duplicatesDescriptor && ["1", "*"].contains($0.descriptor) }) { pipelineSensitive = false }
            if !pipesToNext { result.sensitiveOutput = result.sensitiveOutput || pipelineSensitive }
            if invocation.name == "cd", !original.pipeFromPrevious, !pipesToNext, let path = invocation.args.first, !path.contains("$") {
                currentDirectory = AgentHostDataPathPolicy.resolvedPath(token: path, workingDirectory: currentDirectory)
            }
            if invocation.words.first?.dynamic == true { result.unsupported.append("dynamic executable") }
        }
        return result
    }

    private static func variableName(_ argument: String) -> String {
        if argument.hasPrefix("${"), argument.hasSuffix("}") { return String(argument.dropFirst(2).dropLast()) }
        return argument.hasPrefix("$") ? String(argument.dropFirst()) : ""
    }

    private static func executableForkBomb(_ command: String) -> Bool {
        guard let text = AgentShellCommandParser.unquotedText(command) else { return false }
        return text.range(of: #"(?:^|[;\n])\s*([A-Za-z_][A-Za-z_0-9]*|:)\s*\(\s*\)\s*\{\s*\1\s*\|\s*\1\s*&\s*\}\s*;\s*\1(?:\s|;|$)"#, options: .regularExpression) != nil
    }
}
