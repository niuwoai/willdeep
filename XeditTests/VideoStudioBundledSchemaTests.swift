import Foundation
import Testing
@testable import WillDeep

@Suite("Video Studio bundled schema")
struct VideoStudioBundledSchemaTests {
    @Test("Installed service loads its shared creative schema from the application bundle")
    func bundledServiceLoadsSchema() throws {
        let resources = try #require(Bundle.main.resourceURL)
        let plugin = resources.appendingPathComponent("BundledPlugins/video-studio")
        let schema = plugin.appendingPathComponent("schemas/creative-v1.json")
        let data = try Data(contentsOf: schema)
        let catalog = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let definitions = try #require(catalog["$defs"] as? [String: Any])
        #expect(definitions["frames"] != nil)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
        process.arguments = [
            "-r", plugin.appendingPathComponent("server/lib/creative_schema.rb").path,
            "-e", "exit(CreativeSchema::CATALOG.fetch('$defs').key?('frames') ? 0 : 1)"
        ]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == 0)
    }
}
