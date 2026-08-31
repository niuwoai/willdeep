import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentWorkerTierSharedConfigTests {
    /// Shaped like the config.toml willdeep-rs actually ships, so the parser
    /// is tested against the neighbours it has to skip rather than an
    /// idealized three-line file.
    private let realisticConfig = """
    version = 1
    default_provider = "some-im"

    [providers.some-im]
    provider = "some-im"
    api_base = "https://some.im/v1"
    model = "glm-5"

    [providers.private-box]
    provider = "openai-compatible"
    api_base = "https://box.internal/v1"
    model = "qwen3-32b"

    [worker_tiers.advanced]
    model = "deepseek-v4-pro"   # 进阶档换成 pro

    [worker_tiers.expert]
    provider_profile = "private-box"
    model = "opus-5"
    context_window = 400000

    [subagents.implementer]
    context_window = 262144

    [notifications]
    webhook_enabled = true
    """

    @Test("the shared [worker_tiers.*] tables parse alongside everything else in the file")
    func parsesTierTables() {
        let config = AgentWorkerTierSharedConfig.parse(realisticConfig)

        #expect(config[.standard] == nil, "未写的档不该凭空出现")
        // Trailing inline comment must not become part of the model name.
        #expect(config[.advanced]?.model == "deepseek-v4-pro")
        #expect(config[.advanced]?.providerProfile == nil)
        #expect(config[.expert]?.model == "opus-5")
        #expect(config[.expert]?.contextWindowTokens == 400_000)

        // `provider_profile` names a table; only the preset inside it means
        // anything to this app.
        #expect(config[.expert]?.providerProfile == "private-box")
        #expect(config.providerPreset(for: config[.expert]!) == "openai-compatible")
        #expect(config.providerPresets["some-im"] == "some-im")

        // `[subagents.*]` and `[providers.*].model` are different tables and
        // must not leak into a tier.
        #expect(config.tiers.count == 2)
    }

    @Test("only the three canonical table names are recognized")
    func rejectsAliasTableNames() {
        // `deep` still works as a tier *value* on both sides, but as a table
        // name it would collide with `expert` and there is no defensible rule
        // for which one wins — the CLI rejects it outright, and reading it
        // here would resurrect exactly the ambiguity that rejection prevents.
        let config = AgentWorkerTierSharedConfig.parse("""
        [worker_tiers.deep]
        model = "opus-5"

        [worker_tiers.basic]
        model = "glm-5"
        """)
        #expect(config.tiers.isEmpty)
    }

    @Test("a missing or unreadable config.toml is simply empty")
    func missingFileIsEmpty() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("willdeep-\(UUID().uuidString)/config.toml")
        #expect(AgentWorkerTierSharedConfig.load(from: url) == AgentWorkerTierSharedConfig())
    }

    @Test("a hash inside a quoted model name is not an inline comment")
    func hashInsideQuotesSurvives() {
        let config = AgentWorkerTierSharedConfig.parse("""
        [worker_tiers.advanced]
        model = "vendor#weird-name"   # 真正的注释
        """)
        #expect(config[.advanced]?.model == "vendor#weird-name")
    }

    @Test("a quoted provider table name still matches provider_profile")
    func quotedProviderTableName() {
        let config = AgentWorkerTierSharedConfig.parse("""
        [providers."my box"]
        provider = "openai-compatible"

        [worker_tiers.expert]
        provider_profile = "my box"
        model = "opus-5"
        """)
        #expect(config.providerPreset(for: config[.expert]!) == "openai-compatible")
    }

    @Test("the file overrides the app's stored binding, tier by tier")
    func fileWinsOverStoredBindings() {
        var stored = AgentWorkerTierModels()
        stored[.advanced] = .init(preferredProviderID: "some-im", model: "deepseek-v4-flash")
        stored[.expert] = .init(preferredProviderID: "some-im", model: "gpt-5.6-sol")

        let entry = UUID()
        let merged = AgentWorkerTierModels.merging(
            stored: stored,
            shared: AgentWorkerTierSharedConfig.parse(realisticConfig),
            resolveProviderPreset: { preset in
                preset == "openai-compatible" ? (entry, "openai-compatible") : nil
            }
        )

        // 没写的档保持 App 自己的设置。
        #expect(merged[.standard].model == AgentWorkerTierModels.defaultBinding(.standard).model)
        // 只写了 model：沿用父端点，与 willdeep-rs 同一语义。
        #expect(merged[.advanced].model == "deepseek-v4-pro")
        #expect(merged[.advanced].preferredProviderEntryID == nil)
        #expect(merged[.advanced].preferredProviderID == nil)
        // 写了 provider_profile：整套端点都换。
        #expect(merged[.expert].model == "opus-5")
        #expect(merged[.expert].preferredProviderEntryID == entry)
        #expect(merged[.expert].contextWindowTokens == 400_000)
    }

    @Test("an unresolvable provider profile disables the tier instead of falling back")
    func unresolvableProviderDoesNotFallThroughToTheParent() {
        // 这是最要紧的一条：静默回落会把 opus-5 发到会话当前那个网关上——
        // 一个必然失败、而且没人要求过的请求。宁可这一档派不出去。
        let merged = AgentWorkerTierModels.merging(
            stored: AgentWorkerTierModels(),
            shared: AgentWorkerTierSharedConfig.parse(realisticConfig),
            resolveProviderPreset: { _ in nil }
        )
        #expect(merged[.expert].model == nil)
        #expect(merged[.expert].preferredProviderEntryID == nil)
        // 窗口仍然保留：这一档跑不了，但预算计算不该因此读到一个错的数。
        #expect(merged[.expert].contextWindowTokens == 400_000)
        // 没指定 provider 的那一档不受影响。
        #expect(merged[.advanced].model == "deepseek-v4-pro")
    }

    @Test("a tier table with no model leaves the app's binding alone")
    func tableWithoutModelIsNotAnOverride() {
        // 只写了 context_window 的段落不构成「换模型」，否则会把 App 里配好的
        // 模型抹成空，这一档直接不可用。
        var stored = AgentWorkerTierModels()
        stored[.advanced] = .init(preferredProviderID: "some-im", model: "deepseek-v4-flash")
        let merged = AgentWorkerTierModels.merging(
            stored: stored,
            shared: AgentWorkerTierSharedConfig.parse("""
            [worker_tiers.advanced]
            context_window = 262144
            """)
        )
        #expect(merged[.advanced].model == "deepseek-v4-flash")
    }

    @Test("the parse is memoized per file revision and re-read after an edit")
    func cacheFollowsTheFile() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("willdeep-tier-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")

        try "[worker_tiers.expert]\nmodel = \"opus-5\"\n".write(to: url, atomically: true, encoding: .utf8)
        AgentWorkerTierSharedConfig.invalidateCache()
        #expect(AgentWorkerTierSharedConfig.cached(from: url)[.expert]?.model == "opus-5")

        // 改文件之后必须重读。mtime 的分辨率不保证能区分同一瞬间的两次写入，
        // 所以这里连内容长度一起变，覆盖 (mtime, size) 两个判据里的后一个。
        try "[worker_tiers.expert]\nmodel = \"gpt-5.6-sol\"\ncontext_window = 400000\n"
            .write(to: url, atomically: true, encoding: .utf8)
        #expect(AgentWorkerTierSharedConfig.cached(from: url)[.expert]?.model == "gpt-5.6-sol")
    }
}
