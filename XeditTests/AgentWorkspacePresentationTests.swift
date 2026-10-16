import Foundation
import Testing
@testable import WillDeep

@Suite(.serialized) @MainActor struct AgentWorkspacePresentationTests {
    private func package() throws -> AgentPackageV1 {
        try AgentPackageV1.unsigned(AgentDefinitionV1(schema: AgentDefinitionV1.schemaID, definition_id: "user/workspace-test",
            version: "1.0.0-rc1", name: ["en": "Reviewer"], purpose: "Review files.", base_role: "reviewer",
            instructions: "Read files and report evidence.", input_modalities: ["text"], tools: ["workspace.read"], skills: [], forked_from: nil))
    }
    @Test func remarksAreAccountScopedAndNeverEnterCandidateOrInstalledRevision() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "workspace-test-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let library = AgentDefinitionLibrary(root: root.appendingPathComponent("library"), defaults: defaults)
        let baseline = try package(), installed = try library.install(baseline, source: .local)
        let before = try baseline.encoded(), candidate = try AgentRSIOfflineRunner.candidate(baseline: baseline, instructions: "Read and verify evidence.", version: "1.0.0-rc2")
        let a = AgentRSIStore(root: root.appendingPathComponent("rsi"), owner: "account-A")
        let b = AgentRSIPresentationStore(store: .init(root: a.root, owner: "account-B"))
        try a.save(candidate, entity: "candidate")
        let id = try #require(candidate["candidate_id"].text)
        try AgentRSIPresentationStore(store: a).save(label: "Only on this Mac", candidateID: id)
        #expect(try b.label(candidateID: id) == nil)
        #expect(try AgentRSIPresentationStore(store: a).label(candidateID: id) == "Only on this Mac")
        #expect(try a.values(entity: "candidate") == [candidate])
        #expect(!candidate.canonical.contains("Only on this Mac"))
        #expect(try library.package(revision: installed.selected).encoded() == before)
        #expect(try library.visibleInstallations().first?.selected == baseline.sha256)
        #expect(throws: (any Error).self) { try AgentRSIPresentationStore(store: a).save(label: String(repeating: "x", count: 121), candidateID: id) }
    }
    @Test func remarksRejectSymlinkFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentRSIStore(root: root, owner: "account-A")
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("outside.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: store.directory.appendingPathComponent("presentation.json"), withDestinationURL: target)
        #expect(throws: (any Error).self) { try AgentRSIPresentationStore(store: store).save(label: "blocked", candidateID: "candidate") }
        #expect(try Data(contentsOf: target) == Data("{}".utf8))
    }
    @Test func sourceAndNameSearchAreIndependent() {
        #expect(AgentWorkspacePresentation.matches(name: "文档审查", id: "user/reviewer", query: "文档"))
        #expect(AgentWorkspacePresentation.matches(name: "Reviewer", id: "user/reviewer", query: "REVIEW"))
        #expect(!AgentWorkspacePresentation.matches(name: "Reviewer", id: "user/reviewer", query: "missing"))
        #expect(AgentWorkspacePresentation.matchesSource("private", filter: "all"))
        #expect(!AgentWorkspacePresentation.matchesSource("official", filter: "local"))
        #expect(AgentWorkspacePresentation.matchesSource("official", filter: "official"))
    }
    @Test func officialAndSignedBaselinesRequireFork() throws {
        let user = try package()
        #expect(AgentWorkspacePresentation.eligible(user))
        var signed = user; signed.signature = .init(key_id: "fixture", value: String(repeating: "0", count: 128))
        #expect(!AgentWorkspacePresentation.eligible(signed))
        var official = user.definition; official.definition_id = "official/reviewer"
        #expect(!AgentWorkspacePresentation.eligible(try AgentPackageV1.unsigned(official)))
        #expect(!AgentWorkspacePresentation.eligible(nil))
        #expect(AgentWorkspacePresentation.nextVersion("1.0.0-rc1") == "1.0.0-rc2")
        #expect(AgentWorkspacePresentation.nextVersion("1.0.0") == "1.0.0-rc1")
    }
    @Test func dirtyNavigationRequiresExplicitDiscardAndAccountSwitchClearsBaseline() throws {
        let navigation = AgentWorkspaceNavigation()
        navigation.select(.experiments, baseline: try package())
        navigation.dirtySections.insert(.experiments)
        navigation.select(.library)
        #expect(navigation.section == .experiments && navigation.baseline != nil)
        #expect(navigation.pending?.section == .library)
        navigation.pending = nil // Cancel keeps the editor and baseline.
        #expect(navigation.baseline != nil && navigation.dirtySections.contains(.experiments))
        navigation.select(.library); navigation.discardAndContinue()
        #expect(navigation.section == .library && navigation.pending == nil)
        navigation.select(.experiments, baseline: try package())
        navigation.dirtySections.insert(.experiments); navigation.select(.library)
        let epoch = navigation.accountEpoch
        NotificationCenter.default.post(name: SomeIMIntegrationStore.sessionDidChangeNotification, object: nil)
        #expect(navigation.baseline == nil && navigation.pending == nil && navigation.dirtySections.isEmpty)
        #expect(navigation.accountEpoch != epoch)
    }
    @Test func loadingHistoricalCandidateUpdatesNavigationWithoutActivatingInstalledHead() throws {
        let navigation = AgentWorkspaceNavigation(), old = try package()
        var revised = old.definition; revised.version = "1.0.0-rc2"; revised.instructions += " Verify the result."
        let current = try AgentPackageV1.unsigned(revised)
        navigation.select(.experiments, baseline: current)
        navigation.didLoadCandidateBaseline(old)
        #expect(navigation.baseline?.sha256 == old.sha256)
        navigation.select(.experiments, baseline: current)
        #expect(navigation.baseline?.sha256 == current.sha256)
    }
    @Test func accountEpochRejectsLateResultsEvenAfterReturningToSameAccount() throws {
        let epoch = UUID(), scope = AgentWorkspaceOperationScope(owner: "A", epoch: epoch)
        try scope.validate(owner: "A", epoch: epoch)
        #expect(throws: AgentRSIError.ownerChanged) { try scope.validate(owner: "B", epoch: epoch) }
        #expect(throws: AgentRSIError.ownerChanged) { try scope.validate(owner: "A", epoch: UUID()) }
    }
    @Test func experimentDatesComeOnlyFromMatchingActualEvidence() {
        let experiment = AgentCanonicalJSON.object(["experiment_id": .string("exp-1")])
        let other = AgentCanonicalJSON.object(["experiment_id": .string("exp-other"), "finished_at": .string("2099-01-01T00:00:00Z")])
        #expect(AgentWorkspacePresentation.latestEvidenceDate(experiment, evidence: [other]) == nil)
        let finished = AgentCanonicalJSON.object(["experiment_id": .string("exp-1"), "finished_at": .string("2026-10-16T00:00:00Z")])
        #expect(AgentWorkspacePresentation.latestEvidenceDate(experiment, evidence: [other, finished]) == "2026-10-16T00:00:00Z")
    }
    @Test func dedicatedPreviewUsesIsolatedLibraryAndNoAccount() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try AgentWorkspacePreviewFixture(root: root)
        #expect(fixture.library.root.path.hasPrefix(root.path))
        #expect(fixture.rsiRoot.path.hasPrefix(root.path))
        #expect(fixture.library.activeAccount == nil)
        #expect(try fixture.library.visibleInstallations().count == 1)
        #expect(try fixture.library.visibleInstallations().first?.selected == fixture.baseline.sha256)
    }
    @Test func queuedOldAccountActionNeverBeginsOrCompletesInNewScope() async {
        let gate = AgentWorkspaceOperationGate(), initial = AgentWorkspaceOperationScope(owner: "A", epoch: UUID())
        let ticket = gate.begin(scope: initial)
        var started = false, completed = false
        await gate.execute(ticket, current: { .init(owner: "B", epoch: UUID()) }, action: { started = true }) { _ in completed = true }
        #expect(!started && !completed)
    }
    @Test func suspendedOldSuccessAndFailureCannotOverwriteNewAccountMessageOrBusy() async throws {
        for fails in [false, true] {
            let gate = AgentWorkspaceOperationGate()
            var current = AgentWorkspaceOperationScope(owner: "A", epoch: UUID())
            let ticket = gate.begin(scope: current)
            var release: CheckedContinuation<Void, Never>?
            var message = "A", busy = true
            let old = Task { @MainActor in
                await gate.execute(ticket, current: { current }, action: {
                    await withCheckedContinuation { release = $0 }
                    if fails { throw AgentRSIError.ownerChanged }
                }) { _ in message = "old-result"; busy = false }
            }
            for _ in 0..<100 where release == nil { await Task.yield() }
            let continuation = try #require(release)
            gate.invalidate(); current = .init(owner: "B", epoch: UUID()); message = "B"; busy = false
            current = .init(owner: "A", epoch: UUID()) // A → B → A still differs from the original scope.
            let next = gate.begin(scope: current)
            busy = true
            continuation.resume(); await old.value
            #expect(message == "B" && busy)
            // The newer operation's busy state and ticket must survive the old completion.
            var completed = false
            await gate.execute(next, current: { current }, action: {}) { _ in completed = true; busy = false }
            #expect(completed && !busy)
        }
    }
    @Test func currentScopeOperationCompletesWithActualSuccessOrFailure() async {
        for fails in [false, true] {
            let gate = AgentWorkspaceOperationGate(), current = AgentWorkspaceOperationScope(owner: "A", epoch: UUID())
            let ticket = gate.begin(scope: current)
            var completed = false
            await gate.execute(ticket, current: { current }, action: { if fails { throw AgentRSIError.invalidContract } }) { result in
                switch result {
                case .success: #expect(!fails)
                case .failure: #expect(fails)
                }
                completed = true
            }
            #expect(completed)
        }
    }
}
