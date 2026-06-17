//
//  DBExploreWorkflow.swift
//  WillDeep
//
//  /db-explore <connection> <natural-language question> — 接 Postgres /
//  MySQL / SQLite / DuckDB。schema introspect → 写 SQL 跑 → 解读。所有
//  查询都被强制 read-only。1.81.0-rc3 引入。
//

import Foundation

struct DBExploreWorkflow: WorkflowDefinition {
    var name: String { "db-explore" }
    var displayTitle: String { "DB Explore" }
    var slashCommand: String { "/db-explore" }
    var shortDescription: String { "Run a natural-language question against a SQL database (read-only)" }
    var argsPlaceholder: String { "<conn-uri> <question>" }
    var maxAgents: Int { 5 }
    var allowsEmptyArgs: Bool { false }

    func run(engine: WorkflowEngine, args: String) async throws -> String {
        let (connection, question) = splitArgs(args)
        guard !connection.isEmpty else {
            return "Usage: `/db-explore <conn> <question>`. Examples:\n- `/db-explore postgres://user:pass@host/db how many users signed up last week?`\n- `/db-explore sqlite:///~/data/app.sqlite which products have zero stock?`\n\n**Tip**: to keep passwords out of the workflow card, use environment variables (`$DATABASE_URL`) or a `~/.pgpass` file."
        }

        // Preflight：解析 target + 检测对应 CLI。
        let target: DatabaseToolingPreflight.Target
        do {
            target = try DatabaseToolingPreflight.parseTarget(connection)
            try DatabaseToolingPreflight.check(target)
        } catch let failure as DatabaseToolingPreflight.Failure {
            return failure.errorDescription ?? "Preflight failed."
        }

        let dialect = dialectName(target)
        let cliInvocation = cliInvocationHint(target, connection: connection)

        // Phase 1: schema introspect。
        let schemaPrompt = """
        Introspect the schema of this \(dialect) database.

        Connect using this exact CLI form (substitute the actual SQL into
        the `-c` arg / pipe / heredoc as needed):
        \(cliInvocation)

        Run information_schema / pragma queries to list:
        - Tables in the public/default schema (cap at ~50)
        - For each table: rough row count (use COUNT(*) or table stats)
        - Column names + types for the 8-12 tables most likely relevant
          to the user's question

        User's question (for picking which tables matter):
        \(question.isEmpty ? "(no specific question — sketch the overall data model)" : question)

        **READ-ONLY**: SELECT / SHOW / PRAGMA / EXPLAIN only.

        Output a markdown brief:
        ## Tables
        | name | rows (approx) | likely relevant to question? |
        ## Detailed columns (relevant tables only)
        Per-table block with column name | type | nullable | notes.

        Do not answer the user's question yet.
        """
        let schemaDoc = try await engine.agent(schemaPrompt, label: "schema")

        // Phase 2: 3 个并发 angle agent。
        let angles: [(label: String, prompt: String)] = [
            ("answer", """
            Answer the user's question against the \(dialect) database.

            User question: \(question.isEmpty ? "(no specific question — give one interesting headline number with context)" : question)

            Schema (already collected):

            \(schemaDoc)

            CLI form:
            \(cliInvocation)

            **HARD RULE — READ-ONLY**: only SELECT / WITH / EXPLAIN.
            Never INSERT / UPDATE / DELETE / DROP / CREATE / ALTER /
            TRUNCATE / GRANT / REVOKE. If the user's question would
            require writes, refuse and say so.

            Iterate at most 4 queries.

            Output:
            ## Question
            ## SQL used
            ```sql
            ```
            ## Result
            Markdown table. ≤20 rows; if more, say so.
            ## Answer
            1-3 sentences interpreting the result.
            """),
            ("sanity", """
            Independently sanity-check the same database for issues that
            could distort the answer to the user's question. Run ≤4
            read-only queries to spot-check:
            - Time coverage: what's the earliest / latest record in the
              most important date column you can identify? Any obvious
              gaps?
            - Duplicate keys in tables that should have unique IDs?
            - Tables with a huge skew (one segment dominates everything)?

            CLI form:
            \(cliInvocation)

            Schema:

            \(schemaDoc)

            Output:
            ## What I checked
            Bullet list of the 4 spot-checks.
            ## What I found
            Bullet list of concrete issues (or "no concerns").
            ## How this affects the user's question
            1-2 sentences, only if relevant.

            **READ-ONLY** queries only.
            """),
            ("alternatives", """
            The user asked: \(question.isEmpty ? "(no specific question)" : question).

            Without running queries (this is a meta-suggestion step),
            propose 3-5 **alternative slices** of the question that would
            give complementary insight — e.g. by time, segment, cohort,
            or comparing to a baseline. For each:
            - 1-line description of the angle
            - The exact SELECT statement you'd run (don't run it now,
              just write it — the synthesizer may use it)

            Schema:

            \(schemaDoc)

            Output a markdown list. Keep SQL valid for \(dialect).
            """),
        ]

        let parts = await engine.parallel(maxConcurrent: 3, angles.map { item in
            { @Sendable in
                try await engine.agent(item.prompt, label: item.label)
            }
        })
        let answerPart = parts[0] ?? "(answer agent failed)"
        let sanityPart = parts[1] ?? "(sanity agent failed)"
        let altsPart = parts[2] ?? "(alternatives agent failed)"

        // Phase 3: synthesize。
        let synthesisPrompt = """
        Compose the final report. Lead with the user's answer, weave in
        sanity-check caveats, end with suggested follow-ups.

        Output structure:
        # \(question.isEmpty ? "Database exploration" : question)

        ## TL;DR
        2-3 sentences: the answer + the most important caveat from the
        sanity check.

        ## Answer
        Paste the SQL block, result table, and interpretation from the
        answer phase verbatim.

        ## Caveats
        Only the concrete sanity issues that matter for this answer.
        Skip "everything looked fine" boilerplate.

        ## What to look at next
        Pick the 2-3 strongest alternatives from the alternatives list,
        each one sentence + its suggested SQL in a fenced block.

        Connection summary: \(DatabaseToolingPreflight.maskConnection(connection)) (\(dialect))

        Schema brief:

        \(schemaDoc)

        Answer block:

        \(answerPart)

        Sanity block:

        \(sanityPart)

        Alternatives block:

        \(altsPart)
        """

        return try await engine.agent(synthesisPrompt, label: "synthesize")
    }

    // MARK: - Helpers

    private func splitArgs(_ raw: String) -> (connection: String, question: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let spaceIdx = trimmed.firstIndex(of: " ") else {
            return (trimmed, "")
        }
        let conn = String(trimmed[..<spaceIdx])
        let question = String(trimmed[trimmed.index(after: spaceIdx)...])
            .trimmingCharacters(in: .whitespaces)
        return (conn, question)
    }

    private func dialectName(_ target: DatabaseToolingPreflight.Target) -> String {
        switch target {
        case .postgres: return "PostgreSQL"
        case .mysql: return "MySQL"
        case .sqlite: return "SQLite"
        case .duckdb, .csvOrParquet: return "DuckDB"
        }
    }

    /// 给 sub-agent 的 CLI invocation 提示：用什么命令打开连接。包含
    /// 提示用户参考 `~/.pgpass` / 环境变量保管密码，不直接 echo 它。
    private func cliInvocationHint(
        _ target: DatabaseToolingPreflight.Target,
        connection: String
    ) -> String {
        let masked = DatabaseToolingPreflight.maskConnection(connection)
        switch target {
        case .postgres:
            return """
            ```
            psql "\(connection)" -c "<your SQL here>"
            ```
            (Card display shows the masked form `\(masked)`. If the
            connection embeds a password, consider re-running with
            `$DATABASE_URL` shell-expanded instead so secrets don't
            leak into the transcript.)
            """
        case .mysql:
            return """
            ```
            mysql --table -e "<your SQL here>" <connection-flags>
            ```
            For the URI `\(masked)`, expand manually into
            `-h host -u user -p<pass> dbname`. Prefer
            `~/.my.cnf` or `MYSQL_PWD` env to keep passwords off CLI.
            """
        case .sqlite(let path):
            return """
            ```
            sqlite3 "\(path)" "<your SQL here>"
            ```
            """
        case .duckdb(let path):
            return """
            ```
            duckdb "\(path)" -c "<your SQL here>"
            ```
            """
        case .csvOrParquet(let path):
            return """
            ```
            duckdb -c "<your SQL using FROM '\(path)'>"
            ```
            (DuckDB reads CSV / parquet / JSON directly from disk — no
            need to import.)
            """
        }
    }
}
