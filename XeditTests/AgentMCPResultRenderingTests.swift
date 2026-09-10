import Foundation
import Testing
@testable import WillDeep

/// 真实故障：短剧工坊点「生成 4 张候选」，右下角弹出
/// `JSON Parse error: Unterminated string`，候选是 0。
///
/// 原因是宿主把 MCP 工具的结果一律走 `prettyJSON`，那里在 48000 字符处硬
/// 截断并接上 `[truncated]`。给模型看没问题——省上下文，`[truncated]` 它
/// 读得懂，少一点信息而已。给插件页面看是致命的：那头是 `JSON.parse`，
/// 半份 JSON 直接抛错，而切口落在字符串里的时候，报错长得特别像「服务挂
/// 了」，可服务好好的，是宿主把它的回答剪断了。
///
/// 所以这个 suite 守的是一条不变量：**页面那条路要么给完整 JSON，要么
/// 报错，绝不给半份。**
@Suite
struct AgentMCPResultRenderingTests {
    /// 一集剧本加候选图轻松过 48000 字符，短剧工坊每次保存都撞。
    private func largeResult(characters: Int) -> [String: Any] {
        ["ok": true, "script": String(repeating: "戏", count: characters)]
    }

    @Test("超过 48000 字符时，模型那份会截断")
    func modelFacingTruncates() {
        let rendered = AgentMCPBridge.prettyJSON(largeResult(characters: 60_000))
        #expect(rendered.contains("[truncated]"))
        // 截断之后就不再是合法 JSON——这正是页面不能用它的原因。
        #expect((try? JSONSerialization.jsonObject(with: Data(rendered.utf8))) == nil)
    }

    @Test("同样的数据，页面那份完整且可解析")
    func pageFacingStaysParsable() throws {
        let value = largeResult(characters: 60_000)
        let rendered = try AgentMCPBridge.render(value, as: .pageFacing)
        #expect(!rendered.contains("[truncated]"))
        let parsed = try JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any]
        #expect(parsed?["ok"] as? Bool == true)
        #expect((parsed?["script"] as? String)?.count == 60_000)
    }

    /// 页面那份不缩进：消费者是机器，缩进只是白白多出的字节。
    @Test("页面那份紧凑，模型那份缩进")
    func pageFacingIsCompact() throws {
        let value: [String: Any] = ["ok": true, "count": 2]
        let page = try AgentMCPBridge.render(value, as: .pageFacing)
        let model = try AgentMCPBridge.render(value, as: .modelFacing)
        #expect(!page.contains("\n"))
        #expect(model.contains("\n"))
        // 两份解出来必须是同一个东西。
        let a = try JSONSerialization.jsonObject(with: Data(page.utf8)) as? [String: Any]
        let b = try JSONSerialization.jsonObject(with: Data(model.utf8)) as? [String: Any]
        #expect(a?["ok"] as? Bool == b?["ok"] as? Bool)
    }

    /// 大到离谱时宁可报错。一个明确的失败可以查，一份看着像 JSON 的半截
    /// 数据只会把人引去查错的地方——这次就是。
    @Test("超过页面上限时抛错，而不是截断")
    func pageFacingThrowsInsteadOfTruncating() {
        let huge = largeResult(characters: AgentMCPBridge.pageFacingResultLimit)
        #expect(throws: (any Error).self) {
            _ = try AgentMCPBridge.render(huge, as: .pageFacing)
        }
    }

    @Test("上限足够容下一部短剧的量级")
    func limitIsGenerousEnoughForRealData() {
        // 客户那份会话 JSON 是 2.9 MB；短剧数据同一量级。上限低于这个数
        // 等于把正常使用判成错误。
        #expect(AgentMCPBridge.pageFacingResultLimit > 8 * 1024 * 1024)
    }
}
