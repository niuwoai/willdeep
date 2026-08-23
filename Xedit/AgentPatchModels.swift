//
//  AgentPatchModels.swift
//  WillDeep
//
//  Patch / worktree change models split out of AgentModels.swift.
//

import Foundation

enum AgentPatchStatus: String, Codable {
    case pending
    case applied
    case rejected
    case failed
}

struct AgentPatchProposal: Identifiable, Codable, Equatable {
    let id: UUID
    let messageID: UUID
    let title: String
    let diff: String
    /// Root selected from the owning Project for this proposal. Nil keeps
    /// persisted proposals from older versions bound to the session root.
    let workspaceRootPath: String?
    var status: AgentPatchStatus
    var statusMessage: String?

    init(
        id: UUID = UUID(),
        messageID: UUID,
        title: String,
        diff: String,
        workspaceRootPath: String? = nil,
        status: AgentPatchStatus = .pending,
        statusMessage: String? = nil
    ) {
        self.id = id
        self.messageID = messageID
        self.title = title
        self.diff = diff
        self.workspaceRootPath = workspaceRootPath
        self.status = status
        self.statusMessage = statusMessage
    }
}

struct AgentLineChangeStats: Equatable {
    var added: Int?
    var deleted: Int?

    nonisolated init(added: Int?, deleted: Int?) {
        self.added = added
        self.deleted = deleted
    }
}

struct AgentFileChangeSummary: Identifiable, Equatable {
    var path: String
    var kind: GitFileStatusKind
    var lineStats: AgentLineChangeStats

    nonisolated var id: String { path }

    nonisolated var fileName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    nonisolated var addedLines: Int {
        lineStats.added ?? 0
    }

    nonisolated var deletedLines: Int {
        lineStats.deleted ?? 0
    }

    nonisolated var hasKnownLineStats: Bool {
        lineStats.added != nil || lineStats.deleted != nil
    }
}

struct AgentWorktreeChangeSummary: Equatable {
    var repositoryRoot: URL?
    var files: [AgentFileChangeSummary]

    nonisolated init(repositoryRoot: URL? = nil, files: [AgentFileChangeSummary] = []) {
        self.repositoryRoot = repositoryRoot
        self.files = files.sorted { lhs, rhs in
            lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
    }

    nonisolated var isEmpty: Bool {
        files.isEmpty
    }

    nonisolated var fileCount: Int {
        files.count
    }

    nonisolated var totalAddedLines: Int {
        files.reduce(0) { $0 + $1.addedLines }
    }

    nonisolated var totalDeletedLines: Int {
        files.reduce(0) { $0 + $1.deletedLines }
    }

    nonisolated func change(for relativePath: String) -> AgentFileChangeSummary? {
        files.first { $0.path == relativePath }
    }

    nonisolated func filtering(paths: Set<String>) -> AgentWorktreeChangeSummary {
        guard !paths.isEmpty else {
            return AgentWorktreeChangeSummary(repositoryRoot: repositoryRoot)
        }
        return AgentWorktreeChangeSummary(
            repositoryRoot: repositoryRoot,
            files: files.filter { paths.contains($0.path) }
        )
    }
}

struct AgentWorktreeDiffPreview: Identifiable, Equatable {
    let id: UUID
    var title: String
    var diff: String

    nonisolated init(id: UUID = UUID(), title: String, diff: String) {
        self.id = id
        self.title = title
        self.diff = diff
    }
}
