//
//  AgentComputerUsePolicy.swift
//  WillDeep
//
//  Host-enforced safety policy for native macOS Computer Use actions.
//  Model instructions remain useful guidance, but consequential actions must
//  be classified and enforced before a request can reach the privileged
//  helper.
//

import Foundation

nonisolated enum AgentComputerUseConsequence: String, CaseIterable, Sendable {
    case none
    case navigation
    case authentication
    case captcha
    case credentialEntry = "credential_entry"
    case send
    case delete
    case purchase
    case financialTransaction = "financial_transaction"
    case legalAgreement = "legal_agreement"
    case permissionChange = "permission_change"
    case accountChange = "account_change"
    case sensitiveDataTransfer = "sensitive_data_transfer"

    var requiresExplicitConfirmation: Bool {
        switch self {
        case .send, .delete, .purchase, .legalAgreement,
             .permissionChange, .accountChange, .sensitiveDataTransfer:
            return true
        case .none, .navigation, .authentication, .captcha,
             .credentialEntry, .financialTransaction:
            return false
        }
    }

    var requiresUserTakeover: Bool {
        switch self {
        case .authentication, .captcha, .credentialEntry, .financialTransaction:
            return true
        case .none, .navigation, .send, .delete, .purchase, .legalAgreement,
             .permissionChange, .accountChange, .sensitiveDataTransfer:
            return false
        }
    }
}

nonisolated enum AgentComputerUsePolicy {
    static let consequenceAwareTools: Set<String> = [
        "computer_use_click",
        "computer_use_secondary_action",
        "computer_use_drag",
        "computer_use_type_text",
        "computer_use_press_key",
        "computer_use_set_value",
        "computer_use_select_text",
    ]

    static let helperActionNames: Set<String> = [
        "click", "secondary_action", "scroll", "drag", "type_text",
        "press_key", "set_value", "focus", "hover", "select_text",
    ]

    private static let leaseAutoApprovalTools: Set<String> = [
        "computer_use_activate_app",
        "computer_use_click",
        "computer_use_secondary_action",
        "computer_use_scroll",
        "computer_use_type_text",
        "computer_use_press_key",
        "computer_use_set_value",
        "computer_use_focus",
        "computer_use_hover",
        "computer_use_select_text",
    ]

    static func risk(
        toolName: String,
        arguments: [String: AgentJSONValue],
        declaredRisk: AgentToolRisk
    ) -> AgentToolRisk {
        if requiresPerActionTypedConfirmation(
            toolName: toolName,
            arguments: arguments
        ) {
            return .danger
        }
        if isLeaseEligibleClickTool(toolName),
           hasLeaseEligibleClickShape(arguments) {
            return requiresUserTakeover(arguments) ? .danger : declaredRisk
        }
        guard consequenceAwareTools.contains(toolName) else {
            return declaredRisk
        }
        guard let consequence = declaredConsequence(arguments) else {
            // An omitted classification is not silently treated as harmless.
            return .danger
        }
        if consequence.requiresExplicitConfirmation || consequence.requiresUserTakeover {
            return .danger
        }
        if inferredConsequence(arguments)?.requiresExplicitConfirmation == true
            || inferredConsequence(arguments)?.requiresUserTakeover == true {
            return .danger
        }
        return declaredRisk
    }

    static func requiresExplicitConfirmation(
        toolName: String,
        arguments: [String: AgentJSONValue]
    ) -> Bool {
        if requiresPerActionTypedConfirmation(
            toolName: toolName,
            arguments: arguments
        ) {
            return true
        }
        if isLeaseEligibleClickTool(toolName),
           hasLeaseEligibleClickShape(arguments) {
            return requiresUserTakeover(arguments)
        }
        guard consequenceAwareTools.contains(toolName) else { return false }
        guard let consequence = declaredConsequence(arguments) else { return true }
        if consequence.requiresExplicitConfirmation || consequence.requiresUserTakeover {
            return true
        }
        guard let inferred = inferredConsequence(arguments) else { return false }
        return inferred.requiresExplicitConfirmation || inferred.requiresUserTakeover
    }

    static func requiresUserTakeover(
        _ arguments: [String: AgentJSONValue]
    ) -> Bool {
        declaredConsequence(arguments)?.requiresUserTakeover == true
            || inferredConsequence(arguments)?.requiresUserTakeover == true
    }

    /// Ordinary desktop interaction may run without one approval card per
    /// primitive only after the host owns a live, target-bound control lease.
    /// The lease is runtime memory, not an allow-list signature: it cannot
    /// survive a turn, app restart, user takeover, or target switch.
    static func canAutoApproveInOperationalLease(
        toolName: String,
        arguments: [String: AgentJSONValue],
        owner: AgentComputerUseOwner?,
        controlState: AgentComputerUseControlState
    ) -> Bool {
        guard leaseAutoApprovalTools.contains(toolName),
              let owner,
              case .controlling(let lease) = controlState,
              lease.operation == .controlling,
              lease.belongs(to: owner) else {
            return false
        }
        guard argumentsMatchTargetLease(arguments, lease: lease),
              hasAutoApprovableActionShape(
                  toolName: toolName,
                  arguments: arguments
              ) else {
            return false
        }
        return true
    }

    static func validateBeforeHelper(
        action: String,
        arguments: [String: AgentJSONValue]
    ) throws {
        let toolName = "computer_use_\(action)"
        if consequenceAwareTools.contains(toolName) {
            let purpose = arguments["purpose"]?.stringValue()?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !purpose.isEmpty else {
                throw AgentToolError.invalidArgument(
                    "Computer Use requires a concise purpose for this action."
                )
            }
            guard let consequence = declaredConsequence(arguments) else {
                throw AgentToolError.invalidArgument(
                    "Computer Use requires a valid consequence classification before this action."
                )
            }
            if consequence.requiresUserTakeover
                || inferredConsequence(arguments)?.requiresUserTakeover == true {
                throw AgentToolError.invalidArgument(
                    "This action requires private user takeover. Pause Computer Use, let the user complete it without screenshots, then resume from a fresh app state."
                )
            }
        }

        if referencesClipboardAccess(arguments) {
            throw AgentToolError.invalidArgument(
                "Computer Use refuses Copy, Cut, and Paste actions because clipboard contents are private external state. Type non-sensitive text explicitly or ask the user to take over."
            )
        }

        if action == "press_key",
           isClipboardShortcut(arguments["key"]?.stringValue() ?? "") {
            throw AgentToolError.invalidArgument(
                "Computer Use refuses Cmd-C, Cmd-X, and Cmd-V because clipboard contents are private external state. Type non-sensitive text explicitly or ask the user to take over."
            )
        }

        if action == "type_text" || action == "set_value" || action == "select_text" {
            let candidate = (arguments["text"] ?? arguments["value"])?.stringValue() ?? ""
            if likelySensitiveText(candidate) {
                throw AgentToolError.invalidArgument(
                    "Computer Use refuses to enter likely credentials, private identifiers, payment data, recovery material, or one-time codes. Ask the user to take over."
                )
            }
        }
    }

    static func declaredConsequence(
        _ arguments: [String: AgentJSONValue]
    ) -> AgentComputerUseConsequence? {
        guard let raw = arguments["consequence"]?.stringValue()?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !raw.isEmpty else {
            return nil
        }
        return AgentComputerUseConsequence(rawValue: raw)
    }

    static func likelySensitiveText(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lowered = trimmed.lowercased()

        let secretPrefixes = [
            "sk-", "ghp_", "github_pat_", "akia", "bearer ", "xoxb-", "xoxp-",
            "-----begin", "ssh-rsa ", "eyj",
        ]
        if secretPrefixes.contains(where: lowered.hasPrefix) {
            return true
        }

        let normalizedDigits = trimmed.filter(\.isNumber)
        let oneTimeCodePatterns = [
            #"(?i)(?:otp|code|验证码|校验码|动态码|一次性密码)\s*[:：-]?\s*\d(?:[\s-]?\d){3,7}"#,
            #"^\s*\d(?:[\s-]?\d){3,7}\s*$"#,
        ]
        if oneTimeCodePatterns.contains(where: {
            trimmed.range(of: $0, options: .regularExpression) != nil
        }) {
            return true
        }

        let credentialLabels = [
            "password", "passcode", "密码", "口令", "recovery code",
            "recovery phrase", "seed phrase", "助记词", "private key", "私钥",
        ]
        if credentialLabels.contains(where: lowered.contains) {
            return true
        }

        // Payment cards are commonly 13–19 digits with spaces or dashes.
        if (13...19).contains(normalizedDigits.count),
           luhnValid(normalizedDigits) {
            return true
        }

        // Mainland China resident identity numbers. This deliberately checks
        // only the strong shape; it never persists or logs the candidate.
        if trimmed.range(
            of: #"(?i)^\d{17}[\dx]$"#,
            options: .regularExpression
        ) != nil {
            return true
        }

        return false
    }

    static func containsControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        }
    }

    static func isLeaseSafeNavigationKey(_ raw: String) -> Bool {
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")

        let aliases: Set<String> = [
            "tab",
            "shift+tab",
            "tab+shift",
            "backtab",
            "left",
            "arrowleft",
            "right",
            "arrowright",
            "up",
            "arrowup",
            "down",
            "arrowdown",
            "escape",
            "esc",
            "home",
            "end",
            "pageup",
            "page+up",
            "pagedown",
            "page+down",
        ]
        return aliases.contains(normalized)
    }

    private static func requiresPerActionTypedConfirmation(
        toolName: String,
        arguments: [String: AgentJSONValue]
    ) -> Bool {
        switch toolName {
        case "computer_use_press_key":
            return !isLeaseSafeNavigationKey(
                arguments["key"]?.stringValue() ?? ""
            ) || !hasConsequentialActionMetadata(arguments)
                || !hasFreshSnapshot(arguments)
        case "computer_use_type_text":
            return !hasOrdinaryTextInput(
                arguments["text"]?.stringValue(),
                arguments: arguments,
                allowEmpty: false
            )
        case "computer_use_set_value":
            return !hasOrdinaryTextInput(
                arguments["value"]?.stringValue(),
                arguments: arguments,
                allowEmpty: true
            ) || !hasFreshRef(arguments)
        case "computer_use_select_text":
            return !hasOrdinaryTextInput(
                arguments["text"]?.stringValue(),
                arguments: arguments,
                allowEmpty: false
            ) || !hasFreshRef(arguments)
        case "computer_use_click", "computer_use_secondary_action":
            return !hasLeaseEligibleClickShape(arguments)
        case "computer_use_drag":
            // The current drag protocol is coordinate-only. A fresh screenshot
            // constrains the window, but it cannot prove the semantic source
            // and destination controls, so every drag remains per-action.
            return true
        default:
            break
        }
        return referencesClipboardAccess(arguments)
    }

    private static func hasAutoApprovableActionShape(
        toolName: String,
        arguments: [String: AgentJSONValue]
    ) -> Bool {
        guard !referencesClipboardAccess(arguments) else { return false }

        switch toolName {
        case "computer_use_activate_app":
            return arguments["pid"]?.intValue().map { $0 > 0 } == true
                || nonEmptyString(arguments["app"]) != nil

        case "computer_use_type_text":
            return hasOrdinaryTextInput(
                arguments["text"]?.stringValue(),
                arguments: arguments,
                allowEmpty: false
            ) && arguments["pid"]?.intValue().map { $0 > 0 } == true

        case "computer_use_set_value":
            return hasOrdinaryTextInput(
                arguments["value"]?.stringValue(),
                arguments: arguments,
                allowEmpty: true
            ) && hasFreshRef(arguments)

        case "computer_use_select_text":
            return hasOrdinaryTextInput(
                arguments["text"]?.stringValue(),
                arguments: arguments,
                allowEmpty: false
            ) && hasFreshRef(arguments)

        case "computer_use_press_key":
            return hasConsequentialActionMetadata(arguments)
                && hasFreshSnapshot(arguments)
                && arguments["pid"]?.intValue().map { $0 > 0 } == true
                && isLeaseSafeNavigationKey(
                    arguments["key"]?.stringValue() ?? ""
                )

        case "computer_use_click", "computer_use_secondary_action":
            return hasLeaseEligibleClickShape(arguments)

        case "computer_use_drag":
            return false

        case "computer_use_scroll":
            guard hasFreshSnapshot(arguments),
                  arguments["pid"]?.intValue().map({ $0 > 0 }) == true,
                  let direction = nonEmptyString(arguments["direction"])?
                    .lowercased(),
                  ["up", "down", "left", "right"].contains(direction) else {
                return false
            }
            if let pages = arguments["pages"]?.intValue() {
                return (1...8).contains(pages)
            }
            return true

        case "computer_use_focus":
            return hasFreshRef(arguments)

        case "computer_use_hover":
            guard hasFreshSnapshot(arguments) else { return false }
            if nonEmptyString(arguments["ref"]) != nil {
                return hasFreshRef(arguments)
            }
            return arguments["pid"]?.intValue().map { $0 > 0 } == true
                && arguments["x"]?.intValue() != nil
                && arguments["y"]?.intValue() != nil

        default:
            return false
        }
    }

    private static func hasOrdinaryTextInput(
        _ candidate: String?,
        arguments: [String: AgentJSONValue],
        allowEmpty: Bool
    ) -> Bool {
        guard hasConsequentialActionMetadata(arguments),
              hasFreshSnapshot(arguments),
              let candidate else {
            return false
        }
        if !allowEmpty && candidate.isEmpty {
            return false
        }
        return !containsControlCharacters(candidate)
            && !likelySensitiveText(candidate)
    }

    private static func hasConsequentialActionMetadata(
        _ arguments: [String: AgentJSONValue]
    ) -> Bool {
        guard nonEmptyString(arguments["purpose"]) != nil,
              nonEmptyString(arguments["target_label"]) != nil,
              let declared = declaredConsequence(arguments),
              declared == .none || declared == .navigation else {
            return false
        }
        guard let inferred = inferredConsequence(arguments) else {
            return true
        }
        return inferred == .none || inferred == .navigation
    }

    private static func isLeaseEligibleClickTool(_ toolName: String) -> Bool {
        toolName == "computer_use_click"
            || toolName == "computer_use_secondary_action"
    }

    private static func hasLeaseEligibleClickShape(
        _ arguments: [String: AgentJSONValue]
    ) -> Bool {
        guard !referencesClipboardAccess(arguments),
              hasTruthfulActionMetadata(arguments),
              hasFreshSnapshot(arguments) else {
            return false
        }

        if nonEmptyString(arguments["ref"]) != nil {
            return hasFreshRef(arguments)
        }

        guard arguments["pid"]?.intValue().map({ $0 > 0 }) == true,
              arguments["x"]?.intValue() != nil,
              arguments["y"]?.intValue() != nil else {
            return false
        }
        if let coordinateSpace = nonEmptyString(arguments["coordinate_space"]),
           coordinateSpace.lowercased() != "screenshot" {
            return false
        }
        if let clickCount = arguments["click_count"]?.intValue(),
           !(1...3).contains(clickCount) {
            return false
        }
        return true
    }

    private static func hasTruthfulActionMetadata(
        _ arguments: [String: AgentJSONValue]
    ) -> Bool {
        guard nonEmptyString(arguments["purpose"]) != nil,
              nonEmptyString(arguments["target_label"]) != nil,
              let declared = declaredConsequence(arguments) else {
            return false
        }
        guard let inferred = inferredConsequence(arguments) else {
            return true
        }
        return inferred == declared
    }

    private static func hasFreshSnapshot(
        _ arguments: [String: AgentJSONValue]
    ) -> Bool {
        nonEmptyString(arguments["snapshot_id"]) != nil
    }

    private static func hasFreshRef(
        _ arguments: [String: AgentJSONValue]
    ) -> Bool {
        guard let snapshotID = nonEmptyString(arguments["snapshot_id"]),
              let ref = nonEmptyString(arguments["ref"]) else {
            return false
        }
        return ref.hasPrefix("\(snapshotID):")
    }

    private static func argumentsMatchTargetLease(
        _ arguments: [String: AgentJSONValue],
        lease: AgentComputerUseLease
    ) -> Bool {
        if let requestedPID = arguments["pid"]?.intValue() {
            guard requestedPID > 0,
                  lease.target.pid == requestedPID else {
                return false
            }
        }

        if let requestedApp = nonEmptyString(arguments["app"]) {
            let requestedTarget = AgentComputerUseTarget(
                pid: nil,
                applicationName: requestedApp,
                bundleIdentifier: requestedApp.contains(".")
                    ? requestedApp
                    : nil,
                windowTitle: nil
            )
            guard lease.target.matches(requestedTarget) else {
                return false
            }
        }
        return true
    }

    private static func nonEmptyString(
        _ value: AgentJSONValue?
    ) -> String? {
        guard let normalized = value?.stringValue()?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty else {
            return nil
        }
        return normalized
    }

    private static func inferredConsequence(
        _ arguments: [String: AgentJSONValue]
    ) -> AgentComputerUseConsequence? {
        let purpose = arguments["purpose"]?.stringValue() ?? ""
        let label = arguments["target_label"]?.stringValue() ?? ""
        let haystack = "\(purpose) \(label)".lowercased()
        guard !haystack.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let groups: [(AgentComputerUseConsequence, [String])] = [
            (.credentialEntry, [
                "password", "passcode", "otp", "recovery", "密码", "验证码",
                "助记词", "私钥", "登录凭据",
            ]),
            (.captcha, ["captcha", "人机验证", "图形验证"]),
            (.financialTransaction, [
                "transfer", "wire", "bank", "stock trade", "crypto trade",
                "转账", "汇款", "证券交易", "买入股票", "卖出股票",
            ]),
            (.delete, [
                "delete", "remove permanently", "empty trash", "erase",
                "删除", "永久移除", "清空废纸篓", "抹掉",
            ]),
            (.purchase, [
                "purchase", "buy now", "checkout", "place order", "pay",
                "购买", "下单", "结账", "付款",
            ]),
            (.legalAgreement, [
                "accept terms", "agree to", "sign contract", "eula",
                "接受条款", "同意协议", "签署合同",
            ]),
            (.permissionChange, [
                "oauth", "authorize", "grant access", "permission",
                "授权", "授予访问", "权限",
            ]),
            (.accountChange, [
                "change account", "reset account", "create api key",
                "修改账户", "重置账户", "创建 api key", "创建密钥",
            ]),
            (.send, [
                "send", "submit", "publish", "post message", "reply",
                "发送", "提交", "发布", "回复",
            ]),
            (.authentication, [
                "sign in", "log in", "login", "authenticate",
                "登录", "认证",
            ]),
        ]
        return groups.first { _, needles in
            needles.contains(where: haystack.contains)
        }?.0
    }

    private static func isClipboardShortcut(_ raw: String) -> Bool {
        let normalized = raw
            .lowercased()
            .replacingOccurrences(of: "command", with: "cmd")
            .replacingOccurrences(of: "super", with: "cmd")
            .replacingOccurrences(of: "meta", with: "cmd")
            .replacingOccurrences(of: "⌘", with: "cmd+")
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: " ", with: "")
        let tokens = Set(normalized.split(separator: "+").map(String.init))
        return tokens.contains("cmd")
            && !tokens.isDisjoint(with: ["c", "x", "v"])
    }

    private static func referencesClipboardAccess(
        _ arguments: [String: AgentJSONValue]
    ) -> Bool {
        let values = [
            arguments["purpose"]?.stringValue(),
            arguments["target_label"]?.stringValue(),
        ]
        let localizedClipboardTerms = [
            "复制", "拷贝", "剪切", "粘贴", "剪贴板",
            "コピー", "切り取り", "貼り付け", "クリップボード",
        ]
        return values.compactMap { $0?.lowercased() }.contains { value in
            if value.range(
                of: #"(?<![a-z0-9_])(?:copy|cut|paste|clipboard)(?![a-z0-9_])"#,
                options: .regularExpression
            ) != nil {
                return true
            }
            return localizedClipboardTerms.contains(where: value.contains)
        }
    }

    private static func luhnValid(_ digits: String) -> Bool {
        let values = digits.compactMap(\.wholeNumberValue)
        guard values.count == digits.count else { return false }
        let checksum = values.reversed().enumerated().reduce(0) { result, entry in
            let (offset, digit) = entry
            if offset.isMultiple(of: 2) {
                return result + digit
            }
            let doubled = digit * 2
            return result + (doubled > 9 ? doubled - 9 : doubled)
        }
        return checksum.isMultiple(of: 10)
    }
}
