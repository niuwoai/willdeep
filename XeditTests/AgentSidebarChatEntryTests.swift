//
//  AgentSidebarChatEntryTests.swift
//  WillDeepTests
//
//  The sidebar's chat row is navigation, not creation. It used to be
//  "New Chat" — the only way back to the conversation from a plugin or the
//  dispatch board, and taking it abandoned whatever chat was open.
//

import Foundation
import Testing
@testable import WillDeep

@MainActor
@Suite
struct AgentSidebarChatEntryTests {
    private func makeWorkspace() throws -> URL {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-chat-entry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return workspace
    }

    /// The reported bug: leave for a plugin, come back, and you were dropped
    /// into a brand-new chat because the only way back said "New Chat".
    @Test("returning from a plugin keeps the conversation that was open")
    func returningFromAPluginResumesTheSameSession() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let appState = AppState()
        let session = appState.startNewAgentSession(inWorkspaceAt: workspace.path)
        appState.agentPrimaryDestination = .plugin("demo.panel")

        appState.returnToAgentConversation()

        #expect(appState.agentPrimaryDestination == .conversation)
        #expect(appState.activeAgentSessionID == session.id)   // same chat, not a new one
        #expect(appState.agentSessions.count == 1)
    }

    /// Same for the other destinations that share this row's neighbourhood.
    @Test("returning from the dispatch board and scheduled tasks resumes too")
    func returningFromOtherDestinationsResumes() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let appState = AppState()
        let session = appState.startNewAgentSession(inWorkspaceAt: workspace.path)

        for destination in [AgentPrimaryDestination.dispatchBoard, .scheduledTasks, .roundtable, .pluginCenter] {
            appState.agentPrimaryDestination = destination
            appState.returnToAgentConversation()
            #expect(appState.agentPrimaryDestination == .conversation)
            #expect(appState.activeAgentSessionID == session.id)
        }

        #expect(appState.agentSessions.count == 1)
    }

    /// With nothing to go back to, the row still has to land somewhere usable —
    /// so it falls back to starting a chat rather than showing an empty shell.
    @Test("with no conversation open, returning starts one")
    func returningWithNothingOpenStartsAChat() {
        let appState = AppState()
        appState.agentPrimaryDestination = .pluginCenter

        #expect(!appState.hasResumableAgentConversation)
        appState.returnToAgentConversation()

        #expect(appState.agentPrimaryDestination == .conversation)
        #expect(appState.activeAgentSessionID != nil)
    }

    /// `activeAgentSessionID` can outlive the session it names. Navigating to a
    /// conversation that no longer exists would show an empty shell, so a
    /// dangling id counts as nothing to resume.
    @Test("a dangling active session id does not count as resumable")
    func danglingActiveSessionIDIsNotResumable() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let appState = AppState()
        let session = appState.startNewAgentSession(inWorkspaceAt: workspace.path)
        #expect(appState.hasResumableAgentConversation)

        // Drop the session while leaving the id pointing at it.
        appState.agentSessions.removeAll { $0.id == session.id }
        #expect(appState.activeAgentSessionID == session.id)
        #expect(!appState.hasResumableAgentConversation)

        appState.returnToAgentConversation()

        #expect(appState.agentPrimaryDestination == .conversation)
        let resumed = try #require(appState.activeAgentSessionID)
        #expect(resumed != session.id)                          // a fresh one
        #expect(appState.agentSessions.contains { $0.id == resumed })
    }

    /// Navigating back closes whatever side panel the previous destination had
    /// open, matching what the other sidebar destinations already do.
    @Test("returning clears the side panel")
    func returningClearsTheSidePanel() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let appState = AppState()
        appState.startNewAgentSession(inWorkspaceAt: workspace.path)
        appState.agentSidePanelKind = .backgroundTasks
        appState.agentPrimaryDestination = .dispatchBoard

        appState.returnToAgentConversation()

        #expect(appState.agentSidePanelKind == nil)
        #expect(appState.agentSidePanelRequest == nil)
    }

    /// The trailing button on the row keeps the old behavior, so "make a new
    /// chat" did not disappear when the row stopped meaning that.
    @Test("starting a new chat still leaves the previous one behind")
    func startingANewChatStillCreatesASeparateSession() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let appState = AppState()
        let first = appState.startNewAgentSession(inWorkspaceAt: workspace.path)
        let second = appState.startNewAgentSession(inWorkspaceAt: workspace.path)

        #expect(first.id != second.id)
        #expect(appState.activeAgentSessionID == second.id)
        #expect(appState.agentPrimaryDestination == .conversation)
    }
}
