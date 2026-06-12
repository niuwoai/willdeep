//
//  ProjectFileListCacheTests.swift
//  XeditTests
//
//  Locks in the invariants of the Quick Open disk cache: SHA-256-based
//  per-project directory stability, schema-version invalidation, mtime/
//  size sensitivity in `differs`, the scan candidate limit, and the
//  ProjectDirectoryExclusions skip list.
//
//  These tests use scratch directories under `FileManager.temporaryDirectory`
//  and never touch the real `~/Library/Caches/.../projects` tree. Cache
//  reads still target the user Caches dir, so we don't test the disk
//  load/save path directly — we exercise everything that can be exercised
//  without a writable injection seam.
//

import Testing
import Foundation
@testable import WillDeep

@Suite
struct ProjectFileListCacheTests {

    // MARK: - cacheURL / SHA-256 stability

    /// Same input path → same cache URL across calls. The directory
    /// name is derived from a SHA-256 hex prefix, so it must be
    /// stable across process boundaries — Swift's `Hasher` is seeded
    /// per process and would silently break the cache between launches.
    @Test
    func cacheURLIsDeterministicForSameRootPath() {
        let path = "/Users/example/repo-A"
        let a = ProjectFileListCache.cacheURL(forRootPath: path)
        let b = ProjectFileListCache.cacheURL(forRootPath: path)
        #expect(a != nil)
        #expect(a == b)
    }

    /// Different inputs produce different cache directories — a
    /// truncated-hash collision here would silently mix two projects'
    /// file lists.
    @Test
    func cacheURLDiffersForDifferentRoots() {
        let urlA = ProjectFileListCache.cacheURL(forRootPath: "/Users/example/repo-A")
        let urlB = ProjectFileListCache.cacheURL(forRootPath: "/Users/example/repo-B")
        #expect(urlA != urlB)
    }

    /// Cache lands inside `<Caches>/<bundleID>/projects/<hash>/filelist.json`
    /// — never inside the project directory. This guard catches
    /// accidental refactors that drop the bundle-id segment and would
    /// otherwise pollute the user's Caches root.
    @Test
    func cacheURLLivesUnderCachesAndEndsInFilelistJSON() {
        let url = ProjectFileListCache.cacheURL(forRootPath: "/tmp/sample")
        #expect(url != nil)
        let path = url?.path ?? ""
        #expect(path.hasSuffix("filelist.json"))
        #expect(path.contains("projects"))
        #expect(path.contains("Caches"))
    }

    // MARK: - Entry equality / differs

    /// `differs` returns false for byte-identical lists — the diff is the
    /// gate between "cache hit, render instantly" and "background scan
    /// invalidates the list". A false positive would cause spurious
    /// re-renders; a false negative would freeze the list at stale state.
    @Test
    func differsReturnsFalseForIdenticalLists() {
        let entries = [
            ProjectFileListCache.Entry(relativePath: "a.swift", mtime: 1.0, size: 10),
            ProjectFileListCache.Entry(relativePath: "b.swift", mtime: 2.0, size: 20)
        ]
        #expect(ProjectFileListCache.differs(entries, entries) == false)
    }

    /// A changed mtime alone (size + path identical) flags as different.
    @Test
    func differsDetectsMtimeChange() {
        let a = [ProjectFileListCache.Entry(relativePath: "x.swift", mtime: 1.0, size: 10)]
        let b = [ProjectFileListCache.Entry(relativePath: "x.swift", mtime: 9.0, size: 10)]
        #expect(ProjectFileListCache.differs(a, b))
    }

    /// A changed size alone flags as different.
    @Test
    func differsDetectsSizeChange() {
        let a = [ProjectFileListCache.Entry(relativePath: "x.swift", mtime: 1.0, size: 10)]
        let b = [ProjectFileListCache.Entry(relativePath: "x.swift", mtime: 1.0, size: 99)]
        #expect(ProjectFileListCache.differs(a, b))
    }

    /// Different membership (added/removed paths) flags as different.
    @Test
    func differsDetectsMembershipChange() {
        let a = [ProjectFileListCache.Entry(relativePath: "x.swift", mtime: 1.0, size: 10)]
        let b: [ProjectFileListCache.Entry] = []
        #expect(ProjectFileListCache.differs(a, b))
    }

    // MARK: - CacheFile codable round-trip

    /// CacheFile must JSON round-trip — that's the whole reason it
    /// exists. The schema field is what `load` matches against to
    /// invalidate older shapes.
    @Test
    func cacheFileRoundTripsThroughJSON() throws {
        let file = ProjectFileListCache.CacheFile(
            schemaVersion: ProjectFileListCache.schemaVersion,
            rootPath: "/tmp/sample",
            generatedAt: Date(timeIntervalSince1970: 1_000_000),
            entries: [
                ProjectFileListCache.Entry(relativePath: "a/b.swift", mtime: 5.5, size: 42)
            ]
        )
        let data = try JSONEncoder().encode(file)
        let decoded = try JSONDecoder().decode(ProjectFileListCache.CacheFile.self, from: data)
        #expect(decoded.schemaVersion == file.schemaVersion)
        #expect(decoded.rootPath == file.rootPath)
        #expect(decoded.entries == file.entries)
    }

    // MARK: - scan(root:limit:)

    /// scan respects the `limit` parameter — large projects must not
    /// monopolize a worker. The candidate cap is `limit * 4` internally
    /// then sorted+truncated to `limit`.
    @Test
    func scanRespectsLimit() throws {
        let tmp = try makeTempProject(fileCount: 12)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let result = ProjectFileListCache.scan(root: tmp, limit: 5)
        #expect(result.entries.count == 5)
        #expect(result.rootPath == tmp.standardizedFileURL.path)
        #expect(result.schemaVersion == ProjectFileListCache.schemaVersion)
    }

    /// Files inside `.build`, `node_modules`, `.git` etc. don't appear
    /// in scan output — the exclusion list is applied as a directory
    /// skip so we don't even descend.
    @Test
    func scanSkipsExcludedDirectoryNames() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try makeFile(at: tmp.appendingPathComponent("keep.swift"), contents: "ok")
        let excluded = tmp.appendingPathComponent("node_modules")
        try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: true)
        try makeFile(at: excluded.appendingPathComponent("ignored.js"), contents: "x")

        let result = ProjectFileListCache.scan(root: tmp, limit: 50)
        let paths = result.entries.map { $0.relativePath }
        #expect(paths.contains("keep.swift"))
        #expect(!paths.contains(where: { $0.contains("node_modules") }))
    }

    /// Sort is by `localizedStandardCompare` on the last path component —
    /// "file2" comes before "file10".
    @Test
    func scanSortsByLocalizedStandardComparison() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        for name in ["file10.swift", "file2.swift", "file1.swift"] {
            try makeFile(at: tmp.appendingPathComponent(name), contents: "x")
        }
        let entries = ProjectFileListCache.scan(root: tmp, limit: 50).entries
        let names = entries.map { ($0.relativePath as NSString).lastPathComponent }
        #expect(names == ["file1.swift", "file2.swift", "file10.swift"])
    }

    /// Entries are stored as paths relative to the scanned root, never as
    /// absolute paths — the cache must survive moving the user's home dir.
    @Test
    func scanProducesRelativePaths() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try makeFile(at: tmp.appendingPathComponent("a.swift"), contents: "x")

        let entries = ProjectFileListCache.scan(root: tmp, limit: 10).entries
        #expect(entries.allSatisfy { !$0.relativePath.hasPrefix("/") })
        #expect(entries.contains(where: { $0.relativePath == "a.swift" }))
    }

    // MARK: - ProjectDirectoryExclusions

    /// Exact directory-name match wins regardless of parent path —
    /// the rule operates on `lastPathComponent`.
    @Test
    func exclusionsRecognizeStandardSkipList() {
        let names = [
            ".angular",
            ".build",
            ".cargo",
            ".dart_tool",
            ".git",
            ".gradle",
            ".mypy_cache",
            ".pnpm-store",
            ".pytest_cache",
            ".ruff_cache",
            ".stack-work",
            ".terraform",
            ".yarn",
            "__pycache__",
            "_build",
            "bazel-bin",
            "bazel-out",
            "bazel-testlogs",
            "node_modules",
            "DerivedData",
            "Pods",
            "deps",
            "dist",
            "vendor",
            "target",
            "bazel-my-workspace"
        ]
        for name in names {
            let url = URL(fileURLWithPath: "/anywhere/\(name)")
            #expect(ProjectDirectoryExclusions.shouldSkip(url),
                    "expected to skip \(name)")
        }
    }

    /// Names not on the skip list are NOT skipped — over-eager matching
    /// here would hide real source directories like `src` or `lib`.
    @Test
    func exclusionsDoNotMatchUnrelatedNames() {
        for name in ["src", "lib", "Sources", "Tests", "app"] {
            let url = URL(fileURLWithPath: "/anywhere/\(name)")
            #expect(!ProjectDirectoryExclusions.shouldSkip(url),
                    "did not expect to skip \(name)")
        }
    }

    // MARK: - fileURLs(from:root:)

    /// `fileURLs` rebuilds absolute URLs from the cached relative paths +
    /// supplied root, which is how QuickOpen renders after a cache hit.
    @Test
    func fileURLsAppendsRelativePathsToRoot() {
        let root = URL(fileURLWithPath: "/tmp/proj")
        let file = ProjectFileListCache.CacheFile(
            schemaVersion: 1,
            rootPath: root.path,
            generatedAt: Date(),
            entries: [
                ProjectFileListCache.Entry(relativePath: "a/b.swift", mtime: 0, size: 0),
                ProjectFileListCache.Entry(relativePath: "c.swift",   mtime: 0, size: 0)
            ]
        )
        let urls = ProjectFileListCache.fileURLs(from: file, root: root)
        #expect(urls.count == 2)
        #expect(urls[0].path.hasSuffix("/tmp/proj/a/b.swift"))
        #expect(urls[1].path.hasSuffix("/tmp/proj/c.swift"))
    }

    // MARK: - Schema version constant

    /// The schema version is the on-disk invalidation gate. Bumping it
    /// is intentional; an accidental decrement would silently keep
    /// reading stale shapes. Lock in the current value so any bump
    /// shows up in this test as a one-line update.
    @Test
    func schemaVersionMatchesExpectedConstant() {
        #expect(ProjectFileListCache.schemaVersion == 1)
    }

    /// The max-cached-projects cap is the FIFO eviction threshold. The
    /// current value is 50; if we ever raise it without considering
    /// disk usage, this test fails as a forcing function.
    @Test
    func maxCachedProjectsMatchesExpectedConstant() {
        #expect(ProjectFileListCache.maxCachedProjects == 50)
    }
}

// MARK: - Test helpers

private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("XeditTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeFile(at url: URL, contents: String) throws {
    try contents.data(using: .utf8)!.write(to: url)
}

private func makeTempProject(fileCount: Int) throws -> URL {
    let tmp = try makeTempDir()
    for i in 0..<fileCount {
        try makeFile(at: tmp.appendingPathComponent("f\(String(format: "%03d", i)).txt"),
                     contents: "content-\(i)")
    }
    return tmp
}
