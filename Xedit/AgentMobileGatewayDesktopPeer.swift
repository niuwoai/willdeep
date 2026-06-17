//
//  AgentMobileGatewayDesktopPeer.swift
//  WillDeep
//
//  Desktop WebSocket peer for the LAN Mobile Gateway.
//

import Combine
import Foundation

@MainActor
final class AgentMobileGatewayDesktopPeer: ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var lastErrorMessage: String?

    private weak var appState: AppState?
    private var webSocketTask: URLSessionWebSocketTask?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectBaseURL: URL?
    private var reconnectDesktopToken: String?
    private var reconnectSession: URLSession = .shared
    private var shouldReconnect = false
    private var appStateCancellable: AnyCancellable?
    private var snapshotTask: Task<Void, Never>?
    private var messageEventState = AgentMobileGatewayMessageEventState()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(appState: AppState) {
        self.appState = appState
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.appStateCancellable = appState.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleSnapshot()
            }
        }
    }

    func connect(baseURL: URL, desktopToken: String, session: URLSession = .shared) {
        disconnect()
        shouldReconnect = true
        reconnectBaseURL = baseURL
        reconnectDesktopToken = desktopToken
        reconnectSession = session
        open(baseURL: baseURL, desktopToken: desktopToken, session: session)
    }

    func disconnect() {
        shouldReconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil
        snapshotTask?.cancel()
        snapshotTask = nil
        messageEventState.reset()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
        reconnectBaseURL = nil
        reconnectDesktopToken = nil
        reconnectSession = .shared
    }

    func publishSnapshot() {
        guard let appState else { return }
        let respondingSessionIDs = Set(
            appState.mobileGatewaySessions
                .filter { appState.mobileGatewayRuntimeIsResponding(sessionID: $0.id) }
                .map(\.id)
        )
        for event in messageEventState.envelopes(
            for: appState.mobileGatewayRecentMessages,
            respondingSessionIDs: respondingSessionIDs
        ) {
            send(event)
        }
        send(AgentMobileGatewayCommandRouter.snapshotEnvelope(controller: appState))
        send(AgentMobileGatewayCommandRouter.workspaceListEnvelope(controller: appState))
        for approval in appState.mobileGatewayPendingToolApprovals {
            send(AgentMobileGatewayCommandRouter.toolPendingEnvelope(approval))
        }
        for proposal in appState.mobileGatewayPendingPatchProposals {
            send(AgentMobileGatewayCommandRouter.patchUpsertEnvelope(proposal))
        }
        for job in appState.mobileGatewayJobs {
            send(AgentMobileGatewayCommandRouter.jobUpdatedEnvelope(job))
        }
        for worktree in appState.mobileGatewayWorktreeChanges {
            send(AgentMobileGatewayCommandRouter.worktreeUpdatedEnvelope(worktree))
        }
    }

    private func open(baseURL: URL, desktopToken: String, session: URLSession) {
        guard let url = websocketURL(from: baseURL) else {
            lastErrorMessage = "Invalid Mobile Gateway URL."
            return
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(desktopToken)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        webSocketTask = task
        isConnected = true
        lastErrorMessage = nil
        task.resume()
        receiveNext()
        publishSnapshot()
    }

    private func scheduleSnapshot() {
        guard isConnected, webSocketTask != nil else { return }
        snapshotTask?.cancel()
        snapshotTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.publishSnapshot()
        }
    }

    private func receiveNext() {
        guard let task = webSocketTask else { return }
        task.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .success(let message):
                    self.handle(message)
                    self.receiveNext()
                case .failure(let error):
                    self.isConnected = false
                    self.lastErrorMessage = error.localizedDescription
                    self.webSocketTask = nil
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        guard let appState else { return }
        do {
            let data: Data
            switch message {
            case .data(let value):
                data = value
            case .string(let value):
                data = Data(value.utf8)
            @unknown default:
                return
            }
            let envelope = try decoder.decode(AgentMobileGatewayEnvelope.self, from: data)
            let response = AgentMobileGatewayCommandRouter.handle(envelope, controller: appState)
            send(response)
            if response.type == "ack" {
                publishSnapshot()
            }
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func send(_ envelope: AgentMobileGatewayEnvelope) {
        guard let task = webSocketTask else { return }
        do {
            let data = try encoder.encode(envelope)
            guard let text = String(data: data, encoding: .utf8) else { return }
            task.send(.string(text)) { [weak self] error in
                guard let error else { return }
                Task { @MainActor [weak self] in
                    self?.lastErrorMessage = error.localizedDescription
                    self?.isConnected = false
                    self?.webSocketTask = nil
                    self?.scheduleReconnect()
                }
            }
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func scheduleReconnect() {
        guard shouldReconnect,
              reconnectTask == nil,
              let baseURL = reconnectBaseURL,
              let desktopToken = reconnectDesktopToken else {
            return
        }
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard let self, !Task.isCancelled, self.shouldReconnect else { return }
            self.reconnectTask = nil
            self.open(baseURL: baseURL, desktopToken: desktopToken, session: self.reconnectSession)
        }
    }

    private func websocketURL(from baseURL: URL) -> URL? {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        switch components?.scheme?.lowercased() {
        case "http":
            components?.scheme = "ws"
        case "https":
            components?.scheme = "wss"
        case "ws", "wss":
            break
        default:
            return nil
        }
        components?.path = "/mobile/ws"
        components?.query = nil
        return components?.url
    }
}
