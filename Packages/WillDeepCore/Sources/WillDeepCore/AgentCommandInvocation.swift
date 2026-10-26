import Foundation

nonisolated enum AgentCommandInvocation {
    typealias Invocation = AgentCommandInspection.Invocation
    typealias Word = AgentCommandInspection.Word

    private static let controlPrefixes: Set<String> = ["if", "then", "elif", "else", "do", "while", "until", "!", "{"]
    private static let simpleWrappers: Set<String> = ["command", "exec", "builtin", "nohup", "time", "setsid"]
    private static let wrapperValues: [String: Set<String>] = [
        "exec": ["-a"],
        "sudo": ["-u", "-g", "-h", "-p", "-C", "-T", "-r", "-t", "-D", "--user", "--group", "--host", "--prompt", "--chdir"],
        "doas": ["-u", "-C"],
        "env": ["-u", "--unset", "-C", "--chdir"],
        "nice": ["-n", "--adjustment"],
        "ionice": ["-c", "-n", "-p", "-P", "-u"],
        "stdbuf": ["-i", "-o", "-e", "--input", "--output", "--error"],
        "timeout": ["-k", "--kill-after", "-s", "--signal"],
        "xargs": ["-I", "-i", "-L", "-l", "-n", "-P", "-s", "-E", "-e", "-d", "--replace", "--max-args", "--max-procs", "--delimiter"]
    ]

    static func assignment(_ word: Word) -> (String, String)? {
        guard let equal = word.text.firstIndex(of: "=") else { return nil }
        let name = String(word.text[..<equal])
        guard let first = name.first, first.isLetter || first == "_",
              name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        return (name, String(word.text[word.text.index(after: equal)...]))
    }

    static func unwrap(_ original: Invocation) -> Invocation {
        var result = original
        while let first = result.words.first {
            if assignment(first) != nil || (!first.quoted && controlPrefixes.contains(first.text)) {
                result.words.removeFirst(); continue
            }
            let name = result.name
            guard simpleWrappers.contains(name) || wrapperValues[name] != nil else { break }
            // `command -v nc` only prints a path.
            if name == "command", result.args.contains(where: { ["-v", "-V"].contains($0) }) {
                result.words = []; break
            }
            result.words.removeFirst()
            while let option = result.words.first, option.text.hasPrefix("-") {
                result.words.removeFirst()
                if option.text == "--" { break }
                if wrapperValues[name]?.contains(option.text) == true, !result.words.isEmpty {
                    result.words.removeFirst()
                }
            }
            if name == "timeout", !result.words.isEmpty { result.words.removeFirst() }
        }
        return result
    }

    static func sshPayload(_ invocation: Invocation) -> String? {
        let tokens = invocation.words.map(\.text)
        guard invocation.name == "ssh", let host = sshHostIndex(tokens), host + 1 < tokens.count else { return nil }
        return tokens.dropFirst(host + 1).joined(separator: " ")
    }

    private static func sshHostIndex(_ tokens: [String]) -> Int? {
        let values: Set<String> = ["-b", "-c", "-D", "-E", "-e", "-F", "-i", "-J", "-L", "-l", "-m", "-O", "-o", "-p", "-Q", "-R", "-S", "-W", "-w"]
        var index = 1
        while index < tokens.count {
            let token = tokens[index]
            if token == "--" { return index + 1 < tokens.count ? index + 1 : nil }
            if values.contains(token) { index += 2; continue }
            if token.hasPrefix("-") { index += 1; continue }
            return index
        }
        return nil
    }

    static func shellPayload(_ invocation: Invocation) -> String? {
        guard ["sh", "bash", "zsh", "dash", "ksh"].contains(invocation.name) else { return nil }
        let args = invocation.args
        var index = 0
        while index < args.count {
            let arg = args[index]
            guard arg != "--", arg.hasPrefix("-") else { return nil }
            if arg == "-o" || arg == "-O" { index += 2; continue }
            if !arg.hasPrefix("--"), arg.dropFirst().contains("c") {
                return index + 1 < args.count ? args[index + 1] : nil
            }
            index += 1
        }
        return nil
    }

    static func positionals(_ args: [String], valueOptions: Set<String> = []) -> [String] {
        var result: [String] = []
        var options = true
        var index = 0
        while index < args.count {
            let arg = args[index]
            if options, arg == "--" { options = false; index += 1; continue }
            if options, valueOptions.contains(arg) { index += 2; continue }
            if options, arg.hasPrefix("-"), arg != "-" { index += 1; continue }
            result.append(arg); index += 1
        }
        return result
    }

    static func hasFlag(_ args: [String], short: Character, long: String) -> Bool {
        for arg in args {
            if arg == "--" { break }
            if arg == long { return true }
            if arg.hasPrefix("-"), !arg.hasPrefix("--"), arg.dropFirst().contains(short) { return true }
        }
        return false
    }
}
