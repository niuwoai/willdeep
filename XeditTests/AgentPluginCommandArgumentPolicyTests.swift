import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentPluginCommandArgumentPolicyTests {
    @Test("允许 10 MiB 附件及 Base64 和 JSON 转义开销")
    func acceptsMaximumAttachment() throws {
        // 0xff produces slashes in Base64: exercise JSON's worst-case escaping.
        let bytes = Data(repeating: 0xff, count: 10 * 1024 * 1024)
        let arguments: [String: Any] = [
            "id": "todo-test", "name": "截图.png", "mimeType": "image/png",
            "dataBase64": bytes.base64EncodedString()
        ]
        let encoded = try JSONSerialization.data(withJSONObject: arguments)
        #expect(encoded.count > 65_536)
        #expect(AgentPluginCommandArgumentPolicy.accepts(keyCount: arguments.count, encodedArguments: encoded))
        let decoded = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: String])
        #expect(Data(base64Encoded: try #require(decoded["dataBase64"])) == bytes)
    }

    @Test("允许字节上限，拒绝超限")
    func byteBoundary() {
        let limit = AgentPluginCommandArgumentPolicy.maximumEncodedBytes
        #expect(AgentPluginCommandArgumentPolicy.accepts(keyCount: 1, encodedArguments: Data(count: limit)))
        #expect(!AgentPluginCommandArgumentPolicy.accepts(keyCount: 1, encodedArguments: Data(count: limit + 1)))
    }

    @Test("保留参数数量及 JSON 有效性限制")
    func keyCountAndEncoding() {
        #expect(AgentPluginCommandArgumentPolicy.accepts(keyCount: 64, encodedArguments: Data("{}".utf8)))
        #expect(!AgentPluginCommandArgumentPolicy.accepts(keyCount: 65, encodedArguments: Data("{}".utf8)))
        #expect(!AgentPluginCommandArgumentPolicy.accepts(keyCount: 1, encodedArguments: nil))
    }
}
