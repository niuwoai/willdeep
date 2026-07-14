//
//  AgentSkillAutoActivation.swift
//  WillDeep
//
//  Deterministic, low-cost activation for narrowly scoped built-in skills.
//  This keeps obvious workflows from depending on the model first discovering
//  and reading a skill, while respecting the user's disabled-skill settings.
//

import Foundation

nonisolated enum AgentSkillAutoActivation {
    static let figmaSwiftUIIdentifier = "figma-swiftui"
    static let designToCodeIdentifier = "design-to-code"

    static func mergedSkills(
        userText: String,
        workspaceRootPath: String?,
        manuallySelectedSkills: [AgentSkillEntry],
        hasVisualTargetAttachment: Bool = false
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
