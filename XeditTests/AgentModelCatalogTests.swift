//
//  AgentModelCatalogTests.swift
//  WillDeepTests
//
//  Locks the built-in model context-window catalog (AppState.agentContextWindow)
//  for the 2026-06 model lineup — Claude 1M flagship line, GPT-5.5, Kimi K2
//  256K, Zhipu GLM-5, Qwen3.7, DeepSeek V4. Values verified against vendor
//  docs; see CHANGELOG 1.108.0-rc33. A dedicated suite so it runs in
//  isolation, unlike the @Test inside the big WillDeepTests suite.
//

import Testing
import Foundation
@testable import WillDeep

@Suite(.serialized)
struct AgentModelCatalogTests {
    @Test("Claude flagship line is 1M, Haiku/older stay 200K")
    func claudeContextWindows() {
        // Opus 4.6+/Sonnet 4.6/Fable 5 ship a 1M window at standard pricing.
        #expect(AppState.agentContextWindow(model: "claude-opus-4-8", providerID: "claude") == 1_000_000)
        #expect(AppState.agentContextWindow(model: "claude-opus-4.7", providerID: "claude") == 1_000_000)
        #expect(AppState.agentContextWindow(model: "claude-opus-4-6", providerID: "claude") == 1_000_000)
        #expect(AppState.agentContextWindow(model: "claude-sonnet-4-6", providerID: "claude") == 1_000_000)
        #expect(AppState.agentContextWindow(model: "claude-fable-5", providerID: "claude") == 1_000_000)
        // Haiku and the older Opus/Sonnet 4.0–4.5 line stay at the classic 200K.
        #expect(AppState.agentContextWindow(model: "claude-haiku-4-5", providerID: "claude") == 200_000)
        #expect(AppState.agentContextWindow(model: "claude-opus-4-1", providerID: "claude") == 200_000)
        #expect(AppState.agentContextWindow(model: "claude-sonnet-4-5", providerID: "claude") == 200_000)
    }

    @Test("GPT-5.5 is ~1M, plain GPT-5 stays 400K")
    func gptContextWindows() {
        #expect(AppState.agentContextWindow(model: "gpt-5.5", providerID: "openai") == 1_050_000)
        #expect(AppState.agentContextWindow(model: "gpt-5.5-pro", providerID: "openai") == 1_050_000)
        #expect(AppState.agentContextWindow(model: "gpt-5", providerID: "openai") == 400_000)
    }

    @Test("Kimi K2 line is 256K")
    func kimiContextWindows() {
        #expect(AppState.agentContextWindow(model: "kimi-k2.7-code", providerID: "kimi") == 262_144)
        #expect(AppState.agentContextWindow(model: "kimi-k2.7-code-highspeed", providerID: "kimi") == 262_144)
        #expect(AppState.agentContextWindow(model: "kimi-k2.6", providerID: "moonshot") == 262_144)
        #expect(AppState.agentContextWindow(model: "kimi-k2.5", providerID: "kimi") == 262_144)
        // Legacy moonshot-v1-128k still resolves via the size suffix.
        #expect(AppState.agentContextWindow(model: "moonshot-v1-128k", providerID: "moonshot") == 128_000)
    }

    @Test("Zhipu GLM-5: 5.2 is 1M, 5/5.1 are 200K, older 128K")
    func glmContextWindows() {
        #expect(AppState.agentContextWindow(model: "glm-5.2", providerID: "zhipu") == 1_000_000)
        #expect(AppState.agentContextWindow(model: "glm-5.1", providerID: "zhipu") == 200_000)
        #expect(AppState.agentContextWindow(model: "glm-5", providerID: "zhipu") == 200_000)
        #expect(AppState.agentContextWindow(model: "glm-4.5", providerID: "zhipu") == 128_000)
    }

    @Test("Qwen3.7 max/plus are 1M, qwen-long stays 1M")
    func qwenContextWindows() {
        #expect(AppState.agentContextWindow(model: "qwen3.7-max", providerID: "dashscope") == 1_000_000)
        #expect(AppState.agentContextWindow(model: "qwen3.7-plus", providerID: "dashscope") == 1_000_000)
        #expect(AppState.agentContextWindow(model: "qwen-long", providerID: "dashscope") == 1_000_000)
        #expect(AppState.agentContextWindow(model: "qwen-plus", providerID: "dashscope") == 128_000)
    }
}
