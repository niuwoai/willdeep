//
//  CSVAskWorkflow.swift
//  WillDeep
//
//  /csv-ask <path> <natural-language question> — 用 DuckDB 0 配置查
//  本地 CSV / TSV / Parquet / JSONL。schema introspect → 3 angle 并发
//  分析 → synthesize。1.81.0-rc3 引入。
//

import Foundation

struct CSVAskWorkflow: WorkflowDefinition {
    var name: String { "csv-ask" }
    var displayTitle: String { "CSV Ask" }
    var slashCommand: String { "/csv-ask" }
    var shortDescription: String { "Query a local CSV/Parquet via DuckDB and explain the answer" }
    var argsPlaceholder: String { "<path> <natural language question>" }
    var maxAgents: Int { 5 }
    var allowsEmptyArgs: Bool { false }

    func run(engine: WorkflowEngine, args: String) async throws -> String {
        let (path, question) = splitArgs(args)
        guard !path.isEmpty else {
            return "Usage: `/csv-ask <path> <question>`, e.g. `/csv-ask ~/data/sales.csv what week had the most revenue?`"
        }

        // Preflight: 文件存在 + duckdb 装好。
        let target: DatabaseToolingPreflight.Target
        do {
            target = try DatabaseToolingPreflight.parseTarget(path)
            try await DatabaseToolingPreflight.check(target)
        } catch let failure as DatabaseToolingPreflight.Failure {
            return failure.errorDescription ?? "Preflight failed."
        }

        // Phase 1: schema + sample。一个 agent 用 duckdb 内省。
        let schemaPrompt = """
        Profile the data file at `\(path)` using DuckDB. Run these as
        separate `run_command` calls — copy exactly, just substitute the
        path:

        - `duckdb -c "DESCRIBE SELECT * FROM '\(path)' LIMIT 0;"` (column names + types)
        - `duckdb -c "SELECT COUNT(*) AS row_count FROM '\(path)';"`
        - `duckdb -c "SELECT * FROM '\(path)' USING SAMPLE 5 ROWS;"` (5-row sample)

        Output a self-contained markdown brief:
        ## File
        Path, row count, file size (skip if unknown).
        ## Columns
        Markdown table: name | type | example value (from sample) | guess at semantic role
        ## Sample rows
        Inline the 5-row sample as a markdown table.

        DO NOT answer the user's question yet — that's the next phase.
        Just describe what's in the file.
        """
        let schemaDoc = try await engine.agent(schemaPrompt, label: "schema")

        // Phase 2: 3 个 angle agent 并发。每个跑独立查询。
        let angles: [(label: String, prompt: String)] = [
            ("answer", """
            Answer the user's question against the data file at `\(path)`.

            User question: \(question.isEmpty ? "(no specific question — give an interesting summary)" : question)

            Schema and sample (already collected):

            \(schemaDoc)

            Write SQL that DuckDB can run against `'\(path)'` directly
            (DuckDB reads CSV/parquet/json from disk natively). Run it
            via `run_command "duckdb -c \\"<your sql here>\\""`.

            **READ-ONLY**: SELECT / WITH only — no INSERT / UPDATE /
            DELETE / DROP / CREATE TABLE.

            Iterate if needed: refine SQL based on results. Stop after
            at most 4 queries.

            Output:
            ## Question
            Restate succinctly.
            ## SQL used
            ```sql
            <final SQL>
            ```
            ## Result
            Inline as markdown table. If many rows, top 20 with a
            "(N more rows)" footer.
            ## Answer
            1-3 sentences interpreting the result.
            """),
            ("quality", """
            Independently profile **data quality** of `\(path)`. Run
            DuckDB queries against `'\(path)'` directly. Cover at
            minimum:
            - NULL count per column
            - Duplicate row count
            - Min / max / distinct count for each numeric column
            - For string columns: most-frequent value + its share

            Read-only SQL. ≤6 queries total.

            Output a markdown brief:
            ## Nulls
            ## Duplicates
            ## Numeric ranges
            ## Categorical top values
            ## Quality concerns
            (Anything that looks suspicious — high null rate, one value
            dominating, etc.)

            Schema (already known):

            \(schemaDoc)
            """),
            ("distribution", """
            Independently explore **distributions and outliers** in
            `\(path)`. Pick 2-3 of the most interesting numeric columns
            (skip IDs, timestamps) and run DuckDB queries to compute:
            - Percentiles (25 / 50 / 75 / 90 / 99)
            - Outlier count via IQR rule (> Q3 + 1.5·IQR or < Q1 −
              1.5·IQR)
            - Histogram-ish: 10 equal-width buckets and their counts

            For 1-2 categorical columns: top 10 categories + their
            share of total rows.

            Read-only SQL. ≤8 queries total.

            Output a markdown brief:
            ## Numeric profiles
            (one subsection per column)
            ## Categorical profiles
            ## Notable patterns
            (skewed distributions, fat tails, dominant categories,
            obvious outliers)

            Schema:

            \(schemaDoc)
            """),
        ]

        let parts = await engine.parallel(maxConcurrent: 3, angles.map { item in
            { @Sendable in
                try await engine.agent(item.prompt, label: item.label)
            }
        })
        let answerPart = parts[0] ?? "(answer agent failed)"
        let qualityPart = parts[1] ?? "(quality agent failed)"
        let distributionPart = parts[2] ?? "(distribution agent failed)"

        // Phase 3: synthesize.
        let synthesisPrompt = """
        Synthesize a final markdown report combining one direct answer
        and two background profiles. Lead with the answer the user
        actually asked; surface quality / distribution insights only if
        they qualify or expand the answer.

        Output structure:
        # \(question.isEmpty ? "CSV exploration" : question)
        ## TL;DR
        2-3 sentences: the answer + any caveat from the data quality
        check that affects how to read it.
        ## Direct answer
        Copy the SQL, result table, and interpretation verbatim from
        the answer block.
        ## Data quality notes
        Bulletize the most actionable points from the quality block.
        Skip generic findings.
        ## Distribution highlights
        2-3 bullets — only patterns that matter for the question or
        that the user would clearly want to know about.

        Schema reference:

        \(schemaDoc)

        Direct answer block:

        \(answerPart)

        Quality block:

        \(qualityPart)

        Distribution block:

        \(distributionPart)
        """

        return try await engine.agent(synthesisPrompt, label: "synthesize")
    }

    /// 切 args 为 (path, question)。第一个空格之前是 path（不带空格的
    /// 路径），之后是 question。允许用户用引号包路径但 MVP 不解析 ——
    /// 多数 CSV 路径不带空格。
    private func splitArgs(_ raw: String) -> (path: String, question: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let spaceIdx = trimmed.firstIndex(of: " ") else {
            return (trimmed, "")
        }
        let path = String(trimmed[..<spaceIdx])
        let question = String(trimmed[trimmed.index(after: spaceIdx)...])
            .trimmingCharacters(in: .whitespaces)
        return (path, question)
    }
}
