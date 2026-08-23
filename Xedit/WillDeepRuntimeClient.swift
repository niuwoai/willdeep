//
//  WillDeepRuntimeClient.swift
//  WillDeep
//
//  Read-only observation of a running willdeep-rs Runtime — phase 1 of the
//  four-phase plan in rs `docs/CLI_TUI_RUNTIME_ROADMAP.md` §1.0.
//
//  ## Read-only is enforced here, not just intended
//
//  The Runtime serves 54 operations, many of which submit turns, spawn agents,
//  resolve approvals or delete sessions. This phase observes; it does not act.
//  That distinction is worth a mechanism rather than a comment, because the
//  cost of getting it wrong is asymmetric: a missing read is a blank panel, a
//  stray write is someone's session deleted from an app that was only supposed
//  to be looking. `send` refuses any operation outside `readOnlyOperations`,
//  so reaching a mutating operation takes a deliberate edit to that list and
//  the test that pins it.
//
//  The app is also not the owner of this Runtime — the CLI is. Two clients
//  observing is fine; two clients driving needs the ownership question
//  answered first, and phase 1 is not where that gets decided.
//

import Foundation

nonisolated struct WillDeepRuntimeSnapshot {
    let connection: WillDeepRuntimeConnection
    let capabilities: WillDeepRuntimeCapabilities
    let workspaces: [WillDeepRuntimeWorkspace]
    let sessions: [WillDeepRuntimeSession]
    let agents: [WillDeepRuntimeAgent]
}

nonisolated enum WillDeepRuntimeClient {
    /// Every operation this phase may issue. Deliberately a literal list: an
    /// allowlist that derived itself from a naming rule ("anything ending in
    /// .list") would quietly admit the next read-shaped operation that turns
    /// out to have side effects.
    static let readOnlyOperations: Set<String> = [
        "runtime.capabilities",
        "runtime.status",
        "workspace.list",
        "session.list",
        "agent.list",
        "agent.get",
        "turn.list",
        "tool.list",
        "task.list",
        "approval.list",
        "question.list",
        "artifact.list",
        "event.list",
    ]

    static func isAvailable() -> Bool {
        WillDeepRuntimeDiscovery.connection() != nil
    }

    /// Issue one read-only operation and decode its envelope.
    ///
    /// Errors are surfaced, never swallowed into an empty result: "the Runtime
    /// said no" and "the Runtime has nothing" look identical in a UI that
    /// collapses them, and the first one is a bug worth seeing.
    static func send<Payload: Decodable>(
        _ operation: String,
        params: [String: Any] = [:],
        as payload: Payload.Type,
        connection: WillDeepRuntimeConnection
    ) throws -> Payload {
        guard readOnlyOperations.contains(operation) else {
            throw WillDeepRuntimeTransportError.api(
                code: "forbidden",
                message: "\(operation) is not a read-only operation; this client only observes"
            )
        }
        let data = try WillDeepRuntimeTransport.send(
            operation: operation, params: params, connection: connection
        )
        let envelope = try decodeEnvelope(data, as: Payload.self)
        guard envelope.isOK else {
            throw WillDeepRuntimeTransportError.api(
                code: envelope.error?.code ?? "unknown",
                message: envelope.error?.message ?? "the Runtime reported an error"
            )
        }
        guard let value = envelope.data else {
            throw WillDeepRuntimeTransportError.malformedResponse(
                "\(operation) returned no data"
            )
        }
        return value
    }

    static func decodeEnvelope<Payload: Decodable>(
        _ data: Data,
        as payload: Payload.Type
    ) throws -> WillDeepRuntimeEnvelope<Payload> {
        do {
            return try JSONDecoder().decode(WillDeepRuntimeEnvelope<Payload>.self, from: data)
        } catch {
            // An error envelope decodes even when the success payload does
            // not, and its message is what the operator actually needs.
            if let failure = try? JSONDecoder().decode(
                WillDeepRuntimeEnvelope<EmptyPayload>.self, from: data
            ), let apiError = failure.error {
                throw WillDeepRuntimeTransportError.api(
                    code: apiError.code ?? "unknown",
                    message: apiError.message ?? "the Runtime reported an error"
                )
            }
            throw WillDeepRuntimeTransportError.malformedResponse(String(describing: error))
        }
    }

    nonisolated struct EmptyPayload: Decodable {}

    // MARK: Convenience reads

    static func capabilities(
        connection: WillDeepRuntimeConnection
    ) throws -> WillDeepRuntimeCapabilities {
        try send("runtime.capabilities", as: WillDeepRuntimeCapabilities.self, connection: connection)
    }

    static func status(connection: WillDeepRuntimeConnection) throws -> WillDeepRuntimeStatus {
        try send("runtime.status", as: WillDeepRuntimeStatus.self, connection: connection)
    }

    static func workspaces(
        connection: WillDeepRuntimeConnection
    ) throws -> [WillDeepRuntimeWorkspace] {
        try send("workspace.list", as: [WillDeepRuntimeWorkspace].self, connection: connection)
    }

    static func sessions(
        connection: WillDeepRuntimeConnection
    ) throws -> [WillDeepRuntimeSession] {
        try send("session.list", as: [WillDeepRuntimeSession].self, connection: connection)
    }

    static func agents(connection: WillDeepRuntimeConnection) throws -> [WillDeepRuntimeAgent] {
        try send("agent.list", as: [WillDeepRuntimeAgent].self, connection: connection)
    }

    static func tasks(connection: WillDeepRuntimeConnection) throws -> [WillDeepRuntimeTask] {
        try send("task.list", as: [WillDeepRuntimeTask].self, connection: connection)
    }

    /// One round of everything the observation surface needs. Kept sequential
    /// on purpose: this runs against a daemon that is usually busy doing the
    /// user's actual work, and four cheap calls in order cost less than the
    /// contention of racing them.
    static func snapshot(
        connection: WillDeepRuntimeConnection? = WillDeepRuntimeDiscovery.connection()
    ) throws -> WillDeepRuntimeSnapshot {
        guard let connection else { throw WillDeepRuntimeTransportError.noRuntime }
        return WillDeepRuntimeSnapshot(
            connection: connection,
            capabilities: try capabilities(connection: connection),
            workspaces: try workspaces(connection: connection),
            sessions: try sessions(connection: connection),
            agents: try agents(connection: connection)
        )
    }
}
