//
//  AgentExecutionProfile.swift
//  WillDeep
//
//  App-owned execution profiles and the AI-authored dispatch DAG contract.
//

import Foundation
import CryptoKit

nonisolated enum AgentExecutionProfileOrigin: String, Codable, Equatable {
    case builtIn
    case managed
    case discovered
}

nonisolated struct AgentExecutionProfile: Codable, Equatable, Identifiable {
    static let recommendedPlannerID = "builtin:willdeep:kimi-k3"
    static let recommendedWorkerID = "builtin:willdeep:deepseek-v4-pro"

    var id: String
    var name: String
    var executor: AgentExecutionAgent
    var modelID: String?
    var providerID: String?
    var nativeProfileName: String?
    var origin: AgentExecutionProfileOrigin

    init(
        id: String = "managed:\(UUID().uuidString.lowercased())",
        name: String,
        executor: AgentExecutionAgent,
        modelID: String? = nil,
        providerID: String? = nil,
        nativeProfileName: String? = nil,
        origin: AgentExecutionProfileOrigin = .managed
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.executor = executor
        self.modelID = Self.normalized(modelID)
        self.providerID = Self.normalized(providerID)
        self.nativeProfileName = Self.normalized(nativeProfileName)
        self.origin = origin
    }

    @MainActor var displayDetail: String {
        let model = modelID ?? L10n.Dispatch.followCurrentModel
        return "\(executor.displayName) · \(model)"
    }

    var delegatedProfile: LocalAgentCLIProfile? {
        guard executor != .willDeep else { return nil }
        let configuration: LocalAgentCLIProfile.Configuration
        switch executor {
        case .codexCLI:
            configuration = .codexConfig(name: nativeProfileName ?? "")
        case .claudeCode:
            configuration = .claudeAgent(name: nativeProfileName ?? "")
        case .hermesCLI:
            configuration = .hermesProfile(name: nativeProfileName ?? "default")
        case .willDeep, .cursorAgent, .clineCLI:
            configuration = .generic
        }
        return LocalAgentCLIProfile(
            id: id,
            displayName: name,
            executor: executor,
            configuration: configuration,
            modelID: modelID,
            providerID: providerID
        )
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    static let builtIns = [
        AgentExecutionProfile(
            id: recommendedPlannerID,
            name: "Kimi K3 Planner",
            executor: .willDeep,
            modelID: AgentDispatchModelRouting.recommendedPlanningModel,
            origin: .builtIn
        ),
        AgentExecutionProfile(
            id: recommendedWorkerID,
            name: "DeepSeek V4 Pro Worker",
            executor: .willDeep,
            modelID: AgentDispatchModelRouting.recommendedExecutionModel,
            origin: .builtIn
        ),
    ]

    private enum CodingKeys: String, CodingKey {
        case id, name, executor, modelID, providerID, nativeProfileName, origin
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        executor = try container.decode(AgentExecutionAgent.self, forKey: .executor)
        modelID = try container.decodeIfPresent(String.self, forKey: .modelID)
        providerID = try container.decodeIfPresent(String.self, forKey: .providerID)
        nativeProfileName = try container.decodeIfPresent(String.self, forKey: .nativeProfileName)
        origin = try container.decodeIfPresent(
            AgentExecutionProfileOrigin.self,
            forKey: .origin
        ) ?? .managed
    }
}

struct AgentExecutionProfileStore {
    private static let defaultsKey = "com.willdeep.agentDispatch.executionProfiles.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadManaged() -> [AgentExecutionProfile] {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([AgentExecutionProfile].self, from: data)) ?? []
    }

    func saveManaged(_ profiles: [AgentExecutionProfile]) {
        let managed = profiles.filter { $0.origin == .managed }
        guard let data = try? JSONEncoder().encode(managed) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    func availableProfiles(workspacePath: String?) -> [AgentExecutionProfile] {
        let discovered = LocalAgentCLIProfile.discover(workspacePath: workspacePath).map {
            AgentExecutionProfile(
                id: $0.id,
                name: $0.displayName,
                executor: $0.executor,
                modelID: $0.modelID,
                providerID: $0.providerID,
                nativeProfileName: $0.nativeProfileName,
                origin: .discovered
            )
        }
        var seen: Set<String> = []
        return (AgentExecutionProfile.builtIns + loadManaged() + discovered)
            .filter { !$0.name.isEmpty && seen.insert($0.id).inserted }
    }

    func profile(id: String?, workspacePath: String?) -> AgentExecutionProfile? {
        guard let id else { return nil }
        return availableProfiles(workspacePath: workspacePath).first { $0.id == id }
    }
}

nonisolated struct AgentGoalDispatchPlan: Codable, Equatable {
    nonisolated struct Node: Codable, Equatable, Identifiable {
        var id: UUID
        var key: String
        var title: String
        var dependencyIDs: [UUID]
        var primaryProfileID: String?
        var fallbackProfileIDs: [String]
        var acceptanceCriteria: [String]
    }

    var nodes: [Node]
}

nonisolated enum AgentGoalDispatchPlanParser {
    private struct Payload: Decodable {
        struct Node: Decodable {
            let id: String
            let title: String
            let dependsOn: [String]
            let profile: String?
            let fallbackProfiles: [String]
            let acceptance: [String]

            enum CodingKeys: String, CodingKey {
                case id, title, profile, acceptance
                case dependsOn = "depends_on"
                case fallbackProfiles = "fallback_profiles"
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = try container.decode(String.self, forKey: .id)
                title = try container.decode(String.self, forKey: .title)
                dependsOn = try container.decodeIfPresent(
                    [String].self,
                    forKey: .dependsOn
                ) ?? []
                profile = try container.decodeIfPresent(String.self, forKey: .profile)
                fallbackProfiles = try container.decodeIfPresent(
                    [String].self,
                    forKey: .fallbackProfiles
                ) ?? []
                acceptance = try container.decodeIfPresent(
                    [String].self,
                    forKey: .acceptance
                ) ?? []
            }
        }

        let nodes: [Node]
    }

    static func extract(
        from content: String,
        availableProfileIDs: Set<String>? = nil,
        namespace: String = "dispatch"
    ) -> AgentGoalDispatchPlan? {
        guard let json = fencedBlock(named: "dispatch-graph", in: content),
              let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              validationFailures(
                payload: payload,
                availableProfileIDs: availableProfileIDs
              ).isEmpty else {
            return nil
        }

        let idByKey = Dictionary(
            uniqueKeysWithValues: payload.nodes.map {
                ($0.id, stableUUID(namespace: namespace, key: $0.id))
            }
        )
        return AgentGoalDispatchPlan(nodes: payload.nodes.compactMap { node in
            guard let id = idByKey[node.id] else { return nil }
            return AgentGoalDispatchPlan.Node(
                id: id,
                key: node.id,
                title: node.title.trimmingCharacters(in: .whitespacesAndNewlines),
                dependencyIDs: node.dependsOn.compactMap { idByKey[$0] },
                primaryProfileID: normalized(node.profile),
                fallbackProfileIDs: unique(
                    node.fallbackProfiles.compactMap(normalized)
                ),
                acceptanceCriteria: node.acceptance
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        })
    }

    static func validationFailures(
        content: String,
        availableProfileIDs: Set<String>? = nil
    ) -> [String] {
        guard let json = fencedBlock(named: "dispatch-graph", in: content),
              let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return ["the reply needs one valid fenced ```dispatch-graph JSON block"]
        }
        return validationFailures(
            payload: payload,
            availableProfileIDs: availableProfileIDs
        )
    }

    private static func validationFailures(
        payload: Payload,
        availableProfileIDs: Set<String>?
    ) -> [String] {
        var failures: [String] = []
        guard !payload.nodes.isEmpty else {
            return ["dispatch-graph.nodes must contain at least one execution node"]
        }
        let keys = payload.nodes.map {
            $0.id.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let keySet = Set(keys)
        if keySet.count != keys.count || keys.contains(where: \.isEmpty) {
            failures.append("every dispatch node id must be non-empty and unique")
        }
        for node in payload.nodes {
            if node.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                failures.append("dispatch node \(node.id) needs a non-empty title")
            }
            let missing = node.dependsOn.filter { !keySet.contains($0) }
            if !missing.isEmpty {
                failures.append("dispatch node \(node.id) references unknown dependencies: \(missing.joined(separator: ", "))")
            }
            if node.dependsOn.contains(node.id) {
                failures.append("dispatch node \(node.id) cannot depend on itself")
            }
            if node.acceptance.allSatisfy({
                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) {
                failures.append("dispatch node \(node.id) needs at least one acceptance criterion")
            }
            if let availableProfileIDs {
                let profileIDs = [node.profile].compactMap { $0 } + node.fallbackProfiles
                let unavailable = profileIDs.filter { !availableProfileIDs.contains($0) }
                if !unavailable.isEmpty {
                    failures.append("dispatch node \(node.id) references unavailable profiles: \(unavailable.joined(separator: ", "))")
                }
            }
        }
        if hasCycle(payload.nodes) {
            failures.append("dispatch-graph dependencies must form an acyclic graph")
        }
        return failures
    }

    private static func hasCycle(_ nodes: [Payload.Node]) -> Bool {
        let dependencies = Dictionary(uniqueKeysWithValues: nodes.map {
            ($0.id, $0.dependsOn)
        })
        var visiting: Set<String> = []
        var visited: Set<String> = []

        func visit(_ key: String) -> Bool {
            if visiting.contains(key) { return true }
            if visited.contains(key) { return false }
            visiting.insert(key)
            for dependency in dependencies[key, default: []] where visit(dependency) {
                return true
            }
            visiting.remove(key)
            visited.insert(key)
            return false
        }
        return nodes.contains { visit($0.id) }
    }

    private static func fencedBlock(named name: String, in content: String) -> String? {
        let marker = "```\(name)"
        guard let markerRange = content.range(of: marker),
              let lineEnd = content[markerRange.upperBound...].firstIndex(of: "\n") else {
            return nil
        }
        let bodyStart = content.index(after: lineEnd)
        guard let bodyEnd = content.range(
            of: "```",
            range: bodyStart..<content.endIndex
        )?.lowerBound else {
            return nil
        }
        return String(content[bodyStart..<bodyEnd])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    /// Graph keys are authored by AI, but task UUIDs must survive retries and
    /// revised plans so runtime history and completed nodes do not disappear.
    private static func stableUUID(namespace: String, key: String) -> UUID {
        var bytes = Array(
            SHA256.hash(data: Data("\(namespace):\(key)".utf8)).prefix(16)
        )
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
