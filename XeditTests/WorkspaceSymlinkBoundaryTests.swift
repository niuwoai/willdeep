//
//  WorkspaceSymlinkBoundaryTests.swift
//  WillDeepTests
//
//  Symbolic links must not widen the set of folders a project authorized.
//  Before this suite the three channels disagreed: the native file tools
//  matched paths lexically and happily followed a link out of the workspace,
//  `run_command` was blocked by seatbelt at the resolved vnode path, and the
//  sidebar rendered a linked folder as an unexpandable file. These tests pin
//  the agreed behavior — resolve before deciding, read the link in the tree,
//  never loop on a cycle.
//

import Testing
import Foundation
@testable import WillDeep

@Suite(.serialized)
struct WorkspaceSymlinkBoundaryTests {
    /// Fresh sandbox with `workspace/` and `outside/` siblings.
    /// Note the temporary directory itself lives under `/var/folders/…`,
    /// where `/var` is a symlink to `/private/var` — so every case here also
    /// exercises a root whose own spelling contains a link.
    private func makeSandbox() throws -> (root: URL, workspace: URL, outside: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-symlink-boundary-\(UUID().uuidString)")
        let workspace = root.appendingPathComponent("workspace")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        return (root, workspace, outside)
    }

    // MARK: - Tool path resolution

    @Test("A link out of the workspace is rejected, not followed")
    @MainActor
    func linkEscapingWorkspaceIsRejected() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let secret = sandbox.outside.appendingPathComponent("secret.txt")
        try "classified".write(to: secret, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: sandbox.workspace.appendingPathComponent("linked"),
            withDestinationURL: sandbox.outside
        )

        let context = AgentToolContext(rootDirectory: sandbox.workspace)
        var thrown: AgentToolError?
        do {
            _ = try context.resolveWorkspaceURL("linked/secret.txt")
        } catch let error as AgentToolError {
            thrown = error
        }

        guard case .symlinkOutsideWorkspace(_, let resolved)? = thrown else {
            Issue.record("expected symlinkOutsideWorkspace, got \(String(describing: thrown))")
            return
        }
        // The message has to name the real destination — that is the whole
        // point of the dedicated case: the user learns which folder to add.
        #expect(resolved.hasSuffix("/outside/secret.txt"))
        let description = thrown?.errorDescription ?? ""
        #expect(description.contains("symbolic link"))
        #expect(description.contains("outside"))
    }

    @Test("A link escape is rejected even when the target does not exist yet")
    @MainActor
    func linkEscapeIsRejectedForNewFiles() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        try FileManager.default.createSymbolicLink(
            at: sandbox.workspace.appendingPathComponent("linked"),
            withDestinationURL: sandbox.outside
        )

        let context = AgentToolContext(rootDirectory: sandbox.workspace)
        var thrown: (any Error)?
        do {
            _ = try context.resolveWorkspaceURL("linked/brand-new/file.txt")
        } catch {
            thrown = error
        }

        guard case .symlinkOutsideWorkspace? = thrown as? AgentToolError else {
            Issue.record("a write to a not-yet-existing path behind a link must still be refused")
            return
        }
    }

    @Test("A link into another authorized folder is allowed")
    @MainActor
    func linkIntoSecondAuthorizedRootIsAllowed() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let note = sandbox.outside.appendingPathComponent("note.txt")
        try "shared".write(to: note, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: sandbox.workspace.appendingPathComponent("linked"),
            withDestinationURL: sandbox.outside
        )

        // `outside` is a second project folder here, so the link points at
        // something the user already granted — and seatbelt allows the same
        // pair, so refusing it would only split the two channels again.
        let context = AgentToolContext(
            rootDirectory: sandbox.workspace,
            additionalWorkspaceRoots: [sandbox.outside]
        )
        let resolved = try context.resolveWorkspaceURL("linked/note.txt")

        #expect(resolved.url.path.hasSuffix("/workspace/linked/note.txt"))
        #expect(resolved.root.path == sandbox.workspace.standardizedFileURL.path)
    }

    @Test("Ordinary paths inside the workspace still resolve")
    @MainActor
    func ordinaryPathsStillResolve() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let nested = sandbox.workspace.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "print()".write(
            to: nested.appendingPathComponent("main.swift"),
            atomically: true,
            encoding: .utf8
        )

        let context = AgentToolContext(rootDirectory: sandbox.workspace)
        let relative = try context.resolveWorkspaceURL("src/main.swift")
        let absolute = try context.resolveWorkspaceURL(
            sandbox.workspace.appendingPathComponent("src/main.swift").path
        )

        #expect(relative.url.path == absolute.url.path)
        #expect(relative.root.path == sandbox.workspace.standardizedFileURL.path)
    }

    @Test("A link that stays inside the workspace is allowed")
    @MainActor
    func internalLinkIsAllowed() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let real = sandbox.workspace.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try "x".write(to: real.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: sandbox.workspace.appendingPathComponent("alias"),
            withDestinationURL: real
        )

        let context = AgentToolContext(rootDirectory: sandbox.workspace)
        let resolved = try context.resolveWorkspaceURL("alias/f.txt")

        #expect(resolved.url.path.hasSuffix("/alias/f.txt"))
    }

    @Test("Lexical escapes are still refused as plain out-of-workspace paths")
    @MainActor
    func lexicalEscapeKeepsOriginalError() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let context = AgentToolContext(rootDirectory: sandbox.workspace)
        var thrown: (any Error)?
        do {
            _ = try context.resolveWorkspaceURL("../outside/secret.txt")
        } catch {
            thrown = error
        }

        guard case .pathOutsideWorkspace? = thrown as? AgentToolError else {
            Issue.record("expected pathOutsideWorkspace, got \(String(describing: thrown))")
            return
        }
    }

    @Test("apply_patch cannot spell its way out through a link")
    @MainActor
    func applyPatchRefusesLinkedPath() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        try FileManager.default.createSymbolicLink(
            at: sandbox.workspace.appendingPathComponent("linked"),
            withDestinationURL: sandbox.outside
        )
        let target = sandbox.outside.appendingPathComponent("victim.txt")
        try "original\n".write(to: target, atomically: true, encoding: .utf8)
        let diff = """
        --- a/linked/victim.txt
        +++ b/linked/victim.txt
        @@ -1 +1 @@
        -original
        +planted
        """

        let context = AgentToolContext(
            rootDirectory: sandbox.workspace,
            patchProposalSink: { title, diff, _, _ in
                AgentPatchProposal(messageID: UUID(), title: title ?? "patch", diff: diff)
            }
        )
        var thrown: (any Error)?
        do {
            _ = try await AgentToolRunner.run(
                name: "apply_patch",
                arguments: ["diff": .string(diff)],
                context: context
            )
        } catch {
            thrown = error
        }

        guard case .symlinkOutsideWorkspace? = thrown as? AgentToolError else {
            Issue.record("expected symlinkOutsideWorkspace, got \(String(describing: thrown))")
            return
        }
        let content = try String(contentsOf: target, encoding: .utf8)
        #expect(content == "original\n")
    }

    // MARK: - File tree

    @Test("The sidebar reads a symlinked folder as a folder")
    @MainActor
    func treeTreatsLinkedDirectoryAsDirectory() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        try "hello".write(
            to: sandbox.outside.appendingPathComponent("inside.txt"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: sandbox.workspace.appendingPathComponent("linked"),
            withDestinationURL: sandbox.outside
        )

        let root = FileSystemNode(url: sandbox.workspace)
        root.loadChildrenSyncIfNeeded()
        let linked = root.children?.first { $0.name == "linked" }

        #expect(linked?.isDirectory == true)
        #expect(linked?.isSymbolicLink == true)
        #expect(linked?.isCyclicSymlink == false)

        linked?.loadChildrenSyncIfNeeded()
        let linkedChildNames = (linked?.children ?? []).map(\.name)
        #expect(linkedChildNames.contains("inside.txt"))
    }

    @Test("A symlink to a file stays a file")
    @MainActor
    func treeKeepsFileLinksAsFiles() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let target = sandbox.outside.appendingPathComponent("target.txt")
        try "hello".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: sandbox.workspace.appendingPathComponent("alias.txt"),
            withDestinationURL: target
        )

        let root = FileSystemNode(url: sandbox.workspace)
        root.loadChildrenSyncIfNeeded()
        let alias = root.children?.first { $0.name == "alias.txt" }

        #expect(alias?.isSymbolicLink == true)
        #expect(alias?.isDirectory == false)
    }

    @Test("A self-referential link expands once and then stops")
    @MainActor
    func treeStopsOnSymlinkCycle() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        // `workspace/loop` -> `workspace`: walking it would recurse forever.
        try FileManager.default.createSymbolicLink(
            at: sandbox.workspace.appendingPathComponent("loop"),
            withDestinationURL: sandbox.workspace
        )

        let root = FileSystemNode(url: sandbox.workspace)
        root.loadChildrenSyncIfNeeded()
        let firstLoop = root.children?.first { $0.name == "loop" }

        // One level is legitimate — the link does point at a real directory.
        #expect(firstLoop?.isDirectory == true)
        #expect(firstLoop?.isCyclicSymlink == true)

        firstLoop?.loadChildrenSyncIfNeeded()
        #expect(firstLoop?.children == nil)
    }

    @Test("A two-hop link cycle is caught as well")
    @MainActor
    func treeStopsOnIndirectSymlinkCycle() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let nested = sandbox.workspace.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        // `workspace/nested/back` -> `workspace`
        try FileManager.default.createSymbolicLink(
            at: nested.appendingPathComponent("back"),
            withDestinationURL: sandbox.workspace
        )

        let root = FileSystemNode(url: sandbox.workspace)
        root.loadChildrenSyncIfNeeded()
        let nestedNode = root.children?.first { $0.name == "nested" }
        nestedNode?.loadChildrenSyncIfNeeded()
        let back = nestedNode?.children?.first { $0.name == "back" }

        #expect(back?.isCyclicSymlink == true)
        back?.loadChildrenSyncIfNeeded()
        #expect(back?.children == nil)
    }
}
