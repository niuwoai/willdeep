//
//  AgentToolDisplayNames.swift
//  WillDeep
//
//  Tool-id → display-name mapping for transcript cards. Split out of
//  AgentToolCallViews.swift, which had grown past the repository's hard
//  file-size limit.
//

import SwiftUI
import AppKit

/// 工具卡片的本地化展示助手。模型给的工具 id 是英文 snake_case
/// （`terminal_send_command` / `ask_user` …），直接糊在卡片上对中文
/// 用户不友好。这里集中维护「工具 id → 中文名」与控制键别名的友好
/// 展示。与 transcript 视图里 `已读取 N 个文件` 等中文活动文案保持
/// 同一约定（Agent transcript 视图统一硬编码中文，不走 L10n 目录）。
nonisolated enum AgentToolDisplay {
    /// 工具 id → 中文展示名。未收录的工具回退到原始 id，绝不丢信息。
    static func name(for toolName: String) -> String {
        toolNames[toolName] ?? toolName
    }

    /// 带括号原始 id 的展示名，例如「终端执行命令 (terminal_send_command)」，
    /// 既给中文用户读得懂的名字，也保留可检索的原始 id 供排查。
    static func nameWithRawID(for toolName: String) -> String {
        guard let localized = toolNames[toolName] else { return toolName }
        return "\(localized)（\(toolName)）"
    }

    /// `terminal_send_control` 的 control 取值。
    /// 直接显示原始别名既不直观也容易被误会，这里展开成「人话 + 作用」。
    static func controlLabel(for raw: String) -> String {
        switch raw {
        case "ctrl_c": return "Ctrl-C（中断当前命令 / SIGINT）"
        case "ctrl_d": return "Ctrl-D（发送 EOF）"
        case "ctrl_right_bracket": return "Ctrl-]（打开 telnet 退出提示符）"
        case "enter": return "Enter（回车提交当前行）"
        case "escape": return "Esc（取消 / 退出终端 UI 模式）"
        default: return raw
        }
    }

    /// 工具作用的**宾语**：读的哪个文件、grep 的什么模式、跑的哪条命令。
    ///
    /// 只有动词的标签（派工卡上一列三个「运行命令」）只能告诉人「它在忙」。
    /// 而那张卡存在的意义是让人判断要不要打断，判断依据恰恰是宾语。返回值
    /// 已做密钥脱敏与长度收敛，可以直接进 UI。拿不到有意义的宾语时返回 nil，
    /// 由调用方决定退化成只有动词的样子——绝不编一个出来。
    static func objectSummary(
        toolName: String,
        arguments: [String: AgentJSONValue]
    ) -> String? {
        func string(_ key: String) -> String? { arguments[key]?.stringValue() }
        switch toolName {
        case "read_file", "list_directory", "edit_file", "create_file", "write_file", "apply_patch":
            return objectFileName(string("path"))
        case AgentBundledRules.readerToolName:
            return objectFileName(string("file"))
        case "grep_files":
            return objectCondensed(string("pattern")) ?? objectFileName(string("path"))
        case "search_files":
            return objectCondensed(string("query")) ?? objectFileName(string("path"))
        case "run_command":
            return objectCondensed(string("label")) ?? objectCondensed(string("command"))
        case "terminal_send_command":
            return objectCondensed(string("command"))
        case "terminal_send_control":
            return string("control").map(controlLabel(for:)).flatMap(objectCondensed)
        case "web_fetch":
            guard let raw = string("url") else { return nil }
            return URL(string: raw)?.host ?? objectCondensed(raw)
        case "web_search":
            return objectCondensed(string("query"))
        case "spawn_agent":
            return objectCondensed(string("label")) ?? objectCondensed(string("trade"))
        case "call_mcp_tool":
            return objectCondensed(string("tool"))
        case "show_widget":
            return objectCondensed(string("title"))
        default:
            return nil
        }
    }

    /// 同上，参数还是 provider 回来的原始 JSON 字符串时用这个。子代理运行器
    /// 手里的 `AgentMessageToolCall` 只有 `argumentsJSON`，没有解析好的字典。
    static func objectSummary(toolName: String, argumentsJSON: String) -> String? {
        guard !argumentsJSON.isEmpty,
              case .object(let arguments) = AgentJSONValue.decode(from: argumentsJSON) else {
            return nil
        }
        return objectSummary(toolName: toolName, arguments: arguments)
    }

    /// 路径取末段：派工卡的一行放不下绝对路径，而人认的是文件名。
    private static func objectFileName(_ path: String?) -> String? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let name = URL(fileURLWithPath: trimmed).lastPathComponent
        return name.isEmpty ? objectCondensed(trimmed) : objectCondensed(name)
    }

    /// 压成单行、把 `${secret:…}` 引用换成 `[secret]`、超长截断。与失败命令
    /// 详情卡同一套口径：占位符指向哪一条凭据不该印在聊天区里。
    private static func objectCondensed(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = AgentSecretStore.redactPlaceholders(in: value)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        guard normalized.count > objectSummaryCharacterLimit else { return normalized }
        return String(normalized.prefix(objectSummaryCharacterLimit)) + "…"
    }

    /// 标签是横向流排的，宾语再长也不能把一行撑爆。
    static let objectSummaryCharacterLimit = 34

    /// 审批卡只展示用户真正需要核对的工具参数。以下划线开头的字段由
    /// 宿主写入，供沙箱判定和审计使用；把它们原样展示会泄露实现细节，
    /// 还会让英文安全原因挤掉文件路径、写入内容等关键信息。
    static func approvalArgumentsLines(
        for arguments: [String: AgentJSONValue]
    ) -> String {
        approvalArguments(for: arguments)
            .map { "\($0.label)：\(approvalValueSummary($0.value))" }
            .joined(separator: "\n")
    }

    /// 审批卡与审批解释共用的参数顺序和中文名。卡片要摘要，解释模型要
    /// 原文——两边只在「值怎么写」上分叉，筛选和排序必须是同一份。
    static func approvalArguments(
        for arguments: [String: AgentJSONValue]
    ) -> [(label: String, value: AgentJSONValue)] {
        arguments
            .filter { !$0.key.hasPrefix("_") }
            .sorted {
                let left = argumentOrder[$0.key] ?? Int.max
                let right = argumentOrder[$1.key] ?? Int.max
                return left == right ? $0.key < $1.key : left < right
            }
            .map { (label: argumentName(for: $0.key), value: $0.value) }
    }

    private static func argumentName(for key: String) -> String {
        argumentNames[key] ?? key
    }

    static func approvalValueSummary(_ value: AgentJSONValue) -> String {
        switch value {
        case .bool(let enabled): return enabled ? "是" : "否"
        case .null: return "空"
        default: return value.displaySummary
        }
    }

    private static let argumentNames: [String: String] = [
        "command": "执行命令",
        "content": "写入内容",
        "control": "控制键",
        "cwd": "工作目录",
        "download_directory": "下载目录",
        "file_path": "文件路径",
        "max_chars": "最大读取字符数",
        "overwrite": "覆盖已有文件",
        "path": "文件路径",
        "paths": "文件路径",
        "query": "查询内容",
        "text": "文本内容",
        "title": "标题",
        "url": "访问地址",
        "zmodem_download_directory": "ZMODEM 下载目录",
        "zmodem_upload_paths": "ZMODEM 上传文件",
    ]

    private static let argumentOrder: [String: Int] = [
        "path": 0,
        "file_path": 0,
        "cwd": 1,
        "url": 1,
        "command": 2,
        "overwrite": 3,
        "content": 4,
    ]

    static let toolNames: [String: String] = [
        "search_files": "搜索文件",
        "grep_files": "正则搜索",
        "glob": "通配查找",
        "read_file": "读取文件",
        AgentBundledRules.readerToolName: L10n.AgentTools.readBundledRule,
        "list_directory": "浏览目录",
        "git_status": "查看 Git 状态",
        "rename_session": "重命名会话",
        "list_projects": "列出项目",
        "send_session_message": "给其他会话发消息",
        "list_project_sessions": "列出项目会话",
        "manage_sessions": "批量管理会话",
        "change_workspace": "更改 Workspace",
        "run_command": "运行命令",
        "terminal_snapshot": "终端快照",
        "terminal_create_shortcut": "生成终端捷径",
        "terminal_list_shortcuts": "终端捷径列表",
        "terminal_edit_shortcut": "编辑终端捷径",
        "terminal_send_command": "终端执行命令",
        "terminal_send_control": "终端控制键",
        "terminal_list_tabs": "终端标签列表",
        "terminal_select_tab": "切换终端标签",
        "create_file": "创建文件",
        "write_file": "写入外部文件",
        "edit_file": "编辑文件",
        "apply_patch": "应用补丁",
        "list_jobs": "查看后台任务",
        "get_job_output": "读取任务输出",
        "kill_job": "终止后台任务",
        "monitor": "盯住命令输出",
        "send_agent_message": "给子代理发消息",
        "stop_agent": "停止子代理",
        "list_skills": "查看技能",
        "read_skill": "读取技能",
        "activate_expert": "激活技能包",
        "update_plan": "更新计划进度",
        "add_memory": "记忆要点",
        "create_user_skill": "新建技能",
        "create_user_skills": "批量新建技能",
        "update_user_skill": "更新技能",
        "delete_user_skill": "删除技能",
        "search_mcp_servers": "搜索 MCP 服务",
        "suggest_mcp_server": "推荐 MCP 服务",
        "configure_mcp_server": "配置 MCP 服务",
        "web_search": "联网搜索",
        "web_fetch": "抓取网页",
        "generate_image": "生成图片",
        "design_to_code_acceptance": "界面视觉验收",
        "visual_qa_screenshot": "截图视觉检查",
        "capture_screenshot": "截屏",
        "computer_use_permissions": "电脑操作权限",
        "computer_use_request_permissions": "请求电脑操作权限",
        "computer_use_list_apps": "列出 Mac 应用",
        "computer_use_launch_app": "后台启动 Mac 应用",
        "computer_use_activate_app": "切到 Mac 应用",
        "computer_use_get_app_state": "读取应用界面",
        "computer_use_inspect_app": "检查应用控件",
        "computer_use_wait_for": "等待应用状态",
        "computer_use_click": "点击应用控件",
        "computer_use_secondary_action": "打开应用菜单",
        "computer_use_scroll": "滚动应用界面",
        "computer_use_drag": "拖拽应用界面",
        "computer_use_type_text": "输入应用文本",
        "computer_use_press_key": "发送应用按键",
        "computer_use_set_value": "设置应用控件值",
        "computer_use_focus": "聚焦应用控件",
        "computer_use_hover": "悬停应用控件",
        "computer_use_select_text": "选择应用文本",
        "computer_use_restart_helper": "重启电脑操作 Helper",
        "chrome_status": "Chrome 状态",
        "chrome_read_page": "读取网页",
        "chrome_read_selection": "读取网页选区",
        "chrome_snapshot": "读取网页控件",
        "chrome_list_tabs": "列出 Chrome 标签页",
        "chrome_activate_tab": "切换 Chrome 标签页",
        "chrome_navigate": "打开网页",
        "chrome_history": "浏览器前进后退",
        "chrome_click": "点击页面元素",
        "chrome_type": "输入网页文本",
        "chrome_hover": "悬停网页元素",
        "chrome_select_option": "选择网页选项",
        "chrome_press_key": "发送网页按键",
        "chrome_scroll": "滚动网页",
        "chrome_wait_for": "等待网页状态",
        "chrome_capture_tab": "截取标签页",
        "chrome_debugger_command": "Chrome 调试命令",
        "list_mcp_servers": "MCP 服务列表",
        "list_mcp_tools": "MCP 工具列表",
        "call_mcp_tool": "调用 MCP 工具",
        "lark_cli": "飞书 CLI",
        "claude_code": "Claude Code",
        "codex_cli": "Codex CLI",
        "hermes_cli": "Hermes",
        "cursor_agent": "Cursor Agent",
        "cline_cli": "Cline CLI",
        "opencode_cli": "opencode CLI",
        "spawn_agent": "派生子代理",
        "ask_user": "询问你",
        "run_workflow": "运行工作流",
        "declare_environment_trust": "登记环境信任",
        "show_widget": "展示组件",
    ]
}

/// Approval controls are primary task actions, so their hit targets must not
/// collapse to the compact caption-sized controls used by passive tool rows.
/// Keeping the metrics centralized also makes accidental regressions easy to
/// catch without rendering the full transcript in a unit test.
