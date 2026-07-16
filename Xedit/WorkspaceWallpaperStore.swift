//
//  WorkspaceWallpaperStore.swift
//  WillDeep
//
//  Installs user-selected workspace wallpaper images into WillDeep's own
//  Application Support directory. Keeping a managed copy means the wallpaper
//  survives when the original file is moved, renamed, or lives on removable
//  media.
//

import Foundation
import ImageIO

enum WorkspaceWallpaperStore {
    nonisolated static let maximumFileSize = 64 * 1024 * 1024
    nonisolated static let maximumPixelCount = 80_000_000

    enum StoreError: Error, Equatable {
        case sourceIsNotAFile
        case fileTooLarge
        case unsupportedImage
        case imageTooLarge
        case applicationSupportUnavailable
    }

    nonisolated static func install(
        from sourceURL: URL,
        applicationSupportRoot: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        let source = sourceURL.standardizedFileURL
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw StoreError.sourceIsNotAFile
        }
        guard (values.fileSize ?? 0) <= maximumFileSize else {
            throw StoreError.fileTooLarge
        }

        try validateImage(at: source)

        let directory = try managedDirectory(
            applicationSupportRoot: applicationSupportRoot,
            fileManager: fileManager
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let fileExtension = safeFileExtension(from: source)
        let displayName = safeDisplayName(from: source)
        let stagedURL = directory
            .appendingPathComponent(".wallpaper-stage-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
        let installedURL = directory
            .appendingPathComponent("wallpaper-\(UUID().uuidString)--\(displayName)")
            .appendingPathExtension(fileExtension)

        defer { try? fileManager.removeItem(at: stagedURL) }
        try fileManager.copyItem(at: source, to: stagedURL)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stagedURL.path)
        try fileManager.moveItem(at: stagedURL, to: installedURL)

        removeOtherManagedWallpapers(
            keeping: installedURL,
            in: directory,
            fileManager: fileManager
        )
        return installedURL
    }

    nonisolated static func displayName(for path: String) -> String {
        let filename = URL(fileURLWithPath: path).lastPathComponent
        guard let separator = filename.range(of: "--") else { return filename }
        return String(filename[separator.upperBound...])
    }

    nonisolated static func removeManagedWallpaper(
        at path: String?,
        applicationSupportRoot: URL? = nil,
        fileManager: FileManager = .default
    ) {
        guard let path else { return }
        guard let directory = try? managedDirectory(
            applicationSupportRoot: applicationSupportRoot,
            fileManager: fileManager
        ) else { return }

        let candidate = URL(fileURLWithPath: path).standardizedFileURL
        let candidateDirectory = candidate.deletingLastPathComponent().resolvingSymlinksInPath()
        let managedDirectory = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard candidateDirectory == managedDirectory,
              candidate.lastPathComponent.hasPrefix("wallpaper-") else {
            return
        }
        try? fileManager.removeItem(at: candidate)
    }

    nonisolated static func managedDirectory(
        applicationSupportRoot: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        let root: URL
        if let applicationSupportRoot {
            root = applicationSupportRoot
        } else if let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            root = applicationSupport
        } else {
            throw StoreError.applicationSupportUnavailable
        }

        let applicationDirectoryName = Bundle.main.bundleIdentifier ?? "com.willdeep.app"
        return root
            .appendingPathComponent(applicationDirectoryName, isDirectory: true)
            .appendingPathComponent("Wallpapers", isDirectory: true)
    }

    private nonisolated static func validateImage(at url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw StoreError.unsupportedImage
        }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,
              height > 0 else {
            throw StoreError.unsupportedImage
        }

        let (pixelCount, overflowed) = width.multipliedReportingOverflow(by: height)
        guard !overflowed, pixelCount <= maximumPixelCount else {
            throw StoreError.imageTooLarge
        }
    }

    private nonisolated static func safeFileExtension(from url: URL) -> String {
        let candidate = url.pathExtension.lowercased()
        let allowed = candidate.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
        }
        return allowed && !candidate.isEmpty && candidate.count <= 10 ? candidate : "image"
    }

    private nonisolated static func safeDisplayName(from url: URL) -> String {
        let baseName = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "--", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return baseName.isEmpty ? "custom" : String(baseName.prefix(80))
    }

    private nonisolated static func removeOtherManagedWallpapers(
        keeping installedURL: URL,
        in directory: URL,
        fileManager: FileManager
    ) {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        let installedPath = installedURL.resolvingSymlinksInPath().path
        for url in contents
            where url.resolvingSymlinksInPath().path != installedPath
                && url.lastPathComponent.hasPrefix("wallpaper-") {
            try? fileManager.removeItem(at: url)
        }
    }
}
