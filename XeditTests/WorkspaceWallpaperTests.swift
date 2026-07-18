import AppKit
import Foundation
import ImageIO
import Testing
@testable import WillDeep

struct WorkspaceWallpaperTests {
    @Test("selected wallpaper is copied into managed Application Support storage")
    @MainActor
    func installsWallpaperIntoManagedStorage() throws {
        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("willdeep-wallpaper-tests-\(UUID().uuidString)", isDirectory: true)
        let sourceURL = testRoot.appendingPathComponent("source.png")
        try fileManager.createDirectory(at: testRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: testRoot) }
        try makePNGData().write(to: sourceURL, options: .atomic)

        let installedURL = try WorkspaceWallpaperStore.install(
            from: sourceURL,
            applicationSupportRoot: testRoot,
            fileManager: fileManager
        )
        let expectedDirectory = try WorkspaceWallpaperStore.managedDirectory(
            applicationSupportRoot: testRoot,
            fileManager: fileManager
        )

        #expect(installedURL.deletingLastPathComponent() == expectedDirectory)
        #expect(installedURL.lastPathComponent.hasPrefix("wallpaper-"))
        #expect(WorkspaceWallpaperStore.displayName(for: installedURL.path) == "source.png")
        #expect(fileManager.fileExists(atPath: installedURL.path))
        #expect(try Data(contentsOf: installedURL) == Data(contentsOf: sourceURL))

        WorkspaceWallpaperStore.removeManagedWallpaper(
            at: installedURL.path,
            applicationSupportRoot: testRoot,
            fileManager: fileManager
        )
        #expect(!fileManager.fileExists(atPath: installedURL.path))
    }

    @Test("wallpaper storage rejects files that are not images")
    func rejectsInvalidImages() throws {
        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("willdeep-wallpaper-invalid-\(UUID().uuidString)", isDirectory: true)
        let sourceURL = testRoot.appendingPathComponent("not-an-image.png")
        try fileManager.createDirectory(at: testRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: testRoot) }
        try Data("not an image".utf8).write(to: sourceURL, options: .atomic)

        #expect(throws: WorkspaceWallpaperStore.StoreError.unsupportedImage) {
            try WorkspaceWallpaperStore.install(
                from: sourceURL,
                applicationSupportRoot: testRoot,
                fileManager: fileManager
            )
        }
    }

    @Test("Agent wallpaper effects are opt-in to a configured image and remain bounded")
    func agentWallpaperConfigurationIsBounded() {
        var settings = EditorSettings.default
        #expect(!settings.hasConfiguredAgentWallpaper)

        settings.windowBackgroundImagePath = "builtin-wallpaper://aurora-drift"
        #expect(settings.hasConfiguredAgentWallpaper)

        settings.agentWallpaperEnabled = false
        #expect(!settings.hasConfiguredAgentWallpaper)

        settings.agentWallpaperEnabled = true
        settings.agentWallpaperGlassOpacity = 2
        settings.agentWallpaperSurfaceOpacity = 0
        let normalized = settings.normalized()
        #expect(normalized.agentWallpaperGlassOpacity == 1)
        #expect(normalized.agentWallpaperSurfaceOpacity == 0.2)
        #expect(EditorSettings.default.agentWallpaperSurfaceOpacity >= 0.5)
        #expect(EditorSettings.default.agentWallpaperSurfaceOpacity < 1)
    }

    @Test("workspace wallpaper preference remains backward-compatible")
    @MainActor
    func wallpaperConfigurationUsesExistingPersistedPath() throws {
        var settings = EditorSettings.default
        #expect(!settings.hasConfiguredWorkspaceWallpaper)

        settings.windowBackgroundImagePath = "/tmp/wallpaper.png"
        #expect(settings.hasConfiguredWorkspaceWallpaper)
        #expect(EditorBackgroundImageMode.allCases.contains(.tile))
        #expect(EditorBackgroundImageMode.allCases.allSatisfy { !$0.displayName.isEmpty })

        let encoded = try JSONEncoder().encode(EditorSettings.default)
        var legacyPayload = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacyPayload.removeValue(forKey: "agentWallpaperEnabled")
        legacyPayload.removeValue(forKey: "agentWallpaperGlassEnabled")
        legacyPayload.removeValue(forKey: "agentWallpaperGlassMaterial")
        legacyPayload.removeValue(forKey: "agentWallpaperGlassOpacity")
        legacyPayload.removeValue(forKey: "agentWallpaperSurfaceOpacity")
        let decoded = try JSONDecoder().decode(
            EditorSettings.self,
            from: JSONSerialization.data(withJSONObject: legacyPayload)
        )
        #expect(decoded.agentWallpaperEnabled == EditorSettings.default.agentWallpaperEnabled)
        #expect(decoded.agentWallpaperGlassEnabled == EditorSettings.default.agentWallpaperGlassEnabled)
        #expect(decoded.agentWallpaperGlassMaterial == EditorSettings.default.agentWallpaperGlassMaterial)
        #expect(decoded.agentWallpaperGlassOpacity == EditorSettings.default.agentWallpaperGlassOpacity)
        #expect(decoded.agentWallpaperSurfaceOpacity == EditorSettings.default.agentWallpaperSurfaceOpacity)
    }

    @Test("built-in wallpaper catalog has eight stable 4K resources and thumbnails")
    @MainActor
    func builtInWallpaperCatalogResources() throws {
        let wallpapers = BuiltInWorkspaceWallpaper.all
        #expect(wallpapers.count == 8)
        #expect(Set(wallpapers.map(\.id)).count == wallpapers.count)
        #expect(Set(wallpapers.map(\.persistedPath)).count == wallpapers.count)

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let resources = repositoryRoot
            .appendingPathComponent("Xedit", isDirectory: true)
            .appendingPathComponent("BuiltInWallpapers", isDirectory: true)

        for wallpaper in wallpapers {
            #expect(
                BuiltInWorkspaceWallpaper.wallpaper(forPersistedPath: wallpaper.persistedPath) == wallpaper
            )
            try expectImage(
                at: resources.appendingPathComponent(wallpaper.resourceBaseName).appendingPathExtension("jpg"),
                width: 3_840,
                height: 2_160
            )
            try expectImage(
                at: resources.appendingPathComponent(wallpaper.thumbnailBaseName).appendingPathExtension("jpg"),
                width: 480,
                height: 270
            )
        }
    }

    @Test("custom wallpaper paths remain directly resolvable")
    func customWallpaperPathResolution() throws {
        let path = "/tmp/custom-wallpaper.jpg"
        let resolved = try #require(BuiltInWorkspaceWallpaper.resolvedImageURL(for: path))
        #expect(resolved.path == path)
    }

    @MainActor
    private func makePNGData() throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        bitmap.setColor(.systemBlue, atX: 0, y: 0)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    private func expectImage(at url: URL, width: Int, height: Int) throws {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        #expect((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == width)
        #expect((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == height)
    }
}
