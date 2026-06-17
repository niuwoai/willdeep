//
//  UserWorkflowManifestTests.swift
//  WillDeepTests
//
//  1.85.0-rc5：覆盖 declarative workflow 清单的 YAML 子集解析、
//  占位符渲染、reserved slash 拒绝、错误路径。
//

import Foundation
import Testing
@testable import WillDeep

@Suite
struct UserWorkflowManifestTests {

    // MARK: - Parser happy path

    @Test
    func parsesMinimalManifest() throws {
        let yaml = """
        name: my-skill
        version: 1.2.3
        slash_command: /demo
        display_title: Demo Skill
        short_description: Just a demo
        args_placeholder: <input>
        allows_empty_args: false
        max_agents: 2

        steps:
          - id: first
            label: first-step
            prompt: |
              Echo: {{args}}

        summary: |
          ## Result

          {{steps.first.output}}
        """
        let m = try UserWorkflowManifestParser.parse(yaml)
        #expect(m.name == "my-skill")
        #expect(m.version == "1.2.3")
        #expect(m.slashCommand == "/demo")
        #expect(m.displayTitle == "Demo Skill")
        #expect(m.shortDescription == "Just a demo")
        #expect(m.argsPlaceholder == "<input>")
        #expect(m.allowsEmptyArgs == false)
        #expect(m.maxAgents == 2)
        #expect(m.steps.count == 1)
        #expect(m.steps[0].id == "first")
        #expect(m.steps[0].label == "first-step")
        #expect(m.steps[0].prompt.contains("Echo: {{args}}"))
        #expect(m.summaryTemplate.contains("{{steps.first.output}}"))
    }

    @Test
    func slashCommandGetsLeadingSlashIfOmitted() throws {
        let yaml = """
        name: x
        slash_command: bare
        steps:
          - id: a
            prompt: |
              hi
        """
        let m = try UserWorkflowManifestParser.parse(yaml)
        #expect(m.slashCommand == "/bare")
    }

    @Test
    func defaultSummaryWhenOmitted() throws {
        let yaml = """
        name: x
        slash_command: /x
        steps:
          - id: a
            prompt: |
              p
          - id: b
            prompt: |
              q
        """
        let m = try UserWorkflowManifestParser.parse(yaml)
        #expect(m.summaryTemplate.contains("{{steps.a.output}}"))
        #expect(m.summaryTemplate.contains("{{steps.b.output}}"))
    }

    @Test
    func maxAgentsClampsTo1To8() throws {
        let yaml = """
        name: x
        slash_command: /x
        max_agents: 99
        steps:
          - id: a
            prompt: |
              p
        """
        let m = try UserWorkflowManifestParser.parse(yaml)
        #expect(m.maxAgents == 8)

        let yaml2 = """
        name: x
        slash_command: /x
        max_agents: 0
        steps:
          - id: a
            prompt: |
              p
        """
        let m2 = try UserWorkflowManifestParser.parse(yaml2)
        #expect(m2.maxAgents == 1)
    }

    // MARK: - Block scalar

    @Test
    func blockScalarPreservesNewlines() throws {
        let yaml = """
        name: x
        slash_command: /x
        steps:
          - id: a
            prompt: |
              line one
              line two

              line four
        """
        let m = try UserWorkflowManifestParser.parse(yaml)
        // YAML clip 模式(`|`):trim 尾部空行,保留中间空行,固定补一个尾换行(spec 行为)。
        #expect(m.steps[0].prompt == "line one\nline two\n\nline four\n")
    }

    // MARK: - Errors

    @Test
    func rejectsMissingName() {
        let yaml = """
        slash_command: /x
        steps:
          - id: a
            prompt: |
              p
        """
        #expect(throws: UserWorkflowManifestError.self) {
            _ = try UserWorkflowManifestParser.parse(yaml)
        }
    }

    @Test
    func rejectsEmptySteps() {
        let yaml = """
        name: x
        slash_command: /x
        steps:
        """
        #expect(throws: UserWorkflowManifestError.self) {
            _ = try UserWorkflowManifestParser.parse(yaml)
        }
    }

    @Test
    func rejectsDuplicateStepID() {
        let yaml = """
        name: x
        slash_command: /x
        steps:
          - id: a
            prompt: |
              p
          - id: a
            prompt: |
              q
        """
        #expect(throws: UserWorkflowManifestError.self) {
            _ = try UserWorkflowManifestParser.parse(yaml)
        }
    }

    @Test
    func rejectsInvalidSlashCommandShape() {
        let yaml = """
        name: x
        slash_command: /has spaces
        steps:
          - id: a
            prompt: |
              p
        """
        #expect(throws: UserWorkflowManifestError.self) {
            _ = try UserWorkflowManifestParser.parse(yaml)
        }
    }

    @Test
    func rejectsReservedSlashCommand() {
        let yaml = """
        name: x
        slash_command: /code-review
        steps:
          - id: a
            prompt: |
              p
        """
        #expect(throws: UserWorkflowManifestError.self) {
            _ = try UserWorkflowManifestParser.parse(
                yaml,
                reservedSlashCommands: ["/code-review", "/deep-research"]
            )
        }
    }

    // MARK: - DeclarativeWorkflow placeholder rendering

    @Test
    func declarativeWorkflowConformsToProtocol() throws {
        let yaml = """
        name: demo
        slash_command: /demo
        display_title: Demo
        short_description: A demo
        args_placeholder: <text>
        allows_empty_args: true
        max_agents: 3

        steps:
          - id: a
            label: first
            prompt: |
              {{args}}

        summary: |
          {{args}} → {{steps.a.output}}
        """
        let m = try UserWorkflowManifestParser.parse(yaml)
        let wf = DeclarativeWorkflow(manifest: m)
        #expect(wf.name == "demo")
        #expect(wf.slashCommand == "/demo")
        #expect(wf.displayTitle == "Demo")
        #expect(wf.shortDescription == "A demo")
        #expect(wf.argsPlaceholder == "<text>")
        #expect(wf.allowsEmptyArgs == true)
        #expect(wf.maxAgents == 3)
    }

    // MARK: - Registry integration

    @Test
    @MainActor
    func bundledExampleSkillIsDiscoverable() {
        // BundledSkills/example-translate/workflow.yaml 应该被发现并
        // 注册为 /translate-cn,且不和任何内置 workflow 冲突。
        let workflows = WorkflowRegistry.all
        let translate = workflows.first(where: { $0.slashCommand == "/translate-cn" })
        #expect(translate != nil, "BundledSkills 里的 example-translate 应该被注册")
        #expect(translate?.name == "example-translate")
    }

    @Test
    @MainActor
    func builtInWorkflowsAlwaysPresent() {
        let workflows = WorkflowRegistry.all
        let slashes = Set(workflows.map(\.slashCommand))
        #expect(slashes.contains("/code-review"))
        #expect(slashes.contains("/research"))
        #expect(slashes.contains("/video-clip"))
    }
}
