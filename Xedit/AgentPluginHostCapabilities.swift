//
//  AgentPluginHostCapabilities.swift
//  WillDeep
//
//  插件页面向宿主借的三样东西：读工作区文件、自己的持久化、宿主事件。
//  （第四样「把活交给 Agent」要动 AppState，放在 AppStateAgentPluginChat.swift。）
//
//  为什么由宿主代劳，而不是让插件自带一个 MCP 服务去干：
//  自带进程等于绕开宿主的全部闸门——路径守卫、只读语义、体积上限一条都
//  不生效，用户在安装面板上点的那几个权限也就成了摆设。走这条桥，
//  `workspace.read` 才真的是「只读」，越界的路径才真的进不去。
//
//  三个共同约束：
//   · 路径一律经 AgentWorkspacePathGuard 落到已授权的根里，软链接解析后
//     仍越界的直接拒；
//   · 每个返回值都有体积上限，页面拿不到能把 WebView 撑爆的载荷；
//   · 越权与越界分开报错，插件作者能看懂是「没这个权限」还是「路径不对」。
//

import Foundation

/// 桥接层的错误。文案直接进页面的 Promise reject，所以要能让插件作者
/// 一眼看出是哪一类问题。
nonisolated enum AgentPluginCapabilityError: LocalizedError, Equatable {
    case permissionDenied(String)
    case noWorkspace
    case pathOutsideWorkspace(String)
    case notFound(String)
    case notAFile(String)
    case notADirectory(String)
    case invalidArgument(String)
    case storageFull(Int)
    case payloadTooLarge(Int)
    case networkSchemeRefused(String)
    case networkHostRefused(String)
    case networkHostNotDeclared(String)
    case commandRefused(String)
    case commandDeclined

    var errorDescription: String? {
        switch self {
        case .permissionDenied(let permission):
            return "This plugin does not have the \(permission) permission"
        case .noWorkspace:
            return "The active session has no local workspace"
        case .pathOutsideWorkspace(let path):
            return "Path escapes the authorized workspace roots: \(path)"
        case .notFound(let path):
            return "No such file or directory: \(path)"
        case .notAFile(let path):
            return "Not a regular file: \(path)"
        case .notADirectory(let path):
            return "Not a directory: \(path)"
        case .invalidArgument(let name):
            return "Missing or invalid argument: \(name)"
        case .storageFull(let limit):
            return "Plugin storage is full (limit \(limit) bytes)"
        case .payloadTooLarge(let limit):
            return "Payload exceeds \(limit) bytes"
        case .networkSchemeRefused(let scheme):
            return "Only https is allowed; got \(scheme)"
        case .networkHostRefused(let host):
            return "Loopback and private hosts are never reachable from a plugin page: \(host)"
        case .networkHostNotDeclared(let host):
            return "\(host) is not listed in the plugin's networkDomains"
        case .commandRefused(let reason):
            return "Command refused: \(reason)"
        case .commandDeclined:
            return "The user declined the command"
        }
    }
}

/// `window.willdeep.fs.*` 背后的实现：列目录、读文件、全文搜索。
/// 全部只读，需要 `workspace.read`。
nonisolated enum AgentPluginFileAccess {
    /// 单次读文件的上限。页面是给人看的，不是数据管道；超了截断并置位
    /// `truncated`，让插件自己决定要不要分段读。
    static let maximumReadBytes = 256 * 1024
    /// 单次列目录的条目上限。
    static let maximumListEntries = 500
    /// 单次搜索的命中上限。
    static let maximumSearchMatches = 200

    /// 把页面给的路径落到某个已授权根里。
    ///
    /// 相对路径按第一个根解析；绝对路径也收，但必须落在某个根内——插件
    /// 从 `fs.list` 拿到的 path 就是绝对的，不收等于逼它自己拼字符串。
    static func resolve(path rawPath: String, roots: [URL]) throws -> URL {
        guard let primary = roots.first else { throw AgentPluginCapabilityError.noWorkspace }
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: URL
        if trimmed.isEmpty || trimmed == "." {
            candidate = primary
        } else if trimmed.hasPrefix("/") {
            candidate = URL(fileURLWithPath: trimmed)
        } else {
            candidate = primary.appendingPathComponent(trimmed)
        }
        let standardized = candidate.standardizedFileURL
        guard AgentWorkspacePathGuard.containingRoot(for: standardized, roots: roots) != nil else {
            throw AgentPluginCapabilityError.pathOutsideWorkspace(standardized.path)
        }
        return standardized
    }

    static func list(path rawPath: String, roots: [URL]) throws -> [String: Any] {
        let directory = try resolve(path: rawPath, roots: roots)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            throw AgentPluginCapabilityError.notFound(directory.path)
        }
        guard isDirectory.boolValue else {
            throw AgentPluginCapabilityError.notADirectory(directory.path)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { !$0.hasPrefix(".") }
            .sorted()
        let truncated = names.count > maximumListEntries
        let entries = names.prefix(maximumListEntries).map { name -> [String: Any] in
            let child = directory.appendingPathComponent(name)
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            return [
                "name": name,
                "path": child.path,
                "isDirectory": values?.isDirectory ?? false,
                "byteSize": values?.fileSize ?? 0,
            ]
        }
        return [
            "path": directory.path,
            "entries": Array(entries),
            "truncated": truncated,
        ]
    }

    static func read(path rawPath: String, roots: [URL]) throws -> [String: Any] {
        let file = try resolve(path: rawPath, roots: roots)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) else {
            throw AgentPluginCapabilityError.notFound(file.path)
        }
        guard !isDirectory.boolValue else {
            throw AgentPluginCapabilityError.notAFile(file.path)
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        // 多读一个字节只为判断「是不是还有」，不进返回值。
        let raw = try handle.read(upToCount: maximumReadBytes + 1) ?? Data()
        let truncated = raw.count > maximumReadBytes
        let clipped = truncated ? raw.prefix(maximumReadBytes) : raw
        // 半个 UTF-8 字符被截断会让 String(decoding:) 吐出替换符，
        // 复用工具侧那套按字符边界回退的裁剪。
        let safe = AgentFileTools.utf8SafePrefix(Data(clipped))
        return [
            "path": file.path,
            "text": String(decoding: safe, as: UTF8.self),
            "truncated": truncated,
            "byteSize": (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0,
        ]
    }

    /// 全文搜索。有 ripgrep 就用 ripgrep（尊重 .gitignore、快得多），
    /// 没有就退回逐文件扫描——与 Agent 的 `grep_files` 同一套取舍。
    static func search(
        query: String,
        path rawPath: String,
        isRegularExpression: Bool,
        limit rawLimit: Int?,
        roots: [URL]
    ) throws -> [String: Any] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { throw AgentPluginCapabilityError.invalidArgument("query") }
        guard let primary = roots.first else { throw AgentPluginCapabilityError.noWorkspace }
        let searchRoot = try resolve(path: rawPath, roots: roots)
        let limit = min(max(rawLimit ?? 60, 1), maximumSearchMatches)
        let matches = AgentRipgrepSearch.search(
            root: primary,
            searchRoot: searchRoot,
            pattern: isRegularExpression ? .regularExpression(needle) : .literal(needle),
            caseSensitive: false,
            includeGlob: nil,
            limit: limit
        ) ?? fallbackSearch(needle: needle, searchRoot: searchRoot, limit: limit)
        return [
            "query": needle,
            "path": searchRoot.path,
            "matches": matches,
            "truncated": matches.count >= limit,
        ]
    }

    /// 机器上没装 ripgrep 时的兜底：只扫文本文件、逐行找子串。
    /// 慢，但「没装 rg 就搜不了」对插件作者是无法自证的失败。
    private static func fallbackSearch(needle: String, searchRoot: URL, limit: Int) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: searchRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        let lowered = needle.lowercased()
        var results: [String] = []
        for case let url as URL in enumerator {
            if results.count >= limit { break }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true, (values?.fileSize ?? 0) <= maximumReadBytes else { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                guard line.lowercased().contains(lowered) else { continue }
                results.append("\(url.path):\(index + 1):\(line.prefix(400))")
                if results.count >= limit { break }
            }
        }
        return results
    }
}

/// `window.willdeep.storage.*`：每个插件一份、跨刷新与重启都在的小仓库。
///
/// 插件页跑在 `nonPersistent()` 的 WKWebView 里，localStorage 刷新一次就
/// 空了。没有这个，插件想记住任何东西都只能反过来求宿主加功能——正是
/// 这次要断掉的那条路。
///
/// 不设权限门：命名空间按插件 ID 隔开，一个插件读不到另一个的键，写的
/// 也只是宿主自己的 Application Support，不碰用户工作区。
nonisolated enum AgentPluginStorageStore {
    /// 单个值的上限（序列化后的字节数）。
    static let maximumValueBytes = 64 * 1024
    /// 单个插件的总上限。到顶后写入报错而不是静默丢弃——静默丢会让插件
    /// 以为自己存住了。
    static let maximumTotalBytes = 1024 * 1024
    /// 键名长度上限。
    static let maximumKeyLength = 200

    /// 落盘目录。测试传自己的临时目录进来——刻意不做成可写的全局变量：
    /// Swift Testing 并行跑用例，一个全局覆盖点会被另一个 suite 中途改掉
    /// 或删掉，故障现场是「mktemp 失败」这种看不出根因的报错。
    static var defaultDirectory: URL {
        AgentSessionStore.applicationSupportDirectory
            .appendingPathComponent("PluginStorage", isDirectory: true)
    }

    private static func fileURL(pluginID: AgentPluginID, directory: URL) -> URL {
        // 插件 ID 进文件名前先净化：它来自 manifest，不该能写出 `../` 来。
        let allowed = CharacterSet.alphanumerics
        var safe = ""
        for scalar in pluginID.unicodeScalars {
            let keep = allowed.contains(scalar) || scalar == "." || scalar == "-" || scalar == "_"
            safe.append(keep ? Character(scalar) : "_")
        }
        return directory.appendingPathComponent(safe + ".json", isDirectory: false)
    }

    static func load(pluginID: AgentPluginID, directory: URL = defaultDirectory) -> [String: Any] {
        guard let data = try? Data(contentsOf: fileURL(pluginID: pluginID, directory: directory)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    static func keys(pluginID: AgentPluginID, directory: URL = defaultDirectory) -> [String] {
        load(pluginID: pluginID, directory: directory).keys.sorted()
    }

    static func value(
        forKey key: String,
        pluginID: AgentPluginID,
        directory: URL = defaultDirectory
    ) -> Any? {
        load(pluginID: pluginID, directory: directory)[key]
    }

    static func setValue(
        _ value: Any,
        forKey key: String,
        pluginID: AgentPluginID,
        directory: URL = defaultDirectory
    ) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.count <= maximumKeyLength else {
            throw AgentPluginCapabilityError.invalidArgument("key")
        }
        guard JSONSerialization.isValidJSONObject([key: value]) else {
            throw AgentPluginCapabilityError.invalidArgument("value")
        }
        let encoded = try JSONSerialization.data(withJSONObject: [key: value])
        guard encoded.count <= maximumValueBytes else {
            throw AgentPluginCapabilityError.storageFull(maximumValueBytes)
        }
        var store = load(pluginID: pluginID, directory: directory)
        store[key] = value
        try write(store, pluginID: pluginID, directory: directory)
    }

    static func removeValue(
        forKey key: String,
        pluginID: AgentPluginID,
        directory: URL = defaultDirectory
    ) throws {
        var store = load(pluginID: pluginID, directory: directory)
        guard store.removeValue(forKey: key) != nil else { return }
        try write(store, pluginID: pluginID, directory: directory)
    }

    private static func write(_ store: [String: Any], pluginID: AgentPluginID, directory: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: store, options: [.sortedKeys])
        guard data.count <= maximumTotalBytes else {
            throw AgentPluginCapabilityError.storageFull(maximumTotalBytes)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL(pluginID: pluginID, directory: directory), options: .atomic)
    }
}

/// 宿主推给页面的事件。页面此前只能靠 `refresh` 轮询，插件想「会话切了
/// 就重算一遍」只能定时器扫。
nonisolated enum AgentPluginHostEvent: String, CaseIterable, Sendable {
    /// 当前会话换了（含新建、切换、关闭到空）。
    case sessionChanged = "session.changed"
    /// 一个回合开始跑。
    case turnStarted = "turn.started"
    /// 一个回合跑完了（无论成功失败）。插件据此刷新自己的视图。
    case turnFinished = "turn.finished"
    /// 当前会话的工作区根变了。
    case workspaceChanged = "workspace.changed"

    /// 会话与回合类事件带会话 id，属于会话元数据，因此要 `conversation.read`；
    /// 工作区路径同理走 `workspace.read`。没有对应权限的插件订阅了也收不到。
    var requiredPermission: AgentPluginPermission {
        switch self {
        case .sessionChanged, .turnStarted, .turnFinished:
            return .conversationRead
        case .workspaceChanged:
            return .workspaceRead
        }
    }

    static func named(_ raw: String) -> AgentPluginHostEvent? {
        AgentPluginHostEvent(rawValue: raw)
    }
}
