//
//  AgentContextBuilder.swift
//  VeilWriter
//
//  Builds compact project context for first-phase agent chat.
//

import Foundation

enum AgentContextBuilder {
    private static let maxCurrentFileCharacters = 12_000
    private static let maxSelectionCharacters = 6_000
    private static let maxRulesCharacters = 6_000

    static func systemPrompt(
        rootDirectory: URL?,
        openedFileURL: URL?,
        fileContent: String,
        selectedText: String,
        language: Language?,
        toolsEnabled: Bool = false
    ) -> String {
        var sections: [String] = []
        sections.append("""
        You are VeilWriter Agent, a concise coding assistant embedded in a native macOS editor.
        Work with the currently opened project directory as the workspace.
        You cannot directly change files. When the user asks for code edits, provide a unified diff in a ```diff fenced block.
        Only generate diffs for existing files in the workspace, using paths relative to the workspace root.
        Avoid new files, deleted files, binary files, and paths outside the workspace unless the user explicitly asks and the app supports that workflow.
        Keep answers practical and scoped to the visible project context.
        """)

        if toolsEnabled {
            sections.append("""
            Tools:
            - You can call tools to look around the workspace before answering: search_files, grep_files, read_file, list_directory, git_status, run_command.
            - You can discover Codex skills with list_skills and read a selected skill's SKILL.md with read_skill. Use skills when the user's task matches a specialized workflow.
            - You can inspect configured MCP servers with list_mcp_servers, inspect a server's tools with list_mcp_tools, and call a configured MCP tool with call_mcp_tool. MCP tool calls may require approval.
            - Prefer the read-only tools first. They run automatically. Simple read-only run_command calls such as `cd subdir && git diff`, `ls`, `cat`, `rg`, and `grep` can also run automatically after conservative parsing. Other run_command calls require user approval; destructive commands additionally need typed confirmation.
            - When something a user asked for is ambiguous or you're missing a required piece of information, call ask_user with a single concrete question instead of guessing. Do NOT call ask_user for things you can determine by reading files yourself. If the answer is one of a small known set, pass `options` so the user can click; set `multi_select` to true only when more than one option can legitimately apply at once.
            - Use workspace-relative paths in tool arguments.
            - After gathering enough context, stop calling tools and answer the user. For edits, still emit a ```diff block.
            """)
        }

        if let rootDirectory {
            sections.append("""
            Workspace:
            - Root: \(rootDirectory.path)
            - Name: \(rootDirectory.lastPathComponent)
            """)

            if let rules = projectRules(in: rootDirectory) {
                sections.append("""
                Project instructions:
                \(rules)
                """)
            }
        } else {
            sections.append("Workspace: no folder is currently open.")
        }

        if let openedFileURL {
            sections.append("""
            Active file:
            - Path: \(relativePath(for: openedFileURL, rootDirectory: rootDirectory))
            - Language: \(language?.displayName ?? "Plain Text")
            """)
        } else {
            sections.append("Active file: none.")
        }

        let trimmedSelection = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSelection.isEmpty {
            sections.append("""
            Current selection:
            ```text
            \(limit(trimmedSelection, to: maxSelectionCharacters))
            ```
            """)
        }

        let trimmedContent = fileContent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedContent.isEmpty {
            sections.append("""
            Current file content excerpt:
            ```text
            \(limit(trimmedContent, to: maxCurrentFileCharacters))
            ```
            """)
        }

        return sections.joined(separator: "\n\n")
    }

    private static func projectRules(in rootDirectory: URL) -> String? {
        let candidates = ["AGENTS.md", "CLAUDE.md", "README.md", "product-overview.md"]
        var collected: [String] = []

        for name in candidates {
            let url = rootDirectory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else {
                continue
            }

            let excerpt = limit(text.trimmingCharacters(in: .whitespacesAndNewlines), to: maxRulesCharacters)
            guard !excerpt.isEmpty else { continue }
            collected.append("# \(name)\n\(excerpt)")
        }

        guard !collected.isEmpty else { return nil }
        return collected.joined(separator: "\n\n")
    }

    private static func relativePath(for url: URL, rootDirectory: URL?) -> String {
        guard let rootDirectory else { return url.path }
        let rootPath = rootDirectory.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else { return filePath }
        let relative = String(filePath.dropFirst(rootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relative.isEmpty ? url.lastPathComponent : relative
    }

    private static func limit(_ text: String, to maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        let index = text.index(text.startIndex, offsetBy: maxCharacters)
        return "\(text[..<index])\n\n[truncated]"
    }
}
