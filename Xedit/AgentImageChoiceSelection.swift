//
//  AgentImageChoiceSelection.swift
//  WillDeep
//
//  Runtime-only state for image-choice widgets. A widget button still sends
//  its structured prompt back to chat, but the app also records the selected
//  image locally so the next model turn can see the choice without searching
//  through a long transcript.
//

import Foundation

struct AgentImageChoiceSelection: Equatable, Identifiable {
    let id: UUID
    var widgetID: UUID
    var widgetTitle: String
    var action: String
    var imagePath: String
    var index: Int?
    var taskID: String?
    var taskHandle: String?
    var projectID: String?
    var episodeID: String?
    var shotID: String?
    var assetKind: String?
    var assetID: String?
    var reviewItemID: String?
    var recommendedTool: String?
    var recommendedArguments: String?
    var postSelectActionKeys: [String]
    var sourceBlock: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        widgetID: UUID,
        widgetTitle: String,
        action: String,
        imagePath: String,
        index: Int? = nil,
        taskID: String? = nil,
        taskHandle: String? = nil,
        projectID: String? = nil,
        episodeID: String? = nil,
        shotID: String? = nil,
        assetKind: String? = nil,
        assetID: String? = nil,
        reviewItemID: String? = nil,
        recommendedTool: String? = nil,
        recommendedArguments: String? = nil,
        postSelectActionKeys: [String] = [],
        sourceBlock: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.widgetID = widgetID
        self.widgetTitle = widgetTitle
        self.action = action
        self.imagePath = imagePath
        self.index = index
        self.taskID = taskID
        self.taskHandle = taskHandle
        self.projectID = projectID
        self.episodeID = episodeID
        self.shotID = shotID
        self.assetKind = assetKind
        self.assetID = assetID
        self.reviewItemID = reviewItemID
        self.recommendedTool = recommendedTool
        self.recommendedArguments = recommendedArguments
        self.postSelectActionKeys = postSelectActionKeys
        self.sourceBlock = sourceBlock
        self.createdAt = createdAt
    }

    var hasShotAnchor: Bool {
        clean(projectID) != nil && clean(episodeID) != nil && clean(shotID) != nil
    }

    var hasAssetAnchor: Bool {
        clean(projectID) != nil && clean(assetKind) != nil && clean(assetID) != nil
    }

    var systemPromptBlock: String {
        var lines = [
            "=== Latest Image Choice ===",
            "<latest-image-choice>",
            "widget_id: \(widgetID.uuidString)",
            "widget_title: \(widgetTitle)",
            "action: \(action)",
            "image_path: \(imagePath)"
        ]
        if let index {
            lines.append("index: \(index)")
        }
        appendCleanLine("task_id", taskID, to: &lines)
        appendCleanLine("task_handle", taskHandle, to: &lines)
        appendCleanLine("project_id", projectID, to: &lines)
        appendCleanLine("episode_id", episodeID, to: &lines)
        appendCleanLine("shot_id", shotID, to: &lines)
        appendCleanLine("asset_kind", assetKind, to: &lines)
        appendCleanLine("asset_id", assetID, to: &lines)
        appendCleanLine("review_item_id", reviewItemID, to: &lines)
        appendCleanLine("recommended_tool", recommendedTool, to: &lines)
        appendCleanLine("recommended_arguments", recommendedArguments, to: &lines)
        if !postSelectActionKeys.isEmpty {
            lines.append("post_select_action_keys: \(postSelectActionKeys.joined(separator: ", "))")
        }
        if hasShotAnchor {
            lines.append("selection_scope: short_drama_shot")
            lines.append("selection_note: this image has already been recorded as the current local image choice; when appropriate, call short_drama_select_shot_artifact with artifact_path=image_path, then use post_select_* fields from the user message for video/edit/erase/upscale follow-up.")
        } else if hasAssetAnchor {
            lines.append("selection_scope: short_drama_asset")
            lines.append("selection_note: this image has already been recorded as the current local image choice; when appropriate, call short_drama_attach_asset_reference_image with image_path, then continue with asset reference generation or review.")
        } else {
            lines.append("selection_scope: generic_image")
            lines.append("selection_note: use this image_path as the user's latest chosen candidate for editing, erasing, upscaling, video generation, or import into a short-drama shot/asset.")
        }
        lines.append("</latest-image-choice>")
        return lines.joined(separator: "\n")
    }

    static func parse(widgetID: UUID, widgetTitle: String, prompt: String) -> AgentImageChoiceSelection? {
        guard let block = firstChoiceBlock(in: prompt) else { return nil }
        let entries = parseEntries(from: block)
        let imagePath = clean(entries["image_path"]) ?? clean(entries["artifact_path"])
        guard let imagePath else { return nil }
        let action = clean(entries["action"]) ?? "select_image"
        return AgentImageChoiceSelection(
            widgetID: widgetID,
            widgetTitle: widgetTitle,
            action: action,
            imagePath: imagePath,
            index: clean(entries["index"]).flatMap(Int.init),
            taskID: clean(entries["task_id"]),
            taskHandle: clean(entries["task_handle"]),
            projectID: clean(entries["project_id"]),
            episodeID: clean(entries["episode_id"]),
            shotID: clean(entries["shot_id"]),
            assetKind: clean(entries["asset_kind"]),
            assetID: clean(entries["asset_id"]),
            reviewItemID: clean(entries["review_item_id"]),
            recommendedTool: clean(entries["recommended_tool"]),
            recommendedArguments: clean(entries["recommended_arguments"]),
            postSelectActionKeys: splitList(clean(entries["post_select_action_keys"])),
            sourceBlock: block
        )
    }

    private static func firstChoiceBlock(in prompt: String) -> String? {
        for tag in ["image-choice", "media-task-image-choice", "short-drama-image-choice"] {
            if let block = taggedBlock(tag, in: prompt) {
                return block
            }
        }
        return nil
    }

    private static func taggedBlock(_ tag: String, in prompt: String) -> String? {
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        guard let start = prompt.range(of: open),
              let end = prompt.range(of: close, range: start.upperBound..<prompt.endIndex) else {
            return nil
        }
        return String(prompt[start.lowerBound..<end.upperBound])
    }

    private static func parseEntries(from block: String) -> [String: String] {
        var entries: [String: String] = [:]
        for rawLine in block.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.hasPrefix("<"),
                  let separator = line.firstIndex(of: ":") ?? line.firstIndex(of: "=") else {
                continue
            }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard isEntryKey(key), !value.isEmpty else { continue }
            entries[key] = value
        }
        return entries
    }

    private static func splitList(_ value: String?) -> [String] {
        guard let value else { return [] }
        return value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func isEntryKey(_ key: String) -> Bool {
        guard !key.isEmpty else { return false }
        return key.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == UnicodeScalar("_")
        }
    }

    private func appendCleanLine(_ key: String, _ value: String?, to lines: inout [String]) {
        guard let value = clean(value) else { return }
        lines.append("\(key): \(value)")
    }

    private static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func clean(_ value: String?) -> String? {
        Self.clean(value)
    }
}

@MainActor
extension AppState {
    var agentLatestImageChoice: AgentImageChoiceSelection? {
        get { activeRuntime?.latestImageChoice }
        set { activeRuntime?.latestImageChoice = newValue }
    }

    func recordAgentImageChoiceFromWidget(widgetID: UUID, widgetTitle: String, prompt: String) {
        guard let selection = AgentImageChoiceSelection.parse(
            widgetID: widgetID,
            widgetTitle: widgetTitle,
            prompt: prompt
        ) else {
            return
        }
        agentLatestImageChoice = selection
        applyShortDramaSelectionIfPossible(selection)
    }

    private func applyShortDramaSelectionIfPossible(_ selection: AgentImageChoiceSelection) {
        if let projectID = selection.projectID.flatMap(UUID.init(uuidString:)),
           let episodeID = selection.episodeID.flatMap(UUID.init(uuidString:)),
           let shotID = selection.shotID.flatMap(UUID.init(uuidString:)),
           selection.action.contains("select") {
            _ = agentShortDramaStore.selectShotArtifact(
                projectID: projectID,
                episodeID: episodeID,
                shotID: shotID,
                artifactPath: selection.imagePath
            )
            return
        }
        if let projectID = selection.projectID.flatMap(UUID.init(uuidString:)),
           let assetKind = selection.assetKind,
           let assetID = selection.assetID.flatMap(UUID.init(uuidString:)),
           selection.action.contains("select") {
            _ = agentShortDramaStore.attachReferenceImages(
                projectID: projectID,
                assetKind: assetKind,
                assetID: assetID,
                imagePaths: [selection.imagePath]
            )
        }
    }
}
