//
//  UserWorkflowManifest.swift
//  WillDeep
//
//  1.85.0-rc5：用户自定义 declarative workflow 的清单格式 + 解析器。
//
//  位置：`~/.willdeep/skills/<slug>/workflow.yaml`
//  （也兼容 `~/.codex/skills/<slug>/workflow.yaml` 老路径,以及
//   BundledSkills/ 里的示例）
//
//  格式（最小子集 YAML,自己解析,不引入依赖）：
//
//    name: example-translate
//    version: 1.0.0
//    slash_command: /translate-cn
//    display_title: Translate to Chinese
//    short_description: Translate text to Simplified Chinese
//    args_placeholder: <text to translate>
//    allows_empty_args: false
//    max_agents: 1
//
//    steps:
//      - id: translate
//        label: translate
//        prompt: |
//          Translate the following to Simplified Chinese.
//          Output only the translation.
//
//          Text:
//          {{args}}
//
//    summary: |
//      ## Translation
//
//      **Source**: {{args}}
//
//      {{steps.translate.output}}
//
//  支持的占位符（运行时由 DeclarativeWorkflow 替换）：
//   - `{{args}}` —— 用户在 slash 后面输入的整段原文
//   - `{{steps.<step-id>.output}}` —— 之前已跑完的 step 的输出
//
//  解析器特点：
//   - 只支持 2-space 缩进
//   - 支持 block scalar `|`（保留换行,trim 尾部空行）
//   - 支持 `#` 注释
//   - 支持 quoted `"..."` 和裸 string
//   - 不支持 anchors / aliases / flow 风格 / 多文档
//

import Foundation

struct UserWorkflowManifest: Equatable {
    var name: String
    var version: String
    var slashCommand: String
    var displayTitle: String
    var shortDescription: String
    var argsPlaceholder: String
    var allowsEmptyArgs: Bool
    var maxAgents: Int
    var steps: [Step]
    var summaryTemplate: String

    /// 源文件 URL,用来在 widget loader 里解析相邻文件路径（widget.html）。
    var sourceURL: URL?

    struct Step: Equatable {
        var id: String
        var label: String
        var prompt: String
    }
}

enum UserWorkflowManifestError: LocalizedError, Equatable {
    case missingField(String)
    case invalidStep(reason: String)
    case yamlSyntax(line: Int, reason: String)
    case slashCommandShape(String)
    case reservedSlashCommand(String)

    var errorDescription: String? {
        switch self {
        case .missingField(let f): return "workflow.yaml 缺少必填字段:\(f)"
        case .invalidStep(let r): return "workflow.yaml steps 无效:\(r)"
        case .yamlSyntax(let line, let r): return "workflow.yaml 第 \(line) 行语法错误:\(r)"
        case .slashCommandShape(let s): return "workflow.yaml slash_command 必须以 / 开头且只含字母数字-_,得到:\(s)"
        case .reservedSlashCommand(let s): return "workflow.yaml slash_command \(s) 与内置 workflow 冲突,改用别的命令名"
        }
    }
}

enum UserWorkflowManifestParser {
    /// 解析 workflow.yaml 文本为 manifest。
    /// `reservedSlashCommands` 由调用方传入(内置 workflow 占用的 slash),
    /// 不允许用户覆盖。
    static func parse(
        _ text: String,
        sourceURL: URL? = nil,
        reservedSlashCommands: Set<String> = []
    ) throws -> UserWorkflowManifest {
        let tree = try MiniYAML.parse(text)
        guard case .mapping(let top) = tree else {
            throw UserWorkflowManifestError.yamlSyntax(line: 1, reason: "顶层必须是 mapping")
        }

        func requiredString(_ key: String) throws -> String {
            guard let node = top[key], let s = node.scalarString, !s.isEmpty else {
                throw UserWorkflowManifestError.missingField(key)
            }
            return s
        }
        func optionalString(_ key: String, fallback: String = "") -> String {
            top[key]?.scalarString ?? fallback
        }
        func optionalBool(_ key: String, fallback: Bool) -> Bool {
            guard let s = top[key]?.scalarString?.lowercased() else { return fallback }
            return ["true", "yes", "1", "on"].contains(s)
        }
        func optionalInt(_ key: String, fallback: Int) -> Int {
            guard let s = top[key]?.scalarString, let v = Int(s) else { return fallback }
            return v
        }

        let name = try requiredString("name")
        let version = optionalString("version", fallback: "0.0.1")
        var slash = try requiredString("slash_command").trimmingCharacters(in: .whitespacesAndNewlines)
        if !slash.hasPrefix("/") {
            slash = "/" + slash
        }
        try validateSlashCommand(slash)
        if reservedSlashCommands.contains(slash) {
            throw UserWorkflowManifestError.reservedSlashCommand(slash)
        }

        let displayTitle = optionalString("display_title", fallback: name)
        let shortDesc = optionalString("short_description", fallback: "")
        let placeholder = optionalString("args_placeholder", fallback: "")
        let allowsEmpty = optionalBool("allows_empty_args", fallback: false)
        let maxAgents = max(1, min(8, optionalInt("max_agents", fallback: 1)))

        guard let stepsNode = top["steps"], case .sequence(let stepNodes) = stepsNode, !stepNodes.isEmpty else {
            throw UserWorkflowManifestError.invalidStep(reason: "steps 必须是非空 list")
        }
        var steps: [UserWorkflowManifest.Step] = []
        var seenIDs = Set<String>()
        for (idx, n) in stepNodes.enumerated() {
            guard case .mapping(let m) = n else {
                throw UserWorkflowManifestError.invalidStep(reason: "step #\(idx + 1) 不是 mapping")
            }
            let stepID = (m["id"]?.scalarString ?? "step\(idx + 1)").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stepID.isEmpty else {
                throw UserWorkflowManifestError.invalidStep(reason: "step #\(idx + 1) 缺少 id")
            }
            guard seenIDs.insert(stepID).inserted else {
                throw UserWorkflowManifestError.invalidStep(reason: "step id 重复:\(stepID)")
            }
            let label = (m["label"]?.scalarString ?? stepID)
            guard let prompt = m["prompt"]?.scalarString, !prompt.isEmpty else {
                throw UserWorkflowManifestError.invalidStep(reason: "step \(stepID) 缺少 prompt")
            }
            steps.append(.init(id: stepID, label: label, prompt: prompt))
        }

        let summary = optionalString("summary", fallback: defaultSummaryTemplate(steps: steps))

        return UserWorkflowManifest(
            name: name,
            version: version,
            slashCommand: slash,
            displayTitle: displayTitle,
            shortDescription: shortDesc,
            argsPlaceholder: placeholder,
            allowsEmptyArgs: allowsEmpty,
            maxAgents: maxAgents,
            steps: steps,
            summaryTemplate: summary,
            sourceURL: sourceURL
        )
    }

    private static func defaultSummaryTemplate(steps: [UserWorkflowManifest.Step]) -> String {
        let pieces = steps.map { "## \($0.label)\n\n{{steps.\($0.id).output}}" }
        return pieces.joined(separator: "\n\n")
    }

    private static func validateSlashCommand(_ s: String) throws {
        guard s.hasPrefix("/"), s.count >= 2 else {
            throw UserWorkflowManifestError.slashCommandShape(s)
        }
        let rest = s.dropFirst()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        for scalar in rest.unicodeScalars {
            if !allowed.contains(scalar) {
                throw UserWorkflowManifestError.slashCommandShape(s)
            }
        }
    }
}

// MARK: - Mini YAML parser

/// 极简 YAML 子集解析。只用于 workflow.yaml,不要拿去解析任意 YAML。
/// 支持:
///   - 2-space 缩进的 mapping 嵌套
///   - sequence 用 `- ` 前缀,sequence item 可以是 inline scalar 或 mapping
///   - block scalar `|`,保留换行,自动 dedent 到最浅一行的缩进
///   - `# ...` 行注释
///   - quoted `"..."` 或 `'...'` 标量
///   - bool / number 都按字符串读,后续业务层自己转
enum MiniYAML {
    indirect enum Node: Equatable {
        case scalar(String)
        case mapping([String: Node])
        case sequence([Node])

        var scalarString: String? {
            if case .scalar(let s) = self { return s }
            return nil
        }
    }

    static func parse(_ text: String) throws -> Node {
        let raw = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let rawLines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var lines: [Line] = []
        for (i, l) in rawLines.enumerated() {
            lines.append(Line(text: l, originalIndex: i + 1))
        }
        var parser = Parser(lines: lines, cursor: 0)
        return try parser.parseBlock(minIndent: 0)
    }

    private struct Line {
        let text: String
        let originalIndex: Int

        var indent: Int {
            var n = 0
            for c in text {
                if c == " " { n += 1 } else { break }
            }
            return n
        }
        var trimmed: String {
            text.trimmingCharacters(in: .whitespaces)
        }
        var isBlankOrComment: Bool {
            let t = trimmed
            return t.isEmpty || t.hasPrefix("#")
        }
    }

    private struct Parser {
        let lines: [Line]
        var cursor: Int

        mutating func skipBlanks() {
            while cursor < lines.count, lines[cursor].isBlankOrComment {
                cursor += 1
            }
        }

        /// 解析从当前 cursor 开始,缩进 >= minIndent 的 block。
        /// 返回 mapping / sequence / scalar。
        mutating func parseBlock(minIndent: Int) throws -> Node {
            skipBlanks()
            guard cursor < lines.count else { return .mapping([:]) }
            let first = lines[cursor]
            let indent = first.indent
            if indent < minIndent {
                return .mapping([:])
            }
            let stripped = first.trimmed
            if stripped.hasPrefix("- ") || stripped == "-" {
                return try parseSequence(indent: indent)
            } else {
                return try parseMapping(indent: indent)
            }
        }

        mutating func parseMapping(indent: Int) throws -> Node {
            var result: [String: Node] = [:]
            while cursor < lines.count {
                skipBlanks()
                if cursor >= lines.count { break }
                let line = lines[cursor]
                if line.indent < indent { break }
                if line.indent > indent {
                    throw UserWorkflowManifestError.yamlSyntax(
                        line: line.originalIndex,
                        reason: "意外缩进 \(line.indent),期望 \(indent)"
                    )
                }
                let text = line.trimmed
                if text.hasPrefix("- ") {
                    // 上层 sequence,交还
                    break
                }
                guard let colonIdx = findKeyColon(in: text) else {
                    throw UserWorkflowManifestError.yamlSyntax(
                        line: line.originalIndex,
                        reason: "缺少 `:` —— `\(text)`"
                    )
                }
                let key = String(text[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                let valuePart = String(text[text.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                cursor += 1

                if valuePart == "|" || valuePart == "|-" || valuePart == "|+" {
                    let chomp: BlockChomp = (valuePart == "|-") ? .strip : (valuePart == "|+" ? .keep : .clip)
                    let block = try readBlockScalar(parentIndent: indent, chomp: chomp)
                    result[key] = .scalar(block)
                } else if valuePart.isEmpty {
                    // 嵌套
                    let nested = try parseBlock(minIndent: indent + 1)
                    result[key] = nested
                } else {
                    result[key] = .scalar(parseInlineScalar(valuePart))
                }
            }
            return .mapping(result)
        }

        mutating func parseSequence(indent: Int) throws -> Node {
            var items: [Node] = []
            while cursor < lines.count {
                skipBlanks()
                if cursor >= lines.count { break }
                let line = lines[cursor]
                if line.indent < indent { break }
                let text = line.trimmed
                guard text.hasPrefix("- ") || text == "-" else { break }
                if line.indent != indent { break }

                // 把 "- foo: bar" 改写为同 indent 下的 mapping line "foo: bar"
                // 让 parseMapping 接管。再把后续更深缩进行也当作此 item 的延续。
                let afterDash = text == "-" ? "" : String(text.dropFirst(2))
                let itemIndent = indent + 2
                if afterDash.isEmpty {
                    // 下面应该是更深缩进的 mapping 或 sequence
                    cursor += 1
                    let nested = try parseBlock(minIndent: itemIndent)
                    items.append(nested)
                    continue
                }

                // 在 afterDash 是 "key: value" 形式时,把当前行临时改写
                // 为 mapping 第一行,再让 parseMapping 从 itemIndent 接管。
                if findKeyColon(in: afterDash) != nil {
                    // 用 stub 重新组织本行 + 后续行
                    var rewritten: [Line] = []
                    let pad = String(repeating: " ", count: itemIndent)
                    rewritten.append(Line(text: pad + afterDash, originalIndex: line.originalIndex))
                    // 后续更深缩进行（>= itemIndent）算这个 item 的延续
                    var look = cursor + 1
                    while look < lines.count {
                        let nxt = lines[look]
                        if nxt.isBlankOrComment {
                            rewritten.append(nxt)
                            look += 1
                            continue
                        }
                        if nxt.indent < itemIndent { break }
                        rewritten.append(nxt)
                        look += 1
                    }
                    var sub = Parser(lines: rewritten, cursor: 0)
                    let nested = try sub.parseMapping(indent: itemIndent)
                    items.append(nested)
                    cursor = look
                } else {
                    // 单 scalar item
                    items.append(.scalar(parseInlineScalar(afterDash)))
                    cursor += 1
                }
            }
            return .sequence(items)
        }

        /// 读 `|` block scalar:吃所有缩进 > parentIndent 的行作为内容,
        /// 自动 dedent 到最浅一行。
        mutating func readBlockScalar(parentIndent: Int, chomp: BlockChomp) throws -> String {
            var collected: [String] = []
            var contentIndent = -1
            while cursor < lines.count {
                let line = lines[cursor]
                let isBlank = line.trimmed.isEmpty
                if isBlank {
                    collected.append("")
                    cursor += 1
                    continue
                }
                if line.indent <= parentIndent { break }
                if contentIndent < 0 { contentIndent = line.indent }
                let stripCount = min(line.indent, contentIndent)
                let stripped = String(line.text.dropFirst(stripCount))
                collected.append(stripped)
                cursor += 1
            }
            // 去掉首尾空行
            while collected.first == "" { collected.removeFirst() }
            switch chomp {
            case .strip:
                while collected.last == "" { collected.removeLast() }
                return collected.joined(separator: "\n")
            case .clip:
                while collected.last == "" { collected.removeLast() }
                return collected.joined(separator: "\n") + "\n"
            case .keep:
                return collected.joined(separator: "\n") + "\n"
            }
        }

        private func findKeyColon(in text: String) -> String.Index? {
            // 简化:第一个 `: ` 或行尾的 `:`,但跳过 quoted "..." 内部
            var inDouble = false
            var inSingle = false
            var i = text.startIndex
            while i < text.endIndex {
                let c = text[i]
                if c == "\"" && !inSingle { inDouble.toggle() }
                else if c == "'" && !inDouble { inSingle.toggle() }
                else if c == ":" && !inDouble && !inSingle {
                    let next = text.index(after: i)
                    if next == text.endIndex || text[next] == " " {
                        return i
                    }
                }
                i = text.index(after: i)
            }
            return nil
        }

        private func parseInlineScalar(_ raw: String) -> String {
            var s = raw
            // 去掉行尾注释（裸 scalar 时）
            if !s.hasPrefix("\""), !s.hasPrefix("'") {
                if let hash = s.firstIndex(of: "#") {
                    // 仅当前面是空白时才算注释
                    let prev = s.index(before: hash)
                    if hash == s.startIndex || s[prev] == " " {
                        s = String(s[..<hash]).trimmingCharacters(in: .whitespaces)
                    }
                }
            }
            if s.count >= 2 {
                if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
                    s.removeFirst()
                    s.removeLast()
                }
            }
            return s
        }
    }

    private enum BlockChomp {
        case clip
        case strip
        case keep
    }
}
