//
//  AgentGlobalRulesStore.swift
//  WillDeep
//
//  Stores the user-level Agent rules file preference and reads its content.
//

import Foundation

struct AgentGlobalRulesSettings: Codable, Equatable {
    var isEnabled: Bool
    var filePath: String

    static let defaultFilePath = "~/.willdeep/CLAUDE.md"
    static let `default` = AgentGlobalRulesSettings(
        isEnabled: true,
        filePath: defaultFilePath
    )

    var normalized: AgentGlobalRulesSettings {
        var copy = self
        copy.filePath = copy.filePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.filePath.isEmpty {
            copy.filePath = Self.defaultFilePath
        }
        return copy
    }
}

enum AgentGlobalRulesStore {
    private static let settingsKey = "com.willdeep.agentGlobalRules.settings.v1"
    static let maxRulesCharacters = 8_000
    static let defaultRulesTemplate = """
    # Codex 规则（严格条款）

    本文件用于约束 Codex 在本仓库中的行为与输出风格。条款分级如下：
    - **MUST**：必须遵守
    - **MUST NOT**：严禁
    - **SHOULD**：应当遵守（如无充分理由不得偏离）

    ---

    ## 1) 语言与表达

    - **MUST**：所有对用户的回复一律使用**简体中文**。
    - **SHOULD**：语言可适度玩梗；可偶尔用“郭德纲式幽默/鲁迅式语气”增色。
    - **MUST NOT**：在**关键信息**（需求结论、操作步骤、风险提示、版本号、代码关键约束）上玩梗或含糊其辞。

    ---

    ## 2) 前端技术栈与国际化

    - **MUST**：在 Vue 与 React 之间做选择时，优先使用 **React**。
    - **MUST**：React 部分**禁止硬编码**（包括但不限于：UI 文案、枚举展示文案、提示语、按钮文本、错误信息等）。
    - **MUST**：React 相关实现必须考虑**国际化（i18n）**：
      - 文案必须走 i18n 字典/资源文件；
      - 对外可见文本不得直接写死在 JSX/TSX 中（除非是纯占位符且会被立即替换为 i18n）。

    ---

    ## 3) 包管理与工程工具偏好

    - **MUST**：在 yarn / npm / pnpm 之间，优先使用 **yarn**（包括安装依赖、脚本执行等）。

    ---

    ## 4) 文件生成与编辑方式

    - **SHOULD**：默认避免使用管道、`cat`、`echo` 重定向、heredoc 等方式生成/覆写文件内容；优先使用“编辑/写文件”能力、应用补丁或明确的文件传输路径。
    - **MUST**：创建/更新文件必须确保变更可审计、可回滚、可 review；当远程环境无法安装/使用传输工具时，可以使用小而清晰的 heredoc、patch、sed/perl 等兜底编辑方式，并在完成后验证结果。

    ---

    ## 5) 版本号（语义化 + 前后端一致）

    - **MUST**：版本号采用语义化格式，允许预发布标识，例如：`1.2.3-rc2`。
    - **MUST**：每次**修改代码**后，必须同步更新版本号。
    - **MUST**：如果是**功能新增**，才允许提升正式版本（例如变更 `1.2.3` 的主/次/补位；具体增幅按仓库既定规则）。
    - **MUST**：如果是 **bugfix**，只允许递增 `rc` 号（例如 `-rc2` → `-rc3`），不得在 bugfix 中提升正式版本位。
    - **MUST**：前端与后端版本号必须保持一致。
    - **SHOULD**：前端界面底部/关于页尽量展示当前版本号（与后端一致）。
    - **SHOULD**：当用户要求 git 提交时，需要打一个 v{版本号} 这样的 tag（就是版本号前面加一个 v），并和代码一起推送到 GitHub（如果远程是 GitHub 的话）。

    ---

    ## 6) 服务端 API 版本可观测性

    - **MUST**：服务端 API 必须通过响应 header（或等价机制）暴露版本号，用于排查（例如 `X-App-Version` / `X-Server-Version` 等；具体名称以项目现有约定为准）。
    - **MUST**：该版本号必须与当前仓库版本号一致。

    ---

    ## 7) Changelog 规则

    - **MUST**：如果仓库存在 `CHANGELOG.md`（或同类变更记录文件），每次版本号变更时必须同步记录本次变更要点。没有的话应该确保有一个。
    - **SHOULD**：最好应该有一个 `product-overview.md` 文件（或类似文件），记录当前设计思路、主要功能、待完成问题等；每一次版本变更或功能变更时保持及时更新。

    ---

    ## 8) 安全与敏感信息

    - **MUST NOT**：在对用户输出、日志、示例代码、提交信息中泄露任何密钥/Token/凭据/个人隐私数据。
    - **MUST NOT**：提交包含敏感信息的文件或改动（如 `.env`、密钥、访问令牌等）。
    - **SHOULD**：一旦发现疑似敏感信息，优先采取**删除/替换/脱敏**策略，并在变更说明中提示风险与处理结果。
    - **SHOULD**：保密类的 key/secret、web hook 地址要放在 `.env` 或类似功能的文件中，并且注明不上传到 git 中。

    ---

    ## 9) 测试与自动化测试

    - **SHOULD**：使用最流行的自动化测试工具。
    - **SHOULD**：如果可以，用 Ruby 写自动化测试脚本，并输出 JSON 和 Markdown 两种格式的报告；尽量不要用 Python。

    ---

    ## 10) 文件控制

    - **SHOULD**：单个文件不可以超过 3000 行，如果超过 2000 行就要考虑分拆，超过 3000 行必须分拆。

    ---

    <!-- BEGIN ALMA AGENTRULES SYNC -->

    ## Alma 规则库摘要

    以下规则适用于 Codex 全局会话。若与当前项目的 AGENTS.md / CLAUDE.md 或用户最新指令冲突，以更具体、更晚出现的指令为准。

    ### 编程最佳实践

    - **一致性 > 个人偏好**：一个项目一种风格，用 linter 强制。
    - **命名即文档**：变量/函数名应该自解释。
    - **函数要短**：超过 30 行的函数就该拆，一个函数只做一件事。
    - **魔法数字死刑**：所有硬编码数字/字符串抽成常量，给个有意义的名字。
    - **提前 return**：减少嵌套层级。
    - **不要吞异常**：至少记录上下文。
    - **错误信息要有上下文**：说明哪个系统、什么操作、什么原因失败。
    - **写测试**：核心逻辑必须有单测，测试数据要隔离。
    - **安全优先**：不要信任用户输入，SQL 用参数化查询，密钥不进代码。
    - **结构化日志**：不要记录敏感信息。

    ### 前端最佳实践

    - TypeScript 优先，strict 模式全开。
    - React 新代码使用函数组件和 Hooks。
    - 服务端状态优先使用 React Query / SWR 类工具。
    - CSS 优先使用项目既有体系；响应式 mobile-first。
    - 测试优先 Vitest / Testing Library / Playwright。
    - 前端可见文本必须走 i18n。

    ### Go 最佳实践

    - 标准布局优先：`cmd/`、`internal/`、`pkg/`、`api/`。
    - `main.go` 要瘦，逻辑放到 `internal/`。
    - error 永远最后，wrap error 保留上下文。
    - goroutine 生命周期要可控，用 context 取消。
    - 表驱动测试是 Go 标配。

    ### 数据库最佳实践

    - 所有 DDL 变更走迁移文件，up/down 成对。
    - 每张业务表应有 `created_at` / `updated_at`。
    - SQL 明确列名，不用 `SELECT *`。
    - 参数化查询永远第一位。
    - 大表迁移先评估锁表风险和回滚预案。

    ### Linux / 运维最佳实践

    - 禁用 root SSH 登录，密钥认证，最小开放防火墙。
    - CPU、内存、磁盘和服务健康检查必须可观测。
    - 备份遵循 3-2-1 原则，并定期恢复演练。
    - 关键脚本必须幂等，Cron 任务要有监控。

    <!-- END ALMA AGENTRULES SYNC -->
    """

    static func loadSettings() -> AgentGlobalRulesSettings {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(AgentGlobalRulesSettings.self, from: data) else {
            return .default
        }
        return settings.normalized
    }

    static func saveSettings(_ settings: AgentGlobalRulesSettings) {
        guard let data = try? JSONEncoder().encode(settings.normalized) else { return }
        UserDefaults.standard.set(data, forKey: settingsKey)
    }

    static func resolvedURL(for filePath: String) -> URL {
        let normalized = filePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = normalized.isEmpty ? AgentGlobalRulesSettings.defaultFilePath : normalized
        let expanded: String
        if path == "~" {
            expanded = FileManager.default.homeDirectoryForCurrentUser.path
        } else if path.hasPrefix("~/") {
            expanded = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(path.dropFirst(2)))
                .path
        } else {
            expanded = (path as NSString).expandingTildeInPath
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    static func displayPath(for url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~/" + String(path.dropFirst(home.count + 1))
        }
        return path
    }

    static func loadRules(settings: AgentGlobalRulesSettings = loadSettings()) -> String? {
        let settings = settings.normalized
        guard settings.isEnabled else { return nil }
        ensureDefaultRulesFileIfNeeded(settings: settings)
        return readRules(at: resolvedURL(for: settings.filePath))
    }

    static func readRules(at url: URL) -> String? {
        guard let trimmed = readRulesFileText(at: url)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return limit(trimmed, to: maxRulesCharacters)
    }

    static func readRulesFileText(at url: URL) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }

    static func saveRules(_ text: String, settings: AgentGlobalRulesSettings = loadSettings()) throws {
        let url = resolvedURL(for: settings.normalized.filePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func ensureDefaultRulesFileIfNeeded(settings: AgentGlobalRulesSettings = loadSettings()) {
        let settings = settings.normalized
        let url = resolvedURL(for: settings.filePath)
        guard shouldSeedDefaultRulesFile(settings: settings, fileExists: FileManager.default.fileExists(atPath: url.path)) else {
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try defaultRulesTemplate.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            // Best effort only: failing to seed the editable defaults should
            // not prevent the Agent from running or Settings from opening.
        }
    }

    static func shouldSeedDefaultRulesFile(settings: AgentGlobalRulesSettings, fileExists: Bool) -> Bool {
        settings.normalized.filePath == AgentGlobalRulesSettings.defaultFilePath && !fileExists
    }

    private static func limit(_ text: String, to maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        let index = text.index(text.startIndex, offsetBy: maxCharacters)
        return "\(text[..<index])\n\n[truncated]"
    }
}
