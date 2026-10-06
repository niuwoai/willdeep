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

        // 26 since background-task contract C2: `monitor`, `send_agent_message`
        // and `stop_agent` are core like the job tools they complement.
        #expect(names.count <= 26)
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
        #expect(!shortDramaNames.contains { $0.hasPrefix("short_drama_") })
        #expect(shortDramaNames.contains("generate_image"))
    }

    @Test("unmounted packs stay out of the tool list, the pack index and model dispatch")
    func unmountedShortDramaPackIsHiddenFromTheModel() {
        #expect(AgentToolPackCatalog.unmountedPacks.contains(.shortDrama))
        #expect(AgentToolPackCatalog.isUnmounted(toolName: "short_drama_create_project"))
        #expect(!AgentToolPackCatalog.isUnmounted(toolName: "generate_image"))

        let full = AgentToolRegistry.tools(activeExperts: [.shortDrama]).map(\.name)
        let lazy = AgentToolRegistry.tools(activeExperts: [.shortDrama], loadedPacks: [.shortDrama, .media]).map(\.name)
        #expect(!full.contains { $0.hasPrefix("short_drama_") })
        #expect(!lazy.contains { $0.hasPrefix("short_drama_") })
        #expect(!AgentToolPackCatalog.loaderDescriptor.description.contains("`short_drama`"))
        let effective = AgentToolPackCatalog.effectiveLoadedPacks(
            explicit: [.shortDrama], activeExperts: [.shortDrama], delegationPolicy: .automatic
        )
        #expect(!effective.contains(.shortDrama))
        #expect(effective.contains(.media))
        #expect(throws: AgentToolError.self) {
            _ = try AgentToolPackCatalog.requestedPackIDs(from: ["pack_ids": .array([.string("short_drama")])])
        }

        #expect(!AgentToolNameAliases.isDispatchable("short_drama_create_project", advertisedToolNames: []))
        let message = AgentToolNameAliases.unknownToolMessage(for: "short_drama_create_project", advertisedToolNames: [])
        #expect(message.contains("mcp__video_studio__"))
        #expect(message.contains("Nothing was executed"))

        let plugin = AgentToolDescriptor(name: "mcp__video_studio__drama_get", description: "", risk: .read, parameters: [])
        let withPlugin = AgentToolRegistry.tools(activeExperts: [.shortDrama], loadedPacks: [], pluginMCPTools: [plugin]).map(\.name)
        #expect(withPlugin.contains("mcp__video_studio__drama_get"))
    }
}
