import Foundation

nonisolated enum AgentNetcatExecutionMatcher {
    static func hasExecutionOption(executable: String, arguments: [String]) -> Bool {
        guard ["nc", "ncat", "netcat"].contains(executable) else { return false }
        let values: Set<Character> = ["s", "p", "w", "i", "o", "x", "X", "m"]
        let longValues: Set<String> = ["--source", "--source-port", "--wait", "--idle-timeout", "--proxy", "--proxy-type", "--proxy-auth", "--ssl-cert", "--ssl-key"]
        let execution: Set<String> = ["--exec", "--sh-exec", "--lua-exec"]
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            if arg == "--" { return false }
            if execution.contains(arg) { return index + 1 < arguments.count && !arguments[index + 1].isEmpty }
            if execution.contains(where: { arg.hasPrefix($0 + "=") && arg.count > $0.count + 1 }) { return true }
            if longValues.contains(arg) { index += 2; continue }
            if arg.hasPrefix("-"), !arg.hasPrefix("--") {
                let flags = Array(arg.dropFirst())
                for (offset, flag) in flags.enumerated() {
                    if flag == "e" || flag == "c" { return offset + 1 < flags.count || index + 1 < arguments.count }
                    if values.contains(flag) { if offset + 1 == flags.count { index += 1 }; break }
                }
            }
            index += 1
        }
        return false
    }
}
