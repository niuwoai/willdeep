import Foundation

struct MagpieSessionSelectionSnapshot: Equatable {
    let providerEntryID: UUID?
    let providerID: String?
    let model: String?
    let managed: Bool

    init(_ runtime: AgentRuntime) {
        providerEntryID = runtime.sessionProviderEntryID
        providerID = runtime.sessionProviderIDOverride
        model = runtime.sessionModelOverride
        managed = runtime.managedRouting != nil
    }
}

extension AppState {
    /// Only this projection contains the temporary entry. Settings editing and all
    /// persistence continue to use agentProviderLibrary, never this value.
    var effectiveAgentProviderLibrary: AgentProviderLibrary {
        var library = agentProviderLibrary
        if let entry = magpieProviderEntry { library.entries.append(entry) }
        return library
    }

    var magpieIntegrationFailure: AgentMagpieIntegration.Failure? {
        if agentProviderLibrary.entries.contains(where: { $0.id == AgentMagpieIntegration.providerEntryID }) {
            return .init(code: .conflict)
        }
        if case .invalid(let error) = magpieIntegrationState { return error }
        return nil
    }

    var magpieProviderEntry: AgentProviderEntry? {
        guard magpieIntegrationFailure == nil, case .connected(let connection) = magpieIntegrationState else { return nil }
        var entry = AgentProviderEntry(
            id: AgentMagpieIntegration.providerEntryID,
            providerID: AgentProviderPreset.customID,
            displayName: "Magpie",
            baseURL: connection.baseURL,
            apiKey: AgentMagpieIntegration.clientMarker,
            flashPrimary: connection.model,
            proPrimary: connection.model,
            routingMode: .flash,
            customKindOverride: .openAIChat
        )
        entry.magpieConnection = connection
        return entry
    }

    @discardableResult
    func refreshMagpieIntegration() async -> AgentMagpieIntegration.State {
        guard let home = magpieIntegrationHome else { return .disconnected }
        let task: Task<AgentMagpieIntegration.State, Never>
        let refreshID: UUID
        if let running = magpieIntegrationRefreshTask, let currentID = magpieIntegrationRefreshID {
            task = running
            refreshID = currentID
        } else {
            refreshID = UUID()
            task = Task { await AgentMagpieIntegration.read(home: home) }
            magpieIntegrationRefreshTask = task
            magpieIntegrationRefreshID = refreshID
            isRefreshingMagpieIntegration = true
        }
        let state = await task.value
        // Several UI/dispatch waiters can share this read. A late waiter must
        // not clear or overwrite a newer refresh started after the first resumed.
        if magpieIntegrationRefreshID == refreshID {
            magpieIntegrationState = state
            magpieIntegrationRefreshTask = nil
            magpieIntegrationRefreshID = nil
            isRefreshingMagpieIntegration = false
        }
        return state
    }

    func scheduleMagpieIntegrationRefresh() {
        Task { [weak self] in await self?.refreshMagpieIntegration() }
    }

    func initializeMagpieIntegration() {
        guard let home = magpieIntegrationHome else { return }
        Task { [weak self] in
            do {
                try await AgentMagpieIntegration.writeSupportMarker(
                    home: home, version: AgentNetworkSupport.appVersionHeaderValue
                )
            } catch {
                // Log only the error category; never the connection JSON or markers.
                NSLog("[magpie-integration] support marker unavailable")
            }
            await self?.refreshMagpieIntegration()
        }
    }

    /// Synchronous UI entry points create a draft immediately, then resolve its
    /// default asynchronously. Dispatch waits for this task before any request.
    /// Eligibility is never reconstructed from an empty/restored legacy session.
    func prepareMagpieDefaultForNewSession(_ runtime: AgentRuntime) {
        magpieDefaultEligibleSessionIDs.insert(runtime.id)
        magpieInitialSelections[runtime.id] = MagpieSessionSelectionSnapshot(runtime)
        magpieSessionPreparationTasks[runtime.id] = Task { [weak self, weak runtime] in
            guard let self, let runtime else { return }
            await self.refreshMagpieIntegration()
            self.applyMagpieDefaultIfEligible(to: runtime)
            self.magpieSessionPreparationTasks.removeValue(forKey: runtime.id)
        }
    }

    func applyMagpieDefaultIfEligible(to runtime: AgentRuntime) {
        guard magpieDefaultEligibleSessionIDs.contains(runtime.id) else { return }
        guard magpieInitialSelections[runtime.id] == MagpieSessionSelectionSnapshot(runtime) else {
            cancelMagpieDefaultSelection(for: runtime)
            return
        }
        guard magpieIntegrationFailure == nil else { return }
        if let entry = magpieProviderEntry {
            runtime.sessionProviderEntryID = entry.id
            runtime.sessionProviderIDOverride = entry.providerID
            runtime.sessionModelOverride = entry.flashPrimary
            runtime.session.providerEntryID = entry.id
            runtime.session.providerID = entry.providerID
            runtime.session.providerDisplayName = entry.displayName
            runtime.session.modelID = entry.flashPrimary
            runtime.managedRouting = nil
            if let index = agentSessions.firstIndex(where: { $0.id == runtime.id }) {
                agentSessions[index] = runtime.session
            }
        }
        cancelMagpieDefaultSelection(for: runtime)
    }

    func cancelMagpieDefaultSelection(for runtime: AgentRuntime?) {
        guard let runtime else { return }
        magpieDefaultEligibleSessionIDs.remove(runtime.id)
        magpieInitialSelections.removeValue(forKey: runtime.id)
    }

    /// Re-read for each new execution. An in-flight turn holds its own immutable
    /// configuration, so refreshing cannot reroute or cancel that turn.
    func prepareMagpieConnectionForTurn(_ runtime: AgentRuntime) async throws {
        if let pending = magpieSessionPreparationTasks[runtime.id] { await pending.value }
        await refreshMagpieIntegration()
        applyMagpieDefaultIfEligible(to: runtime)
        if magpieDefaultEligibleSessionIDs.contains(runtime.id), let error = magpieIntegrationFailure { throw error }
        if runtime.sessionProviderEntryID == AgentMagpieIntegration.providerEntryID {
            if let error = magpieIntegrationFailure { throw error }
            guard magpieProviderEntry != nil else { throw AgentMagpieIntegration.Failure(code: .disconnected) }
        }
    }

    func magpieConfiguration(for runtime: AgentRuntime) -> AgentConfiguration {
        guard let entry = magpieProviderEntry else {
            // The facade rejects this before accounting or network work. It must
            // never fall back to a saved provider when an integration pin expires.
            var unavailable = agentConfiguration
            unavailable.apiKey = ""
            unavailable.magpieFailure = magpieIntegrationFailure ?? .init(code: .disconnected)
            return unavailable
        }
        let model = runtime.sessionModelOverride ?? runtime.session.modelID ?? entry.flashPrimary
        var configuration = entry.makeConfiguration(routingMode: .flash,
            imageDescription: agentConfiguration.imageDescription)
        configuration.model = model
        configuration.flashModel = model
        configuration.proModel = model
        if let connection = entry.magpieConnection, connection.model != model {
            // Metadata for B cannot be applied to a pinned A model.
            configuration.magpieConnection = .init(baseURL: connection.baseURL, model: model,
                contextWindow: nil, maximumOutputTokens: nil)
        }
        return configuration
    }
}
