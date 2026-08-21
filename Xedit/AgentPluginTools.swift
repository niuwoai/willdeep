//
//  AgentPluginTools.swift
//  WillDeep
//
//  AI-authored plugins are confined to an inert draft directory. These tools
//  never approve, install, or enable a package; that transition remains a
//  user-visible action in Plugin Center.
//

import Foundation

nonisolated enum AgentPluginTools {
    private static let maximumTextFileBytes = 2 * 1024 * 1024

    static func createDraft(arguments: [String: AgentJSONValue]) throws -> AgentToolResult {
        let pluginID = try requiredString("plugin_id", arguments: arguments)
        let version = try requiredString("version", arguments: arguments)
        let codexJSON = try requiredString("codex_manifest_json", arguments: arguments)
        let willDeepJSON = try requiredString("willdeep_manifest_json", arguments: arguments)
        guard let codexData = codexJSON.data(using: .utf8),
              let willDeepData = willDeepJSON.data(using: .utf8),
              codexData.count <= maximumTextFileBytes,
              willDeepData.count <= maximumTextFileBytes else {
            throw AgentPluginPackageError.oversizedManifest(pluginID)
        }
        let codexManifest = try JSONDecoder().decode(AgentCodexPluginManifest.self, from: codexData)
        let willDeepManifest = try JSONDecoder().decode(AgentPluginManifest.self, from: willDeepData)
        guard codexManifest.name == pluginID,
              codexManifest.version == version,
              AgentPluginPackageLoader.isSafeIdentifier(pluginID),
              AgentPluginPackageLoader.isSafePathComponent(version),
              AppVersion(version) != nil else {
            throw AgentPluginPackageError.invalidContribution(
                "draft arguments must match a safe plugin name and semantic version in the Codex manifest"
            )
        }
        guard willDeepManifest.schemaVersion == AgentPluginPackageLoader.supportedSchemaVersion else {
            throw AgentPluginPackageError.unsupportedSchema(willDeepManifest.schemaVersion)
        }

        let draftURL = try AgentPluginDraftStore.createDraft(pluginID: pluginID, version: version)
        do {
            _ = try AgentPluginDraftStore.write(
                data: codexData,
                relativePath: ".codex-plugin/plugin.json",
                draftRoot: draftURL
            )
            _ = try AgentPluginDraftStore.write(
                data: willDeepData,
                relativePath: ".willdeep-plugin/plugin.json",
                draftRoot: draftURL
            )
            return AgentToolResult(
                summary: "Plugin draft created",
                payload: "Draft: \(draftURL.path)\nPlugin: \(pluginID)\nVersion: \(version)\nStatus: inert and incomplete; add declared resources and localizations, then inspect it. User approval and installation are still required."
            )
        } catch {
            try? FileManager.default.removeItem(at: draftURL)
            throw error
        }
    }

    static func writeDraftFile(arguments: [String: AgentJSONValue]) throws -> AgentToolResult {
        let draftPath = try requiredString("draft_path", arguments: arguments)
        let relativePath = try requiredString("relative_path", arguments: arguments)
        let content = arguments["content"]?.stringValue() ?? ""
        guard let data = content.data(using: .utf8), data.count <= maximumTextFileBytes else {
            throw AgentPluginPackageError.oversizedManifest(relativePath)
        }
        let target = try AgentPluginDraftStore.write(
            data: data,
            relativePath: relativePath,
            draftRoot: URL(fileURLWithPath: draftPath, isDirectory: true)
        )
        return AgentToolResult(
            summary: "Plugin draft file written",
            payload: "Wrote \(data.count) bytes to \(target.path). The draft remains disabled until the user approves it in Plugin Center."
        )
    }

    static func inspectDraft(arguments: [String: AgentJSONValue]) throws -> AgentToolResult {
        let draftPath = try requiredString("draft_path", arguments: arguments)
        let draftURL = try validatedDraftURL(draftPath)
        let package = try AgentPluginPackageLoader.load(
            packageURL: draftURL,
            source: .draft,
            currentWillDeepVersion: currentVersion
        )
        let permissions = package.manifest?.permissions.map(\.rawValue).sorted() ?? []
        return AgentToolResult(
            summary: "Plugin draft validated",
            payload: "Plugin: \(package.pluginID)\nVersion: \(package.version)\nDestinations: \(package.destinations.count)\nPermissions: \(permissions.isEmpty ? "none" : permissions.joined(separator: ", "))\nDigest: \(package.digest)\nDraft: \(package.packageURL.path)"
        )
    }

    private static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    private static func validatedDraftURL(_ path: String) throws -> URL {
        let allowedRoot = AgentPluginPaths.draftRoot.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let prefix = allowedRoot.path.hasSuffix("/") ? allowedRoot.path : allowedRoot.path + "/"
        guard candidate.path.hasPrefix(prefix) else {
            throw AgentPluginInstallerError.invalidDraftPath(path)
        }
        return candidate
    }

    private static func requiredString(
        _ name: String,
        arguments: [String: AgentJSONValue]
    ) throws -> String {
        guard let value = arguments[name]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            throw AgentToolError.missingArgument(name)
        }
        return value
    }
}
