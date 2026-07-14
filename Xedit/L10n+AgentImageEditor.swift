import Foundation

extension L10n {
    nonisolated enum AgentImageEditor {
        static let brushModeAdd = String(localized: "agent-image-editor.brush-mode.add", defaultValue: "Add")
        static let brushModeEraser = String(localized: "agent-image-editor.brush-mode.eraser", defaultValue: "Eraser")
        static let brushModePicker = String(localized: "agent-image-editor.brush-mode-picker", defaultValue: "Brush Mode")
        static let chatContextLead = String(localized: "agent-image-editor.chat-context-lead", defaultValue: "Continue collaborating based on the current image mask editor panel.")
        static let chatSubmittedLead = String(localized: "agent-image-editor.chat-submitted-lead", defaultValue: "Submitted an image mask edit task; track progress in the media tasks sidebar.")
        static let clearHelp = String(localized: "agent-image-editor.clear-help", defaultValue: "Clear all selections and strokes")
        static let contextAsset = String(localized: "agent-image-editor.context.asset", defaultValue: "Asset")
        static let contextAssetKind = String(localized: "agent-image-editor.context.asset-kind", defaultValue: "Asset Kind")
        static let contextCardAnchors = String(localized: "agent-image-editor.context-card.anchors", defaultValue: "Production Anchors")
        static let contextCardGeneric = String(localized: "agent-image-editor.context-card.generic", defaultValue: "Edit Handoff")
        static let contextEpisode = String(localized: "agent-image-editor.context.episode", defaultValue: "Episode")
        static let contextProject = String(localized: "agent-image-editor.context.project", defaultValue: "Project")
        static let contextReviewItem = String(localized: "agent-image-editor.context.review-item", defaultValue: "Review Item")
        static let contextShot = String(localized: "agent-image-editor.context.shot", defaultValue: "Shot")
        static let emptySubtitle = String(localized: "agent-image-editor.empty-subtitle", defaultValue: "Click the mask button on an image output in Media Tasks to send it here for editing.")
        static let emptyTitle = String(localized: "agent-image-editor.empty-title", defaultValue: "Select an image")
        static func exportFailed(_ a1: String) -> String {
            let template = String(localized: "agent-image-editor.export-failed", defaultValue: "Export failed: %@")
            return String(format: template, a1)
        }
        static let exportHelp = String(localized: "agent-image-editor.export-help", defaultValue: "Export mask")
        static func exportedEraseSuffix(_ a1: String) -> String {
            let template = String(localized: "agent-image-editor.exported.erase-suffix", defaultValue: ", %@ eraser strokes")
            return String(format: template, a1)
        }
        static func exportedMask(_ a1: String, _ a2: String, _ a3: String) -> String {
            let template = String(localized: "agent-image-editor.exported.mask", defaultValue: "Exported mask (%@ selections/strokes%@): %@")
            return String(format: template, a1, a2, a3)
        }
        static func exportedMaskInverted(_ a1: String, _ a2: String, _ a3: String) -> String {
            let template = String(localized: "agent-image-editor.exported.mask-inverted", defaultValue: "Exported inverted mask (%@ selections/strokes%@): %@")
            return String(format: template, a1, a2, a3)
        }
        static let exportedSeedSuffix = String(localized: "agent-image-editor.exported.seed-suffix", defaultValue: ", with the previous mask base")
        static let genericEditHint = String(localized: "agent-image-editor.generic-edit-hint", defaultValue: "Generic image editing. Sending to chat exports the mask first when a selection exists and attaches edit_image_with_mask parameters.")
        static let invertHelp = String(localized: "agent-image-editor.invert-help", defaultValue: "When on, the white edit region becomes everything outside the selection — good for keeping the subject and repainting the background.")
        static let invertToggle = String(localized: "agent-image-editor.invert-toggle", defaultValue: "Invert Mask")
        static let maskToolBrush = String(localized: "agent-image-editor.mask-tool.brush", defaultValue: "Brush")
        static let maskToolBrushHelp = String(localized: "agent-image-editor.mask-tool.brush-help", defaultValue: "Paint over the areas to erase or repaint. Switch between add and eraser to refine mask edges, then export a same-size PNG mask. White areas become the edit region.")
        static let maskToolPicker = String(localized: "agent-image-editor.mask-tool-picker", defaultValue: "Mask Tool")
        static let maskToolRectangle = String(localized: "agent-image-editor.mask-tool.rectangle", defaultValue: "Rectangle")
        static let maskToolRectangleHelp = String(localized: "agent-image-editor.mask-tool.rectangle-help", defaultValue: "Drag to select the areas to erase or repaint. You can select multiple areas, then export a same-size PNG mask. White areas become the edit region.")
        static let needMaskFirst = String(localized: "agent-image-editor.need-mask-first", defaultValue: "Select an area and export a mask first.")
        static let openReplicateSettings = String(localized: "agent-image-editor.open-replicate-settings", defaultValue: "Open Replicate Settings")
        static let operationErase = String(localized: "agent-image-editor.operation.erase", defaultValue: "Erase")
        static let operationInpaint = String(localized: "agent-image-editor.operation.inpaint", defaultValue: "Inpaint")
        static let operationMissingPromptErase = String(localized: "agent-image-editor.operation.missing-prompt-erase", defaultValue: "Enter an erase prompt, or leave it empty to use the default erase prompt.")
        static let operationMissingPromptInpaint = String(localized: "agent-image-editor.operation.missing-prompt-inpaint", defaultValue: "Enter an inpaint prompt.")
        static let operationPicker = String(localized: "agent-image-editor.operation-picker", defaultValue: "Mode")
        static let operationPromptPlaceholderErase = String(localized: "agent-image-editor.operation.prompt-placeholder-erase", defaultValue: "Prompt (optional): describe what to erase or clean up")
        static let operationPromptPlaceholderInpaint = String(localized: "agent-image-editor.operation.prompt-placeholder-inpaint", defaultValue: "Prompt: describe what to paint into the selection")
        static let operationSubmitErase = String(localized: "agent-image-editor.operation.submit-erase", defaultValue: "Submit Erase")
        static let operationSubmitInpaint = String(localized: "agent-image-editor.operation.submit-inpaint", defaultValue: "Submit Inpaint")
        static let panelTitle = String(localized: "agent-image-editor.panel-title", defaultValue: "Image Mask")
        static let providerPicker = String(localized: "agent-image-editor.provider-picker", defaultValue: "Provider")
        static let replicateHelpErase = String(localized: "agent-image-editor.replicate.help-erase", defaultValue: "Replicate prefers the version entered here; when empty, the image-erase version from Settings → Integrations → Replicate is used. Erase can run without a prompt — a basic background-repair prompt is added automatically on submit.")
        static let replicateHelpInpaint = String(localized: "agent-image-editor.replicate.help-inpaint", defaultValue: "Replicate prefers the version entered here; when empty, the mask-inpaint version from Settings → Integrations → Replicate is used. The model must accept image, mask, and prompt inputs.")
        static let replicateNeedEraseVersion = String(localized: "agent-image-editor.replicate.need-erase-version", defaultValue: "Enter a Replicate version hash, or configure a default image-erase version in Settings.")
        static let replicateNeedInpaintVersion = String(localized: "agent-image-editor.replicate.need-inpaint-version", defaultValue: "Enter a Replicate version hash, or configure a default mask-inpaint version in Settings.")
        static let replicateNeedToken = String(localized: "agent-image-editor.replicate.need-token", defaultValue: "Configure a Replicate API token first, or set the REPLICATE_API_TOKEN environment variable.")
        static let replicateVersionPlaceholderErase = String(localized: "agent-image-editor.replicate.version-placeholder-erase", defaultValue: "Replicate version hash; leave empty for the default erase version")
        static let replicateVersionPlaceholderInpaint = String(localized: "agent-image-editor.replicate.version-placeholder-inpaint", defaultValue: "Replicate version hash; leave empty for the default mask-inpaint version")
        static let seedMaskHelp = String(localized: "agent-image-editor.seed-mask-help", defaultValue: "Loaded the previous mask as a base. Exports will keep it and overlay new selections and strokes.")
        static let sendToChat = String(localized: "agent-image-editor.send-to-chat", defaultValue: "Send to Chat")
        static let sendToChatHelp = String(localized: "agent-image-editor.send-to-chat-help", defaultValue: "Send the current image and mask path to the chat")
        static let someIMEndpointPlaceholder = String(localized: "agent-image-editor.someim.endpoint-placeholder", defaultValue: "some.im endpoint, e.g. images/edits")
        static let someIMHelp = String(localized: "agent-image-editor.someim.help", defaultValue: "some.im submits with the image, mask, and prompt fields; adjust the endpoint to match your relay service routing. Erase mode automatically uses a basic erase prompt when no prompt is given.")
        static let someIMModelPlaceholder = String(localized: "agent-image-editor.someim.model-placeholder", defaultValue: "some.im model; leave empty to use the default image model")
        static func submitFailed(_ a1: String) -> String {
            let template = String(localized: "agent-image-editor.submit-failed", defaultValue: "Submission failed: %@")
            return String(format: template, a1)
        }
        static let submitSectionTitle = String(localized: "agent-image-editor.submit-section-title", defaultValue: "Submit Mask Edit")
        static func submittedReplicate(_ a1: String) -> String {
            let template = String(localized: "agent-image-editor.submitted-replicate", defaultValue: "Submitted Replicate task: %@")
            return String(format: template, a1)
        }
        static func submittedSomeIM(_ a1: String) -> String {
            let template = String(localized: "agent-image-editor.submitted-someim", defaultValue: "Submitted some.im task: %@")
            return String(format: template, a1)
        }
        static let submitting = String(localized: "agent-image-editor.submitting", defaultValue: "Submitting")
        static func submittingStatus(_ a1: String) -> String {
            let template = String(localized: "agent-image-editor.submitting-status", defaultValue: "Submitting %@ task...")
            return String(format: template, a1)
        }
        static func summaryFull(_ a1: String, _ a2: String, _ a3: String, _ a4: String, _ a5: String, _ a6: String, _ a7: String, _ a8: String) -> String {
            let template = String(localized: "agent-image-editor.summary.full", defaultValue: "Selection: %@%@ rectangles, %@ brush strokes, %@ eraser strokes, rectangles ≈ %@ px, strokes ≈ %@ px, eraser ≈ %@ px%@")
            return String(format: template, a1, a2, a3, a4, a5, a6, a7, a8)
        }
        static let summaryInvertedBackgroundSuffix = String(localized: "agent-image-editor.summary.inverted-background-suffix", defaultValue: ", background inverted")
        static let summaryInvertedSuffix = String(localized: "agent-image-editor.summary.inverted-suffix", defaultValue: ", inverted")
        static func summaryRect(_ a1: String, _ a2: String, _ a3: String, _ a4: String, _ a5: String) -> String {
            let template = String(localized: "agent-image-editor.summary.rect", defaultValue: "Selection: x %@, y %@, w %@, h %@%@")
            return String(format: template, a1, a2, a3, a4, a5)
        }
        static func summarySeedOnly(_ a1: String) -> String {
            let template = String(localized: "agent-image-editor.summary.seed-only", defaultValue: "Selection: previous mask base%@")
            return String(format: template, a1)
        }
        static let summarySeedPrefix = String(localized: "agent-image-editor.summary.seed-prefix", defaultValue: "previous mask + ")
        static let undoHelp = String(localized: "agent-image-editor.undo-help", defaultValue: "Undo the current or last selection/stroke")
    }
}
