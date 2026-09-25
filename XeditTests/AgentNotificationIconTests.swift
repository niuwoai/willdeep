import Foundation
import Testing
import UserNotifications
@testable import WillDeep

/// UserNotifications moves an attachment's file into its own store once the
/// request is added. The icon used to live in one shared temp file, so every
/// notification after the first pointed at a file that was already gone and
/// usernoted dropped the whole request.
@Suite
@MainActor
struct AgentNotificationIconTests {
    private let samplePNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02, 0x03])

    private func makeScratchDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-notification-icon-tests-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("each app-icon attachment gets its own file that exists when it is created")
    func appIconAttachmentsUseDistinctFiles() throws {
        let first = try #require(AgentNotificationIcon.attachment())
        let second = try #require(AgentNotificationIcon.attachment())
        defer {
            for url in [first.url, second.url] where FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
        }

        #expect(first.url != second.url)
        #expect(FileManager.default.fileExists(atPath: first.url.path))
        #expect(FileManager.default.fileExists(atPath: second.url.path))
        let iconDirectory = AgentNotificationIcon.directory.standardizedFileURL.path
        #expect(first.url.deletingLastPathComponent().standardizedFileURL.path == iconDirectory)
        #expect(second.url.deletingLastPathComponent().standardizedFileURL.path == iconDirectory)
        #expect(first.identifier == AgentNotificationIcon.attachmentIdentifier)
    }

    @Test("a posted attachment's file disappearing does not break the next one")
    func nextAttachmentSurvivesPreviousFileBeingMoved() throws {
        let directory = makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try #require(AgentNotificationIcon.attachment(pngData: samplePNG, in: directory))
        // Simulate usernoted moving the first file into its data store.
        try FileManager.default.removeItem(at: first.url)

        let second = try #require(AgentNotificationIcon.attachment(pngData: samplePNG, in: directory))
        #expect(second.url != first.url)
        #expect(try Data(contentsOf: second.url) == samplePNG)
    }

    @Test("orphaned icon files older than the stale age are swept, fresh ones are kept")
    func staleFilesAreSwept() throws {
        let directory = makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let now = Date()
        let stale = directory.appendingPathComponent("stale.png")
        let fresh = directory.appendingPathComponent("fresh.png")
        try samplePNG.write(to: stale)
        try samplePNG.write(to: fresh)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-(AgentNotificationIcon.staleFileAge + 60))],
            ofItemAtPath: stale.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-60)],
            ofItemAtPath: fresh.path
        )

        let attachment = try #require(AgentNotificationIcon.attachment(pngData: samplePNG, in: directory, now: now))

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(FileManager.default.fileExists(atPath: attachment.url.path))
    }

    @Test("an unusable icon directory yields no attachment instead of a broken one")
    func unusableDirectoryReturnsNil() throws {
        let scratch = makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let blocker = scratch.appendingPathComponent("not-a-directory")
        try samplePNG.write(to: blocker)

        #expect(AgentNotificationIcon.attachment(pngData: samplePNG, in: blocker) == nil)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
        #expect(leftovers == ["not-a-directory"])
    }
}
