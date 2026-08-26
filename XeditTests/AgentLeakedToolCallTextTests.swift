//
//  AgentLeakedToolCallTextTests.swift
//  WillDeepTests
//

import Testing

@testable import WillDeep

/// Samples are transcribed from real sessions on disk, including the doubled
/// full-width bars the models actually produced.
@Suite("Leaked tool-call markup")
nonisolated struct AgentLeakedToolCallTextTests {
    @Test("整条回复都是 DSML 块时正文清空、片段留证")
    func wholeReplyIsDSMLMarkup() {
        let raw = """
        <｜｜DSML｜｜tool_calls>
        <｜｜DSML｜｜invoke name="get_job_output">
        <｜｜DSML｜｜parameter name="job_id" string="true">job_8a9548</｜｜DSML｜｜parameter>
        </｜｜DSML｜｜invoke>
        </｜｜DSML｜｜tool_calls>
        """

        let detection = AgentLeakedToolCallText.detect(in: raw)

        #expect(detection?.cleanedText == "")
        #expect(detection?.discardedFragment == raw)
    }

    /// The costly case: the handover prose was being written as a tool
    /// argument, so the useful text sits *before* the first marker — which is
    /// a closing tag, not an opening one.
    @Test("正文写在闭合标签之前时正文必须保留")
    func prosePrecedingAClosingTagSurvives() {
        let raw = """
        PAUSE: 上下文快跑完了，这不是任务完成。

        DONE: 已把草稿完整镜像到 `PluginExamples/session-vitality/`。</｜｜DSML｜｜parameter>
        <｜｜DSML｜｜parameter name="path" string="true">PluginExamples/session-vitality</｜｜DSML｜｜parameter>
        </｜｜DSML｜｜invoke>
        </｜｜DSML｜｜tool_calls>
        """

        let detection = AgentLeakedToolCallText.detect(in: raw)

        #expect(detection?.cleanedText.hasPrefix("PAUSE: 上下文快跑完了") == true)
        #expect(detection?.cleanedText.hasSuffix("session-vitality/`。") == true)
        #expect(detection?.cleanedText.contains("DSML") == false)
        #expect(detection?.discardedFragment.hasPrefix("</") == true)
    }

    @Test("canonical 单竖线 DSML 同样识别")
    func canonicalSinglePipeIsRecognized() {
        #expect(AgentLeakedToolCallText.contains(in: "<｜DSML｜tool_calls>\nx"))
    }

    @Test("非 DeepSeek 家族的 <tool_call> 语法同样识别")
    func openWeightToolCallSyntaxIsRecognized() {
        let raw = """
        <tool_call>
        <function=get_job_output>
        <parameter=job_id>
        job_b21872
        </parameter>
        </function>
        </tool_call>
        """

        let detection = AgentLeakedToolCallText.detect(in: raw)

        #expect(detection?.cleanedText == "")
        #expect(detection?.discardedFragment.hasPrefix("<tool_call>") == true)
    }

    /// A handover that merely *mentions* these names must survive intact —
    /// stripping is only ever justified by tag-shaped markup.
    @Test("正常交接文本不被误伤")
    func ordinaryHandoverTextIsUntouched() {
        let raw = """
        PAUSE: 上下文触顶。

        DONE: 修好了 DSML 泄漏的解析路径，函数名是 detect(in:)。
        REMAINING: 还要覆盖 tool_calls 这个字段的回归测试。
        NEXT PROMPT: 继续补 AgentLeakedToolCallText 的用例。
        """

        #expect(AgentLeakedToolCallText.detect(in: raw) == nil)
        #expect(AgentLeakedToolCallText.contains(in: raw) == false)
    }

    @Test("空文本与纯散文返回 nil")
    func emptyAndPlainTextYieldNoDetection() {
        #expect(AgentLeakedToolCallText.detect(in: "") == nil)
        #expect(AgentLeakedToolCallText.detect(in: "一切正常，没有任何标记。") == nil)
    }

    /// Bars without a tag around them are ordinary punctuation — tables and
    /// Chinese prose both use the full-width bar.
    @Test("孤立的全角竖线不构成标记")
    func lonePipesAreNotMarkers() {
        #expect(AgentLeakedToolCallText.contains(in: "选项 A｜选项 B｜选项 C") == false)
        #expect(AgentLeakedToolCallText.contains(in: "DSML 是 DeepSeek 的标记语言") == false)
    }

    @Test("最早出现的标记决定切点")
    func earliestMarkerWins() {
        let raw = "先说明。<tool_call>后面还有 <｜｜DSML｜｜tool_calls> 更多垃圾"

        #expect(AgentLeakedToolCallText.detect(in: raw)?.cleanedText == "先说明。")
    }
}
