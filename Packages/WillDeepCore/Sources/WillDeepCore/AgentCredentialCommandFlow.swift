import Foundation

/// Bounded source/sink analysis. A semicolon is not a pipe, an SSH identity
/// option is not file contents, and a filename printed by echo is not a read.
nonisolated enum AgentCredentialCommandFlow {
    struct Result { var exfiltrates = false; var sensitiveOutput = false }
    typealias Invocation = AgentCommandInspection.Invocation

    static func inspect(_ call: Invocation, stdinSensitive: Bool) -> Result {
        let name = call.name
        let args = call.args
        let argumentSensitive = call.words.dropFirst().contains(where: \.sensitiveContent)
        let inputRedirects = call.redirects.filter { !$0.writes && !$0.duplicatesDescriptor && $0.descriptor == "0" }
        let input = inputRedirects.isEmpty ? stdinSensitive : inputRedirects.contains { sensitivePath($0.target.text) }
        if ["scp", "sftp", "rsync"].contains(name) {
            let valueOptions: Set<String> = name == "rsync"
                ? ["-e", "--rsh", "--exclude", "--include", "--filter", "--port", "--password-file"]
                : ["-i", "-o", "-P", "-F", "-S", "-c", "-J", "-l"]
            let operands = AgentCommandInvocation.positionals(args, valueOptions: valueOptions)
            guard let destination = operands.last, remotePath(destination) else { return Result() }
            return Result(exfiltrates: operands.dropLast().contains(where: sensitivePath))
        }
        if ["curl", "wget", "http", "https"].contains(name) {
            let payloads = uploadPayloads(args, command: name)
            let sendsInput = payloads.contains { $0 == "@-" || $0 == "-" }
            let files = payloads.contains { value in
                sensitivePath(value.hasPrefix("@") ? String(value.dropFirst()) : value)
            }
            return Result(exfiltrates: files || (sendsInput && input) || sentSensitiveArgument(call))
        }
        if ["nc", "ncat", "netcat", "mail", "sendmail", "ftp"].contains(name) || (name == "openssl" && args.first == "s_client") {
            return Result(exfiltrates: input || argumentSensitive)
        }
        if name == "security", ["find-generic-password", "find-internet-password", "dump-keychain"].contains(args.first ?? "") {
            return Result(sensitiveOutput: true)
        }
        if name == "dd" {
            let writesFile = args.contains { $0.hasPrefix("of=") && $0 != "of=/dev/stdout" && $0 != "of=/dev/fd/1" }
            return Result(sensitiveOutput: !writesFile && args.contains { $0.hasPrefix("if=") && sensitivePath(String($0.dropFirst(3))) })
        }
        let readers: Set<String> = ["cat", "head", "tail", "less", "more", "base64", "xxd", "od", "strings", "tar", "gzip", "openssl"]
        let filters: Set<String> = ["sed", "awk", "grep", "rg", "sort", "uniq", "cut", "tr", "tee"]
        if readers.contains(name) {
            let paths = AgentCommandInvocation.positionals(args, valueOptions: ["-n", "-c", "-f", "-o", "-out"])
            return Result(sensitiveOutput: input || paths.contains(where: sensitivePath))
        }
        if filters.contains(name) {
            let valueOptions: Set<String> = name == "awk" ? ["-f", "-F", "-v"] : ["-e", "-f"]
            var paths = AgentCommandInvocation.positionals(args, valueOptions: valueOptions)
            if ["sed", "awk", "grep", "rg"].contains(name), !args.contains("-e"), !args.contains("-f"), !paths.isEmpty { paths.removeFirst() }
            if ["grep", "rg"].contains(name), args.contains("-c") || args.contains("--count") { return Result() }
            return Result(sensitiveOutput: input || paths.contains(where: sensitivePath))
        }
        if ["echo", "printf"].contains(name) { return Result(sensitiveOutput: argumentSensitive) }
        return Result()
    }

    private static func sentSensitiveArgument(_ call: Invocation) -> Bool {
        let words = Array(call.words.dropFirst())
        // Local filenames/format strings are not sent over the wire.
        let localValues: Set<String> = ["-o", "--output", "-O", "--output-document", "-w", "--write-out", "--stderr", "--trace", "--trace-ascii"]
        var index = 0
        while index < words.count {
            let word = words[index]
            if localValues.contains(word.text) { index += 2; continue }
            if localValues.contains(where: { $0.hasPrefix("--") && word.text.hasPrefix($0 + "=") }) { index += 1; continue }
            if word.sensitiveContent { return true }
            index += 1
        }
        return false
    }

    static func sensitivePath(_ raw: String) -> Bool {
        var path = raw
        if let colon = path.firstIndex(of: ":"), !path.hasPrefix("/"), !path.hasPrefix("~") { path = String(path[path.index(after: colon)...]) }
        let components = path.split(separator: "/").map(String.init)
        guard let last = components.last else { return false }
        if last == ".env" || last.hasPrefix(".env.") || ["id_rsa", "id_ed25519", "id_ecdsa", ".netrc", "credentials.json"].contains(last) { return true }
        if last.hasSuffix(".keychain") || last.hasSuffix(".keychain-db") { return true }
        let suffixes = [".aws/credentials", ".docker/config.json", ".kube/config", ".config/gh/hosts.yml", ".config/gh/hosts", ".gnupg"]
        return suffixes.contains { path == $0 || path.hasSuffix("/" + $0) } || components.contains(".gnupg")
    }

    private static func remotePath(_ path: String) -> Bool {
        path.contains(":") && !path.hasPrefix("/") && !path.hasPrefix("./")
    }

    private static func uploadPayloads(_ args: [String], command: String) -> [String] {
        let options: Set<String> = command == "wget"
            ? ["--post-file", "--body-file"]
            : ["-d", "--data", "--data-binary", "--data-urlencode", "-T", "--upload-file", "-F", "--form"]
        var payloads: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "--" { break }
            var value: String?
            var option = arg
            if options.contains(arg), index + 1 < args.count { index += 1; value = args[index] }
            else if let key = options.first(where: { $0.hasPrefix("--") && arg.hasPrefix($0 + "=") }) {
                option = key; value = String(arg.dropFirst(key.count + 1))
            } else if let key = options.first(where: { !$0.hasPrefix("--") && arg.hasPrefix($0) && arg.count > $0.count }) {
                option = key; value = String(arg.dropFirst(key.count))
            }
            if var value {
                if option == "-F" || option == "--form" {
                    value = value.split(separator: "=", maxSplits: 1).last.map(String.init) ?? value
                    value = value.split(separator: ";", maxSplits: 1).first.map(String.init) ?? value
                }
                if option == "--data-urlencode", let at = value.firstIndex(of: "@") { value = String(value[at...]) }
                if option == "-T" || option == "--upload-file" || command == "wget" || value.hasPrefix("@") || value.contains("__willdeep_substitution__") { payloads.append(value) }
            }
            index += 1
        }
        return payloads
    }
}
