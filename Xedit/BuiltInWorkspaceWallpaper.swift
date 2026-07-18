//
//  BuiltInWorkspaceWallpaper.swift
//  WillDeep
//
//  Catalog and Settings preview for the wallpapers shipped inside the app.
//  Persisted selections use a stable token instead of an App bundle path so
//  they survive Debug/Release moves and application upgrades.
//

import AppKit
import Foundation
import SwiftUI

struct BuiltInWorkspaceWallpaper: Identifiable, Equatable, Sendable {
    nonisolated static let persistedPathPrefix = "willdeep-builtin-wallpaper://"

    let id: String
    let resourceBaseName: String
    let thumbnailBaseName: String

    nonisolated var persistedPath: String {
        Self.persistedPathPrefix + id
    }

    nonisolated func imageURL(in bundle: Bundle = .main) -> URL? {
        Self.resourceURL(named: resourceBaseName, in: bundle)
    }

    nonisolated func thumbnailURL(in bundle: Bundle = .main) -> URL? {
        Self.resourceURL(named: thumbnailBaseName, in: bundle)
    }

    nonisolated static func wallpaper(forPersistedPath path: String) -> Self? {
        guard path.hasPrefix(persistedPathPrefix) else { return nil }
        let id = String(path.dropFirst(persistedPathPrefix.count))
        return all.first { $0.id == id }
    }

    nonisolated static func resolvedImageURL(
        for path: String,
        in bundle: Bundle = .main
    ) -> URL? {
        if path.hasPrefix(persistedPathPrefix) {
            return wallpaper(forPersistedPath: path)?.imageURL(in: bundle)
        }
        return URL(fileURLWithPath: path)
    }

    private nonisolated static func resourceURL(named name: String, in bundle: Bundle) -> URL? {
        bundle.url(
            forResource: name,
            withExtension: "jpg",
            subdirectory: "BuiltInWallpapers"
        ) ?? bundle.url(forResource: name, withExtension: "jpg")
    }

    nonisolated static let pastelDrift = Self(
        id: "pastel-drift",
        resourceBaseName: "willdeep-wallpaper-pastel-drift-4k",
        thumbnailBaseName: "willdeep-wallpaper-pastel-drift-thumb"
    )
    nonisolated static let ringedWorld = Self(
        id: "ringed-world",
        resourceBaseName: "willdeep-wallpaper-ringed-world-4k",
        thumbnailBaseName: "willdeep-wallpaper-ringed-world-thumb"
    )
    nonisolated static let skyGarden = Self(
        id: "sky-garden",
        resourceBaseName: "willdeep-wallpaper-sky-garden-4k",
        thumbnailBaseName: "willdeep-wallpaper-sky-garden-thumb"
    )
    nonisolated static let springQipao = Self(
        id: "spring-qipao",
        resourceBaseName: "willdeep-wallpaper-spring-qipao-4k",
        thumbnailBaseName: "willdeep-wallpaper-spring-qipao-thumb"
    )
    nonisolated static let glacierMirror = Self(
        id: "glacier-mirror",
        resourceBaseName: "willdeep-wallpaper-glacier-mirror-4k",
        thumbnailBaseName: "willdeep-wallpaper-glacier-mirror-thumb"
    )
    nonisolated static let emeraldSteppe = Self(
        id: "emerald-steppe",
        resourceBaseName: "willdeep-wallpaper-emerald-steppe-4k",
        thumbnailBaseName: "willdeep-wallpaper-emerald-steppe-thumb"
    )
    nonisolated static let coralRealm = Self(
        id: "coral-realm",
        resourceBaseName: "willdeep-wallpaper-coral-realm-4k",
        thumbnailBaseName: "willdeep-wallpaper-coral-realm-thumb"
    )
    nonisolated static let auroraSanctuary = Self(
        id: "aurora-sanctuary",
        resourceBaseName: "willdeep-wallpaper-aurora-sanctuary-4k",
        thumbnailBaseName: "willdeep-wallpaper-aurora-sanctuary-thumb"
    )

    nonisolated static let all: [Self] = [
        pastelDrift,
        ringedWorld,
        skyGarden,
        springQipao,
        glacierMirror,
        emeraldSteppe,
        coralRealm,
        auroraSanctuary,
    ]

    var displayName: String {
        L10n.Settings.BuiltInWallpaper.name(id)
    }
}

struct BuiltInWorkspaceWallpaperCard: View {
    let wallpaper: BuiltInWorkspaceWallpaper
    let isSelected: Bool
    let action: () -> Void
    @State private var previewImage: NSImage?

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let previewImage {
                            Image(nsImage: previewImage)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Color.secondary.opacity(0.12)
                        }
                    }
                    .frame(height: 76)
                    .clipped()

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .padding(6)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                Text(wallpaper.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .padding(7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(
                        isSelected ? Color.accentColor : Color.secondary.opacity(0.2),
                        lineWidth: isSelected ? 1.6 : 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(wallpaper.displayName)
        .task(id: wallpaper.id) {
            previewImage = nil
            guard let url = wallpaper.thumbnailURL() else { return }
            let data = await Task.detached(priority: .utility) {
                try? Data(contentsOf: url, options: [.mappedIfSafe])
            }.value
            guard !Task.isCancelled else { return }
            previewImage = data.flatMap(NSImage.init(data:))
        }
    }
}

struct NoWorkspaceWallpaperCard: View {
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.secondary.opacity(0.08))
                        .overlay {
                            Image(systemName: "photo.badge.minus")
                                .font(.system(size: 24, weight: .regular))
                                .foregroundStyle(.secondary)
                        }

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .padding(6)
                    }
                }
                .frame(height: 76)

                Text(L10n.Settings.noBackground)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .padding(7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(
                        isSelected ? Color.accentColor : Color.secondary.opacity(0.2),
                        lineWidth: isSelected ? 1.6 : 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.Settings.noBackground)
    }
}
