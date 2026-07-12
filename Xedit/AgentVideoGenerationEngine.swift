//
//  AgentVideoGenerationEngine.swift
//  WillDeep
//
//  Normalizes video-generation engine choices shared by generic media tools
//  and short-drama tooling. The default stays Seedance 2.0; Kling is exposed as
//  an explicit MCP handoff because the app-side Swift tool runner cannot spend
//  MCP credits by itself.
//

import Foundation

enum AgentVideoGenerationEngine: String, Codable, CaseIterable, Identifiable {
    case seedance
    case kling

    static let defaultEngine: AgentVideoGenerationEngine = .seedance
    static let defaultSeedanceModel = SomeIMIntegrationSettings.defaultVideoModel
    static let defaultKlingTextModel = "kling-video-v3_0_omni"
    static let defaultKlingImageModel = "kling-video-v3_0_turbo"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .seedance:
            return "Seedance 2.0"
        case .kling:
            return "Kling / 可灵"
        }
    }

    var providerLabel: String {
        switch self {
        case .seedance:
            return "some.im / Seedance"
        case .kling:
            return "Kling MCP"
        }
    }

    static func parse(_ raw: String?) -> AgentVideoGenerationEngine {
        guard let raw else { return defaultEngine }
        let token = normalized(raw)
        guard !token.isEmpty else { return defaultEngine }
        switch token {
        case "kling", "可灵", "kling_ai", "klingai", "keling":
            return .kling
        case "seedance", "seedance2", "seedance20", "seedance_2_0", "seedance_2", "some_im", "someim", "some":
            return .seedance
        default:
            if token.contains("kling") || token.contains("可灵") {
                return .kling
            }
            return .seedance
        }
    }

    static func parse(arguments: [String: AgentJSONValue]) -> AgentVideoGenerationEngine {
        parse(
            arguments["video_engine"]?.stringValue()
                ?? arguments["engine"]?.stringValue()
                ?? arguments["provider"]?.stringValue()
        )
    }

    static func defaultModel(for engine: AgentVideoGenerationEngine, hasReferenceImage: Bool) -> String {
        switch engine {
        case .seedance:
            return defaultSeedanceModel
        case .kling:
            return hasReferenceImage ? defaultKlingImageModel : defaultKlingTextModel
        }
    }

    static func allowedValuesDescription() -> String {
        "seedance (default, uses Seedance 2.0 via some.im) or kling/可灵 (uses Kling MCP handoff; default models: text=\(defaultKlingTextModel), image=\(defaultKlingImageModel))."
    }

    private static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }
}
