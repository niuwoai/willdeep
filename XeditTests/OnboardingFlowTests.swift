import AppKit
import SwiftUI
import Testing
@testable import WillDeep

@Suite
struct OnboardingFlowTests {
    @Test("some.im login precedes custom provider setup")
    func someIMPrecedesProvider() {
        #expect(OnboardingStep.allCases == [.welcome, .someIM, .provider, .voice, .done])
        #expect(OnboardingStep.someIM.next == .provider)
        #expect(OnboardingStep.provider.previous == .someIM)
    }

    @Test("render the redesigned onboarding welcome screen")
    @MainActor
    func renderWelcomeForDesignQA() throws {
        let outputPath = ProcessInfo.processInfo.environment["WILLDEEP_ONBOARDING_QA_OUTPUT"]
            ?? "/tmp/Xedit-onboarding-design-qa.png"
        try render(step: .welcome, to: outputPath)
    }

    @Test("render some.im before provider setup")
    @MainActor
    func renderSomeIMForDesignQA() throws {
        let outputPath = ProcessInfo.processInfo.environment["WILLDEEP_ONBOARDING_SOMEIM_QA_OUTPUT"]
            ?? "/tmp/Xedit-onboarding-some-im-design-qa.png"
        try render(step: .someIM, to: outputPath)
    }

    @MainActor
    private func render(step: OnboardingStep, to outputPath: String) throws {
        var settings = EditorSettings.default
        settings.interfaceSkinID = EditorInterfaceSkin.ricePaper.id
        let appState = AppState(editorSettings: settings)
        let size = NSSize(width: 780, height: 620)
        let root = OnboardingView(
            initialStep: step,
            usesStoredSomeIMState: false,
            preparesSomeIMBrowserLogin: false
        )
            .environmentObject(appState)
            .tint(appState.editorSettings.interfaceSkin.palette.accent)
            .preferredColorScheme(.light)
            .frame(width: size.width, height: size.height)

        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try #require(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }
}
