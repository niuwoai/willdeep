//
//  AppStateMobileGatewayController.swift
//  WillDeep
//
//  AppState adapter used by the LAN Mobile Gateway command router.
//

import Foundation

private struct AgentState_MobileGatewayWorkspaceBucket {
    var path: String
    var name: String
    var lastUsedAt: Date?
    var sessionCount: Int
    var isCurrent: Bool
}

/// Memoizes the two filesystem probes behind `mobileGatewayWorkspaceList`.
///
/// That property runs both probes for **every** workspace on **every** gateway
/// snapshot — once per 400ms for as long as a phone stays connected — and
/// `mobileGatewayRepositoryRoot` additionally walks *up* the directory tree
/// stat-ing `.git` at each level. All of it is synchronous file IO on
/// @MainActor; a 5s sample of 1.228.0-rc10 caught `lstat` as a main-thread leaf
/// while the window was doing nothing but rendering.
///
/// Whether a directory is a git repo is a human-scale fact, so entries expire on
/// a short TTL rather than living forever: a `git init` in an open workspace
/// still reaches the phone within a snapshot or two, while the steady state
/// costs a dictionary lookup instead of a syscall.
///
/// The probes are injected rather than called directly so the cache semantics
/// can be tested without touching a filesystem.
struct AgentMobileGatewayRepoProbeCache {
    /// Chosen against the 400ms snapshot cadence: long enough that ~75
    /// consecutive snapshots reuse one probe, short enough that a repo
    /// appearing or disappearing is never stale for more than half a minute.
    static let ttl: TimeInterval = 30

    private var isRepoByPath: [String: (value: Bool, readAt: Date)] = [:]
    private var repositoryRootByPath: [String: (value: String?, readAt: Date)] = [:]

    mutating func isGitRepo(_ path: String, now: Date = Date(), probe: () -> Bool) -> Bool {
        if let hit = isRepoByPath[path], now.timeIntervalSince(hit.readAt) < Self.ttl {
            return hit.value
        }
        let value = probe()
        isRepoByPath[path] = (value, now)
        return value
    }

    mutating func repositoryRoot(
        for path: String,
        now: Date = Date(),
        probe: () -> String?
    ) -> String? {
        if let hit = repositoryRootByPath[path], now.timeIntervalSince(hit.readAt) < Self.ttl {
            return hit.value
        }
        let value = probe()
        repositoryRootByPath[path] = (value, now)
        return value
    }

    mutating func reset() {
        isRepoByPath.removeAll()
        repositoryRootByPath.removeAll()
    }
}

@MainActor private var agentState_mobileGatewayRepoProbes = AgentMobileGatewayRepoProbeCache()

extension AppState: AgentMobileGatewayControlling {
    var mobileGatewaySessions: [AgentSession] { agentSessions.filter { $0.presentationScope != .deferredTask } }
    var mobileGatewayActiveSessionID: UUID? { activeAgentSessionID }
    var mobileGatewayPendingToolApprovals: [AgentMobileGatewayToolApprovalSnapshot] {
        agentRuntimes.values.flatMap { runtime in
            runtime.toolCalls
                .filter { call in
                    call.status == .pendingApproval ||
                    call.status == .awaitingConfirm ||
                    call.status == .awaitingUserAnswer
                }
                .map { call in
                    AgentMobileGatewayToolApprovalSnapshot(
                        parked: runtime.parkedGateIDs.contains(call.id),
                        id: call.id.uuidString,
                        title: mobileGatewayToolTitle(for: call),
                        summary: mobileGatewayToolSummary(for: call),
                        toolName: call.toolName,
                        inputPreview: Self.mobileGatewayArgumentsPreview(call.arguments),
                        requiresConfirmation: call.status == .awaitingConfirm,
                        sessionID: runtime.deferredParentRuntimeID ?? runtime.id
                    )
                }
        }
        .sorted { lhs, rhs in
            if lhs.sessionID != rhs.sessionID {
                return lhs.sessionID.uuidString < rhs.sessionID.uuidString
            }
            return lhs.id < rhs.id
        }
    }

    var mobileGatewayPendingPatchProposals: [AgentMobileGatewayPatchSnapshot] {
        agentRuntimes.values.flatMap { runtime in
            runtime.patchProposals
                .filter { $0.status == .pending }
                .map { proposal in
                    let batchCount = runtime.patchProposals.filter {
                        $0.messageID == proposal.messageID
                    }.count
                    return AgentMobileGatewayPatchSnapshot(
                        id: proposal.id,
                        title: proposal.title,
                        summary: "Patch proposal",
                        path: Self.mobileGatewayPatchPath(from: proposal.diff),
                        stats: Self.mobileGatewayPatchStats(from: proposal.diff),
                        sessionID: runtime.id,
                        batchID: proposal.messageID,
                        batchCount: batchCount,
                        batchCollecting: runtime.collectingPatchReviewMessageIDs.contains(
                            proposal.messageID
                        )
                    )
                }
        }
        .sorted { lhs, rhs in
            if lhs.sessionID != rhs.sessionID {
                return lhs.sessionID.uuidString < rhs.sessionID.uuidString
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    var mobileGatewayJobs: [AgentMobileGatewayJobSnapshot] {
        agentRuntimes.values.flatMap { runtime in
            agentJobRegistry.jobs(forRuntime: runtime.id).map { job in
                AgentMobileGatewayJobSnapshot(
                    id: job.id,
                    handle: job.displayHandle,
                    command: Self.mobileGatewayTruncated(job.command),
                    status: job.status.rawValue,
                    isAlive: job.isAlive,
                    pid: job.pid,
                    exitCode: job.exitCode,
                    outputByteCount: job.outputByteCount,
                    startedAt: job.startedAt,
                    finishedAt: job.finishedAt,
                    sessionID: runtime.id
                )
            }
        }
        .sorted { lhs, rhs in
            if lhs.sessionID != rhs.sessionID {
                return lhs.sessionID.uuidString < rhs.sessionID.uuidString
            }
            return lhs.startedAt > rhs.startedAt
        }
    }

    /// Live runtimes in session-list order, READ-ONLY. Snapshot accessors
    /// must never go through `runtime(for:)`: that call materializes a
    /// runtime for every persisted session (disk read + JSON decode) and
    /// triggers idle-runtime eviction, which synchronously JSON-encodes and
    /// atomically writes each evicted session — all on @MainActor. With the
    /// gateway snapshotting periodically, materialize→evict→persist looped
    /// forever and pinned a core (v1.129.0-rc21 sample: 20–60% CPU).
    /// Sessions without a live runtime have no queued/streaming state to
    /// report; the phone materializes one on demand via the command path
    /// when it opens a session.
    private var mobileGatewayLiveRuntimes: [AgentRuntime] {
        agentSessions.compactMap { agentRuntimes[$0.id] }
    }

    var mobileGatewayQueuedMessages: [AgentMobileGatewayQueuedMessageSnapshot] {
        mobileGatewayLiveRuntimes.flatMap { runtime in
            runtime.queuedMessages
                .filter { $0.source == .operatorInput }
                .map { message in
                    AgentMobileGatewayQueuedMessageSnapshot(
                        id: message.id,
                        textPreview: Self.mobileGatewayQueuedTextPreview(message),
                        imageCount: message.images.count,
                        textAttachmentCount: message.textAttachments.count,
                        sessionID: runtime.id,
                        text: Self.mobileGatewayEditableQueueText(message.text)
                    )
                }
        }
    }

    var mobileGatewayRecentMessages: [AgentMobileGatewayMessageSnapshot] {
        mobileGatewayLiveRuntimes.flatMap { runtime in
            runtime.messages
                .filter { message in
                    message.isOperatorInput ||
                    message.role == .assistant ||
                    message.role == .system
                }
                .suffix(Self.mobileGatewayMaxRecentMessagesPerSession)
                .map { message in
                    AgentMobileGatewayMessageSnapshot(
                        id: message.id,
                        role: message.role.rawValue,
                        content: Self.mobileGatewayMessageContentPreview(message),
                        createdAt: message.createdAt,
                        sessionID: runtime.deferredParentRuntimeID ?? runtime.id
                    )
                }
        }
    }

    var mobileGatewayWorktreeChanges: [AgentMobileGatewayWorktreeSnapshot] {
        mobileGatewayLiveRuntimes.compactMap { runtime in
            let changes = runtime.worktreeChanges
            guard !changes.isEmpty else { return nil }
            return AgentMobileGatewayWorktreeSnapshot(
                repositoryRoot: changes.repositoryRoot?.standardizedFileURL.path,
                fileCount: changes.fileCount,
                totalAddedLines: changes.totalAddedLines,
                totalDeletedLines: changes.totalDeletedLines,
                files: changes.files.map { file in
                    AgentMobileGatewayWorktreeFileSnapshot(
                        path: file.path,
                        kind: file.kind.rawValue,
                        addedLines: file.addedLines,
                        deletedLines: file.deletedLines
                    )
                },
                sessionID: runtime.id
            )
        }
    }

    func mobileGatewayRuntimeIsResponding(sessionID: UUID) -> Bool {
        guard let runtime = agentRuntimes[sessionID] else { return false }
        return deferredGroup(for: runtime).contains { $0.isResponding || $0.isAwaitingProviderSlot || !$0.toolDecisionWaiters.isEmpty }
    }

    var mobileGatewayWorkspaceList: [AgentMobileGatewayWorkspaceSnapshot] {
        var buckets: [String: AgentState_MobileGatewayWorkspaceBucket] = [:]
        let currentPath = rootDirectory.map { Self.mobileGatewayRealpath($0.path) }

        for session in agentSessions {
            guard case .local(let raw)? = session.workspaceLocation else {
                if let raw = session.workspaceRootPath, !raw.isEmpty {
                    Self.mobileGatewayUpsertWorkspaceBucket(
                        into: &buckets,
                        rawPath: raw,
                        lastUsedAt: session.updatedAt,
                        currentPath: currentPath
                    )
                }
                continue
            }
            guard !raw.isEmpty else { continue }
            Self.mobileGatewayUpsertWorkspaceBucket(
                into: &buckets,
                rawPath: raw,
                lastUsedAt: session.updatedAt,
                currentPath: currentPath
            )
        }
        if let currentPath {
            Self.mobileGatewayUpsertWorkspaceBucket(
                into: &buckets,
                rawPath: currentPath,
                lastUsedAt: nil,
                currentPath: currentPath
            )
        }

        let now = Date()
        var snapshots: [AgentMobileGatewayWorkspaceSnapshot] = []
        snapshots.reserveCapacity(buckets.count)
        for bucket in buckets.values {
            let url = URL(fileURLWithPath: bucket.path)
            // Both probes go through the TTL cache: this loop runs on every
            // gateway snapshot, and each miss is a `.git` stat plus (for the
            // root) a walk to the filesystem root.
            let isGitRepo = agentState_mobileGatewayRepoProbes.isGitRepo(bucket.path, now: now) {
                Self.mobileGatewayIsGitRepo(url)
            }
            let repositoryRoot = agentState_mobileGatewayRepoProbes.repositoryRoot(
                for: bucket.path,
                now: now
            ) {
                Self.mobileGatewayRepositoryRoot(for: url)
            }
            snapshots.append(
                AgentMobileGatewayWorkspaceSnapshot(
                    path: bucket.path,
                    name: bucket.name,
                    lastUsedAt: bucket.lastUsedAt ?? (bucket.isCurrent ? now : nil),
                    sessionCount: bucket.sessionCount,
                    isCurrent: bucket.isCurrent,
                    isGitRepo: isGitRepo,
                    repositoryRoot: repositoryRoot
                )
            )
        }
        return snapshots.sorted { lhs, rhs in
            let l = lhs.lastUsedAt ?? .distantPast
            let r = rhs.lastUsedAt ?? .distantPast
            if l != r { return l > r }
            return lhs.path < rhs.path
        }
    }

    var mobileGatewayCapabilities: AgentMobileGatewayCapabilitiesSnapshot {
        let activeProvider = activeAgentProviderEntry
        let activeProviderID = activeProvider?.id.uuidString
        let overrideModel = agentSessionModelOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeModelID = overrideModel?.isEmpty == false
            ? overrideModel!
            : activeAgentModelID

        let providers = agentProviderLibrary.entries.map { entry in
            let presetName = AgentProviderPreset.preset(id: entry.providerID)?.displayName ?? entry.providerID
            return AgentMobileGatewayCapabilityOptionSnapshot(
                id: entry.id.uuidString,
                title: entry.displayName,
                subtitle: presetName,
                isActive: entry.id == activeProvider?.id
            )
        }

        let modelCandidates = Self.mobileGatewayUniqueStrings(
            (activeProvider?.allFlashModels ?? []) +
            (activeProvider?.allProModels ?? []) +
            agentRecentlyUsedModelIDs +
            agentKnownModelIDs +
            [
                activeModelID,
                agentConfiguration.normalized.model(for: .interactive),
                agentConfiguration.normalized.flashModel,
                agentConfiguration.normalized.proModel
            ]
        ).filter { agentModelIsCompatibleWithActiveProvider($0) }
        let models = modelCandidates.map { model in
            AgentMobileGatewayCapabilityOptionSnapshot(
                id: model,
                title: model,
                subtitle: activeProvider?.displayName,
                isActive: model == activeModelID
            )
        }

        let pendingSkillIDs = Set(agentPendingSkills.map(\.identifier))
        let skillEntries = AgentSkillDirectory.list(includeDisabled: false)
        let skills = skillEntries
            .filter { $0.source != .plugin }

            .map { entry in
                AgentMobileGatewayCapabilityOptionSnapshot(
                    id: entry.identifier,
                    title: AgentSkillLocalization.displayName(for: entry),
                    subtitle: AgentSkillLocalization.displayDescription(for: entry),
                    isActive: pendingSkillIDs.contains(entry.identifier)
                )
            }

        let activeExperts = agentActiveExperts
        let experts = AgentExpert.allCases.map { expert in
            AgentMobileGatewayCapabilityOptionSnapshot(
                id: expert.rawValue,
                title: expert.displayName,
                subtitle: expert.summary,
                isActive: activeExperts.contains(expert)
            )
        }

        let pluginGroups = Dictionary(grouping: skillEntries.filter { $0.source == .plugin }) { skill in
            skill.identifier.split(separator: ":").first.map(String.init) ?? skill.identifier
        }
        let plugins = pluginGroups
            .map { name, skills in
                AgentMobileGatewayCapabilityOptionSnapshot(
                    id: "plugin:\(name)",
                    title: Self.mobileGatewayPluginDisplayName(name),
                    subtitle: "\(skills.count) skills",
                    isActive: skills.contains { pendingSkillIDs.contains($0.identifier) }
                )
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        return AgentMobileGatewayCapabilitiesSnapshot(
            providers: providers,
            models: models,
            skills: Array(skills),
            experts: experts,
            plugins: plugins,
            activeProviderID: activeProviderID,
            activeModelID: activeModelID,
            activeApprovalMode: Self.mobileGatewayCanonicalApprovalMode(agentApprovalMode),
            supportsConfiguration: true
        )
    }

    func mobileGatewayValidateWorkspacePath(_ rawPath: String) throws -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AgentMobileGatewayCommandError.missingWorkspacePath
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let resolved = Self.mobileGatewayRealpath(expanded)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir) else {
            throw AgentMobileGatewayCommandError.workspacePathNotFound(rawPath)
        }
        guard isDir.boolValue else {
            throw AgentMobileGatewayCommandError.workspacePathNotDirectory(rawPath)
        }
        guard Self.mobileGatewayIsWorkspacePathAllowed(resolved) else {
            throw AgentMobileGatewayCommandError.workspacePathForbidden(rawPath)
        }
        return resolved
    }

    func mobileGatewayStartSession(workspacePath: String?) -> AgentSession {
        startNewAgentSession(inWorkspaceAt: workspacePath)
    }

    private static func mobileGatewayUpsertWorkspaceBucket(
        into buckets: inout [String: AgentState_MobileGatewayWorkspaceBucket],
        rawPath: String,
        lastUsedAt: Date?,
        currentPath: String?
    ) {
        let resolved = mobileGatewayRealpath(rawPath)
        guard !resolved.isEmpty, resolved != "/" else { return }
        guard mobileGatewayIsWorkspacePathAllowed(resolved) else { return }
        let name = (resolved as NSString).lastPathComponent
        let isCurrent = currentPath.map { $0 == resolved } ?? false
        if var existing = buckets[resolved] {
            if let lastUsedAt {
                if let prior = existing.lastUsedAt {
                    if lastUsedAt > prior { existing.lastUsedAt = lastUsedAt }
                } else {
                    existing.lastUsedAt = lastUsedAt
                }
                existing.sessionCount += 1
            }
            if isCurrent { existing.isCurrent = true }
            buckets[resolved] = existing
        } else {
            buckets[resolved] = AgentState_MobileGatewayWorkspaceBucket(
                path: resolved,
                name: name.isEmpty ? resolved : name,
                lastUsedAt: lastUsedAt,
                sessionCount: lastUsedAt == nil ? 0 : 1,
                isCurrent: isCurrent
            )
        }
    }

    private static func mobileGatewayRealpath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        return url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func mobileGatewayIsGitRepo(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        let gitPath = url.appendingPathComponent(".git").path
        guard FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDir) else {
            return false
        }
        return isDir.boolValue || mobileGatewayIsGitFileWorktree(url.appendingPathComponent(".git"))
    }

    private static func mobileGatewayIsGitFileWorktree(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let text = String(data: data.prefix(64), encoding: .utf8) else {
            return false
        }
        return text.hasPrefix("gitdir:")
    }

    private static func mobileGatewayRepositoryRoot(for url: URL) -> String? {
        var current = url.standardizedFileURL
        let fm = FileManager.default
        while true {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: current.appendingPathComponent(".git").path, isDirectory: &isDir) {
                return current.path
            }
            // On macOS 13 Foundation, deletingLastPathComponent() at "/" yields
            // "/.." — must re-standardize or the walk never terminates and the
            // URL grows unboundedly (main-thread hang, sample: appendingPathComponent
            // / deletingLastPathComponent / URL.path in a tight loop).
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path || parent.path.count >= current.path.count { return nil }
            current = parent
        }
    }

    private static func mobileGatewayIsWorkspacePathAllowed(_ resolved: String) -> Bool {
        guard !resolved.isEmpty, resolved != "/" else { return false }
        let forbiddenExact: Set<String> = ["/etc", "/var", "/usr", "/bin", "/sbin", "/private", "/System", "/Library"]
        if forbiddenExact.contains(resolved) { return false }
        let forbiddenPrefixes = ["/etc/", "/private/etc/", "/System/", "/usr/", "/bin/", "/sbin/"]
        for prefix in forbiddenPrefixes where resolved.hasPrefix(prefix) {
            return false
        }
        let home = NSHomeDirectory()
        let userLibrary = (home as NSString).appendingPathComponent("Library")
        if resolved == userLibrary || resolved.hasPrefix(userLibrary + "/") {
            return false
        }
        return true
    }

    func mobileGatewaySelectSession(id: UUID) -> Bool {
        guard agentSessions.contains(where: { $0.id == id }) else { return false }
        selectAgentSession(id: id)
        return true
    }

    func mobileGatewaySendMessage(
        sessionID: UUID?,
        text: String,
        images: [AgentImageAttachment],
        workspacePath: String?,
        providerID: String?,
        modelID: String?,
        approvalModeID: String?,
        skillIDs: [String],
        expertIDs: [String],
        pluginIDs: [String]
    ) throws -> AgentMobileGatewayCommandResult {
        if let sessionID {
            guard mobileGatewaySelectSession(id: sessionID) else {
                throw AgentMobileGatewayCommandError.sessionNotFound(sessionID)
            }
        } else if let workspacePath, !workspacePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let url = URL(fileURLWithPath: workspacePath).standardizedFileURL
            if let runtime = activeRuntime, runtime.isEmpty, !runtime.isResponding {
                runtime.rebindWorkspace(to: url.path)
            } else if activeRuntime?.workspaceRootPath != url.path || activeRuntime?.isResponding == true {
                _ = startNewAgentSession(inWorkspaceAt: url.path)
            }
        } else if activeRuntime == nil {
            _ = startNewAgentSession()
        }
        guard let runtime = activeRuntime else {
            let session = startNewAgentSession()
            return try mobileGatewaySendMessage(
                sessionID: session.id,
                text: text,
                images: images,
                workspacePath: nil,
                providerID: providerID,
                modelID: modelID,
                approvalModeID: approvalModeID,
                skillIDs: skillIDs,
                expertIDs: expertIDs,
                pluginIDs: pluginIDs
            )
        }
        var patch: [String: AgentMobileGatewayJSON] = [:]
        if let providerID { patch["provider_id"] = .string(providerID) }
        if let modelID { patch["model"] = .string(modelID) }
        if let approvalModeID { patch["approval_mode"] = .string(approvalModeID) }
        if !skillIDs.isEmpty { patch["skills"] = .array(skillIDs.map(AgentMobileGatewayJSON.string)) }
        if !expertIDs.isEmpty { patch["experts"] = .array(expertIDs.map(AgentMobileGatewayJSON.string)) }
        if !pluginIDs.isEmpty { patch["plugins"] = .array(pluginIDs.map(AgentMobileGatewayJSON.string)) }
        if !patch.isEmpty { _ = try mobileGatewayConfigure(sessionID: runtime.id, patch: patch) }
        runtime.input = text
        runtime.pendingImages = images
        sendAgentMessage()
        return .ok(sessionID: runtime.id)
    }

    private func applyMobileGatewayRunContext(
        providerID: String?,
        modelID: String?,
        approvalModeID: String?,
        skillIDs: [String],
        expertIDs: [String],
        pluginIDs: [String]
    ) {
        if let rawProviderID = providerID?.trimmingCharacters(in: .whitespacesAndNewlines),
           let providerUUID = UUID(uuidString: rawProviderID),
           let entry = agentProviderLibrary.entries.first(where: { $0.id == providerUUID }) {
            selectAgentEntryAndModel(entryID: providerUUID, model: modelID ?? entry.makeConfiguration().normalized.model(for: .interactive))
        } else if let rawModelID = modelID?.trimmingCharacters(in: .whitespacesAndNewlines), !rawModelID.isEmpty {
            setAgentSessionModel(rawModelID)
        }
        if let mode = Self.mobileGatewayApprovalMode(from: approvalModeID) {
            setAgentApprovalMode(mode)
        }

        let entries = AgentSkillDirectory.list(includeDisabled: false)
        let directIDs = Set(skillIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        let pluginPrefixes = pluginIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { $0.hasPrefix("plugin:") ? String($0.dropFirst("plugin:".count)) : $0 }
        let selectedSkills = entries.filter { entry in
            if directIDs.contains(entry.identifier) { return true }
            return pluginPrefixes.contains { prefix in
                entry.identifier == prefix || entry.identifier.hasPrefix(prefix + ":")
            }
        }
        selectedSkills.forEach { attachAgentSkill($0) }

        expertIDs
            .compactMap { AgentExpert(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .forEach { activateAgentExpert($0) }
    }

    private static func mobileGatewayUniqueStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }

    private static func mobileGatewayPluginDisplayName(_ name: String) -> String {
        switch name.lowercased() {
        case "browser": return "Browser"
        case "chrome": return "Chrome"
        case "gmail": return "Gmail"
        case "github": return "GitHub"
        default: return name
        }
    }

    private static func mobileGatewayApprovalMode(from raw: String?) -> AgentApprovalMode? {
        let value = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        switch value {
        case "strict", "ask_every_time", "request_every_time", "requesteverytime":
            return .requestEveryTime
        case "smart", "smart_approval":
            return .smart
        case "silent", "silent_mode", "silentmode", "full_access", "fullaccess":
            return .fullAccess
        case "workspace_write", "workspace_access", "workspace_writable", "workspaceaccess":
            return .workspaceAccess
        default:
            return nil
        }
    }

    static func mobileGatewayCanonicalApprovalMode(_ mode: AgentApprovalMode) -> String {
        switch mode {
        case .requestEveryTime: return "strict"
        case .smart: return "smart"
        case .workspaceAccess: return "workspace-write"
        case .fullAccess: return "full-access"
        }
    }

    func mobileGatewayConfigure(sessionID: UUID?, patch: [String: AgentMobileGatewayJSON]) throws -> AgentMobileGatewayCommandResult {
        if let sessionID, !mobileGatewaySelectSession(id: sessionID) {
            throw AgentMobileGatewayCommandError.sessionNotFound(sessionID)
        }
        guard let runtime = activeRuntime else { throw AgentMobileGatewayCommandError.missingID("session.configure") }
        let allowed = Set(["provider_id", "model", "approval_mode", "skills", "experts", "plugins"])
        guard Set(patch.keys).isSubset(of: allowed) else { throw AgentMobileGatewayCommandError.invalidAction("configuration field") }
        let entries = AgentSkillDirectory.list(includeDisabled: false)
        let stringFields = ["provider_id", "model", "approval_mode"]
        for key in stringFields where patch[key] != nil {
            guard let value = patch[key]?.stringValue, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentMobileGatewayCommandError.invalidAction(key)
            }
        }
        if let provider = patch["provider_id"]?.stringValue {
            guard let id = UUID(uuidString: provider), agentProviderLibrary.entries.contains(where: { $0.id == id }) else {
                throw AgentMobileGatewayCommandError.invalidAction("provider_id")
            }
        }
        if let mode = patch["approval_mode"]?.stringValue, Self.mobileGatewayApprovalMode(from: mode) == nil {
            throw AgentMobileGatewayCommandError.invalidAction("approval_mode")
        }
        if let model = patch["model"]?.stringValue, model.count > 256 || model.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
            throw AgentMobileGatewayCommandError.invalidAction("model")
        }
        if patch["provider_id"] != nil || patch["model"] != nil {
            let candidateID = patch["provider_id"]?.stringValue.flatMap(UUID.init(uuidString:)) ?? activeAgentProviderEntry?.id
            if let candidateID { materializeProviderLibraryEntryAPIKey(id: candidateID) }
            guard let candidate = agentProviderLibrary.entries.first(where: { $0.id == candidateID }),
                  candidate.isUsableForChatSelection(isSomeIMAuthenticated: SomeIMIntegrationStore.hasAuthenticatedSessionForAutomaticDefaults()) else {
                throw AgentMobileGatewayCommandError.invalidAction("provider is not configured for chat")
            }
            if let model = patch["model"]?.stringValue, let preset = AgentProviderPreset.preset(id: candidate.providerID),
               preset.id != AgentProviderPreset.customID, !preset.recognizesModelID(model) {
                throw AgentMobileGatewayCommandError.invalidAction("model is incompatible with provider")
            }
        }
        func ids(_ key: String) throws -> [String]? {
            guard let value = patch[key] else { return nil }
            guard case .array(let values) = value else { throw AgentMobileGatewayCommandError.invalidAction(key) }
            let strings = values.compactMap(\.stringValue)
            guard strings.count == values.count else { throw AgentMobileGatewayCommandError.invalidAction(key) }
            return strings
        }
        let skills = try ids("skills")
        let experts = try ids("experts")
        let plugins = try ids("plugins")
        if let skills, skills.count > 16 || skills.contains(where: { id in !entries.contains { $0.identifier == id && $0.source != .plugin } }) {
            throw AgentMobileGatewayCommandError.invalidAction("skills")
        }
        if let experts, experts.contains(where: { AgentExpert(rawValue: $0) == nil }) {
            throw AgentMobileGatewayCommandError.invalidAction("experts")
        }
        if let experts, !canDeactivateAgentExperts(), !agentActiveExperts.isSubset(of: Set(experts.compactMap(AgentExpert.init(rawValue:)))) {
            throw AgentMobileGatewayCommandError.invalidAction("experts cannot be removed after the conversation has started")
        }
        let pluginIDs = Set(mobileGatewayCapabilities.plugins.map(\.id))
        if let plugins, !Set(plugins).isSubset(of: pluginIDs) { throw AgentMobileGatewayCommandError.invalidAction("plugins") }
        // 用替换语义处理多选，取消勾选也必须落到真实 composer 上。
        if skills != nil || plugins != nil {
            for entry in agentPendingSkills where (entry.source == .plugin ? plugins != nil : skills != nil) {
                detachAgentSkill(identifier: entry.identifier)
            }
        }
        if let experts {
            for expert in agentActiveExperts where !experts.contains(expert.rawValue) { _ = deactivateAgentExpert(expert) }
        }
        applyMobileGatewayRunContext(
            providerID: patch["provider_id"]?.stringValue, modelID: patch["model"]?.stringValue,
            approvalModeID: patch["approval_mode"]?.stringValue, skillIDs: skills ?? [], expertIDs: experts ?? [], pluginIDs: plugins ?? []
        )
        persistActiveAgentSession()
        return .ok(sessionID: runtime.id)
    }

    func mobileGatewayStopTurn(sessionID: UUID?) throws -> AgentMobileGatewayCommandResult {
        if let sessionID {
            guard mobileGatewaySelectSession(id: sessionID) else {
                throw AgentMobileGatewayCommandError.sessionNotFound(sessionID)
            }
        }
        stopAgentResponse()
        return .ok(sessionID: activeAgentSessionID)
    }

    func mobileGatewayDecideTool(
        sessionID: UUID?,
        toolID: String,
        approved: Bool,
        typedConfirmation: String?,
        answer: String?
    ) throws -> AgentMobileGatewayCommandResult {
        let runtime = try mobileGatewayRuntime(sessionID: sessionID)
        guard let index = runtime.toolCalls.firstIndex(where: { call in
            call.id.uuidString == toolID || call.externalID == toolID
        }) else {
            throw AgentMobileGatewayCommandError.toolNotFound(toolID)
        }
        let call = runtime.toolCalls[index]
        guard call.status == .pendingApproval || call.status == .awaitingConfirm || call.status == .awaitingUserAnswer else {
            throw AgentMobileGatewayCommandError.toolNotPending(toolID)
        }

        let decision: AgentToolDecision
        if approved {
            switch call.status {
            case .awaitingConfirm:
                guard typedConfirmation?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "confirm" else {
                    throw AgentMobileGatewayCommandError.confirmationRequired(toolID)
                }
                decision = .approved
            case .awaitingUserAnswer:
                guard let answer = answer?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty else {
                    throw AgentMobileGatewayCommandError.missingAnswer
                }
                decision = .answered(answer)
            default:
                decision = .approved
            }
        } else {
            decision = .denied(reason: "Denied from Android")
        }

        resolveAgentToolCallDecision(id: call.id, decision: decision)
        return .ok(sessionID: runtime.id, message: approved ? "Tool approved" : "Tool rejected")
    }

    func mobileGatewayDecidePatch(
        sessionID: UUID?,
        patchID: UUID,
        approved: Bool
    ) throws -> AgentMobileGatewayCommandResult {
        if let sessionID {
            guard mobileGatewaySelectSession(id: sessionID) else {
                throw AgentMobileGatewayCommandError.sessionNotFound(sessionID)
            }
        }
        guard let proposal = agentPatchProposals.first(where: {
            $0.id == patchID && $0.status == .pending
        }) else {
            throw AgentMobileGatewayCommandError.patchNotFound(patchID)
        }
        if activeRuntime?.collectingPatchReviewMessageIDs.contains(proposal.messageID) == true {
            throw AgentMobileGatewayCommandError.patchBatchCollecting(patchID)
        }
        let pendingBatchCount = agentPatchProposals.filter {
            $0.messageID == proposal.messageID && $0.status == .pending
        }.count
        if approved {
            applyAgentPatchProposals(forMessageID: proposal.messageID)
            guard let finalProposal = agentPatchProposals.first(where: {
                $0.id == patchID
            }) else {
                throw AgentMobileGatewayCommandError.patchNotFound(patchID)
            }
            guard finalProposal.status == .applied else {
                throw AgentMobileGatewayCommandError.patchApplyFailed(
                    patchID,
                    finalProposal.statusMessage ?? "unknown error"
                )
            }
        } else {
            rejectAgentPatchProposals(forMessageID: proposal.messageID)
        }
        let scope = pendingBatchCount > 1 ? "Patch batch" : "Patch"
        return .ok(
            sessionID: activeAgentSessionID,
            message: approved ? "\(scope) approved" : "\(scope) rejected"
        )
    }

    func mobileGatewayDiff(
        sessionID: UUID?,
        patchID: UUID
    ) throws -> AgentMobileGatewayDiffSnapshot {
        let runtime: AgentRuntime
        if let sessionID {
            runtime = try mobileGatewayRuntime(sessionID: sessionID)
        } else if let found = agentRuntimes.values.first(where: { runtime in
            runtime.patchProposals.contains(where: { $0.id == patchID })
        }) {
            runtime = found
        } else {
            throw AgentMobileGatewayCommandError.patchNotFound(patchID)
        }

        guard let proposal = runtime.patchProposals.first(where: { $0.id == patchID && $0.status == .pending }) else {
            throw AgentMobileGatewayCommandError.patchNotFound(patchID)
        }
        return AgentMobileGatewayDiffSnapshot(
            patchID: proposal.id,
            title: proposal.title,
            diff: proposal.diff,
            sessionID: runtime.id
        )
    }

    func mobileGatewayKillJob(
        sessionID: UUID?,
        jobID: String
    ) throws -> AgentMobileGatewayCommandResult {
        let runtime = try mobileGatewayRuntime(sessionID: sessionID)
        guard let job = agentJobRegistry.job(matchingHandle: jobID, runtimeID: runtime.id) else {
            throw AgentMobileGatewayCommandError.jobNotFound(jobID)
        }
        let didSignal = agentJobRegistry.kill(id: job.id)
        return .ok(
            sessionID: runtime.id,
            message: didSignal ? "Job killed" : "Job was not running"
        )
    }

    func mobileGatewayReadFile(
        sessionID: UUID?,
        path: String,
        maxBytes: Int?
    ) throws -> AgentMobileGatewayFileSnapshot {
        let runtime = try mobileGatewayRuntime(sessionID: sessionID)
        let workspaceURL: URL?
        do {
            workspaceURL = try runtime.localWorkspaceURLForOptimisticUse()
        } catch {
            throw AgentMobileGatewayCommandError.workspaceUnavailable(error.localizedDescription)
        }
        guard let root = workspaceURL else {
            throw AgentMobileGatewayCommandError.noWorkspace
        }
        let rootPath = root.path
        let requestedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetURL: URL
        if (requestedPath as NSString).isAbsolutePath {
            targetURL = URL(fileURLWithPath: requestedPath).standardizedFileURL
        } else {
            targetURL = root.appendingPathComponent(requestedPath).standardizedFileURL
        }
        let targetPath = targetURL.path
        guard targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") else {
            throw AgentMobileGatewayCommandError.pathOutsideWorkspace(path)
        }
        // The phone reads through the same boundary as the agent: a symlink
        // inside the workspace must not turn into a read of ~/.ssh.
        guard AgentWorkspacePathGuard.containingRoot(for: targetURL, roots: [root]) != nil else {
            throw AgentMobileGatewayCommandError.pathOutsideWorkspace(path)
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: targetPath, isDirectory: &isDirectory) else {
            if let availability = runtime.diagnoseLocalWorkspaceAfterFailure(),
               availability.blocksLocalWorkspaceUse,
               let message = availability.message {
                persistAgentSession(runtime: runtime)
                throw AgentMobileGatewayCommandError.workspaceUnavailable(message)
            }
            throw AgentMobileGatewayCommandError.fileNotFound(path)
        }
        guard !isDirectory.boolValue else {
            throw AgentMobileGatewayCommandError.notRegularFile(path)
        }
        guard !Self.isBinaryFile(at: targetURL) else {
            throw AgentMobileGatewayCommandError.binaryFile(path)
        }

        let limit = max(1, min(maxBytes ?? Self.mobileGatewayDefaultReadBytes, Self.mobileGatewayAbsoluteMaxReadBytes))
        let handle = try FileHandle(forReadingFrom: targetURL)
        defer { try? handle.close() }
        let data = handle.readData(ofLength: limit + 1)
        let truncated = data.count > limit
        let usable = truncated ? Data(data.prefix(limit)) : data
        let content = String(data: usable, encoding: .utf8) ?? Self.decodeText(from: usable)
        return AgentMobileGatewayFileSnapshot(
            path: Self.mobileGatewayRelativePath(for: targetURL, rootPath: rootPath),
            content: content,
            truncated: truncated,
            byteCount: usable.count,
            sessionID: runtime.id
        )
    }

    func mobileGatewayUpdateQueue(
        sessionID: UUID?,
        action: String,
        messageID: UUID?,
        text: String?,
        images: [AgentImageAttachment]
    ) throws -> AgentMobileGatewayCommandResult {
        let runtime = try mobileGatewayRuntime(sessionID: sessionID)
        defer { persistAgentSession(runtime: runtime, touchUpdatedAt: false, moveToFront: false) }
        let normalizedAction = action
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")

        switch normalizedAction {
        case "edit", "update":
            guard let messageID,
                  let index = runtime.queuedMessages.firstIndex(where: {
                      $0.id == messageID && $0.source == .operatorInput
                  }) else {
                throw AgentMobileGatewayCommandError.queueMessageChanged
            }
            let message = runtime.queuedMessages[index]
            guard let text, text.utf8.count <= 1024 * 1024,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !message.images.isEmpty || !message.textAttachments.isEmpty else {
                throw AgentMobileGatewayCommandError.missingText
            }
            guard Self.mobileGatewayEditableQueueText(message.text) != nil else {
                throw AgentMobileGatewayCommandError.queueMessageChanged
            }
            runtime.queuedMessages[index].independentOfHumanWait = nil
            runtime.deferredDependencyChecks.removeValue(forKey: messageID)
            if AgentAttachedPromptDisplay.transform(message.text).isSplicedPrelude,
               let boundary = message.text.range(of: AgentAttachedPromptProtocol.userTextBoundary, options: .backwards) {
                runtime.queuedMessages[index].text = String(message.text[..<boundary.upperBound]) + "\n\n" + text
            } else {
                runtime.queuedMessages[index].text = text
            }
            return .ok(sessionID: runtime.id, message: "Queued message updated")
        case "add":
            let prompt = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !prompt.isEmpty || !images.isEmpty else {
                throw AgentMobileGatewayCommandError.missingText
            }
            runtime.queuedMessages.append(AgentQueuedMessage(text: prompt, images: images))
            return .ok(sessionID: runtime.id, message: "Queued message added")

        case "clear":
            runtime.queuedMessages.removeAll { $0.source == .operatorInput }
            runtime.shouldConsumeQueueAfterStop = false
            return .ok(sessionID: runtime.id, message: "Queue cleared")

        case "remove", "delete":
            guard let messageID else {
                throw AgentMobileGatewayCommandError.missingID("queue.update")
            }
            guard let index = runtime.queuedMessages.firstIndex(where: { $0.id == messageID && $0.source == .operatorInput }) else {
                throw AgentMobileGatewayCommandError.queueMessageNotFound(messageID)
            }
            runtime.queuedMessages.remove(at: index)
            if runtime.queuedMessages.isEmpty {
                runtime.shouldConsumeQueueAfterStop = false
            }
            return .ok(sessionID: runtime.id, message: "Queued message removed")

        case "send_now", "run_independently":
            guard let messageID else {
                throw AgentMobileGatewayCommandError.missingID("queue.update")
            }
            guard let index = runtime.queuedMessages.firstIndex(where: { $0.id == messageID && $0.source == .operatorInput }) else {
                throw AgentMobileGatewayCommandError.queueMessageNotFound(messageID)
            }
            let message = runtime.queuedMessages.remove(at: index)
            runtime.queuedMessages.insert(message, at: 0)
            if activeAgentSessionID != runtime.id {
                selectAgentSession(id: runtime.id)
            }
            if normalizedAction == "run_independently" { runQueuedAgentMessageIndependently(id: messageID) }
            else { sendQueuedAgentMessageNow(id: messageID) }
            return .ok(sessionID: runtime.id, message: "Queued message sent")

        default:
            throw AgentMobileGatewayCommandError.invalidAction(action)
        }
    }

    private func mobileGatewayRuntime(sessionID: UUID?) throws -> AgentRuntime {
        if let sessionID {
            guard let runtime = runtime(for: sessionID) else {
                throw AgentMobileGatewayCommandError.sessionNotFound(sessionID)
            }
            return runtime
        }
        guard let runtime = activeRuntime else {
            throw AgentMobileGatewayCommandError.invalidSessionID("")
        }
        return runtime
    }

    private func mobileGatewayToolTitle(for call: AgentToolCall) -> String {
        switch call.status {
        case .awaitingConfirm:
            return "\(call.toolName) requires confirmation"
        case .awaitingUserAnswer:
            return call.toolName == "ask_user" ? "Agent asks a question" : call.toolName
        default:
            return call.toolName
        }
    }

    private func mobileGatewayToolSummary(for call: AgentToolCall) -> String {
        switch call.status {
        case .pendingApproval:
            return "Waiting for approval"
        case .awaitingConfirm:
            return "Danger-tier tool requires typed confirmation on the Mac protocol."
        case .awaitingUserAnswer:
            return "Waiting for your answer"
        default:
            return ""
        }
    }

    private static func mobileGatewayArgumentsPreview(_ arguments: [String: AgentJSONValue]) -> String {
        guard !arguments.isEmpty else { return "" }
        let object = arguments.mapValues(\.rawAny)
        if JSONSerialization.isValidJSONObject(object),
           let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return mobileGatewayTruncated(text)
        }
        return mobileGatewayTruncated(arguments.map { "\($0.key): \($0.value.displaySummary)" }.sorted().joined(separator: ", "))
    }

    private static func mobileGatewayPatchPath(from diff: String) -> String {
        for line in diff.split(separator: "\n") {
            if line.hasPrefix("+++ b/") {
                return String(line.dropFirst(6))
            }
            if line.hasPrefix("--- a/") {
                return String(line.dropFirst(6))
            }
        }
        return ""
    }

    private static func mobileGatewayPatchStats(from diff: String) -> String {
        var added = 0
        var deleted = 0
        for line in diff.split(separator: "\n") {
            guard !line.hasPrefix("+++") && !line.hasPrefix("---") else { continue }
            if line.hasPrefix("+") {
                added += 1
            } else if line.hasPrefix("-") {
                deleted += 1
            }
        }
        return "+\(added) -\(deleted)"
    }

    private static func mobileGatewayEditableQueueText(_ text: String) -> String? {
        let display = AgentAttachedPromptDisplay.transform(text)
        if display.isSplicedPrelude && !text.contains(AgentAttachedPromptProtocol.userTextBoundary) {
            return nil
        }
        return AgentAttachedPromptDisplay.composerText(of: text)
    }

    private static func mobileGatewayQueuedTextPreview(_ message: AgentQueuedMessage) -> String {
        // Same rule as the desktop queue card: the queue stores the composed
        // prompt, so an attached turn would otherwise ship the English
        // model-facing prelude to the phone instead of the user's sentence.
        if let spliced = AgentAttachedPromptDisplay.singleLinePreview(of: message.text) {
            return mobileGatewayTruncated(spliced)
        }
        let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return mobileGatewayTruncated(trimmed)
        }
        if !message.textAttachments.isEmpty {
            return "\(message.textAttachments.count) text attachments"
        }
        if !message.images.isEmpty {
            return "\(message.images.count) images"
        }
        return "Queued message"
    }

    private static let mobileGatewayMaxRecentMessagesPerSession = 40
    private static let mobileGatewayMaxMessageCharacters = 12_000

    private static func mobileGatewayMessageContentPreview(_ message: AgentMessage) -> String {
        var blocks: [String] = []
        // User turns are stored as the model-facing prompt: skill routing
        // candidates, skill bodies and file envelopes spliced in front of what
        // the operator typed. The phone must see the same thing the desktop
        // bubble does, never the protocol header and prelude.
        let displayContent = message.role == .user
            ? AgentAttachedPromptDisplay.transform(message.content).visibleContent
            : message.content
        let trimmed = displayContent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            blocks.append(trimmed)
        }
        if message.role == .user {
            if !message.images.isEmpty {
                blocks.append("[\(message.images.count) images]")
            }
            if !message.textAttachments.isEmpty {
                let names = message.textAttachments
                    .map(\.displayName)
                    .prefix(3)
                    .joined(separator: ", ")
                blocks.append("[attachments: \(names)]")
            }
        }
        let joined = blocks.joined(separator: "\n\n")
        if joined.count <= mobileGatewayMaxMessageCharacters {
            return joined
        }
        return String(joined.prefix(mobileGatewayMaxMessageCharacters))
            .trimmingCharacters(in: .whitespacesAndNewlines) + "\n..."
    }

    private static let mobileGatewayDefaultReadBytes = 64 * 1024
    private static let mobileGatewayAbsoluteMaxReadBytes = 256 * 1024

    private static func mobileGatewayRelativePath(for url: URL, rootPath: String) -> String {
        let path = url.standardizedFileURL.path
        guard path == rootPath || path.hasPrefix(rootPath + "/") else { return path }
        return String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func mobileGatewayTruncated(_ text: String, limit: Int = 300) -> String {
        if text.count <= limit { return text }
        return String(text.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }
}
