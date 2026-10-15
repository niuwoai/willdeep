import Foundation

extension AgentModelRequestAccounting {
    static func run<T>(ledger: AgentModelRequestLedger?, configuration: AgentConfiguration,
        requestBody: Data? = nil, onEvent: @escaping @Sendable (AgentClientEvent) async -> Void,
        operation: (@escaping @Sendable (AgentClientEvent) async -> Void) async throws -> T) async throws -> T {
        try await observe(configuration: configuration, body: requestBody, onEvent: onEvent) { consume in
            try await runAccounted(ledger: ledger, configuration: configuration, requestBody: requestBody,
                onEvent: consume, operation: operation)
        }
    }

    static func run<T>(ledger: AgentModelRequestLedger?, configuration: AgentConfiguration,
        request: URLRequest, format: AgentModelRequestFormat, safelyQuantifiableInput: Bool = true,
        ownerGate: AgentRequestOwnerGate? = nil, onEvent: @escaping @Sendable (AgentClientEvent) async -> Void,
        operation: (URLRequest, @escaping @Sendable (AgentClientEvent) async -> Void) async throws -> T) async throws -> T {
        try await runAccounted(ledger: ledger, configuration: configuration, request: request, format: format,
            safelyQuantifiableInput: safelyQuantifiableInput, ownerGate: ownerGate, onEvent: onEvent) { prepared, consume in
            try await observe(configuration: configuration, body: prepared.httpBody, onEvent: consume) { observed in
                try await operation(prepared, observed)
            }
        }
    }

    private static func observe<T>(configuration: AgentConfiguration, body: Data?,
        onEvent: @escaping @Sendable (AgentClientEvent) async -> Void,
        operation: (@escaping @Sendable (AgentClientEvent) async -> Void) async throws -> T) async throws -> T {
        guard let trace = AgentExecutionTrace.current else { return try await operation(onEvent) }
        let requestID = UUID()
        trace.record("request_started") {
            $0.requestID = requestID; $0.provider = AgentRSIOfflineProvider.transportProvider(configuration: configuration); $0.model = configuration.model
            $0.promptSHA256 = body.map(AgentPackageV1.hash)
        }
        do {
            let value = try await AgentExecutionTrace.$physicalRequestID.withValue(requestID) {
              try await operation { event in
                if case .requestIdentified(let identifier) = event {
                    trace.record("request_identified") { $0.requestID = requestID; $0.providerRequestID = identifier }
                }
                if case .usageReported(let input, let output, let total, _, _, _) = event {
                    trace.record("request_usage") { $0.requestID = requestID; $0.usageTokens = total; $0.inputTokens = input; $0.outputTokens = output }
                }
                await onEvent(event)
              }
            }
            trace.record("request_finished") { $0.requestID = requestID; $0.status = "completed" }
            return value
        } catch {
            trace.record("request_finished") {
                $0.requestID = requestID; $0.status = error is CancellationError ? "interrupted" : "infra_error"
            }
            throw error
        }
    }
}
