//
//  AgentProviderL10n.swift
//  Xedit
//
//  UI-facing copy for provider kinds and presets, collected in one
//  file so the Settings view stays focused on layout and we have a
//  single grep target when we wire up String Catalog localization
//  later. All strings are Chinese per CLAUDE.md §1 (user-facing copy
//  is 简体中文); structural labels (徽章) stay short.
//

import Foundation

extension AgentProviderKind {
    /// Short label shown in the Preset picker and on each provider
    /// row in the library list. Stays under 12 chars so a row reads
    /// "(OpenAI Chat) DashScope" without truncating the brand name.
    var shortLabel: String {
        switch self {
        case .openAIChat:           return "OpenAI Chat"
        case .openAIResponses:      return "OpenAI Responses"
        case .anthropicMessages:    return "Anthropic"
        case .geminiGenerateContent: return "Gemini"
        }
    }

    /// One-paragraph help text shown in the "协议说明" card above the
    /// Connection group. Tells the user what dialect this preset
    /// speaks and where they can typically find their key.
    var helpText: String {
        switch self {
        case .openAIChat:
            return "使用 OpenAI 兼容协议（`/v1/chat/completions`）。这是覆盖面最广的方言——OpenAI 本家、绝大多数国内厂商（DashScope / DeepSeek / Kimi / Moonshot）和所有常见中转站（OpenRouter / SiliconFlow / AnyRouter / some.im 等）都说这一种。"
        case .openAIResponses:
            return "使用 OpenAI 新版 Responses API（`/v1/responses`）。主要给 o-系列推理模型用，事件流形状与传统 Chat Completions 不同。目前仅 OpenAI 本家和极少数中转站支持。"
        case .anthropicMessages:
            return "使用 Anthropic 原生 Messages API（`/v1/messages`），鉴权头是 `x-api-key` 而不是 `Authorization: Bearer`。需要 Anthropic Console 签发的 API Key（`sk-ant-...`）。"
        case .geminiGenerateContent:
            return "使用 Google AI Studio 的 `streamGenerateContent` 接口。API Key 放在 URL `?key=...` 参数里——这是 Google 官方做法，我们已经做了脱敏，不会出现在错误日志里。"
        }
    }
}

extension AgentProviderPreset {
    /// Where to grab an API key for this preset, shown as a hint
    /// below the API Key field. Empty string → no hint (custom
    /// preset, user knows where their own service lives).
    var apiKeySourceHint: String {
        switch id {
        case "openai":
            return "在 https://platform.openai.com/api-keys 申请。"
        case "openai-responses":
            return "和普通 OpenAI 用同一个 key（sk-...），但模型要选 o-系列推理模型。"
        case "claude":
            return "在 https://console.anthropic.com/settings/keys 申请（`sk-ant-...`）。"
        case "gemini":
            return "在 https://aistudio.google.com/apikey 申请。"
        case "dashscope":
            return "在阿里云百炼控制台获取（`sk-...`）。"
        case "deepseek":
            return "在 https://platform.deepseek.com/api_keys 申请。"
        case "kimi", "moonshot":
            return "在 https://platform.moonshot.cn/console/api-keys 申请。"
        case "openrouter":
            return "在 https://openrouter.ai/keys 申请（`sk-or-...`）。模型 ID 形如 `vendor/model`，例如 `anthropic/claude-sonnet-4.5`。"
        case "siliconflow":
            return "在 https://cloud.siliconflow.cn/account/ak 申请（`sk-...`）。模型 ID 含组织前缀，例如 `Qwen/Qwen2.5-7B-Instruct`。"
        case "anyrouter":
            return "登录 AnyRouter 控制台获取。模型 ID 与 OpenAI / Claude 原版一致。"
        case "some-im":
            return "这是 Rocky 个人中转站，需要 some.im 颁发的 token；如果你不知道这是什么，可以忽略。"
        case AgentProviderPreset.customID:
            return ""
        default:
            return ""
        }
    }

    /// Extra inline notice (one short line) shown under the help
    /// card. Used for relays that auto-stamp identifying headers,
    /// quirky private endpoints, or anything else the user should
    /// know without opening docs.
    var inlineNotice: String? {
        switch id {
        case "openrouter":
            return "本应用会自动附带 `HTTP-Referer: https://willdeep.com` 与 `X-Title: WillDeep` 这两个 header，用于在 OpenRouter 应用榜上署名。无需手动填写。"
        case "some-im":
            return "这是个人中转站，请确认你拥有访问权限再使用。"
        case "gemini":
            return "Gemini 的 base URL 与其他厂商不同（不带 `/v1`），保持默认即可。"
        default:
            return nil
        }
    }
}
