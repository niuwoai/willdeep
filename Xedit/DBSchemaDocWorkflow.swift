//
//  DBSchemaDocWorkflow.swift
//  WillDeep
//
//  /db-schema-doc <connection> — 反查数据库 schema，生成 markdown 文档
//  + mermaid ER 图。1 个 picker 选出最重要的 6 张表（如果总表很多），
//  6 个 inspect agent 并发各审一表，1 个 synthesize 出文档。
//  1.81.0-rc3 引入。
//

import Foundation

struct DBSchemaDocWorkflow: WorkflowDefinition {
    var name: String { "db-schema-doc" }
    var displayTitle: String { "DB Schema Doc" }
    var slashCommand: String { "/db-schema-doc" }
    var shortDescription: String { "Reverse-engineer a database into a markdown doc + ER diagram" }
    var argsPlaceholder: String { "<conn-uri>" }
    var maxAgents: Int { 8 }
    var allowsEmptyArgs: Bool { false }

    /// 最多深入文档化多少张表。schema 大时 picker 挑这么多张。
    private let maxTablesToInspect = 6

    func run(engine: WorkflowEngine, args: String) async throws -> String {
        let connection = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !connection.isEmpty else {
            return "Usage: `/db-schema-doc <conn>`, e.g. `/db-schema-doc postgres://user:pass@host/db` or `/db-schema-doc sqlite:///~/data/app.sqlite`."
        }

        let target: DatabaseToolingPreflight.Target
        do {
            target = try DatabaseToolingPreflight.parseTarget(connection)
            try await DatabaseToolingPreflight.check(target)
        } catch let failure as DatabaseToolingPreflight.Failure {
            return failure.errorDescription ?? "Preflight failed."
        }

        let dialect = dialectName(target)
        let cliExample = cliExample(target, connection: connection)

        // Phase 1: picker。让一个 agent 列出所有表 + 挑最重要的 6 张。
        let pickerPrompt = """
        List the tables in this \(dialect) database and pick the
        \(maxTablesToInspect) MOST IMPORTANT ones to document in depth.

        Connect via:
        \(cliExample)

        For the listing, run information_schema / pragma queries to get
        all tables in the default / public schema with their row count.

        Picking heuristics (in priority order):
        1. Tables with many rows (skip empty / sub-100-row tables unless
           they're clearly central, e.g. `users`).
        2. Tables referenced by many foreign keys (lookups, dimensions).
        3. Core domain tables (names like users, orders, products,
           accounts, transactions, posts — typical fact tables).
        4. Skip noise: migration tables, queue tables, audit logs,
           shadow tables ending in `_archive` / `_old`.

        Output:
        ## All tables
        Markdown table: name | rows (approx) | picked?
        ## Picked tables
        Exactly \(maxTablesToInspect) lines, each line a bare table
        name (no commas, no markdown). The synthesizer parses this.

        **READ-ONLY** queries only.
        """
        let pickerOutput = try await engine.agent(pickerPrompt, label: "pick")

        // Parse picked table list out of agent output.
        let pickedTables = extractPickedTables(from: pickerOutput, cap: maxTablesToInspect)
        guard !pickedTables.isEmpty else {
            return "Picker returned no tables. Either the database is empty or it misbehaved. Picker output:\n\n\(pickerOutput)"
        }

        // Phase 2: per-table inspect, in parallel.
        let inspectPrompts = pickedTables.map { table in
            """
            Document table `\(table)` in detail using \(dialect).

            Connect via:
            \(cliExample)

            Collect:
            - All columns: name, type, nullable, default, primary key, unique
            - Foreign keys: which column → which table.column
            - Indexes: name, columns, unique?
            - Approximate row count
            - Three representative sample rows (use `SELECT * … LIMIT 3`)
            - The 1-3 most useful "natural" query patterns for this
              table — e.g. "filter by user_id and order by created_at"

            **READ-ONLY** queries only. ≤6 queries.

            Output a self-contained markdown block:
            ### \(table) (~N rows)
            One-sentence what-it-is description.
            #### Columns
            Markdown table: column | type | nullable | default | pk | fk → ref
            #### Indexes
            (or "(none beyond pk)")
            #### Sample rows
            Inline markdown table.
            #### Typical queries
            Bulleted list, each item: 1-line use case + a fenced SQL
            block that runs against this dialect.
            """
        }
        let inspectResults = await engine.parallel(
            maxConcurrent: maxTablesToInspect,
            inspectPrompts.enumerated().map { idx, prompt in
                { @Sendable in
                    try await engine.agent(prompt, label: "inspect:\(pickedTables[idx])")
                }
            }
        )

        let tableDocs = zip(pickedTables, inspectResults).compactMap { name, doc -> String? in
            doc.map { $0 } ?? "### \(name)\n\n_(inspect agent failed for this table)_"
        }

        // Phase 3: synthesize → final doc with mermaid ER diagram.
        let synthesisPrompt = """
        Assemble a clean markdown reference doc for this database.

        Connection: `\(DatabaseToolingPreflight.maskConnection(connection))` (\(dialect))

        Structure:
        # \(dialect) schema reference

        ## At-a-glance
        Bulleted list of the \(pickedTables.count) documented tables —
        one line each: name + 1-sentence purpose pulled from the per-
        table doc.

        ## Entity relationships
        Mermaid ER diagram in a ```mermaid code block. Use `erDiagram`
        syntax. Include only the documented tables and their FK
        relationships. If you don't have enough FK info, draw what you
        can and note what's missing.

        ## Tables
        Paste each per-table block verbatim.

        ## Full table list (not deep-documented)
        Pull the "All tables" markdown table from the picker output —
        useful for "where do I look up X?" — keep it intact.

        Picker output (for the All-tables table):

        \(pickerOutput)

        Per-table docs (already self-contained markdown):

        \(tableDocs.joined(separator: "\n\n---\n\n"))
        """

        return try await engine.agent(synthesisPrompt, label: "synthesize")
    }

    // MARK: - Helpers

    /// 从 picker agent 输出里抽出 "Picked tables" 段下的纯表名行。
    /// 容忍 LLM 加点 markdown，但只保留看起来是 table name 的（没有
    /// 空格、不以 `|` / `#` 开头）。
    private func extractPickedTables(from text: String, cap: Int) -> [String] {
        guard let range = text.range(of: "## Picked tables", options: .caseInsensitive) else {
            // Fallback: scan whole output for bare-word lines.
            return looksLikeTableLines(in: text, cap: cap)
        }
        let after = text[range.upperBound...]
        return looksLikeTableLines(in: String(after), cap: cap)
    }

    private func looksLikeTableLines(in text: String, cap: Int) -> [String] {
        var out: [String] = []
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty,
                  !line.hasPrefix("#"),
                  !line.hasPrefix("|"),
                  !line.hasPrefix("`"),
                  !line.hasPrefix("-"),
                  !line.contains(" "),
                  line.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-" })
            else { continue }
            out.append(line)
            if out.count >= cap { break }
        }
        return out
    }

    private func dialectName(_ target: DatabaseToolingPreflight.Target) -> String {
        switch target {
        case .postgres: return "PostgreSQL"
        case .mysql: return "MySQL"
        case .sqlite: return "SQLite"
        case .duckdb, .csvOrParquet: return "DuckDB"
        }
    }

    private func cliExample(_ target: DatabaseToolingPreflight.Target, connection: String) -> String {
        let masked = DatabaseToolingPreflight.maskConnection(connection)
        switch target {
        case .postgres:
            return "`psql \"\(connection)\" -c \"<sql>\"` — masked form: `\(masked)`"
        case .mysql:
            return "`mysql --table -e \"<sql>\" <flags>` — pass connection bits from `\(masked)`"
        case .sqlite(let path):
            return "`sqlite3 \"\(path)\" \"<sql>\"`"
        case .duckdb(let path):
            return "`duckdb \"\(path)\" -c \"<sql>\"`"
        case .csvOrParquet:
            return "`duckdb -c \"<sql>\"` (DuckDB reads files directly — no DB to introspect; this workflow may have limited value here)"
        }
    }
}
