//
//  AgentDevServerPanel.swift
//  WillDeep
//
//  Web-programming side panel for dev-server and live log jobs. It reuses
//  AgentJobRegistry instead of owning processes directly, so AI-started
//  Vite/Next/backend/tail jobs stay visible and controllable in one place.
//

import SwiftUI
import Combine

struct AgentDevServerPanel: View {
    @EnvironmentObject var appState: AppState
    var width: CGFloat = 320

    @State private var logPath: String = ""
    @State private var refreshTick = Date()

    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        let palette = appState.editorSettings.interfaceSkin.palette
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                commandShortcuts
                logTailBox
                jobsSection
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 16)
        }
        .frame(width: width)
        .background(palette.panelFill)
        .onReceive(timer) { value in
            refreshTick = value
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "server.rack")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("Dev Server")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                Text("\(devJobs.filter(\.isAlive).count) running")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text("Web 编程专家会把 Vite/Next/React/Vue、后端服务和 tail -f 日志作为后台任务放到这里。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var commandShortcuts: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("启动")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button {
                    appendPrompt("请激活 Web 编程专家流程，自动识别前端项目脚本，优先用 yarn 启动前端 dev server；用 run_command 的 run_in_background=true，并在启动后打开可预览 URL。")
                } label: {
                    Label("前端", systemImage: "play.fill")
                }
                .buttonStyle(.borderless)
                .focusable(false)

                Button {
                    appendPrompt("请识别当前项目的后端服务启动命令，用 run_command 的 run_in_background=true 启动后端 dev server，并说明端口、健康检查或日志查看方式。")
                } label: {
                    Label("后端", systemImage: "play.circle")
                }
                .buttonStyle(.borderless)
                .focusable(false)
            }

            if !devJobs.isEmpty {
                HStack(spacing: 8) {
                    Button {
                        devJobs.filter(\.isAlive).forEach { _ = appState.agentJobRegistry.kill(id: $0.id) }
                    } label: {
                        Label("停止全部", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
                    .disabled(devJobs.filter(\.isAlive).isEmpty)

                    Button {
                        let handles = devJobs.map(\.displayHandle).joined(separator: ", ")
                        appendPrompt("请重启这些 dev server / tail 任务：\(handles)。先用 kill_job 停止旧任务，再按项目脚本重新用 run_command(run_in_background=true) 启动。")
                    } label: {
                        Label("重启", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.035)))
    }

    private var logTailBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tail 日志")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("logs/dev.log 或 /tmp/app.log", text: $logPath)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
            HStack(spacing: 8) {
                Button {
                    let trimmed = logPath.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    appendPrompt("请用 run_command(run_in_background=true) 执行 tail -f \(trimmed)，并把它作为当前 Dev Server 面板里的实时日志源。")
                } label: {
                    Label("让 AI tail", systemImage: "text.alignleft")
                }
                .buttonStyle(.borderless)
                .focusable(false)
                .disabled(logPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button {
                    appendPrompt("请根据当前前端/后端 dev server 输出，判断应该 tail -f 哪个日志文件；如果没有日志文件，就用 get_job_output 读取后台任务输出。")
                } label: {
                    Label("自动选择", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderless)
                .focusable(false)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.035)))
    }

    private var jobsSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("运行中 / 最近")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if !devJobs.isEmpty {
                    Text(refreshTick, style: .time)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            if devJobs.isEmpty {
                Text("还没有 dev server 或 tail -f 任务。让 AI 启动前端/后端后，这里会显示句柄、状态、停止按钮和输出尾部。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(devJobs) { job in
                        DevServerJobCard(
                            job: job,
                            output: appState.agentJobRegistry.output(id: job.id, tailLines: 60),
                            inspect: { appState.prefillAgentJobInspectionPrompt(for: job) },
                            restart: {
                                appendPrompt("请重启 \(job.displayHandle)：先 kill_job 停掉它，再按原命令或项目最新脚本重新启动。原命令：\(job.command)")
                            },
                            kill: { _ = appState.agentJobRegistry.kill(id: job.id) }
                        )
                    }
                }
            }
        }
    }

    private var devJobs: [AgentBackgroundJob] {
        guard let runtimeID = appState.activeRuntime?.id else { return [] }
        return appState.agentJobRegistry.jobs(forRuntime: runtimeID)
            .filter { job in
                job.isAlive || Self.looksLikeDevServerCommand(job.command)
            }
    }

    private func appendPrompt(_ prompt: String) {
        let trimmedInput = appState.agentInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedInput.isEmpty {
            appState.agentInput = prompt
        } else {
            appState.agentInput += "\n\n\(prompt)"
        }
        appState.agentComposerFocusRevision += 1
    }

    private static func looksLikeDevServerCommand(_ command: String) -> Bool {
        let lower = command.lowercased()
        let needles = [
            "yarn dev", "npm run dev", "pnpm dev", "bun dev",
            "vite", "next dev", "react-scripts start", "vue-cli-service serve",
            "tail -f", "tail -F", "air", "gin --", "go run",
            "rails server", "rails s", "uvicorn", "fastapi", "nodemon",
            "python -m http.server"
        ]
        return needles.contains { lower.contains($0.lowercased()) }
    }
}

private struct DevServerJobCard: View {
    let job: AgentBackgroundJob
    let output: String
    let inspect: () -> Void
    let restart: () -> Void
    let kill: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(job.displayHandle)
                    .font(.caption.weight(.semibold).monospaced())
                Text(job.status.rawValue)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(action: inspect) {
                    Image(systemName: "doc.text.magnifyingglass")
                }
                .buttonStyle(.borderless)
                .focusable(false)
                .help("读取输出")
                Button(action: restart) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .focusable(false)
                .help("让 AI 重启")
                Button(action: kill) {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.borderless)
                .focusable(false)
                .disabled(!job.isAlive)
                .help("停止任务")
            }
            Text(job.command)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            ScrollView(.vertical, showsIndicators: true) {
                Text(output.isEmpty ? "(no output captured yet)" : output)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.82))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 78, maxHeight: 170)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.08)))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.035)))
    }

    private var statusColor: Color {
        switch job.status {
        case .running: return .green
        case .completed: return .blue
        case .failed, .launchFailed, .timedOut: return .red
        case .killed: return .orange
        }
    }
}
