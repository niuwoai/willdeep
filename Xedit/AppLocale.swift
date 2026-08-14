//
//  AppLocale.swift
//  WillDeep
//
//  1.85.0-rc16:用户反馈「输出的 memory / skill 要本地化,用户的语言是
//  什么就要用什么形式输出。所以 app 启动时要检测当前的语言并全局共享
//  给 agent」。
//
//  这里把「用户偏好语言」收成一个全局单例,供两个上游消费:
//   1) AgentContextBuilder 往 system prompt 末尾追加一句「Respond in
//      <language> unless the user asks otherwise」—— 让模型输出文字、
//      它调 add_memory / create_user_skill / create_user_skills 时塞进去的 content,以及
//      ask_user 的提问,自然落到用户的母语上。
//   2) 任何未来需要按用户语言走的 UI / 提示文案,都从这里读。
//
//  数据源:`Locale.preferredLanguages.first`(系统偏好的第一档),失败
//  退到 `Locale.current.identifier`。语言显示名走 `Locale.current
//  .localizedString(forIdentifier:)`(用同一份 locale 显示,所以
//  中文 macOS 上 zh-Hans 显示为「简体中文」,英文 macOS 上是
//  "Chinese, Simplified")—— 这样写进 system prompt 时模型一眼能懂。
//

import Foundation

nonisolated enum AppLanguagePreference: String, CaseIterable, Identifiable, Sendable {
    case system
    case simplifiedChinese
    case english
    case japanese
    case spanish
    case french

    var id: String { rawValue }

    var languageTag: String? {
        switch self {
        case .system: return nil
        case .simplifiedChinese: return "zh-Hans"
        case .english: return "en"
        case .japanese: return "ja"
        case .spanish: return "es"
        case .french: return "fr"
        }
    }

    /// 语言自身的名字(而不是当前界面语言下的译名)。切换语言的提示卡片
    /// 用它,这样「已切换为 日本語」在任何界面语言下都指向同一个东西。
    var nativeDisplayName: String {
        switch self {
        case .system: return L10n.Settings.Language.system
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        case .japanese: return "日本語"
        case .spanish: return "Español"
        case .french: return "Français"
        }
    }
}

@MainActor
enum AppLocale {
    static let preferenceKey = "appLanguagePreference"

    static var preference: AppLanguagePreference {
        AppLanguagePreference(
            rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? ""
        ) ?? .system
    }

    /// 本进程启动时生效的语言偏好——也就是当前这套 .lproj 是按什么选的。
    /// 设置页拿它判断「用户点了一圈又点回来」,那种情况不该继续挂着
    /// 「需要重启」的横幅。
    ///
    /// `static let` 首次访问时求值,而 `setPreference` 第一行就强制求它,
    /// 所以它固化的一定是**本进程被改写之前**的值(setPreference 是这个
    /// 偏好唯一的写入点)。
    static let launchPreference: AppLanguagePreference = preference

    static func setPreference(_ preference: AppLanguagePreference) {
        _ = launchPreference
        UserDefaults.standard.set(preference.rawValue, forKey: preferenceKey)
        if let languageTag = preference.languageTag {
            UserDefaults.standard.set([languageTag], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
    }

    nonisolated static func resolvedLanguageTag(
        preference: AppLanguagePreference,
        preferredLanguages: [String],
        localeIdentifier: String
    ) -> String {
        if let languageTag = preference.languageTag {
            return languageTag
        }
        if let preferred = preferredLanguages.first, !preferred.isEmpty {
            return preferred
        }
        return localeIdentifier
    }

    /// `zh-Hans` / `en-US` / `ja-JP` 之类的完整 BCP-47 标签。
    static var languageTag: String {
        resolvedLanguageTag(
            preference: preference,
            preferredLanguages: Locale.preferredLanguages,
            localeIdentifier: Locale.current.identifier
        )
    }

    /// 只取主语言部分(`zh` / `en` / `ja` …),用于粗粒度判断。
    static var languageCode: String {
        let tag = languageTag
        return Locale(identifier: tag).language.languageCode?.identifier ?? tag
    }

    /// 自然语言显示名,塞进 system prompt 时模型一眼能懂(简体中文 /
    /// English / 日本語 …)。优先用 *当前* locale 的本地化结果,这样
    /// 中文用户读 prompt 也能看懂。
    static var displayName: String {
        let tag = languageTag
        if let display = Locale.current.localizedString(forIdentifier: tag), !display.isEmpty {
            return display
        }
        return tag
    }

    /// 给 system prompt 用的一句指令。集中在这里方便统一改文案 / 加
    /// 多语言变体。
    static var systemPromptDirective: String {
        """
        User's preferred language: \(displayName) (\(languageTag)). Reply to the user, write memory entries created via add_memory, generate skill content via create_user_skill or create_user_skills, draft ask_user questions, and produce any other user-facing artifact in this language unless the user explicitly asks for another. If the user's global or project rules specify a reply language, those rules win over this locale default.
        """
    }
}
