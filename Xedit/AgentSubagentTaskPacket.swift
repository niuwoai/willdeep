//
//  AgentSubagentTaskPacket.swift
//  WillDeep
//
//  The compiled task a worker receives instead of a bare sentence.
//
//  A small model with a 32K window cannot afford to discover its own context:
//  every grep it runs to find the file it was supposed to edit is window it no
//  longer has for the fix. So the parent, which already knows where things are,
//  compiles what it knows into a packet — goal, the relevant files' contents,
//  facts already established, constraints, and the command that decides
//  success — and the worker starts hot.
//
//  See docs/SMALL_MODEL_SKILL_WORKERS_DESIGN.md §3.
//

import Foundation

nonisolated struct AgentSubagentTaskPacket: Equatable, Sendable {
    /// What "done" looks like, in the parent's words.
    var goal: String
    /// Installed skill whose body is inlined into the worker's opening
    /// message. Workers have no business fetching their own instructions —
    /// every fetch round burns the window the fix itself needs — so the
    /// parent names the skill and the dispatcher does the reading.
    var skill: String?
    /// Context the worker may read. Inlined like every other declared file,
    /// but never writable merely by being readable.
    ///
    /// This split exists because the combined field made "let the worker see
    /// this file" and "let the worker change this file" the same request. The
    /// cheapest way to give a worker enough context was to widen its write
    /// authority, which is exactly backwards.
    var readFiles: [String]
    /// The exact set a writing trade may create or edit. When empty, the
    /// legacy `relevantFiles` remains the write set so old packets keep their
    /// original meaning.
    var writeFiles: [String]
    /// Legacy combined read/write set. Kept with its **original** semantics
    /// for packets written against the old schema; new callers should send
    /// `read_files` plus `write_files`.
    var relevantFiles: [String]

    /// Everything inlined into the worker's opening message, de-duplicated
    /// with declaration order preserved.
    var inlineFiles: [String] {
        var seen = Set<String>()
        return (readFiles + writeFiles + relevantFiles).filter { seen.insert($0).inserted }
    }

    /// The paths this packet is asking write authority for.
    var requestedWriteFiles: [String] {
        writeFiles.isEmpty ? relevantFiles : writeFiles
    }
    /// What the parent already established, so the worker does not re-derive
    /// it at its own expense.
    var knownFacts: [String]
    var constraints: [String]
    /// The command whose exit code decides success. Without it a worker's
    /// "done" is just an assertion.
    var verifierCommand: String?
    var maxAttempts: Int

    static let defaultMaxAttempts = 4
    static let maxAttemptsCeiling = 6

    /// Total characters of inlined file content for a 32K-window worker.
    /// Roughly a third of the window: enough for the two or three files a
    /// local fix touches, and hard-capped because the alternative failure —
    /// blowing the window on round one — costs the whole run.
    static let inlineCharacterBudget = 24_000

    init(
        goal: String,
        skill: String? = nil,
        readFiles: [String] = [],
        writeFiles: [String] = [],
        relevantFiles: [String] = [],
        knownFacts: [String] = [],
        constraints: [String] = [],
        verifierCommand: String? = nil,
        maxAttempts: Int = defaultMaxAttempts
    ) {
        self.goal = goal
        self.skill = skill
        self.readFiles = readFiles
        self.writeFiles = writeFiles
        self.relevantFiles = relevantFiles
        self.knownFacts = knownFacts
        self.constraints = constraints
        self.verifierCommand = verifierCommand
        self.maxAttempts = min(max(1, maxAttempts), Self.maxAttemptsCeiling)
    }

    /// Parse the `task` argument of a `spawn_agent` call. Returns nil when the
    /// argument is absent or carries no usable goal — callers then fall back to
    /// the plain prompt, so an older prompt keeps working unchanged.
    static func parse(_ value: AgentJSONValue?) -> AgentSubagentTaskPacket? {
        // The schema declares `task` as a JSON string (the tool parameter
        // vocabulary has no object type), but models routinely send a real
        // object anyway. Accept both rather than lose a whole spawn to a
        // formatting preference.
        guard let fields = AgentJSONValue.objectFields(unwrapping: value) else { return nil }
        let goal = fields["goal"]?.stringValue()?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !goal.isEmpty else { return nil }

        var verifier: String?
        if case .object(let verifierFields)? = fields["verifier"] {
            verifier = verifierFields["command"]?.stringValue()?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let inline = fields["verifier"]?.stringValue() {
            // Tolerate `verifier: "swift test"`: models routinely flatten a
            // one-key object, and rejecting that would cost a whole round.
            verifier = inline.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if verifier?.isEmpty == true { verifier = nil }

        let attempts: Int
        if case .number(let raw)? = fields["max_attempts"] {
            attempts = Int(raw)
        } else {
            attempts = defaultMaxAttempts
        }

        return AgentSubagentTaskPacket(
            goal: goal,
            skill: fields["skill"]?.stringValue()
                .flatMap {
                    let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                },
            readFiles: stringList(fields["read_files"]),
            writeFiles: stringList(fields["write_files"]),
            relevantFiles: stringList(fields["relevant_files"]),
            knownFacts: stringList(fields["known_facts"]),
            constraints: stringList(fields["constraints"]),
            verifierCommand: verifier,
            maxAttempts: attempts
        )
    }

    private static func stringList(_ value: AgentJSONValue?) -> [String] {
        guard case .array(let items)? = value else { return [] }
        return items.compactMap {
            let text = $0.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (text?.isEmpty == false) ? text : nil
        }
    }

    /// The worker's opening user message: the packet rendered, with each
    /// relevant file's contents inlined.
    ///
    /// `readFile` returns nil for anything it cannot read; a missing file is
    /// reported in place rather than silently dropped, because "the file you
    /// named isn't there" is information the worker needs before it starts
    /// inventing one.
    func openingMessage(
        fallbackPrompt: String,
        readFile: (String) -> String?
    ) -> String {
        var sections: [String] = ["## Task\n\(goal)"]

        if let skill = skill?.trimmingCharacters(in: .whitespacesAndNewlines), !skill.isEmpty {
            // Unresolvable skills are named, never silent: a worker that
            // thinks it was handed a procedure must not improvise one.
            if let record = AgentSkillDirectory.list(includeDisabled: false).first(where: {
                $0.identifier == skill || $0.name == skill
            }), let body = AgentSkillDirectory.loadBody(
                for: record,
                maxCharacters: Self.inlineCharacterBudget / 2
            ) {
                sections.append("## Skill: \(record.identifier)\n\(body)")
            } else {
                sections.append(
                    "## Skill: \(skill)\n(unavailable: not installed on this runtime; say so in your report instead of improvising the procedure)"
                )
            }
        }

        if !fallbackPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           fallbackPrompt.trimmingCharacters(in: .whitespacesAndNewlines) != goal {
            sections.append("## Details\n\(fallbackPrompt)")
        }
        if !knownFacts.isEmpty {
            sections.append("## Known facts\n" + knownFacts.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !constraints.isEmpty {
            sections.append(
                "## Constraints (do not violate)\n"
                    + constraints.map { "- \($0)" }.joined(separator: "\n")
            )
        }
        if let verifierCommand {
            sections.append("""
            ## Verifier
            `\(verifierCommand)`
            This command decides whether you succeeded. It will be run for you; \
            you are not done until it exits 0.
            """)
        }
        if let files = inlinedFilesSection(readFile: readFile) {
            sections.append(files)
        }
        return sections.joined(separator: "\n\n")
    }

    private func inlinedFilesSection(readFile: (String) -> String?) -> String? {
        let files = inlineFiles
        guard !files.isEmpty else { return nil }
        var remaining = Self.inlineCharacterBudget
        var blocks: [String] = []

        for path in files {
            guard let contents = readFile(path) else {
                blocks.append("### \(path)\n(could not be read — it may not exist at this path)")
                continue
            }
            if remaining <= 0 {
                blocks.append("### \(path)\n(omitted: inline budget exhausted — read it yourself if you need it)")
                continue
            }
            let slice = String(contents.prefix(remaining))
            remaining -= slice.count
            let truncationNote = slice.count < contents.count
                ? "\n… (truncated at the inline budget — use `read_file` for the rest)"
                : ""
            blocks.append("### \(path)\n```\n\(slice)\n```\(truncationNote)")
        }

        return "## Relevant files\n" + blocks.joined(separator: "\n\n")
    }
}
