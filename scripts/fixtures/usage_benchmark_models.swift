// Isolated scalar workload models for the SQLite microbenchmark only.
// Nested worker records are empty fixtures; production round trips are tested in AgentUsageSidecarTests.
import Foundation
struct AgentHostWorkerRunRecord: Equatable, Codable {}
struct AgentSubagentRunUsage: Equatable, Codable {}
struct AgentAuxiliaryModelRequestRecord: Equatable, Codable {}
enum AgentRole: String, Codable { case user, assistant, tool, system }
enum AgentToolCallStatus: String, Codable { case succeeded, failed }
enum AgentMessageOrigin: String, Codable { case manual }
nonisolated struct AgentUsageSessionSnapshot: Identifiable, Equatable, Codable {
    let id: UUID
    var modelID: String?
    var providerID: String?
    var providerDisplayName: String?
    var createdAt: Date
    var updatedAt: Date
    var messages: [AgentUsageMessageSnapshot]
    var hostWorkerRuns: [AgentHostWorkerRunRecord]?
    /// Runs the coordinator started without a `spawn_agent` tool call.
    /// See `AgentSession.coordinatorWorkerRuns`.
    var coordinatorWorkerRuns: [AgentSubagentRunUsage]?
    var auxiliaryModelRequests: [AgentAuxiliaryModelRequestRecord]
    var workspaceIdentifier: String?
    var editedFileCount: Int
    var artifactCount: Int
    var artifactPaths: [String]
    /// True when this session ran under 省心托管 (some.im managed routing).
    /// Managed sessions never persist a resolved `modelID` (it's cleared in
    /// `AppStateAgentSessions` because routing is per-turn), so without this
    /// flag their usage collapses into the anonymous "unknown-model" bucket
    /// alongside genuinely-unknown legacy sessions. We carry the signal so
    /// managed traffic can be attributed to a single "省心托管" pseudo-model
    /// instead — and legacy nils stay unknown.
    var isManagedRouting: Bool

    init(
        id: UUID,
        modelID: String?,
        providerID: String?,
        providerDisplayName: String?,
        createdAt: Date,
        updatedAt: Date,
        messages: [AgentUsageMessageSnapshot],
        hostWorkerRuns: [AgentHostWorkerRunRecord]? = nil,
        coordinatorWorkerRuns: [AgentSubagentRunUsage]? = nil,
        auxiliaryModelRequests: [AgentAuxiliaryModelRequestRecord] = [],
        workspaceIdentifier: String? = nil,
        editedFileCount: Int = 0,
        artifactCount: Int = 0,
        artifactPaths: [String] = [],
        isManagedRouting: Bool = false
    ) {
        self.id = id
        self.modelID = modelID
        self.providerID = providerID
        self.providerDisplayName = providerDisplayName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.hostWorkerRuns = hostWorkerRuns
        self.coordinatorWorkerRuns = coordinatorWorkerRuns
        self.auxiliaryModelRequests = auxiliaryModelRequests
        self.workspaceIdentifier = workspaceIdentifier
        self.editedFileCount = editedFileCount
        self.artifactCount = artifactCount
        self.artifactPaths = artifactPaths
        self.isManagedRouting = isManagedRouting
    }




}

nonisolated struct AgentUsageMessageSnapshot: Equatable, Codable {
    var id: UUID?
    var role: AgentRole
    var isOperatorInput: Bool?
    /// Profile selected from the operator's raw request when the usage sidecar
    /// was built. The raw text is not duplicated into analytics.
    var workerRouteProfileID: String?
    var contentCharacterCount: Int
    var reasoningCharacterCount: Int
    var imageCount: Int
    var toolCallArgumentCharacterCount: Int
    var toolCallNames: [String]
    var toolCallExternalIDs: [String]
    /// Normalized profile ids for `spawn_agent` calls on this message.
    /// Missing/unknown profile arguments resolve to `deep`, matching the
    /// runtime's backwards-compatible execution rule.
    var subagentProfileIDs: [String]
    /// What the `spawn_agent` runs on this message actually cost and whether
    /// they verified. Empty while a run is still going, and for every session
    /// recorded before worker accounting existed — those keep reporting only
    /// the parent's tokens, which is honest: we never had the child's.
    var subagentRuns: [AgentSubagentRunUsage]
    var toolCallID: String?
    var toolCallStatus: AgentToolCallStatus?
    var toolErrorMessage: String?
    var usageTokens: Int?
    var promptTokens: Int?
    var completionTokens: Int?
    var cachedPromptTokens: Int?
    var cacheWritePromptTokens: Int?
    var reasoningTokens: Int?
    var origin: AgentMessageOrigin?
    var originLabel: String?
    var requestModelID: String?
    var requestProviderID: String?
    var requestProviderDisplayName: String?
    var requestStablePrefixCharacters: Int?
    var elapsedSeconds: Double?
    var firstResponseSeconds: Double?
    var requestIsLocal: Bool?
    var createdAt: Date

    init(
        id: UUID? = nil,
        role: AgentRole,
        isOperatorInput: Bool? = nil,
        workerRouteProfileID: String? = nil,
        contentCharacterCount: Int,
        reasoningCharacterCount: Int = 0,
        imageCount: Int = 0,
        toolCallArgumentCharacterCount: Int = 0,
        toolCallNames: [String] = [],
        toolCallExternalIDs: [String] = [],
        subagentProfileIDs: [String] = [],
        subagentRuns: [AgentSubagentRunUsage] = [],
        toolCallID: String? = nil,
        toolCallStatus: AgentToolCallStatus? = nil,
        toolErrorMessage: String? = nil,
        usageTokens: Int? = nil,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        cachedPromptTokens: Int? = nil,
        cacheWritePromptTokens: Int? = nil,
        reasoningTokens: Int? = nil,
        origin: AgentMessageOrigin? = nil,
        originLabel: String? = nil,
        requestModelID: String? = nil,
        requestProviderID: String? = nil,
        requestProviderDisplayName: String? = nil,
        requestStablePrefixCharacters: Int? = nil,
        elapsedSeconds: Double? = nil,
        firstResponseSeconds: Double? = nil,
        requestIsLocal: Bool? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.role = role
        self.isOperatorInput = isOperatorInput
        self.workerRouteProfileID = workerRouteProfileID
        self.contentCharacterCount = contentCharacterCount
        self.reasoningCharacterCount = reasoningCharacterCount
        self.imageCount = imageCount
        self.toolCallArgumentCharacterCount = toolCallArgumentCharacterCount
        self.toolCallNames = toolCallNames
        self.toolCallExternalIDs = toolCallExternalIDs
        self.subagentProfileIDs = subagentProfileIDs
        self.subagentRuns = subagentRuns
        self.toolCallID = toolCallID
        self.toolCallStatus = toolCallStatus
        self.toolErrorMessage = toolErrorMessage
        self.usageTokens = usageTokens
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.cachedPromptTokens = cachedPromptTokens
        self.cacheWritePromptTokens = cacheWritePromptTokens
        self.reasoningTokens = reasoningTokens
        self.origin = origin
        self.originLabel = originLabel
        self.requestModelID = requestModelID
        self.requestProviderID = requestProviderID
        self.requestProviderDisplayName = requestProviderDisplayName
        self.requestStablePrefixCharacters = requestStablePrefixCharacters
        self.elapsedSeconds = elapsedSeconds
        self.firstResponseSeconds = firstResponseSeconds
        self.requestIsLocal = requestIsLocal
        self.createdAt = createdAt
    }




}
