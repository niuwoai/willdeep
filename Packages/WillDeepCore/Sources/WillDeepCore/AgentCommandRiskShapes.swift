import Foundation

nonisolated enum AgentCommandRiskShapes {
    typealias Invocation = AgentCommandInspection.Invocation
    typealias Match = AgentMaliciousCommandDenylist.Match

    static func match(_ call: Invocation, remote: Bool, workingDirectory: URL?) -> Match? {
        let name = call.name
        let args = call.args
        func hit(_ id: String, _ reason: String) -> Match { Match(ruleID: id, reason: reason, segment: call.source) }
        if name == "rm", AgentCommandInvocation.hasFlag(args, short: "r", long: "--recursive") || AgentCommandInvocation.hasFlag(args, short: "R", long: "--recursive"),
           let path = AgentCommandInvocation.positionals(args).first(where: { path in
               !literalExpansion(path, in: call) && criticalPath(path, remote: remote, cwd: workingDirectory)
           }) {
            return hit("recursive-remove-critical-root", "递归删除系统或主目录：\(path)")
        }
        if name == "mkfs" || name.hasPrefix("mkfs.") || name == "newfs" || name.hasPrefix("newfs.") ||
            (name == "diskutil" && args.first.map { ["eraseDisk", "zeroDisk", "partitionDisk", "reformat", "eraseVolume"].contains($0) } == true) {
            return hit("format-volume", "该命令执行磁盘格式化或重新分区")
        }
        if name == "dd", let target = args.first(where: { $0.hasPrefix("of=") }).map({ String($0.dropFirst(3)) }), rawDevice(target) {
            return hit("dd-to-raw-device", "dd 写入裸设备：\(target)")
        }
        for redirect in call.redirects where redirect.writes && !redirect.duplicatesDescriptor {
            if rawDevice(redirect.target.text) { return hit("redirect-to-raw-device", "重定向写入裸设备：\(redirect.target.text)") }
            if authorizedKeys(redirect.target.text) { return hit("ssh-key-implant", "重定向写入 SSH authorized_keys") }
            if shellHistory(redirect.target.text) { return hit("wipe-shell-history", "重定向改写 shell 历史文件") }
            let literalHome = redirect.target.quoted && !redirect.target.dynamic &&
                (redirect.target.text.hasPrefix("$") || redirect.target.text.hasPrefix("~"))
            if !remote, !literalHome, let path = AgentHostDataPathPolicy.resolvedPath(token: redirect.target.text, workingDirectory: workingDirectory),
               AgentHostDataPathPolicy.protectedRoot(containing: path) != nil {
                return hit("willdeep-own-data-destruction", "重定向改写 WillDeep 自身数据目录")
            }
        }
        if ["chmod", "chown", "chgrp"].contains(name), AgentCommandInvocation.hasFlag(args, short: "R", long: "--recursive"),
           let path = AgentCommandInvocation.positionals(args).dropFirst().first(where: { path in
               !literalExpansion(path, in: call) && criticalPath(path, remote: remote, cwd: workingDirectory)
           }) {
            return hit("recursive-permission-change-root", "递归改写系统或主目录权限：\(path)")
        }
        if ["tee", "cp", "mv", "install"].contains(name) {
            let paths = AgentCommandInvocation.positionals(args)
            let destinations = name == "tee" ? paths : Array(paths.suffix(1))
            if destinations.contains(where: authorizedKeys) { return hit("ssh-key-implant", "写入 SSH authorized_keys 文件") }
        }
        // macOS /usr/bin/nc -c sends CRLF; it does not execute a program.
        // Do not transfer this local binary's semantics to an SSH host or an
        // unqualified nc resolved through a possibly overridden PATH.
        let knownAppleNetcat = !remote && call.words.first?.text == "/usr/bin/nc" &&
            !args.contains(where: { $0 == "-e" || $0.hasPrefix("--exec") || $0.hasPrefix("--sh-exec") || $0.hasPrefix("--lua-exec") || ($0.hasPrefix("-e") && $0.count > 2) })
        if !knownAppleNetcat, AgentNetcatExecutionMatcher.hasExecutionOption(executable: name, arguments: args) {
            return hit("reverse-shell", "netcat 命令包含执行程序选项（不同实现语义可能不同，需核对）")
        }
        if ["sh", "bash", "zsh", "ksh"].contains(name), AgentCommandInvocation.hasFlag(args, short: "i", long: "--interactive"),
           call.redirects.contains(where: { $0.target.text.hasPrefix("/dev/tcp/") }) {
            return hit("reverse-shell", "交互式 shell 的文件描述符连接到网络端点")
        }
        if name == "history", AgentCommandInvocation.hasFlag(args, short: "c", long: "--clear") { return hit("wipe-shell-history", "清空 shell 历史") }
        if name == "log", args.first == "erase" || (args.first == "collect" && args.contains("--erase")) {
            return hit("wipe-system-log", "执行系统日志清除")
        }
        if ["rm", "unlink", "shred", "truncate"].contains(name), AgentCommandInvocation.positionals(args).contains(where: shellHistory) {
            return hit("wipe-shell-history", "删除或截断 shell 历史文件")
        }
        if (name == "csrutil" && args.first == "disable") || (name == "spctl" && args.contains(where: { ["--master-disable", "--global-disable"].contains($0) })) {
            return hit("disable-security-control", "执行系统安全控制关闭操作")
        }
        let hostArguments = args.filter { !literalExpansion($0, in: call) }
        if !remote, !name.isEmpty, let match = AgentHostDataPathPolicy.mutationHit(tokens: [name] + hostArguments, workingDirectory: workingDirectory) {
            return hit("willdeep-own-data-destruction", "改写 WillDeep 自身数据：\(match.token)")
        }
        return nil
    }

    private static func authorizedKeys(_ path: String) -> Bool { (path as NSString).lastPathComponent == "authorized_keys" }
    private static func shellHistory(_ path: String) -> Bool {
        [".bash_history", ".zsh_history", ".sh_history", ".python_history"].contains((path as NSString).lastPathComponent)
    }
    private static func rawDevice(_ path: String) -> Bool {
        (path as NSString).standardizingPath.range(of: #"^/dev/(?:r?disk\d+(?:s\d+)*|[shv]d[a-z]+\d*|nvme\d+n\d+(?:p\d+)?)$"#, options: .regularExpression) != nil
    }
    private static func literalExpansion(_ path: String, in call: Invocation) -> Bool {
        guard path.hasPrefix("~") || path.hasPrefix("$") else { return false }
        return call.words.dropFirst().contains { $0.text == path && $0.quoted && !$0.dynamic }
    }
    private static func criticalPath(_ original: String, remote: Bool, cwd: URL?) -> Bool {
        if ["~", "~/", "~/*", "$HOME", "${HOME}", "$HOME/", "${HOME}/", "$HOME/*", "${HOME}/*"].contains(original) { return true }
        if original.hasPrefix("$"), original.hasSuffix("/") || original.hasSuffix("/*") { return true }
        var path = original
        if path.hasSuffix("/*") { path = path == "/*" ? "/" : String(path.dropLast(2)) }
        if path.hasPrefix("/") { path = URL(fileURLWithPath: path).standardizedFileURL.path }
        let roots: Set<String> = ["/", "/System", "/usr", "/bin", "/sbin", "/etc", "/var", "/Library", "/Applications", "/Volumes", "/private", "/boot", "/dev", "/opt/homebrew", "/root", "/home", "/Users"]
        if roots.contains(path) { return true }
        if !remote, let url = AgentHostDataPathPolicy.resolvedPath(token: path, workingDirectory: cwd) {
            path = url.resolvingSymlinksInPath().standardizedFileURL.path
            let resolvedRoots = Set(roots.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path })
            if path == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path || resolvedRoots.contains(path) { return true }
        }
        return path.range(of: #"^/(?:Users|home)/[^/]+/?$"#, options: .regularExpression) != nil
    }
}
