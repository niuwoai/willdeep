import Foundation

/// A non-executing lexer for policy inspection. Quoted arguments remain data;
/// only shell substitution and explicitly identified interpreter payloads are code.
/// Unsupported syntax is reported, never handed back to substring matching.
nonisolated enum AgentCommandInspection {
    struct Word: Equatable {
        var text: String
        var dynamic = false
        var quoted = false
        var substitutions: [String] = []
        var sensitiveContent = false
    }
    struct Redirect {
        let operation: String
        let target: Word
        let descriptor: String
        var writes: Bool { operation.contains(">") || operation == "<>" }
        var duplicatesDescriptor: Bool { [">&", "<&"].contains(operation) && (Int(target.text) != nil || target.text == "-") }
    }
    struct Invocation {
        var words: [Word] = []
        var redirects: [Redirect] = []
        var pipeFromPrevious = false
        var source = ""
        var name: String { words.first.map { ($0.text as NSString).lastPathComponent } ?? "" }
        var args: [String] { words.dropFirst().map(\.text) }
    }
    struct Result {
        var commands: [Invocation] = []
        var unsupported: [String] = []
    }

    static func parse(_ source: String) -> Result {
        var scanner = Scanner(source)
        return scanner.run()
    }

    private struct Scanner {
        let characters: [Character]
        let source: String
        var index = 0
        var result = Result()
        var invocation = Invocation()
        var word = Word(text: "")
        var wordStarted = false
        var quote: Character?
        var pendingRedirect: String?
        var pendingDescriptor = ""

        init(_ source: String) { self.source = source; characters = Array(source) }

        mutating func flushWord() {
            guard wordStarted else { return }
            if let operation = pendingRedirect {
                invocation.redirects.append(Redirect(operation: operation, target: word, descriptor: pendingDescriptor))
                pendingRedirect = nil
            } else { invocation.words.append(word) }
            word = Word(text: ""); wordStarted = false
        }

        mutating func flushCommand(pipeline: Bool = false) {
            flushWord()
            if pendingRedirect != nil { result.unsupported.append("missing redirection target"); pendingRedirect = nil }
            if !invocation.words.isEmpty || !invocation.redirects.isEmpty {
                invocation.source = source
                result.commands.append(invocation)
            }
            invocation = Invocation(pipeFromPrevious: pipeline)
        }

        mutating func run() -> Result {
            while index < characters.count {
                let c = characters[index]
                if c == "\\", quote != "'" {
                    index += 1
                    guard index < characters.count else { result.unsupported.append("trailing escape"); break }
                    let next = characters[index]
                    if next != "\n" {
                        if quote == "\"", !["$", "`", "\"", "\\"].contains(next) { word.text.append("\\") }
                        word.text.append(next); wordStarted = true
                    }
                    index += 1; continue
                }
                if c == "'" || c == "\"" {
                    if quote == nil { quote = c; word.quoted = true; wordStarted = true; index += 1; continue }
                    if quote == c { quote = nil; index += 1; continue }
                }
                if quote != "'", c == "$", peek(1) == "(" {
                    captureSubstitution(backtick: false); continue
                }
                if quote != "'", c == "`" {
                    captureSubstitution(backtick: true); continue
                }
                if quote != "'", c == "$" {
                    word.dynamic = true
                }
                if quote == nil {
                    if c == "#", !wordStarted {
                        while index < characters.count, characters[index] != "\n" { index += 1 }
                        continue
                    }
                    if c == "\n" || c == ";" || c == "|" || (c == "&" && peek(1) != ">") {
                        let pipeline = c == "|" && peek(1) != "|"
                        flushCommand(pipeline: pipeline)
                        if peek(1) == c || (c == "|" && peek(1) == "&") { index += 1 }
                        index += 1; continue
                    }
                    if c == "<" || c == ">" || (c == "&" && peek(1) == ">") {
                        readRedirect(); continue
                    }
                    if c == "(" || c == ")" {
                        result.unsupported.append("shell grouping or function syntax")
                        flushCommand(); index += 1; continue
                    }
                    if c.isWhitespace { flushWord(); index += 1; continue }
                }
                word.text.append(c); wordStarted = true; index += 1
            }
            if quote != nil { result.unsupported.append("unterminated quote") }
            flushCommand()
            return result
        }

        func peek(_ offset: Int) -> Character? {
            index + offset < characters.count ? characters[index + offset] : nil
        }

        mutating func readRedirect() {
            var descriptor: String?
            // Adjacent, unquoted digits are the source descriptor, not argv.
            if wordStarted, !word.quoted, !word.text.isEmpty, word.text.allSatisfy(\.isNumber) {
                descriptor = word.text
                word = Word(text: ""); wordStarted = false
            } else { flushWord() }
            var operation = String(characters[index]); index += 1
            if index < characters.count, [">", "<", "&", "|"].contains(characters[index]) {
                operation.append(characters[index]); index += 1
            }
            if operation == "<<" {
                // Do not reinterpret a heredoc body as executable commands.
                result.unsupported.append("here-document")
                index = characters.count
                return
            }
            if pendingRedirect != nil { result.unsupported.append("missing redirection target") }
            pendingRedirect = operation
            pendingDescriptor = descriptor ?? (operation.hasPrefix("&") ? "*" : (operation.hasPrefix("<") ? "0" : "1"))
        }

        mutating func captureSubstitution(backtick: Bool) {
            index += backtick ? 1 : 2
            let start = index
            var depth = 1
            var innerQuote: Character?
            var escaped = false
            while index < characters.count {
                let c = characters[index]
                if escaped { escaped = false; index += 1; continue }
                if c == "\\", innerQuote != "'" { escaped = true; index += 1; continue }
                if backtick, c == "`" { depth = 0; break }
                if c == "'" || c == "\"" {
                    if innerQuote == c { innerQuote = nil }
                    else if innerQuote == nil { innerQuote = c }
                }
                if !backtick, innerQuote == nil {
                    if c == "(" { depth += 1 }
                    if c == ")" { depth -= 1; if depth == 0 { break } }
                }
                index += 1
            }
            if depth != 0 { result.unsupported.append("unterminated substitution") }
            let body = String(characters[start..<index])
            word.substitutions.append(body)
            word.dynamic = true; wordStarted = true
            word.text += "__willdeep_substitution__"
            if index < characters.count { index += 1 }
        }
    }
}
