//
//  AgentShortDramaExportActions.swift
//  WillDeep
//
//  Side-panel actions for handing short-drama production packages to scripts
//  and staging the follow-up prompt back into the Agent composer.
//

import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension AgentShortDramaPanel {
    var productionExportImportActions: some View {
        HStack(spacing: 8) {
            Button {
                importLastProductionPackage(dryRun: true)
            } label: {
                Label("预检导回", systemImage: "checklist")
            }
            .buttonStyle(.borderless)

            Button {
                importLastProductionPackage(dryRun: false)
            } label: {
                Label("导回产物", systemImage: "square.and.arrow.down.on.square")
            }
            .buttonStyle(.borderless)

            Button {
                importLastProductionPackage(dryRun: false, importPendingTasks: true)
            } label: {
                Label("登记任务", systemImage: "clock.arrow.circlepath")
            }
            .buttonStyle(.borderless)

            Button {
                importReviewCSVFromFile(dryRun: true)
            } label: {
                Label("预检审片", systemImage: "doc.text.magnifyingglass")
            }
            .buttonStyle(.borderless)

            Button {
                importReviewCSVFromFile(dryRun: false)
            } label: {
                Label("导入审片", systemImage: "square.and.arrow.down.badge.checkmark")
            }
            .buttonStyle(.borderless)

            Button {
                revealReviewTemplateCSV()
            } label: {
                Label("审片模板", systemImage: "tablecells")
            }
            .buttonStyle(.borderless)

            Button {
                revealReviewQueueCSV()
            } label: {
                Label("修复队列", systemImage: "list.bullet.rectangle")
            }
            .buttonStyle(.borderless)

            Button {
                revealMediaAPIEnvExample()
            } label: {
                Label("配置 API", systemImage: "key.horizontal")
            }
            .buttonStyle(.borderless)

            Button {
                openProductionWidgetPreview()
            } label: {
                Label("预览网页", systemImage: "rectangle.on.rectangle")
            }
            .buttonStyle(.borderless)

            Button {
                stageProductionScriptPrompt()
            } label: {
                Label("运行脚本", systemImage: "play.circle")
            }
            .buttonStyle(.borderless)

            Button {
                restageProductionPackagePrompt()
            } label: {
                Label("接力聊天", systemImage: "text.bubble")
            }
            .buttonStyle(.borderless)
        }
        .font(.caption)
        .disabled(lastProductionExport == nil)
    }

    func importShortDramaPlanFromFile(dryRun: Bool) {
        let panel = NSOpenPanel()
        panel.title = dryRun ? "预检短剧规划 JSON" : "导入短剧规划 JSON"
        panel.message = "选择短剧 Skill、Ruby 脚本或 WillDeep 导出的规划 JSON。"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        statusMessage = dryRun ? "正在预检短剧规划：\(url.path)" : "正在导入短剧规划：\(url.path)"
        Task {
            do {
                let result = try await AgentShortDramaTools.importPlan(
                    arguments: [
                        "file_path": .string(url.path),
                        "dry_run": .bool(dryRun),
                    ],
                    context: AgentToolContext(
                        rootDirectory: nil,
                        runtimeID: panelScope.runtime?.id,
                        shortDramaStore: appState.agentShortDramaStore
                    )
                )
                await MainActor.run {
                    statusMessage = result.payload
                    if !dryRun {
                        panelScope.request = AgentSidePanelOpenRequest(kind: .shortDrama)
                    }
                }
            } catch {
                await MainActor.run {
                    statusMessage = "\(dryRun ? "预检" : "导入")短剧规划失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func exportShortDramaPlanTemplate() {
        do {
            let url = try AgentShortDramaPlanTemplate.write(to: AgentShortDramaPlanTemplate.defaultOutputURL())
            NSWorkspace.shared.activateFileViewerSelecting([url])
            statusMessage = """
            已生成短剧规划 JSON 模板：
            \(url.path)
            可交给短剧 Skill 或 Ruby 脚本填写，再用侧栏导入按钮或 short_drama_import_plan 导回。
            """
        } catch {
            statusMessage = "生成短剧规划模板失败：\(error.localizedDescription)"
        }
    }

    func importReviewCSVFromFile(dryRun: Bool) {
        let panel = NSOpenPanel()
        panel.title = dryRun ? "预检短剧审片 CSV" : "导入短剧审片 CSV"
        panel.message = "选择已填写的 production-review-template.csv 或 production-review-queue.csv，也可选择基于 production-shot-list.csv 扩展的审片表。至少包含 shot_id 和 review_title/title/issue；包含 review_item_id/review_status 时会更新或关闭已有检查项。"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if let csvType = UTType(filenameExtension: "csv") {
            panel.allowedContentTypes = [csvType, .plainText]
        } else {
            panel.allowedContentTypes = [.plainText]
        }
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        statusMessage = dryRun ? "正在预检审片 CSV：\(url.path)" : "正在导入审片 CSV：\(url.path)"
        Task {
            do {
                let result = try await AgentShortDramaTools.importReviewCSV(
                    arguments: [
                        "file_path": .string(url.path),
                        "dry_run": .bool(dryRun),
                    ],
                    context: AgentToolContext(
                        rootDirectory: nil,
                        runtimeID: panelScope.runtime?.id,
                        shortDramaStore: appState.agentShortDramaStore
                    )
                )
                await MainActor.run {
                    statusMessage = result.payload
                    if !dryRun {
                        panelScope.request = AgentSidePanelOpenRequest(kind: .shortDrama)
                        stageImportedReviewCSVPrompt(fileURL: url, result: result)
                    }
                }
            } catch {
                await MainActor.run {
                    statusMessage = "\(dryRun ? "预检" : "导入")审片 CSV 失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func exportActiveProject() {
        guard let project = store.activeProject else {
            statusMessage = "请先选择短剧项目。"
            return
        }
        do {
            try exportProductionPackage(project: project, episode: nil)
        } catch {
            statusMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    func exportEpisodePackage(project: AgentShortDramaProject, episode: AgentShortDramaEpisode) {
        do {
            try exportProductionPackage(project: project, episode: episode)
        } catch {
            statusMessage = "导出本集失败：\(error.localizedDescription)"
        }
    }

    private func exportProductionPackage(project: AgentShortDramaProject, episode: AgentShortDramaEpisode?) throws {
        let export = try AgentShortDramaProductionExporter.export(project: project, episodeID: episode?.id)
        lastProductionExport = export
        NSWorkspace.shared.activateFileViewerSelecting([export.markdownURL])
        stageProductionPackagePrompt(project: project, episode: episode, export: export)
        let widgetStatus = queueProductionWidgetPreview(export: export)
        statusMessage = """
        已导出\(episode == nil ? "制作包" : "本集制作包")：
        \(export.markdownURL.path)
        Manifest 模板：
        \(export.mediaManifestTemplateURL.path)
        剪辑时间线：
        \(export.timelineURL.path)
        缺口报告：
        \(export.gapReportURL.path)
        分镜 CSV 清单：
        \(export.shotListCSVURL.path)
        审片 CSV 模板：
        \(export.reviewTemplateCSVURL.path)
        检查项修复队列：
        \(export.reviewQueueCSVURL.path)
        Ruby 脚本模板：
        \(export.rubyScriptTemplateURL.path)
        环境变量示例：
        \(export.envExampleURL.path)
        网页预览：
        \(export.widgetPreviewURL.path)
        网页组件：
        \(widgetStatus)
        输出目录：
        \(export.outputDirectory.path)
        """
    }

    private func importLastProductionPackage(dryRun: Bool, importPendingTasks: Bool = false) {
        guard let export = lastProductionExport else {
            statusMessage = "请先导出短剧制作包。"
            return
        }
        if dryRun {
            statusMessage = "正在预检制作包产物..."
        } else if importPendingTasks {
            statusMessage = "正在登记制作包远端异步任务..."
        } else {
            statusMessage = "正在导回制作包产物..."
        }
        Task {
            do {
                let result = try await AgentMediaImportTools.importManifest(
                    arguments: [
                        "package_directory": .string(export.directory.path),
                        "dry_run": .bool(dryRun),
                        "import_pending_tasks": .bool(importPendingTasks),
                    ],
                    context: AgentToolContext(
                        rootDirectory: nil,
                        runtimeID: panelScope.runtime?.id,
                        mediaTaskRegistry: appState.agentMediaTaskRegistry,
                        shortDramaStore: appState.agentShortDramaStore
                    )
                )
                await MainActor.run {
                    statusMessage = result.payload
                    if !dryRun || importPendingTasks {
                        panelScope.request = AgentSidePanelOpenRequest(kind: .mediaTasks)
                        stageImportedProductionPackagePrompt(
                            export: export,
                            importPendingTasks: importPendingTasks,
                            result: result
                        )
                    }
                }
            } catch {
                await MainActor.run {
                    let action = dryRun ? "预检" : (importPendingTasks ? "登记远端任务" : "导回")
                    statusMessage = "\(action)失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func stageImportedProductionPackagePrompt(
        export: AgentShortDramaProductionExporter.ExportResult,
        importPendingTasks: Bool,
        result: AgentToolResult
    ) {
        let actionLabel = importPendingTasks ? "登记远端异步任务" : "导回产物"
        let handoff = productionPackageHandoff(export: export, action: "production_package_imported")
        let prompt = """
        已完成短剧制作包\(actionLabel)，请基于最新媒体任务和短剧项目状态继续推进制作：
        制作包目录：\(export.directory.path)
        媒体回填 manifest：\(export.mediaManifestTemplateURL.path)
        剪辑时间线：\(export.timelineURL.path)
        缺口报告：\(export.gapReportURL.path)
        分镜 CSV 清单：\(export.shotListCSVURL.path)
        审片 CSV 模板：\(export.reviewTemplateCSVURL.path)
        检查项修复队列：\(export.reviewQueueCSVURL.path)
        网页预览：\(export.widgetPreviewURL.path)
        脚本输出目录：\(export.outputDirectory.path)

        导入结果摘要：
        \(result.summary)

        \(handoff)

        请先查看当前短剧项目和媒体任务侧栏状态。若有多个候选图，请打开候选图选择器让用户选主图；若已有可用主图，请继续安排视频生成；若有失败或仍在运行的任务，请说明原因并给出刷新、重试或调整 prompt 的下一步。
        """
        let trimmedInput = panelScope.input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedInput.isEmpty {
            panelScope.input = prompt
        } else if !panelScope.input.contains(export.directory.path) {
            panelScope.input += "\n\n\(prompt)"
        }
        appState.agentComposerFocusRevision += 1
    }

    private func stageImportedReviewCSVPrompt(fileURL: URL, result: AgentToolResult) {
        let prompt = """
        已导入短剧审片 CSV，请基于最新分镜 reviewItems 继续推进修复：
        审片 CSV：\(fileURL.path)

        导入结果摘要：
        \(result.summary)

        请先查看短剧侧栏中新增的待处理检查项。对 continuity/prompt/note 类型，请给出批量修复顺序；对 redraw/erase/upscale/reshoot 类型，请优先使用已有的图片编辑、放大或补拍工具，并保持 project/episode/shot 锚点回填到对应分镜。
        """
        let trimmedInput = panelScope.input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedInput.isEmpty {
            panelScope.input = prompt
        } else if !panelScope.input.contains(fileURL.path) {
            panelScope.input += "\n\n\(prompt)"
        }
        appState.agentComposerFocusRevision += 1
    }

    private func revealMediaAPIEnvExample() {
        guard let export = lastProductionExport else {
            statusMessage = "请先导出短剧制作包。"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([export.envExampleURL])
        statusMessage = """
        已定位媒体 API 环境变量示例：
        \(export.envExampleURL.path)
        请复制到私有位置后填写真实 token，不要把密钥写回制作包或提交到 git。
        """
    }

    private func revealReviewTemplateCSV() {
        guard let export = lastProductionExport else {
            statusMessage = "请先导出短剧制作包。"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([export.reviewTemplateCSVURL])
        statusMessage = """
        已定位审片 CSV 模板：
        \(export.reviewTemplateCSVURL.path)
        填写 review_title/detail/kind/severity/review_status/suggested_action/artifact_paths 后，可点击“导入审片”写回分镜检查项。
        """
    }

    private func revealReviewQueueCSV() {
        guard let export = lastProductionExport else {
            statusMessage = "请先导出短剧制作包。"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([export.reviewQueueCSVURL])
        statusMessage = """
        已定位检查项修复队列：
        \(export.reviewQueueCSVURL.path)
        这份 CSV 一条未解决 reviewItem 一行，可交给 Ruby、Skill 或外部脚本按 kind/severity/suggested_action 批量处理重绘、擦除、放大、补拍或提示词修复。
        """
    }

    private func openProductionWidgetPreview() {
        guard let export = lastProductionExport else {
            statusMessage = "请先导出短剧制作包。"
            return
        }
        guard let runtimeID = panelScope.runtime?.id else {
            statusMessage = "请先打开或创建一个 Agent 会话，再预览制作包网页。"
            return
        }
        do {
            let html = try String(contentsOf: export.widgetPreviewURL, encoding: .utf8)
            let byteCount = html.utf8.count
            guard byteCount <= 1_048_576 else {
                statusMessage = "制作包网页预览超过 1 MB，请拆分或精简后再打开。"
                return
            }
            let widget = AgentWidget(
                title: "短剧制作预览",
                html: html,
                contextLines: productionPackageWidgetContextLines(export: export, sourceLabel: "short-drama-side-panel")
            )
            AgentWidgetRegistry.shared.add(widget, forRuntime: runtimeID)
            panelScope.request = AgentSidePanelOpenRequest(kind: .widget)
            let kbLabel = byteCount >= 1024 ? "\(byteCount / 1024) KB" : "\(byteCount) B"
            statusMessage = """
            已打开制作包网页预览：
            \(export.widgetPreviewURL.path)
            大小：\(kbLabel)
            """
        } catch {
            statusMessage = "打开制作包网页预览失败：\(error.localizedDescription)"
        }
    }

    private func queueProductionWidgetPreview(export: AgentShortDramaProductionExporter.ExportResult) -> String {
        guard let runtimeID = panelScope.runtime?.id else {
            return "未打开：请先打开或创建一个 Agent 会话。"
        }
        do {
            let html = try String(contentsOf: export.widgetPreviewURL, encoding: .utf8)
            let byteCount = html.utf8.count
            guard byteCount <= 1_048_576 else {
                return "未打开：网页预览超过 1 MB。"
            }
            let widget = AgentWidget(
                title: "短剧制作预览",
                html: html,
                contextLines: productionPackageWidgetContextLines(export: export, sourceLabel: "short-drama-side-panel-auto-export")
            )
            AgentWidgetRegistry.shared.add(widget, forRuntime: runtimeID)
            panelScope.request = AgentSidePanelOpenRequest(kind: .widget)
            let kbLabel = byteCount >= 1024 ? "\(byteCount / 1024) KB" : "\(byteCount) B"
            return "已打开右侧网页组件（\(kbLabel)）。"
        } catch {
            return "未打开：\(error.localizedDescription)"
        }
    }

    private func productionPackageWidgetContextLines(
        export: AgentShortDramaProductionExporter.ExportResult,
        sourceLabel: String
    ) -> [String] {
        [
            "<production-package-handoff>",
            "action: short_drama_side_panel_production_widget",
            "source_label: \(sourceLabel)",
            "source_path: \(export.widgetPreviewURL.path)",
            "package_directory: \(export.directory.path)",
            "manifest_path: \(export.mediaManifestTemplateURL.path)",
            "widget_preview_path: \(export.widgetPreviewURL.path)",
            "review_template_path: \(export.reviewTemplateCSVURL.path)",
            "review_queue_path: \(export.reviewQueueCSVURL.path)",
            "gap_report_path: \(export.gapReportURL.path)",
            "timeline_path: \(export.timelineURL.path)",
            "shot_list_path: \(export.shotListCSVURL.path)",
            "dry_run_import_tool: import_media_manifest",
            "dry_run_import_arguments: package_directory=\(export.directory.path), dry_run=true, import_pending_tasks=true",
            "submit_import_tool: import_media_manifest",
            "submit_import_arguments: package_directory=\(export.directory.path), dry_run=false, import_pending_tasks=true",
            "review_template_import_tool: short_drama_import_review_csv",
            "review_template_import_arguments: package_directory=\(export.directory.path), dry_run=true",
            "review_queue_import_tool: short_drama_import_review_csv",
            "review_queue_import_arguments: file_path=\(export.reviewQueueCSVURL.path), dry_run=true",
            "widget_tool: show_widget",
            "widget_arguments: title=短剧制作预览, html_path=\(export.widgetPreviewURL.path)",
            "recommended_tool: import_media_manifest",
            "recommended_arguments: package_directory=\(export.directory.path), dry_run=true, import_pending_tasks=true",
            "widget_context: production_package_preview",
            "</production-package-handoff>",
        ]
    }

    private func restageProductionPackagePrompt() {
        guard let export = lastProductionExport else {
            statusMessage = "请先导出短剧制作包。"
            return
        }
        guard let project = store.activeProject else {
            statusMessage = "请先选择短剧项目。"
            return
        }
        stageProductionPackagePrompt(project: project, episode: nil, export: export)
        statusMessage = """
        已把制作包接力提示写入聊天输入框：
        \(export.directory.path)
        """
    }

    private func stageProductionScriptPrompt() {
        guard let export = lastProductionExport else {
            statusMessage = "请先导出短剧制作包。"
            return
        }
        let prompt = """
        请运行这个短剧制作包的 Ruby 媒体脚本，并把结果接回 WillDeep：
        制作包目录：\(export.directory.path)
        Ruby 脚本：\(export.rubyScriptTemplateURL.path)
        环境变量示例：\(export.envExampleURL.path)
        剪辑时间线：\(export.timelineURL.path)
        缺口报告：\(export.gapReportURL.path)
        分镜 CSV 清单：\(export.shotListCSVURL.path)
        审片 CSV 模板：\(export.reviewTemplateCSVURL.path)
        检查项修复队列：\(export.reviewQueueCSVURL.path)
        媒体回填 manifest：\(export.mediaManifestTemplateURL.path)
        脚本输出目录：\(export.outputDirectory.path)
        网页预览：\(export.widgetPreviewURL.path)

        请先检查 media-api.env.example 需要哪些环境变量，提醒我把真实 token 放在私有 shell 环境或私有 env 文件里，不要写回制作包、聊天记录或 git。运行脚本时优先使用后台任务；如果 run_command 因 workspace 边界不能访问这个 Application Support 目录，请先说明原因，再请求我确认是否改用可见侧边栏终端执行。

        建议命令：
        cd \(shellQuoted(export.directory.path)) && ruby \(shellQuoted(export.rubyScriptTemplateURL.lastPathComponent))

        脚本结束后，请先调用 import_media_manifest(package_directory: \(export.directory.path), dry_run: true) 预检；如果只有 pending 远端任务，请用 import_pending_tasks: true 登记到媒体任务侧栏；如果已有 outputs 产物，再正式导回并打开 widget-preview.html 或媒体任务侧栏继续处理候选图、主图和视频生成。

        <ruby-media-script-run-handoff>
        action: run_short_drama_ruby_media_script
        package_directory: \(export.directory.path)
        ruby_script_path: \(export.rubyScriptTemplateURL.path)
        env_example_path: \(export.envExampleURL.path)
        timeline_path: \(export.timelineURL.path)
        gap_report_path: \(export.gapReportURL.path)
        shot_list_path: \(export.shotListCSVURL.path)
        review_template_path: \(export.reviewTemplateCSVURL.path)
        review_queue_path: \(export.reviewQueueCSVURL.path)
        manifest_path: \(export.mediaManifestTemplateURL.path)
        output_directory: \(export.outputDirectory.path)
        widget_preview_path: \(export.widgetPreviewURL.path)
        recommended_command: cd \(shellQuoted(export.directory.path)) && ruby \(shellQuoted(export.rubyScriptTemplateURL.lastPathComponent))
        dry_run_import_tool: import_media_manifest
        dry_run_import_arguments: package_directory=\(export.directory.path), dry_run=true, import_pending_tasks=true
        submit_import_tool: import_media_manifest
        submit_import_arguments: package_directory=\(export.directory.path), dry_run=false, import_pending_tasks=true
        pending_import_tool: import_media_manifest
        pending_import_arguments: package_directory=\(export.directory.path), dry_run=false, import_pending_tasks=true
        review_queue_import_tool: short_drama_import_review_csv
        review_queue_import_arguments: file_path=\(export.reviewQueueCSVURL.path), dry_run=true
        widget_tool: show_widget
        widget_arguments: title=短剧制作预览, html_path=\(export.widgetPreviewURL.path), source_label=ruby-media-script-side-panel, source_path=\(export.widgetPreviewURL.path), package_directory=\(export.directory.path), recommended_tool=import_media_manifest, recommended_arguments=package_directory=\(export.directory.path), dry_run=true, import_pending_tasks=true
        security_note: keep real API tokens in a private env file or shell environment; do not write secrets into the package, chat, logs, or git.
        </ruby-media-script-run-handoff>
        """
        let trimmedInput = panelScope.input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedInput.isEmpty {
            panelScope.input = prompt
        } else if !panelScope.input.contains(export.rubyScriptTemplateURL.path) {
            panelScope.input += "\n\n\(prompt)"
        }
        appState.agentComposerFocusRevision += 1
        statusMessage = """
        已把 Ruby 脚本运行接力写入聊天输入框：
        \(export.rubyScriptTemplateURL.path)
        """
    }

    private func stageProductionPackagePrompt(project: AgentShortDramaProject, episode: AgentShortDramaEpisode?, export: AgentShortDramaProductionExporter.ExportResult) {
        let handoff = productionPackageHandoff(export: export, action: "production_package_exported")
        let prompt = """
        请基于这个短剧制作包继续制作媒体产物：
        项目：\(project.title)
        范围：\(episode.map { "第 \($0.order) 集：\($0.title)" } ?? "全项目")
        制作包目录：\(export.directory.path)
        制作包 JSON：\(export.jsonURL.path)
        制作包 Markdown：\(export.markdownURL.path)
        媒体回填 manifest 模板：\(export.mediaManifestTemplateURL.path)
        剪辑时间线：\(export.timelineURL.path)
        缺口报告：\(export.gapReportURL.path)
        分镜 CSV 清单：\(export.shotListCSVURL.path)
        审片 CSV 模板：\(export.reviewTemplateCSVURL.path)
        检查项修复队列：\(export.reviewQueueCSVURL.path)
        Ruby 脚本模板：\(export.rubyScriptTemplateURL.path)
        环境变量示例：\(export.envExampleURL.path)
        网页预览：\(export.widgetPreviewURL.path)
        脚本输出目录：\(export.outputDirectory.path)

        \(handoff)

        请优先用短剧相关 skill 或 Ruby 脚本读取 production-timeline.json 作为剪辑/装配顺序清单；如果要自动补缺口，请读取 production-gap-report.json，它会列出缺主图、缺视频、未解决检查项以及 short_drama_generate_batch_media(target_filter=missing) 的 dry-run/submit 参数。如果要给剪辑软件、表格或审片脚本使用，请读取 production-shot-list.csv，它是一镜一行的平面清单。需要把审片意见回写到分镜时，请填写 production-review-template.csv 里的 review_title/detail/kind/severity/review_status/suggested_action/artifact_paths，再调用 short_drama_import_review_csv(package_directory: \(export.directory.path)) 或让我点击短剧侧栏的“导入审片”。若要批量处理已存在的未解决检查项，请读取 production-review-queue.csv，它按一条 reviewItem 一行列出 kind/severity/detail/suggested_action/artifact_paths。需要完整项目结构时再读取 production-package.json / production-package.md。可以从 ruby-media-script-template.rb 开始改，并参考 media-api.env.example 在环境变量中配置第三方图片/视频 API；该示例支持 WILLDEEP_MEDIA_API_METHOD、WILLDEEP_MEDIA_EXTRA_HEADERS_JSON、自定义轮询/取消 URL，以及 WILLDEEP_MEDIA_REQUEST_FORMAT=multipart。处理擦除、重绘、放大等修复任务时，manifest item 里的 source_image_path / mask_path 可由 Ruby 模板自动转成 data URL 或按 WILLDEEP_MEDIA_SOURCE_IMAGE_FIELD / WILLDEEP_MEDIA_MASK_FIELD 作为 multipart 文件字段上传。生成产物时，把图片/视频写入 outputs/，更新或复用 media-import-manifest-template.json 中的 file_path，然后调用 import_media_manifest 将已生成产物导回 App。可以分批导入，缺失文件会被跳过；如果第三方一次返回多张图片或多个视频 URL，模板会把额外产物保存成 *-candidate-N sibling 文件并追加同锚点 manifest item，导回 App 后可继续走候选图选择流程。如果脚本只提交了远端异步任务、暂时没有 outputs 文件，请把 remote_task_id 或 status_url 写回 manifest，并用 import_pending_tasks: true 先登记到媒体任务侧栏；如果 provider 只返回 id 且需要自定义 some.im 路由，请同时写 status_endpoint_suffix / cancel_endpoint_suffix，保证重启后仍能刷新或取消。脚本运行后可以调用 show_widget 并传入 html_path 指向 widget-preview.html，或让我点击短剧侧栏的“预览网页”打开制作包预览。
        """
        let trimmedInput = panelScope.input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedInput.isEmpty {
            panelScope.input = prompt
        } else if !panelScope.input.contains(export.directory.path) {
            panelScope.input += "\n\n\(prompt)"
        }
        appState.agentComposerFocusRevision += 1
    }

    private func productionPackageHandoff(export: AgentShortDramaProductionExporter.ExportResult, action: String) -> String {
        """
        <production-package-handoff>
        action: \(action)
        package_directory: \(export.directory.path)
        manifest_path: \(export.mediaManifestTemplateURL.path)
        widget_preview_path: \(export.widgetPreviewURL.path)
        markdown_path: \(export.markdownURL.path)
        timeline_path: \(export.timelineURL.path)
        gap_report_path: \(export.gapReportURL.path)
        shot_list_path: \(export.shotListCSVURL.path)
        review_template_path: \(export.reviewTemplateCSVURL.path)
        review_queue_path: \(export.reviewQueueCSVURL.path)
        ruby_script_path: \(export.rubyScriptTemplateURL.path)
        env_example_path: \(export.envExampleURL.path)
        output_directory: \(export.outputDirectory.path)
        dry_run_import_tool: import_media_manifest
        dry_run_import_arguments: package_directory=\(export.directory.path), dry_run=true, import_pending_tasks=true
        submit_import_tool: import_media_manifest
        submit_import_arguments: package_directory=\(export.directory.path), dry_run=false, import_pending_tasks=true
        review_template_import_tool: short_drama_import_review_csv
        review_template_import_arguments: package_directory=\(export.directory.path), dry_run=true
        review_queue_import_tool: short_drama_import_review_csv
        review_queue_import_arguments: file_path=\(export.reviewQueueCSVURL.path), dry_run=true
        widget_tool: show_widget
        widget_arguments: title=短剧制作预览, html_path=\(export.widgetPreviewURL.path), source_label=short-drama-side-panel, source_path=\(export.widgetPreviewURL.path), package_directory=\(export.directory.path), recommended_tool=import_media_manifest, recommended_arguments=package_directory=\(export.directory.path), dry_run=true, import_pending_tasks=true
        </production-package-handoff>
        """
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
