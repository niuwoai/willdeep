//
//  WorkflowRegistry.swift
//  WillDeep
//
//  内置 + 用户自定义 workflow 的统一注册中心。
//
//  1.81.0-rc1 起手只有内置 workflow 静态注册。
//  1.85.0-rc5 起把 `~/.willdeep/skills/<slug>/workflow.yaml` 发现来的
//  用户 workflow 合并进同一个表 —— composer palette、slash 命令分发、
//  `spawn_workflow` 工具看到的是合并后的列表。
//

import Foundation

enum WorkflowRegistry {
    /// 仅内置 workflow（不含用户）。顺序就是 palette 显示顺序的内置段。
    static let builtIn: [any WorkflowDefinition] = [
        DeepResearchWorkflow(),
        CodeReviewWorkflow(),
        BugHuntWorkflow(),
        CompetitorAnalysisWorkflow(),
        // 1.81.0-rc2：GitHub 系 workflow。所有这些 workflow 开跑前会
        // 通过 GitHubCLIPreflight 同步检查 `gh` 是否装好且登录，未通过
        // 直接报错给用户，避免子 agent 跑到 LLM 调用层才发现 401。
        PRReviewWorkflow(),
        ReleaseNotesWorkflow(),
        IssueTriageWorkflow(),
        // 1.81.0-rc3：BI / 数据库系 workflow。开跑前用
        // DatabaseToolingPreflight 解析 target 类型 + 检测对应 CLI
        // （duckdb / psql / mysql / sqlite3）。所有查询 prompt 强制
        // read-only —— sub-agent 看到 SELECT 之外的语句应当拒绝。
        CSVAskWorkflow(),
        DBExploreWorkflow(),
        DBSchemaDocWorkflow(),
        // Phase 1 voice-to-text (feat/voice-to-text branch). Local
        // SenseVoice ONNX pipeline ported from fastv. No LLM sub-agents
        // —— pure Swift work, runs through Workflow surface for card UI.
        TranscribeWorkflow(),
        // Phase 2 voice → application workflows. Both share the local
        // SenseVoice pipeline; /video-summary additionally needs
        // ffmpeg + (for URL inputs) yt-dlp.
        VideoSummaryWorkflow(),
        MeetingNotesWorkflow(),
        // 1.85.0-rc1: ffmpeg-driven video manipulation workflows. All
        // three rely on SpeechTranscriber to locate moments in the
        // video (clip / gif) or none at all (compress). Output goes to
        // ~/Downloads/.
        VideoClipWorkflow(),
        VideoCompressWorkflow(),
        VideoGifWorkflow(),
        // 1.85.0-rc2: "extract everything" + thumbnail + merge —— the
        // tools you reach for when copying someone else's video.
        VideoExtractWorkflow(),
        VideoThumbnailWorkflow(),
        VideoMergeWorkflow(),
        // 1.85.0-rc3: 「creator essentials」三连 —— 给"我抄了别人视频但
        // 要加点自己的东西"场景：水印、变速、字幕。
        VideoWatermarkWorkflow(),
        VideoSpeedupWorkflow(),
        VideoSubtitleWorkflow(),
    ]

    /// 全部 workflow：内置在前，用户自定义在后（同一 slash 用户不可覆盖
    /// 内置）。每次访问都重新扫盘 —— 用户改 yaml 立即生效，规模上 skill
    /// 数量是十级别，扫描成本可忽略。
    static var all: [any WorkflowDefinition] {
        let reserved = Set(builtIn.map(\.slashCommand))
        let user = UserWorkflowRegistry.discover(reservedSlashCommands: reserved)
        return builtIn + (user as [any WorkflowDefinition])
    }

    static func find(slashCommand: String) -> (any WorkflowDefinition)? {
        all.first { $0.slashCommand == slashCommand }
    }

    static func find(name: String) -> (any WorkflowDefinition)? {
        all.first { $0.name == name }
    }
}
