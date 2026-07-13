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
        "daily-report": .init(
            name: "daily-report",
            description: "Generate a work journal for a day or week, grouped by project, decisions, mentions, and versions.",
            aliases: ["work journal", "recap", "日报"]
        ),
        "discord": .init(
            name: "discord",
            description: "Interact with Discord channels and manage the Discord bot integration.",
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
        "image-gen": .init(
            name: "image-gen",
            description: "Generate or edit images with AI, including photos, avatars, backgrounds, and logos.",
            aliases: ["draw", "picture", "photo"]
        ),
        "memory-management": .init(
            name: "memory-management",
            description: "Search and manage memory, past conversations, preferences, and personal facts.",
            aliases: ["remember", "history", "recall"]
        ),
        "music-gen": .init(
            name: "music-gen",
            description: "Generate original songs, lyrics, vocals, and instrumental music from prompts.",
            aliases: ["song", "audio", "compose"]
        ),
        "music-listener": .init(
            name: "music-listener",
            description: "Listen to music files and analyze genre, mood, tempo, lyrics, or song identity.",
            aliases: ["audio analysis", "song analysis"]
        ),
        "notebook": .init(
            name: "notebook",
            description: "Edit Jupyter notebooks by inserting, replacing, or deleting notebook cells.",
            aliases: ["ipynb", "jupyter"]
        ),
        "plan-mode": .init(
            name: "plan-mode",
            description: "Switch into structured planning mode for multi-step work, then exit when the plan is done.",
            aliases: ["planning", "plan"]
        ),
        "reactions": .init(
            name: "reactions",
            description: "React to messages with emoji on Telegram, Discord, and Feishu.",
            aliases: ["emoji", "reaction"]
        ),
        "scheduler": .init(
            name: "scheduler",
            description: "Create and manage reminders, recurring tasks, cron jobs, and heartbeat checks.",
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
            description: "Read and update Alma settings such as voice, TTS, models, and configuration.",
            aliases: ["settings", "config"]
        ),
        "self-reflection": .init(
            name: "self-reflection",
            description: "Run daily reflection, extract lessons, update personality notes, and write diary entries.",
            aliases: ["diary", "journal", "growth"]
        ),
        "selfie": .init(
            name: "selfie",
            description: "Create consistent selfies or self-portraits from the configured private reference album.",
            aliases: ["portrait", "self photo"]
        ),
        "send-file": .init(
            name: "send-file",
            description: "Deliver files, photos, audio, video, generated art, documents, or screenshots to the user.",
            aliases: ["share file", "send photo"]
        ),
        "skill-hub": .init(
            name: "skill-hub",
            description: "Search, install, and manage Alma skills from the skills.sh ecosystem.",
            aliases: ["skill marketplace", "install skill"]
        ),
        "skill-search": .init(
            name: "skill-search",
            description: "Search for and install new skills when the current capability set is not enough.",
            aliases: ["discover skills", "install skills"]
        ),
        "system-info": .init(
            name: "system-info",
            description: "Inspect OS version, disk usage, memory, processes, network status, and system health.",
            aliases: ["diagnostics", "computer status"]
        ),
        "tasks": .init(
            name: "tasks",
            description: "Track global multi-step tasks that persist across threads and app restarts.",
            aliases: ["task tracking", "project tasks"]
        ),
        "telegram": .init(
            name: "telegram",
            description: "Use Telegram Bot API for messages, media, group management, reactions, and more.",
            aliases: ["bot api", "telegram group"]
        ),
        "thread-management": .init(
            name: "thread-management",
            description: "Create, list, switch, delete, and search chat threads.",
            aliases: ["conversation management", "threads"]
        ),
        "todo": .init(
            name: "todo",
            description: "Manage a workspace Markdown todo list for complex multi-step work.",
            aliases: ["checklist", "task list"]
        ),
        "travel": .init(
            name: "travel",
            description: "Run virtual travel experiences, local exploration, travel diaries, and personality evolution.",
            aliases: ["virtual travel", "destination"]
        ),
        "twitter-media": .init(
            name: "twitter-media",
            description: "Extract text, images, videos, and thumbnails from Twitter/X links.",
            aliases: ["x.com", "tweet", "media"]
        ),
        "video-reader": .init(
            name: "video-reader",
            description: "Understand video or audio files with Gemini native video analysis or fallback extraction.",
            aliases: ["watch video", "video analysis"]
        ),
        "voice": .init(
            name: "voice",
            description: "Generate local voice messages and text-to-speech audio with configurable voices and emotions.",
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
        "daily-report": .init(name: "工作日报", description: "生成按项目、决策、提及和版本分组的每日或每周工作日志。", aliases: ["日报", "复盘", "工作总结"]),
        "discord": .init(name: "Discord", description: "与 Discord 频道交互并管理 Discord 机器人集成。", aliases: ["机器人", "频道", "服务器"]),
        "example-translate": .init(name: "翻译示例", description: "内置声明式 workflow 示例,用 /translate-cn 把文本翻译成简体中文。", aliases: ["翻译", "工作流示例"]),
        "file-manager": .init(name: "文件管理", description: "查找、整理、移动、重命名、压缩和清理用户电脑上的文件。", aliases: ["文件", "访达", "整理"]),
        "image-gen": .init(name: "图像生成", description: "用 AI 生成或编辑图片,包括照片、头像、背景和 Logo。", aliases: ["画图", "图片", "照片"]),
        "memory-management": .init(name: "记忆管理", description: "搜索和管理记忆、历史对话、偏好与个人事实。", aliases: ["记住", "历史", "召回"]),
        "music-gen": .init(name: "音乐生成", description: "根据提示生成原创歌曲、歌词、人声或纯音乐。", aliases: ["歌曲", "音频", "作曲"]),
        "music-listener": .init(name: "音乐聆听", description: "分析音乐文件的流派、情绪、速度、歌词或歌曲身份。", aliases: ["音频分析", "歌曲分析"]),
        "notebook": .init(name: "Notebook 编辑", description: "编辑 Jupyter Notebook,支持插入、替换或删除单元格。", aliases: ["ipynb", "Jupyter"]),
        "plan-mode": .init(name: "计划模式", description: "在多步骤任务前进入结构化规划模式,计划完成后退出。", aliases: ["规划", "计划"]),
        "reactions": .init(name: "消息反应", description: "在 Telegram、Discord 和飞书上给消息添加 emoji 反应。", aliases: ["表情", "回应"]),
        "scheduler": .init(name: "定时任务", description: "创建和管理提醒、循环任务、cron 作业和心跳检查。", aliases: ["提醒", "定时", "自动化"]),
        "screenshot": .init(name: "屏幕截图", description: "截取并缩放 macOS 屏幕截图,用于界面调试或查看屏幕。", aliases: ["截图", "屏幕捕获"]),
        "swiftui-hang-diagnose": .init(name: "SwiftUI 卡死诊断", description: "用 sample、spindump 和主线程栈判读诊断原生 SwiftUI/AppKit/UIKit App 卡死、转圈、CPU 跑满等问题。", aliases: ["SwiftUI 卡死", "主线程卡死", "转圈", "彩虹圈", "sample", "spindump", "CPU 100%"]),
        "self-management": .init(name: "自我设置", description: "读取和更新 Alma 的语音、TTS、模型与配置。", aliases: ["设置", "配置"]),
        "self-reflection": .init(name: "自我反思", description: "执行每日反思、提炼经验、更新人格笔记并写日记。", aliases: ["日记", "反思", "成长"]),
        "selfie": .init(name: "自拍", description: "基于私有参考相册创建一致的人像自拍或自画像。", aliases: ["自拍照", "头像", "人像"]),
        "send-file": .init(name: "发送文件", description: "把文件、照片、音频、视频、生成图、文档或截图发送给用户。", aliases: ["发文件", "发送照片"]),
        "skill-hub": .init(name: "技能中心", description: "从 skills.sh 生态搜索、安装和管理 Alma 技能。", aliases: ["技能市场", "安装技能"]),
        "skill-search": .init(name: "技能搜索", description: "当现有能力不足时搜索并安装新的技能。", aliases: ["发现技能", "安装技能"]),
        "system-info": .init(name: "系统信息", description: "查看系统版本、磁盘、内存、进程、网络状态和健康信息。", aliases: ["诊断", "电脑状态"]),
        "tasks": .init(name: "全局任务", description: "跟踪跨线程、跨重启持久保存的多步骤任务。", aliases: ["任务跟踪", "项目任务"]),
        "telegram": .init(name: "Telegram", description: "通过 Telegram Bot API 处理消息、媒体、群管理、反应等操作。", aliases: ["机器人 API", "电报群"]),
        "thread-management": .init(name: "会话管理", description: "创建、列出、切换、删除和搜索聊天会话。", aliases: ["对话管理", "线程"]),
        "todo": .init(name: "待办清单", description: "用工作区 Markdown 文件管理复杂多步骤任务的待办列表。", aliases: ["清单", "任务列表"]),
        "travel": .init(name: "虚拟旅行", description: "进行虚拟旅行、当地探索、旅行日记和人格成长体验。", aliases: ["旅行", "目的地"]),
        "twitter-media": .init(name: "Twitter/X 媒体", description: "从 Twitter/X 链接提取文本、图片、视频和缩略图。", aliases: ["推文", "X 链接", "媒体"]),
        "video-reader": .init(name: "视频理解", description: "用 Gemini 原生视频分析或备用抽帧/转写理解音视频文件。", aliases: ["看视频", "视频分析"]),
        "voice": .init(name: "语音生成", description: "本地生成语音消息和 TTS 音频,支持声音、情绪与速度设置。", aliases: ["文字转语音", "语音回复"]),
        "web-fetch": .init(name: "网页读取", description: "获取并阅读网页、API、在线内容和用户分享的 URL。", aliases: ["链接", "网页"]),
        "web-search": .init(name: "网页搜索", description: "搜索最新信息、做资料研究和事实核查。", aliases: ["搜索引擎", "研究"]),
        "xiaohongshu-cli": .init(name: "小红书 CLI", description: "处理小红书 / Rednote 任务:登录、搜索、读笔记评论、浏览和发布。", aliases: ["小红书", "Rednote", "Little Red Book"])
    ]
}
