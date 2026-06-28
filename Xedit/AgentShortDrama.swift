//
//  AgentShortDrama.swift
//  WillDeep
//
//  Lightweight short-drama project structure for Agent-driven media
//  workflows. It stores episodes, shots, characters, scenes, and output
//  artifact paths so skills and provider tools can coordinate without
//  stuffing every storyboard detail into chat history.
//

import Foundation
import Combine
import AppKit
import SwiftUI

enum AgentShortDramaShotStatus: String, Codable, CaseIterable, Identifiable {
    case planned
    case scripting
    case generating
    case ready
    case needsReview

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .planned: return "待规划"
        case .scripting: return "写作中"
        case .generating: return "生成中"
        case .ready: return "已就绪"
        case .needsReview: return "待检查"
        }
    }
}

enum AgentShortDramaReviewItemKind: String, Codable, CaseIterable, Identifiable {
    case continuity
    case prompt
    case redraw
    case erase
    case upscale
    case reshoot
    case note

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .continuity: return "连续性"
        case .prompt: return "提示词"
        case .redraw: return "重绘"
        case .erase: return "擦除"
        case .upscale: return "放大"
        case .reshoot: return "补拍"
        case .note: return "备注"
        }
    }
}

enum AgentShortDramaReviewItemSeverity: String, Codable, CaseIterable, Identifiable {
    case low
    case medium
    case high

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        }
    }
}

enum AgentShortDramaReviewItemStatus: String, Codable, CaseIterable, Identifiable {
    case open
    case doing
    case resolved

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .open: return "待处理"
        case .doing: return "处理中"
        case .resolved: return "已解决"
        }
    }
}

struct AgentShortDramaReviewItem: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var kind: AgentShortDramaReviewItemKind = .note
    var severity: AgentShortDramaReviewItemSeverity = .medium
    var status: AgentShortDramaReviewItemStatus = .open
    var title: String
    var detail: String?
    var suggestedAction: String?
    var artifactPaths: [String] = []
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
}

struct AgentShortDramaCharacter: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var description: String?
    var visualPrompt: String?
    var referenceImagePaths: [String] = []
}

struct AgentShortDramaScene: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var description: String?
    var visualPrompt: String?
    var referenceImagePaths: [String] = []
}

struct AgentShortDramaShot: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var title: String
    var summary: String?
    var prompt: String?
    var status: AgentShortDramaShotStatus = .planned
    var order: Int
    var sceneID: UUID?
    var characterIDs: [UUID] = []
    var artifactPaths: [String] = []
    var selectedArtifactPath: String?
    var reviewItems: [AgentShortDramaReviewItem] = []
    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        title: String,
        summary: String?,
        prompt: String?,
        status: AgentShortDramaShotStatus = .planned,
        order: Int,
        sceneID: UUID?,
        characterIDs: [UUID] = [],
        artifactPaths: [String] = [],
        selectedArtifactPath: String? = nil,
        reviewItems: [AgentShortDramaReviewItem] = [],
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.prompt = prompt
        self.status = status
        self.order = order
        self.sceneID = sceneID
        self.characterIDs = characterIDs
        self.artifactPaths = artifactPaths
        self.selectedArtifactPath = selectedArtifactPath
        self.reviewItems = reviewItems
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decode(String.self, forKey: .title)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
        status = try container.decodeIfPresent(AgentShortDramaShotStatus.self, forKey: .status) ?? .planned
        order = try container.decode(Int.self, forKey: .order)
        sceneID = try container.decodeIfPresent(UUID.self, forKey: .sceneID)
        characterIDs = try container.decodeIfPresent([UUID].self, forKey: .characterIDs) ?? []
        artifactPaths = try container.decodeIfPresent([String].self, forKey: .artifactPaths) ?? []
        selectedArtifactPath = try container.decodeIfPresent(String.self, forKey: .selectedArtifactPath)
        reviewItems = try container.decodeIfPresent([AgentShortDramaReviewItem].self, forKey: .reviewItems) ?? []
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

struct AgentShortDramaEpisode: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var title: String
    var summary: String?
    var order: Int
    var shots: [AgentShortDramaShot] = []
    var updatedAt: Date = Date()
}

struct AgentShortDramaProject: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var title: String
    var logline: String?
    var characters: [AgentShortDramaCharacter] = []
    var scenes: [AgentShortDramaScene] = []
    var episodes: [AgentShortDramaEpisode] = []
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
}

struct AgentShortDramaTaskAnchor: Equatable {
    var projectID: UUID
    var projectTitle: String
    var episodeTitle: String?
    var shotTitle: String?
    var assetKind: String?
    var assetName: String?

    var displayLabel: String {
        var parts = [projectTitle]
        if let episodeTitle {
            parts.append(episodeTitle)
        }
        if let shotTitle {
            parts.append(shotTitle)
        }
        if let assetName {
            let label = assetKind == "scene" ? "场景" : "人物"
            parts.append("\(label)：\(assetName)")
        }
        return parts.joined(separator: " / ")
    }
}

@MainActor
final class AgentShortDramaStore: ObservableObject {
    static let shared = AgentShortDramaStore()

    @Published private(set) var projects: [AgentShortDramaProject]
    @Published var activeProjectID: UUID? {
        didSet { save() }
    }

    private let fileURL: URL

    init(fileURL: URL = AgentShortDramaStore.defaultFileURL()) {
        self.fileURL = fileURL
        let snapshot = Self.load(from: fileURL)
        self.projects = snapshot.projects
        self.activeProjectID = snapshot.activeProjectID ?? snapshot.projects.first?.id
    }

    var activeProject: AgentShortDramaProject? {
        guard let activeProjectID else { return projects.first }
        return projects.first { $0.id == activeProjectID } ?? projects.first
    }

    @discardableResult
    func createProject(title: String, logline: String?) -> AgentShortDramaProject {
        let project = AgentShortDramaProject(title: title, logline: logline)
        projects.insert(project, at: 0)
        activeProjectID = project.id
        save()
        return project
    }

    @discardableResult
    func importProject(_ project: AgentShortDramaProject) -> AgentShortDramaProject {
        var normalized = project
        normalized.episodes = normalized.episodes.map { episode in
            var nextEpisode = episode
            nextEpisode.shots.sort { $0.order < $1.order }
            return nextEpisode
        }
        normalized.episodes.sort { $0.order < $1.order }
        normalized.updatedAt = Date()
        if let index = projects.firstIndex(where: { $0.id == normalized.id }) {
            projects[index] = normalized
        } else {
            projects.insert(normalized, at: 0)
        }
        activeProjectID = normalized.id
        save()
        return normalized
    }

    @discardableResult
    func upsertEpisode(projectID: UUID, episodeID: UUID?, title: String, summary: String?, order: Int?) -> AgentShortDramaEpisode? {
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }) else { return nil }
        let now = Date()
        let resultID: UUID
        if let episodeID, let index = projects[projectIndex].episodes.firstIndex(where: { $0.id == episodeID }) {
            projects[projectIndex].episodes[index].title = title
            projects[projectIndex].episodes[index].summary = summary
            if let order { projects[projectIndex].episodes[index].order = order }
            projects[projectIndex].episodes[index].updatedAt = now
            resultID = episodeID
        } else {
            let nextOrder = order ?? ((projects[projectIndex].episodes.map(\.order).max() ?? 0) + 1)
            let episode = AgentShortDramaEpisode(title: title, summary: summary, order: nextOrder)
            resultID = episode.id
            projects[projectIndex].episodes.append(episode)
        }
        projects[projectIndex].episodes.sort { $0.order < $1.order }
        projects[projectIndex].updatedAt = now
        save()
        return projects[projectIndex].episodes.first { $0.id == resultID }
    }

    @discardableResult
    func upsertCharacter(
        projectID: UUID,
        characterID: UUID?,
        name: String,
        description: String?,
        visualPrompt: String?,
        referenceImagePaths: [String]
    ) -> AgentShortDramaCharacter? {
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }) else { return nil }
        let resultID: UUID
        if let characterID, let index = projects[projectIndex].characters.firstIndex(where: { $0.id == characterID }) {
            projects[projectIndex].characters[index].name = name
            projects[projectIndex].characters[index].description = description
            projects[projectIndex].characters[index].visualPrompt = visualPrompt
            projects[projectIndex].characters[index].referenceImagePaths = referenceImagePaths
            resultID = characterID
        } else {
            let character = AgentShortDramaCharacter(
                name: name,
                description: description,
                visualPrompt: visualPrompt,
                referenceImagePaths: referenceImagePaths
            )
            resultID = character.id
            projects[projectIndex].characters.append(character)
        }
        projects[projectIndex].updatedAt = Date()
        save()
        return projects[projectIndex].characters.first { $0.id == resultID }
    }

    @discardableResult
    func upsertScene(
        projectID: UUID,
        sceneID: UUID?,
        name: String,
        description: String?,
        visualPrompt: String?,
        referenceImagePaths: [String]
    ) -> AgentShortDramaScene? {
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }) else { return nil }
        let resultID: UUID
        if let sceneID, let index = projects[projectIndex].scenes.firstIndex(where: { $0.id == sceneID }) {
            projects[projectIndex].scenes[index].name = name
            projects[projectIndex].scenes[index].description = description
            projects[projectIndex].scenes[index].visualPrompt = visualPrompt
            projects[projectIndex].scenes[index].referenceImagePaths = referenceImagePaths
            resultID = sceneID
        } else {
            let scene = AgentShortDramaScene(
                name: name,
                description: description,
                visualPrompt: visualPrompt,
                referenceImagePaths: referenceImagePaths
            )
            resultID = scene.id
            projects[projectIndex].scenes.append(scene)
        }
        projects[projectIndex].updatedAt = Date()
        save()
        return projects[projectIndex].scenes.first { $0.id == resultID }
    }

    @discardableResult
    func upsertShot(
        projectID: UUID,
        episodeID: UUID,
        shotID: UUID?,
        title: String,
        summary: String?,
        prompt: String?,
        status: AgentShortDramaShotStatus?,
        order: Int?,
        sceneID: UUID?,
        characterIDs: [UUID],
        artifactPaths: [String]
    ) -> AgentShortDramaShot? {
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }),
              let episodeIndex = projects[projectIndex].episodes.firstIndex(where: { $0.id == episodeID }) else {
            return nil
        }
        let now = Date()
        let resultID: UUID
        if let shotID, let index = projects[projectIndex].episodes[episodeIndex].shots.firstIndex(where: { $0.id == shotID }) {
            projects[projectIndex].episodes[episodeIndex].shots[index].title = title
            projects[projectIndex].episodes[episodeIndex].shots[index].summary = summary
            projects[projectIndex].episodes[episodeIndex].shots[index].prompt = prompt
            if let status { projects[projectIndex].episodes[episodeIndex].shots[index].status = status }
            if let order { projects[projectIndex].episodes[episodeIndex].shots[index].order = order }
            projects[projectIndex].episodes[episodeIndex].shots[index].sceneID = sceneID
            projects[projectIndex].episodes[episodeIndex].shots[index].characterIDs = characterIDs
            projects[projectIndex].episodes[episodeIndex].shots[index].artifactPaths = artifactPaths
            if let selected = projects[projectIndex].episodes[episodeIndex].shots[index].selectedArtifactPath,
               !artifactPaths.contains(selected) {
                projects[projectIndex].episodes[episodeIndex].shots[index].selectedArtifactPath = preferredSelectedArtifact(in: artifactPaths)
            } else if projects[projectIndex].episodes[episodeIndex].shots[index].selectedArtifactPath == nil {
                projects[projectIndex].episodes[episodeIndex].shots[index].selectedArtifactPath = preferredSelectedArtifact(in: artifactPaths)
            }
            projects[projectIndex].episodes[episodeIndex].shots[index].updatedAt = now
            resultID = shotID
        } else {
            let nextOrder = order ?? ((projects[projectIndex].episodes[episodeIndex].shots.map(\.order).max() ?? 0) + 1)
            let shot = AgentShortDramaShot(
                title: title,
                summary: summary,
                prompt: prompt,
                status: status ?? .planned,
                order: nextOrder,
                sceneID: sceneID,
                characterIDs: characterIDs,
                artifactPaths: artifactPaths,
                selectedArtifactPath: preferredSelectedArtifact(in: artifactPaths),
                reviewItems: [],
                updatedAt: now
            )
            resultID = shot.id
            projects[projectIndex].episodes[episodeIndex].shots.append(shot)
        }
        projects[projectIndex].episodes[episodeIndex].shots.sort { $0.order < $1.order }
        projects[projectIndex].episodes[episodeIndex].updatedAt = now
        projects[projectIndex].updatedAt = now
        save()
        return projects[projectIndex].episodes[episodeIndex].shots.first { $0.id == resultID }
    }

    @discardableResult
    func deleteEpisode(projectID: UUID, episodeID: UUID) -> AgentShortDramaEpisode? {
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }),
              let episodeIndex = projects[projectIndex].episodes.firstIndex(where: { $0.id == episodeID }) else {
            return nil
        }
        let removed = projects[projectIndex].episodes.remove(at: episodeIndex)
        projects[projectIndex].updatedAt = Date()
        save()
        return removed
    }

    @discardableResult
    func deleteShot(projectID: UUID, episodeID: UUID?, shotID: UUID) -> AgentShortDramaShot? {
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }) else {
            return nil
        }
        let episodeIndex: Int?
        if let episodeID {
            episodeIndex = projects[projectIndex].episodes.firstIndex(where: { $0.id == episodeID })
        } else {
            episodeIndex = projects[projectIndex].episodes.firstIndex { episode in
                episode.shots.contains { $0.id == shotID }
            }
        }
        guard let episodeIndex,
              let shotIndex = projects[projectIndex].episodes[episodeIndex].shots.firstIndex(where: { $0.id == shotID }) else {
            return nil
        }
        let removed = projects[projectIndex].episodes[episodeIndex].shots.remove(at: shotIndex)
        let now = Date()
        projects[projectIndex].episodes[episodeIndex].updatedAt = now
        projects[projectIndex].updatedAt = now
        save()
        return removed
    }

    @discardableResult
    func deleteCharacter(projectID: UUID, characterID: UUID) -> AgentShortDramaCharacter? {
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }),
              let characterIndex = projects[projectIndex].characters.firstIndex(where: { $0.id == characterID }) else {
            return nil
        }
        let removed = projects[projectIndex].characters.remove(at: characterIndex)
        let now = Date()
        for episodeIndex in projects[projectIndex].episodes.indices {
            for shotIndex in projects[projectIndex].episodes[episodeIndex].shots.indices {
                projects[projectIndex].episodes[episodeIndex].shots[shotIndex].characterIDs.removeAll { $0 == characterID }
                projects[projectIndex].episodes[episodeIndex].shots[shotIndex].updatedAt = now
            }
            projects[projectIndex].episodes[episodeIndex].updatedAt = now
        }
        projects[projectIndex].updatedAt = now
        save()
        return removed
    }

    @discardableResult
    func deleteScene(projectID: UUID, sceneID: UUID) -> AgentShortDramaScene? {
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }),
              let sceneIndex = projects[projectIndex].scenes.firstIndex(where: { $0.id == sceneID }) else {
            return nil
        }
        let removed = projects[projectIndex].scenes.remove(at: sceneIndex)
        let now = Date()
        for episodeIndex in projects[projectIndex].episodes.indices {
            for shotIndex in projects[projectIndex].episodes[episodeIndex].shots.indices
                where projects[projectIndex].episodes[episodeIndex].shots[shotIndex].sceneID == sceneID {
                projects[projectIndex].episodes[episodeIndex].shots[shotIndex].sceneID = nil
                projects[projectIndex].episodes[episodeIndex].shots[shotIndex].updatedAt = now
            }
            projects[projectIndex].episodes[episodeIndex].updatedAt = now
        }
        projects[projectIndex].updatedAt = now
        save()
        return removed
    }

    @discardableResult
    func reorderEpisodes(projectID: UUID, orderedIDs: [UUID]) -> [AgentShortDramaEpisode]? {
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }) else {
            return nil
        }
        let existing = projects[projectIndex].episodes
        let requested = orderedIDs.reduce(into: [UUID]()) { result, id in
            if !result.contains(id) {
                result.append(id)
            }
        }
        var reordered: [AgentShortDramaEpisode] = []
        for id in requested {
            if let episode = existing.first(where: { $0.id == id }) {
                reordered.append(episode)
            }
        }
        let remaining = existing
            .filter { episode in !requested.contains(episode.id) }
            .sorted { $0.order < $1.order }
        reordered.append(contentsOf: remaining)
        guard reordered.count == existing.count else {
            return nil
        }
        let now = Date()
        projects[projectIndex].episodes = reordered.enumerated().map { index, episode in
            var next = episode
            next.order = index + 1
            next.updatedAt = now
            return next
        }
        projects[projectIndex].updatedAt = now
        save()
        return projects[projectIndex].episodes
    }

    @discardableResult
    func reorderShots(projectID: UUID, episodeID: UUID, orderedIDs: [UUID]) -> [AgentShortDramaShot]? {
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }),
              let episodeIndex = projects[projectIndex].episodes.firstIndex(where: { $0.id == episodeID }) else {
            return nil
        }
        let existing = projects[projectIndex].episodes[episodeIndex].shots
        let requested = orderedIDs.reduce(into: [UUID]()) { result, id in
            if !result.contains(id) {
                result.append(id)
            }
        }
        var reordered: [AgentShortDramaShot] = []
        for id in requested {
            if let shot = existing.first(where: { $0.id == id }) {
                reordered.append(shot)
            }
        }
        let remaining = existing
            .filter { shot in !requested.contains(shot.id) }
            .sorted { $0.order < $1.order }
        reordered.append(contentsOf: remaining)
        guard reordered.count == existing.count else {
            return nil
        }
        let now = Date()
        projects[projectIndex].episodes[episodeIndex].shots = reordered.enumerated().map { index, shot in
            var next = shot
            next.order = index + 1
            next.updatedAt = now
            return next
        }
        projects[projectIndex].episodes[episodeIndex].updatedAt = now
        projects[projectIndex].updatedAt = now
        save()
        return projects[projectIndex].episodes[episodeIndex].shots
    }

    @discardableResult
    func duplicateShot(
        projectID: UUID,
        episodeID: UUID,
        sourceShotID: UUID,
        title: String?,
        summary: String?,
        prompt: String?,
        order: Int?,
        copyArtifacts: Bool,
        copyReviewItems: Bool
    ) -> AgentShortDramaShot? {
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }),
              let episodeIndex = projects[projectIndex].episodes.firstIndex(where: { $0.id == episodeID }),
              let source = projects[projectIndex].episodes[episodeIndex].shots.first(where: { $0.id == sourceShotID }) else {
            return nil
        }
        let now = Date()
        let nextOrder = order ?? (source.order + 1)
        var duplicated = AgentShortDramaShot(
            title: title ?? "\(source.title) 副本",
            summary: summary ?? source.summary,
            prompt: prompt ?? source.prompt,
            status: .planned,
            order: nextOrder,
            sceneID: source.sceneID,
            characterIDs: source.characterIDs,
            artifactPaths: copyArtifacts ? source.artifactPaths : [],
            selectedArtifactPath: copyArtifacts ? source.selectedArtifactPath : nil,
            reviewItems: copyReviewItems ? source.reviewItems.map { item in
                var next = item
                next.id = UUID()
                next.status = .open
                next.createdAt = now
                next.updatedAt = now
                return next
            } : [],
            updatedAt: now
        )
        duplicated.id = UUID()
        projects[projectIndex].episodes[episodeIndex].shots.append(duplicated)
        projects[projectIndex].episodes[episodeIndex].shots.sort { lhs, rhs in
            if lhs.order == rhs.order {
                return lhs.updatedAt < rhs.updatedAt
            }
            return lhs.order < rhs.order
        }
        projects[projectIndex].episodes[episodeIndex].shots = projects[projectIndex].episodes[episodeIndex].shots.enumerated().map { index, shot in
            var next = shot
            next.order = index + 1
            return next
        }
        projects[projectIndex].episodes[episodeIndex].updatedAt = now
        projects[projectIndex].updatedAt = now
        save()
        return projects[projectIndex].episodes[episodeIndex].shots.first { $0.id == duplicated.id }
    }

    @discardableResult
    func moveShot(
        projectID: UUID,
        sourceEpisodeID: UUID?,
        targetEpisodeID: UUID,
        shotID: UUID,
        order: Int?
    ) -> AgentShortDramaShot? {
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }),
              let targetEpisodeIndex = projects[projectIndex].episodes.firstIndex(where: { $0.id == targetEpisodeID }) else {
            return nil
        }
        let sourceEpisodeIndex: Int?
        if let sourceEpisodeID {
            sourceEpisodeIndex = projects[projectIndex].episodes.firstIndex(where: { $0.id == sourceEpisodeID })
        } else {
            sourceEpisodeIndex = projects[projectIndex].episodes.firstIndex { episode in
                episode.shots.contains { $0.id == shotID }
            }
        }
        guard let sourceEpisodeIndex,
              let sourceShotIndex = projects[projectIndex].episodes[sourceEpisodeIndex].shots.firstIndex(where: { $0.id == shotID }) else {
            return nil
        }
        let now = Date()
        var shot = projects[projectIndex].episodes[sourceEpisodeIndex].shots.remove(at: sourceShotIndex)
        shot.order = order ?? ((projects[projectIndex].episodes[targetEpisodeIndex].shots.map(\.order).max() ?? 0) + 1)
        shot.updatedAt = now
        let adjustedTargetIndex = sourceEpisodeIndex == targetEpisodeIndex ? sourceEpisodeIndex : targetEpisodeIndex
        projects[projectIndex].episodes[adjustedTargetIndex].shots.append(shot)
        projects[projectIndex].episodes[sourceEpisodeIndex].shots = normalizedShots(projects[projectIndex].episodes[sourceEpisodeIndex].shots)
        projects[projectIndex].episodes[sourceEpisodeIndex].updatedAt = now
        if adjustedTargetIndex != sourceEpisodeIndex {
            projects[projectIndex].episodes[adjustedTargetIndex].shots = normalizedShots(projects[projectIndex].episodes[adjustedTargetIndex].shots)
            projects[projectIndex].episodes[adjustedTargetIndex].updatedAt = now
        }
        projects[projectIndex].updatedAt = now
        save()
        return projects[projectIndex].episodes[adjustedTargetIndex].shots.first { $0.id == shotID }
    }

    @discardableResult
    func upsertReviewItem(
        projectID: UUID?,
        episodeID: UUID?,
        shotID: UUID,
        itemID: UUID?,
        kind: AgentShortDramaReviewItemKind,
        severity: AgentShortDramaReviewItemSeverity,
        status: AgentShortDramaReviewItemStatus,
        title: String,
        detail: String?,
        suggestedAction: String?,
        artifactPaths: [String]
    ) -> AgentShortDramaReviewItem? {
        guard let location = findShot(projectID: projectID, episodeID: episodeID, shotID: shotID) else {
            return nil
        }
        let now = Date()
        var shot = projects[location.project].episodes[location.episode].shots[location.shot]
        let resultID: UUID
        if let itemID, let index = shot.reviewItems.firstIndex(where: { $0.id == itemID }) {
            shot.reviewItems[index].kind = kind
            shot.reviewItems[index].severity = severity
            shot.reviewItems[index].status = status
            shot.reviewItems[index].title = title
            shot.reviewItems[index].detail = detail
            shot.reviewItems[index].suggestedAction = suggestedAction
            shot.reviewItems[index].artifactPaths = artifactPaths
            shot.reviewItems[index].updatedAt = now
            resultID = itemID
        } else {
            let item = AgentShortDramaReviewItem(
                kind: kind,
                severity: severity,
                status: status,
                title: title,
                detail: detail,
                suggestedAction: suggestedAction,
                artifactPaths: artifactPaths,
                createdAt: now,
                updatedAt: now
            )
            resultID = item.id
            shot.reviewItems.append(item)
        }
        if shot.reviewItems.contains(where: { $0.status != .resolved }) {
            shot.status = .needsReview
        } else if shot.status == .needsReview {
            shot.status = shot.artifactPaths.isEmpty ? .planned : .ready
        }
        shot.updatedAt = now
        projects[location.project].episodes[location.episode].shots[location.shot] = shot
        projects[location.project].episodes[location.episode].updatedAt = now
        projects[location.project].updatedAt = now
        save()
        return shot.reviewItems.first { $0.id == resultID }
    }

    @discardableResult
    func resolveReviewItem(projectID: UUID?, episodeID: UUID?, shotID: UUID, itemID: UUID) -> AgentShortDramaReviewItem? {
        guard let location = findShot(projectID: projectID, episodeID: episodeID, shotID: shotID) else {
            return nil
        }
        var shot = projects[location.project].episodes[location.episode].shots[location.shot]
        guard let index = shot.reviewItems.firstIndex(where: { $0.id == itemID }) else {
            return nil
        }
        let now = Date()
        shot.reviewItems[index].status = .resolved
        shot.reviewItems[index].updatedAt = now
        if !shot.reviewItems.contains(where: { $0.status != .resolved }) {
            shot.status = shot.artifactPaths.isEmpty ? .planned : .ready
        }
        shot.updatedAt = now
        projects[location.project].episodes[location.episode].shots[location.shot] = shot
        projects[location.project].episodes[location.episode].updatedAt = now
        projects[location.project].updatedAt = now
        save()
        return shot.reviewItems[index]
    }

    @discardableResult
    func updateReviewItemStatus(
        projectID: UUID?,
        episodeID: UUID?,
        shotID: UUID,
        itemID: UUID,
        status: AgentShortDramaReviewItemStatus
    ) -> AgentShortDramaReviewItem? {
        guard let location = findShot(projectID: projectID, episodeID: episodeID, shotID: shotID) else {
            return nil
        }
        var shot = projects[location.project].episodes[location.episode].shots[location.shot]
        guard let index = shot.reviewItems.firstIndex(where: { $0.id == itemID }) else {
            return nil
        }
        if shot.reviewItems[index].status == .resolved {
            return shot.reviewItems[index]
        }
        let now = Date()
        shot.reviewItems[index].status = status
        shot.reviewItems[index].updatedAt = now
        if shot.reviewItems.contains(where: { $0.status != .resolved }) {
            shot.status = .needsReview
        } else {
            shot.status = shot.artifactPaths.isEmpty ? .planned : .ready
        }
        shot.updatedAt = now
        projects[location.project].episodes[location.episode].shots[location.shot] = shot
        projects[location.project].episodes[location.episode].updatedAt = now
        projects[location.project].updatedAt = now
        save()
        return shot.reviewItems[index]
    }

    @discardableResult
    func updateShotStatuses(
        projectID: UUID,
        episodeID: UUID?,
        shotIDs: [UUID],
        status: AgentShortDramaShotStatus
    ) -> [AgentShortDramaShot]? {
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }) else {
            return nil
        }
        let requestedIDs = Set(shotIDs)
        let now = Date()
        var updated: [AgentShortDramaShot] = []
        for episodeIndex in projects[projectIndex].episodes.indices {
            if let episodeID, projects[projectIndex].episodes[episodeIndex].id != episodeID {
                continue
            }
            var didUpdateEpisode = false
            for shotIndex in projects[projectIndex].episodes[episodeIndex].shots.indices {
                let shotID = projects[projectIndex].episodes[episodeIndex].shots[shotIndex].id
                if !requestedIDs.isEmpty, !requestedIDs.contains(shotID) {
                    continue
                }
                projects[projectIndex].episodes[episodeIndex].shots[shotIndex].status = status
                projects[projectIndex].episodes[episodeIndex].shots[shotIndex].updatedAt = now
                updated.append(projects[projectIndex].episodes[episodeIndex].shots[shotIndex])
                didUpdateEpisode = true
            }
            if didUpdateEpisode {
                projects[projectIndex].episodes[episodeIndex].updatedAt = now
            }
        }
        if !updated.isEmpty {
            projects[projectIndex].updatedAt = now
            save()
        }
        return updated
    }

    @discardableResult
    func updateShotLinks(projectID: UUID, episodeID: UUID?, shotIDs: [UUID], updateScene: Bool, sceneID: UUID?, characterIDs: [UUID]?, appendCharacterIDs: Bool, removeCharacterIDs: [UUID]) -> [AgentShortDramaShot]? {
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }) else { return nil }
        let requestedIDs = Set(shotIDs)
        let removeIDs = Set(removeCharacterIDs)
        let now = Date()
        var updated: [AgentShortDramaShot] = []
        for episodeIndex in projects[projectIndex].episodes.indices {
            if let episodeID, projects[projectIndex].episodes[episodeIndex].id != episodeID { continue }
            var didUpdateEpisode = false
            for shotIndex in projects[projectIndex].episodes[episodeIndex].shots.indices {
                let shotID = projects[projectIndex].episodes[episodeIndex].shots[shotIndex].id
                if !requestedIDs.isEmpty, !requestedIDs.contains(shotID) { continue }
                if updateScene { projects[projectIndex].episodes[episodeIndex].shots[shotIndex].sceneID = sceneID }
                if let characterIDs {
                    if appendCharacterIDs {
                        var merged = projects[projectIndex].episodes[episodeIndex].shots[shotIndex].characterIDs
                        for characterID in characterIDs where !merged.contains(characterID) {
                            merged.append(characterID)
                        }
                        projects[projectIndex].episodes[episodeIndex].shots[shotIndex].characterIDs = merged
                    } else {
                        projects[projectIndex].episodes[episodeIndex].shots[shotIndex].characterIDs = characterIDs
                    }
                }
                if !removeIDs.isEmpty { projects[projectIndex].episodes[episodeIndex].shots[shotIndex].characterIDs.removeAll { removeIDs.contains($0) } }
                projects[projectIndex].episodes[episodeIndex].shots[shotIndex].updatedAt = now
                updated.append(projects[projectIndex].episodes[episodeIndex].shots[shotIndex])
                didUpdateEpisode = true
            }
            if didUpdateEpisode { projects[projectIndex].episodes[episodeIndex].updatedAt = now }
        }
        if !updated.isEmpty {
            projects[projectIndex].updatedAt = now
            save()
        }
        return updated
    }

    @discardableResult
    func attachArtifactsToShot(
        projectID: UUID?,
        episodeID: UUID?,
        shotID: UUID,
        artifactPaths: [String],
        status: AgentShortDramaShotStatus?
    ) -> AgentShortDramaShot? {
        guard let location = findShot(projectID: projectID, episodeID: episodeID, shotID: shotID) else {
            return nil
        }
        let cleanPaths = artifactPaths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let now = Date()
        var shot = projects[location.project].episodes[location.episode].shots[location.shot]
        var seen = Set(shot.artifactPaths)
        for path in cleanPaths where seen.insert(path).inserted {
            shot.artifactPaths.append(path)
        }
        if shot.selectedArtifactPath == nil {
            shot.selectedArtifactPath = preferredSelectedArtifact(in: shot.artifactPaths)
        }
        if let status {
            shot.status = status
        }
        shot.updatedAt = now
        projects[location.project].episodes[location.episode].shots[location.shot] = shot
        projects[location.project].episodes[location.episode].updatedAt = now
        projects[location.project].updatedAt = now
        save()
        return shot
    }

    @discardableResult
    func selectShotArtifact(projectID: UUID?, episodeID: UUID?, shotID: UUID, artifactPath: String) -> AgentShortDramaShot? {
        guard let location = findShot(projectID: projectID, episodeID: episodeID, shotID: shotID) else {
            return nil
        }
        let cleanPath = artifactPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPath.isEmpty else { return nil }
        let now = Date()
        var shot = projects[location.project].episodes[location.episode].shots[location.shot]
        if !shot.artifactPaths.contains(cleanPath) {
            shot.artifactPaths.append(cleanPath)
        }
        shot.selectedArtifactPath = cleanPath
        shot.updatedAt = now
        projects[location.project].episodes[location.episode].shots[location.shot] = shot
        projects[location.project].episodes[location.episode].updatedAt = now
        projects[location.project].updatedAt = now
        save()
        return shot
    }

    @discardableResult
    func attachReferenceImages(projectID: UUID, assetKind: String, assetID: UUID, imagePaths: [String]) -> Bool {
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }) else { return false }
        let cleanPaths = imagePaths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleanPaths.isEmpty else { return false }
        let normalizedKind = assetKind.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")

        let didUpdate: Bool
        switch normalizedKind {
        case "character", "characters":
            guard let index = projects[projectIndex].characters.firstIndex(where: { $0.id == assetID }) else {
                return false
            }
            for path in cleanPaths where !projects[projectIndex].characters[index].referenceImagePaths.contains(path) {
                projects[projectIndex].characters[index].referenceImagePaths.append(path)
            }
            didUpdate = true
        case "scene", "scenes", "location", "locations":
            guard let index = projects[projectIndex].scenes.firstIndex(where: { $0.id == assetID }) else {
                return false
            }
            for path in cleanPaths where !projects[projectIndex].scenes[index].referenceImagePaths.contains(path) {
                projects[projectIndex].scenes[index].referenceImagePaths.append(path)
            }
            didUpdate = true
        default:
            return false
        }

        if didUpdate {
            projects[projectIndex].updatedAt = Date()
            save()
        }
        return didUpdate
    }

    func project(id: UUID?) -> AgentShortDramaProject? {
        guard let id else { return activeProject }
        return projects.first { $0.id == id }
    }

    func setActiveProject(id: UUID) {
        guard projects.contains(where: { $0.id == id }) else { return }
        activeProjectID = id
    }

    func anchor(for task: AgentMediaTask) -> AgentShortDramaTaskAnchor? {
        guard let projectID = uuid(from: task.projectID) ?? uuid(from: task.projectPath),
              let project = projects.first(where: { $0.id == projectID }) else {
            return nil
        }

        let episodeID = uuid(from: task.episodeID)
        let shotID = uuid(from: task.shotID)
        var episodeTitle: String?
        var shotTitle: String?
        if let episode = project.episodes.first(where: { episode in
            guard let episodeID else { return false }
            return episode.id == episodeID
        }) {
            episodeTitle = episode.title
            if let shot = episode.shots.first(where: { shot in
                guard let shotID else { return false }
                return shot.id == shotID
            }) {
                shotTitle = shot.title
            }
        } else if let shotID {
            for episode in project.episodes {
                if let shot = episode.shots.first(where: { $0.id == shotID }) {
                    episodeTitle = episode.title
                    shotTitle = shot.title
                    break
                }
            }
        }

        let normalizedAssetKind = task.assetKind?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        let assetID = uuid(from: task.assetID)
        let assetName: String?
        switch normalizedAssetKind {
        case "character", "characters":
            assetName = assetID.flatMap { id in project.characters.first { $0.id == id }?.name }
        case "scene", "scenes", "location", "locations":
            assetName = assetID.flatMap { id in project.scenes.first { $0.id == id }?.name }
        default:
            assetName = nil
        }

        return AgentShortDramaTaskAnchor(
            projectID: project.id,
            projectTitle: project.title,
            episodeTitle: episodeTitle,
            shotTitle: shotTitle,
            assetKind: normalizedAssetKind,
            assetName: assetName
        )
    }

    private func normalizedShots(_ shots: [AgentShortDramaShot]) -> [AgentShortDramaShot] {
        shots.sorted { lhs, rhs in
            if lhs.order == rhs.order {
                return lhs.updatedAt < rhs.updatedAt
            }
            return lhs.order < rhs.order
        }.enumerated().map { index, shot in
            var next = shot
            next.order = index + 1
            return next
        }
    }

    private func save() {
        let snapshot = Snapshot(projects: projects, activeProjectID: activeProjectID)
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            print("AgentShortDramaStore: failed to save projects: \(error)")
        }
    }

    private static func load(from url: URL) -> Snapshot {
        guard let data = try? Data(contentsOf: url) else {
            return Snapshot(projects: [], activeProjectID: nil)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Snapshot.self, from: data)) ?? Snapshot(projects: [], activeProjectID: nil)
    }

    private func findShot(projectID: UUID?, episodeID: UUID?, shotID: UUID) -> (project: Int, episode: Int, shot: Int)? {
        for projectIndex in projects.indices {
            if let projectID, projects[projectIndex].id != projectID { continue }
            for episodeIndex in projects[projectIndex].episodes.indices {
                if let episodeID, projects[projectIndex].episodes[episodeIndex].id != episodeID { continue }
                if let shotIndex = projects[projectIndex].episodes[episodeIndex].shots.firstIndex(where: { $0.id == shotID }) {
                    return (projectIndex, episodeIndex, shotIndex)
                }
            }
        }
        return nil
    }

    private func uuid(from value: String?) -> UUID? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return UUID(uuidString: value)
    }

    private func preferredSelectedArtifact(in paths: [String]) -> String? {
        paths.first(where: isImagePath) ?? paths.first
    }

    func isImagePath(_ path: String) -> Bool {
        ["png", "jpg", "jpeg", "webp", "gif", "tif", "tiff", "heic"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    nonisolated private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("WillDeep/short-drama/projects.json", isDirectory: false)
    }

    private struct Snapshot: Codable {
        var projects: [AgentShortDramaProject]
        var activeProjectID: UUID?
    }
}

struct AgentShortDramaPanel: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var store: AgentShortDramaStore
    var width: CGFloat

    @State private var generatingKeys: Set<String> = []
    @State private var reviewActionKeys: Set<String> = []
    @State var statusMessage = ""
    @State var lastProductionExport: AgentShortDramaProductionExporter.ExportResult?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                mediaTaskHealthSummary(
                    tasks: allProjectMediaTasks(),
                    scope: nil,
                    title: "全部任务"
                )
                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if lastProductionExport != nil {
                    productionExportImportActions
                }
                if store.projects.isEmpty {
                    emptyState
                } else {
                    ForEach(store.projects) { project in
                        projectCard(project)
                    }
                }
            }
            .padding(12)
        }
        .frame(width: width)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("短剧项目")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(store.projects.count) 个项目")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                exportShortDramaPlanTemplate()
            } label: {
                Image(systemName: "doc.badge.plus")
            }
            .buttonStyle(.borderless)
            .help("生成短剧规划 JSON 模板")

            Button {
                importShortDramaPlanFromFile(dryRun: true)
            } label: {
                Image(systemName: "checklist")
            }
            .buttonStyle(.borderless)
            .help("预检短剧规划 JSON")

            Button {
                importShortDramaPlanFromFile(dryRun: false)
            } label: {
                Image(systemName: "tray.and.arrow.down")
            }
            .buttonStyle(.borderless)
            .help("导入短剧规划 JSON")

            Button {
                exportActiveProject()
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(.borderless)
            .disabled(store.activeProject == nil)
            .help("导出短剧制作包")

            Button {
                showStoryboardWidget()
            } label: {
                Image(systemName: "rectangle.grid.2x2")
            }
            .buttonStyle(.borderless)
            .disabled(store.activeProject == nil || appState.activeRuntime == nil)
            .help(appState.activeRuntime == nil ? "请先创建 Agent 会话" : "生成网页分镜板")

            Button {
                _ = store.createProject(title: "未命名短剧", logline: nil)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("新建短剧项目")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.stack.badge.play")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text("还没有短剧项目")
                .font(.system(size: 13, weight: .semibold))
            Text("Agent 或 Skill 创建项目后，集数、分镜、人物和场景会显示在这里。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private func projectCard(_ project: AgentShortDramaProject) -> some View {
        let summary = projectStructureSummary(project)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(project.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                    if let logline = project.logline, !logline.isEmpty {
                        Text(logline)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                Spacer()
                Button {
                    appendProjectContextToChat(project)
                } label: {
                    Image(systemName: "text.bubble")
                }
                .buttonStyle(.borderless)
                .help("发送项目结构到聊天")
                if store.activeProjectID == project.id {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            HStack(spacing: 8) {
                metric("集", project.episodes.count)
                metric("分镜", project.episodes.reduce(0) { $0 + $1.shots.count })
                metric("人物", project.characters.count)
                metric("场景", project.scenes.count)
                mediaTaskBadge(
                    tasks: mediaTasks(project: project),
                    scope: mediaTaskScope(project: project)
                )
                Button {
                    openMediaTasksPanel(scope: mediaTaskScope(project: project))
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .help("查看全剧媒体任务")
                if missingAssetReferenceCount(project) > 0 {
                    Button {
                        submitMissingAssetReferences(project: project)
                    } label: {
                        Image(systemName: "sparkles.rectangle.stack")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .disabled(isGeneratingMissingAssetReferences(project))
                    .help("补齐缺失的人物/场景参考图")
                }
            }

            productionGapActionStrip(
                missingImages: summary.missingImageCount,
                missingVideos: summary.missingVideoCount,
                openReviews: summary.openReviewCount,
                missingAssetReferences: missingAssetReferenceCount(project),
                openMediaTasks: { openMediaTasksPanel(scope: mediaTaskScope(project: project)) },
                sendImageContext: { appendProductionGapActionToChat(project: project, episode: nil, action: .missingImages) },
                sendVideoContext: { appendProductionGapActionToChat(project: project, episode: nil, action: .missingVideos) },
                sendReviewContext: { appendProductionGapActionToChat(project: project, episode: nil, action: .openReviews) },
                generateAssetReferences: { submitMissingAssetReferences(project: project) },
                isGeneratingAssetReferences: isGeneratingMissingAssetReferences(project)
            )

            mediaTaskHealthSummary(
                tasks: mediaTasks(project: project),
                scope: mediaTaskScope(project: project),
                title: "任务"
            )

            if !project.characters.isEmpty || !project.scenes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    if !project.characters.isEmpty {
                        assetSection(
                            title: "人物",
                            systemImage: "person.crop.circle",
                            items: project.characters.prefix(3).map {
                                ShortDramaAssetSummary(
                                    id: $0.id,
                                    projectID: project.id,
                                    assetKind: "character",
                                    name: $0.name,
                                    detail: clean($0.visualPrompt) ?? clean($0.description),
                                    referenceImagePaths: $0.referenceImagePaths
                                )
                            },
                            generateReference: { item in
                                submitAssetMedia(project: project, asset: item)
                            },
                            isGeneratingReference: { item in
                                isGenerating(asset: item)
                            },
                            mediaTasks: { item in
                                mediaTasks(project: project, asset: item)
                            },
                            mediaTaskScope: { item in
                                mediaTaskScope(project: project, asset: item)
                            },
                            appendContext: { item in
                                appendAssetContextToChat(project: project, asset: item)
                            }
                        )
                    }
                    if !project.scenes.isEmpty {
                        assetSection(
                            title: "场景",
                            systemImage: "photo.on.rectangle.angled",
                            items: project.scenes.prefix(3).map {
                                ShortDramaAssetSummary(
                                    id: $0.id,
                                    projectID: project.id,
                                    assetKind: "scene",
                                    name: $0.name,
                                    detail: clean($0.visualPrompt) ?? clean($0.description),
                                    referenceImagePaths: $0.referenceImagePaths
                                )
                            },
                            generateReference: { item in
                                submitAssetMedia(project: project, asset: item)
                            },
                            isGeneratingReference: { item in
                                isGenerating(asset: item)
                            },
                            mediaTasks: { item in
                                mediaTasks(project: project, asset: item)
                            },
                            mediaTaskScope: { item in
                                mediaTaskScope(project: project, asset: item)
                            },
                            appendContext: { item in
                                appendAssetContextToChat(project: project, asset: item)
                            }
                        )
                    }
                }
            }

            if !project.episodes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(project.episodes.prefix(4)) { episode in
                        episodeRow(project: project, episode: episode)
                        ForEach(episode.shots.prefix(3)) { shot in
                            shotRow(project: project, episode: episode, shot: shot)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.035)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(store.activeProjectID == project.id ? 0.18 : 0.08), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            store.setActiveProject(id: project.id)
        }
    }

    private func metric(_ label: String, _ value: Int) -> some View {
        HStack(spacing: 3) {
            Text("\(value)")
                .font(.caption.weight(.semibold))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.045)))
    }

    @ViewBuilder
    func mediaTaskBadge(tasks: [AgentMediaTask], scope: AgentMediaTaskScope? = nil, compact: Bool = false) -> some View {
        let active = tasks.filter(\.isActive).count
        let failed = tasks.filter(\.needsAttention).count
        let completed = tasks.filter { $0.status == .succeeded }.count
        if active > 0 {
            Button {
                openMediaTasksPanel(scope: scope)
            } label: {
                taskBadge(
                    label: compact ? "\(active)" : "处理中 \(active)",
                    systemImage: "clock.arrow.circlepath",
                    color: .orange
                )
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("打开媒体任务侧栏")
        } else if failed > 0 {
            Button {
                openMediaTasksPanel(scope: scope)
            } label: {
                taskBadge(
                    label: compact ? "\(failed)" : "失败 \(failed)",
                    systemImage: "exclamationmark.triangle.fill",
                    color: .red
                )
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("打开媒体任务侧栏")
        } else if completed > 0 {
            Button {
                openMediaTasksPanel(scope: scope)
            } label: {
                taskBadge(
                    label: compact ? "\(completed)" : "完成 \(completed)",
                    systemImage: "checkmark.circle.fill",
                    color: .green
                )
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("打开媒体任务侧栏")
        }
    }

    @ViewBuilder
    private func mediaTaskHealthSummary(tasks: [AgentMediaTask], scope: AgentMediaTaskScope?, title: String = "任务") -> some View {
        if !tasks.isEmpty {
            let active = tasks.filter(\.isActive).count
            let failed = tasks.filter(\.needsAttention).count
            let completed = tasks.filter { $0.status == .succeeded }.count
            let latest = tasks.sorted { $0.updatedAt > $1.updatedAt }.first
            Button {
                openMediaTasksPanel(scope: scope)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: failed > 0 ? "exclamationmark.triangle.fill" : (active > 0 ? "clock.arrow.circlepath" : "checkmark.circle"))
                        .font(.caption2)
                        .foregroundStyle(failed > 0 ? Color.red : (active > 0 ? Color.orange : Color.green))
                    Text(title)
                        .font(.caption2.weight(.semibold))
                    if active > 0 {
                        Text("运行 \(active)")
                            .foregroundStyle(.orange)
                    }
                    if failed > 0 {
                        Text("失败 \(failed)")
                            .foregroundStyle(.red)
                    }
                    if completed > 0 {
                        Text("完成 \(completed)")
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if let latest {
                        Text(latest.displayHandle)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption2)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.035)))
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("打开这个项目的媒体任务侧栏")
        }
    }

    private func openMediaTasksPanel(scope: AgentMediaTaskScope?) {
        appState.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .mediaTasks, mediaTaskScope: scope)
    }

    private func taskBadge(label: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.caption2)
            Text(label)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
        .help("媒体任务状态")
    }

    func mediaTasks(project: AgentShortDramaProject) -> [AgentMediaTask] {
        appState.agentMediaTaskRegistry.tasks.filter { task in
            task.projectID == project.id.uuidString || task.projectPath == project.id.uuidString
        }
    }

    private func allProjectMediaTasks() -> [AgentMediaTask] {
        let projectIDs = Set(store.projects.map { $0.id.uuidString })
        guard !projectIDs.isEmpty else { return [] }
        return appState.agentMediaTaskRegistry.tasks.filter { task in
            if let projectID = task.projectID, projectIDs.contains(projectID) {
                return true
            }
            if let projectPath = task.projectPath, projectIDs.contains(projectPath) {
                return true
            }
            return false
        }
    }

    func projectStructureSummary(_ project: AgentShortDramaProject) -> (
        episodeCount: Int,
        shotCount: Int,
        characterCount: Int,
        sceneCount: Int,
        openReviewCount: Int,
        selectedImageCount: Int,
        videoCount: Int,
        missingImageCount: Int,
        missingVideoCount: Int
    ) {
        let shots = project.episodes.flatMap(\.shots)
        let selectedImageCount = shots.filter { shot in
            shot.selectedArtifactPath.map(isImagePath) ?? false
        }.count
        let videoCount = shots.filter { shot in
            shot.artifactPaths.contains(where: isVideoPath)
        }.count
        let missingImageCount = shots.filter { shot in
            !(shot.selectedArtifactPath.map(isImagePath) ?? false)
        }.count
        let missingVideoCount = shots.filter { shot in
            !shot.artifactPaths.contains(where: isVideoPath)
        }.count
        let openReviewCount = shots.reduce(0) { total, shot in
            total + shot.reviewItems.filter { $0.status != .resolved }.count
        }
        return (
            episodeCount: project.episodes.count,
            shotCount: shots.count,
            characterCount: project.characters.count,
            sceneCount: project.scenes.count,
            openReviewCount: openReviewCount,
            selectedImageCount: selectedImageCount,
            videoCount: videoCount,
            missingImageCount: missingImageCount,
            missingVideoCount: missingVideoCount
        )
    }

    func episodeStructureSummary(_ episode: AgentShortDramaEpisode) -> (
        shotCount: Int,
        openReviewCount: Int,
        selectedImageCount: Int,
        videoCount: Int,
        missingImageCount: Int,
        missingVideoCount: Int
    ) {
        let selectedImageCount = episode.shots.filter { shot in
            shot.selectedArtifactPath.map(isImagePath) ?? false
        }.count
        let videoCount = episode.shots.filter { shot in
            shot.artifactPaths.contains(where: isVideoPath)
        }.count
        let missingImageCount = episode.shots.filter { shot in
            !(shot.selectedArtifactPath.map(isImagePath) ?? false)
        }.count
        let missingVideoCount = episode.shots.filter { shot in
            !shot.artifactPaths.contains(where: isVideoPath)
        }.count
        let openReviewCount = episode.shots.reduce(0) { total, shot in
            total + shot.reviewItems.filter { $0.status != .resolved }.count
        }
        return (
            shotCount: episode.shots.count,
            openReviewCount: openReviewCount,
            selectedImageCount: selectedImageCount,
            videoCount: videoCount,
            missingImageCount: missingImageCount,
            missingVideoCount: missingVideoCount
        )
    }

    func mediaTasks(project: AgentShortDramaProject, episode: AgentShortDramaEpisode) -> [AgentMediaTask] {
        mediaTasks(project: project).filter { task in
            task.episodeID == episode.id.uuidString
        }
    }

    func mediaTasks(project: AgentShortDramaProject, episode: AgentShortDramaEpisode, shot: AgentShortDramaShot) -> [AgentMediaTask] {
        mediaTasks(project: project, episode: episode).filter { task in
            task.shotID == shot.id.uuidString
        }
    }

    private func reviewMediaTasks(item: AgentShortDramaReviewItem) -> [AgentMediaTask] {
        appState.agentMediaTaskRegistry.tasks.filter { task in
            task.reviewItemID == item.id.uuidString
        }
    }

    func mediaTasks(project: AgentShortDramaProject, asset: ShortDramaAssetSummary) -> [AgentMediaTask] {
        mediaTasks(project: project).filter { task in
            task.assetKind == asset.assetKind && task.assetID == asset.id.uuidString
        }
    }

    private func mediaTaskScope(project: AgentShortDramaProject) -> AgentMediaTaskScope {
        AgentMediaTaskScope(label: "项目：\(project.title)", projectID: project.id.uuidString)
    }

    private func mediaTaskScope(
        project: AgentShortDramaProject,
        episode: AgentShortDramaEpisode
    ) -> AgentMediaTaskScope {
        AgentMediaTaskScope(
            label: "分集：\(episode.title)",
            projectID: project.id.uuidString,
            episodeID: episode.id.uuidString
        )
    }

    private func mediaTaskScope(
        project: AgentShortDramaProject,
        episode: AgentShortDramaEpisode,
        shot: AgentShortDramaShot
    ) -> AgentMediaTaskScope {
        AgentMediaTaskScope(
            label: "分镜：\(shot.title)",
            projectID: project.id.uuidString,
            episodeID: episode.id.uuidString,
            shotID: shot.id.uuidString
        )
    }

    private func mediaTaskScope(
        project: AgentShortDramaProject,
        episode: AgentShortDramaEpisode,
        shot: AgentShortDramaShot,
        item: AgentShortDramaReviewItem
    ) -> AgentMediaTaskScope {
        AgentMediaTaskScope(
            label: "检查项：\(item.title)",
            projectID: project.id.uuidString,
            episodeID: episode.id.uuidString,
            shotID: shot.id.uuidString,
            reviewItemID: item.id.uuidString
        )
    }

    private func mediaTaskScope(project: AgentShortDramaProject, asset: ShortDramaAssetSummary) -> AgentMediaTaskScope {
        let assetLabel = asset.assetKind == "scene" ? "场景" : "人物"
        return AgentMediaTaskScope(
            label: "\(assetLabel)：\(asset.name)",
            projectID: project.id.uuidString,
            assetKind: asset.assetKind,
            assetID: asset.id.uuidString
        )
    }

    private func episodeRow(project: AgentShortDramaProject, episode: AgentShortDramaEpisode) -> some View {
        let summary = episodeStructureSummary(episode)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("\(episode.order)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, alignment: .leading)
                Text(episode.title)
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
                Text("\(episode.shots.count) 镜")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                mediaTaskBadge(
                    tasks: mediaTasks(project: project, episode: episode),
                    scope: mediaTaskScope(project: project, episode: episode),
                    compact: true
                )
                Button {
                    openMediaTasksPanel(scope: mediaTaskScope(project: project, episode: episode))
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .help("查看本集媒体任务")
                Button {
                    appendEpisodeContextToChat(project: project, episode: episode)
                } label: {
                    Image(systemName: "text.bubble")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .help("发送本集结构到聊天")

                Button {
                    submitEpisodeMedia(project: project, episode: episode, kind: .imageGeneration)
                } label: {
                    Image(systemName: "photo.stack")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .disabled(episode.shots.isEmpty || isGenerating(episode: episode, kind: .imageGeneration))
                .help("批量生成本集分镜图片")

                Button {
                    submitEpisodeMedia(project: project, episode: episode, kind: .videoGeneration)
                } label: {
                    Image(systemName: "film.stack")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .disabled(episode.shots.isEmpty || isGenerating(episode: episode, kind: .videoGeneration))
                .help("批量生成本集分镜视频")

                Button {
                    exportEpisodePackage(project: project, episode: episode)
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .disabled(episode.shots.isEmpty)
                .help("导出本集制作包")

                Button {
                    showEpisodeStoryboardWidget(project: project, episode: episode)
                } label: {
                    Image(systemName: "rectangle.grid.2x2")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .disabled(episode.shots.isEmpty || appState.activeRuntime == nil)
                .help(appState.activeRuntime == nil ? "请先创建 Agent 会话" : "生成本集网页分镜板")
            }
            let parts = productionGapParts(
                missingImages: summary.missingImageCount,
                missingVideos: summary.missingVideoCount,
                openReviews: summary.openReviewCount,
                missingAssetReferences: 0
            )
            if !parts.isEmpty {
                productionGapActionStrip(
                    missingImages: summary.missingImageCount,
                    missingVideos: summary.missingVideoCount,
                    openReviews: summary.openReviewCount,
                    missingAssetReferences: 0,
                    openMediaTasks: { openMediaTasksPanel(scope: mediaTaskScope(project: project, episode: episode)) },
                    sendImageContext: { appendProductionGapActionToChat(project: project, episode: episode, action: .missingImages) },
                    sendVideoContext: { appendProductionGapActionToChat(project: project, episode: episode, action: .missingVideos) },
                    sendReviewContext: { appendProductionGapActionToChat(project: project, episode: episode, action: .openReviews) },
                    generateAssetReferences: { appendEpisodeContextToChat(project: project, episode: episode) },
                    isGeneratingAssetReferences: false
                )
                .help("发送本集制作缺口和下一步建议到聊天")
            }
        }
    }

    private func shotRow(project: AgentShortDramaProject, episode: AgentShortDramaEpisode, shot: AgentShortDramaShot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: shot.artifactPaths.isEmpty ? "circle" : "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(shot.artifactPaths.isEmpty ? Color.secondary : Color.green)
                    .frame(width: 18, alignment: .leading)
                Text("\(shot.order). \(shot.title)")
                    .font(.caption2)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if !shot.artifactPaths.isEmpty {
                    Text("\(shot.artifactPaths.count) 产物")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text(shot.status.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                mediaTaskBadge(
                    tasks: mediaTasks(project: project, episode: episode, shot: shot),
                    scope: mediaTaskScope(project: project, episode: episode, shot: shot),
                    compact: true
                )
                Button {
                    openMediaTasksPanel(scope: mediaTaskScope(project: project, episode: episode, shot: shot))
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .help("查看本分镜媒体任务")
                Button {
                    appendShotContextToChat(project: project, episode: episode, shot: shot)
                } label: {
                    Image(systemName: "text.bubble")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .help("发送分镜结构到聊天")

                Button {
                    submitShotMedia(project: project, episode: episode, shot: shot, kind: .imageGeneration)
                } label: {
                    Image(systemName: "photo.badge.plus")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .disabled(isGenerating(shot: shot, kind: .imageGeneration))
                .help("用 some.im 生成分镜图片")

                Button {
                    submitShotMedia(project: project, episode: episode, shot: shot, kind: .videoGeneration)
                } label: {
                    Image(systemName: "film.badge.plus")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .disabled(isGenerating(shot: shot, kind: .videoGeneration))
                .help("用 some.im 生成分镜视频")

                if shot.artifactPaths.count > 1 {
                    Button {
                        showImageChoiceWidget(project: project, episode: episode, shot: shot)
                    } label: {
                        Image(systemName: "square.grid.2x2")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .disabled(appState.activeRuntime == nil)
                    .help(appState.activeRuntime == nil ? "请先创建 Agent 会话" : "在聊天中选择主图")
                }
            }

            if !shot.artifactPaths.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(shot.artifactPaths.prefix(6)), id: \.self) { path in
                            AgentShortDramaArtifactTile(
                                path: path,
                                shotTitle: shot.title,
                                isSelected: shot.selectedArtifactPath == path,
                                editorContext: AgentImageEditorContext(
                                    projectID: project.id.uuidString,
                                    episodeID: episode.id.uuidString,
                                    shotID: shot.id.uuidString
                                ),
                                selectAction: {
                                    _ = store.selectShotArtifact(
                                        projectID: project.id,
                                        episodeID: episode.id,
                                        shotID: shot.id,
                                        artifactPath: path
                                    )
                                }
                            )
                        }
                        if shot.artifactPaths.count > 6 {
                            Text("+\(shot.artifactPaths.count - 6)")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 42, height: 54)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.045)))
                        }
                    }
                    .padding(.vertical, 1)
                }
                .frame(height: 76)
            }

            if !shot.reviewItems.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(shot.reviewItems.filter { $0.status != .resolved }.prefix(3)) { item in
                        HStack(spacing: 5) {
                            Image(systemName: reviewItemSystemImage(item.kind))
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(reviewItemColor(item.severity))
                            Text(item.title)
                                .font(.caption2)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(item.kind.displayName)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                            mediaTaskBadge(
                                tasks: reviewMediaTasks(item: item),
                                scope: mediaTaskScope(project: project, episode: episode, shot: shot, item: item),
                                compact: true
                            )
                            Button {
                                openMediaTasksPanel(scope: mediaTaskScope(project: project, episode: episode, shot: shot, item: item))
                            } label: {
                                Image(systemName: "list.bullet.rectangle")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            .buttonStyle(.borderless)
                            .help("查看这个检查项的媒体任务")
                            Button {
                                handleReviewItemAction(project: project, episode: episode, shot: shot, item: item)
                            } label: {
                                Image(systemName: reviewItemActionSystemImage(item.kind))
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            .buttonStyle(.borderless)
                            .disabled(isReviewActionRunning(item))
                            .help(reviewItemActionHelp(item.kind))
                            Button {
                                resolveReviewItem(project: project, episode: episode, shot: shot, item: item)
                            } label: {
                                Image(systemName: "checkmark.circle")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            .buttonStyle(.borderless)
                            .help("标记为已解决")
                        }
                    }
                    let resolvedCount = shot.reviewItems.filter { $0.status == .resolved }.count
                    if resolvedCount > 0 {
                        Text("\(resolvedCount) 个已解决项")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.035)))
            }
        }
        .padding(.leading, 18)
    }

    private func submitShotMedia(
        project: AgentShortDramaProject,
        episode: AgentShortDramaEpisode,
        shot: AgentShortDramaShot,
        kind: AgentMediaTaskKind,
        reviewItemID: String? = nil
    ) {
        let key = mediaKey(shot: shot, kind: kind)
        guard !generatingKeys.contains(key) else { return }
        guard validateGenerationSettings(kind: kind) else { return }

        generatingKeys.insert(key)
        statusMessage = "正在提交 \(kind.displayName)：\(shot.title)"

        Task {
            do {
                let task = try await submitShotMediaTask(project: project, episode: episode, shot: shot, kind: kind, reviewItemID: reviewItemID)
                appState.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .mediaTasks)
                statusMessage = "已提交 \(kind.displayName)：\(task.displayHandle)"
            } catch {
                statusMessage = "提交失败：\(error.localizedDescription)"
            }
            generatingKeys.remove(key)
        }
    }

    private func submitEpisodeMedia(
        project: AgentShortDramaProject,
        episode: AgentShortDramaEpisode,
        kind: AgentMediaTaskKind
    ) {
        let key = mediaKey(episode: episode, kind: kind)
        guard !generatingKeys.contains(key) else { return }
        guard validateGenerationSettings(kind: kind) else { return }
        guard !episode.shots.isEmpty else {
            statusMessage = "这一集还没有分镜。"
            return
        }

        generatingKeys.insert(key)
        statusMessage = "正在批量提交 \(episode.title) 的 \(episode.shots.count) 个\(kind.displayName)任务..."

        Task {
            var submitted = 0
            do {
                for shot in episode.shots.sorted(by: { $0.order < $1.order }) {
                    let shotKey = mediaKey(shot: shot, kind: kind)
                    if generatingKeys.contains(shotKey) { continue }
                    generatingKeys.insert(shotKey)
                    defer { generatingKeys.remove(shotKey) }
                    _ = try await submitShotMediaTask(project: project, episode: episode, shot: shot, kind: kind)
                    submitted += 1
                }
                appState.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .mediaTasks)
                statusMessage = "已提交 \(episode.title)：\(submitted) 个\(kind.displayName)任务"
            } catch {
                statusMessage = "批量提交失败：已提交 \(submitted) 个，错误：\(error.localizedDescription)"
            }
            generatingKeys.remove(key)
        }
    }

    private func submitAssetMedia(project: AgentShortDramaProject, asset: ShortDramaAssetSummary) {
        let key = mediaKey(asset: asset)
        guard !generatingKeys.contains(key) else { return }
        guard validateGenerationSettings(kind: .imageGeneration) else { return }

        generatingKeys.insert(key)
        statusMessage = "正在提交参考图：\(asset.name)"

        Task {
            do {
                let task = try await submitAssetMediaTask(project: project, asset: asset)
                appState.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .mediaTasks)
                statusMessage = "已提交参考图：\(task.displayHandle)"
            } catch {
                statusMessage = "参考图提交失败：\(error.localizedDescription)"
            }
            generatingKeys.remove(key)
        }
    }

    private func submitMissingAssetReferences(project: AgentShortDramaProject) {
        let key = mediaKey(missingReferencesFor: project)
        guard !generatingKeys.contains(key) else { return }
        guard validateGenerationSettings(kind: .imageGeneration) else { return }
        let assets = missingReferenceAssets(project)
        guard !assets.isEmpty else {
            statusMessage = "人物和场景参考图都已齐备。"
            return
        }

        generatingKeys.insert(key)
        statusMessage = "正在补齐 \(assets.count) 个参考图任务..."

        Task {
            var submitted = 0
            do {
                for asset in assets {
                    let assetKey = mediaKey(asset: asset)
                    if generatingKeys.contains(assetKey) { continue }
                    generatingKeys.insert(assetKey)
                    defer { generatingKeys.remove(assetKey) }
                    _ = try await submitAssetMediaTask(project: project, asset: asset)
                    submitted += 1
                }
                appState.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .mediaTasks)
                statusMessage = "已提交 \(submitted) 个参考图任务"
            } catch {
                statusMessage = "补齐参考图失败：已提交 \(submitted) 个，错误：\(error.localizedDescription)"
            }
            generatingKeys.remove(key)
        }
    }

    @discardableResult
    private func submitShotMediaTask(
        project: AgentShortDramaProject,
        episode: AgentShortDramaEpisode,
        shot: AgentShortDramaShot,
        kind: AgentMediaTaskKind,
        reviewItemID: String? = nil
    ) async throws -> AgentMediaTask {
        let settings = SomeIMIntegrationStore.loadSettings()
        let prompt = AgentShortDramaPromptBuilder.prompt(project: project, shot: shot)
        let model = SomeIMAsyncMediaClient.defaultModel(for: kind, settings: settings)
        let endpointSuffix = SomeIMAsyncMediaClient.defaultEndpointSuffix(for: kind)
        var body: [String: Any] = [
            "model": model,
            "prompt": prompt,
        ]
        if kind == .imageGeneration {
            body["size"] = "1024x1024"
            body["response_format"] = "b64_json"
        } else if kind == .videoGeneration,
                  let referenceURL = referenceImageURL(for: shot),
                  let imageDataURL = try? dataURL(for: referenceURL) {
            body["image"] = imageDataURL
        }

        let response = try await SomeIMAsyncMediaClient.submit(
            endpointSuffix: endpointSuffix,
            body: body,
            settings: settings,
            apiKey: SomeIMIntegrationStore.loadAPIKey()
        )
        let status = SomeIMAsyncMediaClient.status(from: response.status)
        let titleSuffix = kind == .videoGeneration && referenceImageURL(for: shot) != nil ? " · 参考主图" : ""
        let title = "\(shot.title) · \(kind.displayName)\(titleSuffix)"
        let artifacts = status == .succeeded
            ? try await SomeIMAsyncMediaClient.downloadArtifacts(from: response, title: title).map(\.mediaArtifact)
            : []
        let task = appState.agentMediaTaskRegistry.create(
            provider: .someIM,
            kind: kind,
            title: title,
            prompt: prompt,
            model: model,
            remoteTaskID: response.id,
            statusURL: response.statusURL,
            cancelURL: response.cancelURL,
            reviewItemID: reviewItemID,
            runtimeID: appState.activeRuntime?.id,
            projectID: project.id.uuidString,
            episodeID: episode.id.uuidString,
            shotID: shot.id.uuidString,
            status: status,
            statusMessage: SomeIMAsyncMediaClient.statusMessage(for: response)
        )
        if !artifacts.isEmpty {
            appState.agentMediaTaskRegistry.update(id: task.id, progress: 1, artifacts: artifacts)
        }
        return task
    }

    @discardableResult
    private func submitAssetMediaTask(project: AgentShortDramaProject, asset: ShortDramaAssetSummary) async throws -> AgentMediaTask {
        let settings = SomeIMIntegrationStore.loadSettings()
        let prompt = assetPrompt(project: project, asset: asset)
        let model = SomeIMAsyncMediaClient.defaultModel(for: .imageGeneration, settings: settings)
        let endpointSuffix = SomeIMAsyncMediaClient.defaultEndpointSuffix(for: .imageGeneration)
        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "size": "1024x1024",
            "response_format": "b64_json",
        ]

        let response = try await SomeIMAsyncMediaClient.submit(
            endpointSuffix: endpointSuffix,
            body: body,
            settings: settings,
            apiKey: SomeIMIntegrationStore.loadAPIKey()
        )
        let status = SomeIMAsyncMediaClient.status(from: response.status)
        let title = "\(asset.name) · 参考图"
        let artifacts = status == .succeeded
            ? try await SomeIMAsyncMediaClient.downloadArtifacts(from: response, title: title).map(\.mediaArtifact)
            : []
        let task = appState.agentMediaTaskRegistry.create(
            provider: .someIM,
            kind: .imageGeneration,
            title: title,
            prompt: prompt,
            model: model,
            remoteTaskID: response.id,
            statusURL: response.statusURL,
            cancelURL: response.cancelURL,
            runtimeID: appState.activeRuntime?.id,
            projectID: project.id.uuidString,
            assetKind: asset.assetKind,
            assetID: asset.id.uuidString,
            status: status,
            statusMessage: SomeIMAsyncMediaClient.statusMessage(for: response)
        )
        if !artifacts.isEmpty {
            appState.agentMediaTaskRegistry.update(id: task.id, progress: 1, artifacts: artifacts)
        }
        return task
    }

    private func validateGenerationSettings(kind: AgentMediaTaskKind) -> Bool {
        let settings = SomeIMIntegrationStore.loadSettings()
        if kind == .videoGeneration, settings.normalized.preferredVideoModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            statusMessage = "请先在 Settings → some.im 配置视频模型。"
            return false
        }
        return true
    }

    private func assetPrompt(project: AgentShortDramaProject, asset: ShortDramaAssetSummary) -> String {
        var sections = [asset.detail ?? asset.name]
        if let logline = clean(project.logline) {
            sections.append("Project logline: \(logline)")
        }
        let kindLabel = asset.assetKind == "scene" ? "scene/location reference" : "character reference"
        sections.append("Create a production-ready \(kindLabel) image for short-drama continuity.")
        return sections.joined(separator: "\n\n")
    }

    private func showStoryboardWidget() {
        guard let project = store.activeProject else {
            statusMessage = "请先选择短剧项目。"
            return
        }
        guard let runtimeID = appState.activeRuntime?.id else {
            statusMessage = "请先创建 Agent 会话，再生成网页分镜板。"
            return
        }
        let widget = AgentShortDramaStoryboardWidgetBuilder.widget(
            for: project,
            mediaTasks: appState.agentMediaTaskRegistry.tasks(forRuntime: runtimeID)
        )
        AgentWidgetRegistry.shared.add(widget, forRuntime: runtimeID)
        appState.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .widget)
        statusMessage = "已生成网页分镜板：\(project.title)"
    }

    private func showEpisodeStoryboardWidget(project: AgentShortDramaProject, episode: AgentShortDramaEpisode) {
        guard let runtimeID = appState.activeRuntime?.id else {
            statusMessage = "请先创建 Agent 会话，再生成本集网页分镜板。"
            return
        }
        let widget = AgentShortDramaStoryboardWidgetBuilder.widget(
            for: project,
            episode: episode,
            mediaTasks: appState.agentMediaTaskRegistry.tasks(forRuntime: runtimeID)
        )
        AgentWidgetRegistry.shared.add(widget, forRuntime: runtimeID)
        appState.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .widget)
        statusMessage = "已生成本集网页分镜板：第 \(episode.order) 集 \(episode.title)"
    }

    private func showImageChoiceWidget(project: AgentShortDramaProject, episode: AgentShortDramaEpisode, shot: AgentShortDramaShot) {
        guard let runtimeID = appState.activeRuntime?.id else {
            statusMessage = "请先创建 Agent 会话，再生成候选图选择器。"
            return
        }
        let widget = AgentShortDramaStoryboardWidgetBuilder.imageChoiceWidget(project: project, episode: episode, shot: shot)
        AgentWidgetRegistry.shared.add(widget, forRuntime: runtimeID)
        appState.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .widget)
        statusMessage = "已生成候选图选择器：\(shot.title)"
    }

    private func isGenerating(shot: AgentShortDramaShot, kind: AgentMediaTaskKind) -> Bool {
        generatingKeys.contains(mediaKey(shot: shot, kind: kind))
    }

    private func isGenerating(episode: AgentShortDramaEpisode, kind: AgentMediaTaskKind) -> Bool {
        generatingKeys.contains(mediaKey(episode: episode, kind: kind))
    }

    private func isGenerating(asset: ShortDramaAssetSummary) -> Bool {
        generatingKeys.contains(mediaKey(asset: asset))
    }

    private func isGeneratingMissingAssetReferences(_ project: AgentShortDramaProject) -> Bool {
        generatingKeys.contains(mediaKey(missingReferencesFor: project))
    }

    private func mediaKey(shot: AgentShortDramaShot, kind: AgentMediaTaskKind) -> String {
        "\(shot.id.uuidString)-\(kind.rawValue)"
    }

    private func mediaKey(episode: AgentShortDramaEpisode, kind: AgentMediaTaskKind) -> String {
        "\(episode.id.uuidString)-\(kind.rawValue)"
    }

    private func mediaKey(asset: ShortDramaAssetSummary) -> String {
        "asset-\(asset.assetKind)-\(asset.id.uuidString)"
    }

    private func mediaKey(missingReferencesFor project: AgentShortDramaProject) -> String {
        "asset-missing-\(project.id.uuidString)"
    }

    func missingAssetReferenceCount(_ project: AgentShortDramaProject) -> Int {
        missingReferenceAssets(project).count
    }

    func missingReferenceAssets(_ project: AgentShortDramaProject) -> [ShortDramaAssetSummary] {
        let characters = project.characters
            .filter { $0.referenceImagePaths.isEmpty }
            .map {
                ShortDramaAssetSummary(
                    id: $0.id,
                    projectID: project.id,
                    assetKind: "character",
                    name: $0.name,
                    detail: clean($0.visualPrompt) ?? clean($0.description),
                    referenceImagePaths: $0.referenceImagePaths
                )
            }
        let scenes = project.scenes
            .filter { $0.referenceImagePaths.isEmpty }
            .map {
                ShortDramaAssetSummary(
                    id: $0.id,
                    projectID: project.id,
                    assetKind: "scene",
                    name: $0.name,
                    detail: clean($0.visualPrompt) ?? clean($0.description),
                    referenceImagePaths: $0.referenceImagePaths
                )
            }
        return characters + scenes
    }

    private func reviewActionKey(_ item: AgentShortDramaReviewItem) -> String {
        item.id.uuidString
    }

    private func isReviewActionRunning(_ item: AgentShortDramaReviewItem) -> Bool {
        reviewActionKeys.contains(reviewActionKey(item))
    }

    func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func referenceImageURL(for shot: AgentShortDramaShot) -> URL? {
        let candidates = [shot.selectedArtifactPath].compactMap { $0 } + shot.artifactPaths
        guard let path = candidates.first(where: isImagePath) else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func reviewItemSystemImage(_ kind: AgentShortDramaReviewItemKind) -> String {
        switch kind {
        case .continuity: return "link.badge.plus"
        case .prompt: return "text.quote"
        case .redraw: return "paintbrush.pointed"
        case .erase: return "eraser"
        case .upscale: return "arrow.up.left.and.arrow.down.right"
        case .reshoot: return "film.badge.plus"
        case .note: return "note.text"
        }
    }

    private func reviewItemActionSystemImage(_ kind: AgentShortDramaReviewItemKind) -> String {
        switch kind {
        case .redraw, .erase:
            return "rectangle.and.pencil.and.ellipsis"
        case .upscale:
            return "arrow.up.left.and.arrow.down.right"
        case .reshoot:
            return "photo.badge.plus"
        case .continuity, .prompt, .note:
            return "text.bubble"
        }
    }

    private func reviewItemActionHelp(_ kind: AgentShortDramaReviewItemKind) -> String {
        switch kind {
        case .redraw:
            return "打开关联图片做蒙版重绘"
        case .erase:
            return "打开关联图片做蒙版擦除"
        case .upscale:
            return "用 Replicate 放大关联图片"
        case .reshoot:
            return "重新提交分镜图片生成任务"
        case .continuity, .prompt, .note:
            return "把处理建议放入聊天输入框"
        }
    }

    private func handleReviewItemAction(
        project: AgentShortDramaProject,
        episode: AgentShortDramaEpisode,
        shot: AgentShortDramaShot,
        item: AgentShortDramaReviewItem
    ) {
        switch item.kind {
        case .redraw, .erase:
            guard let url = primaryImageURL(for: item, shot: shot) else {
                statusMessage = "这个检查项还没有可编辑的图片产物。"
                NSSound.beep()
                return
            }
            appState.agentImageEditorPreferredOperation = item.kind == .erase ? .erase : .inpaint
            appState.agentImageEditorContext = AgentImageEditorContext(
                projectID: project.id.uuidString,
                episodeID: episode.id.uuidString,
                shotID: shot.id.uuidString,
                reviewItemID: item.id.uuidString
            )
            appState.agentImageEditorImageURL = url
            appState.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .imageEditor)
            statusMessage = "已打开蒙版编辑：\(url.lastPathComponent)"
        case .upscale:
            submitReviewItemUpscale(project: project, episode: episode, shot: shot, item: item)
        case .reshoot:
            submitShotMedia(project: project, episode: episode, shot: shot, kind: .imageGeneration, reviewItemID: item.id.uuidString)
        case .continuity, .prompt, .note:
            stageReviewItemPrompt(project: project, episode: episode, shot: shot, item: item)
        }
    }

    private func resolveReviewItem(
        project: AgentShortDramaProject,
        episode: AgentShortDramaEpisode,
        shot: AgentShortDramaShot,
        item: AgentShortDramaReviewItem
    ) {
        guard store.resolveReviewItem(projectID: project.id, episodeID: episode.id, shotID: shot.id, itemID: item.id) != nil else {
            statusMessage = "未找到检查项：\(item.title)"
            NSSound.beep()
            return
        }
        statusMessage = "已解决：\(item.title)"
    }

    private func submitReviewItemUpscale(
        project: AgentShortDramaProject,
        episode: AgentShortDramaEpisode,
        shot: AgentShortDramaShot,
        item: AgentShortDramaReviewItem
    ) {
        let key = reviewActionKey(item)
        guard !reviewActionKeys.contains(key) else { return }
        guard let version = replicateUpscaleVersion else {
            statusMessage = "请先在 Settings → Integrations → Replicate 配置图片放大 version。"
            NSSound.beep()
            return
        }
        guard let url = primaryImageURL(for: item, shot: shot) else {
            statusMessage = "这个检查项还没有可放大的图片产物。"
            NSSound.beep()
            return
        }

        reviewActionKeys.insert(key)
        statusMessage = "正在提交 Replicate 放大：\(url.lastPathComponent)"
        Task {
            do {
                let inputJSON = try jsonString(from: ["image": dataURL(for: url)])
                let prediction = try await ReplicateClient.createPrediction(version: version, inputJSON: inputJSON)
                let status = ReplicateClient.status(from: prediction.status)
                let title = "\(shot.title) · \(item.title) · Replicate 放大"
                let artifacts = status == .succeeded
                    ? try await ReplicateClient.downloadArtifacts(from: prediction, title: title).map(\.mediaArtifact)
                    : []
                let task = appState.agentMediaTaskRegistry.create(
                    provider: .replicate,
                    kind: .imageUpscale,
                    title: title,
                    prompt: item.suggestedAction ?? "Upscale short-drama artifact: \(url.lastPathComponent)",
                    model: version,
                    remoteTaskID: prediction.id,
                    statusURL: prediction.urls?.get,
                    cancelURL: prediction.urls?.cancel,
                    reviewItemID: item.id.uuidString,
                    runtimeID: appState.activeRuntime?.id,
                    projectID: project.id.uuidString,
                    episodeID: episode.id.uuidString,
                    shotID: shot.id.uuidString,
                    status: status,
                    statusMessage: ReplicateClient.statusMessage(for: prediction)
                )
                if !artifacts.isEmpty {
                    appState.agentMediaTaskRegistry.update(id: task.id, progress: 1, artifacts: artifacts)
                }
                appState.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .mediaTasks)
                statusMessage = "已提交 Replicate 放大：\(task.displayHandle)"
            } catch {
                statusMessage = "放大提交失败：\(error.localizedDescription)"
                NSSound.beep()
            }
            reviewActionKeys.remove(key)
        }
    }

    private func stageReviewItemPrompt(
        project: AgentShortDramaProject,
        episode: AgentShortDramaEpisode,
        shot: AgentShortDramaShot,
        item: AgentShortDramaReviewItem
    ) {
        let reviewTasks = reviewMediaTasks(item: item)
        let primaryImagePath = primaryImageURL(for: item, shot: shot)?.path
        var lines: [String] = [
            "<short-drama-review-item-context>",
            "action: inspect_short_drama_review_item_from_side_panel",
            "project_id: \(project.id.uuidString)",
            "project_title: \(project.title)",
            "episode_id: \(episode.id.uuidString)",
            "episode_title: \(episode.title)",
            "shot_id: \(shot.id.uuidString)",
            "shot_title: \(shot.title)",
            "review_item_id: \(item.id.uuidString)",
            "review_kind: \(item.kind.rawValue)",
            "review_kind_label: \(item.kind.displayName)",
            "review_severity: \(item.severity.rawValue)",
            "review_status: \(item.status.rawValue)",
            "review_title: \(item.title)",
            "review_task_count: \(reviewTasks.count)",
            "active_review_task_count: \(reviewTasks.filter(\.isActive).count)",
            "failed_review_task_count: \(reviewTasks.filter(\.needsAttention).count)",
            "open_review_tasks_tool: short_drama_open_media_tasks",
            "open_review_tasks_arguments: project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), shot_id=\(shot.id.uuidString), scope=review_item, review_item_id=\(item.id.uuidString)",
            "resolve_review_tool: short_drama_resolve_review_item",
            "resolve_review_arguments: project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), shot_id=\(shot.id.uuidString), item_id=\(item.id.uuidString)"
        ]
        if let detail = clean(item.detail) {
            lines.append("review_detail: \(detail)")
        }
        if let suggestedAction = clean(item.suggestedAction) {
            lines.append("suggested_action: \(suggestedAction)")
        }
        if !item.artifactPaths.isEmpty {
            lines.append("review_artifact_paths: \(item.artifactPaths.prefix(8).joined(separator: " | "))")
        }
        if let primaryImagePath {
            lines.append("primary_image_path: \(primaryImagePath)")
            lines.append("redraw_tool: short_drama_open_image_editor")
            lines.append("redraw_arguments: project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), shot_id=\(shot.id.uuidString), review_item_id=\(item.id.uuidString), artifact_path=\(primaryImagePath), operation=inpaint")
            lines.append("erase_tool: short_drama_open_image_editor")
            lines.append("erase_arguments: project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), shot_id=\(shot.id.uuidString), review_item_id=\(item.id.uuidString), artifact_path=\(primaryImagePath), operation=erase")
            lines.append("upscale_tool: short_drama_upscale_shot_artifact")
            lines.append("upscale_arguments: project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), shot_id=\(shot.id.uuidString), review_item_id=\(item.id.uuidString), artifact_path=\(primaryImagePath)")
        }
        lines.append("reshoot_tool: short_drama_generate_shot_media")
        lines.append("reshoot_arguments: project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), shot_id=\(shot.id.uuidString), kind=image_generation, review_item_id=\(item.id.uuidString)")
        lines.append("follow_up: 请只围绕这个检查项推进；重绘、擦除、放大、补拍和图生视频都必须保留 review_item_id，确认修复后再调用 resolve_review_tool 关闭检查项。")
        lines.append("</short-drama-review-item-context>")

        let prompt = lines.joined(separator: "\n")
        let trimmedInput = appState.agentInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let duplicateGuard = "review_item_id: \(item.id.uuidString)"
        if trimmedInput.isEmpty {
            appState.agentInput = prompt
        } else if !appState.agentInput.contains(duplicateGuard) {
            appState.agentInput += "\n\n\(prompt)"
        }
        appState.agentComposerFocusRevision += 1
        statusMessage = "已把检查项结构发送到聊天输入框。"
    }

    private func primaryImageURL(for item: AgentShortDramaReviewItem, shot: AgentShortDramaShot) -> URL? {
        let paths = item.artifactPaths + shot.artifactPaths
        guard let path = paths.first(where: isImagePath) else { return nil }
        return URL(fileURLWithPath: path)
    }

    func isImagePath(_ path: String) -> Bool {
        ["png", "jpg", "jpeg", "webp", "gif", "tif", "tiff", "heic"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    func isVideoPath(_ path: String) -> Bool {
        ["mp4", "mov", "m4v", "webm", "avi", "mkv"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    private var replicateUpscaleVersion: String? {
        let version = ReplicateIntegrationStore.loadWorkflowSettings().upscaleVersion
        return version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : version
    }

    private func dataURL(for url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let mimeType: String
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": mimeType = "image/jpeg"
        case "webp": mimeType = "image/webp"
        case "gif": mimeType = "image/gif"
        case "tif", "tiff": mimeType = "image/tiff"
        case "heic": mimeType = "image/heic"
        default: mimeType = "image/png"
        }
        return "data:\(mimeType);base64,\(data.base64EncodedString())"
    }

    private func jsonString(from object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func reviewItemColor(_ severity: AgentShortDramaReviewItemSeverity) -> Color {
        switch severity {
        case .low: return .secondary
        case .medium: return .orange
        case .high: return .red
        }
    }
}
