//
//  AppStateProviderImport.swift
//  WillDeep
//
//  从其他本地 CLI Agent 的配置文件导入 provider。
//
//  从 AppStateAgentSessions.swift 抽出（同一次 3000 行硬上限治理）。这块
//  本来就在那个文件的 extension 之外自带 enum 与 extension，是最干净的
//  一条切缝。
//

import Foundation

// MARK: - Import providers from other CLI agents' config files

/// Other local CLI agents whose provider config WillDeep can import, so a
/// dev/debug session can reuse an existing key without re-entering it.
enum ProviderImportSource: String, CaseIterable, Identifiable {
    case claudeCode
    case openclaw
    case hermes

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .openclaw: return "openclaw"
        case .hermes: return "hermes"
        }
    }
}

/// One provider parsed out of an external tool's config, ready to upsert.
private struct ImportedProviderDraft {
    var displayName: String
    var providerID: String
    var baseURL: String
    var apiKey: String
    var flashModel: String
    var proModel: String
    var extraModels: [String] = []
    /// Optional caveat surfaced to the user (e.g. openclaw's ambiguous key).
    var note: String?
}

extension AppState {
    /// Import provider(s) from another CLI agent's local config into the library
    /// and activate the first one. Returns a short human summary for the UI.
    /// Never logs API keys.
    @discardableResult
    func importProviders(from source: ProviderImportSource) -> String {
        let drafts: [ImportedProviderDraft]
        switch source {
        case .claudeCode: drafts = Self.importDraftsFromClaudeCode()
        case .openclaw: drafts = Self.importDraftsFromOpenclaw()
        case .hermes: drafts = Self.importDraftsFromHermes()
        }
        guard !drafts.isEmpty else {
            return "\(source.displayName)：未找到可导入的 provider（配置缺失 base/key，或走 OAuth 登录）"
        }

        var activatedFirst = false
        for draft in drafts {
            let existing = agentProviderLibrary.entries.first {
                $0.providerID == draft.providerID
                    && $0.baseURL.trimmingCharacters(in: .whitespacesAndNewlines) == draft.baseURL
            }
            let entryID = existing?.id ?? UUID()
            let entry = AgentProviderEntry(
                id: entryID,
                providerID: draft.providerID,
                displayName: draft.displayName,
                baseURL: draft.baseURL,
                apiKey: draft.apiKey,
                flashPrimary: draft.flashModel,
                flashAlternates: draft.extraModels,
                proPrimary: draft.proModel.nonEmptyOrNil ?? draft.flashModel,
                proAlternates: [],
                routingMode: existing?.routingMode ?? .auto
            )
            agentProviderLibrary.upsert(entry)
            if !activatedFirst {
                agentProviderLibrary.setActive(entryID)
                if agentProviderLibrary.activeID == entryID {
                    applyActiveProviderLibraryEntry()
                }
                activatedFirst = true
            }
        }
        let note = drafts.compactMap(\.note).first.map { "（\($0)）" } ?? ""
        return "\(source.displayName)：已导入 \(drafts.count) 个 provider" + note
    }

    // MARK: parsers (each returns [] when the config is absent/unusable)

    private static func importDraftsFromHermes() -> [ImportedProviderDraft] {
        let env = parseDotenv(("~/.hermes/.env" as NSString).expandingTildeInPath)
        guard let key = env["ANTHROPIC_API_KEY"]?.nonEmptyOrNil else { return [] }
        let preset = AgentProviderPreset.preset(id: "claude")
        return [ImportedProviderDraft(
            displayName: "hermes · Claude",
            providerID: "claude",
            baseURL: env["ANTHROPIC_BASE_URL"]?.nonEmptyOrNil ?? preset?.baseURL ?? "",
            apiKey: key,
            flashModel: env["ANTHROPIC_SMALL_FAST_MODEL"]?.nonEmptyOrNil ?? preset?.defaultFlashModel ?? "",
            proModel: env["ANTHROPIC_MODEL"]?.nonEmptyOrNil ?? preset?.defaultProModel ?? ""
        )]
    }

    private static func importDraftsFromClaudeCode() -> [ImportedProviderDraft] {
        let path = ("~/.claude/settings.json" as NSString).expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = root["env"] as? [String: Any] else { return [] }
        func value(_ name: String) -> String? { (env[name] as? String)?.nonEmptyOrNil }
        guard let key = value("ANTHROPIC_API_KEY") ?? value("ANTHROPIC_AUTH_TOKEN") else { return [] }
        let preset = AgentProviderPreset.preset(id: "claude")
        return [ImportedProviderDraft(
            displayName: "Claude Code",
            providerID: "claude",
            baseURL: value("ANTHROPIC_BASE_URL") ?? preset?.baseURL ?? "",
            apiKey: key,
            flashModel: value("ANTHROPIC_SMALL_FAST_MODEL") ?? preset?.defaultFlashModel ?? "",
            proModel: value("ANTHROPIC_MODEL") ?? preset?.defaultProModel ?? ""
        )]
    }

    private static func importDraftsFromOpenclaw() -> [ImportedProviderDraft] {
        let jsonPath = ("~/.openclaw/openclaw.json" as NSString).expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: jsonPath)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [String: Any],
              let providers = models["providers"] as? [String: Any] else { return [] }
        // openclaw stores no per-provider key in the JSON; keys live in .env.
        // Best-effort: reuse the single .env key and flag it for the user.
        let env = parseDotenv(("~/.openclaw/.env" as NSString).expandingTildeInPath)
        let fallbackKey = env.values.compactMap(\.nonEmptyOrNil).first ?? ""

        return providers.sorted { $0.key < $1.key }.compactMap { name, raw -> ImportedProviderDraft? in
            guard let provider = raw as? [String: Any],
                  let base = (provider["baseUrl"] as? String)?.nonEmptyOrNil else { return nil }
            let modelIDs = ((provider["models"] as? [[String: Any]]) ?? [])
                .compactMap { ($0["id"] as? String)?.nonEmptyOrNil }
            let flash = modelIDs.first ?? ""
            return ImportedProviderDraft(
                displayName: "openclaw · \(name)",
                providerID: AgentProviderPreset.customID,
                baseURL: base,
                apiKey: fallbackKey,
                flashModel: flash,
                proModel: modelIDs.count > 1 ? modelIDs[1] : flash,
                extraModels: Array(modelIDs.dropFirst()),
                note: fallbackKey.isEmpty
                    ? "openclaw 未存 key，请手动填写"
                    : "openclaw key 取自 .env，请核对是否匹配该 provider"
            )
        }
    }

    /// Minimal dotenv reader: `KEY=VALUE` per line, `#` comments, optional
    /// surrounding quotes stripped. Missing file → empty map.
    private static func parseDotenv(_ path: String) -> [String: String] {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for rawLine in content.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty { result[key] = value }
        }
        return result
    }
}

/// 与 `AppStateAgentSessions.swift` 里那份同名同义。两边各留一份 fileprivate
/// 是本仓库既有的做法（另有 5 个文件同样自带一份），提升成 internal 反而会
/// 和 `AgentComposerPickers.swift` 里那个非 private 的 `extension String` 抢
/// 命名空间——为一个三行的纯函数不值得。
private extension String {
    var nonEmptyOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
