//
//  AgentDispatchGraphView.swift
//  WillDeep
//

import SwiftUI

enum AgentDispatchPresentation {
    static func executorChoiceName(_ choice: AgentDispatchExecutorChoice) -> String {
        choice.pinnedExecutor?.displayName ?? L10n.Dispatch.automatic
    }

    static func targetChoiceName(
        _ choice: AgentDispatchTargetChoice,
        runtimes: [RuntimeDescriptor],
        automaticSuffix: String? = nil
    ) -> String {
        switch choice {
        case .automatic:
            return automaticSuffix.map { L10n.Dispatch.automatic + $0 }
                ?? L10n.Dispatch.automatic
        case .local:
            return L10n.Dispatch.currentMac
        case .remote(let id):
            guard let runtime = runtimes.first(where: { $0.id == id }) else {
                return L10n.Dispatch.notProbed
            }
            return "\(runtime.displayName) · SSH"
        }
    }

    static func taskStateColor(_ state: AgentDispatchTaskState) -> Color {
        switch state {
        case .blocked: return .secondary
        case .queued: return .indigo
        case .running: return .blue
        case .reviewing: return .orange
        case .accepted: return .mint
        case .failed: return .red
        case .cancelled: return .secondary
        case .merged: return .green
        }
    }

    static func commandStatus(_ command: AgentDispatchCommand) -> String {
        switch command.status {
        case .applied: return L10n.Dispatch.appliedImmediately
        case .queued: return L10n.Dispatch.queuedForSafePoint
        case .pendingConfirmation: return L10n.Dispatch.interruptRequired
        case .cancelled: return L10n.Dispatch.cancelled
        }
    }
}

nonisolated enum AgentDispatchGraphSelection: Hashable {
    case task(UUID)
    case acceptance
}

nonisolated struct AgentDispatchGraphEdge: Equatable {
    let sourceID: UUID
    let targetID: UUID?
}

nonisolated struct AgentDispatchGraphLayout: Equatable {
    static let taskSize = CGSize(width: 216, height: 156)
    static let gateSize = CGSize(width: 168, height: 124)
    static let columnSpacing: CGFloat = 92
    static let rowSpacing: CGFloat = 38
    static let canvasPadding: CGFloat = 72

    let taskCenters: [UUID: CGPoint]
    let gateCenter: CGPoint
    let edges: [AgentDispatchGraphEdge]
    let canvasSize: CGSize
    let levelCount: Int

    init(tasks: [AgentDispatchTask]) {
        let taskIDs = Set(tasks.map(\.id))
        var levels: [UUID: Int] = [:]
        var unresolved = tasks

        for _ in 0 ..< max(tasks.count, 1) {
            var progressed = false
            unresolved.removeAll { task in
                let dependencies = task.dependencyIDs.filter(taskIDs.contains)
                guard dependencies.allSatisfy({ levels[$0] != nil }) else {
                    return false
                }
                levels[task.id] = dependencies.compactMap { levels[$0] }.max().map { $0 + 1 } ?? 0
                progressed = true
                return true
            }
            if unresolved.isEmpty || !progressed {
                break
            }
        }

        for task in unresolved {
            levels[task.id] = 0
        }

        let maxTaskLevel = levels.values.max() ?? 0
        let grouped = Dictionary(grouping: tasks) { levels[$0.id, default: 0] }
        let maxRows = max(grouped.values.map(\.count).max() ?? 1, 1)
        let contentHeight = CGFloat(maxRows) * Self.taskSize.height
            + CGFloat(maxRows - 1) * Self.rowSpacing
        let canvasHeight = max(contentHeight + Self.canvasPadding * 2, 430)

        var centers: [UUID: CGPoint] = [:]
        for level in 0 ... maxTaskLevel {
            let columnTasks = grouped[level] ?? []
            let columnHeight = CGFloat(columnTasks.count) * Self.taskSize.height
                + CGFloat(max(columnTasks.count - 1, 0)) * Self.rowSpacing
            let firstY = (canvasHeight - columnHeight) / 2 + Self.taskSize.height / 2
            let x = Self.canvasPadding + Self.taskSize.width / 2
                + CGFloat(level) * (Self.taskSize.width + Self.columnSpacing)
            for (row, task) in columnTasks.enumerated() {
                centers[task.id] = CGPoint(
                    x: x,
                    y: firstY + CGFloat(row) * (Self.taskSize.height + Self.rowSpacing)
                )
            }
        }

        let gateLevel = maxTaskLevel + 1
        let gateX = Self.canvasPadding + Self.taskSize.width / 2
            + CGFloat(gateLevel) * (Self.taskSize.width + Self.columnSpacing)
        gateCenter = CGPoint(x: gateX, y: canvasHeight / 2)
        taskCenters = centers
        levelCount = gateLevel + 1

        var builtEdges: [AgentDispatchGraphEdge] = []
        for task in tasks {
            for dependencyID in task.dependencyIDs where taskIDs.contains(dependencyID) {
                builtEdges.append(
                    AgentDispatchGraphEdge(sourceID: dependencyID, targetID: task.id)
                )
            }
        }
        let dependencySources = Set(tasks.flatMap(\.dependencyIDs))
        for task in tasks where !dependencySources.contains(task.id) {
            builtEdges.append(AgentDispatchGraphEdge(sourceID: task.id, targetID: nil))
        }
        edges = builtEdges

        canvasSize = CGSize(
            width: gateX + Self.gateSize.width / 2 + Self.canvasPadding,
            height: canvasHeight
        )
    }
}

struct AgentDispatchGraphView: View {
    let goal: AgentDispatchGoal
    let selection: AgentDispatchGraphSelection?
    let runtimeDescriptors: [RuntimeDescriptor]
    let onSelect: (AgentDispatchGraphSelection) -> Void
    let onAddTask: () -> Void
    let onEditTask: (UUID) -> Void

    @State private var zoom: CGFloat = 1

    private let minimumZoom: CGFloat = 0.65
    private let maximumZoom: CGFloat = 1.4

    private var layout: AgentDispatchGraphLayout {
        AgentDispatchGraphLayout(tasks: goal.tasks)
    }

    var body: some View {
        VStack(spacing: 0) {
            graphToolbar
            Divider().opacity(0.45)
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    graphGrid
                    graphEdges
                    ForEach(Array(goal.tasks.enumerated()), id: \.element.id) { index, task in
                        taskCard(task, index: index)
                            .position(layout.taskCenters[task.id] ?? .zero)
                    }
                    acceptanceGate
                        .position(layout.gateCenter)
                }
                .frame(width: layout.canvasSize.width, height: layout.canvasSize.height)
                .scaleEffect(zoom, anchor: .topLeading)
                .frame(
                    width: layout.canvasSize.width * zoom,
                    height: layout.canvasSize.height * zoom,
                    alignment: .topLeading
                )
            }
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.38))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.Dispatch.graphTitle)
    }

    private var graphToolbar: some View {
        HStack(spacing: 9) {
            Label(L10n.Dispatch.graphTitle, systemImage: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 12, weight: .semibold))
            Text(L10n.Dispatch.graphSummary(goal.tasks.count, layout.edges.count))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            legendDot(.blue, text: L10n.Dispatch.graphActive)
            legendDot(.orange, text: L10n.Dispatch.graphReview)
            legendDot(.green, text: L10n.Dispatch.graphComplete)
            Divider()
                .frame(height: 18)
                .padding(.horizontal, 3)
            Button {
                adjustZoom(by: -0.1)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help(L10n.Dispatch.zoomOut)
            Text("\(Int((zoom * 100).rounded()))%")
                .font(.system(size: 10, design: .monospaced))
                .frame(width: 42)
            Button {
                adjustZoom(by: 0.1)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help(L10n.Dispatch.zoomIn)
            Button {
                withAnimation(.easeOut(duration: 0.16)) {
                    zoom = 1
                }
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .help(L10n.Dispatch.resetZoom)
            Button(action: onAddTask) {
                Label(L10n.Dispatch.addNode, systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!goal.isWorkspaceBound)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.52))
    }

    private var graphGrid: some View {
        Canvas { context, size in
            let spacing: CGFloat = 24
            var path = Path()
            stride(from: 0, through: size.width, by: spacing).forEach { x in
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            stride(from: 0, through: size.height, by: spacing).forEach { y in
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(path, with: .color(Color.secondary.opacity(0.055)), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }

    private var graphEdges: some View {
        Canvas { context, _ in
            for edge in layout.edges {
                guard let sourceCenter = layout.taskCenters[edge.sourceID] else { continue }
                let targetCenter = edge.targetID.flatMap { layout.taskCenters[$0] }
                    ?? layout.gateCenter
                let source = CGPoint(
                    x: sourceCenter.x + AgentDispatchGraphLayout.taskSize.width / 2,
                    y: sourceCenter.y
                )
                let targetWidth = edge.targetID == nil
                    ? AgentDispatchGraphLayout.gateSize.width
                    : AgentDispatchGraphLayout.taskSize.width
                let target = CGPoint(x: targetCenter.x - targetWidth / 2, y: targetCenter.y)
                let controlOffset = max((target.x - source.x) * 0.46, 34)
                var path = Path()
                path.move(to: source)
                path.addCurve(
                    to: target,
                    control1: CGPoint(x: source.x + controlOffset, y: source.y),
                    control2: CGPoint(x: target.x - controlOffset, y: target.y)
                )
                context.stroke(
                    path,
                    with: .color(edgeColor(edge).opacity(0.72)),
                    style: StrokeStyle(lineWidth: 1.8, lineCap: .round)
                )
                context.fill(
                    Path(ellipseIn: CGRect(x: target.x - 3.5, y: target.y - 3.5, width: 7, height: 7)),
                    with: .color(edgeColor(edge))
                )
            }
        }
        .allowsHitTesting(false)
    }

    private func taskCard(_ task: AgentDispatchTask, index: Int) -> some View {
        let selected = selection == .task(task.id)
        let stateColor = AgentDispatchPresentation.taskStateColor(task.state)
        let displayTarget = task.resolvedTarget
            ?? goal.resolvedTargetChoice(taskChoice: task.targetChoice)
            ?? .automatic
        return Button {
            onSelect(.task(task.id))
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    Text(L10n.Dispatch.nodeOrdinal(index + 1))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(stateColor)
                    Spacer(minLength: 4)
                    Label(
                        task.resolvedExecutor?.displayName
                            ?? AgentDispatchPresentation.executorChoiceName(task.executorChoice),
                        systemImage: task.resolvedExecutor?.symbol ?? "cpu"
                    )
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                Text(task.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)

                HStack(spacing: 6) {
                    Circle()
                        .fill(stateColor)
                        .frame(width: 7, height: 7)
                    Text(L10n.Dispatch.state(task.state))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(stateColor)
                    Spacer()
                    if !task.dependencyIDs.isEmpty {
                        Label("\(task.dependencyIDs.count)", systemImage: "arrow.triangle.merge")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }

                Divider().opacity(0.42)

                HStack(spacing: 6) {
                    badge(
                        AgentDispatchPresentation.targetChoiceName(
                            displayTarget,
                            runtimes: runtimeDescriptors
                        ),
                        symbol: displayTarget.isRemoteTarget ? "network" : "desktopcomputer"
                    )
                    badge(task.branchName, symbol: "arrow.triangle.branch")
                }
            }
            .padding(12)
            .frame(
                width: AgentDispatchGraphLayout.taskSize.width,
                height: AgentDispatchGraphLayout.taskSize.height,
                alignment: .topLeading
            )
            .background(Color(nsColor: .controlBackgroundColor).opacity(selected ? 0.96 : 0.82))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(stateColor)
                    .frame(width: selected ? 4 : 3)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .stroke(
                        selected ? Color.accentColor : Color.secondary.opacity(0.18),
                        lineWidth: selected ? 2 : 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 11))
            .shadow(
                color: selected ? Color.accentColor.opacity(0.16) : Color.black.opacity(0.045),
                radius: selected ? 12 : 5,
                y: 2
            )
            .overlay(alignment: .leading) {
                graphPort(color: stateColor)
                    .offset(x: -5)
            }
            .overlay(alignment: .trailing) {
                graphPort(color: stateColor)
                    .offset(x: 5)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                onEditTask(task.id)
            } label: {
                Label(L10n.Dispatch.editNode, systemImage: "slider.horizontal.3")
            }
            .disabled(task.state == .running || task.state == .reviewing)
        }
        .accessibilityLabel(L10n.Dispatch.taskNodeAccessibility(index + 1, task.title))
        .accessibilityValue(L10n.Dispatch.state(task.state))
        .accessibilityHint(L10n.Dispatch.nodeSelectionHint)
    }

    private var acceptanceGate: some View {
        let selected = selection == .acceptance
        let completed = goal.tasks.filter {
            $0.state == .accepted || $0.state == .merged
        }.count
        let tint: Color = completed == goal.tasks.count && !goal.tasks.isEmpty ? .green : .orange
        return Button {
            onSelect(.acceptance)
        } label: {
            VStack(spacing: 9) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(tint)
                Text(L10n.Dispatch.acceptanceGate)
                    .font(.system(size: 12, weight: .semibold))
                    .multilineTextAlignment(.center)
                Text("\(completed)/\(goal.tasks.count)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tint)
                ProgressView(value: Double(completed), total: Double(max(goal.tasks.count, 1)))
                    .tint(tint)
                    .frame(width: 96)
            }
            .frame(
                width: AgentDispatchGraphLayout.gateSize.width,
                height: AgentDispatchGraphLayout.gateSize.height
            )
            .background(Color(nsColor: .controlBackgroundColor).opacity(selected ? 0.96 : 0.84))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(
                        selected ? Color.accentColor : tint.opacity(0.35),
                        lineWidth: selected ? 2 : 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: selected ? Color.accentColor.opacity(0.15) : .clear, radius: 10)
            .overlay(alignment: .leading) {
                graphPort(color: tint)
                    .offset(x: -5)
            }
            .accessibilityElement(children: .ignore)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.Dispatch.acceptanceGate)
        .accessibilityValue(L10n.Dispatch.acceptanceProgress(completed, goal.tasks.count))
        .accessibilityHint(L10n.Dispatch.nodeSelectionHint)
    }

    private func graphPort(color: Color) -> some View {
        Circle()
            .fill(Color(nsColor: .windowBackgroundColor))
            .frame(width: 11, height: 11)
            .overlay(Circle().stroke(color, lineWidth: 2))
    }

    private func edgeColor(_ edge: AgentDispatchGraphEdge) -> Color {
        guard let source = goal.tasks.first(where: { $0.id == edge.sourceID }) else {
            return .secondary
        }
        return AgentDispatchPresentation.taskStateColor(source.state)
    }

    private func badge(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 8.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
            .background(Color.secondary.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func legendDot(_ color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }

    private func adjustZoom(by delta: CGFloat) {
        withAnimation(.easeOut(duration: 0.12)) {
            zoom = min(maximumZoom, max(minimumZoom, zoom + delta))
        }
    }
}
