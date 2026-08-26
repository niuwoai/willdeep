//
//  AgentSkillTierTests.swift
//  WillDeepTests
//
//  The tier is a dispatch hint read before the skill body (model-tiers.v1,
//  shared with willdeep-rs). Both directions matter: a declared tier must
//  surface, and an unknown spelling — skills are user data other tools also
//  write — must stay silent instead of breaking discovery.
//

import Foundation
import Testing

@testable import WillDeep

@Suite("Skill tier parsing")
nonisolated struct AgentSkillTierTests {
    @Test("A declared tier parses, aliases included")
    func declaredTierParses() {
        let parsed = AgentSkillDirectory.parseMetadata(
            from: "---\nname: convert\ndescription: test\ntier: worker\n---\n# body"
        )
        #expect(parsed.tier == .worker)
        #expect(AgentSkillTier.parse("Small") == .worker)
        #expect(AgentSkillTier.parse("medium") == .standard)
        #expect(AgentSkillTier.parse("LARGE") == .deep)
    }

    @Test("Unknown spellings and missing keys stay silent")
    func unknownSpellingIsNotAnError() {
        let epic = AgentSkillDirectory.parseMetadata(
            from: "---\nname: write\ndescription: test\ntier: epic\n---\n"
        )
        #expect(epic.tier == nil)
        #expect(epic.name == "write", "a bad tier must not poison the rest of the frontmatter")

        let plain = AgentSkillDirectory.parseMetadata(
            from: "---\nname: plain\ndescription: test\n---\n"
        )
        #expect(plain.tier == nil)
    }
}
