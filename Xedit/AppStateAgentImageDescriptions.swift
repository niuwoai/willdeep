//
//  AppStateAgentImageDescriptions.swift
//  WillDeep
//
//  Image-understanding fallback used when the active provider only accepts text.
//

import Foundation

nonisolated enum AgentImageDescriptionRetryPolicy {
    /// A vision-route lookup can briefly return 422 while the relay refreshes
    /// its healthy upstream set. Keep the retry budget bounded and scoped to
    /// this exact transient response, but wait long enough for route discovery
    /// to settle so users are not forced to press Retry themselves.
    static let maximumRetryCount = 3
    static let initialRetryDelayNanoseconds: UInt64 = 800_000_000

    static func retryDelayNanoseconds(for retryCount: Int) -> UInt64 {
        let boundedRetryCount = max(0, min(retryCount, maximumRetryCount - 1))
        return initialRetryDelayNanoseconds << boundedRetryCount
    }

    static func shouldRetry(_ error: Error, retryCount: Int) -> Bool {
        guard retryCount < maximumRetryCount,
              case AgentClientError.serverStatus(let providerError) = error,
              providerError.statusCode == 422 else {
            return false
        }
        let response = providerError.responseBody.lowercased()
        return response.contains("no route can preserve")
            && response.contains("input_modality:image")
    }
}

extension AppState {
    func prepareImagesForTextOnlyProvider(
        for runtime: AgentRuntime,
        userMessageID: AgentMessage.ID,
        mainConfiguration: AgentConfiguration,
        imageDescriptionConfiguration: AgentConfiguration
    ) async throws {
        guard !mainConfiguration.supportsImageInput else { return }
        guard let index = runtime.messages.firstIndex(where: { $0.id == userMessageID }) else { return }
        let images = runtime.messages[index].images
        guard !images.isEmpty else { return }

        let description = try await describeImagesForTextOnlyProvider(
            images,
            configuration: imageDescriptionConfiguration
        )

        guard !Task.isCancelled,
              let liveIndex = runtime.messages.firstIndex(where: { $0.id == userMessageID }) else {
            return
        }
        runtime.messages[liveIndex].content = Self.contentByAppendingImageDescription(
            to: runtime.messages[liveIndex].content,
            description: description,
            imageCount: images.count,
            providerID: imageDescriptionConfiguration.providerID,
            model: imageDescriptionConfiguration.model
        )
        persistAgentSession(runtime: runtime)
    }

    func describeImagesForTextOnlyProvider(
        _ images: [AgentImageAttachment],
        configuration: AgentConfiguration
    ) async throws -> String {
        var lastError: Error?
        var retryCount = 0
        for candidate in imageDescriptionConfigurationCandidates(fallback: configuration) {
            while true {
                do {
                    return try await requestImageDescription(images, configuration: candidate)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if AgentImageDescriptionRetryPolicy.shouldRetry(error, retryCount: retryCount) {
                        let delay = AgentImageDescriptionRetryPolicy.retryDelayNanoseconds(
                            for: retryCount
                        )
                        retryCount += 1
                        try await Task.sleep(nanoseconds: delay)
                        continue
                    }
                    lastError = Self.imageDescriptionStageError(error)
                    break
                }
            }
        }
        if let lastError {
            throw lastError
        }
        do {
            return try await requestImageDescription(images, configuration: configuration)
        } catch {
            throw Self.imageDescriptionStageError(error)
        }
    }

    private nonisolated static func imageDescriptionStageError(_ error: Error) -> Error {
        guard case AgentClientError.serverStatus(let providerError) = error else {
            return error
        }
        return AgentClientError.imageDescriptionServerStatus(providerError)
    }

    private func requestImageDescription(
        _ images: [AgentImageAttachment],
        configuration: AgentConfiguration
    ) async throws -> String {
        let normalized = configuration.normalized
        guard normalized.supportsImageInput else {
            throw AgentClientError.serverStatus(
                AgentProviderHTTPError(
                    statusCode: 400,
                    method: "POST",
                    url: normalized.baseURL,
                    providerID: normalized.providerID,
                    model: normalized.model,
                    requestSummary: "Image description provider does not support image input.",
                    requestBody: "(not sent)",
                    responseBody: "Choose an image-capable provider/model for Image Understanding."
                )
            )
        }

        let prompt = """
        Describe each attached image for a coding agent that cannot see images directly.
        Return concise but information-dense notes. For screenshots, include visible UI text, error messages, dialogs, file names, code snippets, tables, controls, layout, and anything likely relevant to debugging or implementation.
        If there are multiple images, number them as Image 1, Image 2, etc.
        """
        let message = AgentMessage(role: .user, content: prompt, images: images)
        let messages: [AgentMessage]
        if AgentLocalModelPrompting.prefersLocalLanguageInstruction(normalized) {
            messages = AgentLocalModelPrompting.messagesWithLanguageInstruction(
                systemPrompt: "You describe images for a coding agent.",
                userMessages: [message],
                configuration: normalized
            )
        } else {
            messages = [message]
        }
        let collector = CompressionSummaryCollector()
        try await AgentClient(configuration: normalized).streamChat(messages: messages) { event in
            if case .textDelta(let delta) = event {
                await collector.append(delta)
            }
        }
        let result = await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else {
            throw AgentClientError.invalidResponse
        }
        return result
    }

    nonisolated static func contentByAppendingImageDescription(
        to content: String,
        description: String,
        imageCount: Int,
        providerID: String,
        model: String
    ) -> String {
        let header = "[Image description generated by \(providerID) / \(model) for \(imageCount) attached image\(imageCount == 1 ? "" : "s")]"
        let block = "\(header)\n\(description)"
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? block : "\(content)\n\n\(block)"
    }
}
