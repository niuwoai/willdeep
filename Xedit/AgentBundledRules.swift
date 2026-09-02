//
//  AgentBundledRules.swift
//  WillDeep
//
//  Locates the read-only Alma rule library shipped inside WillDeep and keeps
//  the user-level global prompt as a small routing index.
//

import Foundation

nonisolated struct AgentBundledRulesManifest: Decodable, Equatable, Sendable {
    let schemaVersion: Int
    let rulesVersion: String
    let sourceRepository: String
    let sourceRevision: String
    let contentSHA256: String
    let files: [String]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case rulesVersion = "rules_version"
        case sourceRepository = "source_repository"
        case sourceRevision = "source_revision"
        case contentSHA256 = "content_sha256"
        case files
    }
}

nonisolated enum AgentBundledRules {
    static let directoryName = "BundledAgentRules"
    static let rootPlaceholder = "{{WILLDEEP_BUNDLED_RULES_DIR}}"
    static let readerToolName = "read_bundled_rule"

    /// The compact index shipped before the native rule reader existed.
    /// Keep the exact text so an untouched default file can migrate without
    /// overwriting users who appended personal instructions.
    static let previousDefaultGlobalRulesTemplate = """
    # WillDeep 全局规则（精简索引）

    - 所有回复使用简体中文；关键信息保持明确、准确。
    - 系统、开发者和用户最新指令优先；项目内更具体的 `AGENTS.md` / `CLAUDE.md` 可补充或覆盖本索引。
    - 修改前检查仓库规则、工作区状态和既有实现；保留用户已有改动。
    - 不得输出或提交密钥、Token、凭据或个人隐私数据。

    ## 内置规则库

    规则根目录：`{{WILLDEEP_BUNDLED_RULES_DIR}}`

    只按当前任务读取直接相关文件，不要一次性读取整个目录，也不要把规则全文复制进提示词：

    - 代码修改：`ai-guardrails.md`、`programming.md`
    - UI / 前端：再读 `design.md`、`frontend.md`
    - Go / Python：再读 `go.md` 或 `python.md`
    - 数据库：按需读取 `database-migrations.md`、`database-queries.md`、`database-sync.md`
    - 部署 / Linux：按需读取 `deployment.md`、`linux-server.md`
    - Git、版本、提交或发布：读取 `version-control.md`

    可在本文件追加少量个人偏好；详细工程规范应留在内置规则库或项目规则中。
    """

    static let defaultGlobalRulesTemplate = """
    # WillDeep 全局规则（精简索引）

    - 所有回复使用简体中文；关键信息保持明确、准确。
    - 系统、开发者和用户最新指令优先；项目内更具体的 `AGENTS.md` / `CLAUDE.md` 可补充或覆盖本索引。
    - 修改前检查仓库规则、工作区状态和既有实现；保留用户已有改动。
    - 不得输出或提交密钥、Token、凭据或个人隐私数据。

    ## 内置规则库

    规则根目录：`{{WILLDEEP_BUNDLED_RULES_DIR}}`

    使用 `read_bundled_rule` 读取下面直接相关的文件；不要用 `read_file` 或 shell 访问 App 包，不要一次性读取整个目录，也不要把规则全文复制进提示词。规则正文继续引用其他 Markdown 时，仍用 `read_bundled_rule` 按文件名读取：

    - 代码修改：`ai-guardrails.md`、`programming.md`
    - UI / 前端：再读 `design.md`、`frontend.md`
    - Go / Python：再读 `go.md` 或 `python.md`
    - 数据库：按需读取 `database-migrations.md`、`database-queries.md`、`database-sync.md`
    - 部署 / Linux：按需读取 `deployment.md`、`linux-server.md`
    - Git、版本、提交或发布：读取 `version-control.md`

    可在本文件追加少量个人偏好；详细工程规范应留在内置规则库或项目规则中。
    """

    static func rootURL(
        bundle: Bundle = .main,
        sourceRoot: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    ) -> URL? {
        var candidates: [URL] = []
        if let resourceURL = bundle.resourceURL {
            candidates.append(resourceURL.appendingPathComponent(directoryName, isDirectory: true))
        }
        candidates.append(sourceRoot.appendingPathComponent(directoryName, isDirectory: true))

        return candidates.first { candidate in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
                && FileManager.default.fileExists(
                    atPath: candidate.appendingPathComponent("AGENTS.md", isDirectory: false).path
                )
        }
    }

    static func manifest(rootURL: URL? = rootURL()) -> AgentBundledRulesManifest? {
        guard let rootURL,
              let data = try? Data(contentsOf: rootURL.appendingPathComponent("manifest.json")) else {
            return nil
        }
        return try? JSONDecoder().decode(AgentBundledRulesManifest.self, from: data)
    }

    static func resolvingRootPlaceholder(
        in text: String,
        rootURL: URL? = rootURL()
    ) -> String {
        let replacement = rootURL?.standardizedFileURL.path
            ?? "[WillDeep bundled rule library is unavailable]"
        return text.replacingOccurrences(of: rootPlaceholder, with: replacement)
    }

    static func readRule(
        named rawName: String,
        rootURL: URL? = rootURL()
    ) throws -> AgentToolResult {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw AgentToolError.missingArgument("file")
        }
        guard let rootURL,
              let manifest = manifest(rootURL: rootURL) else {
            throw AgentToolError.invalidArgument("WillDeep bundled rule library is unavailable.")
        }
        guard manifest.files.contains(name) else {
            let available = manifest.files.joined(separator: ", ")
            throw AgentToolError.invalidArgument(
                "Unknown bundled rule `\(name)`. Available files: \(available)"
            )
        }

        let standardizedRoot = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let url = standardizedRoot
            .appendingPathComponent(name, isDirectory: false)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard url.deletingLastPathComponent() == standardizedRoot else {
            throw AgentToolError.invalidArgument("Bundled rule paths must name a root-level manifest file.")
        }
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              let text = String(data: data, encoding: .utf8) else {
            throw AgentToolError.notFound(name)
        }
        return AgentToolResult(
            summary: "Read bundled rule \(name)",
            payload: text
        )
    }
}
