import Foundation

/// Planning hints are scheduling constraints, not permission grants. Missing or
/// malformed write scopes reserve the whole workspace conservatively.
nonisolated struct AgentDispatchSchedulingHints: Codable, Equatable, Sendable {
    static let maximumEstimatedSeconds: Double = 7 * 24 * 60 * 60
    var estimatedSeconds: Double? = nil
    var writePaths: [String]? = nil
    var exclusiveResources: [String]? = nil

    enum CodingKeys: String, CodingKey {
        case estimatedSeconds = "estimated_seconds"
        case writePaths = "write_paths"
        case exclusiveResources = "exclusive_resources"
    }

    var cost: Double {
        guard let value = estimatedSeconds, value.isFinite, value > 0 else { return 1 }
        return min(value, Self.maximumEstimatedSeconds)
    }

    var normalizedWritePaths: [String]? {
        guard let writePaths, !writePaths.isEmpty, writePaths.count <= 256 else { return nil }
        let normalized = writePaths.compactMap(Self.normalizedPath)
        guard normalized.count == writePaths.count else { return nil }
        return Array(Set(normalized)).sorted()
    }

    func covers(_ path: String) -> Bool {
        guard let scope = normalizedWritePaths else { return true }
        guard let path = Self.normalizedPath(path) else { return false }
        return scope.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private static func normalizedPath(_ raw: String) -> String? {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasSuffix("/**") { path.removeLast(3) }
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"),
              path.rangeOfCharacter(from: CharacterSet(charactersIn: "*?[]\\\0\n\r")) == nil else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return path.precomposedStringWithCanonicalMapping.lowercased()
    }
}

nonisolated enum AgentDispatchReadyScheduler {
    enum Phase { case queued, active, integrated, inactive }

    struct Resource: Equatable {
        let key: String
        /// Nil means an exclusive whole-resource reservation.
        let paths: [String]?
    }

    struct Node {
        let id: UUID
        let dependencies: [UUID]
        let phase: Phase
        let cost: Double
        let resources: [Resource]
    }

    /// Longest remaining dependency path first, stable input order for ties.
    /// Kahn traversal avoids recursive overflow and leaves cycles unlaunchable.
    static func ready(nodes: [Node], capacity: Int) -> [UUID] {
        guard capacity > 0 else { return [] }
        var byID: [UUID: Node] = [:]
        for node in nodes {
            guard byID.updateValue(node, forKey: node.id) == nil else { return [] }
        }
        let scores = criticalPathCosts(nodes: nodes, byID: byID)
        let candidates = nodes.enumerated().filter { _, node in
            node.phase == .queued && scores[node.id] != nil
                && node.dependencies.allSatisfy { byID[$0]?.phase == .integrated }
        }.sorted { lhs, rhs in
            let left = scores[lhs.element.id] ?? 0, right = scores[rhs.element.id] ?? 0
            return left == right ? lhs.offset < rhs.offset : left > right
        }
        var reserved = nodes.filter { $0.phase == .active }.flatMap(\.resources)
        var result: [UUID] = []
        for (_, node) in candidates {
            if node.resources.contains(where: { proposed in reserved.contains { conflicts(proposed, $0) } }) { continue }
            result.append(node.id)
            reserved.append(contentsOf: node.resources)
            if result.count == capacity { break }
        }
        return result
    }

    private static func criticalPathCosts(nodes: [Node], byID: [UUID: Node]) -> [UUID: Double] {
        var children: [UUID: [UUID]] = [:], indegrees: [UUID: Int] = [:]
        for node in nodes {
            let dependencies = Set(node.dependencies)
            indegrees[node.id] = dependencies.count
            for dependency in dependencies { children[dependency, default: []].append(node.id) }
        }
        var order = nodes.filter { indegrees[$0.id] == 0 }.map(\.id)
        var cursor = 0
        while cursor < order.count {
            let id = order[cursor]
            cursor += 1
            for child in children[id] ?? [] {
                indegrees[child, default: 0] -= 1
                if indegrees[child] == 0 { order.append(child) }
            }
        }
        var scores: [UUID: Double] = [:]
        for id in order.reversed() {
            guard let node = byID[id] else { continue }
            let downstream = children[id] ?? []
            guard downstream.allSatisfy({ scores[$0] != nil }) else { continue }
            let cost = node.cost.isFinite && node.cost > 0 ? min(node.cost, AgentDispatchSchedulingHints.maximumEstimatedSeconds) : 1
            scores[id] = (node.phase == .integrated ? 0 : cost) + (downstream.compactMap { scores[$0] }.max() ?? 0)
        }
        return scores
    }

    private static func conflicts(_ lhs: Resource, _ rhs: Resource) -> Bool {
        guard lhs.key == rhs.key else { return false }
        guard let left = lhs.paths, let right = rhs.paths else { return true }
        return left.contains { a in right.contains { b in a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/") } }
    }
}
