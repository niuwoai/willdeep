import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Exchange definitions are edited separately from legacy model overrides.
struct AgentRegistrySettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @State private var installations: [AgentDefinitionLibrary.Installation] = []
    @State private var catalog: [AgentRegistryIndex.Item] = []
    @State private var selected: AgentDefinitionLibrary.Installation?
    @State private var draft = ""
    @State private var message = ""
    @State private var busy = false
    @State private var advancedEditor = false
    private let library: AgentDefinitionLibrary

    init(library: AgentDefinitionLibrary = AgentDefinitionLibrary(), initialSelection: AgentDefinitionLibrary.Installation? = nil) {
        self.library = library
        _selected = State(initialValue: initialSelection)
        let data = initialSelection.flatMap { try? library.package(revision: $0.selected, account: $0.account).definitionEditorData() }
        _draft = State(initialValue: data.map { String(decoding: $0, as: UTF8.self) } ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(String(localized: "智能体版本库", table: "AgentRegistry")).font(.title2.bold())
                Spacer()
                Button(String(localized: "完成", table: "AgentRegistry")) { dismiss() }
            }
            Text(String(localized: "原生子智能体使用固定版本。定义与模型绑定分开；外部 CLI 不应用这些指令。", table: "AgentRegistry"))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(String(localized: "创建", table: "AgentRegistry"), action: create)
                Button(String(localized: "导入", table: "AgentRegistry"), action: importPackage)
                Button(String(localized: "刷新官方目录", table: "AgentRegistry")) { perform { catalog = try await service().index().items } }
                Button(String(localized: "同步私有智能体", table: "AgentRegistry")) { synchronize() }
            }.disabled(busy)
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(installations) { installation in
                            Button { choose(installation) } label: {
                                VStack(alignment: .leading) {
                                    Text(displayName(installation)).font(.headline)
                                    Text(installation.definitionID).font(.caption).foregroundStyle(.secondary)
                                    Text(installation.source.rawValue + " · " + String(installation.selected.prefix(12)))
                                        .font(.caption).foregroundStyle(.secondary)
                                    if installation.conflict != nil { Text(String(localized: "同步冲突", table: "AgentRegistry")).foregroundStyle(.orange) }
                                    if installation.deleted { Text(String(localized: "已删除", table: "AgentRegistry")).foregroundStyle(.secondary) }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                            }.buttonStyle(.plain)
                        }
                        Divider()
                        ForEach(catalog) { item in
                            VStack(alignment: .leading) {
                                Text(item.name["zh-Hans"] ?? item.name["en"] ?? item.definition_id)
                                Text(item.version + " · " + item.purpose).font(.caption)
                                Button(String(localized: "安装固定版本", table: "AgentRegistry")) {
                                    perform {
                                        let (package, keys) = try await service().official(item)
                                        _ = try library.install(package, source: .official, keys: keys, dirty: false)
                                    }
                                }.disabled(busy)
                            }
                        }
                    }.padding(8)
                }.frame(minWidth: 220, idealWidth: 260, maxWidth: 340)
                VStack(alignment: .leading, spacing: 8) {
                    if let selected { controls(selected) }
                    Toggle(String(localized: "高级 JSON 与技能正文", table: "AgentRegistry"), isOn: $advancedEditor).toggleStyle(.checkbox)
                    if advancedEditor {
                        Text(String(localized: "定义 JSON：修改指令、职责、工具或技能时增加 version，保存后形成新的不可变版本。", table: "AgentRegistry"))
                            .font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $draft).font(.system(.body, design: .monospaced))
                            .disabled(selected?.source == .official)
                    } else if !draft.isEmpty {
                        definitionForm.disabled(selected?.source == .official)
                    } else {
                        Text(String(localized: "创建智能体或选择一个已有版本", table: "AgentRegistry")).foregroundStyle(.secondary)
                        Spacer()
                    }
                    HStack {
                        Button(String(localized: "保存并固定版本", table: "AgentRegistry"), action: saveDraft)
                            .disabled(busy || selected?.source == .official || draft.isEmpty)
                        Button(String(localized: "导出版本包", table: "AgentRegistry"), action: exportPackage).disabled(selected == nil)
                    }
                }.padding(8).frame(minWidth: 400)
            }
            if !message.isEmpty { Text(message).font(.caption).textSelection(.enabled) }
            if busy { ProgressView().controlSize(.small) }
        }.padding(18).frame(minWidth: 850, minHeight: 600)
            .onAppear(perform: reload)
            .onReceive(NotificationCenter.default.publisher(for: SomeIMIntegrationStore.sessionDidChangeNotification)) { _ in
                selected = nil; draft = ""; reload()
            }
    }
    private var definitionForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(String(localized: "智能体标识", table: "AgentRegistry"), text: definitionBinding(\.definition_id))
                .disabled(selected != nil)
            TextField(String(localized: "名称", table: "AgentRegistry"), text: Binding(
                get: { decodedDraft?.name["zh-Hans"] ?? decodedDraft?.name["en"] ?? "" },
                set: { value in editDefinition { $0.name["zh-Hans"] = value } }))
            TextField(String(localized: "版本号", table: "AgentRegistry"), text: definitionBinding(\.version))
            TextField(String(localized: "适用任务", table: "AgentRegistry"), text: definitionBinding(\.purpose))
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
                    Button(revision.prefix(12).description) { change { try library.select(revision, installation: installation) } }
                }
            }
        }.disabled(busy)
        HStack {
            Button(String(localized: "派生副本", table: "AgentRegistry")) {
                change { _ = try library.fork(installation, id: "user/" + UUID().uuidString.lowercased()) }
            }
            if installation.source == .local {
                Button(String(localized: "加入私有同步", table: "AgentRegistry")) {
                    perform {
                        let client = try authenticatedService(); let token = client.token
                        let identity = try await client.identity()
                        guard sessionMatches(client) else { throw AgentAssetError.authentication }
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
                        if let id, let entry = appState.agentProviderLibrary.entries.first(where: { $0.id == id }) {
                            changed.binding = .init(preferredProviderEntryID: id, preferredProviderID: entry.providerID, model: entry.flashPrimary, contextWindowTokens: nil)
                        } else { changed.binding = .inheritsParent }
                        try library.update(changed)
                    }
                })) {
                    Text(String(localized: "继承当前会话模型", table: "AgentRegistry")).tag(nil as UUID?)
                    ForEach(appState.agentProviderLibrary.entries) { entry in Text(entry.displayName + " · " + entry.flashPrimary).tag(Optional(entry.id)) }
                }
            TextField(String(localized: "模型 ID（可选）", table: "AgentRegistry"), text: Binding(
                get: { installation.binding.model ?? "" }, set: { model in
                    change { var changed = installation; changed.binding.model = model.isEmpty ? nil : model; try library.update(changed) }
                })).frame(maxWidth: 240)
        }
        if installation.conflict != nil {
            HStack {
                Text(String(localized: "本地和远端修改均已保留", table: "AgentRegistry"))
                Button(String(localized: "保留本地", table: "AgentRegistry")) { change { try library.resolve(installation, keepLocal: true) } }
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
            if let selected, let current = installations.first(where: { $0.id == selected.id }) { self.selected = current }
        } catch { message = error.localizedDescription }
    }
    private func choose(_ installation: AgentDefinitionLibrary.Installation) {
        selected = installation
        do { draft = String(data: try library.package(revision: installation.selected, account: installation.account).definitionEditorData(), encoding: .utf8) ?? "" }
        catch { message = error.localizedDescription }
    }
    private func create() {
        selected = nil
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
        }
    }
    private func importPackage() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        change { selected = try library.install(AgentPackageV1.decode(Data(contentsOf: url)), source: .local) }
    }
    private func exportPackage() {
        guard let selected else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = selected.definitionID.replacingOccurrences(of: "/", with: "-") + ".json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        change { try library.package(revision: selected.selected, account: selected.account).encoded().write(to: url, options: .atomic) }
    }
    private func service() throws -> AgentRegistryService { try AgentRegistryService(baseURL: SomeIMIntegrationStore.loadSettings().baseURL) }
    private func authenticatedService() throws -> AgentRegistryService {
        let token = SomeIMIntegrationStore.loadSessionToken()
        guard !token.isEmpty else { throw AgentAssetError.authentication }
        return try AgentRegistryService(baseURL: SomeIMIntegrationStore.loadSettings().baseURL, token: token)
    }
    private func synchronize() {
        perform {
            let client = try authenticatedService()
            _ = try await AgentRegistrySync(library: library, service: client, sessionStillCurrent: {
                sessionMatches(client)
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
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true
        Task { @MainActor in
            defer { busy = false; reload() }
            do { try await action(); message = String(localized: "操作完成", table: "AgentRegistry") }
            catch { message = error.localizedDescription }
        }
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; return encoder }
}
