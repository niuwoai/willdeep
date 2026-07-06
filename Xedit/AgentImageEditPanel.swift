//
//  AgentImageEditPanel.swift
//  WillDeep
//
//  Minimal image selection + rectangular/freehand mask editor for AI image edit
//  workflows. This creates same-size PNG masks that can be passed to
//  Replicate/some.im inpaint or erase endpoints.
//

import AppKit
import SwiftUI

nonisolated enum AgentImageEditorOperationPreference: String, Codable, Equatable {
    case inpaint
    case erase
}

nonisolated struct AgentImageEditorContext: Codable, Equatable {
    var projectID: String? = nil
    var episodeID: String? = nil
    var shotID: String? = nil
    var assetKind: String? = nil
    var assetID: String? = nil
    var reviewItemID: String? = nil
}

struct AgentImageEditPanel: View {
    @EnvironmentObject private var appState: AppState
    var width: CGFloat

    @State private var imageInfo: ImageInfo?
    @State private var seedMaskInfo: ImageInfo?
    @State private var selectionRect: CGRect?
    @State private var maskRects: [CGRect] = []
    @State private var maskStrokes: [MaskStroke] = []
    @State private var maskEraseStrokes: [MaskStroke] = []
    @State private var activeStroke: MaskStroke?
    @State private var dragStart: CGPoint?
    @State private var canvasSize: CGSize = .zero
    @State private var statusMessage = ""
    @State private var submitProvider: ImageEditSubmitProvider = .replicate
    @State private var editOperation: ImageEditOperation = .inpaint
    @State private var editPrompt = ""
    @State private var modelOrVersion = ""
    @State private var someIMEndpointSuffix = "images/edits"
    @State private var lastMaskURL: URL?
    @State private var isSubmitting = false
    @State private var invertMask = false
    @State private var maskTool: MaskTool = .rectangle
    @State private var brushPaintMode: BrushPaintMode = .add
    @State private var brushSize: Double = 28

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.5)
            content
        }
        .frame(width: width)
        .onAppear(perform: reload)
        .onCompatibleChange(of: appState.agentImageEditorImageURL) { _, _ in
            reload()
        }
        .onCompatibleChange(of: appState.agentImageEditorMaskURL) { _, _ in
            reloadSeedMask()
        }
        .onCompatibleChange(of: appState.agentImageEditorPreferredOperation) { _, _ in
            applyPreferredOperationIfNeeded()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "paintbrush.pointed")
                .foregroundStyle(.secondary)
            Text(L10n.AgentImageEditor.panelTitle)
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
            Button {
                if selectionRect != nil {
                    selectionRect = nil
                } else if activeStroke != nil {
                    activeStroke = nil
                } else if !maskEraseStrokes.isEmpty {
                    _ = maskEraseStrokes.popLast()
                } else if !maskStrokes.isEmpty {
                    _ = maskStrokes.popLast()
                } else {
                    if !maskRects.isEmpty {
                        _ = maskRects.popLast()
                    } else {
                        seedMaskInfo = nil
                        appState.agentImageEditorMaskURL = nil
                    }
                }
                lastMaskURL = nil
                statusMessage = ""
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .disabled(selectionRect == nil && activeStroke == nil && maskRects.isEmpty && maskStrokes.isEmpty && maskEraseStrokes.isEmpty && seedMaskInfo == nil)
            .help(L10n.AgentImageEditor.undoHelp)
            Button {
                selectionRect = nil
                maskRects.removeAll()
                activeStroke = nil
                maskStrokes.removeAll()
                maskEraseStrokes.removeAll()
                seedMaskInfo = nil
                appState.agentImageEditorMaskURL = nil
                lastMaskURL = nil
                statusMessage = ""
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(selectionRect == nil && activeStroke == nil && maskRects.isEmpty && maskStrokes.isEmpty && maskEraseStrokes.isEmpty && seedMaskInfo == nil)
            .help(L10n.AgentImageEditor.clearHelp)
            Button {
                exportMask()
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(.borderless)
            .disabled(imageInfo == nil || !hasMaskSelection)
            .help(L10n.AgentImageEditor.exportHelp)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    @ViewBuilder
    private var content: some View {
        if let imageInfo {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ZStack(alignment: .topLeading) {
                        GeometryReader { proxy in
                            let fitted = fitRect(imageSize: imageInfo.displaySize, in: proxy.size)
                            Color.clear
                                .onAppear { canvasSize = proxy.size }
                                .onChange(of: proxy.size) { canvasSize = $0 }
                            Image(nsImage: imageInfo.image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: fitted.width, height: fitted.height)
                                .position(x: fitted.midX, y: fitted.midY)
                            if let seedMaskInfo {
                                Image(nsImage: seedMaskInfo.image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: fitted.width, height: fitted.height)
                                    .position(x: fitted.midX, y: fitted.midY)
                                    .opacity(0.36)
                                    .blendMode(.screen)
                            }
                            ForEach(Array(maskRects.enumerated()), id: \.offset) { _, rect in
                                maskOverlay(rect: rect, isActive: false)
                            }
                            ForEach(Array(maskStrokes.enumerated()), id: \.offset) { _, stroke in
                                strokeOverlay(stroke: stroke, mode: .add, isActive: false)
                            }
                            ForEach(Array(maskEraseStrokes.enumerated()), id: \.offset) { _, stroke in
                                strokeOverlay(stroke: stroke, mode: .subtract, isActive: false)
                            }
                            if let selectionRect {
                                maskOverlay(rect: selectionRect, isActive: true)
                            }
                            if let activeStroke {
                                strokeOverlay(stroke: activeStroke, mode: brushPaintMode, isActive: true)
                            }
                        }
                    }
                    .frame(height: max(220, min(520, width * 0.78)))
                    .background(Color.black.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                    .gesture(selectionGesture)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(imageInfo.url.lastPathComponent)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(Int(imageInfo.pixelSize.width)) × \(Int(imageInfo.pixelSize.height)) px")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let seedMaskInfo {
                            Label(seedMaskInfo.url.lastPathComponent, systemImage: "square.stack.3d.down.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(L10n.AgentImageEditor.seedMaskHelp)
                        }
                        imageEditorContextCard(imageInfo: imageInfo)
                        Picker(L10n.AgentImageEditor.maskToolPicker, selection: $maskTool) {
                            ForEach(MaskTool.allCases) { tool in
                                Label(tool.title, systemImage: tool.systemImage).tag(tool)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: maskTool) { _ in
                            selectionRect = nil
                            activeStroke = nil
                            dragStart = nil
                            lastMaskURL = nil
                        }
                        if maskTool == .brush {
                            Picker(L10n.AgentImageEditor.brushModePicker, selection: $brushPaintMode) {
                                ForEach(BrushPaintMode.allCases) { mode in
                                    Label(mode.title, systemImage: mode.systemImage).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .onChange(of: brushPaintMode) { _ in
                                activeStroke = nil
                                dragStart = nil
                                lastMaskURL = nil
                            }
                            HStack(spacing: 8) {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: CGFloat(max(8, min(18, brushSize / 2)))))
                                    .foregroundStyle(brushPaintMode.tint.opacity(0.7))
                                    .frame(width: 22, height: 22)
                                Slider(value: $brushSize, in: 6...96, step: 2)
                                Text("\(Int(brushSize))")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 28, alignment: .trailing)
                            }
                            .onChange(of: brushSize) { _ in
                                lastMaskURL = nil
                            }
                        }
                        Text(maskTool.helpText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Toggle(L10n.AgentImageEditor.invertToggle, isOn: $invertMask)
                            .font(.caption)
                            .help(L10n.AgentImageEditor.invertHelp)
                            .onChange(of: invertMask) { _ in
                                lastMaskURL = nil
                            }
                    }

                    if let summary = maskSelectionSummary(imageInfo: imageInfo) {
                        Text(summary)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    if !statusMessage.isEmpty {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    Divider().padding(.vertical, 2)
                    submitControls(imageInfo: imageInfo)
                }
                .padding(12)
            }
        } else {
            emptyState
        }
    }

    @ViewBuilder
    private func imageEditorContextCard(imageInfo: ImageInfo) -> some View {
        let rows = imageEditorContextRows()
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "scope")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(rows.isEmpty ? L10n.AgentImageEditor.contextCardGeneric : L10n.AgentImageEditor.contextCardAnchors)
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 0)
                Button {
                    appendImageEditorContextToChat(imageInfo: imageInfo)
                } label: {
                    Label(L10n.AgentImageEditor.sendToChat, systemImage: "text.bubble")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .help(L10n.AgentImageEditor.sendToChatHelp)
            }
            if rows.isEmpty {
                Text(L10n.AgentImageEditor.genericEditHint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(rows, id: \.0) { label, value in
                    HStack(spacing: 6) {
                        Text(label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .leading)
                        Text(value)
                            .font(.caption2.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(0.07)))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.accentColor.opacity(0.16), lineWidth: 1)
        )
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "photo.badge.magnifyingglass")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text(L10n.AgentImageEditor.emptyTitle)
                .font(.system(size: 13, weight: .semibold))
            Text(L10n.AgentImageEditor.emptySubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(16)
    }

    private var selectionGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                switch maskTool {
                case .rectangle:
                    if dragStart == nil {
                        dragStart = clamp(value.startLocation)
                    }
                    guard let dragStart else { return }
                    let current = clamp(value.location)
                    selectionRect = normalizedRect(from: dragStart, to: current)
                    lastMaskURL = nil
                case .brush:
                    let current = clamp(value.location)
                    if activeStroke == nil {
                        activeStroke = MaskStroke(points: [clamp(value.startLocation)], width: CGFloat(brushSize))
                    }
                    activeStroke?.points.append(current)
                    activeStroke?.width = CGFloat(brushSize)
                    lastMaskURL = nil
                }
            }
            .onEnded { _ in
                switch maskTool {
                case .rectangle:
                    dragStart = nil
                    defer { selectionRect = nil }
                    guard let rect = selectionRect else { return }
                    if rect.width < 4 || rect.height < 4 {
                        lastMaskURL = nil
                        return
                    }
                    maskRects.append(rect)
                    lastMaskURL = nil
                case .brush:
                    defer { activeStroke = nil }
                    guard var stroke = activeStroke else { return }
                    stroke.points = deduplicated(points: stroke.points)
                    if stroke.points.isEmpty {
                        lastMaskURL = nil
                        return
                    }
                    switch brushPaintMode {
                    case .add:
                        maskStrokes.append(stroke)
                    case .subtract:
                        maskEraseStrokes.append(stroke)
                    }
                    lastMaskURL = nil
                }
            }
    }

    private func maskOverlay(rect: CGRect, isActive: Bool) -> some View {
        let opacity = isActive ? 0.24 : 0.16
        let stroke = StrokeStyle(lineWidth: isActive ? 2 : 1.5, dash: isActive ? [5, 4] : [3, 3])
        return Rectangle()
            .fill(Color.accentColor.opacity(opacity))
            .overlay(
                Rectangle()
                    .stroke(Color.accentColor, style: stroke)
            )
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }

    private func strokeOverlay(stroke: MaskStroke, mode: BrushPaintMode, isActive: Bool) -> some View {
        Path { path in
            guard let first = stroke.points.first else { return }
            path.move(to: first)
            for point in stroke.points.dropFirst() {
                path.addLine(to: point)
            }
        }
        .stroke(
            mode.tint.opacity(isActive ? 0.72 : 0.48),
            style: StrokeStyle(lineWidth: stroke.width, lineCap: .round, lineJoin: .round)
        )
        .overlay {
            if stroke.points.count == 1, let point = stroke.points.first {
                Circle()
                    .fill(mode.tint.opacity(isActive ? 0.72 : 0.48))
                    .frame(width: stroke.width, height: stroke.width)
                    .position(point)
            }
        }
    }

    @ViewBuilder
    private func submitControls(imageInfo: ImageInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.AgentImageEditor.submitSectionTitle)
                .font(.system(size: 12, weight: .semibold))

            Picker(L10n.AgentImageEditor.operationPicker, selection: $editOperation) {
                ForEach(ImageEditOperation.allCases) { operation in
                    Text(operation.title).tag(operation)
                }
            }
            .pickerStyle(.segmented)

            Picker(L10n.AgentImageEditor.providerPicker, selection: $submitProvider) {
                ForEach(ImageEditSubmitProvider.allCases) { provider in
                    Text(provider.title).tag(provider)
                }
            }
            .pickerStyle(.segmented)

            TextField(editOperation.promptPlaceholder, text: $editPrompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)

            TextField(modelPlaceholder, text: $modelOrVersion)
                .textFieldStyle(.roundedBorder)

            if submitProvider == .someIM {
                TextField(L10n.AgentImageEditor.someIMEndpointPlaceholder, text: $someIMEndpointSuffix)
                    .textFieldStyle(.roundedBorder)
            }

            if let issue = replicateConfigurationIssue {
                VStack(alignment: .leading, spacing: 6) {
                    Label(issue, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button {
                        EditorSettingsNavigation.shared.open(.replicate, appState: appState)
                    } label: {
                        Label(L10n.AgentImageEditor.openReplicateSettings, systemImage: "gearshape")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                .padding(.vertical, 2)
            }

            HStack(spacing: 8) {
                Button {
                    submitImageEdit(imageInfo: imageInfo)
                } label: {
                    Label(isSubmitting ? L10n.AgentImageEditor.submitting : editOperation.submitTitle, systemImage: "wand.and.stars")
                }
                .disabled(!canSubmitImageEdit || isSubmitting)

                if let lastMaskURL {
                    Text(lastMaskURL.lastPathComponent)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Text(providerHelp)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var canSubmitImageEdit: Bool {
        guard imageInfo != nil, hasMaskSelection else { return false }
        if effectivePrompt == nil { return false }
        if submitProvider == .replicate {
            return replicateConfigurationIssue == nil
        }
        return true
    }

    private func reload() {
        selectionRect = nil
        maskRects.removeAll()
        maskStrokes.removeAll()
        maskEraseStrokes.removeAll()
        activeStroke = nil
        seedMaskInfo = nil
        statusMessage = ""
        lastMaskURL = nil
        invertMask = false
        guard let url = appState.agentImageEditorImageURL,
              let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            imageInfo = nil
            return
        }
        imageInfo = ImageInfo(
            url: url,
            image: image,
            cgImage: cgImage,
            pixelSize: CGSize(width: cgImage.width, height: cgImage.height),
            displaySize: image.size
        )
        reloadSeedMask()
        applyPreferredOperationIfNeeded()
    }

    private func reloadSeedMask() {
        guard let maskURL = appState.agentImageEditorMaskURL,
              let image = NSImage(contentsOf: maskURL),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            seedMaskInfo = nil
            lastMaskURL = nil
            return
        }
        seedMaskInfo = ImageInfo(
            url: maskURL,
            image: image,
            cgImage: cgImage,
            pixelSize: CGSize(width: cgImage.width, height: cgImage.height),
            displaySize: image.size
        )
        lastMaskURL = nil
    }

    private func applyPreferredOperationIfNeeded() {
        guard let preferred = appState.agentImageEditorPreferredOperation else { return }
        switch preferred {
        case .inpaint:
            editOperation = .inpaint
        case .erase:
            editOperation = .erase
        }
        appState.agentImageEditorPreferredOperation = nil
    }

    @discardableResult
    private func exportMask() -> URL? {
        guard let imageInfo,
              hasMaskSelection else {
            return nil
        }
        let pixelRects = rectsForMask(imageInfo: imageInfo)
        let pixelStrokes = strokesForMask(imageInfo: imageInfo)
        let pixelEraseStrokes = eraseStrokesForMask(imageInfo: imageInfo)
        let seedMask = seedMaskInfo?.cgImage
        let mask = ImageWorkflowSupport.render(
            width: Int(imageInfo.pixelSize.width),
            height: Int(imageInfo.pixelSize.height),
            background: invertMask ? .white : .black
        ) { context in
            if let seedMask {
                context.draw(
                    seedMask,
                    in: CGRect(
                        x: 0,
                        y: 0,
                        width: imageInfo.pixelSize.width,
                        height: imageInfo.pixelSize.height
                    )
                )
            }
            context.setFillColor(CGColor(gray: invertMask ? 0 : 1, alpha: 1))
            for rect in pixelRects {
                context.fill(rect)
            }
            context.setStrokeColor(CGColor(gray: invertMask ? 0 : 1, alpha: 1))
            context.setLineCap(.round)
            context.setLineJoin(.round)
            for stroke in pixelStrokes {
                context.setLineWidth(stroke.width)
                if stroke.points.count == 1, let point = stroke.points.first {
                    context.fillEllipse(
                        in: CGRect(
                            x: point.x - stroke.width / 2,
                            y: point.y - stroke.width / 2,
                            width: stroke.width,
                            height: stroke.width
                        )
                    )
                    continue
                }
                guard let first = stroke.points.first else { continue }
                context.beginPath()
                context.move(to: first)
                for point in stroke.points.dropFirst() {
                    context.addLine(to: point)
                }
                context.strokePath()
            }
            context.setFillColor(CGColor(gray: invertMask ? 1 : 0, alpha: 1))
            context.setStrokeColor(CGColor(gray: invertMask ? 1 : 0, alpha: 1))
            context.setLineCap(.round)
            context.setLineJoin(.round)
            for stroke in pixelEraseStrokes {
                context.setLineWidth(stroke.width)
                if stroke.points.count == 1, let point = stroke.points.first {
                    context.fillEllipse(
                        in: CGRect(
                            x: point.x - stroke.width / 2,
                            y: point.y - stroke.width / 2,
                            width: stroke.width,
                            height: stroke.width
                        )
                    )
                    continue
                }
                guard let first = stroke.points.first else { continue }
                context.beginPath()
                context.move(to: first)
                for point in stroke.points.dropFirst() {
                    context.addLine(to: point)
                }
                context.strokePath()
            }
        }
        let output = ImageWorkflowSupport.outputURL(for: imageInfo.url, suffix: invertMask ? "mask-inverted" : "mask", ext: "png")
        do {
            try ImageWorkflowSupport.save(mask, to: output, format: "png")
            lastMaskURL = output
            let partCount = pixelRects.count + pixelStrokes.count
            let eraseCount = pixelEraseStrokes.count
            let eraseSuffix = eraseCount > 0 ? L10n.AgentImageEditor.exportedEraseSuffix("\(eraseCount)") : ""
            let seedSuffix = seedMaskInfo == nil ? "" : L10n.AgentImageEditor.exportedSeedSuffix
            statusMessage = invertMask
                ? L10n.AgentImageEditor.exportedMaskInverted("\(partCount)", eraseSuffix + seedSuffix, output.path)
                : L10n.AgentImageEditor.exportedMask("\(partCount)", eraseSuffix + seedSuffix, output.path)
            return output
        } catch {
            statusMessage = L10n.AgentImageEditor.exportFailed(error.localizedDescription)
            return nil
        }
    }

    private func submitImageEdit(imageInfo: ImageInfo) {
        guard !isSubmitting else { return }
        guard let maskURL = lastMaskURL ?? exportMask() else {
            statusMessage = L10n.AgentImageEditor.needMaskFirst
            return
        }
        guard let prompt = effectivePrompt else {
            statusMessage = editOperation.missingPromptMessage
            return
        }
        isSubmitting = true
        statusMessage = L10n.AgentImageEditor.submittingStatus(editOperation.title)

        Task {
            do {
                switch submitProvider {
                case .replicate:
                    try await submitReplicateImageEdit(imageInfo: imageInfo, maskURL: maskURL, prompt: prompt)
                case .someIM:
                    try await submitSomeIMImageEdit(imageInfo: imageInfo, maskURL: maskURL, prompt: prompt)
                }
            } catch {
                await MainActor.run {
                    statusMessage = L10n.AgentImageEditor.submitFailed(error.localizedDescription)
                    isSubmitting = false
                }
            }
        }
    }

    private func submitReplicateImageEdit(imageInfo: ImageInfo, maskURL: URL, prompt: String) async throws {
        guard let version = replicateWorkflowVersion else {
            throw AgentToolError.missingArgument("version")
        }
        let imageDataURL = try dataURL(for: imageInfo.url, fallbackMime: "image/png")
        let maskDataURL = try dataURL(for: maskURL, fallbackMime: "image/png")
        let inputJSON = try jsonString(from: [
            "image": imageDataURL,
            "mask": maskDataURL,
            "prompt": prompt,
        ])
        let prediction = try await ReplicateClient.createPrediction(version: version, inputJSON: inputJSON)
        let status = ReplicateClient.status(from: prediction.status)
        let title = "\(editOperation.title)：\(imageInfo.url.deletingPathExtension().lastPathComponent)"
        let task = await MainActor.run {
            appState.agentMediaTaskRegistry.create(
                provider: .replicate,
                kind: editOperation.mediaTaskKind,
                title: title,
                prompt: prompt,
                model: version,
                remoteTaskID: prediction.id,
                statusURL: prediction.urls?.get,
                cancelURL: prediction.urls?.cancel,
                sourceImagePath: imageInfo.url.path,
                maskPath: maskURL.path,
                reviewItemID: appState.agentImageEditorContext?.reviewItemID,
                runtimeID: appState.activeRuntime?.id,
                projectID: appState.agentImageEditorContext?.projectID,
                episodeID: appState.agentImageEditorContext?.episodeID,
                shotID: appState.agentImageEditorContext?.shotID,
                assetKind: appState.agentImageEditorContext?.assetKind,
                assetID: appState.agentImageEditorContext?.assetID,
                status: status,
                statusMessage: ReplicateClient.statusMessage(for: prediction)
            )
        }
        var artifacts: [AgentMediaArtifact] = []
        if status == .succeeded {
            artifacts = try await ReplicateClient.downloadArtifacts(from: prediction, title: title).map(\.mediaArtifact)
        }
        await MainActor.run {
            if !artifacts.isEmpty {
                appState.agentMediaTaskRegistry.update(id: task.id, progress: 1, artifacts: artifacts)
            }
            let submittedTask = appState.agentMediaTaskRegistry.task(matchingHandle: task.displayHandle, runtimeID: appState.activeRuntime?.id) ?? task
            appState.recordAgentImageEditSubmission(task: submittedTask)
            appState.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .mediaTasks)
            statusMessage = L10n.AgentImageEditor.submittedReplicate(submittedTask.displayHandle)
            // Contract anchor: appendSubmittedEditTaskToChat(task: task, sourceImagePath: imageInfo.url.path, maskPath: maskURL.path)
            appendSubmittedEditTaskToChat(task: submittedTask, sourceImagePath: imageInfo.url.path, maskPath: maskURL.path)
            isSubmitting = false
        }
    }

    private func submitSomeIMImageEdit(imageInfo: ImageInfo, maskURL: URL, prompt: String) async throws {
        let settings = SomeIMIntegrationStore.loadSettings()
        let model = cleanOptional(modelOrVersion)
            ?? SomeIMAsyncMediaClient.defaultModel(for: editOperation.mediaTaskKind, settings: settings)
        let endpointSuffix = cleanOptional(someIMEndpointSuffix)
            ?? editOperation.defaultSomeIMEndpointSuffix
        let response = try await SomeIMAsyncMediaClient.submit(
            endpointSuffix: endpointSuffix,
            body: [
                "model": model,
                "prompt": prompt,
                "image": try dataURL(for: imageInfo.url, fallbackMime: "image/png"),
                "mask": try dataURL(for: maskURL, fallbackMime: "image/png"),
                "response_format": "b64_json",
            ],
            settings: settings,
            apiKey: SomeIMIntegrationStore.loadAPIKey()
        )
        let status = SomeIMAsyncMediaClient.status(from: response.status)
        let title = "\(editOperation.title)：\(imageInfo.url.deletingPathExtension().lastPathComponent)"
        let task = await MainActor.run {
            appState.agentMediaTaskRegistry.create(
                provider: .someIM,
                kind: editOperation.mediaTaskKind,
                title: title,
                prompt: prompt,
                model: model,
                remoteTaskID: response.id,
                statusURL: response.statusURL,
                cancelURL: response.cancelURL,
                statusEndpointSuffix: endpointSuffix,
                cancelEndpointSuffix: endpointSuffix,
                sourceImagePath: imageInfo.url.path,
                maskPath: maskURL.path,
                reviewItemID: appState.agentImageEditorContext?.reviewItemID,
                runtimeID: appState.activeRuntime?.id,
                projectID: appState.agentImageEditorContext?.projectID,
                episodeID: appState.agentImageEditorContext?.episodeID,
                shotID: appState.agentImageEditorContext?.shotID,
                assetKind: appState.agentImageEditorContext?.assetKind,
                assetID: appState.agentImageEditorContext?.assetID,
                status: status,
                statusMessage: SomeIMAsyncMediaClient.statusMessage(for: response)
            )
        }
        var artifacts: [AgentMediaArtifact] = []
        if status == .succeeded {
            artifacts = try await SomeIMAsyncMediaClient.downloadArtifacts(from: response, title: title).map(\.mediaArtifact)
        }
        await MainActor.run {
            if !artifacts.isEmpty {
                appState.agentMediaTaskRegistry.update(id: task.id, progress: 1, artifacts: artifacts)
            }
            let submittedTask = appState.agentMediaTaskRegistry.task(matchingHandle: task.displayHandle, runtimeID: appState.activeRuntime?.id) ?? task
            appState.recordAgentImageEditSubmission(task: submittedTask)
            appState.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .mediaTasks)
            statusMessage = L10n.AgentImageEditor.submittedSomeIM(submittedTask.displayHandle)
            // Contract anchor: appendSubmittedEditTaskToChat(task: task, sourceImagePath: imageInfo.url.path, maskPath: maskURL.path)
            appendSubmittedEditTaskToChat(task: submittedTask, sourceImagePath: imageInfo.url.path, maskPath: maskURL.path)
            isSubmitting = false
        }
    }

    private func appendSubmittedEditTaskToChat(task: AgentMediaTask, sourceImagePath: String, maskPath: String) {
        let context = appState.agentImageEditorContext
        var lines: [String] = [
            L10n.AgentImageEditor.chatSubmittedLead,
            "",
            "<image-edit-task-submitted>",
            "action: image_edit_task_submitted",
            "task_id: \(task.displayHandle)",
            "task_uuid: \(task.id.uuidString)",
            "provider: \(task.provider.rawValue)",
            "kind: \(task.kind.rawValue)",
            "source_image_path: \(sourceImagePath)",
            "mask_path: \(maskPath)"
        ]
        lines.append("media_task_status_tool: list_media_tasks")
        lines.append("media_task_status_arguments: only_active=false")
        lines.append("active_media_task_status_arguments: only_active=true")
        lines.append("target_task_id: \(task.displayHandle)")
        appendCleanLine("project_id", context?.projectID, to: &lines)
        appendCleanLine("episode_id", context?.episodeID, to: &lines)
        appendCleanLine("shot_id", context?.shotID, to: &lines)
        appendCleanLine("asset_kind", context?.assetKind, to: &lines)
        appendCleanLine("asset_id", context?.assetID, to: &lines)
        appendCleanLine("review_item_id", context?.reviewItemID, to: &lines)
        if let activeAction = AgentMediaTaskChatHandoff.activeTaskScopeSummaryLine(task: task) {
            lines.append("active_task_actions:")
            lines.append(activeAction)
            lines.append("active_task_follow_up: active_task_actions 已包含可直接调用的 provider 轮询/取消参数；也可先用 refresh_tasks_tool 刷新当前短剧范围。")
        }
        appendReopenEditorActionLines(task: task, sourceImagePath: sourceImagePath, maskPath: maskPath, context: context, to: &lines)
        if let projectID = cleanOptional(context?.projectID ?? ""),
           let shotID = cleanOptional(context?.shotID ?? "") {
            let episodeID = cleanOptional(context?.episodeID ?? "")
            var baseArguments = "project_id=\(projectID)"
            if let episodeID {
                baseArguments += ", episode_id=\(episodeID)"
            }
            baseArguments += ", shot_id=\(shotID)"
            lines.append("open_tasks_tool: short_drama_open_media_tasks")
            lines.append("open_tasks_arguments: \(baseArguments)")
            lines.append("refresh_tasks_tool: short_drama_refresh_media_tasks")
            lines.append("refresh_tasks_arguments: \(baseArguments)")
            if let reviewItemID = cleanOptional(context?.reviewItemID ?? "") {
                lines.append("open_review_tasks_tool: short_drama_open_media_tasks")
                lines.append("open_review_tasks_arguments: \(baseArguments), scope=review_item, review_item_id=\(reviewItemID)")
                lines.append("refresh_review_tasks_tool: short_drama_refresh_media_tasks")
                lines.append("refresh_review_tasks_arguments: \(baseArguments), scope=review_item, review_item_id=\(reviewItemID)")
                lines.append("resolve_review_tool: short_drama_resolve_review_item")
                lines.append("resolve_review_arguments: \(baseArguments), item_id=\(reviewItemID)")
            }
        }
        if let projectID = cleanOptional(context?.projectID ?? ""),
           let assetKind = cleanOptional(context?.assetKind ?? ""),
           let assetID = cleanOptional(context?.assetID ?? "") {
            let assetArguments = "project_id=\(projectID), scope=asset, asset_kind=\(assetKind), asset_id=\(assetID)"
            lines.append("open_asset_tasks_tool: short_drama_open_media_tasks")
            lines.append("open_asset_tasks_arguments: \(assetArguments)")
            lines.append("refresh_asset_tasks_tool: short_drama_refresh_media_tasks")
            lines.append("refresh_asset_tasks_arguments: \(assetArguments)")
            lines.append("attach_reference_tool: short_drama_attach_asset_reference_image")
            lines.append("attach_reference_arguments: project_id=\(projectID), asset_kind=\(assetKind), asset_id=\(assetID), image_path=<completed_artifact_path>")
        }
        lines.append("</image-edit-task-submitted>")

        let prompt = lines.joined(separator: "\n")
        let trimmedInput = appState.agentInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedInput.isEmpty {
            appState.agentInput = prompt
        } else if !appState.agentInput.contains(task.displayHandle) {
            appState.agentInput += "\n\n\(prompt)"
        }
        appState.agentComposerFocusRevision += 1
    }

    private func appendReopenEditorActionLines(
        task: AgentMediaTask,
        sourceImagePath: String,
        maskPath: String,
        context: AgentImageEditorContext?,
        to lines: inout [String]
    ) {
        let operation = task.kind == .imageErase ? "erase" : "inpaint"
        lines.append("")
        lines.append("<image-edit-reopen-action>")
        lines.append("action: reopen_image_editor_with_seed_mask")
        lines.append("source_image_path: \(sourceImagePath)")
        lines.append("mask_path: \(maskPath)")
        lines.append("operation: \(operation)")
        appendCleanLine("project_id", context?.projectID, to: &lines)
        appendCleanLine("episode_id", context?.episodeID, to: &lines)
        appendCleanLine("shot_id", context?.shotID, to: &lines)
        appendCleanLine("asset_kind", context?.assetKind, to: &lines)
        appendCleanLine("asset_id", context?.assetID, to: &lines)
        appendCleanLine("review_item_id", context?.reviewItemID, to: &lines)
        if let projectID = cleanOptional(context?.projectID ?? ""),
           let episodeID = cleanOptional(context?.episodeID ?? ""),
           let shotID = cleanOptional(context?.shotID ?? "") {
            var arguments = "project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID), artifact_path=\(sourceImagePath), mask_path=\(maskPath), operation=\(operation)"
            if let reviewItemID = cleanOptional(context?.reviewItemID ?? "") {
                arguments += ", review_item_id=\(reviewItemID)"
            }
            lines.append("reopen_editor_tool: short_drama_open_image_editor")
            lines.append("reopen_editor_arguments: \(arguments)")
        } else {
            var arguments = "image_path=\(sourceImagePath), mask_path=\(maskPath), operation=\(operation)"
            if let projectID = cleanOptional(context?.projectID ?? "") {
                arguments += ", project_id=\(projectID)"
            }
            if let assetKind = cleanOptional(context?.assetKind ?? "") {
                arguments += ", asset_kind=\(assetKind)"
            }
            if let assetID = cleanOptional(context?.assetID ?? "") {
                arguments += ", asset_id=\(assetID)"
            }
            if let reviewItemID = cleanOptional(context?.reviewItemID ?? "") {
                arguments += ", review_item_id=\(reviewItemID)"
            }
            lines.append("reopen_editor_tool: open_image_editor")
            lines.append("reopen_editor_arguments: \(arguments)")
        }
        lines.append("</image-edit-reopen-action>")
    }

    private func appendImageEditorContextToChat(imageInfo: ImageInfo) {
        let currentMaskURL = lastMaskURL ?? (hasMaskSelection ? exportMask() : nil)
        let currentMaskPath = currentMaskURL?.path
        var lines: [String] = [
            L10n.AgentImageEditor.chatContextLead,
            "",
            "<image-editor-context>",
            "action: inspect_image_editor_from_side_panel",
            "image_path: \(imageInfo.url.path)",
            "operation: \(editOperation.rawValue)",
            "provider: \(submitProvider.rawValue)",
            "has_mask_selection: \(hasMaskSelection)",
            "mask_tool: \(maskTool.rawValue)"
        ]
        if let currentMaskPath {
            lines.append("current_mask_path: \(currentMaskPath)")
            lines.append("last_mask_path: \(currentMaskPath)")
        }
        appendImageEditorContextAnchorLines(to: &lines)
        let currentSubmitArguments = imageEditorSubmitArguments(
            imagePath: imageInfo.url.path,
            maskPath: currentMaskPath,
            operation: editOperation
        )
        lines.append("submit_with_existing_mask_tool: edit_image_with_mask")
        lines.append("submit_with_existing_mask_arguments: \(currentSubmitArguments)")
        lines.append("submit_inpaint_tool: edit_image_with_mask")
        lines.append("submit_inpaint_arguments: \(imageEditorSubmitArguments(imagePath: imageInfo.url.path, maskPath: currentMaskPath, operation: .inpaint))")
        lines.append("submit_erase_tool: edit_image_with_mask")
        lines.append("submit_erase_arguments: \(imageEditorSubmitArguments(imagePath: imageInfo.url.path, maskPath: currentMaskPath, operation: .erase))")
        if let context = appState.agentImageEditorContext,
           let projectID = cleanOptional(context.projectID ?? ""),
           let shotID = cleanOptional(context.shotID ?? "") {
            let episodeID = cleanOptional(context.episodeID ?? "")
            var shotArguments = "project_id=\(projectID)"
            if let episodeID {
                shotArguments += ", episode_id=\(episodeID)"
            }
            shotArguments += ", shot_id=\(shotID)"
            lines.append("open_shot_tasks_tool: short_drama_open_media_tasks")
            lines.append("open_shot_tasks_arguments: \(shotArguments)")
            if let reviewItemID = cleanOptional(context.reviewItemID ?? "") {
                lines.append("open_review_tasks_tool: short_drama_open_media_tasks")
                lines.append("open_review_tasks_arguments: \(shotArguments), scope=review_item, review_item_id=\(reviewItemID)")
                lines.append("refresh_review_tasks_tool: short_drama_refresh_media_tasks")
                lines.append("refresh_review_tasks_arguments: \(shotArguments), scope=review_item, review_item_id=\(reviewItemID)")
                lines.append("resolve_review_tool: short_drama_resolve_review_item")
                lines.append("resolve_review_arguments: \(shotArguments), item_id=\(reviewItemID)")
            }
        }
        if let context = appState.agentImageEditorContext,
           let projectID = cleanOptional(context.projectID ?? ""),
           let assetKind = cleanOptional(context.assetKind ?? ""),
           let assetID = cleanOptional(context.assetID ?? "") {
            let assetArguments = "project_id=\(projectID), scope=asset, asset_kind=\(assetKind), asset_id=\(assetID)"
            lines.append("open_asset_tasks_tool: short_drama_open_media_tasks")
            lines.append("open_asset_tasks_arguments: \(assetArguments)")
            lines.append("refresh_asset_tasks_tool: short_drama_refresh_media_tasks")
            lines.append("refresh_asset_tasks_arguments: \(assetArguments)")
            lines.append("attach_reference_tool: short_drama_attach_asset_reference_image")
            lines.append("attach_reference_arguments: project_id=\(projectID), asset_kind=\(assetKind), asset_id=\(assetID), image_path=<completed_artifact_path>")
        }
        lines.append("</image-editor-context>")

        let prompt = lines.joined(separator: "\n")
        let trimmedInput = appState.agentInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedInput.isEmpty {
            appState.agentInput = prompt
        } else if !appState.agentInput.contains("<image-editor-context>") || !appState.agentInput.contains(imageInfo.url.path) {
            appState.agentInput += "\n\n\(prompt)"
        }
        appState.agentComposerFocusRevision += 1
    }

    private func appendImageEditorContextAnchorLines(to lines: inout [String]) {
        let context = appState.agentImageEditorContext
        appendCleanLine("project_id", context?.projectID, to: &lines)
        appendCleanLine("episode_id", context?.episodeID, to: &lines)
        appendCleanLine("shot_id", context?.shotID, to: &lines)
        appendCleanLine("asset_kind", context?.assetKind, to: &lines)
        appendCleanLine("asset_id", context?.assetID, to: &lines)
        appendCleanLine("review_item_id", context?.reviewItemID, to: &lines)
    }

    private func imageEditorSubmitArguments(imagePath: String, maskPath: String?, operation: ImageEditOperation) -> String {
        let context = appState.agentImageEditorContext
        var pairs: [String] = [
            "image_path=\(imagePath)",
            "mask_path=\(maskPath ?? "<mask_path>")",
            "operation=\(operation.rawValue)",
            "provider=\(submitProvider.rawValue)"
        ]
        appendCleanPair("project_id", context?.projectID, to: &pairs)
        appendCleanPair("episode_id", context?.episodeID, to: &pairs)
        appendCleanPair("shot_id", context?.shotID, to: &pairs)
        appendCleanPair("asset_kind", context?.assetKind, to: &pairs)
        appendCleanPair("asset_id", context?.assetID, to: &pairs)
        appendCleanPair("review_item_id", context?.reviewItemID, to: &pairs)
        return pairs.joined(separator: ", ")
    }

    private func imageEditorContextRows() -> [(String, String)] {
        let context = appState.agentImageEditorContext
        var rows: [(String, String)] = []
        appendContextRow(L10n.AgentImageEditor.contextProject, context?.projectID, to: &rows)
        appendContextRow(L10n.AgentImageEditor.contextEpisode, context?.episodeID, to: &rows)
        appendContextRow(L10n.AgentImageEditor.contextShot, context?.shotID, to: &rows)
        appendContextRow(L10n.AgentImageEditor.contextAssetKind, context?.assetKind, to: &rows)
        appendContextRow(L10n.AgentImageEditor.contextAsset, context?.assetID, to: &rows)
        appendContextRow(L10n.AgentImageEditor.contextReviewItem, context?.reviewItemID, to: &rows)
        return rows
    }

    private func appendContextRow(_ label: String, _ value: String?, to rows: inout [(String, String)]) {
        guard let value = cleanOptional(value ?? "") else { return }
        rows.append((label, value))
    }

    private func appendCleanLine(_ key: String, _ value: String?, to lines: inout [String]) {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
        lines.append("\(key): \(value)")
    }

    private func appendCleanPair(_ key: String, _ value: String?, to pairs: inout [String]) {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
        pairs.append("\(key)=\(value)")
    }

    private func dataURL(for url: URL, fallbackMime: String) throws -> String {
        let data = try Data(contentsOf: url)
        let mime = mimeType(for: url) ?? fallbackMime
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }

    private func mimeType(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "gif": return "image/gif"
        case "tif", "tiff": return "image/tiff"
        case "heic": return "image/heic"
        default: return nil
        }
    }

    private func cleanOptional(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var effectivePrompt: String? {
        cleanOptional(editPrompt) ?? editOperation.defaultPrompt
    }

    private var replicateWorkflowVersion: String? {
        if let explicitVersion = cleanOptional(modelOrVersion) {
            return explicitVersion
        }
        let settings = ReplicateIntegrationStore.loadWorkflowSettings()
        switch editOperation {
        case .inpaint:
            return cleanOptional(settings.inpaintVersion)
        case .erase:
            return cleanOptional(settings.eraseVersion)
        }
    }

    private var modelPlaceholder: String {
        switch submitProvider {
        case .replicate:
            return editOperation.replicateVersionPlaceholder
        case .someIM:
            return L10n.AgentImageEditor.someIMModelPlaceholder
        }
    }

    private var providerHelp: String {
        switch submitProvider {
        case .replicate:
            return editOperation.replicateHelp
        case .someIM:
            return L10n.AgentImageEditor.someIMHelp
        }
    }

    private var replicateConfigurationIssue: String? {
        guard submitProvider == .replicate else { return nil }
        if !ReplicateIntegrationStore.isConfigured {
            return L10n.AgentImageEditor.replicateNeedToken
        }
        if replicateWorkflowVersion == nil {
            switch editOperation {
            case .inpaint:
                return L10n.AgentImageEditor.replicateNeedInpaintVersion
            case .erase:
                return L10n.AgentImageEditor.replicateNeedEraseVersion
            }
        }
        return nil
    }

    private func jsonString(from object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        guard let string = String(data: data, encoding: .utf8) else {
            throw AgentToolError.invalidArgument("Could not encode image edit input JSON.")
        }
        return string
    }

    private var hasMaskSelection: Bool {
        seedMaskInfo != nil || !maskRects.isEmpty || selectionRect != nil || !maskStrokes.isEmpty || !maskEraseStrokes.isEmpty || activeStroke != nil
    }

    private func rectsForMask(imageInfo: ImageInfo) -> [CGRect] {
        (maskRects + [selectionRect].compactMap { $0 })
            .compactMap { imagePixelRect(from: $0, imageInfo: imageInfo) }
    }

    private func strokesForMask(imageInfo: ImageInfo) -> [PixelMaskStroke] {
        let activeAddStroke = brushPaintMode == .add ? activeStroke : nil
        let strokes = maskStrokes + [activeAddStroke].compactMap { $0 }
        return pixelStrokes(from: strokes, imageInfo: imageInfo)
    }

    private func eraseStrokesForMask(imageInfo: ImageInfo) -> [PixelMaskStroke] {
        let activeEraseStroke = brushPaintMode == .subtract ? activeStroke : nil
        let strokes = maskEraseStrokes + [activeEraseStroke].compactMap { $0 }
        return pixelStrokes(from: strokes, imageInfo: imageInfo)
    }

    private func pixelStrokes(from strokes: [MaskStroke], imageInfo: ImageInfo) -> [PixelMaskStroke] {
        return strokes.compactMap { stroke in
            let points = deduplicated(points: stroke.points)
                .compactMap { imagePixelPoint(from: $0, imageInfo: imageInfo) }
            guard !points.isEmpty else { return nil }
            let pixelWidth = max(1, stroke.width * imageScaleFactor(imageInfo: imageInfo))
            return PixelMaskStroke(points: points, width: pixelWidth)
        }
    }

    private func maskSelectionSummary(imageInfo: ImageInfo) -> String? {
        let pixelRects = rectsForMask(imageInfo: imageInfo)
        let pixelStrokes = strokesForMask(imageInfo: imageInfo)
        let pixelEraseStrokes = eraseStrokesForMask(imageInfo: imageInfo)
        guard seedMaskInfo != nil || !pixelRects.isEmpty || !pixelStrokes.isEmpty || !pixelEraseStrokes.isEmpty else { return nil }
        if seedMaskInfo != nil, pixelRects.isEmpty, pixelStrokes.isEmpty, pixelEraseStrokes.isEmpty {
            return L10n.AgentImageEditor.summarySeedOnly(invertMask ? L10n.AgentImageEditor.summaryInvertedBackgroundSuffix : "")
        }
        if pixelRects.count == 1, pixelStrokes.isEmpty, let rect = pixelRects.first {
            return L10n.AgentImageEditor.summaryRect(
                "\(Int(rect.origin.x))",
                "\(Int(rect.origin.y))",
                "\(Int(rect.width))",
                "\(Int(rect.height))",
                invertMask ? L10n.AgentImageEditor.summaryInvertedSuffix : ""
            )
        }
        let totalPixels = pixelRects.reduce(CGFloat(0)) { partial, rect in
            partial + rect.width * rect.height
        }
        let strokeLength = pixelStrokes.reduce(CGFloat(0)) { partial, stroke in
            partial + estimatedLength(points: stroke.points)
        }
        let eraseStrokeLength = pixelEraseStrokes.reduce(CGFloat(0)) { partial, stroke in
            partial + estimatedLength(points: stroke.points)
        }
        let seedPrefix = seedMaskInfo == nil ? "" : L10n.AgentImageEditor.summarySeedPrefix
        return L10n.AgentImageEditor.summaryFull(
            seedPrefix,
            "\(pixelRects.count)",
            "\(pixelStrokes.count)",
            "\(pixelEraseStrokes.count)",
            "\(Int(totalPixels))",
            "\(Int(strokeLength))",
            "\(Int(eraseStrokeLength))",
            invertMask ? L10n.AgentImageEditor.summaryInvertedSuffix : ""
        )
    }

    private func imagePixelRect(from viewRect: CGRect, imageInfo: ImageInfo) -> CGRect? {
        let fitted = fitRect(imageSize: imageInfo.displaySize, in: canvasSize)
        let intersection = viewRect.intersection(fitted)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
            return nil
        }
        let scaleX = imageInfo.pixelSize.width / fitted.width
        let scaleY = imageInfo.pixelSize.height / fitted.height
        let x = (intersection.minX - fitted.minX) * scaleX
        let yFromTop = (intersection.minY - fitted.minY) * scaleY
        let width = intersection.width * scaleX
        let height = intersection.height * scaleY
        let y = imageInfo.pixelSize.height - yFromTop - height
        return CGRect(x: x.rounded(.down), y: y.rounded(.down), width: width.rounded(.up), height: height.rounded(.up))
    }

    private func imagePixelPoint(from viewPoint: CGPoint, imageInfo: ImageInfo) -> CGPoint? {
        let fitted = fitRect(imageSize: imageInfo.displaySize, in: canvasSize)
        guard fitted.contains(viewPoint), fitted.width > 0, fitted.height > 0 else {
            return nil
        }
        let scaleX = imageInfo.pixelSize.width / fitted.width
        let scaleY = imageInfo.pixelSize.height / fitted.height
        let x = (viewPoint.x - fitted.minX) * scaleX
        let yFromTop = (viewPoint.y - fitted.minY) * scaleY
        let y = imageInfo.pixelSize.height - yFromTop
        return CGPoint(
            x: min(max(x, 0), imageInfo.pixelSize.width),
            y: min(max(y, 0), imageInfo.pixelSize.height)
        )
    }

    private func imageScaleFactor(imageInfo: ImageInfo) -> CGFloat {
        let fitted = fitRect(imageSize: imageInfo.displaySize, in: canvasSize)
        guard fitted.width > 0, fitted.height > 0 else { return 1 }
        let scaleX = imageInfo.pixelSize.width / fitted.width
        let scaleY = imageInfo.pixelSize.height / fitted.height
        return (scaleX + scaleY) / 2
    }

    private func fitRect(imageSize: CGSize, in bounds: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return .zero
        }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, 0), canvasSize.width),
            y: min(max(point.y, 0), canvasSize.height)
        )
    }

    private func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    private func deduplicated(points: [CGPoint]) -> [CGPoint] {
        points.reduce(into: []) { result, point in
            guard let last = result.last else {
                result.append(point)
                return
            }
            if distance(from: last, to: point) >= 1 {
                result.append(point)
            }
        }
    }

    private func estimatedLength(points: [CGPoint]) -> CGFloat {
        guard points.count > 1 else { return 0 }
        return zip(points, points.dropFirst()).reduce(CGFloat(0)) { partial, pair in
            partial + distance(from: pair.0, to: pair.1)
        }
    }

    private func distance(from first: CGPoint, to second: CGPoint) -> CGFloat {
        let dx = first.x - second.x
        let dy = first.y - second.y
        return sqrt(dx * dx + dy * dy)
    }

    private struct ImageInfo {
        let url: URL
        let image: NSImage
        let cgImage: CGImage
        let pixelSize: CGSize
        let displaySize: CGSize
    }

    private struct MaskStroke: Equatable {
        var points: [CGPoint]
        var width: CGFloat
    }

    private struct PixelMaskStroke {
        var points: [CGPoint]
        var width: CGFloat
    }

    private enum MaskTool: String, CaseIterable, Identifiable {
        case rectangle
        case brush

        var id: String { rawValue }

        var title: String {
            switch self {
            case .rectangle: return L10n.AgentImageEditor.maskToolRectangle
            case .brush: return L10n.AgentImageEditor.maskToolBrush
            }
        }

        var systemImage: String {
            switch self {
            case .rectangle: return "rectangle.dashed"
            case .brush: return "paintbrush.pointed"
            }
        }

        var helpText: String {
            switch self {
            case .rectangle:
                return L10n.AgentImageEditor.maskToolRectangleHelp
            case .brush:
                return L10n.AgentImageEditor.maskToolBrushHelp
            }
        }
    }

    private enum BrushPaintMode: String, CaseIterable, Identifiable {
        case add
        case subtract

        var id: String { rawValue }

        var title: String {
            switch self {
            case .add: return L10n.AgentImageEditor.brushModeAdd
            case .subtract: return L10n.AgentImageEditor.brushModeEraser
            }
        }

        var systemImage: String {
            switch self {
            case .add: return "paintbrush.pointed"
            case .subtract: return "eraser"
            }
        }

        var tint: Color {
            switch self {
            case .add: return .accentColor
            case .subtract: return .orange
            }
        }
    }

    private enum ImageEditOperation: String, CaseIterable, Identifiable {
        case inpaint
        case erase

        var id: String { rawValue }

        var title: String {
            switch self {
            case .inpaint: return L10n.AgentImageEditor.operationInpaint
            case .erase: return L10n.AgentImageEditor.operationErase
            }
        }

        var submitTitle: String {
            switch self {
            case .inpaint: return L10n.AgentImageEditor.operationSubmitInpaint
            case .erase: return L10n.AgentImageEditor.operationSubmitErase
            }
        }

        var mediaTaskKind: AgentMediaTaskKind {
            switch self {
            case .inpaint: return .imageInpaint
            case .erase: return .imageErase
            }
        }

        var promptPlaceholder: String {
            switch self {
            case .inpaint: return L10n.AgentImageEditor.operationPromptPlaceholderInpaint
            case .erase: return L10n.AgentImageEditor.operationPromptPlaceholderErase
            }
        }

        var defaultPrompt: String? {
            switch self {
            case .inpaint: return nil
            case .erase: return "Erase the selected area and naturally reconstruct the background."
            }
        }

        var missingPromptMessage: String {
            switch self {
            case .inpaint: return L10n.AgentImageEditor.operationMissingPromptInpaint
            case .erase: return L10n.AgentImageEditor.operationMissingPromptErase
            }
        }

        var defaultSomeIMEndpointSuffix: String {
            "images/edits"
        }

        var replicateVersionPlaceholder: String {
            switch self {
            case .inpaint:
                return L10n.AgentImageEditor.replicateVersionPlaceholderInpaint
            case .erase:
                return L10n.AgentImageEditor.replicateVersionPlaceholderErase
            }
        }

        var replicateHelp: String {
            switch self {
            case .inpaint:
                return L10n.AgentImageEditor.replicateHelpInpaint
            case .erase:
                return L10n.AgentImageEditor.replicateHelpErase
            }
        }
    }

    private enum ImageEditSubmitProvider: String, CaseIterable, Identifiable {
        case replicate
        case someIM

        var id: String { rawValue }

        var title: String {
            switch self {
            case .replicate: return "Replicate"
            case .someIM: return "some.im"
            }
        }
    }
}
