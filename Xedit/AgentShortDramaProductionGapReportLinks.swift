//
//  AgentShortDramaProductionGapReportLinks.swift
//  WillDeep
//
//  Helpers for linking production gap-report assets back to ordered shots.
//

import Foundation

extension AgentShortDramaProductionExporter {
    static func linkedShotIDs(forCharacterID characterID: UUID, in project: AgentShortDramaProject) -> [String] {
        orderedUniqueShotIDs(in: project) { shot in
            shot.characterIDs.contains(characterID)
        }
    }

    static func linkedShotIDs(forSceneID sceneID: UUID, in project: AgentShortDramaProject) -> [String] {
        orderedUniqueShotIDs(in: project) { shot in
            shot.sceneID == sceneID
        }
    }

    private static func orderedUniqueShotIDs(
        in project: AgentShortDramaProject,
        where matches: (AgentShortDramaShot) -> Bool
    ) -> [String] {
        var seen = Set<UUID>()
        var ids: [String] = []
        for episode in project.episodes.sorted(by: { $0.order < $1.order }) {
            for shot in episode.shots.sorted(by: { $0.order < $1.order }) where matches(shot) && !seen.contains(shot.id) {
                seen.insert(shot.id)
                ids.append(shot.id.uuidString)
            }
        }
        return ids
    }
}
