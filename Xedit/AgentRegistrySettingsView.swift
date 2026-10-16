import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Exchange definitions are edited separately from legacy model overrides.
struct AgentRegistrySettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var installations: [AgentDefinitionLibrary.Installation] = []
    @State private var catalog: [AgentRegistryIndex.Item] = []
    @State private var selected: AgentDefinitionLibrary.Installation?
    @State private var draft = ""
    @State private var message = ""
    @State private var busy = false
    @State private var operationGate = AgentWorkspaceOperationGate()
    @State private var advancedEditor = false
    @State private var query = ""
    @State private var sourceFilter = "all"
    @State private var savedDraft = ""
    @State private var pendingAction: (() -> Void)?
    private var accountEpoch: UUID { AgentWorkspaceNavigation.shared.accountEpoch }
    @State private var conflictVersion: String?
    private let library: AgentDefinitionLibrary
    private let embedded: Bool
    private let allowsRemote: Bool
    private let onExperiment: ((AgentPackageV1?) -> Void)?
    private let providerEntries: [AgentProviderEntry]

    init(library: AgentDefinitionLibrary = AgentDefinitionLibrary(), initialSelection: AgentDefinitionLibrary.Installation? = nil,
         embedded: Bool = false, allowsRemote: Bool = true, providerEntries: [AgentProviderEntry] = [], onExperiment: ((AgentPackageV1?) -> Void)? = nil) {
        self.library = library
        self.embedded = embedded; self.allowsRemote = allowsRemote; self.onExperiment = onExperiment
        self.providerEntries = providerEntries
        _selected = State(initialValue: initialSelection)
        let data = initialSelection.flatMap { try? library.package(revision: $0.selected, account: $0.account).definitionEditorData() }
        let initialDraft = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
        _draft = State(initialValue: initialDraft); _savedDraft = State(initialValue: initialDraft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "智能体库", table: "AgentWorkspace")).font(.system(size: 28, weight: .bold))
                    Text(String(localized: "管理定义、官方版本和跨端同步", table: "AgentWorkspace")).foregroundStyle(.secondary)
                }
                Spacer()
                connectionBadge
                if !embedded { Button(String(localized: "完成", table: "AgentRegistry")) { dismiss() } }
            }
            HStack {
                Button { request(create) } label: { Label(String(localized: "创建智能体", table: "AgentWorkspace"), systemImage: "plus") }.buttonStyle(.borderedProminent)
                Button(String(localized: "导入", table: "AgentRegistry")) { request(importPackage) }
                Button(String(localized: "刷新官方目录", table: "AgentRegistry")) { perform { catalog = try await service().index().items } }
                    .disabled(!allowsRemote)
                Spacer()
                Button { synchronize() } label: { Label(String(localized: "同步私有智能体", table: "AgentRegistry"), systemImage: "arrow.triangle.2.circlepath") }
                    .disabled(!allowsRemote)
            }.disabled(busy)
            HSplitView {
                libraryList
                installationDetail
            }
            if !message.isEmpty { Text(message).font(.caption).textSelection(.enabled) }
            if busy { ProgressView().controlSize(.small) }
        }.padding(28).frame(minWidth: 850, minHeight: 600)
            .onAppear(perform: reload)
            .onChange(of: draft) { _ in
                if draft != savedDraft { AgentWorkspaceNavigation.shared.dirtySections.insert(.library) }
                else { AgentWorkspaceNavigation.shared.dirtySections.remove(.library) }
            }
            .confirmationDialog(String(localized: "有尚未保存的修改", table: "AgentWorkspace"), isPresented: Binding(
                get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } })) {
                    Button(String(localized: "放弃修改并继续", table: "AgentWorkspace"), role: .destructive) {
                        let action = pendingAction; pendingAction = nil; action?()
                    }
                    Button(String(localized: "继续编辑", table: "AgentWorkspace"), role: .cancel) { pendingAction = nil }
                }
            .onReceive(NotificationCenter.default.publisher(for: SomeIMIntegrationStore.sessionDidChangeNotification)) { _ in
                operationGate.invalidate(); busy = false; selected = nil; draft = ""; savedDraft = ""; conflictVersion = nil; pendingAction = nil; message = ""; reload()
            }
    }
    private var libraryList: some View {
                VStack(alignment: .leading, spacing: 12) {
                    TextField(String(localized: "搜索名称或标识", table: "AgentWorkspace"), text: $query).textFieldStyle(.roundedBorder)
                    Picker(String(localized: "来源", table: "AgentWorkspace"), selection: $sourceFilter) {
                        Text(String(localized: "全部", table: "AgentWorkspace")).tag("all")
                        Text(String(localized: "本机", table: "AgentWorkspace")).tag("local")
                        Text(String(localized: "私有", table: "AgentWorkspace")).tag("private")
                        Text(String(localized: "官方", table: "AgentWorkspace")).tag("official")
                    }.labelsHidden().pickerStyle(.segmented)
                    ScrollView {
                      LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(filteredInstallations) { installation in
                            Button { request { choose(installation) } } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: installation.source == .official ? "checkmark.seal" : "person.crop.square").foregroundStyle(.blue).frame(width: 22)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(displayName(installation)).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                                        HStack {
                                            Text(sourceTitle(installation.source.rawValue))
                                            Text((try? library.package(revision: installation.selected, account: installation.account).definition.version) ?? "")
                                        }.font(.system(size: 13)).foregroundStyle(.secondary)
                                        if installation.conflict != nil { Text(String(localized: "同步冲突", table: "AgentRegistry")).foregroundStyle(.orange) }
                                        if installation.deleted { Text(String(localized: "已删除", table: "AgentRegistry")).foregroundStyle(.secondary) }
                                    }
                                    Spacer(minLength: 0)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                    .background(selected?.id == installation.id ? Color.blue.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 9))
                            }.buttonStyle(.plain)
                        }
                        if filteredInstallations.isEmpty {
                            Text(String(localized: "没有匹配的智能体", table: "AgentWorkspace")).foregroundStyle(.secondary).padding(12)
                        }
                        if sourceFilter == "all" || sourceFilter == "official" {
                          ForEach(filteredCatalog) { item in catalogRow(item) }
                        }
                      }
                    }
                }.padding(12).frame(minWidth: 250, idealWidth: 285, maxWidth: 320)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12))
    }
    private var installationDetail: some View {
                ScrollView {
                  VStack(alignment: .leading, spacing: 16) {
                    if let selected {
                        HStack {
                            Text(displayName(selected)).font(.system(size: 22, weight: .semibold))
                            Spacer()
                            Button(String(localized: "创建实验", table: "AgentWorkspace")) {
                                onExperiment?(try? library.package(revision: selected.selected, account: selected.account))
                            }.disabled(onExperiment == nil)
                        }
                    }
                    if !draft.isEmpty {
                        definitionForm.disabled(selected?.source == .official)
                        if selected?.source == .official {
                            Label(String(localized: "官方定义只读，请派生副本后编辑或实验", table: "AgentWorkspace"), systemImage: "lock").foregroundStyle(.secondary)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            Label(String(localized: "选择智能体，查看并编辑版本", table: "AgentWorkspace"), systemImage: "square.grid.2x2").font(.title3)
                            Text(String(localized: "也可以创建定义、导入版本包，或刷新官方目录。", table: "AgentWorkspace")).foregroundStyle(.secondary)
                        }.padding(.vertical, 44)
                    }
                    HStack {
                        Button(String(localized: "保存并固定版本", table: "AgentRegistry"), action: saveDraft)
                            .buttonStyle(.borderedProminent).disabled(busy || selected?.source == .official || draft.isEmpty)
                        Button(String(localized: "导出版本包", table: "AgentRegistry"), action: exportPackage).disabled(selected == nil)
                    }
                    if let selected {
                        Divider()
                        controls(selected)
                    }
                    DisclosureGroup(String(localized: "高级：JSON、技能正文与版本哈希", table: "AgentWorkspace"), isExpanded: $advancedEditor) {
                        if let selected { Text(selected.selected).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                        Text(String(localized: "定义 JSON：修改指令、职责、工具或技能时增加 version，保存后形成新的不可变版本。", table: "AgentRegistry"))
                            .font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $draft).font(.system(.body, design: .monospaced)).frame(minHeight: 220)
                            .disabled(selected?.source == .official)
                    }
                  }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }.background(.white, in: RoundedRectangle(cornerRadius: 12)).frame(minWidth: 480)
    }
    private var filteredInstallations: [AgentDefinitionLibrary.Installation] {
        installations.filter { AgentWorkspacePresentation.matchesSource($0.source.rawValue, filter: sourceFilter)
            && AgentWorkspacePresentation.matches(name: displayName($0), id: $0.definitionID, query: query) }
    }
    private var filteredCatalog: [AgentRegistryIndex.Item] {
        catalog.filter { AgentWorkspacePresentation.matches(name: $0.name["zh-Hans"] ?? $0.name["en"] ?? "", id: $0.definition_id, query: query) }
    }
    private func catalogRow(_ item: AgentRegistryIndex.Item) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.name["zh-Hans"] ?? item.name["en"] ?? item.definition_id)
            Text(item.version + " · " + item.purpose).font(.caption)
            Button(String(localized: "安装固定版本", table: "AgentRegistry")) {
                perform {
                    let (package, keys) = try await service().official(item)
                    _ = try library.install(package, source: .official, keys: keys, dirty: false)
                }
            }.disabled(busy || !allowsRemote)
        }.padding(12)
    }
    private func sourceTitle(_ source: String) -> String {
        switch source {
        case "official": String(localized: "官方", table: "AgentWorkspace")
        case "private": String(localized: "私有", table: "AgentWorkspace")
        default: String(localized: "本机", table: "AgentWorkspace")
        }
    }
    private var connectionBadge: some View {
        Label(library.activeAccount == nil ? String(localized: "本机模式", table: "AgentWorkspace") : String(localized: "some.im · 已连接", table: "AgentWorkspace"),
              systemImage: library.activeAccount == nil ? "desktopcomputer" : "checkmark.circle.fill")
            .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
    }
    private var definitionForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent(String(localized: "智能体标识", table: "AgentRegistry")) {
                TextField(String(localized: "智能体标识", table: "AgentRegistry"), text: definitionBinding(\.definition_id)).labelsHidden().disabled(selected != nil)
            }
            LabeledContent(String(localized: "名称", table: "AgentRegistry")) {
                TextField(String(localized: "名称", table: "AgentRegistry"), text: Binding(
                    get: { decodedDraft?.name["zh-Hans"] ?? decodedDraft?.name["en"] ?? "" },
                    set: { value in editDefinition { $0.name["zh-Hans"] = value } })).labelsHidden()
            }
            LabeledContent(String(localized: "版本号", table: "AgentRegistry")) {
                TextField(String(localized: "版本号", table: "AgentRegistry"), text: definitionBinding(\.version)).labelsHidden()
            }
            LabeledContent(String(localized: "适用任务", table: "AgentRegistry")) {
                TextField(String(localized: "适用任务", table: "AgentRegistry"), text: definitionBinding(\.purpose)).labelsHidden()
            }
            Picker(String(localized: "基础职责", table: "AgentRegistry"), selection: definitionBinding(\.base_role)) {
                Text(String(localized: "通用调查", table: "AgentRegistry")).tag("generalist")
                Text(String(localized: "实现", table: "AgentRegistry")).tag("implementer")
                Text(String(localized: "验证", table: "AgentRegistry")).tag("tester")
                Text(String(localized: "审查", table: "AgentRegistry")).tag("reviewer")
                Text(String(localized: "运维", table: "AgentRegistry")).tag("ops_runner")
            }
            HStack {
                capabilityToggle("workspace.read", title: String(localized: "读取文件", table: "AgentRegistry"))
                capabilityToggle("workspace.edit", title: String(localized: "修改文件", table: "AgentRegistry"))
                capabilityToggle("process.verify", title: String(localized: "命令验证", table: "AgentRegistry"))
                capabilityToggle("repository.inspect", title: String(localized: "检查仓库", table: "AgentRegistry"))
            }
            Text(String(localized: "专业指令", table: "AgentRegistry")).font(.headline)
            TextEditor(text: definitionBinding(\.instructions)).frame(minHeight: 180)
            Text(String(localized: "权限由基础职责与本次授权共同限制；新增技能可通过高级编辑或导入版本包。", table: "AgentRegistry"))
                .font(.caption).foregroundStyle(.secondary)
        }.textFieldStyle(.roundedBorder)
    }
    private var decodedDraft: AgentDefinitionV1? { try? JSONDecoder().decode(AgentDefinitionV1.self, from: Data(draft.utf8)) }
    private func definitionBinding(_ keyPath: WritableKeyPath<AgentDefinitionV1, String>) -> Binding<String> {
        Binding(get: { decodedDraft?[keyPath: keyPath] ?? "" }, set: { value in editDefinition { $0[keyPath: keyPath] = value } })
    }
    private func editDefinition(_ edit: (inout AgentDefinitionV1) -> Void) {
        guard var definition = decodedDraft else { return }
        edit(&definition)
        do {
            var value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(definition)) as! [String: Any]
            value["forked_from"] = definition.forked_from.map { $0 as Any } ?? NSNull()
            let encoded = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            draft = String(decoding: encoded, as: UTF8.self)
        } catch { message = error.localizedDescription }
    }
    private func capabilityToggle(_ id: String, title: String) -> some View {
        Toggle(title, isOn: Binding(get: { decodedDraft?.tools.contains(id) ?? false }, set: { enabled in
            editDefinition { definition in
                definition.tools.removeAll { $0 == id }
                if enabled { definition.tools.append(id) }
            }
        })).toggleStyle(.checkbox)
    }
    @ViewBuilder private func controls(_ installation: AgentDefinitionLibrary.Installation) -> some View {
        HStack {
            Toggle(String(localized: "固定当前版本", table: "AgentRegistry"), isOn: Binding(get: { installation.pinned == true }, set: { pinned in
                change {
                    var changed = installation; changed.pinned = pinned
                    if !pinned && !changed.dirty { changed.conflict = nil }
                    try library.update(changed)
                }
            })).toggleStyle(.checkbox)
            Toggle(String(localized: "启用", table: "AgentRegistry"), isOn: Binding(get: { installation.enabled }, set: { value in
                change { try library.setEnabled(value, installation: installation) }
            })).toggleStyle(.checkbox)
            Menu(String(localized: "固定版本 / 回滚", table: "AgentRegistry")) {
                ForEach(installation.revisions, id: \.self) { revision in
                    Button(((try? library.package(revision: revision, account: installation.account).definition.version) ?? "") + " · " + String(revision.prefix(8))) {
                        request { change { try library.select(revision, installation: installation) } }
                    }
                }
            }
        }.disabled(busy)
        HStack {
            Button(String(localized: "派生副本", table: "AgentRegistry")) {
                change { _ = try library.fork(installation, id: "user/" + UUID().uuidString.lowercased()) }
            }
            if installation.source == .local && allowsRemote {
                Button(String(localized: "加入私有同步", table: "AgentRegistry")) {
                    perform {
                        let client = try authenticatedService(); let token = client.token
                        let epoch = accountEpoch
                        let identity = try await client.identity()
                        guard epoch == accountEpoch, sessionMatches(client) else { throw AgentAssetError.authentication }
                        let account = identity.account(origin: client.origin)
                        try library.recordVerifiedActivation(identity: identity, origin: client.origin, sessionFingerprint: AgentPackageV1.hash(Data(token.utf8)))
                        _ = try library.share(installation, account: account)
                    }
                }
            }
            Button(String(localized: "删除", table: "AgentRegistry")) { change { try library.delete(installation) } }
        }.disabled(busy)
        HStack {
            Picker(String(localized: "本机模型", table: "AgentRegistry"), selection: Binding(
                get: { installation.binding.preferredProviderEntryID },
                set: { id in
                    change {
                        var changed = installation
                        if let id, let entry = providerEntries.first(where: { $0.id == id }) {
                            changed.binding = .init(preferredProviderEntryID: id, preferredProviderID: entry.providerID, model: entry.flashPrimary, contextWindowTokens: nil)
                        } else { changed.binding = .inheritsParent }
                        try library.update(changed)
                    }
                })) {
                    Text(String(localized: "继承当前会话模型", table: "AgentRegistry")).tag(nil as UUID?)
                    ForEach(providerEntries) { entry in Text(entry.displayName + " · " + entry.flashPrimary).tag(Optional(entry.id)) }
                }
            TextField(String(localized: "模型 ID（可选）", table: "AgentRegistry"), text: Binding(
                get: { installation.binding.model ?? "" }, set: { model in
                    change { var changed = installation; changed.binding.model = model.isEmpty ? nil : model; try library.update(changed) }
                })).frame(maxWidth: 240)
        }
        if installation.conflict != nil {
            Text(String(localized: "保留本地需要新的版本号；原来的两份修改仍会保留在历史中。", table: "AgentRegistry"))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(String(localized: "本地和远端修改均已保留", table: "AgentRegistry"))
                TextField(String(localized: "冲突解决的新版本号", table: "AgentRegistry"), text: Binding(
                    get: { conflictVersion ?? (try? library.suggestedConflictVersion(installation)) ?? "" },
                    set: { conflictVersion = $0 })).frame(maxWidth: 160)
                Button(String(localized: "保留本地", table: "AgentRegistry")) {
                    change {
                        let version = try conflictVersion ?? library.suggestedConflictVersion(installation)
                        try library.resolve(installation, keepLocal: true, newVersion: version.trimmingCharacters(in: .whitespacesAndNewlines))
                        conflictVersion = nil
                    }
                }
                Button(String(localized: "保留远端", table: "AgentRegistry")) { change { try library.resolve(installation, keepLocal: false) } }
            }
        }
        if let package = try? library.package(revision: installation.selected, account: installation.account) {
            if let projected = try? AgentDefinitionLibrary.project(package, binding: installation.binding) {
                Text(String(localized: "实际工具由基础职责缩小，再受本次审批限制", table: "AgentRegistry")).font(.caption).foregroundStyle(.secondary)
                Text(projected.capability?.toolNames.sorted().joined(separator: ", ") ?? "")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            } else {
                Text(AgentAssetError.unavailableCapability.localizedDescription).foregroundStyle(.orange)
            }
            if package.definition.skills.contains(where: { !$0.required && $0.content.isEmpty }) {
                Text(String(localized: "可选技能正文为空，运行时将降级", table: "AgentRegistry")).foregroundStyle(.orange)
            }
        }
    }
    private func displayName(_ installation: AgentDefinitionLibrary.Installation) -> String {
        guard let definition = try? library.package(revision: installation.selected, account: installation.account).definition else { return installation.definitionID }
        return definition.name["zh-Hans"] ?? definition.name["en"] ?? installation.definitionID
    }
    private func reload() {
        do {
            installations = try library.visibleInstallations()
            if let selected, let current = installations.first(where: { $0.id == selected.id }) {
                if selected.selected != current.selected { choose(current) } else { self.selected = current }
            }
        } catch { message = error.localizedDescription }
    }
    private func choose(_ installation: AgentDefinitionLibrary.Installation) {
        selected = installation
        conflictVersion = nil
        do {
            draft = String(data: try library.package(revision: installation.selected, account: installation.account).definitionEditorData(), encoding: .utf8) ?? ""
            savedDraft = draft; AgentWorkspaceNavigation.shared.dirtySections.remove(.library)
        }
        catch { message = error.localizedDescription }
    }
    private func create() {
        selected = nil
        savedDraft = ""
        let definition = AgentDefinitionV1(schema: AgentDefinitionV1.schemaID, definition_id: "user/" + UUID().uuidString.lowercased(),
            version: "1.0.0-rc1", name: ["en": "My agent", "zh-Hans": String(localized: "我的智能体", table: "AgentRegistry")],
            purpose: "Review a bounded task and report evidence.", base_role: "reviewer", instructions: "Inspect the task and report actionable findings with evidence.",
            input_modalities: ["text"], tools: ["workspace.read", "repository.inspect"], skills: [], forked_from: nil)
        draft = (try? String(data: AgentPackageV1.unsigned(definition).definitionEditorData(), encoding: .utf8)) ?? ""
    }
    private func saveDraft() {
        change {
            let package = try AgentPackageV1.fromDefinitionData(Data(draft.utf8))
            if let selected, package.definition.definition_id != selected.definitionID { throw AgentAssetError.invalidDefinition }
            var installation = try library.install(package, source: selected?.source ?? .local, account: selected?.account)
            installation.pinned = true
            try library.update(installation)
            selected = installation
            savedDraft = draft
            AgentWorkspaceNavigation.shared.dirtySections.remove(.library)
        }
    }
    private func importPackage() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        change { choose(try library.install(AgentPackageV1.decode(Data(contentsOf: url)), source: .local)) }
    }
    private func exportPackage() {
        guard let selected else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = selected.definitionID.replacingOccurrences(of: "/", with: "-") + ".json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        change { try library.package(revision: selected.selected, account: selected.account).encoded().write(to: url, options: .atomic) }
    }
    private func service() throws -> AgentRegistryService { try AgentRegistryService.controlPlane() }
    private func authenticatedService() throws -> AgentRegistryService {
        let token = SomeIMIntegrationStore.loadSessionToken()
        guard !token.isEmpty else { throw AgentAssetError.authentication }
        return try AgentRegistryService.controlPlane(token: token)
    }
    private func synchronize() {
        perform {
            let client = try authenticatedService()
            let epoch = accountEpoch
            _ = try await AgentRegistrySync(library: library, service: client, sessionStillCurrent: {
                epoch == accountEpoch && sessionMatches(client)
            }).synchronize()
        }
    }
    private func sessionMatches(_ client: AgentRegistryService) -> Bool {
        SomeIMIntegrationStore.loadSessionToken() == client.token
            && (try? service().origin) == client.origin
    }
    private func change(_ action: () throws -> Void) {
        do { try action(); message = ""; reload() } catch { message = error.localizedDescription }
    }
    private func request(_ action: @escaping () -> Void) {
        if draft != savedDraft { pendingAction = action } else { action() }
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true
        let ticket = operationGate.begin(scope: .init(owner: library.activeAccount ?? "local", epoch: accountEpoch))
        Task { @MainActor in
            await operationGate.execute(ticket, current: { .init(owner: library.activeAccount ?? "local", epoch: accountEpoch) }, action: action) { result in
                busy = false
                switch result {
                case .success: message = String(localized: "操作完成", table: "AgentRegistry")
                case .failure(let error): message = error.localizedDescription
                }
                reload()
            }
        }
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; return encoder }
}
