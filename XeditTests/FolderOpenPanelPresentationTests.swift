//
//  FolderOpenPanelPresentationTests.swift
//  WillDeepTests
//

import AppKit
import Testing
@testable import WillDeep

extension WillDeepTests {
    @MainActor
    @Test("folder picker uses an independent panel instead of attaching to a global key window")
    func folderPickerUsesStandalonePresentation() {
        let panel = FolderOpenPanelPresentationSpy()

        AppState.presentFolderOpenPanel(panel) { _ in }

        #expect(panel.presentationCount == 1)
    }
}

@MainActor
private final class FolderOpenPanelPresentationSpy: FolderOpenPanelPresenting {
    private(set) var presentationCount = 0

    func presentStandalone(completion: @escaping (NSApplication.ModalResponse) -> Void) {
        presentationCount += 1
    }
}
