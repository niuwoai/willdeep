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

    // MARK: 副作用面

    @Test("声明的副作用面能解析，别名一起认")
    func declaredEffectsParse() {
        let parsed = AgentSkillDirectory.parseMetadata(
            from: "---\nname: send\ndescription: test\neffects: side-effects\n---\n"
        )
        #expect(parsed.effects == .sideEffects)
        #expect(AgentSkillEffects.parse("readonly") == .readOnly)
        #expect(AgentSkillEffects.parse("READ_ONLY") == .readOnly)
        #expect(AgentSkillEffects.parse("network") == .outboundQuery)
        #expect(AgentSkillEffects.parse("Mutating") == .sideEffects)
        #expect(AgentSkillEffects.parse("desktop") == .hostControl)
    }

    @Test("未标注与拼错都收敛成未知，不当成只读")
    func missingEffectsIsUnknownNotSafe() {
        // 这条是要害：把「没标」读成「只读」，将来任何据此放行的判断都会
        // 把没审过的技能当成安全的。用户自己写的技能几乎都没这个字段。
        let plain = AgentSkillDirectory.parseMetadata(
            from: "---\nname: plain\ndescription: test\n---\n"
        )
        #expect(plain.effects == nil)
        #expect(plain.effects != .readOnly)

        let typo = AgentSkillDirectory.parseMetadata(
            from: "---\nname: typo\ndescription: test\neffects: mostly-harmless\n---\n"
        )
        #expect(typo.effects == nil)
        #expect(typo.name == "typo", "认不出的副作用面不该污染其余 frontmatter")
    }

    @Test("tier 与 effects 并存互不干扰")
    func tierAndEffectsCoexist() {
        let parsed = AgentSkillDirectory.parseMetadata(
            from: "---\nname: both\ndescription: test\ntier: worker\neffects: host-control\n---\n"
        )
        #expect(parsed.tier == .worker)
        #expect(parsed.effects == .hostControl)
    }

    @Test("随包发布的技能全都标了副作用面")
    func bundledSkillsAllDeclareEffects() throws {
        // 41 个内置技能是我们自己审过的，未标注只在用户技能里是常态。
        // 新增内置技能忘了标，这条会红——那正是要的：将来的白名单要靠它。
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let bundled = repositoryRoot.appendingPathComponent("BundledSkills", isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: bundled.path).sorted()
        var checked = 0
        for name in names {
            let manifest = bundled
                .appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent("SKILL.md")
            guard let text = try? String(contentsOf: manifest, encoding: .utf8) else { continue }
            let metadata = AgentSkillDirectory.parseMetadata(from: text)
            #expect(metadata.effects != nil, "内置技能 \(name) 缺 effects 声明")
            checked += 1
        }
        #expect(checked >= 41, "只检到 \(checked) 个内置技能，少于已知的 41 个")
    }
}
