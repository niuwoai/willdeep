//
//  AgentConfigurationTools.swift
//  WillDeep
//
//  Chat-exposed configuration tools for user-managed MCP servers and
//  user skills. These deliberately reuse the Settings storage paths so
//  credentials, safety checks, and UI refreshes stay consistent.
//

import Foundation

enum AgentConfigurationTools {
    private static let maxMCPJSONCharacters = 80_000
    private static let maxSkillBodyCharacters = 24_000
    private static let maxSkillDescriptionCharacters = 360

    static func configureMCPServer(arguments: [String: AgentJSONValue]) throws -> AgentToolResult {
        let rawJSON = try requiredString("json", in: arguments, maxCharacters: maxMCPJSONCharacters)
        let root = AgentJSONValue.decode(from: rawJSON)
        guard case .object(let rootObject) = root else {
            throw AgentToolError.invalidArgument("json must be a JSON object.")
        }

        let requestedName = optionalString("server_name", in: arguments, maxCharacters: 120)
            ?? optionalString("name", in: arguments, maxCharacters: 120)
        let enabledOverride = arguments["enabled"]?.boolValue()
        let trustLevelOverride = parseTrustLevel(
            optionalString("trust_level", in: arguments, maxCharacters: 40)
        )
        let candidates = try extractMCPServerCandidates(
            from: rootObject,
            requestedName: requestedName
        )
        guard !candidates.isEmpty else {
            throw AgentToolError.invalidArgument("json does not contain any MCP server definitions.")
        }

        var configured: [AgentMCPServerConfig] = []
        var trustSummaries: [String] = []
        for candidate in candidates {
            var server = try parseMCPServer(name: candidate.name, object: candidate.object)
            if let enabledOverride {
                server.isEnabled = enabledOverride
            }
            AgentMCPSettingsStore.upsertUserServer(server)
            server = AgentMCPSettingsStore.load().userServers.first { $0.name == server.name } ?? server.normalized
            AgentMCPSettingsStore.setServerEnabled(id: server.id, enabled: server.isEnabled)

            let objectTrustLevel = parseTrustLevel(
                firstString(["trust_level", "trustLevel"], in: candidate.object)
            )
            if let level = trustLevelOverride ?? objectTrustLevel {
                AgentMCPSettingsStore.setServerTrustLevel(id: server.id, level: level)
                trustSummaries.append("\(server.name)=\(level.rawValue)")
            }
            configured.append(server)
        }

        let lines = configured.map { server in
            let credentialNote = credentialSummary(for: server)
            let trustLevel = AgentMCPSettingsStore.trustLevel(id: server.id).rawValue
            return "- \(server.name) (\(server.transport.rawValue), enabled=\(server.isEnabled), trust=\(trustLevel)): \(server.summary)\(credentialNote)"
        }
        let trustLine = trustSummaries.isEmpty ? "" : "\nTrust updated: \(trustSummaries.joined(separator: ", "))"
        return AgentToolResult(
            summary: "Configured \(configured.count) MCP server\(configured.count == 1 ? "" : "s")",
            payload: """
            Configured user MCP server(s):
            \(lines.joined(separator: "\n"))
            \(trustLine)

            Sensitive env/header values are stored through the existing credential store and redacted in UI summaries.
            """
        )
    }

    static func updateUserSkill(arguments: [String: AgentJSONValue]) throws -> AgentToolResult {
        let name = try requiredString("name", in: arguments, maxCharacters: 120)
        let description = optionalString("description", in: arguments, maxCharacters: maxSkillDescriptionCharacters)
            .map { AgentMemorySanitizer.sanitize($0).text }
        let body = optionalString("body", in: arguments, maxCharacters: maxSkillBodyCharacters)
            .map { AgentMemorySanitizer.sanitize($0).text }
        guard description != nil || body != nil else {
            throw AgentToolError.invalidArgument("Provide description, body, or both.")
        }

        let skill = try findUserSkill(named: name)
        try AgentSkillFileManager.updateUserSkill(skill, description: description, body: body)
        return AgentToolResult(
            summary: "Updated skill \(skill.identifier)",
            payload: "Updated user skill at \(skill.url.path)."
        )
    }

    static func deleteUserSkill(arguments: [String: AgentJSONValue]) throws -> AgentToolResult {
        let name = try requiredString("name", in: arguments, maxCharacters: 120)
        let skill = try findUserSkill(named: name)
        try AgentSkillFileManager.deleteUserSkill(skill)
        return AgentToolResult(
            summary: "Deleted skill \(skill.identifier)",
            payload: "Deleted user skill directory \(skill.url.deletingLastPathComponent().path)."
        )
    }

    private static func extractMCPServerCandidates(
        from rootObject: [String: AgentJSONValue],
        requestedName: String?
    ) throws -> [(name: String, object: [String: AgentJSONValue])] {
        if case .object(let servers)? = rootObject["mcpServers"] ?? rootObject["servers"] {
            return try servers.compactMap { name, value in
                if let requestedName,
                   name.caseInsensitiveCompare(requestedName) != .orderedSame {
                    return nil
                }
                guard case .object(let object) = value else {
                    throw AgentToolError.invalidArgument("MCP server \(name) must be a JSON object.")
                }
                return (name, object)
            }
        }

        let name = requestedName
            ?? firstString(["name", "server_name", "serverName"], in: rootObject)
        guard let name, !name.isEmpty else {
            throw AgentToolError.invalidArgument("Single MCP server JSON must include name or pass server_name.")
        }
        return [(name, rootObject)]
    }

    private static func parseMCPServer(
        name: String,
        object: [String: AgentJSONValue]
    ) throws -> AgentMCPServerConfig {
        let transport = parseTransport(from: object)
        let env = try parseStringMap(object["env"], field: "env")
        let headers = try parseStringMap(object["headers"], field: "headers")
        let startupTimeout = firstDouble(["startup_timeout_sec", "startup_timeout", "startupTimeout", "timeout"], in: object) ?? 30
        let isEnabled = object["enabled"]?.boolValue() ?? object["isEnabled"]?.boolValue() ?? true
        switch transport {
        case .streamableHTTP:
            guard let url = firstString(["url"], in: object),
                  !url.isEmpty else {
                throw AgentToolError.invalidArgument("MCP server \(name) requires url for streamable-http transport.")
            }
            return AgentMCPServerConfig(
                name: name,
                source: .user,
                transport: .streamableHTTP,
                url: url,
                headers: headers,
                startupTimeout: startupTimeout,
                isEnabled: isEnabled
            )
        case .stdio:
            guard let command = firstString(["command"], in: object),
                  !command.isEmpty else {
                throw AgentToolError.invalidArgument("MCP server \(name) requires command for stdio transport.")
            }
            return AgentMCPServerConfig(
                name: name,
                source: .user,
                transport: .stdio,
                command: command,
                args: parseStringArray(object["args"]),
                env: env,
                startupTimeout: startupTimeout,
                isEnabled: isEnabled
            )
        }
    }

    private static func parseTransport(from object: [String: AgentJSONValue]) -> AgentMCPTransport {
        let raw = firstString(["transport", "type"], in: object)?.lowercased()
        if raw == AgentMCPTransport.streamableHTTP.rawValue || raw == "http" || object["url"] != nil {
            return .streamableHTTP
        }
        return .stdio
    }

    private static func parseTrustLevel(_ raw: String?) -> AgentMCPServerTrustLevel? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        switch raw.lowercased() {
        case "fullytrusted", "fully_trusted", "trusted", "full", "always":
            return .fullyTrusted
        case "standard", "default":
            return .standard
        case "untrusted", "deny":
            return .untrusted
        default:
            return nil
        }
    }

    private static func parseStringMap(_ value: AgentJSONValue?, field: String) throws -> [String: String] {
        guard let value else { return [:] }
        guard case .object(let object) = value else {
            throw AgentToolError.invalidArgument("\(field) must be a JSON object with string values.")
        }
        var result: [String: String] = [:]
        for (key, value) in object {
            guard let string = value.stringValue() else {
                throw AgentToolError.invalidArgument("\(field).\(key) must be a string.")
            }
            result[key] = string
        }
        return result
    }

    private static func parseStringArray(_ value: AgentJSONValue?) -> [String] {
        guard let value else { return [] }
        if let strings = value.stringArrayValue() {
            return strings
        }
        if let string = value.stringValue() {
            return string.split(separator: " ").map(String.init)
        }
        return []
    }

    private static func firstString(
        _ keys: [String],
        in object: [String: AgentJSONValue]
    ) -> String? {
        for key in keys {
            guard let value = object[key]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else {
                continue
            }
            return value
        }
        return nil
    }

    private static func firstDouble(
        _ keys: [String],
        in object: [String: AgentJSONValue]
    ) -> Double? {
        for key in keys {
            switch object[key] {
            case .number(let value):
                return value
            case .string(let value):
                if let parsed = Double(value) { return parsed }
            default:
                continue
            }
        }
        return nil
    }

    private static func requiredString(
        _ key: String,
        in arguments: [String: AgentJSONValue],
        maxCharacters: Int
    ) throws -> String {
        guard let value = optionalString(key, in: arguments, maxCharacters: maxCharacters) else {
            throw AgentToolError.missingArgument(key)
        }
        return value
    }

    private static func optionalString(
        _ key: String,
        in arguments: [String: AgentJSONValue],
        maxCharacters: Int
    ) -> String? {
        guard let value = arguments[key]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return String(value.prefix(maxCharacters))
    }

    private static func findUserSkill(named rawName: String) throws -> AgentSkillEntry {
        let query = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = query.lowercased()
        let matches = AgentSkillDirectory.list(includeDisabled: true).filter { skill in
            guard skill.source == .user else { return false }
            let displayName = AgentSkillLocalization.displayName(for: skill).lowercased()
            return skill.identifier.lowercased() == lowercased
                || skill.name.lowercased() == lowercased
                || displayName == lowercased
        }
        guard let skill = matches.first else {
            throw AgentToolError.notFound("User skill \(query)")
        }
        guard matches.count == 1 else {
            let options = matches.map(\.identifier).joined(separator: ", ")
            throw AgentToolError.invalidArgument("Multiple user skills match \(query): \(options). Use an exact identifier.")
        }
        return skill
    }

    private static func credentialSummary(for server: AgentMCPServerConfig) -> String {
        let sensitiveEnv = server.env.keys.filter(AgentMCPServerConfig.isSensitiveCredentialKey).sorted()
        let sensitiveHeaders = server.headers.keys.filter(AgentMCPServerConfig.isSensitiveCredentialKey).sorted()
        var parts: [String] = []
        if !sensitiveEnv.isEmpty {
            parts.append("env secrets: \(sensitiveEnv.joined(separator: ", "))")
        }
        if !sensitiveHeaders.isEmpty {
            parts.append("header secrets: \(sensitiveHeaders.joined(separator: ", "))")
        }
        return parts.isEmpty ? "" : " [\(parts.joined(separator: "; "))]"
    }
}
