//
//  AgentMobileGatewayDesktopPeer.swift
//  WillDeep
//
//  Desktop WebSocket peer for the LAN Mobile Gateway.
//

import Combine
import Foundation
import Network

@MainActor
final class AgentMobileGatewayDesktopPeer: ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var lastErrorMessage: String?

    private weak var appState: AppState?
    private var webSocketTask: URLSessionWebSocketTask?
    private var reconnectTask: Task<Void, Never>?
    private var connectionVerificationTask: Task<Void, Never>?
    private var reconnectWebSocketURL: URL?
    private var reconnectToken: String?
    private var reconnectSession: URLSession = .shared
    private var shouldReconnect = false
    private var isRelayConnection = false
    /// 1.87.0-rc3:连续失败次数,做指数退避。每次 receive 失败 +1,
    /// 收到一帧就归 0。退避公式 `min(750ms * 2^n, 30s)`,gateway 不开
    /// 时把 Console 刷屏从每秒一次降到 30s 一次。
    private var consecutiveFailures = 0
    private static let reconnectBaseDelay: UInt64 = 750_000_000  // 750ms
    private static let reconnectMaxDelay: UInt64 = 30_000_000_000  // 30s
    private static let connectionVerificationTimeout: UInt64 = 10_000_000_000  // 10s
    private var appStateCancellable: AnyCancellable?
    /// 监听系统网络路径。断线后原本只能等指数退避 tick（最长 30s）才重连；
    /// 网络切换 / 睡眠唤醒后路径一旦恢复 satisfied，就取消退避、立即重连，
    /// 把「手机总是能连上」的空窗从 30s 压到数秒。仅在 relay/LAN 连接活跃
    /// 期间运行，`disconnect` 时停掉。
    private var pathMonitor: NWPathMonitor?
    private var lastPathSatisfied = false
    private static let pathMonitorQueue = DispatchQueue(label: "com.willdeep.mobileGateway.pathMonitor")
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
        isRelayConnection = false
        reconnectWebSocketURL = websocketURL(from: baseURL)
        reconnectToken = desktopToken
        reconnectSession = session
        startPathMonitor()
        open(webSocketURL: websocketURL(from: baseURL), token: desktopToken, session: session)
    }

    func connectRelay(baseURL: URL, room: String, relayToken: String, session: URLSession = .shared) {
        disconnect()
        shouldReconnect = true
        isRelayConnection = true
        reconnectWebSocketURL = relayWebSocketURL(from: baseURL, room: room)
        reconnectToken = relayToken
        reconnectSession = session
        startPathMonitor()
        open(webSocketURL: reconnectWebSocketURL, token: relayToken, session: session)
    }

    func disconnect() {
        shouldReconnect = false
        isRelayConnection = false
        stopPathMonitor()
        reconnectTask?.cancel()
        reconnectTask = nil
        connectionVerificationTask?.cancel()
        connectionVerificationTask = nil
        snapshotTask?.cancel()
        snapshotTask = nil
        messageEventState.reset()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
        reconnectWebSocketURL = nil
        reconnectToken = nil
        reconnectSession = .shared
        consecutiveFailures = 0
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
        send(AgentMobileGatewayCommandRouter.capabilitiesEnvelope(controller: appState))
        for approval in appState.mobileGatewayPendingToolApprovals {
            send(AgentMobileGatewayCommandRouter.toolPendingEnvelope(approval))
            if isRelayConnection {
                MobileRemotePushNotifier.shared.notifyIfNeeded(MobileRemoteAttentionPayload(approval))
            }
        }
        for proposal in appState.mobileGatewayPendingPatchProposals {
            send(AgentMobileGatewayCommandRouter.patchUpsertEnvelope(proposal))
            if isRelayConnection {
                MobileRemotePushNotifier.shared.notifyIfNeeded(MobileRemoteAttentionPayload(proposal))
            }
        }
        for job in appState.mobileGatewayJobs {
            send(AgentMobileGatewayCommandRouter.jobUpdatedEnvelope(job))
        }
        for worktree in appState.mobileGatewayWorktreeChanges {
            send(AgentMobileGatewayCommandRouter.worktreeUpdatedEnvelope(worktree))
        }
    }

    private func open(webSocketURL: URL?, token: String, session: URLSession) {
        guard let url = webSocketURL else {
            lastErrorMessage = "Invalid Mobile Gateway URL."
            return
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        webSocketTask = task
        // `resume()` only starts the HTTP upgrade. Treating that moment as a
        // live WebSocket made Settings report "connected" even when the relay
        // later rejected or stalled the handshake. A successful WebSocket
        // ping is the first transport-level proof that the upgrade completed.
        isConnected = false
        lastErrorMessage = nil
        task.resume()
        receiveNext()
        verifyConnection(task)
    }

    private func verifyConnection(_ task: URLSessionWebSocketTask) {
        connectionVerificationTask?.cancel()
        connectionVerificationTask = Task { @MainActor [weak self, weak task] in
            try? await Task.sleep(nanoseconds: Self.connectionVerificationTimeout)
            guard let self,
                  let task,
                  !Task.isCancelled,
                  self.webSocketTask === task,
                  !self.isConnected else {
                return
            }
            self.handleConnectionFailure(
                URLError(.timedOut, userInfo: [
                    NSLocalizedDescriptionKey: "Mobile Gateway WebSocket handshake timed out."
                ])
            )
        }
        task.sendPing { [weak self, weak task] error in
            Task { @MainActor [weak self, weak task] in
                guard let self,
                      let task,
                      self.webSocketTask === task else {
                    return
                }
                if let error {
                    self.handleConnectionFailure(error)
                    return
                }
                self.markConnectionVerified()
            }
        }
    }

    private func markConnectionVerified() {
        connectionVerificationTask?.cancel()
        connectionVerificationTask = nil
        consecutiveFailures = 0
        guard !isConnected else { return }
        isConnected = true
        lastErrorMessage = nil
        // The desktop often joins before Android. Publish only after the
        // handshake is real so the initial snapshot cannot be lost to a
        // pre-upgrade send.
        publishSnapshot()
    }

    private func handleConnectionFailure(_ error: Error) {
        connectionVerificationTask?.cancel()
        connectionVerificationTask = nil
        isConnected = false
        lastErrorMessage = error.localizedDescription
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        scheduleReconnect()
    }

    private func scheduleSnapshot() {
        guard isConnected, webSocketTask != nil else { return }
        guard snapshotTask == nil else { return }
        snapshotTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.snapshotTask = nil
            self?.publishSnapshot()
        }
    }

    private func receiveNext() {
        guard let task = webSocketTask else { return }
        task.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.webSocketTask === task else { return }
                switch result {
                case .success(let message):
                    self.markConnectionVerified()
                    self.handle(message)
                    self.receiveNext()
                case .failure(let error):
                    self.handleConnectionFailure(error)
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
                Task { @MainActor [weak self, weak task] in
                    guard let self,
                          let task,
                          self.webSocketTask === task else {
                        return
                    }
                    self.handleConnectionFailure(error)
                }
            }
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func scheduleReconnect() {
        guard shouldReconnect,
              reconnectTask == nil,
              let webSocketURL = reconnectWebSocketURL,
              let token = reconnectToken else {
            return
        }
        consecutiveFailures += 1
        // 指数退避:base × 2^(n-1),封顶 30s。
        let exponent = min(consecutiveFailures - 1, 10)  // 2^10 防溢出
        let delay = min(
            Self.reconnectBaseDelay &* UInt64(1 << exponent),
            Self.reconnectMaxDelay
        )
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, !Task.isCancelled, self.shouldReconnect else { return }
            self.reconnectTask = nil
            self.open(webSocketURL: webSocketURL, token: token, session: self.reconnectSession)
        }
    }

    // MARK: - Network path monitoring

    private func startPathMonitor() {
        // 复用同一个 monitor —— 两个 connect 方法都会调，避免重复创建。
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        // 初始状态未知，按「不满足」起步，这样第一次 satisfied 会是一次
        // 明确的上升沿。真正的首连由 connect/connectRelay 自己发起。
        lastPathSatisfied = false
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.handlePathUpdate(satisfied: satisfied)
            }
        }
        monitor.start(queue: Self.pathMonitorQueue)
        pathMonitor = monitor
    }

    private func stopPathMonitor() {
        pathMonitor?.cancel()
        pathMonitor = nil
        lastPathSatisfied = false
    }

    /// 只在网络路径「从不满足 → 满足」的上升沿、且当前未连接时，取消退避、
    /// 立即重连。避免在已 satisfied 状态下每次路径细节抖动都硬拨一次。
    private func handlePathUpdate(satisfied: Bool) {
        let rose = satisfied && !lastPathSatisfied
        lastPathSatisfied = satisfied
        guard rose,
              shouldReconnect,
              !isConnected,
              let webSocketURL = reconnectWebSocketURL,
              let token = reconnectToken else {
            return
        }
        // 网络刚回来：清掉正在挂起的退避、把失败计数归零，马上重连。
        reconnectTask?.cancel()
        reconnectTask = nil
        consecutiveFailures = 0
        open(webSocketURL: webSocketURL, token: token, session: reconnectSession)
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

    private func relayWebSocketURL(from baseURL: URL, room: String) -> URL? {
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
        let cleanRoom = room.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !cleanRoom.isEmpty else { return nil }
        components?.path = "/ws/broadcast/\(cleanRoom)"
        components?.query = nil
        return components?.url
    }
}
