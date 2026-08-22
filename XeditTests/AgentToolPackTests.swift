import Foundation
import Testing
@testable import WillDeep

@Suite
@MainActor
struct AgentToolPackTests {
    @Test("every native descriptor is either core or assigned to exactly one optional pack")
    func catalogCoversRegistry() {
        let names = AgentToolRegistry.all.map(\.name)
        #expect(Set(names).count == names.count)

        let uncovered = names.filter {
            !AgentToolPackCatalog.coreToolNames.contains($0)
                && AgentToolPackCatalog.packID(for: $0) == nil
        }
        #expect(uncovered.isEmpty, "Uncovered tool descriptors: \(uncovered.joined(separator: ", "))")

        for pack in AgentToolPackCatalog.packs {
            #expect(!AgentToolPackCatalog.toolNames(in: pack.id).isEmpty)
        }
    }

    @Test("ordinary coding requests expose only the compact stable core")
    func emptyPackSetUsesCompactCore() {
        let tools = AgentToolRegistry.tools(activeExperts: [], loadedPacks: [])
        let names = tools.map(\.name)

        #expect(names.count <= 24)
        #expect(names.first == AgentToolPackCatalog.loaderToolName)
        #expect(names.contains("read_file"))
        #expect(names.contains("edit_file"))
        #expect(names.contains("run_command"))
        #expect(names.contains("list_skills"))
        #expect(!names.contains("chrome_snapshot"))
        #expect(!names.contains("generate_image"))
    }

    @Test("loaded packs append schemas in registry order and never remove the core")
    func loadedPacksExpandMonotonically() {
        let core = AgentToolRegistry.tools(activeExperts: [], loadedPacks: [])
        let browser = AgentToolRegistry.tools(activeExperts: [], loadedPacks: [.browserWeb])
        let browserAndMedia = AgentToolRegistry.tools(
            activeExperts: [],
            loadedPacks: [.media, .browserWeb]
        )

        #expect(Set(core.map(\.name)).isSubset(of: Set(browser.map(\.name))))
        #expect(Set(browser.map(\.name)).isSubset(of: Set(browserAndMedia.map(\.name))))
        #expect(browser.contains { $0.name == "web_search" })
        #expect(browser.contains { $0.name == "chrome_snapshot" })
        #expect(browserAndMedia.contains { $0.name == "generate_image" })

        let allOrder = Dictionary(uniqueKeysWithValues: AgentToolRegistry.all.enumerated().map { ($0.element.name, $0.offset) })
        let offsets = browserAndMedia.compactMap { allOrder[$0.name] }
        #expect(offsets == offsets.sorted())
    }

    @Test("loader validates ids and activates several packs in one call")
    func loaderActivatesSeveralPacks() async throws {
        var loaded = Set<AgentToolPackID>()
        let context = AgentToolContext(
            rootDirectory: nil,
            toolPackActivationSink: { requested in
                loaded.formUnion(requested)
                return loaded
            }
        )

        let result = try await AgentToolRunner.run(
            name: AgentToolPackCatalog.loaderToolName,
            arguments: ["pack_ids": .array([.string("browser_web"), .string("media")])],
            context: context
        )

        #expect(loaded == [.browserWeb, .media])
        #expect(result.payload.contains("chrome_snapshot"))
        #expect(result.payload.contains("generate_image"))
    }

    @Test("expert activation implicitly loads its domain pack")
    func expertsImplicitlyLoadDomainPacks() {
        let browserNames = Set(AgentToolRegistry.tools(
            activeExperts: [.browserOps],
            loadedPacks: []
        ).map(\.name))
        let shortDramaNames = Set(AgentToolRegistry.tools(
            activeExperts: [.shortDrama],
            loadedPacks: []
        ).map(\.name))

        #expect(browserNames.contains("embedded_browser_snapshot"))
        #expect(shortDramaNames.contains("short_drama_create_project"))
        #expect(shortDramaNames.contains("generate_image"))
    }
}
