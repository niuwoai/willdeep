import Foundation
import Testing
@testable import WillDeep

@MainActor
@Suite("Runtime-owned plugin workflows")
struct AgentPluginRuntimeWorkflowTests {
    @Test("Only public workflow controls are routed")
    func publicTools() {
        #expect(AgentPluginRuntimeWorkflow.tools.contains("production.start"))
        #expect(AgentPluginRuntimeWorkflow.tools.contains("screenplay.download"))
        #expect(!AgentPluginRuntimeWorkflow.tools.contains("production.step"))
        #expect(!AgentPluginRuntimeWorkflow.tools.contains("screenplay.step"))
        #expect(!AgentPluginRuntimeWorkflow.tools.contains("fs.read"))
        #expect(!WillDeepRuntimeClient.readOnlyOperations.contains("plugin.workflow"))
    }

    @Test("Delivery selects a workflow and fixed selector, never a file path")
    func deliverySelectors() throws {
        let id = "22222222-2222-4222-8222-222222222222"
        for selector in ["manifest", "records", "episode-1", "episode-80"] {
            let url = try #require(URL(string: "willdeep-plugin://bundle/plugin-production/\(id)/\(selector)"))
            #expect(AgentPluginProductionDelivery.selection(url)?.selector == selector)
        }
        for selector in ["episode-0", "episode-81", "episode-01", "file.txt", "manifest/extra"] {
            let url = try #require(URL(string: "willdeep-plugin://bundle/plugin-production/\(id)/\(selector)"))
            #expect(AgentPluginProductionDelivery.selection(url) == nil)
        }
    }

    @Test("Streaming ranges support seeking and suffixes")
    func ranges() throws {
        #expect(try AgentPluginProductionDelivery.byteRange(nil, bytes: 100) == 0...99)
        #expect(try AgentPluginProductionDelivery.byteRange("bytes=10-19", bytes: 100) == 10...19)
        #expect(try AgentPluginProductionDelivery.byteRange("bytes=90-", bytes: 100) == 90...99)
        #expect(try AgentPluginProductionDelivery.byteRange("bytes=-10", bytes: 100) == 90...99)
        for header in ["bytes=100-", "bytes=20-10", "bytes=0-2,8-9", "items=0-1"] {
            #expect(throws: (any Error).self) {
                try AgentPluginProductionDelivery.byteRange(header, bytes: 100)
            }
        }
    }
}
