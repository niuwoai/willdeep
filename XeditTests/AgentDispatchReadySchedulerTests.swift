import Foundation
import Testing
@testable import WillDeep

@Suite("关键路径与资源约束调度")
struct AgentDispatchReadySchedulerTests {
    private typealias Scheduler = AgentDispatchReadyScheduler

    private func node(_ id: UUID, dependencies: [UUID] = [], phase: Scheduler.Phase = .queued,
                      cost: Double = 1, workspace: String = "repository", paths: [String]? = nil,
                      shared: String? = nil) -> Scheduler.Node {
        var resources = [Scheduler.Resource(key: workspace, paths: paths)]
        if let shared { resources.append(.init(key: shared, paths: nil)) }
        return .init(id: id, dependencies: dependencies, phase: phase, cost: cost, resources: resources)
    }

    @Test("优先启动最长剩余链而非队首，成本提示影响关键路径")
    func criticalPathPrecedesQueueOrder() {
        let short = UUID(), foundation = UUID(), tail = UUID()
        let nodes = [node(short, cost: 5), node(foundation, cost: 1), node(tail, dependencies: [foundation], cost: 10)]
        #expect(Scheduler.ready(nodes: nodes, capacity: 1) == [foundation])
        #expect(Scheduler.ready(nodes: [node(short, cost: 50)] + nodes.dropFirst(), capacity: 1) == [short])
    }

    @Test("独立文件可并行，目录重叠及现有验收任务占用会阻止冲突")
    func pathReservationsAndActiveVerification() {
        let a = UUID(), b = UUID(), nested = UUID()
        let nodes = [node(a, paths: ["src/a"]), node(b, paths: ["src/b"]), node(nested, paths: ["src/a/detail.swift"])]
        #expect(Scheduler.ready(nodes: nodes, capacity: 3) == [a, b])
        let active = node(a, phase: .active, paths: ["src/a"])
        #expect(Scheduler.ready(nodes: [active] + nodes.dropFirst(), capacity: 3) == [b])
    }

    @Test("未知写范围保守串行，共享缓存跨工作区互斥")
    func unknownScopeAndSharedResources() {
        let a = UUID(), b = UUID(), other = UUID()
        #expect(Scheduler.ready(nodes: [node(a), node(b), node(other, workspace: "other")], capacity: 3) == [a, other])
        let active = node(a, phase: .active, workspace: "repo-a", paths: ["a"], shared: "cache")
        #expect(Scheduler.ready(nodes: [active, node(b, workspace: "repo-b", shared: "cache"), node(other, workspace: "repo-c")], capacity: 3) == [other])
    }

    @Test("未集成依赖、缺失依赖和环不会被启动，独立分支仍可推进")
    func invalidOrUnintegratedDependenciesDoNotRun() {
        let a = UUID(), b = UUID(), c = UUID(), missing = UUID(), independent = UUID()
        let nodes = [node(a, dependencies: [b]), node(b, dependencies: [a]), node(c, dependencies: [missing]), node(independent)]
        #expect(Scheduler.ready(nodes: nodes, capacity: 10) == [independent])
        #expect(Scheduler.ready(nodes: [node(a, phase: .active), node(b, dependencies: [a])], capacity: 1).isEmpty)
        #expect(Scheduler.ready(nodes: [node(a, phase: .integrated), node(b, dependencies: [a])], capacity: 1) == [b])
        #expect(Scheduler.ready(nodes: [node(a), node(a)], capacity: 1).isEmpty)
    }

    @Test("稳定同分顺序、容量边界、无效成本与路径提示均有确定行为")
    func boundsAndHintValidation() throws {
        let a = UUID(), b = UUID()
        #expect(Scheduler.ready(nodes: [node(a, cost: .infinity), node(b, cost: .nan)], capacity: 1) == [a])
        #expect(Scheduler.ready(nodes: [node(a)], capacity: 0).isEmpty)
        let scope = AgentDispatchSchedulingHints(writePaths: ["Sources/Feature/**", "Tests/test.swift"])
        #expect(scope.covers("Sources/Feature/file.swift"))
        #expect(!scope.covers("Sources/FeatureOther/file.swift"))
        #expect(!scope.covers("../private"))
        for invalid in ["../outside", "/absolute", "**", "a/../b", "a\\b"] {
            #expect(AgentDispatchSchedulingHints(writePaths: [invalid]).normalizedWritePaths == nil)
        }
        let json = Data("{\"estimated_seconds\":25,\"write_paths\":[\"Sources\"],\"exclusive_resources\":[\"cache\"]}".utf8)
        let decoded = try JSONDecoder().decode(AgentDispatchSchedulingHints.self, from: json)
        #expect(decoded.cost == 25)
        #expect(decoded.exclusiveResources == ["cache"])
        #expect(try JSONDecoder().decode(AgentDispatchSchedulingHints.self, from: Data("{}".utf8)).normalizedWritePaths == nil)
    }
}
