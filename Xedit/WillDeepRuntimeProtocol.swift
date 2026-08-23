//
//  WillDeepRuntimeProtocol.swift
//  WillDeep
//
//  Swift decoders for the willdeep-rs Runtime public API (protocol v1).
//
//  This is step zero of the four-phase plan in willdeep-rs
//  `docs/CLI_TUI_RUNTIME_ROADMAP.md` §1.0: teach the Swift side to *read* the
//  Rust Runtime's public objects, with no transport, no behaviour, and no
//  dependency on a running daemon. Phase 1 (read-only observation of a live
//  Runtime) can build directly on these types.
//
//  Why these live in the app target rather than in the test target: a contract
//  test that exercises test-only structs proves only that the test compiles.
//  These are the decoders a client will actually use, and
//  `WillDeepRuntimeProtocolTests` is what keeps them honest.
//
//  The wire format is *not* ours to invent — it belongs to the Rust crate
//  `willdeep-runtime-protocol`, whose `fixtures/public-api-v1.json` is the
//  published cross-language contract fixture (rs `docs/RUNTIME_CONTROL_API.md`
//  names Swift as an intended consumer). A verbatim copy lives at
//  `XeditTests/Fixtures/willdeep-runtime-public-api-v1.json`; when the protocol
//  moves, refresh that copy first and let the test fail before editing types.
//
//  Every field is spelled out in `CodingKeys` rather than relying on
//  `.convertFromSnakeCase`: the converter would turn `root_agent_id` into
//  `rootAgentId`, which fights the `ID` spelling used everywhere else in this
//  app. Explicit keys also make each struct readable as what it is — a written
//  copy of someone else's contract.
//
//  Decode-only on purpose. Request encoding (`agent.spawn` and friends)
//  belongs to the phase that actually issues calls; adding it now would ship
//  an untested writer.
//

import Foundation

/// Envelope wrapping every public Runtime response: `{status, data, meta}` on
/// success, `{status, error, meta}` on failure. Generic over the payload so a
/// single decoder serves all eleven object classes.
nonisolated struct WillDeepRuntimeEnvelope<Payload: Decodable>: Decodable {
    let status: String
    let data: Payload?
    let error: WillDeepRuntimeError?
    let meta: WillDeepRuntimeMeta?

    var isOK: Bool { status == "ok" }
}

nonisolated struct WillDeepRuntimeError: Decodable {
    let code: String?
    let message: String?
}

nonisolated struct WillDeepRuntimeMeta: Decodable {
    let protocolVersion: String?
    let serverVersion: String?

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case serverVersion = "server_version"
    }
}

/// `runtime.capabilities` — the negotiation payload a client reads before
/// anything else, to learn which object classes and operations the server on
/// the other end actually serves. `limits` stays untyped: it is an open map of
/// server-side caps, and pinning its shape here would make every new limit a
/// Swift-side decode failure.
nonisolated struct WillDeepRuntimeCapabilities: Decodable {
    let protocolVersion: String
    let minClientProtocolVersion: String
    let serverVersion: String
    let objects: [String]
    let capabilities: [String]
    let operations: [String]
    let transports: [String]

    enum CodingKeys: String, CodingKey {
        case objects, capabilities, operations, transports
        case protocolVersion = "protocol_version"
        case minClientProtocolVersion = "min_client_protocol_version"
        case serverVersion = "server_version"
    }
}

nonisolated struct WillDeepRuntimeWorkspace: Decodable {
    let id: String
    let name: String
    let root: String?
    let access: String
    let providerProfile: String?
    let skills: [String]
    let mcpServers: [String]
    let active: Bool
    let createdAt: Int
    let updatedAt: Int

    enum CodingKeys: String, CodingKey {
        case id, name, root, access, skills, active
        case providerProfile = "provider_profile"
        case mcpServers = "mcp_servers"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

nonisolated struct WillDeepRuntimeSession: Decodable {
    let id: String
    let rootAgentID: String
    let workspace: String?
    let profile: String?
    let model: String?
    let status: String
    let activeTurnID: String?
    let createdAt: Int
    let updatedAt: Int

    enum CodingKeys: String, CodingKey {
        case id, workspace, profile, model, status
        case rootAgentID = "root_agent_id"
        case activeTurnID = "active_turn_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// Note what is absent: no prompt, no tool arguments, no workspace path. The
/// public agent object is deliberately narrower than the Runtime's internal
/// record, and this type has nowhere to put those fields even if a future
/// server leaked them.
nonisolated struct WillDeepRuntimeAgent: Decodable {
    let id: String
    let parentID: String?
    let taskID: String?
    let label: String
    let background: Bool
    let workspace: String?
    let rootWorkspace: String?
    let worktreeBranch: String?
    let dedicatedWorktree: Bool
    let profile: String
    let status: String
    let currentTurn: Int
    let currentTool: String?
    let inputTokens: Int
    let outputTokens: Int
    let totalTokens: Int
    let maxTurns: Int?
    let tokenBudget: Int?
    let timeoutSeconds: Int?
    let report: String?
    let createdAt: Int
    let updatedAt: Int
    let completedAt: Int?

    enum CodingKeys: String, CodingKey {
        case id, label, background, workspace, profile, status, report
        case parentID = "parent_id"
        case taskID = "task_id"
        case rootWorkspace = "root_workspace"
        case worktreeBranch = "worktree_branch"
        case dedicatedWorktree = "dedicated_worktree"
        case currentTurn = "current_turn"
        case currentTool = "current_tool"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case totalTokens = "total_tokens"
        case maxTurns = "max_turns"
        case tokenBudget = "token_budget"
        case timeoutSeconds = "timeout_seconds"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case completedAt = "completed_at"
    }
}

nonisolated struct WillDeepRuntimeTurn: Decodable {
    let id: String
    let sessionID: String
    let requestID: String?
    let queueSequence: Int
    let status: String
    let activeTaskID: String?
    let attempts: Int
    let createdAt: Int
    let startedAt: Int?
    let completedAt: Int?

    enum CodingKeys: String, CodingKey {
        case id, status, attempts
        case sessionID = "session_id"
        case requestID = "request_id"
        case queueSequence = "queue_sequence"
        case activeTaskID = "active_task_id"
        case createdAt = "created_at"
        case startedAt = "started_at"
        case completedAt = "completed_at"
    }
}

/// Public tool records carry the tool *name* and lifecycle only — never
/// arguments, output, or workspace paths. That redaction is a server-side
/// guarantee (rs `docs/SUBAGENTS.md`); the shape of this type records it.
nonisolated struct WillDeepRuntimeTool: Decodable {
    let id: String
    let sessionID: String
    let turnID: String?
    let taskID: String?
    let agentID: String
    let name: String
    let status: String
    let startedAtMS: Int
    let completedAtMS: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, status
        case sessionID = "session_id"
        case turnID = "turn_id"
        case taskID = "task_id"
        case agentID = "agent_id"
        case startedAtMS = "started_at_ms"
        case completedAtMS = "completed_at_ms"
    }
}

nonisolated struct WillDeepRuntimeTask: Decodable {
    let id: String
    let sessionID: String
    let turnID: String?
    let agentID: String?
    let eventStartSequence: Int
    let status: String
    let workspace: String?
    let profile: String?
    let createdAt: Int
    let startedAt: Int?
    let completedAt: Int?
    let exitCode: Int?
    let failureDomain: String?

    enum CodingKeys: String, CodingKey {
        case id, status, workspace, profile
        case sessionID = "session_id"
        case turnID = "turn_id"
        case agentID = "agent_id"
        case eventStartSequence = "event_start_sequence"
        case createdAt = "created_at"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case exitCode = "exit_code"
        case failureDomain = "failure_domain"
    }
}

nonisolated struct WillDeepRuntimeApproval: Decodable {
    let id: String
    let taskID: String
    let description: String
    let alwaysAllowAvailable: Bool
    let createdAt: Int

    enum CodingKeys: String, CodingKey {
        case id, description
        case taskID = "task_id"
        case alwaysAllowAvailable = "always_allow_available"
        case createdAt = "created_at"
    }
}

nonisolated struct WillDeepRuntimeQuestion: Decodable {
    let id: String
    let taskID: String
    let question: String
    let options: [String]
    let multiSelect: Bool
    let createdAt: Int

    enum CodingKeys: String, CodingKey {
        case id, question, options
        case taskID = "task_id"
        case multiSelect = "multi_select"
        case createdAt = "created_at"
    }
}

nonisolated struct WillDeepRuntimeArtifact: Decodable {
    let id: String
    let kind: String
    let sessionID: String
    let turnID: String?
    let taskID: String?
    let agentID: String?
    let title: String
    let sourceID: String?
    let itemCount: Int
    let createdAt: Int

    enum CodingKeys: String, CodingKey {
        case id, kind, title
        case sessionID = "session_id"
        case turnID = "turn_id"
        case taskID = "task_id"
        case agentID = "agent_id"
        case sourceID = "source_id"
        case itemCount = "item_count"
        case createdAt = "created_at"
    }
}

/// Events are the resumable stream's unit. `sequence` is monotonic and is the
/// cursor a reattaching client sends back as `after`.
nonisolated struct WillDeepRuntimeEvent: Decodable {
    let sequence: Int
    let timestamp: Int
    let kind: String
    let message: String?
}

// MARK: - Control results

nonisolated struct WillDeepRuntimeAgentCommand: Decodable {
    let id: String
    let taskID: String
    let agentID: String
    let kind: String
    let status: String
    let createdAt: Int

    enum CodingKeys: String, CodingKey {
        case id, kind, status
        case taskID = "task_id"
        case agentID = "agent_id"
        case createdAt = "created_at"
    }
}

nonisolated struct WillDeepRuntimeInteraction: Decodable {
    let id: String
    let taskID: String
    let status: String
    let resolvedAt: Int?

    enum CodingKeys: String, CodingKey {
        case id, status
        case taskID = "task_id"
        case resolvedAt = "resolved_at"
    }
}

nonisolated struct WillDeepRuntimeStatus: Decodable {
    let status: String
    let version: String
    let pid: Int
    let uptimeSeconds: Int
    let eventSequence: Int

    enum CodingKeys: String, CodingKey {
        case status, version, pid
        case uptimeSeconds = "uptime_seconds"
        case eventSequence = "event_sequence"
    }
}

nonisolated struct WillDeepRuntimeObjectMutation: Decodable {
    let id: String
    let status: String
}
