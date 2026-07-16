//
//  AppStateAgentKnowledgeFolders.swift
//  WillDeep
//
//  Session-scoped folder knowledge sources and recursive change watching.
//

import Darwin
import Foundation

extension AppState {
    func addAgentKnowledgeFolder(url: URL) {
        guard let runtime = activeRuntime ?? activeRuntimeAfterCreatingNewSession() else { return }
        let standardized = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }

        if let index = runtime.knowledgeFolders.firstIndex(where: { $0.id == standardized.path }) {
            runtime.knowledgeFolders[index].isEnabled = true
            runtime.persist(touchUpdatedAt: false)
            indexAgentKnowledgeFolder(id: standardized.path, in: runtime)
            return
        }

        runtime.knowledgeFolders.append(AgentKnowledgeFolder(url: standardized))
        runtime.persist(touchUpdatedAt: false)
        indexAgentKnowledgeFolder(id: standardized.path, in: runtime)
    }

    func toggleAgentKnowledgeFolderEnabled(id: String) {
        guard let runtime = activeRuntime,
              let index = runtime.knowledgeFolders.firstIndex(where: { $0.id == id }) else { return }
        runtime.knowledgeFolders[index].isEnabled.toggle()
        runtime.persist(touchUpdatedAt: false)
    }

    func removeAgentKnowledgeFolder(id: String) {
        guard let runtime = activeRuntime else { return }
        runtime.knowledgeFolders.removeAll { $0.id == id }
        cancelAgentKnowledgeFolderWatchers(sessionID: runtime.id, folderID: id)
        runtime.persist(touchUpdatedAt: false)
    }

    func updateAgentKnowledgeFolderExclusions(id: String, rawPatterns: String) {
        guard let runtime = activeRuntime,
              let index = runtime.knowledgeFolders.firstIndex(where: { $0.id == id }) else { return }
        let patterns = rawPatterns
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        runtime.knowledgeFolders[index].excludedPatterns = patterns
        runtime.persist(touchUpdatedAt: false)
        indexAgentKnowledgeFolder(id: id, in: runtime)
    }

    func startAgentKnowledgeFolderWatchers(for runtime: AgentRuntime) {
        for folder in runtime.knowledgeFolders {
            installAgentKnowledgeFolderWatchers(folder: folder, runtime: runtime)
        }
    }

    func cancelAgentKnowledgeFolderWatchers(sessionID: AgentSession.ID, folderID: String? = nil) {
        let sessionPrefix = sessionID.uuidString + "|"
        let folderPrefix = folderID.map { sessionPrefix + $0 + "|" }
        let keys = agentKnowledgeFolderWatchers.keys.filter { key in
            if let folderPrefix { return key.hasPrefix(folderPrefix) }
            return key.hasPrefix(sessionPrefix)
        }
        for key in keys {
            agentKnowledgeFolderWatchers.removeValue(forKey: key)?.cancel()
        }

        let taskKeys = agentKnowledgeFolderReindexTasks.keys.filter { key in
            if let folderID { return key == sessionPrefix + folderID }
            return key.hasPrefix(sessionPrefix)
        }
        for key in taskKeys {
            agentKnowledgeFolderReindexTasks.removeValue(forKey: key)?.cancel()
        }
        let indexKeys = agentKnowledgeFolderIndexTasks.keys.filter { key in
            if let folderID { return key == sessionPrefix + folderID }
            return key.hasPrefix(sessionPrefix)
        }
        for key in indexKeys {
            agentKnowledgeFolderIndexTasks.removeValue(forKey: key)?.cancel()
        }
        let discoveryKeys = agentKnowledgeFolderWatcherDiscoveryTasks.keys.filter { key in
            if let folderID { return key == sessionPrefix + folderID }
            return key.hasPrefix(sessionPrefix)
        }
        for key in discoveryKeys {
            agentKnowledgeFolderWatcherDiscoveryTasks.removeValue(forKey: key)?.cancel()
        }
    }

    private func indexAgentKnowledgeFolder(id: String, in runtime: AgentRuntime) {
        guard let index = runtime.knowledgeFolders.firstIndex(where: { $0.id == id }) else { return }
        let folder = runtime.knowledgeFolders[index]
        runtime.knowledgeFolders[index].status = .indexing
        runtime.knowledgeFolders[index].errorMessage = nil
        runtime.persist(touchUpdatedAt: false)

        let taskKey = runtime.id.uuidString + "|" + id
        agentKnowledgeFolderIndexTasks[taskKey]?.cancel()
        agentKnowledgeFolderIndexTasks[taskKey] = Task { [weak self, weak runtime] in
            let result = await AgentKnowledgeFolderIndexer.index(
                folderURL: folder.url,
                existingDocuments: folder.documents,
                excludedPatterns: folder.excludedPatterns
            )
            guard !Task.isCancelled, let self, let runtime,
                  let currentIndex = runtime.knowledgeFolders.firstIndex(where: { $0.id == id }) else { return }
            runtime.knowledgeFolders[currentIndex].documents = result.documents
            runtime.knowledgeFolders[currentIndex].skippedFileCount = result.skippedFileCount
            runtime.knowledgeFolders[currentIndex].status = .ready
            runtime.knowledgeFolders[currentIndex].lastIndexedAt = Date()
            runtime.knowledgeFolders[currentIndex].errorMessage = nil
            runtime.persist(touchUpdatedAt: false)
            installAgentKnowledgeFolderWatchers(
                folder: runtime.knowledgeFolders[currentIndex],
                runtime: runtime
            )
            agentKnowledgeFolderIndexTasks[taskKey] = nil
        }
    }

    private func installAgentKnowledgeFolderWatchers(
        folder: AgentKnowledgeFolder,
        runtime: AgentRuntime
    ) {
        let watcherPrefix = runtime.id.uuidString + "|" + folder.id + "|"
        let watcherKeys = agentKnowledgeFolderWatchers.keys.filter { $0.hasPrefix(watcherPrefix) }
        for key in watcherKeys {
            agentKnowledgeFolderWatchers.removeValue(forKey: key)?.cancel()
        }

        let discoveryKey = runtime.id.uuidString + "|" + folder.id
        agentKnowledgeFolderWatcherDiscoveryTasks[discoveryKey]?.cancel()
        agentKnowledgeFolderWatcherDiscoveryTasks[discoveryKey] = Task { [weak self, weak runtime] in
            let directoryURLs = await Task.detached(priority: .utility) {
                Self.knowledgeWatcherDirectories(root: folder.url)
            }.value
            guard !Task.isCancelled, let self, let runtime,
                  runtime.knowledgeFolders.contains(where: { $0.id == folder.id }) else { return }
            for directoryURL in directoryURLs {
                installAgentKnowledgeFolderWatcher(
                    directoryURL: directoryURL,
                    folder: folder,
                    runtime: runtime
                )
            }
            agentKnowledgeFolderWatcherDiscoveryTasks[discoveryKey] = nil
        }
    }

    private nonisolated static func knowledgeWatcherDirectories(root: URL) -> [URL] {
        var directoryURLs: [URL] = [root]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return directoryURLs }
        var visited = 0
        while let url = enumerator.nextObject() as? URL, directoryURLs.count < 128, visited < 10_000 {
            visited += 1
            if Task.isCancelled { break }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                directoryURLs.append(url)
            }
        }
        return directoryURLs
    }

    private func installAgentKnowledgeFolderWatcher(
        directoryURL: URL,
        folder: AgentKnowledgeFolder,
        runtime: AgentRuntime
    ) {
            let descriptor = open(directoryURL.path, O_EVTONLY)
            guard descriptor >= 0 else { return }
            let key = knowledgeFolderWatcherKey(
                sessionID: runtime.id,
                folderID: folder.id,
                directoryPath: directoryURL.path
            )
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .extend, .attrib, .link, .revoke],
                queue: .global(qos: .utility)
            )
            source.setCancelHandler {
                close(descriptor)
            }
            source.setEventHandler { [weak self, weak runtime] in
                Task { @MainActor [weak self, weak runtime] in
                    guard let self, let runtime else { return }
                    scheduleAgentKnowledgeFolderReindex(folderID: folder.id, runtime: runtime)
                }
            }
            agentKnowledgeFolderWatchers[key] = source
            source.resume()
    }

    private func scheduleAgentKnowledgeFolderReindex(folderID: String, runtime: AgentRuntime) {
        let key = runtime.id.uuidString + "|" + folderID
        agentKnowledgeFolderReindexTasks[key]?.cancel()
        agentKnowledgeFolderReindexTasks[key] = Task { [weak self, weak runtime] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, let runtime else { return }
            indexAgentKnowledgeFolder(id: folderID, in: runtime)
            agentKnowledgeFolderReindexTasks[key] = nil
        }
    }

    private func knowledgeFolderWatcherKey(
        sessionID: AgentSession.ID,
        folderID: String,
        directoryPath: String
    ) -> String {
        sessionID.uuidString + "|" + folderID + "|" + directoryPath
    }
}
