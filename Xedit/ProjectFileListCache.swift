import Foundation
import CryptoKit

/// Cross-session disk cache for a project's Quick Open file list.
///
/// The recurring large-project stall was `QuickOpenPanel` re-walking the whole
/// project tree (`FileManager.enumerator`, capped at 1500 files) synchronously on
/// every keystroke. This store persists the scanned list to disk so a re-opened
/// project can render the list instantly from cache, while a background scan
/// verifies and backfills any changes.
///
/// Design constraints (see product-overview.md "Performance Direction"):
/// - The cache lives in the user Caches area, **never** inside the project
///   directory — so it can't pollute the user's git tree, survives read-only
///   project dirs, and needs no extra sandbox write permission.
/// - Invalidation is layered and cheap: an entry is "unchanged" when its
///   modification time *and* size both match. No content hashing in this phase.
nonisolated enum ProjectFileListCache {
    /// Bump when the on-disk JSON shape changes; a mismatch is treated as a miss.
    static let schemaVersion = 1

    /// Keep at most this many per-project cache directories; older ones are
    /// evicted (by their cache file's modification time) on each write.
    static let maxCachedProjects = 50

    /// Hard cap on URL visits during project scans. File-count caps alone do
    /// not protect repositories with huge generated directory fans.
    static let maxTraversalNodes = 50_000

    struct Entry: Codable, Equatable {
        let relativePath: String
        let mtime: Double
        let size: Int64
    }

    struct CacheFile: Codable {
        let schemaVersion: Int
        let rootPath: String
        let generatedAt: Date
        let entries: [Entry]
    }

    // MARK: - Locations

    private static var projectsBaseURL: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let bundleID = Bundle.main.bundleIdentifier ?? "com.willdeep.app"
        return caches
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
    }

    /// Stable per-project directory name derived from the absolute root path.
    /// Swift's `Hasher`/`hashValue` is seeded per process and unusable across
    /// sessions, so we hash with SHA-256 and keep the first 32 hex chars.
    private static func directoryName(forRootPath rootPath: String) -> String {
        let digest = SHA256.hash(data: Data(rootPath.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(32))
    }

    static func cacheURL(forRootPath rootPath: String) -> URL? {
        guard let base = projectsBaseURL else { return nil }
        return base
            .appendingPathComponent(directoryName(forRootPath: rootPath), isDirectory: true)
            .appendingPathComponent("filelist.json", isDirectory: false)
    }

    // MARK: - Read / write

    /// Returns the cached list, or `nil` on any miss — absent file, decode
    /// failure, schema mismatch, or a `rootPath` that doesn't match the request
    /// (guards against the truncated-hash collision). All misses fall back to a
    /// fresh scan by the caller.
    static func load(forRootPath rootPath: String) -> CacheFile? {
        guard let url = cacheURL(forRootPath: rootPath),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(CacheFile.self, from: data) else {
            return nil
        }
        guard file.schemaVersion == schemaVersion, file.rootPath == rootPath else {
            return nil
        }
        return file
    }

    /// Best-effort atomic write. Failures are swallowed — a cache that can't be
    /// written just means the next open does a full scan.
    static func save(_ file: CacheFile) {
        guard let url = cacheURL(forRootPath: file.rootPath) else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(file)
            try data.write(to: url, options: .atomic)
            evictOldProjectsIfNeeded()
        } catch {
            // Cache is best-effort; ignore write errors.
        }
    }

    // MARK: - Scan

    /// Full enumerator walk producing display-ready, sorted entries. Mirrors the
    /// ordering and limit of `AppState.quickOpenFileURLs` so cached and freshly
    /// scanned lists are directly comparable. Heavy generated directories are
    /// skipped, and candidate collection is capped before sorting so huge
    /// dependency trees cannot monopolize a background worker.
    ///
    /// Callers must run this off the main actor — the enumerator alone can visit
    /// tens of thousands of nodes on a cold project open.
    static func scan(root: URL, limit: Int) -> CacheFile {
        // Resolve symlinks once up front (`/var` → `/private/var`) so the
        // enumerator root and stored `rootPath` share one canonical prefix.
        // Do NOT call `standardizedFileURL` per node — that is the hang hotspot.
        let scanRoot = root.resolvingSymlinksInPath()
        let rootPath = scanRoot.path
        var collected: [(name: String, path: String, mtime: Double, size: Int64)] = []
        let candidateLimit = max(limit * 4, limit)

        if let enumerator = FileManager.default.enumerator(
            at: scanRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            var visited = 0
            for case let url as URL in enumerator {
                visited += 1
                if visited > maxTraversalNodes { break }
                if visited.isMultiple(of: 2_048), Task.isCancelled { break }
                guard let values = try? url.resourceValues(
                    forKeys: [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
                ) else {
                    continue
                }
                if values.isDirectory == true {
                    if ProjectDirectoryExclusions.shouldSkip(url) {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                guard values.isRegularFile == true else { continue }
                let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
                let size = Int64(values.fileSize ?? 0)
                // Keep path strings only — retaining every URL until sort finishes
                // can inflate RSS by hundreds of MB on large trees (old iMac hang).
                collected.append((url.lastPathComponent, url.path, mtime, size))
                if collected.count >= candidateLimit { break }
            }
        }

        let entries = collected
            .sorted { lhs, rhs in
                lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            .prefix(limit)
            .map { item -> Entry in
                Entry(
                    relativePath: relativePath(ofAbsolutePath: item.path, rootPath: rootPath),
                    mtime: item.mtime,
                    size: item.size
                )
            }

        return CacheFile(
            schemaVersion: schemaVersion,
            rootPath: rootPath,
            generatedAt: Date(),
            entries: Array(entries)
        )
    }

    /// Rebuild absolute file URLs for the given root from cached relative paths.
    ///
    /// Uses pure path-string joining — never `URL.appendingPathComponent`, which
    /// on older Foundation may probe the filesystem per call (`getResourceValue`)
    /// and freeze the main thread when reconstructing a large Quick Open list.
    static func fileURLs(from file: CacheFile, root: URL, limit: Int? = nil) -> [URL] {
        let rootPath = root.path
        let capped = limit.map { file.entries.prefix($0) } ?? file.entries.prefix(file.entries.count)
        return capped.map { entry in
            absoluteFileURL(rootPath: rootPath, relativePath: entry.relativePath)
        }
    }

    /// Join `rootPath` + relative path without Foundation filesystem probes.
    static func absoluteFileURL(rootPath: String, relativePath: String) -> URL {
        let trimmed = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.isEmpty {
            return URL(fileURLWithPath: rootPath, isDirectory: true)
        }
        if rootPath.hasSuffix("/") {
            return URL(fileURLWithPath: rootPath + trimmed, isDirectory: false)
        }
        return URL(fileURLWithPath: rootPath + "/" + trimmed, isDirectory: false)
    }

    /// `true` when the two lists differ in membership, ordering, mtime, or size.
    static func differs(_ lhs: [Entry], _ rhs: [Entry]) -> Bool {
        lhs != rhs
    }

    // MARK: - Helpers

    private static func relativePath(ofAbsolutePath filePath: String, rootPath: String) -> String {
        // Fast path: enumerator paths usually already share `rootPath`.
        if let relative = relativePathIfPrefixed(filePath, rootPath: rootPath) {
            return relative
        }
        // Fallback for `/var` vs `/private/var` (only runs on the final capped
        // entry set, never on the 50k-node walk).
        let resolvedFile = URL(fileURLWithPath: filePath).resolvingSymlinksInPath().path
        if let relative = relativePathIfPrefixed(resolvedFile, rootPath: rootPath) {
            return relative
        }
        return filePath
    }

    private static func relativePathIfPrefixed(_ filePath: String, rootPath: String) -> String? {
        guard filePath.hasPrefix(rootPath) else { return nil }
        return String(filePath.dropFirst(rootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Keep only the `maxCachedProjects` most recently written cache directories.
    /// Moved/renamed projects leave orphaned directories (their absolute path
    /// hash changes); this caps unbounded growth without a separate sweep job.
    private static func evictOldProjectsIfNeeded() {
        guard let base = projectsBaseURL else { return }
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ), dirs.count > maxCachedProjects else {
            return
        }

        // Resolve each directory's mtime once up front; doing it inside the
        // sort comparator re-queried file metadata O(n log n) times.
        let sorted = dirs
            .map { url -> (url: URL, mtime: Date) in
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return (url, mtime)
            }
            .sorted { $0.mtime > $1.mtime }

        for stale in sorted.dropFirst(maxCachedProjects) {
            try? FileManager.default.removeItem(at: stale.url)
        }
    }
}

nonisolated enum ProjectDirectoryExclusions {
    private static let names: Set<String> = [
        ".angular",
        ".build",
        ".cache",
        ".cargo",
        ".dart_tool",
        ".direnv",
        ".git",
        ".gradle",
        ".mypy_cache",
        ".next",
        ".nuxt",
        ".parcel-cache",
        ".pnpm-store",
        ".pytest_cache",
        ".ruff_cache",
        ".serverless",
        ".stack-work",
        ".svelte-kit",
        ".swiftpm",
        ".terraform",
        ".turbo",
        ".tox",
        ".venv",
        ".yarn",
        "__pycache__",
        "_build",
        "bazel-bin",
        "bazel-out",
        "bazel-testlogs",
        "bower_components",
        "Carthage",
        "DerivedData",
        "Pods",
        "build",
        "coverage",
        "deps",
        "dist",
        "env",
        "node_modules",
        "out",
        "target",
        "venv",
        "vendor"
    ]

    static func shouldSkip(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return names.contains(name) || name.hasPrefix("bazel-")
    }
}
