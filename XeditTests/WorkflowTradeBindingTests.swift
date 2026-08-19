//
//  WorkflowTradeBindingTests.swift
//  WillDeepTests
//
//  Workflow fan-out steps bound to narrow trades (skill-workers.v1 Phase 2 §7).
//

import Foundation
import Testing
@testable import WillDeep

@Suite
struct WorkflowTradeBindingTests {
    /// Tools a file-picking step needs. Annotating a workflow step with a
    /// trade whose whitelist misses one of these would get it denied mid-run,
    /// which is why the rule is "only annotate steps that fit inside a trade".
    private let filePickingTools: Set<String> = ["search_files", "list_directory", "read_file"]

    @Test("scout covers what a file-picking workflow step needs")
    func scoutCoversFilePicking() {
        let scout = AgentSubagentProfileCatalog.scout

        #expect(filePickingTools.isSubset(of: scout.effectiveToolNames(writeAccessGranted: false)))
    }

    @Test("a picking step must not be annotated with a trade that lacks the shell")
    func scoutHasNoShell() {
        // Documents the boundary the annotation rule protects: any step that
        // shells out (gh, git, build tooling) must stay on a trade that
        // actually carries `run_command`.
        #expect(!AgentSubagentProfileCatalog.scout
            .effectiveToolNames(writeAccessGranted: false).contains("run_command"))
        #expect(AgentSubagentProfileCatalog.deep
            .effectiveToolNames(writeAccessGranted: false).contains("run_command"))
    }

    @Test("every built-in trade carries a localized name, not a raw id")
    func everyTradeIsNamed() {
        // The stats dashboard and the settings list both enumerate `builtIn`,
        // so a trade added without a display-name case silently shows up as
        // its English id in a Chinese UI. This has already happened twice.
        for trade in AgentSubagentProfileCatalog.builtIn {
            let name = trade.localizedDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(!name.isEmpty, "\(trade.id) has no display name")
            #expect(name != trade.id, "\(trade.id) falls back to its raw id")
            #expect(!trade.localizedPurpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "\(trade.id) has no purpose text")
        }
    }

    @Test("deep stays the default so unannotated steps are unchanged")
    func deepRemainsTheDefault() {
        // Every workflow step that names no trade keeps running exactly as it
        // did before trades existed — the migration is opt-in per step.
        #expect(AgentSubagentProfileCatalog.profile(id: nil).id == AgentSubagentProfileCatalog.deepID)
        // deep is now pinned to the 1M tier rather than inheriting whatever
        // the provider's primary model happens to be — that is what makes an
        // escalation to it mean something.
        #expect(AgentSubagentProfileCatalog.deep.modelBinding.model == "deepseek-v4-flash")
    }
}
