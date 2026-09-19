//
//  AgentSkillAutoActivation.swift
//  WillDeep
//
//  Deterministic, low-cost activation for narrowly scoped built-in skills.
//  This keeps obvious workflows from depending on the model first discovering
//  and reading a skill, while respecting the user's disabled-skill settings.
//

import Foundation

nonisolated struct AgentSkillRoutingCandidate: Equatable, Sendable {
    let skill: AgentSkillEntry
    let score: Double
    let matchedTerms: [String]
}

nonisolated struct AgentSkillRoutingDecision: Equatable, Sendable {
    let attachedSkills: [AgentSkillEntry]
    let candidateSkills: [AgentSkillRoutingCandidate]
}

nonisolated enum AgentSkillAutoActivation {
    static let figmaSwiftUIIdentifier = "figma-swiftui"
    static let designToCodeIdentifier = "design-to-code"

    /// Host-side routing stays deterministic only where user intent is
    /// unambiguous: explicit `$skill-name` invocation or a literal skill-name
    /// mention. Every score-based metadata match is demoted to a tiny
    /// `read_skill` hint so the model judges relevance before any body is
    /// loaded. At most one generic skill body is auto-attached, which bounds
    /// prompt growth even when hundreds of installed skills are indexed
    /// locally.
    static func routingDecision(
        userText: String,
        workspaceRootPath: String?,
        manuallySelectedSkills: [AgentSkillEntry],
        hasVisualTargetAttachment: Bool = false,
        availableSkills: [AgentSkillEntry]? = nil
    ) -> AgentSkillRoutingDecision {
        var attached = visualSkills(
            userText: userText,
            workspaceRootPath: workspaceRootPath,
            manuallySelectedSkills: manuallySelectedSkills,
            hasVisualTargetAttachment: hasVisualTargetAttachment
        )
        // An explicit picker choice or the dedicated visual router is already
        // authoritative. Do not surprise the user by stacking a second body;
        // multi-skill requests can still attach several skills explicitly.
        if !attached.isEmpty {
            return AgentSkillRoutingDecision(attachedSkills: attached, candidateSkills: [])
        }
        let excludedIdentifiers = Set(attached.map(\.identifier)).union([
            figmaSwiftUIIdentifier,
            designToCodeIdentifier,
        ])
        let catalog = (availableSkills ?? AgentSkillDirectory.list(includeDisabled: false))
            .filter { !isContaminatedAutoCapturedSkill($0) }
        let generic = AgentSkillRouter.route(
            userText: userText,
            availableSkills: catalog,
            excluding: excludedIdentifiers
        )
        if let automatic = generic.autoAttach,
           !attached.contains(where: { $0.identifier == automatic.identifier }) {
            attached.append(automatic)
        }
        let attachedIdentifiers = Set(attached.map(\.identifier))
        let candidates = generic.candidates.filter {
            !attachedIdentifiers.contains($0.skill.identifier)
        }
        return AgentSkillRoutingDecision(
            attachedSkills: attached,
            candidateSkills: candidates
        )
    }

    /// Self-learning skills captured before 1.238.1 / 1.287.0-rc6 mined host
    /// chrome (the per-turn `<system-reminder>` context, the attachment
    /// prelude) as if the operator had typed it. The files stay on disk —
    /// deleting user skills is the operator's call — but they must not be
    /// offered as routing candidates or auto-attached, which would replay
    /// stale host instructions to the model as skill guidance.
    static func isContaminatedAutoCapturedSkill(_ skill: AgentSkillEntry) -> Bool {
        skill.identifier.hasPrefix("auto-")
            && AgentAttachedPromptProtocol.containsHostChrome(skill.description)
    }

    static func mergedSkills(
        userText: String,
        workspaceRootPath: String?,
        manuallySelectedSkills: [AgentSkillEntry],
        hasVisualTargetAttachment: Bool = false
    ) -> [AgentSkillEntry] {
        routingDecision(
            userText: userText,
            workspaceRootPath: workspaceRootPath,
            manuallySelectedSkills: manuallySelectedSkills,
            hasVisualTargetAttachment: hasVisualTargetAttachment
        ).attachedSkills
    }

    private static func visualSkills(
        userText: String,
        workspaceRootPath: String?,
        manuallySelectedSkills: [AgentSkillEntry],
        hasVisualTargetAttachment: Bool
    ) -> [AgentSkillEntry] {
        var result = manuallySelectedSkills
        let hasManualVisualImplementationSkill = result.contains {
            $0.identifier == figmaSwiftUIIdentifier || $0.identifier == designToCodeIdentifier
        }
        if hasManualVisualImplementationSkill {
            return result
        }

        let normalizedText = userText.lowercased()
        let explicitlyRequestsDesignToCode = normalizedText.contains("$\(designToCodeIdentifier)")
        let workspaceContainsSwiftProject = workspaceRootPath.map(workspaceLooksLikeSwiftProject) ?? false
        let workspaceContainsWebProject = workspaceRootPath.map(workspaceLooksLikeWebProject) ?? false
        let prefersSwiftUI = !explicitlyRequestsDesignToCode && shouldActivateFigmaSwiftUI(
            userText: userText,
            workspaceContainsSwiftProject: workspaceContainsSwiftProject,
            hasVisualTargetAttachment: hasVisualTargetAttachment
        )

        if !result.contains(where: { $0.identifier == figmaSwiftUIIdentifier }),
           prefersSwiftUI,
           let skill = AgentSkillDirectory.bundledSkill(identifier: figmaSwiftUIIdentifier) {
            result.append(skill)
        }

        if !result.contains(where: { $0.identifier == designToCodeIdentifier }),
           shouldActivateDesignToCode(
               userText: userText,
               workspaceContainsWebProject: workspaceContainsWebProject,
               hasVisualTargetAttachment: hasVisualTargetAttachment,
               prefersSwiftUI: prefersSwiftUI
           ),
           let skill = AgentSkillDirectory.bundledSkill(identifier: designToCodeIdentifier) {
            result.append(skill)
        }

        return result
    }

    static func shouldActivateFigmaSwiftUI(
        userText: String,
        workspaceContainsSwiftProject: Bool,
        hasVisualTargetAttachment: Bool = false
    ) -> Bool {
        let text = userText.lowercased()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if text.contains("$\(figmaSwiftUIIdentifier)") { return true }
        if containsAny(
            ["react", "vue", "html", "css", "frontend", "front-end", "web app", "web page", "网页", "网站", "前端"],
            in: text
        ) {
            return false
        }

        let hasFigmaURL = text.contains("figma.com/")
        let hasFigmaContext = hasFigmaURL || hasVisualTargetAttachment || containsAny(
            ["figma", "设计稿", "设计文件"],
            in: text
        )
        let hasSwiftContext = workspaceContainsSwiftProject || containsAny(
            ["swiftui", "swift ui", ".swift", "xcode", "ios", "iphone", "ipad", "macos", "苹果原生"],
            in: text
        )
        let hasTranslationIntent = containsAny(
            [
                "implement", "build", "translate", "convert", "reproduce", "push", "mirror", "sync",
                "实现", "还原", "转换", "转成", "生成", "同步", "推到", "画到", "写进", "做成", "照着", "落地",
            ],
            in: text
        )

        return hasFigmaContext && hasSwiftContext && (hasFigmaURL || hasTranslationIntent)
    }

    static func shouldActivateDesignToCode(
        userText: String,
        workspaceContainsWebProject: Bool,
        hasVisualTargetAttachment: Bool,
        prefersSwiftUI: Bool = false
    ) -> Bool {
        let text = userText.lowercased()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if text.contains("$\(designToCodeIdentifier)") { return true }
        guard !prefersSwiftUI else { return false }

        let hasFigmaURL = text.contains("figma.com/")
        let hasImagePath = containsAny(
            [".png", ".jpg", ".jpeg", ".webp", ".gif", ".heic"],
            in: text
        )
        let hasVisualTarget = hasVisualTargetAttachment || hasFigmaURL || hasImagePath
        let hasImplementationIntent = containsAny(
            [
                "design to code", "image to code", "screenshot to code", "implement", "recreate", "reproduce", "build this", "convert to code", "clone this ui",
                "截图转代码", "设计转代码", "实现这个", "照着实现", "照这个做", "还原页面", "还原界面", "复刻页面", "复刻界面", "转成代码", "写成页面", "做成前端",
            ],
            in: text
        )
        let hasWebContext = workspaceContainsWebProject || containsAny(
            ["react", "vue", "html", "css", "web", "frontend", "front-end", "网页", "网站", "前端"],
            in: text
        )

        return hasVisualTarget && hasImplementationIntent && (hasWebContext || hasVisualTargetAttachment || hasFigmaURL)
    }

    private static func containsAny(_ needles: [String], in text: String) -> Bool {
        needles.contains(where: text.contains)
    }

    private static func workspaceLooksLikeSwiftProject(_ rawPath: String) -> Bool {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty,
              let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return false
        }
        return entries.contains { name in
            name == "Package.swift"
                || name.hasSuffix(".xcodeproj")
                || name.hasSuffix(".xcworkspace")
                || name.hasSuffix(".swift")
        }
    }

    private static func workspaceLooksLikeWebProject(_ rawPath: String) -> Bool {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty,
              let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return false
        }
        return entries.contains { name in
            name == "package.json"
                || name == "index.html"
                || name.hasPrefix("vite.config.")
                || name.hasPrefix("next.config.")
        }
    }
}

/// A deterministic, cached-metadata router for the general skill catalog.
/// It never reads SKILL.md bodies: explicit `$name` invocations and literal
/// skill-name mentions may attach one body through the normal composer path,
/// while every score-based match only gives the model a short `read_skill`
/// candidate list to judge.
nonisolated enum AgentSkillRouter {
    struct Route: Equatable, Sendable {
        let autoAttach: AgentSkillEntry?
        let candidates: [AgentSkillRoutingCandidate]
    }

    private struct ScoredSkill {
        let skill: AgentSkillEntry
        let score: Double
        let matchedTerms: [String]
        let hasExplicitInvocation: Bool
        let hasLiteralNameMatch: Bool
    }

    static let maximumCandidateCount = 3
    static let candidateScoreThreshold = 1.0

    static func route(
        userText: String,
        availableSkills: [AgentSkillEntry],
        excluding excludedIdentifiers: Set<String> = []
    ) -> Route {
        let normalizedText = normalize(userText)
        guard !normalizedText.isEmpty else {
            return Route(autoAttach: nil, candidates: [])
        }
        let skills = availableSkills.filter {
            $0.isEnabled && !excludedIdentifiers.contains($0.identifier)
        }
        guard !skills.isEmpty else {
            return Route(autoAttach: nil, candidates: [])
        }

        let queryTerms = terms(in: normalizedText, includeAliases: true)
        let indexed = skills.map { skill in
            terms(
                in: "\(skill.identifier) \(skill.name) \(skill.description)",
                includeAliases: false
            )
        }
        var documentFrequency: [String: Int] = [:]
        for terms in indexed {
            for term in terms {
                documentFrequency[term, default: 0] += 1
            }
        }

        let scored = zip(skills, indexed).compactMap { skill, skillTerms -> ScoredSkill? in
            let identifier = normalize(skill.identifier)
            let name = normalize(skill.name)
            let explicit = normalizedText.contains("$\(identifier)")
            let literalName = phraseAppears(identifier, in: normalizedText)
                || (name.count >= 4 && phraseAppears(name, in: normalizedText))
            let matched = queryTerms.intersection(skillTerms).sorted()
            var score = matched.reduce(0.0) { partial, term in
                let frequency = Double(documentFrequency[term, default: skills.count])
                let rarity = log((Double(skills.count) + 1.0) / (frequency + 1.0)) + 1.0
                return partial + rarity
            }
            if explicit { score += 100.0 }
            if literalName { score += 12.0 }
            guard score >= candidateScoreThreshold || explicit || literalName else { return nil }
            return ScoredSkill(
                skill: skill,
                score: score,
                matchedTerms: matched,
                hasExplicitInvocation: explicit,
                hasLiteralNameMatch: literalName
            )
        }.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.skill.identifier < rhs.skill.identifier
        }

        guard let first = scored.first else {
            return Route(autoAttach: nil, candidates: [])
        }
        // Score-based auto-attach is intentionally gone (1.287.0-rc6). CJK
        // bigram indexing has no stop list, and IDF rarity is catalog-relative,
        // so everyday words unique to one description look like golden
        // keywords: "没有" + "设计" in a drama skill's description once
        // outscored the whole catalog on a tenant-permission question and
        // attached that skill's full body. Deterministic attach now requires
        // explicit user intent — `$skill-name` or the skill's literal name —
        // and every scored match stays a `read_skill` candidate the model can
        // judge for one cheap tool call.
        let shouldAttach = first.hasExplicitInvocation || first.hasLiteralNameMatch
        let autoAttach = shouldAttach ? first.skill : nil
        let candidates = scored
            .filter { $0.skill.identifier != autoAttach?.identifier }
            .prefix(maximumCandidateCount)
            .map {
                AgentSkillRoutingCandidate(
                    skill: $0.skill,
                    score: $0.score,
                    matchedTerms: $0.matchedTerms
                )
            }
        return Route(autoAttach: autoAttach, candidates: candidates)
    }

    private static func phraseAppears(_ phrase: String, in text: String) -> Bool {
        guard !phrase.isEmpty else { return false }
        if text.contains(phrase) { return true }
        let words = phrase.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return words.count >= 2 && words.allSatisfy { text.contains($0) }
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func terms(in rawText: String, includeAliases: Bool) -> Set<String> {
        let text = normalize(rawText)
        var result = Set<String>()
        var current = ""
        var currentIsCJK: Bool?

        func flush() {
            guard !current.isEmpty else { return }
            if currentIsCJK == true {
                let characters = Array(current)
                if characters.count == 1 {
                    result.insert(current)
                } else {
                    for width in 2...min(4, characters.count) {
                        for start in 0...(characters.count - width) {
                            result.insert(String(characters[start..<(start + width)]))
                        }
                    }
                }
            } else {
                let canonical = canonicalEnglishTerm(current)
                if canonical.count >= 2 && !stopTerms.contains(canonical) {
                    result.insert(canonical)
                }
            }
            current = ""
            currentIsCJK = nil
        }

        for scalar in text.unicodeScalars {
            let isCJK = isCJKScalar(scalar)
            let isWord = CharacterSet.alphanumerics.contains(scalar) || isCJK
            guard isWord else {
                flush()
                continue
            }
            if let currentIsCJK, currentIsCJK != isCJK {
                flush()
            }
            currentIsCJK = isCJK
            current.unicodeScalars.append(scalar)
        }
        flush()

        if includeAliases {
            for (phrase, aliases) in queryAliases where text.contains(phrase) {
                result.formUnion(aliases)
            }
        }
        return result
    }

    private static func canonicalEnglishTerm(_ term: String) -> String {
        switch term {
        case "macos", "osx": return "mac"
        case "images", "pictures", "photos": return "image"
        case "videos": return "video"
        case "websites", "pages": return "web"
        case "schedules", "scheduled", "scheduling": return "schedule"
        case "releases", "released", "releasing": return "release"
        default: return term
        }
    }

    private static func isCJKScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }

    private static let stopTerms: Set<String> = [
        "about", "after", "also", "and", "any", "app", "asks", "available", "built", "can",
        "current", "exact", "for", "from", "into", "local", "only", "other", "otherwise",
        "should", "skill", "supported", "task", "that", "the", "their", "then", "this", "through",
        "tool", "tools", "use", "user", "when", "where", "willdeep", "with",
    ]

    private static let queryAliases: [String: Set<String>] = [
        "发布": ["release", "deploy", "publish"],
        "发版": ["release", "deploy"],
        "部署": ["deploy"],
        "签名": ["signing", "codesign"],
        "公证": ["notarization", "notarize"],
        "系统": ["system"],
        "磁盘": ["disk"],
        "内存": ["memory"],
        "进程": ["process"],
        "网络": ["network"],
        "浏览器": ["browser"],
        "网页": ["web"],
        "网站": ["web"],
        "截图": ["screenshot"],
        "图片": ["image"],
        "图像": ["image"],
        "视频": ["video"],
        "音乐": ["music"],
        "歌曲": ["music"],
        "音频": ["audio"],
        "语音": ["voice", "speech"],
        "朗读": ["voice", "speech"],
        "旅行": ["travel", "trip"],
        "行程": ["itinerary", "travel"],
        "酒店": ["hotel", "travel"],
        "记住": ["remember", "memory"],
        "定时": ["schedule"],
        "提醒": ["reminder", "schedule"],
        "小红书": ["xiaohongshu", "rednote"],
        "待办": ["todo"],
        "复盘": ["reflection", "retrospective"],
        "日报": ["daily", "report"],
        "周报": ["weekly", "report"],
        "今天做了什么": ["daily", "report"],
    ]
}
