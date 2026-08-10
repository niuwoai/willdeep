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
    static let recommendedWorkerID = "builtin:willdeep:deepseek-v4-flash"
    private static let someIMProviderID = "some-im"

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
            providerID: someIMProviderID,
            origin: .builtIn
        ),
        AgentExecutionProfile(
            id: recommendedWorkerID,
            name: "DeepSeek V4 Flash Worker",
            executor: .willDeep,
            modelID: AgentDispatchModelRouting.recommendedExecutionModel,
            providerID: someIMProviderID,
            origin: .builtIn
        ),
        AgentExecutionProfile(
            id: "builtin:willdeep:gpt-5.6-sol",
            name: "GPT-5.6 Sol Worker",
            executor: .willDeep,
            modelID: "gpt-5.6-sol",
            providerID: someIMProviderID,
            origin: .builtIn
        ),
        AgentExecutionProfile(
            id: "builtin:willdeep:gpt-5.6-luna",
            name: "GPT-5.6 Luna Worker",
            executor: .willDeep,
            modelID: "gpt-5.6-luna",
            providerID: someIMProviderID,
            origin: .builtIn
        ),
        AgentExecutionProfile(
            id: "builtin:willdeep:gpt-5.6-terra",
            name: "GPT-5.6 Terra Worker",
            executor: .willDeep,
            modelID: "gpt-5.6-terra",
            providerID: someIMProviderID,
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
    static let maximumNodeCount = 9

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
        if payload.nodes.count > maximumNodeCount {
            failures.append("dispatch-graph exceeds the maximum of \(maximumNodeCount) execution nodes")
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
        } else if keySet.count == keys.count, !keys.contains(where: \.isEmpty) {
            failures += semanticGraphFailures(payload.nodes)
        }
        return failures
    }

    /// A syntactically valid graph can still be operationally useless. The
    /// most common failure is a planner emitting every task as a root and
    /// relying on the synthetic UI acceptance gate as its only convergence
    /// point. That gate is not an execution node: it cannot integrate code,
    /// run tests, or repair a failed deliverable. Multi-node projects must
    /// therefore contain their own staged convergence before they reach it.
    private static func semanticGraphFailures(_ nodes: [Payload.Node]) -> [String] {
        guard nodes.count >= 3 else { return [] }

        let dependenciesByKey = Dictionary(nodes.map { ($0.id, $0.dependsOn) }) {
            _, latest in latest
        }
        let dependencyKeys = Set(nodes.flatMap(\.dependsOn))
        let terminalKeys = nodes.map(\.id).filter { !dependencyKeys.contains($0) }
        var failures: [String] = []

        if nodes.allSatisfy({ $0.dependsOn.isEmpty }) {
            failures.append(
                "a dispatch graph with three or more nodes cannot put every node in the first parallel wave; add real prerequisite edges plus explicit integration and verification work before the synthetic acceptance gate"
            )
        }
        if terminalKeys.count != 1 {
            failures.append(
                "a dispatch graph with three or more nodes must converge to exactly one executable terminal integration/verification node before the synthetic acceptance gate; found \(terminalKeys.count) terminal nodes"
            )
        }

        var depths: [String: Int] = [:]
        func depth(of key: String) -> Int {
            if let existing = depths[key] { return existing }
            let value = dependenciesByKey[key, default: []]
                .map { depth(of: $0) }
                .max()
                .map { $0 + 1 } ?? 0
            depths[key] = value
            return value
        }
        let maximumDepth = nodes.map { depth(of: $0.id) }.max() ?? 0
        if maximumDepth < 2 {
            failures.append(
                "a dispatch graph with three or more nodes needs at least three execution layers (foundation, implementation/integration, verification); the synthetic acceptance gate does not count as a layer"
            )
        }

        let nodesByDepth = Dictionary(grouping: nodes) { depth(of: $0.id) }
        let containsParallelWave = nodesByDepth.values.contains { $0.count > 1 }
        let convergenceNodes = nodes.filter { node in
            node.dependsOn.count >= 2 && hasIntegrationSemantics(node)
        }
        if containsParallelWave, convergenceNodes.isEmpty {
            failures.append(
                "parallel dispatch branches need a distinct merge/integration node whose depends_on lists the upstream implementation nodes"
            )
        }

        if terminalKeys.count == 1,
           let terminalKey = terminalKeys.first,
           let terminalNode = nodes.first(where: { $0.id == terminalKey }) {
            if !hasVerificationSemantics(terminalNode) {
                failures.append(
                    "the executable terminal node must be a distinct test, regression, or verification task before the synthetic acceptance gate"
                )
            }
            if containsParallelWave {
                let integrationKeys = Set(convergenceNodes.map(\.id))
                let directIntegrationDependencies = Set(terminalNode.dependsOn)
                    .intersection(integrationKeys)
                if directIntegrationDependencies.isEmpty {
                    failures.append(
                        "the terminal verification node must depend directly on the distinct merge/integration node; merging code is execution work, not part of the synthetic acceptance gate"
                    )
                }
            }
        }
        return failures
    }

    private static func hasIntegrationSemantics(_ node: Payload.Node) -> Bool {
        containsSemanticMarker(
            node,
            markers: [
                "merge", "integrat", "consolidat", "assemble",
                "合并", "集成", "汇合", "汇总", "整合", "组装",
            ]
        )
    }

    private static func hasVerificationSemantics(_ node: Payload.Node) -> Bool {
        containsSemanticMarker(
            node,
            markers: [
                "test", "verify", "verification", "validation", "regression",
                "review", "quality assurance", "acceptance",
                "测试", "验证", "回归", "复核", "审查", "质检", "验收",
            ]
        )
    }

    private static func containsSemanticMarker(
        _ node: Payload.Node,
        markers: [String]
    ) -> Bool {
        let searchable = ([node.title] + node.acceptance)
            .joined(separator: "\n")
            .lowercased()
        return markers.contains { searchable.contains($0) }
    }

    private static func hasCycle(_ nodes: [Payload.Node]) -> Bool {
        let dependencies = Dictionary(nodes.map { ($0.id, $0.dependsOn) }) {
            _, latest in latest
        }
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
