//
//  AgentMaliciousCommandDenylist.swift
//  WillDeep
//
//  完全访问（`AgentApprovalMode.fullAccess`）的硬地板。
//
//  这份名单和 `SafeCommand.dangerousTokens` 是**两件不同的事**，别合并：
//  那份问「这条命令危险吗」——`rm`、`mv`、`chmod` 全在里面，因为它们值得
//  在常规模式下确认一次；这份问「这条命令是不是在干坏事」。一个写代码的
//  Agent 每天要删几十次 `node_modules`，把那些也拦下来，完全访问就成了
//  改名版的智能审核，等于没做。
//
//  收录标准（四类，缺一不可地窄）：
//   1. **不可逆的大范围破坏**：抹根目录 / 家目录 / 整块磁盘、格式化、
//      往裸设备写、fork bomb；
//   2. **主机接管**：把 root shell 开给外面、往 authorized_keys 塞公钥、
//      装持久化 (launchd/cron/systemd) 指向下载来的东西；
//   3. **反取证**：清历史、抹系统日志、关审计——正经排障不需要毁证据；
//   4. **外泄**：凭据/私钥/keychain 与网络出口在同一条命令里同时出现。
//
//  刻意不收的（完全访问下一律放行，这是这个模式存在的意义）：
//  `rm -rf ./node_modules`、`git reset --hard`、`git push --force` 到功能
//  分支、`docker compose down -v`、`DROP TABLE` 在本地库、`cat .env`。
//  它们可能让人心跳一下，但都不是恶意，而且都在用户自己的工作区语义里。
//
//  命中即**不自动放行**——回落到人工审批卡（该打字确认的仍要打字），
//  不是静默拒绝。完全访问中，没命中的命令直接执行，不再经过 AI 裁判。
//

import Foundation

nonisolated enum AgentMaliciousCommandDenylist {
    /// 一次命中的证据：给用户看的理由 + 触发它的那一段命令。
    struct Match: Equatable, Sendable {
        /// 稳定标识，用于审计与测试断言，不直接展示。
        let ruleID: String
        /// 一句话说明为什么这条被挡下来（中文，直接进审批卡）。
        let reason: String
        /// 命中的那一段（已按 shell 分段），便于用户核对。
        let segment: String
    }

    /// 整条命令按 shell 语义拆段后逐段过；任何一段命中即整条命中。
    /// 条件执行（`a || b`）里的任何一支都算——`|| rm -rf /` 不会因为
    /// 前面那支大概率成功就变得无害。
    static func match(command: String) -> Match? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // 先看整条命令，再拆段。有两类规则拆完就看不见了：
        //  · fork 炸弹 `:(){:|:&};:` 本身由 `|` 和 `;` 组成，分段器会把它
        //    切成几段无意义的碎片，没有任何一段还认得出来；
        //  · 外泄要求「凭据 + 网络出口」同时出现，而这两半天然分居管道两侧
        //    （`cat ~/.ssh/id_rsa | curl …`）。
        if trimmed.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\t", with: "")
            .contains(":(){:|:&};:") {
            return Match(ruleID: "fork-bomb", reason: "fork 炸弹会耗尽进程表，整机失去响应", segment: trimmed)
        }
        if let match = exfiltrationMatch(in: trimmed) {
            return match
        }
        var segments = SafeCommand.splitPipeline(trimmed)
        if segments.isEmpty {
            segments = [trimmed]
        }
        for segment in segments {
            if let match = segmentMatch(segment) {
                return match
            }
        }
        return nil
    }

    // MARK: - 分段规则

    private static func segmentMatch(_ segment: String) -> Match? {
        let raw = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let lowered = raw.lowercased()
        // 空白归一，让 `rm   -rf    /` 和 `rm -rf /` 走同一条规则。
        let squeezed = lowered.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        // 再剥掉提权与包装前缀：`sudo rm -rf /System` 与 `rm -rf /System`
        // 是同一件事，而按 head 匹配的规则只认后者。
        let normalized = strippingWrapperPrefixes(squeezed)

        if let match = destructionMatch(normalized: normalized, segment: raw) {
            return match
        }
        if let match = takeoverMatch(normalized: normalized, segment: raw) {
            return match
        }
        if let match = antiForensicsMatch(normalized: normalized, segment: raw) {
            return match
        }
        return nil
    }

    /// 提权与包装前缀。剥到第一个真正的命令为止；`env FOO=1 rm -rf /`
    /// 里的赋值段也一并跳过。故意不剥 `sh -c`——引号里的东西要不要当命令
    /// 看，是个单独的判断，这里保守地留给分段器和 AI 裁判。
    private static let wrapperPrefixTokens: Set<String> = [
        "sudo", "doas", "nohup", "time", "command", "exec", "builtin", "env",
        "nice", "ionice", "stdbuf", "setsid"
    ]

    private static func strippingWrapperPrefixes(_ normalized: String) -> String {
        var tokens = normalized.split(separator: " ").map(String.init)
        var didStrip = true
        while didStrip, let head = tokens.first {
            didStrip = false
            if wrapperPrefixTokens.contains(head) {
                tokens.removeFirst()
                didStrip = true
                continue
            }
            // sudo 的常见 flag（`sudo -u root rm …`）与 env 赋值（`FOO=1 rm …`）。
            if head.hasPrefix("-") || (head.contains("=") && !head.hasPrefix("/")) {
                tokens.removeFirst()
                didStrip = true
            }
        }
        return tokens.joined(separator: " ")
    }

    // MARK: 1. 不可逆的大范围破坏

    private static func destructionMatch(normalized: String, segment: String) -> Match? {
        if isRecursiveRemoval(normalized), let target = removalTargetsCriticalRoot(normalized) {
            return Match(
                ruleID: "recursive-remove-critical-root",
                reason: "递归删除 \(target)——这是不可逆的大范围破坏，不是清理构建产物",
                segment: segment
            )
        }
        for head in ["mkfs", "mkfs.", "newfs", "diskutil erasedisk", "diskutil zerodisk",
                     "diskutil partitiondisk", "diskutil reformat"]
        where normalized.hasPrefix(head) || normalized.contains(" \(head)") {
            return Match(ruleID: "format-volume", reason: "格式化/重新分区磁盘会抹掉整卷数据", segment: segment)
        }
        // `dd` 只有写向裸设备才算——`dd if=x of=./backup.img` 是正常备份。
        if normalized.hasPrefix("dd ") || normalized.contains(" dd ") {
            if let of = value(ofArgument: "of=", in: normalized), isRawDevicePath(of) {
                return Match(ruleID: "dd-to-raw-device", reason: "dd 直接写裸设备 \(of)，会覆盖整块磁盘", segment: segment)
            }
        }
        // 重定向覆盖裸设备：`> /dev/disk0`、`cat x > /dev/sda`。
        if let redirect = redirectTarget(in: normalized), isRawDevicePath(redirect) {
            return Match(ruleID: "redirect-to-raw-device", reason: "把输出直接覆盖到裸设备 \(redirect)", segment: segment)
        }
        // 递归改权限/属主到系统根：`chmod -R 777 /`、`chown -R x /`。
        for head in ["chmod", "chown", "chgrp"] where normalized.hasPrefix("\(head) ") {
            guard normalized.contains(" -r") || normalized.contains(" --recursive") else { continue }
            if let target = pathArguments(in: normalized).first(where: { isCriticalRoot($0) }) {
                return Match(
                    ruleID: "recursive-permission-change-root",
                    reason: "对 \(target) 递归改权限/属主会破坏系统完整性",
                    segment: segment
                )
            }
        }
        return nil
    }

    private static func isRecursiveRemoval(_ normalized: String) -> Bool {
        guard normalized.hasPrefix("rm ") || normalized == "rm" || normalized.hasPrefix("rm\t") else { return false }
        // `-rf`、`-fr`、`-r -f`、`--recursive` 都算；不带递归的 `rm x` 不算。
        return normalized.contains(" -r") || normalized.contains(" --recursive")
            || normalized.contains(" -fr") || normalized.contains(" -rf")
    }

    /// 递归删除是否指向了根、家目录、或系统关键目录。
    private static func removalTargetsCriticalRoot(_ normalized: String) -> String? {
        for path in pathArguments(in: normalized) where isCriticalRoot(path) {
            return path
        }
        return nil
    }

    /// 判定「不该被整体删掉/改掉」的目标。`/*`、`~`、`$HOME`、`/System` 等。
    private static func isCriticalRoot(_ path: String) -> Bool {
        let p = path.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if p == "/" || p == "/*" || p == "/." { return true }
        if p == "~" || p == "~/" || p == "~/*" { return true }
        if p == "$home" || p == "${home}" || p == "$home/" || p == "$home/*" { return true }
        // 变量未定义时 `rm -rf $UNSET/` 会退化成 `rm -rf /` —— 经典事故。
        if p.hasPrefix("$") && (p.hasSuffix("/") || p.hasSuffix("/*")) { return true }
        let criticalPrefixes = [
            "/system", "/usr", "/bin", "/sbin", "/etc", "/var", "/library",
            "/applications", "/volumes", "/private", "/boot", "/dev", "/opt/homebrew"
        ]
        for prefix in criticalPrefixes {
            if p == prefix || p == prefix + "/" || p == prefix + "/*" { return true }
            // `/usr/local/bin` 这类二级目录不算——只拦整块。
            if p == prefix + "/*" { return true }
        }
        // 家目录整体：`/users/<name>` 或 `/users/<name>/`。
        if p.hasPrefix("/users/") {
            let rest = p.dropFirst("/users/".count).trimmingCharacters(in: CharacterSet(charactersIn: "/*"))
            if !rest.isEmpty, !rest.contains("/") { return true }
        }
        return false
    }

    // MARK: 2. 主机接管

    private static func takeoverMatch(normalized: String, segment: String) -> Match? {
        // 下载即执行：`curl … | sh`、`wget -O- … | bash`。整条命令级别的
        // 判定放在 exfiltration 之外单独做，这里看单段里的自包含形态。
        if normalized.contains("authorized_keys"),
           normalized.contains(">>") || normalized.hasPrefix("tee ") || normalized.contains(" tee ") {
            return Match(ruleID: "ssh-key-implant", reason: "往 authorized_keys 写入公钥＝给外部留下常驻登录后门", segment: segment)
        }
        // 反弹 shell 的几种经典形态。
        if normalized.contains("/dev/tcp/") && (normalized.contains("sh -i") || normalized.contains("bash -i")) {
            return Match(ruleID: "reverse-shell", reason: "反弹 shell：把本机交互式 shell 接到外部主机", segment: segment)
        }
        if (normalized.contains("nc ") || normalized.contains("ncat ") || normalized.contains("netcat "))
            && (normalized.contains(" -e ") || normalized.contains(" -c ")) {
            return Match(ruleID: "reverse-shell", reason: "netcat 反弹 shell：把命令执行能力交给外部连接", segment: segment)
        }
        return nil
    }

    // MARK: 3. 反取证

    private static func antiForensicsMatch(normalized: String, segment: String) -> Match? {
        if normalized.hasPrefix("history -c") || normalized.contains("history -c") {
            return Match(ruleID: "wipe-shell-history", reason: "清空 shell 历史属于消除痕迹，排障从不需要它", segment: segment)
        }
        for pattern in ["log erase", "log collect --erase"] where normalized.contains(pattern) {
            return Match(ruleID: "wipe-system-log", reason: "抹除系统统一日志会毁掉排障与审计证据", segment: segment)
        }
        if normalized.contains("rm ") || normalized.hasPrefix("rm") {
            for history in [".bash_history", ".zsh_history", ".sh_history", ".python_history"]
            where normalized.contains(history) {
                return Match(ruleID: "wipe-shell-history", reason: "删除 shell 历史文件属于消除痕迹", segment: segment)
            }
        }
        if normalized.contains("csrutil disable") || normalized.contains("spctl --master-disable") {
            return Match(ruleID: "disable-security-control", reason: "关闭系统安全控制（SIP/Gatekeeper）", segment: segment)
        }
        return nil
    }

    // MARK: 4. 外泄（整条命令级别）

    /// 凭据来源与网络出口**同时**出现才算。单独 `cat .env` 在完全访问下
    /// 放行——那是排配置，不是外泄；单独 `curl https://api…` 也放行。
    private static func exfiltrationMatch(in command: String) -> Match? {
        let lowered = credentialScanText(command)
        let credentialNeedles = [
            "/.ssh/id_", "id_rsa", "id_ed25519", "id_ecdsa", "/.aws/credentials",
            "/.gnupg", "keychain", "security find-generic-password",
            "security dump-keychain", "/.config/gh/hosts", "credentials.json",
            "/.docker/config.json", "/.kube/config", "/.netrc"
        ]
        var credential = credentialNeedles.first(where: { lowered.contains($0) })
        if credential == nil, referencesDotEnvFile(lowered) {
            credential = ".env"
        }
        guard let credential else {
            return nil
        }
        // 出口命令必须真的**是**某一段的命令头。裸子串匹配会把
        // `journalctl -u some-mail-service` 里的 `mail ` 当成发信出口，审计
        // 日志里有实锤：一条纯读的 `ssh … journalctl …` 被判成私钥外泄。
        let egressHeads: Set<String> = [
            "curl", "wget", "nc", "ncat", "netcat", "scp", "rsync",
            "ftp", "sftp", "mail", "sendmail"
        ]
        let egressSubstrings = ["http post", "requests.post", "openssl s_client"]
        let egress = segmentHeads(in: lowered).first(where: { egressHeads.contains($0) })
            ?? egressSubstrings.first(where: { lowered.contains($0) })
        guard let egress else {
            return nil
        }
        // 例外：把凭据**取回本机**不是外泄（`scp server:~/.ssh/config .`）。
        // 只在凭据出现在出口命令的输入侧时才算，这里用一个保守判据：
        // 出口命令带上传语义（POST/--data/-d/-T/@file）或凭据在管道左侧。
        // `@` 曾经在这个列表里，于是每一条 `user@host` 的 ssh/scp 都命中
        // 「上传语义」，例外保护形同虚设；`post` / `put` 裸子串同样会被
        // `output`、`input`、`compose`、`postgres` 命中。现在上传标记必须是
        // 独立的 flag 或 `@file` 形态的取值，不再靠子串碰运气。
        let uploadMarkers = [
            "--data", "--data-binary", "--data-raw", " -d ", "--upload-file",
            " -t ", " --form", " -f ", "--request post", "--request put",
            "-x post", "-x put", "http post", "http put"
        ]
        let credentialIsUpstream = lowered.range(of: credential).map { range in
            lowered.range(of: "|").map { $0.lowerBound > range.lowerBound } ?? false
        } ?? false
        let looksLikeUpload = uploadMarkers.contains { lowered.contains($0) }
        guard credentialIsUpstream || looksLikeUpload else { return nil }
        return Match(
            ruleID: "credential-exfiltration",
            reason: "凭据/私钥（\(credential)）与网络出口（\(egress.trimmingCharacters(in: .whitespaces))）出现在同一条命令里",
            segment: command
        )
    }

    // MARK: - 外泄判据的小工具

    /// 扫凭据前先摘掉 `ssh`/`scp`/`sftp` 的 `-i <私钥>`：那是**拿钥匙登录**，
    /// 不是把钥匙发出去。留着它，每条 `ssh -i ~/.ssh/id_rsa root@host` 都会
    /// 被判成外泄而直接 deny，连裁判都见不到。远端 `cat ~/.ssh/id_rsa`、
    /// `scp host:~/.ssh/id_rsa .` 这些真正读取密钥的形态照常命中。
    private static func credentialScanText(_ command: String) -> String {
        let lowered = command.lowercased()
        var scanned: [String] = []
        var index = 0
        let tokens = lowered.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var sshFamilyActive = false
        while index < tokens.count {
            let token = tokens[index]
            let bare = token.trimmingCharacters(in: CharacterSet(charactersIn: "'\"`;|&(){}"))
            if ["ssh", "scp", "sftp"].contains(where: { bare == $0 || bare.hasSuffix("/\($0)") }) {
                sshFamilyActive = true
            }
            if sshFamilyActive, token == "-i" {
                index += 2
                continue
            }
            if sshFamilyActive, token.hasPrefix("-i"), !token.hasPrefix("--"), token.count > 2 {
                index += 1
                continue
            }
            scanned.append(token)
            index += 1
        }
        return scanned.joined(separator: " ")
    }

    /// `.env` 只有落在路径末段才是凭据文件。`containers[0].envfrom`、
    /// `.env[?(@.name=="x")]` 这类 kubectl jsonpath 不是读密钥。与
    /// `AgentToolAuthorization.referencesDotEnvFile` 同一判据，两处门禁口径
    /// 必须一致，否则一层放行另一层照拦，用户仍然要点。
    private static func referencesDotEnvFile(_ lowered: String) -> Bool {
        lowered
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .contains { token in
                token
                    .split(separator: "/", omittingEmptySubsequences: false)
                    .contains { $0 == ".env" || $0.hasPrefix(".env.") }
            }
    }

    /// 每个命令段的头一个词（按 `;` `|` `&` 以及 `$(`、反引号切段）。
    private static func segmentHeads(in lowered: String) -> [String] {
        lowered
            .split(whereSeparator: { ";|&`".contains($0) || $0 == "\n" })
            .compactMap { segment in
                segment
                    .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "(" })
                    .first
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'\"$")) }
            }
            .filter { !$0.isEmpty }
    }

    // MARK: - 小工具

    /// 取 `key=value` 形式参数的值。
    private static func value(ofArgument key: String, in normalized: String) -> String? {
        guard let range = normalized.range(of: key) else { return nil }
        let rest = normalized[range.upperBound...]
        let value = rest.prefix { !$0.isWhitespace }
        return value.isEmpty ? nil : String(value)
    }

    /// `> target` / `>> target` 的目标。
    private static func redirectTarget(in normalized: String) -> String? {
        guard let range = normalized.range(of: ">") else { return nil }
        var rest = normalized[range.upperBound...]
        if rest.hasPrefix(">") { rest = rest.dropFirst() }
        let target = rest.drop { $0 == " " }.prefix { !$0.isWhitespace }
        return target.isEmpty ? nil : String(target)
    }

    /// 段里所有看起来像路径的参数（跳过 flag）。
    private static func pathArguments(in normalized: String) -> [String] {
        normalized
            .split(separator: " ")
            .dropFirst()
            .map(String.init)
            .filter { !$0.hasPrefix("-") }
    }

    /// `/dev/disk0`、`/dev/sda`、`/dev/rdisk1` 这类裸设备；`/dev/null`
    /// 与 `/dev/stdout` 显然不是。
    private static func isRawDevicePath(_ path: String) -> Bool {
        let p = path.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard p.hasPrefix("/dev/") else { return false }
        let name = String(p.dropFirst("/dev/".count))
        let safeDevices = ["null", "zero", "stdout", "stderr", "stdin", "tty", "urandom", "random"]
        if safeDevices.contains(name) { return false }
        return name.hasPrefix("disk") || name.hasPrefix("rdisk") || name.hasPrefix("sd")
            || name.hasPrefix("hd") || name.hasPrefix("nvme") || name.hasPrefix("vd")
    }
}
