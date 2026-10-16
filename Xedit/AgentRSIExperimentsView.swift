import SwiftUI

struct AgentRSIExperimentsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var baseline: AgentPackageV1?
    private let requestedBaseline: AgentPackageV1?
    private let library: AgentDefinitionLibrary
    private let root: URL?
    private let embedded: Bool
    private let allowsRemote: Bool
    @State private var available: [AgentDefinitionLibrary.Installation] = []
    @State private var experiments: [AgentCanonicalJSON] = []
    @State private var remark = ""
    @State private var savedEditor = ""
    @State private var pendingCandidate: AgentCanonicalJSON?
    private var accountEpoch: UUID { AgentWorkspaceNavigation.shared.accountEpoch }
    @State private var instructions = ""
    @State private var version = ""
    @State private var candidate: AgentCanonicalJSON?
    @State private var result: AgentRSIOfflineResult?
    @State private var message = ""
    @State private var busy = false
    @State private var operationGate = AgentWorkspaceOperationGate()
    @State private var uploadAuthorized = false
    @State private var entries: [AgentCanonicalJSON] = []
    @State private var allCandidates: [AgentCanonicalJSON] = []
    @State private var history: [AgentCanonicalJSON] = []
    private var owner: String { library.activeAccount ?? "local" }
    private var store: AgentRSIStore { root.map { AgentRSIStore(root: $0, owner: owner) } ?? .local(owner: owner) }
    init(baseline: AgentPackageV1?, library: AgentDefinitionLibrary = AgentDefinitionLibrary(), root: URL? = nil,
         embedded: Bool = false, allowsRemote: Bool = true) {
        _baseline = State(initialValue: baseline)
        requestedBaseline = baseline
        self.library = library; self.root = root; self.embedded = embedded; self.allowsRemote = allowsRemote
    }
    var body: some View {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "RSI 实验", table: "AgentWorkspace")).font(.system(size: 28, weight: .bold))
                    Text(String(localized: "改进一份候选，保留当前版本", table: "AgentWorkspace")).foregroundStyle(.secondary)
                }
                Spacer()
                Label(owner == "local" ? String(localized: "本机模式", table: "AgentWorkspace") : String(localized: "some.im · 已连接", table: "AgentWorkspace"), systemImage: "checkmark.circle")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                if !embedded { Button(String(localized: "完成", table: "AgentRegistry")) { dismiss() } }
            }
            steps
            DisclosureGroup {
                Text(String(localized: "候选独立保存，不改变已安装或固定版本。当前仅运行免费离线验收，不能据此判断模型质量提升。", table: "AgentRSI"))
                    .font(.system(size: 14)).foregroundStyle(.secondary)
            } label: {
                Label(String(localized: "免费离线验证", table: "AgentWorkspace"), systemImage: "checkmark.shield.fill")
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(.blue)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 18) {
                    Text(String(localized: "实验备注（仅本机）", table: "AgentWorkspace")).font(.system(size: 15, weight: .semibold))
                    TextField(String(localized: "实验备注（仅本机）", table: "AgentWorkspace"), text: $remark)
                        .textFieldStyle(.roundedBorder).disabled(!AgentWorkspacePresentation.eligible(baseline))
                }
                Text(String(localized: "保存在本机，不参与同步和评分", table: "AgentWorkspace")).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 18) {
                baselineCard
                candidateCard
            }
            if !entries.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(String(localized: "当前账号的候选", table: "AgentRSI")).font(.headline)
                    ForEach(entries, id: \.canonical) { item in
                        HStack {
                            Image(systemName: "doc.badge.gearshape").foregroundStyle(.blue)
                            Text(candidateLabel(item))
                            Spacer()
                            Text(item["candidate_package"]["definition"]["version"].text ?? "").foregroundStyle(.secondary)
                            Button(String(localized: "编辑候选", table: "AgentWorkspace")) { loadCandidate(item) }
                        }.padding(12).background(.white, in: RoundedRectangle(cornerRadius: 9))
                    }
                }
            }
            if let result { resultCard(result) }
            recentExperiments
            if !message.isEmpty { Text(message).font(.system(size: 14)).textSelection(.enabled) }
            if busy { ProgressView().controlSize(.small) }
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
      }.frame(minWidth: 680, minHeight: 540).disabled(busy)
            .onAppear { resetBaseline(); reload() }
            .onChange(of: requestedBaseline?.sha256) { _ in
                guard baseline?.sha256 != requestedBaseline?.sha256 else { return }
                baseline = requestedBaseline; candidate = nil; result = nil; uploadAuthorized = false; pendingCandidate = nil
                resetBaseline(); reload()
            }
            .onChange(of: instructions) { _ in updateDirty() }
            .onChange(of: version) { _ in updateDirty() }
            .onChange(of: remark) { _ in updateDirty() }
            .onReceive(NotificationCenter.default.publisher(for: SomeIMIntegrationStore.sessionDidChangeNotification)) { _ in
                operationGate.invalidate(); busy = false; baseline = nil; candidate = nil; result = nil; instructions = ""; version = ""; remark = ""; uploadAuthorized = false
                entries = []; allCandidates = []; history = []; experiments = []; message = ""; pendingCandidate = nil; savedEditor = editorSnapshot; reload()
            }
            .confirmationDialog(String(localized: "有尚未保存的修改", table: "AgentWorkspace"), isPresented: Binding(
                get: { pendingCandidate != nil }, set: { if !$0 { pendingCandidate = nil } })) {
                    Button(String(localized: "放弃修改并继续", table: "AgentWorkspace"), role: .destructive) {
                        if let pendingCandidate { applyCandidate(pendingCandidate) }; pendingCandidate = nil
                    }
                    Button(String(localized: "继续编辑", table: "AgentWorkspace"), role: .cancel) { pendingCandidate = nil }
                }
    }
    private var steps: some View {
        HStack(spacing: 0) {
            step("1", String(localized: "选择基线", table: "AgentWorkspace"), complete: baseline != nil)
            step("2", String(localized: "编辑候选", table: "AgentWorkspace"), complete: candidate != nil || editorSnapshot != savedEditor)
            step("3", String(localized: "免费验证", table: "AgentWorkspace"), complete: result != nil)
            step("4", String(localized: "查看结果", table: "AgentWorkspace"), complete: result?.complete == true)
        }.padding(.vertical, 6)
    }
    private func step(_ number: String, _ title: String, complete: Bool) -> some View {
        HStack(spacing: 9) {
            Text(number).font(.system(size: 14, weight: .semibold)).frame(width: 28, height: 28)
                .background(complete ? Color.blue : Color.gray.opacity(0.13), in: Circle()).foregroundStyle(complete ? Color.white : Color.secondary)
            Text(title).font(.system(size: 14, weight: .medium))
            Spacer(minLength: 8)
        }
    }
    private var baselineCard: some View {
        AgentWorkspaceCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(String(localized: "当前基线", table: "AgentWorkspace"), systemImage: "doc.text").font(.system(size: 18, weight: .semibold))
                    Spacer()
                    if let baseline { Text(baseline.definition.version).font(.system(size: 13)).foregroundStyle(.secondary) }
                }.frame(height: 30)
                Menu {
                    ForEach(available) { installation in
                        Button(packageName(installation)) {
                            if let package = try? library.package(revision: installation.selected, account: installation.account) {
                                AgentWorkspaceNavigation.shared.select(.experiments, baseline: package)
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text(baseline.map(packageName) ?? String(localized: "选择智能体基线", table: "AgentWorkspace"))
                        Spacer(); Image(systemName: "chevron.down")
                    }.padding(10).background(Color.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                }.menuStyle(.borderlessButton)
                if let baseline {
                    Label(String(localized: "固定版本，实验不会修改", table: "AgentWorkspace"), systemImage: "lock").font(.system(size: 13)).foregroundStyle(.secondary)
                    ScrollView {
                        Text(baseline.definition.instructions).font(.system(size: 14)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading).padding(12)
                    }.frame(height: 205).background(Color.gray.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.gray.opacity(0.12)))
                    DisclosureGroup(String(localized: "版本详情", table: "AgentWorkspace")) {
                        Text(baseline.definition.definition_id + "\n" + baseline.sha256).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                    if !AgentWorkspacePresentation.eligible(baseline) {
                        Text(String(localized: "请先选择用户定义。官方定义须先派生为用户副本再做实验。", table: "AgentRSI")).font(.system(size: 14)).foregroundStyle(.secondary)
                        Button(String(localized: "派生副本", table: "AgentRegistry")) { forkBaseline() }
                    }
                } else {
                    Text(String(localized: "从智能体库选择已有定义，或先创建一份用户副本。", table: "AgentWorkspace")).foregroundStyle(.secondary).frame(minHeight: 175, alignment: .topLeading)
                    Button(String(localized: "前往智能体库", table: "AgentWorkspace")) { AgentWorkspaceNavigation.shared.select(.library) }
                }
            }
        }
    }
    private var candidateCard: some View {
        AgentWorkspaceCard(highlighted: true) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(String(localized: "候选版本", table: "AgentWorkspace"), systemImage: "pencil.and.outline").font(.system(size: 18, weight: .semibold)).foregroundStyle(.blue)
                    Spacer()
                    TextField(String(localized: "候选版本号", table: "AgentRSI"), text: $version).frame(width: 130)
                }.frame(height: 30)
                Text(baseline.map(packageName) ?? String(localized: "选择智能体基线", table: "AgentWorkspace")).font(.system(size: 15, weight: .semibold))
                Text(String(localized: "候选指令", table: "AgentRSI")).font(.system(size: 14, weight: .semibold))
                TextEditor(text: $instructions).font(.system(size: 14)).frame(height: 205)
                    .padding(8).overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.gray.opacity(0.2)))
                if let baseline, AgentWorkspacePresentation.eligible(baseline) {
                    HStack {
                        Button { perform { try save(baseline) } } label: {
                            Label(String(localized: "保存候选", table: "AgentRSI"), systemImage: "square.and.arrow.down")
                        }.buttonStyle(.borderedProminent)
                        Button { perform { try await run(baseline) } } label: {
                            Label(String(localized: "免费验证", table: "AgentWorkspace"), systemImage: "play")
                        }
                    }
                }
                Label(String(localized: "仅保存候选，不替换或自动晋升基线", table: "AgentWorkspace"), systemImage: "arrow.triangle.branch").font(.system(size: 13)).foregroundStyle(.secondary)
            }.textFieldStyle(.roundedBorder).disabled(!AgentWorkspacePresentation.eligible(baseline))
        }
    }
    private func resultCard(_ result: AgentRSIOfflineResult) -> some View {
        AgentWorkspaceCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(result.complete ? String(localized: "离线执行证据完整", table: "AgentRSI") : String(localized: "离线证据不完整，不能通过", table: "AgentRSI"), systemImage: result.complete ? "checkmark.circle" : "exclamationmark.triangle").font(.headline)
                Text(String(result.evidence.count) + " / " + String(result.experiment["dataset"]["tasks"].elements.count * 2 * (result.experiment["repetitions"].integer ?? 0)))
                if let reason = result.haltReason {
                    Text(reason == "budget_exhausted" ? String(localized: "实验预算已用完，已保留中途记录", table: "AgentRSI") : String(localized: "实验中途停止，已保留可核对记录", table: "AgentRSI")).foregroundStyle(.secondary)
                }
                if allowsRemote {
                    Toggle(String(localized: "授权上传此候选定义和执行摘要到当前 some.im 账号；不上传工作区、原始对话或命令输出", table: "AgentRSI"), isOn: $uploadAuthorized)
                    HStack {
                        Button(String(localized: "上传实验与证据", table: "AgentRSI")) { perform { try await upload(result) } }.disabled(!uploadAuthorized)
                        Button(String(localized: "撤销上传授权", table: "AgentRSI")) { perform { try await revoke(result) } }
                    }
                }
                DisclosureGroup(String(localized: "高级：执行证据与哈希", table: "AgentWorkspace")) {
                    Text(result.document.canonical).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }
        }
    }
    private var recentExperiments: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "最近实验", table: "AgentWorkspace")).font(.system(size: 20, weight: .semibold))
            if experiments.isEmpty {
                AgentWorkspaceCard {
                    Label(String(localized: "尚无实验记录，保存候选后可运行首次免费验证。", table: "AgentWorkspace"), systemImage: "flask").foregroundStyle(.secondary)
                }
            }
            ForEach(experiments, id: \.canonical) { experiment in
                DisclosureGroup {
                    Text(experiment["experiment_id"].text ?? "").font(.caption).textSelection(.enabled)
                    ForEach(history.filter { $0["experiment_id"] == experiment["experiment_id"] }, id: \.canonical) { item in
                        Text((item["task_id"].text ?? "") + " · " + armTitle(item["arm"].text) + " · " + evidenceStatusTitle(item["status"].text)).font(.system(size: 13)).textSelection(.enabled)
                    }
                    Text(experiment.canonical).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(experimentLabel(experiment)).font(.system(size: 15, weight: .semibold))
                            Text(String(localized: "离线执行记录，不代表模型质量结论", table: "AgentWorkspace")).font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let date = AgentWorkspacePresentation.latestEvidenceDate(experiment, evidence: history) { Text(date).font(.system(size: 13)).foregroundStyle(.secondary) }
                    }
                }.padding(16).background(.white, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
    private func armTitle(_ arm: String?) -> String {
        arm == "baseline" ? String(localized: "当前基线", table: "AgentWorkspace") : String(localized: "候选版本", table: "AgentWorkspace")
    }
    private func evidenceStatusTitle(_ status: String?) -> String {
        switch status {
        case "passed": String(localized: "通过", table: "AgentWorkspace")
        case "failed": String(localized: "未通过", table: "AgentWorkspace")
        case "interrupted": String(localized: "已中断", table: "AgentWorkspace")
        case "infra_error": String(localized: "执行环境错误", table: "AgentWorkspace")
        case "budget_exhausted": String(localized: "预算用完", table: "AgentWorkspace")
        default: String(localized: "未验证", table: "AgentWorkspace")
        }
    }
    private func save(_ baseline: AgentPackageV1) throws {
        let sameDefinition = candidate?["baseline_package"]["sha256"].text == baseline.sha256
            && candidate?["candidate_package"]["definition"]["instructions"].text == instructions
            && candidate?["candidate_package"]["definition"]["version"].text == version
        let value = try sameDefinition ? candidate! : AgentRSIOfflineRunner.candidate(baseline: baseline, instructions: instructions, version: version)
        try store.save(value, entity: "candidate")
        try AgentRSIPresentationStore(store: store).save(label: remark, candidateID: value["candidate_id"].text ?? "")
        candidate = value; if !sameDefinition { result = nil }; savedEditor = editorSnapshot; updateDirty(); reload()
    }
    private func run(_ baseline: AgentPackageV1) async throws {
        try save(baseline)
        guard let candidate else { throw AgentRSIError.invalidContract }
        let captured = AgentWorkspaceOperationScope(owner: owner, epoch: accountEpoch)
        let capturedStore = store
        let report = try await AgentRSIOfflineRunner.run(candidate: candidate,
            directory: capturedStore.directory.appendingPathComponent("runs/" + UUID().uuidString.lowercased()))
        try captured.validate(owner: owner, epoch: accountEpoch)
        try capturedStore.save(report.experiment, entity: "experiment")
        for item in report.evidence { try capturedStore.save(item, entity: "evidence") }
        result = report; uploadAuthorized = false
        reload()
    }
    private func upload(_ result: AgentRSIOfflineResult) async throws {
        guard allowsRemote, uploadAuthorized else { throw AgentRSIError.revoked }
        let token = SomeIMIntegrationStore.loadSessionToken(), capturedOwner = owner
        let captured = AgentWorkspaceOperationScope(owner: owner, epoch: accountEpoch)
        guard !token.isEmpty, capturedOwner != "local" else { throw AgentAssetError.authentication }
        let registry = try AgentRegistryService.controlPlane(token: token)
        let service = AgentRSIService(registry: registry)
        let identity = try await registry.identity()
        try captured.validate(owner: owner, epoch: accountEpoch)
        guard identity.account(origin: registry.origin) == capturedOwner else { throw AgentRSIError.ownerChanged }
        let check: () throws -> Void = {
            try captured.validate(owner: owner, epoch: accountEpoch)
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
        guard allowsRemote else { throw AgentRSIError.revoked }
        let token = SomeIMIntegrationStore.loadSessionToken(), capturedOwner = owner
        let captured = AgentWorkspaceOperationScope(owner: owner, epoch: accountEpoch)
        guard !token.isEmpty, capturedOwner != "local", let id = result.candidate["grant_id"].text else { throw AgentAssetError.authentication }
        let client = AgentRSIService(registry: try AgentRegistryService.controlPlane(token: token))
        let receipt = try await client.revokeGrant(id)
        try captured.validate(owner: owner, epoch: accountEpoch)
        guard capturedOwner == owner, token == SomeIMIntegrationStore.loadSessionToken() else { throw AgentRSIError.ownerChanged }
        try store.saveReceipt(receipt); uploadAuthorized = false
    }
    private func reload() {
        do {
            available = try library.visibleInstallations().filter { !$0.deleted }
            allCandidates = try store.values(entity: "candidate")
            entries = allCandidates.filter { $0["baseline_package"]["definition"]["definition_id"].text == baseline?.definition.definition_id }
            history = try store.values(entity: "evidence")
            experiments = try store.values(entity: "experiment")
                .sorted { (AgentWorkspacePresentation.latestEvidenceDate($0, evidence: history) ?? "") > (AgentWorkspacePresentation.latestEvidenceDate($1, evidence: history) ?? "") }
        }
        catch { message = error.localizedDescription }
    }
    private var editorSnapshot: String { AgentCanonicalJSON.array([instructions, version, remark].map(AgentCanonicalJSON.string)).canonical }
    private func updateDirty() {
        if AgentWorkspacePresentation.eligible(baseline), editorSnapshot != savedEditor { AgentWorkspaceNavigation.shared.dirtySections.insert(.experiments) }
        else { AgentWorkspaceNavigation.shared.dirtySections.remove(.experiments) }
    }
    private func resetBaseline() {
        if let baseline, (try? library.visibleInstallations().contains { $0.revisions.contains(baseline.sha256) && !$0.deleted }) != true { self.baseline = nil }
        instructions = baseline?.definition.instructions ?? ""
        version = baseline.map { AgentWorkspacePresentation.nextVersion($0.definition.version) } ?? ""
        remark = baseline.map { AgentWorkspacePresentation.defaultRemark(name: packageName($0), version: version) } ?? ""
        savedEditor = editorSnapshot; updateDirty()
    }
    private func packageName(_ package: AgentPackageV1) -> String {
        package.definition.name["zh-Hans"] ?? package.definition.name["en"] ?? package.definition.definition_id
    }
    private func packageName(_ installation: AgentDefinitionLibrary.Installation) -> String {
        (try? library.package(revision: installation.selected, account: installation.account)).map(packageName) ?? installation.definitionID
    }
    private func candidateLabel(_ item: AgentCanonicalJSON) -> String {
        let label = try? AgentRSIPresentationStore(store: store).label(candidateID: item["candidate_id"].text ?? "")
        return label ?? ((item["candidate_package"]["definition"]["name"]["zh-Hans"].text ?? item["candidate_package"]["definition"]["name"]["en"].text ?? "") + " · " + (item["candidate_package"]["definition"]["version"].text ?? ""))
    }
    private func experimentLabel(_ experiment: AgentCanonicalJSON) -> String {
        allCandidates.first { $0["candidate_id"] == experiment["candidate_id"] }.map(candidateLabel) ?? (experiment["definition_id"].text ?? "")
    }
    private func loadCandidate(_ item: AgentCanonicalJSON) {
        if editorSnapshot != savedEditor { pendingCandidate = item } else { applyCandidate(item) }
    }
    private func applyCandidate(_ item: AgentCanonicalJSON) {
        guard let package = try? AgentPackageV1.decode(item["baseline_package"].bytes), AgentWorkspacePresentation.eligible(package) else { return }
        baseline = package; candidate = item; result = nil; uploadAuthorized = false
        instructions = item["candidate_package"]["definition"]["instructions"].text ?? ""
        version = item["candidate_package"]["definition"]["version"].text ?? ""
        remark = candidateLabel(item); savedEditor = editorSnapshot; updateDirty(); reload()
        AgentWorkspaceNavigation.shared.didLoadCandidateBaseline(package)
    }
    private func forkBaseline() {
        do {
            guard let baseline, let installation = available.first(where: { $0.selected == baseline.sha256 }) else { throw AgentAssetError.invalidDefinition }
            let fork = try library.fork(installation, id: "user/" + UUID().uuidString.lowercased())
            let package = try library.package(revision: fork.selected, account: fork.account)
            AgentWorkspaceNavigation.shared.select(.experiments, baseline: package)
        } catch { message = error.localizedDescription }
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true
        let ticket = operationGate.begin(scope: .init(owner: owner, epoch: accountEpoch))
        Task { @MainActor in
            await operationGate.execute(ticket, current: { .init(owner: owner, epoch: accountEpoch) }, action: action) { result in
                busy = false
                switch result {
                case .success: message = String(localized: "操作完成", table: "AgentRegistry")
                case .failure(let error): message = error.localizedDescription
                }
            }
        }
    }
}
