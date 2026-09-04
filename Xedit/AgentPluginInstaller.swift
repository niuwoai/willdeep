//
//  AgentPluginInstaller.swift
//  WillDeep
//
//  Two-phase plugin installation. Sources are staged and validated before a
//  proposal can be approved; activation never executes package build hooks.
//

import Foundation

nonisolated enum AgentPluginInstallSource: Equatable, Sendable {
    case local(URL)
    case archive(URL)
    case git(repository: String, reference: String?)

    var record: AgentPluginInstallSourceRecord {
        switch self {
        case .local(let url):
            return .init(
                kind: .local,
                location: AgentPluginPackageLoader.canonicalFileURL(url).path,
                reference: nil
            )
        case .archive(let url):
            return .init(
                kind: .archive,
                location: AgentPluginPackageLoader.canonicalFileURL(url).path,
                reference: nil
            )
        case .git(let repository, let reference):
            let normalizedReference = reference?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .init(
                kind: .git,
                location: repository.trimmingCharacters(in: .whitespacesAndNewlines),
                reference: normalizedReference?.isEmpty == false ? normalizedReference : nil
            )
        }
    }
}

nonisolated extension AgentPluginInstallSourceRecord {
    var installSource: AgentPluginInstallSource {
        switch kind {
        case .local:
            return .local(URL(fileURLWithPath: location, isDirectory: true))
        case .archive:
            return .archive(URL(fileURLWithPath: location))
        case .git:
            return .git(repository: location, reference: reference)
        }
    }
}

nonisolated struct AgentPluginInstallProposal: Identifiable, Equatable, Sendable {
    let id: UUID
    let source: AgentPluginInstallSource
    let stagedPackageURL: URL
    let package: AgentPluginPackage
    let addedPermissions: [AgentPluginPermission]
}

nonisolated enum AgentPluginInstallerError: LocalizedError, Equatable {
    case unsupportedSource(String)
    case commandFailed(String)
    case packageNotFound
    case ambiguousPackageRoots
    case sameVersionDifferentContents(String)
    case proposalChanged
    case invalidDraftPath(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSource(let value):
            return "Unsupported plugin source: \(value)."
        case .commandFailed(let output):
            return "Plugin source command failed: \(output)."
        case .packageNotFound:
            return "No Codex plugin package was found in the selected source."
        case .ambiguousPackageRoots:
            return "The selected source contains more than one plugin package."
        case .sameVersionDifferentContents(let version):
            return "Plugin version \(version) is already installed with different contents. Publish a new version."
        case .proposalChanged:
            return "The staged plugin changed after approval. Inspect it again before installing."
        case .invalidDraftPath(let path):
            return "Draft path is outside the plugin draft directory: \(path)."
        }
    }
}

nonisolated enum AgentPluginInstaller {
    static func stage(
        source: AgentPluginInstallSource,
        currentWillDeepVersion: String,
        previouslyGrantedPermissions: [AgentPluginPermission] = []
    ) async throws -> AgentPluginInstallProposal {
        try await Task.detached(priority: .utility) {
            let stagingRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("willdeep-plugin-stage-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
            do {
                try materialize(source: source, into: stagingRoot)
                let packageRoot = try locatePackageRoot(in: stagingRoot)
                let package = try AgentPluginPackageLoader.load(
                    packageURL: packageRoot,
                    source: .installed,
                    currentWillDeepVersion: currentWillDeepVersion
                )
                let previous = Set(previouslyGrantedPermissions)
                let requiredPermissions = AgentMCPServerDirectory.requiredPluginPermissions(for: package)
                let added = requiredPermissions
                    .filter { !previous.contains($0) }
                    .sorted { $0.rawValue < $1.rawValue }
                return AgentPluginInstallProposal(
                    id: UUID(),
                    source: source,
                    stagedPackageURL: packageRoot,
                    package: package,
                    addedPermissions: added
                )
            } catch {
                try? FileManager.default.removeItem(at: stagingRoot)
                throw error
            }
        }.value
    }

    static func install(
        proposal: AgentPluginInstallProposal,
        installedRoot: URL = AgentPluginPaths.installedRoot,
        currentWillDeepVersion: String
    ) throws -> AgentPluginPackage {
        let verified = try AgentPluginPackageLoader.load(
            packageURL: proposal.stagedPackageURL,
            source: .installed,
            currentWillDeepVersion: currentWillDeepVersion
        )
        guard verified.digest == proposal.package.digest,
              verified.pluginID == proposal.package.pluginID,
              verified.version == proposal.package.version else {
            throw AgentPluginInstallerError.proposalChanged
        }

        let pluginRoot = installedRoot.appendingPathComponent(verified.pluginID, isDirectory: true)
        let destination = pluginRoot.appendingPathComponent(verified.version, isDirectory: true)
        try FileManager.default.createDirectory(at: pluginRoot, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            let existing = try AgentPluginPackageLoader.load(
                packageURL: destination,
                source: .installed,
                currentWillDeepVersion: currentWillDeepVersion
            )
            guard existing.digest == verified.digest else {
                throw AgentPluginInstallerError.sameVersionDifferentContents(verified.version)
            }
            cleanup(proposal: proposal)
            return existing
        }

        let incoming = pluginRoot.appendingPathComponent(".incoming-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.copyItem(at: proposal.stagedPackageURL, to: incoming)
            let gitMetadata = incoming.appendingPathComponent(".git", isDirectory: true)
            if FileManager.default.fileExists(atPath: gitMetadata.path) {
                try FileManager.default.removeItem(at: gitMetadata)
            }
            let installed = try AgentPluginPackageLoader.load(
                packageURL: incoming,
                source: .installed,
                currentWillDeepVersion: currentWillDeepVersion
            )
            guard installed.digest == verified.digest else {
                throw AgentPluginInstallerError.proposalChanged
            }
            try FileManager.default.moveItem(at: incoming, to: destination)
            cleanup(proposal: proposal)
            return try AgentPluginPackageLoader.load(
                packageURL: destination,
                source: .installed,
                currentWillDeepVersion: currentWillDeepVersion
            )
        } catch {
            try? FileManager.default.removeItem(at: incoming)
            throw error
        }
    }

    static func uninstall(
        package: AgentPluginPackage,
        installedRoot: URL = AgentPluginPaths.installedRoot
    ) throws {
        guard package.source == .installed else { return }
        let root = AgentPluginPackageLoader.canonicalFileURL(installedRoot)
        let target = AgentPluginPackageLoader.canonicalFileURL(package.packageURL)
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard target.path.hasPrefix(prefix) else {
            throw AgentPluginPackageError.resourceOutsidePackage(target.path)
        }
        try FileManager.default.removeItem(at: target)
        let parent = target.deletingLastPathComponent()
        if (try? FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty) == true {
            try? FileManager.default.removeItem(at: parent)
        }
    }

    static func uninstallAllVersions(
        pluginID: AgentPluginID,
        installedRoot: URL = AgentPluginPaths.installedRoot
    ) throws {
        guard AgentPluginPackageLoader.isSafeIdentifier(pluginID) else {
            throw AgentPluginPackageError.invalidIdentifier(pluginID)
        }
        let root = AgentPluginPackageLoader.canonicalFileURL(installedRoot)
        let candidate = root.appendingPathComponent(pluginID, isDirectory: true)
        let target = FileManager.default.fileExists(atPath: candidate.path)
            ? AgentPluginPackageLoader.canonicalFileURL(candidate)
            : candidate.standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard target.path.hasPrefix(prefix) else {
            throw AgentPluginPackageError.resourceOutsidePackage(target.path)
        }
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        // 页面自己的 WebKit 仓（localStorage / IndexedDB）不在包目录里，
        // 删包删不到它。留着既占地方，也让「删了再装」拿到上一次的残留
        // 状态——那是最难查的一类故障。
        let removedPluginID = pluginID
        Task { @MainActor in
            AgentPluginWebsiteDataStore.remove(for: removedPluginID)
        }
    }

    static func cleanup(proposal: AgentPluginInstallProposal) {
        let stagingRoot = proposal.stagedPackageURL
            .pathComponents
            .firstIndex(where: { $0.hasPrefix("willdeep-plugin-stage-") })
            .map { index -> URL in
                var url = URL(fileURLWithPath: "/")
                for component in proposal.stagedPackageURL.pathComponents[1...index] {
                    url.appendPathComponent(component)
                }
                return url
            }
        if let stagingRoot,
           stagingRoot.lastPathComponent.hasPrefix("willdeep-plugin-stage-") {
            try? FileManager.default.removeItem(at: stagingRoot)
        }
    }

    private static func materialize(source: AgentPluginInstallSource, into stagingRoot: URL) throws {
        switch source {
        case .local(let sourceURL):
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw AgentPluginInstallerError.unsupportedSource(sourceURL.path)
            }
            try FileManager.default.copyItem(
                at: sourceURL,
                to: stagingRoot.appendingPathComponent("package", isDirectory: true)
            )
        case .archive(let archiveURL):
            let extensionName = archiveURL.pathExtension.lowercased()
            guard extensionName == "zip" else {
                throw AgentPluginInstallerError.unsupportedSource(archiveURL.lastPathComponent)
            }
            try validateZipEntries(at: archiveURL)
            try runProcess(
                executable: "/usr/bin/ditto",
                arguments: ["-x", "-k", archiveURL.path, stagingRoot.path]
            )
        case .git(let repository, let reference):
            let trimmed = repository.trimmingCharacters(in: .whitespacesAndNewlines)
            let isSCPStyleSSH = trimmed.hasPrefix("git@") && trimmed.contains(":")
            let scheme = URL(string: trimmed)?.scheme?.lowercased()
            guard isSCPStyleSSH || ["https", "ssh"].contains(scheme ?? "") else {
                throw AgentPluginInstallerError.unsupportedSource(repository)
            }
            let checkout = stagingRoot.appendingPathComponent("package", isDirectory: true)
            _ = try runProcessCapturingOutput(
                executable: "/usr/bin/git",
                arguments: ["clone", "--depth", "1", "--no-checkout", trimmed, checkout.path]
            )
            if let reference = reference?.trimmingCharacters(in: .whitespacesAndNewlines),
               !reference.isEmpty {
                _ = try runProcessCapturingOutput(
                    executable: "/usr/bin/git",
                    arguments: ["-C", checkout.path, "fetch", "--depth", "1", "origin", reference]
                )
                _ = try runProcessCapturingOutput(
                    executable: "/usr/bin/git",
                    arguments: ["-C", checkout.path, "checkout", "--detach", "FETCH_HEAD"]
                )
            } else {
                _ = try runProcessCapturingOutput(
                    executable: "/usr/bin/git",
                    arguments: ["-C", checkout.path, "checkout"]
                )
            }
            let gitMetadata = checkout.appendingPathComponent(".git", isDirectory: true)
            if FileManager.default.fileExists(atPath: gitMetadata.path) {
                try FileManager.default.removeItem(at: gitMetadata)
            }
        }
    }

    private static func locatePackageRoot(in root: URL) throws -> URL {
        var matches: [URL] = []
        collectPackageRoots(at: root, depth: 0, maximumDepth: 3, into: &matches)
        if matches.isEmpty { throw AgentPluginInstallerError.packageNotFound }
        if matches.count > 1 { throw AgentPluginInstallerError.ambiguousPackageRoots }
        return matches[0]
    }

    private static func collectPackageRoots(
        at url: URL,
        depth: Int,
        maximumDepth: Int,
        into matches: inout [URL]
    ) {
        let manifest = url.appendingPathComponent(".codex-plugin/plugin.json")
        if FileManager.default.fileExists(atPath: manifest.path) {
            matches.append(url)
            return
        }
        guard depth < maximumDepth,
              let children = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
              ) else { return }
        for child in children {
            guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true else { continue }
            collectPackageRoots(at: child, depth: depth + 1, maximumDepth: maximumDepth, into: &matches)
        }
    }

    private static func runProcess(executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? "exit \(process.terminationStatus)"
            throw AgentPluginInstallerError.commandFailed(String(text.prefix(4_000)))
        }
    }

    private static func validateZipEntries(at archiveURL: URL) throws {
        let listing = try runProcessCapturingOutput(
            executable: "/usr/bin/unzip",
            arguments: ["-Z1", archiveURL.path]
        )
        let entries = listing.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard entries.count <= 20_000 else {
            throw AgentPluginInstallerError.unsupportedSource("ZIP contains too many files")
        }
        for entry in entries {
            let normalized = entry.replacingOccurrences(of: "\\", with: "/")
            let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
            guard !normalized.hasPrefix("/"),
                  !normalized.hasPrefix("~"),
                  !normalized.contains("\0"),
                  !components.contains(where: { $0 == ".." }) else {
                throw AgentPluginPackageError.resourceOutsidePackage(entry)
            }
        }
    }

    private static func runProcessCapturingOutput(
        executable: String,
        arguments: [String]
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw AgentPluginInstallerError.commandFailed(String(text.prefix(4_000)))
        }
        return text
    }
}

nonisolated enum AgentPluginDraftStore {
    static func createDraft(pluginID: String, version: String) throws -> URL {
        guard AppVersion(version) != nil,
              AgentPluginPackageLoader.isSafePathComponent(version) else {
            throw AgentPluginPackageError.invalidVersion(version)
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard !pluginID.isEmpty,
              AgentPluginPackageLoader.isSafePathComponent(pluginID),
              pluginID.unicodeScalars.first.map(CharacterSet.alphanumerics.contains) == true,
              pluginID.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw AgentPluginPackageError.invalidIdentifier(pluginID)
        }
        let root = AgentPluginPaths.draftRoot
            .appendingPathComponent(pluginID, isDirectory: true)
            .appendingPathComponent("\(version)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func write(
        data: Data,
        relativePath: String,
        draftRoot: URL,
        allowedDraftRoot: URL = AgentPluginPaths.draftRoot
    ) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.contains("\0") else {
            throw AgentPluginInstallerError.invalidDraftPath(relativePath)
        }
        let allowedRoot = AgentPluginPackageLoader.canonicalFileURL(allowedDraftRoot)
        let root = AgentPluginPackageLoader.canonicalFileURL(draftRoot)
        let allowedPrefix = allowedRoot.path.hasSuffix("/") ? allowedRoot.path : allowedRoot.path + "/"
        guard root.path.hasPrefix(allowedPrefix) else {
            throw AgentPluginInstallerError.invalidDraftPath(draftRoot.path)
        }
        let target = root.appendingPathComponent(trimmed).standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard target.path.hasPrefix(prefix) else {
            throw AgentPluginInstallerError.invalidDraftPath(relativePath)
        }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty, !components.contains("..") else {
            throw AgentPluginInstallerError.invalidDraftPath(relativePath)
        }
        var current = root
        for component in components.dropLast() {
            current.appendPathComponent(component, isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: current.path, isDirectory: &isDirectory) {
                let values = try current.resourceValues(forKeys: [.isSymbolicLinkKey])
                guard isDirectory.boolValue, values.isSymbolicLink != true else {
                    throw AgentPluginInstallerError.invalidDraftPath(relativePath)
                }
            } else {
                try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false)
            }
            let canonical = AgentPluginPackageLoader.canonicalFileURL(current)
            guard canonical.path.hasPrefix(prefix) else {
                throw AgentPluginInstallerError.invalidDraftPath(relativePath)
            }
        }
        if FileManager.default.fileExists(atPath: target.path) {
            let values = try target.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true else {
                throw AgentPluginInstallerError.invalidDraftPath(relativePath)
            }
        }
        try data.write(to: target, options: .atomic)
        return target
    }
}
