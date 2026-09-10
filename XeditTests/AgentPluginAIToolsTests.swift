import Foundation
import Testing
@testable import WillDeep

/// 插件页面靠围栏约定收结构化产出，而模型隔三差五回一个普通的 ```json，
/// 整块产出就被当成闲聊丢掉。工具 schema 把口头约定换成协议：字段名和类型
/// 由 provider 那一侧强制。
///
/// 这个 suite 守两件事：页面递过来的工具声明在进模型之前被收干净，以及
/// 「没走工具」和「走了但填坏了」在结果里是两种可分辨的状态——页面据此
/// 决定要不要回落到围栏解析。
@Suite
struct AgentPluginAIToolsTests {
    private func request(_ raw: [String: Any]) -> AgentPluginAIRequest? {
        guard case .success(let value) = AgentPluginAIRequestValidator.request(from: raw) else { return nil }
        return value
    }

    private var baseRequest: [String: Any] {
        ["system": "you are a screenwriter", "messages": [["role": "user", "content": "写这一集"]]]
    }

    private func tool(
        name: String = "write_episode",
        parameters: [[String: Any]] = [["name": "script", "type": "string", "description": "正文", "required": true]]
    ) -> [String: Any] {
        ["name": name, "description": "交出这一集", "parameters": parameters]
    }

    @Test("不带工具时行为和以前完全一致")
    func toolsAreOptional() throws {
        let parsed = try #require(request(baseRequest))
        #expect(parsed.tools.isEmpty)
    }

    @Test("工具声明被完整带到模型侧的描述符上")
    func toolsReachTheDescriptor() throws {
        var raw = baseRequest
        raw["tools"] = [tool(parameters: [
            ["name": "title", "type": "string", "description": "标题"],
            ["name": "duration", "type": "integer", "description": "时长", "required": true],
        ])]
        let parsed = try #require(request(raw))
        #expect(parsed.tools.count == 1)
        let descriptor = try #require(parsed.tools.first).descriptor
        #expect(descriptor.name == "write_episode")
        #expect(descriptor.parameters.map(\.name) == ["title", "duration"])
        #expect(descriptor.parameters[1].type == .integer)
        #expect(descriptor.parameters[1].required)
        // 这些工具什么也不执行，审批与沙箱层面没有可授予的权限。
        #expect(descriptor.risk == .read)
    }

    /// 名字不合规的整条丢掉而不是修正：页面按自己声明的名字去认返回值，
    /// 宿主替它改了名，它就永远认不到。
    @Test("非法工具名整条丢弃，不做修正")
    func malformedToolNamesAreDropped() throws {
        var raw = baseRequest
        raw["tools"] = [
            tool(name: "Write Episode"),
            tool(name: "写这一集"),
            tool(name: ""),
            tool(name: "write_episode"),
        ]
        let parsed = try #require(request(raw))
        #expect(parsed.tools.map(\.name) == ["write_episode"])
    }

    @Test("重名工具和重名参数只保留第一份")
    func duplicatesCollapse() throws {
        var raw = baseRequest
        raw["tools"] = [
            tool(parameters: [
                ["name": "script", "type": "string", "description": "第一份"],
                ["name": "script", "type": "integer", "description": "第二份"],
            ]),
            tool(),
        ]
        let parsed = try #require(request(raw))
        #expect(parsed.tools.count == 1)
        #expect(parsed.tools[0].parameters.count == 1)
        #expect(parsed.tools[0].parameters[0].type == .string)
    }

    @Test("没有参数的工具不算数，超出上限直接拒绝整条请求")
    func emptyAndExcessiveToolsAreRejected() throws {
        var raw = baseRequest
        raw["tools"] = [tool(parameters: [])]
        #expect(try #require(request(raw)).tools.isEmpty)

        raw["tools"] = (0...AgentPluginAIRequest.maximumTools).map { tool(name: "write_\($0)") }
        guard case .failure(let error) = AgentPluginAIRequestValidator.request(from: raw) else {
            Issue.record("超出工具上限的请求应当被拒绝")
            return
        }
        #expect(error == .tooManyTools)
    }

    @Test("未知参数类型的字段被丢掉，其余字段照常保留")
    func unknownParameterTypesAreDropped() throws {
        var raw = baseRequest
        raw["tools"] = [tool(parameters: [
            ["name": "shots", "type": "objectArray", "description": "表达不了的形状"],
            ["name": "script", "type": "string", "description": "正文"],
        ])]
        let parsed = try #require(request(raw))
        #expect(parsed.tools[0].parameters.map(\.name) == ["script"])
    }

    /// 「模型只填了工具参数、一个字正文都没有」是工具调用最常见的形状，
    /// 不能被当成空回复。
    @Test("只有工具参数没有正文也算模型给了答案")
    func toolCallAloneIsAnAnswer() {
        let result = AgentPluginAIResult(
            text: "",
            model: "gpt-5.6-sol",
            providerID: "some.im",
            toolCalls: [AgentPluginAIToolCall(name: "write_episode", argumentsJSON: #"{"script":"陈默：喂？"}"#)]
        )
        #expect(!result.toolCalls.isEmpty)
        #expect(result.text.isEmpty)
        let object = result.toolCalls[0].jsonObject
        #expect(object["name"] as? String == "write_episode")
        #expect((object["arguments"] as? String)?.contains("陈默") == true)
    }

    @Test("桥的能力清单登记了 ai.tools")
    func bridgeAdvertisesTheCapability() {
        #expect(AgentPluginPageBridge.capabilities.contains("ai.tools"))
        // 只增不改：既有能力一个都不能因为这次新增而消失。
        #expect(AgentPluginPageBridge.capabilities.contains("ai.complete"))
        #expect(AgentPluginPageBridge.version != "2.4.0")
    }
}
