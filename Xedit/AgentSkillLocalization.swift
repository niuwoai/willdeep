//
//  AgentSkillLocalization.swift
//  WillDeep
//
//  Localized presentation metadata for bundled skills. The underlying
//  SKILL.md identifier and body stay unchanged; this layer only affects UI
//  labels and search matching.
//

import Foundation

struct AgentSkillLocalizedMetadata {
    let name: String
    let description: String
    let aliases: [String]
}

enum AgentSkillLocalization {
    static func displayName(for entry: AgentSkillEntry) -> String {
        guard entry.source == .bundled,
              let metadata = metadata(for: entry) else {
            return entry.name
        }
        return metadata.name
    }

    static func displayDescription(for entry: AgentSkillEntry) -> String {
        guard entry.source == .bundled,
              let metadata = metadata(for: entry) else {
            return entry.description
        }
        return metadata.description
    }

    static func searchableText(for entry: AgentSkillEntry) -> String {
        var parts = [
            entry.identifier,
            entry.name,
            entry.description,
            entry.url.path
        ]
        // Pool EVERY language's translation into the recall set — not just
        // the current UI locale's — so a Chinese keyword finds an
        // English-authored skill and vice versa. This is what makes the
        // multilingual "命中池" work regardless of who is searching.
        if entry.source == .bundled {
            for metadata in allMetadata(for: entry) {
                parts.append(metadata.name)
                parts.append(metadata.description)
                parts.append(contentsOf: metadata.aliases)
            }
        }
        return parts.joined(separator: "\n").lowercased()
    }

    /// Locale-specific metadata, used for DISPLAY (labels shown to the user
    /// in their own language).
    private static func metadata(for entry: AgentSkillEntry) -> AgentSkillLocalizedMetadata? {
        let slug = slug(for: entry)
        let table = prefersSimplifiedChinese ? zhHansMetadata : enMetadata
        return table[slug] ?? table[entry.name]
    }

    /// Metadata from ALL language tables, used for SEARCH (every translation
    /// joins the recall pool). Deduped by identity of the returned struct is
    /// unnecessary — each table contributes at most one entry per slug.
    private static func allMetadata(for entry: AgentSkillEntry) -> [AgentSkillLocalizedMetadata] {
        let slug = slug(for: entry)
        return [enMetadata, zhHansMetadata].compactMap { table in
            table[slug] ?? table[entry.name]
        }
    }

    private static func slug(for entry: AgentSkillEntry) -> String {
        entry.identifier.split(separator: ":").last.map(String.init) ?? entry.identifier
    }

    private static var prefersSimplifiedChinese: Bool {
        let preferred = Locale.preferredLanguages.first ?? Locale.current.identifier
        return preferred.lowercased().hasPrefix("zh")
    }

    private static let enMetadata: [String: AgentSkillLocalizedMetadata] = [
        "browser": .init(
            name: "browser",
            description: "Automate browser tasks: navigate pages, fill forms, click buttons, extract data, and take screenshots.",
            aliases: ["web automation", "chrome", "pinchtab"]
        ),
        "computer-use": .init(
            name: "computer-use",
            description: "Control native macOS apps with clicks, typing, keyboard shortcuts, scrolling, dragging, and screenshots.",
            aliases: ["desktop automation", "mac app", "accessibility"]
        ),
        "mac-app-docs-site": .init(
            name: "Mac App Docs Site",
            description: "Capture real macOS app workflows, write illustrated Markdown tutorials, and publish them through a documentation website.",
            aliases: ["mac app documentation", "screenshot tutorial", "markdown docs", "documentation website"]
        ),
        "daily-report": .init(
            name: "daily-report",
            description: "Build an evidence-based work report from the current workspace, Git history, changes, and visible session metadata.",
            aliases: ["work journal", "recap", "日报"]
        ),
        "discord": .init(
            name: "discord",
            description: "Operate Discord through a configured MCP server after discovering its exact tools.",
            aliases: ["bot", "guild", "channel"]
        ),
        "example-translate": .init(
            name: "example-translate",
            description: "Example declarative workflow that translates text into Simplified Chinese with /translate-cn.",
            aliases: ["translation", "workflow example"]
        ),
        "file-manager": .init(
            name: "file-manager",
            description: "Find, organize, move, rename, compress, and clean up files on the user's computer.",
            aliases: ["files", "finder", "organize"]
        ),
        "design-to-code": .init(
            name: "Design to Code",
            description: "Turn a selected screenshot, mockup, or Figma frame into a faithful, responsive, verified web frontend.",
            aliases: ["image to code", "screenshot to code", "mockup to React", "frontend recreation"]
        ),
        "figma-swiftui": .init(
            name: "Figma ↔ SwiftUI",
            description: "Translate Figma designs and native SwiftUI screens in either direction, with safe MCP fallback behavior.",
            aliases: ["Figma to SwiftUI", "SwiftUI to Figma", "iOS design", "design to code"]
        ),
        "image-gen": .init(
            name: "image-gen",
            description: "Generate or edit images with AI, including photos, avatars, backgrounds, and logos.",
            aliases: ["draw", "picture", "photo"]
        ),
        "memory-management": .init(
            name: "memory-management",
            description: "Save durable preferences, project rules, recurring facts, and reusable constraints with WillDeep memory.",
            aliases: ["remember", "history", "recall"]
        ),
        "music-gen": .init(
            name: "music-gen",
            description: "Generate songs or instrumentals through a music-generation MCP server configured in WillDeep.",
            aliases: ["song", "audio", "compose"]
        ),
        "music-listener": .init(
            name: "music-listener",
            description: "Inspect local audio metadata and use a configured provider for transcription or semantic analysis.",
            aliases: ["audio analysis", "song analysis"]
        ),
        "notebook": .init(
            name: "notebook",
            description: "Edit Jupyter notebooks by inserting, replacing, or deleting notebook cells.",
            aliases: ["ipynb", "jupyter"]
        ),
        "plan-mode": .init(
            name: "plan-mode",
            description: "Produce a structured, evidence-based plan for complex work without changing state.",
            aliases: ["planning", "plan"]
        ),
        "reactions": .init(
            name: "reactions",
            description: "Add emoji reactions through configured messaging tools when the target message is known.",
            aliases: ["emoji", "reaction"]
        ),
        "scheduler": .init(
            name: "scheduler",
            description: "Create recurring WillDeep tasks at a fixed minute interval or daily local time.",
            aliases: ["reminder", "cron", "automation"]
        ),
        "screenshot": .init(
            name: "screenshot",
            description: "Capture and resize macOS screenshots for UI debugging or screen inspection.",
            aliases: ["screen capture", "capture"]
        ),
        "swiftui-hang-diagnose": .init(
            name: "swiftui-hang-diagnose",
            description: "Diagnose native SwiftUI/AppKit/UIKit app hangs with sample, spindump, main-thread stack reading, and fix patterns.",
            aliases: ["SwiftUI hang", "beachball", "sample", "spindump", "main thread", "CPU 100%"]
        ),
        "self-management": .init(
            name: "self-management",
            description: "Inspect or change WillDeep settings, models, integrations, permissions, updates, and session preferences.",
            aliases: ["settings", "config"]
        ),
        "self-reflection": .init(
            name: "self-reflection",
            description: "Write a grounded reflection or journal entry from the current conversation and provided evidence.",
            aliases: ["diary", "journal", "growth"]
        ),
        "selfie": .init(
            name: "selfie",
            description: "Create or edit a photorealistic selfie with an optional user-provided reference image.",
            aliases: ["portrait", "self photo"]
        ),
        "send-file": .init(
            name: "send-file",
            description: "Deliver files, photos, audio, video, generated art, documents, or screenshots to the user.",
            aliases: ["share file", "send photo"]
        ),
        "skill-hub": .init(
            name: "skill-hub",
            description: "Inspect and maintain WillDeep built-in, user-created, and plugin-provided skills.",
            aliases: ["skill marketplace", "install skill"]
        ),
        "skill-search": .init(
            name: "skill-search",
            description: "Find an installed skill, create a user skill, or identify a missing MCP integration.",
            aliases: ["discover skills", "install skills"]
        ),
        "system-info": .init(
            name: "system-info",
            description: "Inspect OS version, disk usage, memory, processes, network status, and system health.",
            aliases: ["diagnostics", "computer status"]
        ),
        "tasks": .init(
            name: "tasks",
            description: "Route multi-step work to workspace todos, recurring scheduled tasks, and session metadata.",
            aliases: ["task tracking", "project tasks"]
        ),
        "telegram": .init(
            name: "telegram",
            description: "Operate Telegram through a configured MCP server after discovering its exact tools.",
            aliases: ["bot api", "telegram group"]
        ),
        "thread-management": .init(
            name: "thread-management",
            description: "List sessions in the current workspace and rename the current WillDeep session.",
            aliases: ["conversation management", "threads"]
        ),
        "todo": .init(
            name: "todo",
            description: "Manage a workspace Markdown todo list for complex multi-step work.",
            aliases: ["checklist", "task list"]
        ),
        "travel": .init(
            name: "travel",
            description: "Research and plan real trips, itineraries, transport, lodging, budgets, food, and current conditions.",
            aliases: ["virtual travel", "destination"]
        ),
        "twitter-media": .init(
            name: "twitter-media",
            description: "Extract text, images, videos, and thumbnails from Twitter/X links.",
            aliases: ["x.com", "tweet", "media"]
        ),
        "video-reader": .init(
            name: "video-reader",
            description: "Inspect local video metadata and frames, with optional transcription through a configured provider.",
            aliases: ["watch video", "video analysis"]
        ),
        "voice": .init(
            name: "voice",
            description: "Create local text-to-speech audio with macOS voices or a configured TTS provider.",
            aliases: ["tts", "audio reply"]
        ),
        "web-fetch": .init(
            name: "web-fetch",
            description: "Fetch and read web pages, APIs, online content, and shared URLs.",
            aliases: ["url", "web page"]
        ),
        "web-search": .init(
            name: "web-search",
            description: "Search the web for current information, research, and fact checking.",
            aliases: ["search engine", "research"]
        ),
        "xiaohongshu-cli": .init(
            name: "xiaohongshu-cli",
            description: "Handle Xiaohongshu / Rednote tasks: login, search, read notes, comments, feeds, and posting.",
            aliases: ["小红书", "rednote", "little red book"]
        )
    ]

    private static let zhHansMetadata: [String: AgentSkillLocalizedMetadata] = [
        "browser": .init(name: "浏览器自动化", description: "自动操作网页:导航、填表、点击按钮、提取数据和截图。", aliases: ["浏览器", "网页自动化", "Chrome", "PinchTab"]),
        "computer-use": .init(name: "电脑操作", description: "控制 macOS 原生应用:点击、输入、快捷键、滚动、拖拽和截图。", aliases: ["桌面自动化", "Mac 应用", "辅助功能"]),
        "mac-app-docs-site": .init(name: "Mac App 图文文档站", description: "采集真实 macOS App 界面与流程截图，生成图文 Markdown 教程并接入文档网页。", aliases: ["Mac App 文档", "截图教程", "图文教程", "Markdown 文档站"]),
        "daily-report": .init(name: "工作日报", description: "根据当前工作区、Git 历史、改动和可见会话元数据生成有据可查的工作报告。", aliases: ["日报", "复盘", "工作总结"]),
        "discord": .init(name: "Discord", description: "通过已配置的 MCP 服务发现并调用 Discord 工具。", aliases: ["机器人", "频道", "服务器"]),
        "design-to-code": .init(name: "Design to Code", description: "把选中的截图、视觉稿或 Figma 画面还原成高保真、响应式且经过验证的 Web 前端。", aliases: ["截图转代码", "设计转代码", "界面复刻", "视觉稿转前端"]),
        "example-translate": .init(name: "翻译示例", description: "内置声明式 workflow 示例,用 /translate-cn 把文本翻译成简体中文。", aliases: ["翻译", "工作流示例"]),
        "file-manager": .init(name: "文件管理", description: "查找、整理、移动、重命名、压缩和清理用户电脑上的文件。", aliases: ["文件", "访达", "整理"]),
        "figma-swiftui": .init(name: "Figma ↔ SwiftUI", description: "在 Figma 设计与原生 SwiftUI 界面之间双向转换，并在缺少 MCP 能力时安全降级。", aliases: ["设计稿转 SwiftUI", "SwiftUI 转 Figma", "iOS 设计还原", "设计转代码"]),
        "image-gen": .init(name: "图像生成", description: "用 AI 生成或编辑图片,包括照片、头像、背景和 Logo。", aliases: ["画图", "图片", "照片"]),
        "memory-management": .init(name: "记忆管理", description: "把长期偏好、项目规则、重复事实和可复用约束保存到 WillDeep 记忆。", aliases: ["记住", "历史", "召回"]),
        "music-gen": .init(name: "音乐生成", description: "通过 WillDeep 中已配置的音乐生成 MCP 服务生成歌曲或纯音乐。", aliases: ["歌曲", "音频", "作曲"]),
        "music-listener": .init(name: "音乐聆听", description: "检查本地音频元数据，并通过已配置服务完成转写或语义分析。", aliases: ["音频分析", "歌曲分析"]),
        "notebook": .init(name: "Notebook 编辑", description: "编辑 Jupyter Notebook,支持插入、替换或删除单元格。", aliases: ["ipynb", "Jupyter"]),
        "plan-mode": .init(name: "计划模式", description: "在不改变文件或外部状态的前提下，为复杂工作生成结构化、有依据的计划。", aliases: ["规划", "计划"]),
        "reactions": .init(name: "消息反应", description: "通过已配置的消息工具给指定消息添加 emoji 反应。", aliases: ["表情", "回应"]),
        "scheduler": .init(name: "定时任务", description: "创建按固定分钟间隔或每日本地时间运行的 WillDeep 周期任务。", aliases: ["提醒", "定时", "自动化"]),
        "screenshot": .init(name: "屏幕截图", description: "截取并缩放 macOS 屏幕截图,用于界面调试或查看屏幕。", aliases: ["截图", "屏幕捕获"]),
        "swiftui-hang-diagnose": .init(name: "SwiftUI 卡死诊断", description: "用 sample、spindump 和主线程栈判读诊断原生 SwiftUI/AppKit/UIKit App 卡死、转圈、CPU 跑满等问题。", aliases: ["SwiftUI 卡死", "主线程卡死", "转圈", "彩虹圈", "sample", "spindump", "CPU 100%"]),
        "self-management": .init(name: "WillDeep 设置", description: "查看或修改 WillDeep 的设置、模型、集成、权限、更新和会话偏好。", aliases: ["设置", "配置"]),
        "self-reflection": .init(name: "反思记录", description: "根据当前对话和用户提供的证据撰写可信的反思或日记。", aliases: ["日记", "反思", "成长"]),
        "selfie": .init(name: "自拍", description: "使用可选的用户参考图生成或编辑写实自拍。", aliases: ["自拍照", "头像", "人像"]),
        "send-file": .init(name: "发送文件", description: "把文件、照片、音频、视频、生成图、文档或截图发送给用户。", aliases: ["发文件", "发送照片"]),
        "skill-hub": .init(name: "技能中心", description: "查看和维护 WillDeep 的内置技能、用户技能与插件技能。", aliases: ["技能市场", "安装技能"]),
        "skill-search": .init(name: "技能搜索", description: "查找已安装技能、创建用户技能或识别缺失的 MCP 集成。", aliases: ["发现技能", "安装技能"]),
        "system-info": .init(name: "系统信息", description: "查看系统版本、磁盘、内存、进程、网络状态和健康信息。", aliases: ["诊断", "电脑状态"]),
        "tasks": .init(name: "任务协调", description: "把多步骤工作路由到工作区待办、周期任务和会话元数据。", aliases: ["任务跟踪", "项目任务"]),
        "telegram": .init(name: "Telegram", description: "通过已配置的 MCP 服务发现并调用 Telegram 工具。", aliases: ["机器人 API", "电报群"]),
        "thread-management": .init(name: "会话管理", description: "列出当前工作区会话，并重命名当前 WillDeep 会话。", aliases: ["对话管理", "线程"]),
        "todo": .init(name: "待办清单", description: "用工作区 Markdown 文件管理复杂多步骤任务的待办列表。", aliases: ["清单", "任务列表"]),
        "travel": .init(name: "旅行规划", description: "研究并规划真实旅行、行程、交通、住宿、预算、美食与当前状况。", aliases: ["旅行", "目的地"]),
        "twitter-media": .init(name: "Twitter/X 媒体", description: "从 Twitter/X 链接提取文本、图片、视频和缩略图。", aliases: ["推文", "X 链接", "媒体"]),
        "video-reader": .init(name: "视频理解", description: "检查本地视频元数据和画面，并可通过已配置服务完成转写。", aliases: ["看视频", "视频分析"]),
        "voice": .init(name: "语音生成", description: "使用 macOS 系统音色或已配置 TTS 服务生成文本转语音音频。", aliases: ["文字转语音", "语音回复"]),
        "web-fetch": .init(name: "网页读取", description: "获取并阅读网页、API、在线内容和用户分享的 URL。", aliases: ["链接", "网页"]),
        "web-search": .init(name: "网页搜索", description: "搜索最新信息、做资料研究和事实核查。", aliases: ["搜索引擎", "研究"]),
        "xiaohongshu-cli": .init(name: "小红书 CLI", description: "处理小红书 / Rednote 任务:登录、搜索、读笔记评论、浏览和发布。", aliases: ["小红书", "Rednote", "Little Red Book"])
    ]
}
