//
//  AgentSpecGateState.swift
//  WillDeep
//
//  The gate's state across a turn boundary, and the proposal card's payload.
//
//  Both enums here hand-roll `init(from:)`. That is not defensive habit: a
//  synthesized Codable throws on an unrecognised raw value, and a session that
//  throws while decoding does not degrade — it vanishes from the sidebar. An
//  older build reading a state it has never heard of has to see `inactive`,
//  not lose the conversation. Same reasoning as AgentApprovalMode.
//

import Foundation

/// Where this session stands with respect to the design gate.
///
/// Session-scoped rather than per-turn: the whole point is that the decision
/// outlives the turn that made it. The user may quit the app between "write
/// the document" and "yes, go ahead".
enum AgentSpecGateState: String, Codable, Sendable, Equatable {
    /// No gate in play. The overwhelmingly common value.
    case inactive
    /// Gated. The model should be writing a design document and nothing else.
    case awaitingDocument
    /// A document exists and the user has not answered yet. Write tools stay locked.
    case awaitingUserReview
    /// The user answered. This session never gates again — one decision per
    /// conversation, because re-asking after someone already said "go" is how
    /// a helpful gate becomes a nag.
    case released

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentSpecGateState(rawValue: raw) ?? .inactive
    }

    /// Whether write-tier tools are blocked right now.
    var blocksExecution: Bool {
        switch self {
        case .awaitingDocument, .awaitingUserReview:
            return true
        case .inactive, .released:
            return false
        }
    }

    /// The instruction appended to this turn's prompt while the gate is up.
    ///
    /// Lives here rather than in AgentContextBuilder for two reasons. It is
    /// appended after the dynamic-context marker, so it never enters the
    /// cached stable prefix and none of the three profile snapshot hashes
    /// move. And AgentContextBuilder is already near the 2000-line soft limit
    /// the complexity guard warns at.
    var systemPromptBlock: String? {
        switch self {
        case .inactive, .released:
            return nil
        case .awaitingDocument:
            return """
            === DESIGN GATE — WRITE THE DESIGN FIRST ===
            This request was gated for a written design before implementation. \
            Write-tier and destructive tools are blocked until the operator approves; \
            file tools are not, so you can create the document normally.

            Do exactly this, in order:
            1. Investigate the current state first. Read the relevant code and search \
            `docs/` for an existing design covering this area. If one exists, revise \
            that document instead of starting a competing one.
            2. Write a single Markdown document under `docs/`, named in \
            SCREAMING_SNAKE_CASE (for example `docs/FOO_DESIGN.md`). Ground the current \
            state in real code anchors — `file:line` — not recollection.
            3. Cover: what problem this solves, how it will work, what you are \
            deliberately not doing, what could break, and how it will be verified. \
            State anything still undecided explicitly rather than writing around it.
            4. Stop. Say which file you wrote and summarise the approach in a few lines.

            Do not begin implementing. Do not ask for approval — the operator is shown \
            a card with the document and decides there. Do not repeat this instruction \
            back to the user.
            """
        case .awaitingUserReview:
            return """
            === DESIGN GATE — AWAITING OPERATOR REVIEW ===
            A design document has been written and the operator has not answered yet. \
            Write-tier and destructive tools remain blocked. Do not implement, do not \
            re-write the document unless asked, and do not ask for approval; the \
            operator answers on the card. Revise the document if they request changes.
            """
        }
    }
}

/// What the user acted on, kept so the audit log can answer the only question
/// that matters for shipping this: how often were we wrong.
enum AgentSpecProposalChoice: String, Codable, Sendable, Equatable {
    /// Read the document, went ahead with it.
    case accepted
    /// Skipped the document and told the agent to just do the work. This is
    /// the false-positive signal.
    case dismissed
    /// Wants to edit the document first; the card stays.
    case deferred

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentSpecProposalChoice(rawValue: raw) ?? .deferred
    }
}

/// The card's payload. Persisted with the session so the proposal survives a
/// relaunch — a gate that forgets what it was waiting for after a restart
/// would strand the conversation with its write tools locked.
struct AgentSpecProposal: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    /// Workspace-relative path, e.g. `docs/FOO_DESIGN.md`. Relative because
    /// it is displayed, and because an absolute path from another machine is
    /// meaningless after a session moves.
    var documentPath: String
    /// Why the host thought this needed a design. Rendered on the card
    /// verbatim: the user is entitled to see the reasoning, not a verdict.
    var signals: [AgentSpecGateSignal]
    var createdAt: Date
    var choice: AgentSpecProposalChoice?

    init(
        id: UUID = UUID(),
        documentPath: String,
        signals: [AgentSpecGateSignal],
        createdAt: Date = Date(),
        choice: AgentSpecProposalChoice? = nil
    ) {
        self.id = id
        self.documentPath = documentPath
        self.signals = signals
        self.createdAt = createdAt
        self.choice = choice
    }

    /// Still waiting on the user.
    var isPending: Bool { choice == nil || choice == .deferred }
}

nonisolated enum AgentSpecGateDocument {
    /// Where a gated design document is allowed to land.
    static let directoryName = "docs"

    /// Whether a written path counts as the design document this gate asked
    /// for. Deliberately a rule rather than a filename whitelist: the model
    /// names the file, the host only checks it landed somewhere sane. See
    /// docs/SPEC_FIRST_GATE_DESIGN.md §16 decision 3.
    ///
    /// `path` is workspace-relative with forward slashes.
    static func qualifies(path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count == 2 else { return false }
        guard components[0] == directoryName else { return false }
        let name = String(components[1])
        guard name.hasSuffix(".md") else { return false }
        let stem = String(name.dropLast(3))
        guard !stem.isEmpty else { return false }
        // SCREAMING_SNAKE_CASE, matching every other document in docs/. A
        // model that writes `docs/notes.md` has not written the artefact this
        // gate is holding the turn for.
        return stem.allSatisfy { $0.isUppercase || $0.isNumber || $0 == "_" }
    }
}
