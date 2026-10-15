import SwiftUI

struct AgentRSIExperimentsView: View {
    @Environment(\.dismiss) private var dismiss
    let baseline: AgentPackageV1?
    @State private var instructions = ""
    @State private var version = ""
    @State private var candidate: AgentCanonicalJSON?
    @State private var result: AgentRSIOfflineResult?
    @State private var message = ""
    @State private var busy = false
    @State private var uploadAuthorized = false
    @State private var entries: [AgentCanonicalJSON] = []
    @State private var history: [AgentCanonicalJSON] = []
    private var owner: String { AgentDefinitionLibrary().activeAccount ?? "local" }
    private var store: AgentRSIStore { .local(owner: owner) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(String(localized: "智能体实验", table: "AgentRSI")).font(.title2.bold())
                Spacer(); Button(String(localized: "完成", table: "AgentRegistry")) { dismiss() }
            }
            Text(String(localized: "候选独立保存，不改变已安装或固定版本。当前仅运行免费离线验收，不能据此判断模型质量提升。", table: "AgentRSI"))
                .font(.callout).foregroundStyle(.secondary)
            if let baseline, baseline.signature == nil, baseline.definition.definition_id.hasPrefix("user/") {
                Text(baseline.definition.definition_id + " · " + baseline.sha256).font(.caption).textSelection(.enabled)
                TextField(String(localized: "候选版本号", table: "AgentRSI"), text: $version)
                Text(String(localized: "候选指令", table: "AgentRSI"))
                TextEditor(text: $instructions).font(.system(.body, design: .monospaced)).frame(minHeight: 120)
                HStack {
                    Button(String(localized: "保存候选", table: "AgentRSI")) { perform { try save(baseline) } }
                    Button(String(localized: "运行离线配对验收", table: "AgentRSI")) { perform { try await run(baseline) } }
                }
            } else {
                Text(String(localized: "请先选择用户定义。官方定义须先派生为用户副本再做实验。", table: "AgentRSI"))
            }
            Divider()
            Text(String(localized: "当前账号的候选", table: "AgentRSI")).font(.headline)
            ScrollView {
                VStack(alignment: .leading) {
                    ForEach(entries, id: \.canonical) { item in
                        Button {
                            candidate = item; result = nil
                            instructions = item["candidate_package"]["definition"]["instructions"].text ?? ""
                            version = item["candidate_package"]["definition"]["version"].text ?? ""
                        } label: {
                            Text((item["candidate_package"]["definition"]["version"].text ?? "") + " · " + (item["candidate_package"]["sha256"].text ?? ""))
                                .font(.caption).textSelection(.enabled)
                        }.buttonStyle(.plain)
                    }
                }
            }.frame(maxHeight: 100)
            if !history.isEmpty {
                Text(String(localized: "已保存的实验结果", table: "AgentRSI")).font(.headline)
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(history, id: \.canonical) { item in
                            Text((item["task_id"].text ?? "") + " · " + (item["arm"].text ?? "") + " · " + (item["status"].text ?? "")
                                + " · " + (item["definition_revision"].text ?? "")).font(.caption).textSelection(.enabled)
                        }
                    }
                }.frame(maxHeight: 100)
            }
            if let result {
                Text(result.complete ? String(localized: "离线执行证据完整", table: "AgentRSI") : String(localized: "离线证据不完整，不能通过", table: "AgentRSI"))
                if let reason = result.haltReason {
                    Text(reason == "budget_exhausted" ? String(localized: "实验预算已用完，已保留中途记录", table: "AgentRSI")
                         : String(localized: "实验中途停止，已保留可核对记录", table: "AgentRSI")).font(.caption)
                }
                Text((result.experiment["experiment_id"].text ?? "") + " · " + String(result.evidence.count)).font(.caption)
                Toggle(String(localized: "授权上传此候选定义和执行摘要到当前 some.im 账号；不上传工作区、原始对话或命令输出", table: "AgentRSI"), isOn: $uploadAuthorized)
                Button(String(localized: "上传实验与证据", table: "AgentRSI")) { perform { try await upload(result) } }
                    .disabled(!uploadAuthorized)
                Button(String(localized: "撤销上传授权", table: "AgentRSI")) { perform { try await revoke(result) } }
            }
            if !message.isEmpty { Text(message).font(.caption).textSelection(.enabled) }
            if busy { ProgressView().controlSize(.small) }
        }.padding(20).frame(minWidth: 680, minHeight: 540).disabled(busy)
            .onAppear { instructions = baseline?.definition.instructions ?? ""; reload() }
            .onReceive(NotificationCenter.default.publisher(for: SomeIMIntegrationStore.sessionDidChangeNotification)) { _ in
                candidate = nil; result = nil; instructions = ""; version = ""; uploadAuthorized = false; reload()
            }
    }
    private func save(_ baseline: AgentPackageV1) throws {
        let value = try AgentRSIOfflineRunner.candidate(baseline: baseline, instructions: instructions, version: version)
        try store.save(value, entity: "candidate"); candidate = value; result = nil; reload()
    }
    private func run(_ baseline: AgentPackageV1) async throws {
        if candidate == nil || candidate?["candidate_package"]["definition"]["instructions"].text != instructions
            || candidate?["candidate_package"]["definition"]["version"].text != version { try save(baseline) }
        guard let candidate else { throw AgentRSIError.invalidContract }
        let capturedOwner = owner
        let report = try await AgentRSIOfflineRunner.run(candidate: candidate,
            directory: store.directory.appendingPathComponent("runs/" + UUID().uuidString.lowercased()))
        guard capturedOwner == owner else { throw AgentRSIError.ownerChanged }
        try store.save(report.experiment, entity: "experiment")
        for item in report.evidence { try store.save(item, entity: "evidence") }
        result = report; uploadAuthorized = false
        reload()
    }
    private func upload(_ result: AgentRSIOfflineResult) async throws {
        guard uploadAuthorized else { throw AgentRSIError.revoked }
        let token = SomeIMIntegrationStore.loadSessionToken(), capturedOwner = owner
        guard !token.isEmpty, capturedOwner != "local" else { throw AgentAssetError.authentication }
        let registry = try AgentRegistryService.controlPlane(token: token)
        let service = AgentRSIService(registry: registry)
        let identity = try await registry.identity()
        guard identity.account(origin: registry.origin) == capturedOwner else { throw AgentRSIError.ownerChanged }
        let check: () throws -> Void = {
            guard token == SomeIMIntegrationStore.loadSessionToken(), capturedOwner == owner, uploadAuthorized else { throw AgentRSIError.ownerChanged }
        }
        let existing = try store.values(entity: "grant").first { $0["grant_id"] == result.candidate["grant_id"] }
        let expires = ISO8601DateFormatter().string(from: Date().addingTimeInterval(7 * 24 * 3600))
        let grant = existing ?? AgentCanonicalJSON.object(["schema": .string("willdeep.agent-rsi.grant.v1"), "grant_id": result.candidate["grant_id"],
            "purpose": .string("private_evaluation"), "material_scope": .array([.string("execution_summary")]), "expires_at": .string(expires)])
        try store.save(grant, entity: "grant")
        try check(); let grantReceipt = try await service.create(grant, entity: "grant")
        try check(); try store.saveReceipt(grantReceipt)
        try check(); _ = try await service.create(result.candidate, entity: "candidate")
        try check(); _ = try await service.create(result.experiment, entity: "experiment")
        let id = result.experiment["experiment_id"].text!
        for admission in result.admissions {
            try check(); _ = try await service.create(admission, entity: "admission", experimentID: id)
            for evidence in result.evidence where evidence["trial_id"] == admission["trial_id"] {
                try check(); let receipt = try await service.create(evidence, entity: "evidence", experimentID: id)
                try check(); try store.save(receipt.document, entity: "evidence") // retain server trust downgrade alongside local original
                try store.saveReceipt(receipt)
            }
        }
        try check(); uploadAuthorized = false
    }
    private func revoke(_ result: AgentRSIOfflineResult) async throws {
        let token = SomeIMIntegrationStore.loadSessionToken(), capturedOwner = owner
        guard !token.isEmpty, capturedOwner != "local", let id = result.candidate["grant_id"].text else { throw AgentAssetError.authentication }
        let client = AgentRSIService(registry: try AgentRegistryService.controlPlane(token: token))
        let receipt = try await client.revokeGrant(id)
        guard capturedOwner == owner, token == SomeIMIntegrationStore.loadSessionToken() else { throw AgentRSIError.ownerChanged }
        try store.saveReceipt(receipt); uploadAuthorized = false
    }
    private func reload() {
        do {
            entries = try store.values(entity: "candidate").filter { $0["baseline_package"]["definition"]["definition_id"].text == baseline?.definition.definition_id }
            history = try store.values(entity: "evidence").filter { $0["definition_id"].text == baseline?.definition.definition_id }
        }
        catch { message = error.localizedDescription }
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do { try await action(); message = String(localized: "操作完成", table: "AgentRegistry") }
            catch { message = error.localizedDescription }
        }
    }
}
