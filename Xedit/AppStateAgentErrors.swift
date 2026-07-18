//
//  AppStateAgentErrors.swift
//  WillDeep
//
//  Agent error presentation and retry policy helpers split out of
//  AppStateAgentLoop.swift so the main loop can focus on turn orchestration.
//

import Foundation

extension AppState {
    static let maxGoalTransientNetworkRetries = 5
    static let goalTransientNetworkRetryDelayNanoseconds: UInt64 = 3_000_000_000
    static let maxTLSHandshakeRetries = 5
    static let tlsHandshakeRetryDelayNanoseconds: UInt64 = 5_000_000_000

    func setAgentError(_ error: Error, for runtime: AgentRuntime) {
        runtime.errorMessage = Self.friendlyMessage(for: error)
        runtime.errorDetails = Self.details(for: error)
        runtime.errorRequiresSomeIMLogin = false
    }

    /// "省心托管 / some.im" needs a live shared-session login. If the login was
    /// lost (logout in this or another app, an expired token) AFTER a session
    /// was created on managed routing, a send would otherwise fire an
    /// unauthenticated relay request that comes back as an empty stream and
    /// gets silently dropped — the user sees nothing happen. Callers check
    /// this BEFORE dispatching so they can stop with an actionable error
    /// instead of a silent no-op.
    func someIMLoginRequiredForTurn(for runtime: AgentRuntime, providerID: String) -> Bool {
        guard runtime.managedRouting != nil
            || providerID == AgentProviderPreset.someIMID else {
            return false
        }
        return SomeIMIntegrationStore
            .loadAPIKey()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    /// Surface the some.im login gate as an error the user can act on. Keeps
    /// the user's just-typed message in the transcript so it can be re-sent
    /// with the "重试" button once they log back in.
    func setSomeIMLoginRequiredError(for runtime: AgentRuntime) {
        runtime.errorMessage = "some.im 未登录，「省心托管」无法工作。请先登录 some.im，然后点「重试」重新发送这条消息。"
        runtime.errorDetails = nil
        runtime.errorRequiresSomeIMLogin = true
    }

    /// Translate the raw `Error` thrown by `AgentClient` into a one-line
    /// Chinese caption that tells the user what happened and what to do
    /// next. Falls back to `localizedDescription` for the long tail of
    /// errors we don't specifically classify. The "Details" disclosure
    /// still surfaces the full provider payload for debugging.
    static func friendlyMessage(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return "连接模型超时（120 秒内没收到数据）。可能是网络慢、代理掉线，或者模型本身排队。点击「重试」再试一次，或检查网络/代理。"
            case .notConnectedToInternet:
                return "当前似乎没有网络。检查 Wi-Fi 或网线后点「重试」。"
            case .networkConnectionLost:
                return "连接被中途断开。可能是网络抖动或代理重置。点「重试」再发一次。"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "无法连接到模型服务（DNS / 主机解析失败）。检查 Settings 里的 Base URL 是否正确，或代理是否能访问到该域名。"
            case .secureConnectionFailed, .serverCertificateUntrusted,
                 .serverCertificateHasBadDate, .serverCertificateNotYetValid,
                 .serverCertificateHasUnknownRoot, .clientCertificateRejected,
                 .clientCertificateRequired:
                return "TLS / 握手失败。如果在用翻墙/自签代理，可能是代理连接抖动（会自动重试几次），或镜像服务的证书未被系统信任（需先信任对应证书）。"
            case .cancelled:
                return "请求被取消。"
            default:
                return "网络请求失败：\(urlError.localizedDescription)。点「重试」再发一次。"
            }
        }
        if let clientError = error as? AgentClientError {
            switch clientError {
            case .missingAPIKey:
                return "尚未配置 API Key。先到 Settings → Agent 里填好再发请求。"
            case .invalidBaseURL:
                return "Agent Base URL 不合法，先到 Settings 检查一下。"
            case .invalidResponse:
                return "模型返回了无法识别的内容（非标准 SSE/JSON）。如果反复出现，多半是 Base URL 指向了不兼容的服务。"
            case .serverStatus(let provider):
                let code = provider.statusCode
                // If the provider told us *why* in the response body, lead with
                // its own message — a 403 `token_plan_required` ("requires an
                // active Coding Plan subscription") is far more actionable than
                // the generic "check your API key" guess, which for that case
                // is actively misleading. Only fall back to the status-code
                // hint when the body carries no usable message.
                if let serverMessage = Self.providerErrorMessage(from: provider.responseBody) {
                    return "模型服务返回 HTTP \(code)：\(serverMessage)"
                }
                let hint: String
                switch code {
                case 401, 403:
                    hint = "鉴权失败，检查 API Key 是否正确、是否过期。常见原因是从浏览器/密码管理器复制时带了首尾空格或换行——回到 Settings → Agent 把 key 重新粘贴一次（保存时会自动去掉空白）。也确认 Base URL 是否与该 Key 对应的服务匹配。"
                case 404:
                    hint = "接口路径找不到，检查 Base URL 与模型名是否匹配。"
                case 408, 504:
                    hint = "上游网关超时。稍等片刻点「重试」即可。"
                case 429:
                    hint = "触发限流（QPS / 配额）。等几秒再点「重试」，或换一个更宽松的模型。"
                case 500...599:
                    hint = "模型服务端 5xx 错误。多半是临时抽风，点「重试」。"
                default:
                    hint = "查看「Details」里的响应体定位原因。"
                }
                return "模型服务返回 HTTP \(code)。\(hint)"
            case .emptyStream:
                return "模型服务返回了空响应（连接正常，但没有任何内容、也没有报错）。多半是上游临时抽风、被限流，或「省心托管 / some.im」的中继 token 已失效。点「重试」再发一次；如果反复空响应，多半要重新登录 some.im，或换个 provider/模型。"
            case .unsupportedProviderKind(let kind):
                return "当前 provider 使用的传输协议（\(kind.rawValue)）在这个版本里还没接通。到 Settings → Agent Providers 里换一个支持的 provider，或等下个版本。"
            }
        }
        return error.localizedDescription
    }

    /// Pull a human-readable message out of a provider's JSON error body so
    /// the headline can show the server's own explanation. Handles the common
    /// shapes: `{"message": "..."}`, `{"error": "code", "message": "..."}`
    /// (some.im), and `{"error": {"message": "...", "code": "..."}}`
    /// (OpenAI / Anthropic). Returns nil when the body isn't JSON or carries
    /// no usable message — the caller then falls back to the status-code hint.
    /// The full body is always available under the error card's "Details".
    nonisolated static func providerErrorMessage(from body: String) -> String? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        func clean(_ value: Any?) -> String? {
            guard let text = (value as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return nil
            }
            // Keep the headline readable — the full payload lives in Details.
            return text.count > 300 ? String(text.prefix(300)) + "…" : text
        }

        // Top-level `message` (some.im, many gateways).
        if let message = clean(root["message"]) {
            // Prefix a short error code when it adds signal (e.g. token_plan_required).
            if let code = clean(root["error"]), code != message, code.count <= 40 {
                return "\(message)（\(code)）"
            }
            return message
        }
        // Nested `error` object (OpenAI / Anthropic).
        if let errorObject = root["error"] as? [String: Any] {
            if let message = clean(errorObject["message"]) { return message }
        }
        // Bare string `error`.
        return clean(root["error"])
    }

    /// Whether the error banner should expose a "Retry" affordance.
    /// We allow retry whenever the loop is idle and there's at least one
    /// user message in the history — i.e. there's something to retry.
    var canRetryLastAgentTurn: Bool {
        guard !isAgentResponding, !isCompressingAgentContext else { return false }
        guard agentMessages.contains(where: { $0.role == .user }) else { return false }
        return true
    }

    /// Re-run `runAgentLoop` against the existing conversation. The user's
    /// last message is already in `agentMessages` (it stays in the history
    /// even when the assistant turn errors out), so we just kick the loop
    /// again with the current configuration. Used by the error card's
    /// "Retry" button when the previous turn died on a timeout or other
    /// transient network error.
    func retryLastAgentTurn() {
        guard canRetryLastAgentTurn,
              let runtime = activeRuntime else { return }
        repairSomeIMProviderCredentialsForTurnIfNeeded(for: runtime)
        let configuration = configurationForCurrentTurn(for: runtime)

        // Re-check the some.im login gate: if they clicked 重试 while still
        // logged out, keep the actionable error up rather than silently
        // firing another unauthenticated request.
        guard !someIMLoginRequiredForTurn(for: runtime, providerID: configuration.providerID) else {
            setSomeIMLoginRequiredError(for: runtime)
            return
        }

        // Same gate as the dispatch path — a retry counts against the
        // provider quota just like a fresh send. Queueing is fine: when
        // a slot frees, the queue drain will pick up the runtime's
        // existing transcript and re-run.
        guard acquireProviderSlotIfPossible(providerID: configuration.providerID) else {
            // Retry button on the error card while the cap is busy:
            // do nothing rather than silently queue a re-run, because
            // the user's expectation is "right now" — leave the error
            // visible so they can click again in a moment.
            return
        }

        runtime.errorMessage = nil
        runtime.errorDetails = nil
        runtime.errorRequiresSomeIMLogin = false
        runtime.isResponding = true
        runtime.turnStartedAt = Date()

        runtime.requestTask?.cancel()
        runtime.requestTask = Task { [weak self, weak runtime] in
            guard let self else { return }
            guard let runtime else {
                self.releaseProviderSlot(providerID: configuration.providerID)
                return
            }
            await self.runAgentLoop(for: runtime, configuration: configuration)
        }
    }

    /// Dismiss the error banner without retrying — used by the "Close"
    /// (×) affordance on the error card. Keeps the user's last message in
    /// history so they can edit/copy and re-send manually.
    func dismissAgentError() {
        agentErrorMessage = nil
        agentErrorDetails = nil
        agentErrorRequiresSomeIMLogin = false
    }

    static func details(for error: Error) -> AgentErrorDetails? {
        if case AgentClientError.emptyStream(let providerID, let model) = error {
            return AgentErrorDetails(sections: [
                AgentErrorDetails.Section(
                    title: "Empty stream",
                    text: """
                    Provider: \(providerID)
                    Model: \(model)

                    The provider returned HTTP 2xx but the SSE stream closed \
                    without emitting any content, tool call, or finish_reason. \
                    Common causes: an expired managed-routing (some.im) token \
                    that the relay answers with an empty body instead of 401, \
                    an upstream rate-limit, or a provider-side hiccup.
                    """
                )
            ])
        }
        guard case AgentClientError.serverStatus(let providerError) = error else {
            return nil
        }
        return AgentErrorDetails(sections: [
            AgentErrorDetails.Section(
                title: "Request",
                text: """
                Method: \(providerError.method)
                URL: \(providerError.url)
                Provider: \(providerError.providerID)
                Model: \(providerError.model)
                """
            ),
            AgentErrorDetails.Section(title: "Input Messages", text: providerError.requestSummary),
            AgentErrorDetails.Section(title: "Request Body", text: providerError.requestBody),
            AgentErrorDetails.Section(
                title: "Response",
                text: """
                HTTP \(providerError.statusCode)

                \(providerError.responseBody.isEmpty ? "(empty response body)" : providerError.responseBody)
                """
            )
        ])
    }

    func shouldRetryTransientGoalNetworkError(
        _ error: Error,
        for runtime: AgentRuntime,
        assistantID: AgentMessage.ID,
        retryCount: Int
    ) -> Bool {
        guard runtime.interactionMode == .goal else { return false }
        guard retryCount < Self.maxGoalTransientNetworkRetries else { return false }
        guard isTransientAgentNetworkError(error) else { return false }
        guard let index = runtime.messages.firstIndex(where: { $0.id == assistantID }) else { return false }
        let message = runtime.messages[index]
        return message.content.isEmpty
            && message.toolCalls.isEmpty
            && (message.reasoningContent ?? "").isEmpty
    }

    func shouldRetryTLSHandshakeError(
        _ error: Error,
        for runtime: AgentRuntime,
        assistantID: AgentMessage.ID,
        retryCount: Int
    ) -> Bool {
        guard retryCount < Self.maxTLSHandshakeRetries else { return false }
        guard Self.isTLSHandshakeError(error) else { return false }
        guard let index = runtime.messages.firstIndex(where: { $0.id == assistantID }) else { return false }
        let message = runtime.messages[index]
        return message.content.isEmpty
            && message.toolCalls.isEmpty
            && (message.reasoningContent ?? "").isEmpty
    }

    static func isTLSHandshakeError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .secureConnectionFailed, .serverCertificateUntrusted,
             .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .clientCertificateRejected,
             .clientCertificateRequired:
            return true
        default:
            return false
        }
    }

    func isTransientAgentNetworkError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet,
                 .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                 .internationalRoamingOff, .callIsActive, .dataNotAllowed:
                return true
            default:
                return false
            }
        }
        // An empty stream is usually a transient upstream hiccup; in
        // autonomous goal mode we retry a bounded number of times before
        // surfacing the error. (In normal mode there's no auto-retry — the
        // error card with its 重试 button shows immediately.)
        if case AgentClientError.emptyStream = error {
            return true
        }
        guard case AgentClientError.serverStatus(let providerError) = error else {
            return false
        }
        switch providerError.statusCode {
        case 408, 429, 500...599:
            return true
        default:
            return false
        }
    }
}
