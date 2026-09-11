import Foundation
import Testing
@testable import WillDeep

/// 插件页面的模型选择器此前只有两个来源：这一次页面加载的现场探测，以及
/// provider 条目里配置的那一两个 model id。探测是一次带 15 秒上限的网络
/// 调用，失败或超时就只剩配置里那一两个——而 some.im 条目配的恰好只有
/// `someim-auto-flash` 一个，中继那边却有几十个模型。用户看到的就是
/// 「插件里能选的模型比 some.im 提供的少好多」。
///
/// 这个 suite 守住那层持久化：一次成功探测之后目录就长在磁盘上，后面再
/// 失败也不会把列表打回一两条。
@Suite
struct AgentPluginProviderCatalogTests {
    @MainActor
    @Test("一次成功探测之后，目录从磁盘读得回来")
    func catalogSurvivesAcrossReads() {
        let sandbox = KeychainSandbox()
        defer { _ = sandbox }
        let entryID = UUID()

        AgentSettingsStore.saveProviderModelCatalog(
            entryID: entryID,
            models: ["gpt-5.6-sol", "kimi-k3", "deepseek-v4-pro"]
        )

        let loaded = AgentSettingsStore.loadProviderModelCatalogs()[entryID]
        #expect(loaded == ["gpt-5.6-sol", "kimi-k3", "deepseek-v4-pro"])
    }

    /// 「这次探测什么也没拿到」正是这层缓存要防的那个场景。用空列表覆写
    /// 等于亲手制造它要防的塌缩。
    @MainActor
    @Test("空列表不覆写已有目录")
    func emptyFetchDoesNotWipe() {
        let sandbox = KeychainSandbox()
        defer { _ = sandbox }
        let entryID = UUID()

        AgentSettingsStore.saveProviderModelCatalog(entryID: entryID, models: ["kimi-k3"])
        AgentSettingsStore.saveProviderModelCatalog(entryID: entryID, models: [])
        #expect(AgentSettingsStore.loadProviderModelCatalogs()[entryID] == ["kimi-k3"])

        // 空白字符串也算空：清洗之后没有内容就不该动磁盘。
        AgentSettingsStore.saveProviderModelCatalog(entryID: entryID, models: ["  ", ""])
        #expect(AgentSettingsStore.loadProviderModelCatalogs()[entryID] == ["kimi-k3"])
    }

    @MainActor
    @Test("删掉的 provider 条目不会把目录永远留在 defaults 里")
    func pruneDropsRetiredEntries() {
        let sandbox = KeychainSandbox()
        defer { _ = sandbox }
        let kept = UUID()
        let retired = UUID()

        AgentSettingsStore.saveProviderModelCatalog(entryID: kept, models: ["kimi-k3"])
        AgentSettingsStore.saveProviderModelCatalog(entryID: retired, models: ["glm-5.2"])
        AgentSettingsStore.pruneProviderModelCatalogs(keeping: [kept])

        let catalogs = AgentSettingsStore.loadProviderModelCatalogs()
        #expect(catalogs[kept] == ["kimi-k3"])
        #expect(catalogs[retired] == nil)
    }

    /// some.im 的 `/v1/model-capabilities` 不要凭据，而 `/v1/models` 没 key
    /// 就是 401。列表塌成一条的根子在这儿：签出状态下可鉴权那条必然失败。
    @MainActor
    @Test("capabilities 端点解析出模型和各自的上下文窗口")
    func capabilitiesPayloadParses() throws {
        let payload = Data("""
        {"object":"list","data":[
          {"id":"kimi-k3","object":"model.capability","capability_kinds":["llm"],
           "context_window":1000000,"max_output_tokens":1048576,
           "supports_thinking":true,"supports_tools":true},
          {"id":"gpt-5.6-sol","object":"model.capability","capability_kinds":["llm"],
           "context_window":512000,"max_output_tokens":8192,
           "supports_thinking":false,"supports_tools":false},
          {"id":"deepseek-v4-flash","object":"model.capability","capability_kinds":["llm"],
           "context_window":null,"max_output_tokens":8192}
        ]}
        """.utf8)

        let found = try AgentSomeIMModelCapabilities.discoveries(from: payload)
        #expect(found.map(\.id) == ["deepseek-v4-flash", "gpt-5.6-sol", "kimi-k3"])

        // 上报的窗口要原样收下：本地按模型名匹配的表把 kimi-k3 猜成 128K，
        // 少算 87%，压缩和 90% 的停车会对着一个几乎没用的窗口开火。
        #expect(found.first { $0.id == "kimi-k3" }?.contextWindowTokens == 1_000_000)
        #expect(found.first { $0.id == "gpt-5.6-sol" }?.contextWindowTokens == 512_000)
        // 没上报就留空，让本地那张表去兜——不要把 0 当成窗口。
        #expect(found.first { $0.id == "deepseek-v4-flash" }?.contextWindowTokens == nil)
    }

    /// `supports_tools` 不能当权威：gpt-5.6-sol 在这个端点上报 false，而审计
    /// 日志里它实打实完成过一次 write_episode 工具调用。拿它去关功能等于把
    /// 本来能用的路掐掉，所以解析层根本不收这个字段。
    @MainActor
    @Test("非对话类模型不进聊天模型列表，未标类别的照旧算对话模型")
    func capabilitiesFiltersNonConversational() throws {
        let payload = Data("""
        {"object":"list","data":[
          {"id":"kimi-k3","capability_kinds":["llm"],"context_window":1000000},
          {"id":"seedance-2.0","capability_kinds":["video"],"context_window":null},
          {"id":"legacy-model","context_window":128000}
        ]}
        """.utf8)

        let ids = try AgentSomeIMModelCapabilities.discoveries(from: payload).map(\.id)
        #expect(ids.contains("kimi-k3"))
        #expect(!ids.contains("seedance-2.0"))
        // 没有 capability_kinds 字段一直就是「对话模型」的意思，不能误杀。
        #expect(ids.contains("legacy-model"))
    }

    /// 缓存目录必须真的能进模型列表。`models(for:)` 把配置里的 id 排在
    /// 前面，探测/缓存来的接在后面，并且过滤掉图像、视频、语音这些不是
    /// 对话模型的条目。
    @MainActor
    @Test("缓存目录进得了模型列表，非对话模型照样挡在外面")
    func cachedCatalogFeedsTheModelList() {
        // 用户真实配置的形状：some.im 条目只配了一个 model id。
        let entry = AgentProviderEntry(
            providerID: AgentProviderPreset.someIMID,
            baseURL: "https://some.im/v1",
            flashPrimary: "someim-auto-flash",
            proPrimary: "someim-auto-flash"
        )

        let models = AgentExecutionProfileModelCatalog.models(
            for: entry,
            discoveredModels: ["gpt-5.6-sol", "gpt-image-2", "kimi-k3", "sora-2", "text-embedding-3-large"]
        )

        #expect(models.first == "someim-auto-flash")
        #expect(models.contains("gpt-5.6-sol"))
        #expect(models.contains("kimi-k3"))
        // 图像、视频、嵌入模型不能出现在聊天模型选择器里。
        #expect(!models.contains("gpt-image-2"))
        #expect(!models.contains("sora-2"))
        #expect(!models.contains("text-embedding-3-large"))
    }
}
