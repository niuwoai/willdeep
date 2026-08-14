//
//  AgentToolsFileEditing.swift
//  WillDeep
//
//  AgentToolRunner 的文件写入类工具：create_file、edit_file、apply_patch
//  与 generate_image 的落盘分支。自 AgentTools.swift 拆出，行为不变。
//

import Foundation

extension AgentToolRunner {
    // MARK: create_file

    /// Build the unified creation diff that `apply_patch` already knows how to
    /// parse and apply. Splitting on "\n" and prefixing each line with `+`
    /// round-trips exactly through `AgentPatchApplier.apply` (which, for a new
    /// file, joins the added lines back with "\n"), so the file lands byte-for
    /// -byte equal to `content`. Empty content → a single empty added line →
    /// an empty file.
    static func makeCreationDiff(path: String, content: String) -> String {
        let lines = content.components(separatedBy: "\n")
        let body = lines.map { "+\($0)" }.joined(separator: "\n")
        let header = "--- /dev/null\n+++ b/\(path)\nnew file mode 100644\n@@ -0,0 +1,\(lines.count) @@"
        return body.isEmpty ? header : "\(header)\n\(body)"
    }

    /// Dedicated "create a new file" tool. Internally synthesizes a creation
    /// diff and reuses the `apply_patch` pipeline so the inline file card,
    /// worktree-change tracking, undo, and immediate-write semantics stay
    /// identical to how new files behaved when models hand-crafted the diff —
    /// the model just hands us a path + content instead of a unified diff.
    static func createFile(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard let rawPath = arguments["path"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty else {
            throw AgentToolError.missingArgument("path")
        }
        // `content` may legitimately be empty (empty file), so only the key's
        // absence — not an empty string — is an error.
        guard let content = arguments["content"]?.stringValue() else {
            throw AgentToolError.missingArgument("content")
        }
        // Strip an accidental leading `./`; apply_patch resolves the rest
        // workspace-relative and rejects paths outside the workspace.
        let path = rawPath.hasPrefix("./") ? String(rawPath.dropFirst(2)) : rawPath
        let resolved = try context.resolveWorkspaceURL(path)
        let relativePath = relativeWorkspacePath(resolved.url, root: resolved.root)
        let diff = makeCreationDiff(path: relativePath, content: content)

        let rawTitle = arguments["title"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (rawTitle?.isEmpty == false) ? rawTitle! : "创建文件: \(path)"
        // The host decides whether this creation can write immediately from
        // the active approval mode and recoverable git baseline.
        let patchArguments: [String: AgentJSONValue] = [
            "diff": .string(diff),
            "title": .string(title),
            "apply_immediately": .bool(true)
        ]
        return try await applyPatch(
            arguments: patchArguments,
            context: context,
            targetRoot: resolved.root
        )
    }

    // MARK: edit_file

    /// Claude-Code-style exact string replacement editor. The model passes
    /// (path, old_string, new_string) instead of hand-crafting a unified
    /// diff; the host matches old_string against the CURRENT file content
    /// (open tab buffer first, then disk), synthesizes a machine-accurate
    /// diff, and routes it through the apply_patch pipeline so the review
    /// card, auto-apply modes, undo, and worktree tracking stay identical.
    static func editFile(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard let rawPath = arguments["path"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty else {
            throw AgentToolError.missingArgument("path")
        }
        guard let oldString = arguments["old_string"]?.stringValue(), !oldString.isEmpty else {
            throw AgentToolError.missingArgument("old_string")
        }
        // `new_string` may legitimately be empty (pure deletion), so only the
        // key's absence — not an empty string — is an error.
        guard let newString = arguments["new_string"]?.stringValue() else {
            throw AgentToolError.missingArgument("new_string")
        }
        let replaceAll = arguments["replace_all"]?.boolValue() ?? false

        let path = rawPath.hasPrefix("./") ? String(rawPath.dropFirst(2)) : rawPath
        let resolved = try context.resolveWorkspaceURL(path)
        let root = resolved.root
        let url = resolved.url
        let relativePath = relativeWorkspacePath(url, root: root)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AgentToolError.notFound(path)
        }

        let currentContent: String
        if let provider = context.editableContentProvider {
            currentContent = try provider(url)
        } else {
            currentContent = AppState.decodeText(from: try Data(contentsOf: url))
        }

        let edit = try AgentEditFileSupport.makeEdit(
            path: relativePath,
            oldContent: currentContent,
            oldString: oldString,
            newString: newString,
            replaceAll: replaceAll
        )

        let rawTitle = arguments["title"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (rawTitle?.isEmpty == false) ? rawTitle! : "编辑文件: \(path)"
        var patchArguments: [String: AgentJSONValue] = [
            "diff": .string(edit.diff),
            "title": .string(title)
        ]
        if let applyImmediately = arguments["apply_immediately"]?.boolValue() {
            patchArguments["apply_immediately"] = .bool(applyImmediately)
        }
        let result = try await applyPatch(
            arguments: patchArguments,
            context: context,
            targetRoot: root
        )
        let occurrenceLine = edit.occurrences == 1
            ? "Replaced 1 occurrence of old_string in \(path)."
            : "Replaced \(edit.occurrences) occurrences of old_string in \(path)."
        return AgentToolResult(
            summary: result.summary,
            payload: "\(occurrenceLine)\n\n\(result.payload)",
            references: result.references
        )
    }

    // MARK: apply_patch

    static func applyPatch(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext,
        targetRoot: URL? = nil
    ) async throws -> AgentToolResult {
        guard let rootDirectory = context.rootDirectory else {
            throw AgentToolError.noWorkspace
        }
        guard let rawDiff = arguments["diff"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawDiff.isEmpty else {
            throw AgentToolError.missingArgument("diff")
        }
        guard let sink = context.patchProposalSink else {
            throw AgentToolError.invalidArgument("apply_patch is only available inside an interactive WillDeep agent session.")
        }

        let extractedBlocks = AgentPatchApplier.extractDiffBlocks(from: rawDiff)
        let diff = extractedBlocks.count == 1 ? extractedBlocks[0] : rawDiff
        let changes: [AgentPatchFileChange]
        do {
            changes = try AgentPatchApplier.parse(diff)
        } catch {
            throw AgentToolError.invalidArgument(error.localizedDescription)
        }

        let requestedRoot = try arguments["workspace_root"]?.stringValue().map { rawRoot in
            let resolved = try context.resolveWorkspaceURL(rawRoot)
            guard resolved.url.path == resolved.root.path else {
                throw AgentToolError.invalidArgument("workspace_root must name an exact Project folder root.")
            }
            return resolved.root
        }
        let root = (targetRoot ?? requestedRoot ?? rootDirectory).standardizedFileURL
        guard context.workspaceRoots.contains(where: { $0.path == root.path }) else {
            throw AgentToolError.pathOutsideWorkspace(root.path)
        }
        let rootPath = root.path
        for change in changes {
            let url = root.appendingPathComponent(change.path).standardizedFileURL
            guard url.path == rootPath || url.path.hasPrefix(rootPath + "/") else {
                throw AgentToolError.pathOutsideWorkspace(change.path)
            }
            // A diff path may spell its way through a symlink; the lexical
            // check above cannot see that. Same rule as resolveWorkspaceURL.
            guard AgentWorkspacePathGuard.containingRoot(
                for: url,
                roots: context.workspaceRoots
            ) != nil else {
                throw AgentToolError.symlinkOutsideWorkspace(
                    path: change.path,
                    resolved: AgentWorkspacePathGuard.resolvedPath(of: url)
                )
            }
            if change.isNewFile {
                // Creation diff: the file must NOT already exist (use a
                // modify diff to change an existing file).
                if FileManager.default.fileExists(atPath: url.path) {
                    throw AgentToolError.invalidArgument("apply_patch new-file diff targets a path that already exists: \(change.path). Use a normal modify diff instead.")
                }
            } else {
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw AgentToolError.notFound(change.path)
                }
            }
        }

        let rawTitle = arguments["title"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = rawTitle?.isEmpty == false ? rawTitle : nil
        // The model sets apply_immediately only when the user explicitly
        // asked to write / save directly without review.
        let applyImmediately = arguments["apply_immediately"]?.boolValue() ?? false
        let proposal = try await sink(title, diff, applyImmediately, root)
        let files = changes.map(\.path)
        let fileList = files.map { "- \($0)" }.joined(separator: "\n")
        let fileLabel = files.count == 1 ? "1 file" : "\(files.count) files"
        let statusLine: String
        let placementLine: String
        let summaryPrefix: String
        switch proposal.status {
        case .applied:
            statusLine = "Patch status: applied. The existing patch applier wrote the changes to disk."
            placementLine = "Changes written to disk. No further approval is required for this patch."
            summaryPrefix = "patch applied"
        case .failed:
            statusLine = "Patch status: failed\(proposal.statusMessage.map { ": \($0)" } ?? ".")"
            placementLine = "The patch was approved, but applying it failed. Diagnose the failure before retrying."
            summaryPrefix = "patch failed"
        case .rejected:
            statusLine = "Patch status: rejected."
            placementLine = "The user rejected this patch. Do not apply it unless the user explicitly asks again."
            summaryPrefix = "patch rejected"
        case .pending:
            statusLine = "Patch status: pending. No files were modified; the user must click Apply on the patch card in the chat before this patch writes to disk."
            placementLine = "A patch card is shown inline in the chat, right below your message — there is NO separate side / review panel. The user reviews and clicks Apply there. Do NOT tell the user to look in a right-side panel."
            summaryPrefix = "patch queued"
        }

        return AgentToolResult(
            summary: "\(summaryPrefix): \(fileLabel)",
            payload: """
            \(placementLine)

            Patch ID: \(proposal.id.uuidString)
            Title: \(proposal.title)
            \(statusLine)
            Files:
            \(fileList)
            """
        )
    }

    private static func relativeWorkspacePath(_ url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count + 1))
    }

    static func generateImage(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard let prompt = arguments["prompt"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !prompt.isEmpty else {
            throw AgentToolError.missingArgument("prompt")
        }
        var mediaArguments = arguments
        mediaArguments["kind"] = .string("image_generation")
        return try await AgentMediaTools.someIMCreateMediaTask(arguments: mediaArguments, context: context)
    }
}
