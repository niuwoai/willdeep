//
//  AgentLearningSuggestionDeduplicatorTests.swift
//  XeditTests
//
//  回合末的记忆/技能建议要先和本地已有的比一遍再决定弹不弹。
//  这里锁两件事：明显重复的要被拦下，措辞不同但确实是新东西的不能被误吞。
//

import Foundation
import Testing
@testable import WillDeep

struct AgentLearningSuggestionDeduplicatorTests {
    private typealias Dedup = AgentLearningSuggestionDeduplicator

    @Test("identical and contained memories count as duplicates")
    func duplicateMemoriesAreRecognized() {
        let existing = [
            "远程日志巡检应直接读取并流式筛选 journalctl/systemctl 输出，不要为了分析创建远端临时文件，也不要重启服务、修改配置、改变权限或删除数据"
        ]

        // 一字不差
        #expect(Dedup.isDuplicate(existing[0], among: existing, threshold: Dedup.memorySimilarityThreshold))
        // 已存的更长，新建议是其中一句
        #expect(Dedup.isDuplicate(
            "远程日志巡检应直接读取并流式筛选 journalctl/systemctl 输出",
            among: existing,
            threshold: Dedup.memorySimilarityThreshold
        ))
    }

    @Test("a genuinely different memory still gets through")
    func unrelatedMemoryIsNotDropped() {
        let existing = [
            "远程日志巡检应直接读取并流式筛选 journalctl 输出，不要创建远端临时文件"
        ]

        #expect(!Dedup.isDuplicate(
            "发布前必须先备份当前运行的二进制到带时间戳的目录，至少保留最近三个版本",
            among: existing,
            threshold: Dedup.memorySimilarityThreshold
        ))
        #expect(!Dedup.isDuplicate(
            "The user prefers yarn over npm for installing dependencies in this repository",
            among: existing,
            threshold: Dedup.memorySimilarityThreshold
        ))
    }

    @Test("english memories dedupe on wording, not exact match")
    func englishRewordingIsRecognized() {
        let existing = [
            "Agent should call add_memory when a turn reveals a durable user preference, project rule, or recurring fact"
        ]

        #expect(Dedup.similarity(
            "Agent should call add_memory when a turn reveals a durable user preference, project rule or recurring fact",
            existing[0]
        ) >= Dedup.memorySimilarityThreshold)
    }

    @Test("draft filtering drops known drafts and in-batch repeats")
    func draftFilteringKeepsOnlyFreshItems() {
        let existing = ["用户偏好使用 yarn 安装依赖，不要用 npm"]
        let drafts = [
            AgentMemoryDraft(content: "用户偏好使用 yarn 安装依赖，不要用 npm", scopeRaw: "global", lifetimeRaw: "longTerm", rootDirectoryPath: nil),
            AgentMemoryDraft(content: "部署前必须备份旧产物，保留最近三个版本", scopeRaw: "global", lifetimeRaw: "longTerm", rootDirectoryPath: nil),
            AgentMemoryDraft(content: "部署前必须备份旧产物，保留最近三个版本", scopeRaw: "global", lifetimeRaw: "longTerm", rootDirectoryPath: nil)
        ]

        let fresh = Dedup.newMemoryDrafts(drafts, existingMemoryContents: existing)

        #expect(fresh.count == 1)
        #expect(fresh.first?.content == "部署前必须备份旧产物，保留最近三个版本")
    }

    @Test("empty existing memory means nothing is filtered")
    func firstEverSuggestionSurvives() {
        let drafts = [
            AgentMemoryDraft(content: "用户偏好使用 yarn", scopeRaw: "global", lifetimeRaw: "longTerm", rootDirectoryPath: nil)
        ]

        #expect(Dedup.newMemoryDrafts(drafts, existingMemoryContents: []).count == 1)
    }

    @Test("an installed skill is not suggested again")
    func installedSkillIsRecognized() {
        let installed = [
            Dedup.ExistingSkill(
                name: "release-macos-app",
                description: "Build, sign, notarize and publish a macOS app release, then update the appcast."
            )
        ]

        // 名字一致（大小写、连字符差异不算数）
        #expect(Dedup.isKnownSkill(name: "Release macOS App", description: "Ship a release", existing: installed))
        // 名字不同但讲的是同一件事
        #expect(Dedup.isKnownSkill(
            name: "publish-macos-release",
            description: "Build, sign, notarize and publish a macOS app release, then update the appcast.",
            existing: installed
        ))
        // 真正的新技能不受影响
        #expect(!Dedup.isKnownSkill(
            name: "postgres-backup-check",
            description: "Verify that the nightly PostgreSQL backup can actually be restored.",
            existing: installed
        ))
    }

    @Test("short strings only match when identical")
    func shortStringsAvoidFalsePositives() {
        // 两条短句共用一个词，不足以判定重复。
        #expect(!Dedup.isDuplicate("用 yarn", among: ["用 npm"], threshold: Dedup.memorySimilarityThreshold))
        #expect(Dedup.similarity("build app", "build app") == 1)
    }
}
