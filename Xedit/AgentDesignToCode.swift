//
//  AgentDesignToCode.swift
//  WillDeep
//
//  Host-enforced screenshot-to-code context and visual acceptance.
//

import CoreGraphics
import Foundation

nonisolated enum AgentDesignToCode {
    static let webSkillIdentifier = "design-to-code"
    static let nativeSkillIdentifier = "figma-swiftui"
    static let acceptanceToolName = "design_to_code_acceptance"
    static let maximumGateContinuations = 4
    static let webExperts: Set<AgentExpert> = [.webCoding, .browserOps]

    @MainActor
    static func prepareRuntimeForSlashExecution(_ runtime: AgentRuntime, framework: String?) {
        if prefersWebExecution(framework: framework) {
            runtime.activeExperts.formUnion(webExperts)
        }
    }

    static func prefersWebExecution(framework: String?) -> Bool {
        let normalized = framework?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let nativeMarkers = ["swiftui", "appkit", "uikit", "ios", "macos", "swift"]
        return !nativeMarkers.contains(where: normalized.contains)
    }

    private static let implementationToolNames: Set<String> = [
        "create_file", "edit_file", "apply_patch",
        "claude_code", "codex_cli", "cursor_agent", "cline_cli",
    ]
    private static let captureToolNames: Set<String> = [
        "embedded_browser_capture_screenshot", "chrome_capture_tab",
        "computer_use_get_app_state", "capture_screenshot",
    ]

    static func isVisualImplementationSkill(_ skill: AgentSkillEntry) -> Bool {
        skill.identifier == webSkillIdentifier || skill.identifier == nativeSkillIdentifier
    }

    static func isActive(skills: [AgentSkillEntry], images: [AgentImageAttachment]) -> Bool {
        !images.isEmpty && skills.contains(where: isVisualImplementationSkill)
    }

    /// Chooses the implementation skill for the explicit composer CTA without
    /// relying on natural-language keyword matching. A Swift-only workspace is
    /// native; web, mixed, and unknown workspaces use the web workflow because
    /// it has the broadest render-and-capture path.
    static func preferredSkillIdentifier(workspaceRootPath: String?) -> String {
        guard let rawPath = workspaceRootPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty,
              let entries = try? FileManager.default.contentsOfDirectory(atPath: rawPath) else {
            return webSkillIdentifier
        }
        let looksNative = entries.contains { name in
            name == "Package.swift"
                || name.hasSuffix(".xcodeproj")
                || name.hasSuffix(".xcworkspace")
                || name.hasSuffix(".swift")
        }
        let looksWeb = entries.contains { name in
            name == "package.json"
                || name == "index.html"
                || name.hasPrefix("vite.config.")
                || name.hasPrefix("next.config.")
        }
        return looksNative && !looksWeb ? nativeSkillIdentifier : webSkillIdentifier
    }

    static func sourcePaths(from images: [AgentImageAttachment]) -> [String] {
        images.compactMap(\.filePath).filter { !$0.isEmpty }
    }

    static func promptBlock(skills: [AgentSkillEntry], imagePaths: [String]) -> String? {
        guard skills.contains(where: isVisualImplementationSkill), !imagePaths.isEmpty else { return nil }
        let target = skills.contains(where: { $0.identifier == nativeSkillIdentifier })
            ? "native SwiftUI app"
            : "web frontend"
        let paths = imagePaths.enumerated().map { index, path in
            "- source_\(index + 1): `\(path)`"
        }.joined(separator: "\n")
        return """
        ### Design-to-Code Run Contract

        The attached pixels are the visual source of truth. Their file-backed copies are:
        \(paths)

        Target surface: \(target)

        This is an implementation run, not a design critique or starter-code request. Complete every stage before answering:
        1. Inspect the repository and directly create/edit the production files.
        2. Build or run the implementation and fix compile/runtime errors.
        3. Render the result at the source image's viewport. For web work, first call `embedded_browser_status`, then use `embedded_browser_navigate`; the browser workbench has already been opened for this run. A local `file://` URL is valid for static HTML when a dev server cannot bind. Use Chrome only if the embedded browser reports a concrete failure. Use Computer Use for a native app or as the final visible-UI fallback.
        4. Capture a real rendered screenshot. Do not substitute a source-code inspection or an imagined description.
        5. Call `design_to_code_acceptance` with the source path, rendered screenshot path, and the actual capture surface. If it returns `NEEDS_ITERATION`, fix the material mismatches and repeat render → capture → acceptance.
        6. A final answer is allowed only after the acceptance tool returns `PASS`, or after concrete tool evidence proves the browser/Computer Use surface is unavailable or permission was denied. In the latter case, report the exact blocker and never claim visual completion.
        """
    }

    static func completionGateNotice(toolCalls: ArraySlice<AgentToolCall>) -> String? {
        let succeeded = toolCalls.filter { $0.status == .succeeded }
        let failedOrDenied = toolCalls.filter { $0.status == .failed || $0.status == .denied }
        let implemented = succeeded.contains { implementationToolNames.contains($0.toolName) }
        let captured = succeeded.contains { captureToolNames.contains($0.toolName) }
        let acceptanceCalls = succeeded.filter { $0.toolName == acceptanceToolName }
        let passed = acceptanceCalls.last?.result?.payload.contains("Acceptance status: PASS") == true

        if !implemented {
            return gateNotice(
                missing: "No successful production file edit or delegated coding run is recorded.",
                failures: failedOrDenied
            )
        }
        if !captured {
            return gateNotice(
                missing: "No successful real browser or Computer Use screenshot is recorded.",
                failures: failedOrDenied
            )
        }
        if acceptanceCalls.isEmpty {
            return gateNotice(
                missing: "The rendered screenshot has not been compared with the pasted source through `design_to_code_acceptance`.",
                failures: failedOrDenied
            )
        }
        if !passed {
            return gateNotice(
                missing: "The latest visual acceptance did not pass. Inspect its diff/metrics, fix the implementation, then capture and validate again.",
                failures: failedOrDenied
            )
        }
        return nil
    }

    private static func gateNotice(missing: String, failures: [AgentToolCall]) -> String {
        let failureSummary = failures.suffix(4).map { call in
            "- \(call.toolName): \(call.errorMessage ?? call.result?.summary ?? call.status.rawValue)"
        }.joined(separator: "\n")
        let failuresBlock = failureSummary.isEmpty
            ? "No blocking tool failure is recorded; continue the implementation now."
            : "Recent failed/denied tools:\n\(failureSummary)\nRecover with the documented fallback surface where possible."
        return """
        <design-to-code-completion-gate>
        WillDeep refused the premature final answer because the pasted-image implementation contract is incomplete.
        Missing evidence: \(missing)
        \(failuresBlock)
        Continue using tools. Do not summarize or claim completion until the missing evidence exists. If every browser and Computer Use fallback is genuinely unavailable after concrete attempts, provide a precise blocker report instead of a success claim.
        </design-to-code-completion-gate>
        """
    }
}

enum AgentDesignToCodeTools {
    private static let defaultPassScore = 78.0
    private static let defaultMinimumTextCoverage = 70.0

    static func acceptance(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) throws -> AgentToolResult {
        guard let rootDirectory = context.rootDirectory else { throw AgentToolError.noWorkspace }
        let sourcePath = try requiredString("source_path", arguments: arguments)
        let renderedPath = try requiredString("rendered_path", arguments: arguments)
        let surface = try requiredString("surface", arguments: arguments)
        let allowedSurfaces = ["embedded_browser", "chrome", "computer_use", "mac_screen", "android", "ios_simulator"]
        guard allowedSurfaces.contains(surface) else {
            throw AgentToolError.invalidArgument("surface must be one of: \(allowedSurfaces.joined(separator: ", "))")
        }

        let source = try ImageWorkflowSupport.loadImage(path: sourcePath)
        let rendered = try ImageWorkflowSupport.loadImage(path: renderedPath)
        let comparison = ImageWorkflowSupport.compare(source.image, rendered.image)
        let pixelSimilarity = max(0, 100 - (comparison.meanAbsoluteError / 255 * 100))
        let textCoverage = ocrCoverage(source: source.image, rendered: rendered.image)
        let paletteSimilarity = paletteSimilarity(source: source.image, rendered: rendered.image)
        let score = pixelSimilarity * 0.55 + textCoverage * 0.25 + paletteSimilarity * 0.20
        let passScore = clamped(number(arguments["pass_score"]) ?? defaultPassScore)
        let minimumTextCoverage = clamped(number(arguments["minimum_text_coverage"]) ?? defaultMinimumTextCoverage)
        let passed = score >= passScore && textCoverage >= minimumTextCoverage

        let reportDirectory = rootDirectory
            .appendingPathComponent(".willdeep", isDirectory: true)
            .appendingPathComponent("design-to-code", isDirectory: true)
        try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
        let diffURL = reportDirectory.appendingPathComponent("visual-diff.png")
        try ImageWorkflowSupport.save(comparison.diff, to: diffURL, format: "png")
        let reportURL = rootDirectory.appendingPathComponent("design-qa.md")
        let status = passed ? "PASS" : "NEEDS_ITERATION"
        let viewport = arguments["viewport"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = arguments["notes"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines)
        let report = """
        # Design-to-Code Visual Acceptance

        - Status: **\(status)**
        - Capture surface: `\(surface)`
        - Source: `\(source.url.path)` (\(source.width)×\(source.height))
        - Rendered: `\(rendered.url.path)` (\(rendered.width)×\(rendered.height))
        - Viewport: \(viewport?.isEmpty == false ? viewport! : "not supplied")
        - Composite score: \(format(score)) / 100 (required \(format(passScore)))
        - Pixel similarity: \(format(pixelSimilarity))%
        - Source text coverage: \(format(textCoverage))% (required \(format(minimumTextCoverage))%)
        - Palette similarity: \(format(paletteSimilarity))%
        - Changed pixels: \(format(comparison.changedPercent))%
        - Mean absolute error: \(format(comparison.meanAbsoluteError))
        - Diff: `.willdeep/design-to-code/visual-diff.png`

        ## Notes

        \(notes?.isEmpty == false ? notes! : "No additional notes supplied.")

        ## Next action

        \(passed
            ? "Visual acceptance passed. Preserve this screenshot and report as handoff evidence."
            : "Inspect the diff and screenshot, correct material layout/typography/color/content mismatches, then render, capture, and run acceptance again.")
        """
        try Data(report.utf8).write(to: reportURL, options: [.atomic])

        let diffAttachment = AgentImageAttachment(
            mimeType: "image/png",
            filePath: diffURL.path,
            source: .generated,
            prompt: "Design-to-code visual diff",
            createdAt: Date()
        )
        return AgentToolResult(
            summary: "Design-to-code acceptance \(status.lowercased()) (\(format(score))/100)",
            payload: """
            Acceptance status: \(status)
            Composite score: \(format(score)) / 100
            Required score: \(format(passScore))
            Source text coverage: \(format(textCoverage))%
            Required text coverage: \(format(minimumTextCoverage))%
            Pixel similarity: \(format(pixelSimilarity))%
            Palette similarity: \(format(paletteSimilarity))%
            Changed pixels: \(format(comparison.changedPercent))%
            Mean absolute error: \(format(comparison.meanAbsoluteError))
            Capture surface: \(surface)
            Report: \(reportURL.path)
            Diff: \(diffURL.path)
            \(passed ? "The completion gate may now pass." : "Fix the implementation and repeat real capture + acceptance before finalizing.")
            """,
            images: [diffAttachment]
        )
    }

    private static func requiredString(
        _ name: String,
        arguments: [String: AgentJSONValue]
    ) throws -> String {
        guard let value = arguments[name]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            throw AgentToolError.missingArgument(name)
        }
        return value
    }

    private static func ocrCoverage(source: CGImage, rendered: CGImage) -> Double {
        normalizedOCRCoverage(
            sourceTexts: ((try? ImageWorkflowSupport.recognizeText(in: source)) ?? []).map(\.text),
            renderedTexts: ((try? ImageWorkflowSupport.recognizeText(in: rendered)) ?? []).map(\.text)
        )
    }

    static func normalizedOCRCoverage(sourceTexts: [String], renderedTexts: [String]) -> Double {
        let sourceText = comparableOCRText(sourceTexts.joined(separator: " "))
        guard !sourceText.isEmpty else { return 100 }
        let renderedText = comparableOCRText(renderedTexts.joined(separator: " "))
        guard !renderedText.isEmpty else { return 0 }

        let sourceFragments = characterFragments(sourceText, width: 3)
        let renderedFragments = Set(characterFragments(renderedText, width: 3))
        let matchedCount = sourceFragments.reduce(into: 0) { count, fragment in
            if renderedFragments.contains(fragment) {
                count += 1
            }
        }
        return Double(matchedCount) / Double(sourceFragments.count) * 100
    }

    private static func comparableOCRText(_ value: String) -> String {
        String(value.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }

    private static func characterFragments(_ value: String, width: Int) -> [String] {
        let characters = Array(value)
        guard characters.count > width else { return value.isEmpty ? [] : [value] }
        return (0...(characters.count - width)).map { start in
            String(characters[start..<(start + width)])
        }
    }

    private static func paletteSimilarity(source: CGImage, rendered: CGImage) -> Double {
        let sourceColors = ImageWorkflowSupport.palette(from: source, count: 8).map { $0.color }
        let renderedColors = ImageWorkflowSupport.palette(from: rendered, count: 8).map { $0.color }
        guard !sourceColors.isEmpty, !renderedColors.isEmpty else { return 0 }
        let maximumDistance = sqrt(3 * pow(255.0, 2))
        let averageDistance = sourceColors.map { sourceColor in
            renderedColors.map { renderedColor in
                let red = Double(Int(sourceColor.red) - Int(renderedColor.red))
                let green = Double(Int(sourceColor.green) - Int(renderedColor.green))
                let blue = Double(Int(sourceColor.blue) - Int(renderedColor.blue))
                return sqrt(red * red + green * green + blue * blue)
            }.min() ?? maximumDistance
        }.reduce(0, +) / Double(sourceColors.count)
        return max(0, 100 - averageDistance / maximumDistance * 100)
    }

    private static func clamped(_ value: Double) -> Double {
        min(100, max(0, value))
    }

    private static func number(_ value: AgentJSONValue?) -> Double? {
        switch value {
        case .number(let number): return number
        case .string(let string): return Double(string)
        default: return nil
        }
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
