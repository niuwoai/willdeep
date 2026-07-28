import ApplicationServices
import CoreGraphics
import Foundation

enum SensitiveAccessibilityScanResult {
    case complete([CGRect])
    case incomplete
}

enum SensitiveAccessibilityScanner {
    private static let maximumSensitiveScanElementVisits = 20_000
    private static let maximumSensitiveScanDuration: TimeInterval = 5
    private static let protectedContentAttribute = "AXProtectedContent"
    private static let scannedAttributeNames = [
        protectedContentAttribute, kAXRoleAttribute, kAXSubroleAttribute,
        kAXIdentifierAttribute, kAXDescriptionAttribute,
        kAXRoleDescriptionAttribute, kAXPlaceholderValueAttribute,
        kAXTitleAttribute, kAXHelpAttribute, kAXPositionAttribute,
        kAXSizeAttribute, kAXChildrenAttribute
    ]
    private static let securePhrases = [
        "password", "passcode", "passwd", "secure", "otp", "totp", "hotp",
        "cvv", "cvc", "one-time code", "one time code", "verification code",
        "authentication code", "auth code", "security code", "card verification",
        "card number", "credit card", "debit card", "recovery code",
        "recovery key", "recovery phrase", "backup code", "seed phrase",
        "secret phrase", "mnemonic", "private key", "secret key", "api key",
        "api token", "access token", "client secret", "密码", "口令", "验证码",
        "动态码", "短信码", "一次性代码", "一次性密码", "支付密码", "交易密码",
        "安全码", "卡验证码", "卡号", "银行卡", "信用卡", "恢复码", "恢复密钥",
        "恢复短语", "备份码", "助记词", "种子短语", "私钥", "密钥", "令牌",
        "双重验证"
    ]
    private static let terminalKeywords = [
        "terminal", "integrated terminal", "xterm", "shell console",
        "console panel", "终端", "命令行", "控制台"
    ]
    private static let sensitiveTokenPattern =
        #"(?i)(^|[^a-z0-9])(pwd|otp|totp|hotp|cvv|cvc|cid|pin|puk|2fa|mfa)([^a-z0-9]|$)"#

    private struct QueueEntry {
        let element: AXUIElement
        let ancestorSensitive: Bool
    }

    private struct VisitedElement {
        let element: AXUIElement
        var ancestorSensitive: Bool
    }

    private struct VisitedSet {
        private var buckets: [Int: [VisitedElement]] = [:]

        mutating func shouldVisit(
            _ element: AXUIElement,
            ancestorSensitive: Bool
        ) -> Bool {
            let hash = Int(CFHash(element))
            var bucket = buckets[hash, default: []]
            if let index = bucket.firstIndex(where: {
                CFEqual($0.element, element)
            }) {
                guard ancestorSensitive,
                      !bucket[index].ancestorSensitive else {
                    return false
                }
                bucket[index].ancestorSensitive = true
                buckets[hash] = bucket
                return true
            }
            bucket.append(
                VisitedElement(
                    element: element,
                    ancestorSensitive: ancestorSensitive
                )
            )
            buckets[hash] = bucket
            return true
        }
    }

    private enum AttributeResult {
        case complete([String: Any])
        case incomplete
    }

    static func scan(
        root: AXUIElement
    ) -> SensitiveAccessibilityScanResult {
        let deadline =
            ProcessInfo.processInfo.systemUptime
                + maximumSensitiveScanDuration
        var visited = VisitedSet()
        guard visited.shouldVisit(
            root,
            ancestorSensitive: false
        ) else {
            return .incomplete
        }
        var queue = [
            QueueEntry(element: root, ancestorSensitive: false)
        ]
        var nextIndex = 0
        var visitCount = 0
        var sensitiveFrames: [CGRect] = []

        while nextIndex < queue.count {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                return .incomplete
            }
            visitCount += 1
            guard visitCount <= maximumSensitiveScanElementVisits else {
                return .incomplete
            }
            let entry = queue[nextIndex]
            nextIndex += 1
            guard case .complete(let attributes) = attributeValues(
                for: entry.element,
                deadline: deadline
            ) else {
                return .incomplete
            }
            let isSensitive =
                entry.ancestorSensitive
                    || isSecureInputMetadata(attributes)
                    || isTerminalSurfaceMetadata(attributes)
            if isSensitive {
                guard let frame = frame(
                    positionValue: attributes[kAXPositionAttribute],
                    sizeValue: attributes[kAXSizeAttribute]
                ),
                !frame.isNull,
                !frame.isEmpty else {
                    return .incomplete
                }
                sensitiveFrames.append(frame)
            }

            guard let rawChildren = attributes[kAXChildrenAttribute] else {
                continue
            }
            guard let children = rawChildren as? [AXUIElement] else {
                return .incomplete
            }
            for child in children {
                guard visited.shouldVisit(
                    child,
                    ancestorSensitive: isSensitive
                ) else {
                    continue
                }
                guard queue.count < maximumSensitiveScanElementVisits else {
                    return .incomplete
                }
                queue.append(
                    QueueEntry(
                        element: child,
                        ancestorSensitive: isSensitive
                    )
                )
            }
        }
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            return .incomplete
        }
        return .complete(sensitiveFrames)
    }

    static func isSecureInputElement(_ element: AXUIElement) -> Bool {
        isSecureInputMetadata(
            directAttributeValues(
                element,
                names: [
                    protectedContentAttribute, kAXRoleAttribute,
                    kAXSubroleAttribute, kAXIdentifierAttribute,
                    kAXDescriptionAttribute, kAXRoleDescriptionAttribute,
                    kAXPlaceholderValueAttribute, kAXTitleAttribute,
                    kAXHelpAttribute
                ]
            )
        )
    }

    static func isTerminalSurfaceElement(_ element: AXUIElement) -> Bool {
        isTerminalSurfaceMetadata(
            directAttributeValues(
                element,
                names: [
                    kAXIdentifierAttribute, kAXTitleAttribute,
                    kAXDescriptionAttribute, kAXHelpAttribute,
                    kAXRoleDescriptionAttribute
                ]
            )
        )
    }

    private static func attributeValues(
        for element: AXUIElement,
        deadline: TimeInterval
    ) -> AttributeResult {
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            return .incomplete
        }
        var copiedAttributeNames: CFArray?
        guard AXUIElementCopyAttributeNames(
            element,
            &copiedAttributeNames
        ) == .success,
        let attributeNames = copiedAttributeNames as? [String] else {
            return .incomplete
        }
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            return .incomplete
        }
        let supportedNames = Set(attributeNames)
        let requestedNames = scannedAttributeNames.filter(
            supportedNames.contains
        )
        guard !requestedNames.isEmpty else {
            return .complete([:])
        }

        var copiedValues: CFArray?
        let status = AXUIElementCopyMultipleAttributeValues(
            element,
            requestedNames as CFArray,
            AXCopyMultipleAttributeOptions(rawValue: 1),
            &copiedValues
        )
        guard status == .success,
              ProcessInfo.processInfo.systemUptime < deadline,
              let values = copiedValues as? [Any],
              values.count == requestedNames.count else {
            return .incomplete
        }
        var result: [String: Any] = [:]
        result.reserveCapacity(values.count)
        for (name, value) in zip(requestedNames, values) {
            guard !(value is NSNull) else {
                return .incomplete
            }
            let cfValue = value as CFTypeRef
            if CFGetTypeID(cfValue) == AXValueGetTypeID(),
               AXValueGetType(value as! AXValue) == .axError {
                return .incomplete
            }
            result[name] = value
        }
        return .complete(result)
    }

    private static func isSecureInputMetadata(
        _ attributes: [String: Any]
    ) -> Bool {
        if let protectedContent =
                attributes[protectedContentAttribute] as? NSNumber,
           protectedContent.boolValue {
            return true
        }
        let roleValues = [
            attributes[kAXRoleAttribute],
            attributes[kAXSubroleAttribute]
        ]
        if roleValues.contains(where: {
            String(describing: $0 ?? "")
                .lowercased()
                .contains("securetextfield")
        }) {
            return true
        }
        let descriptiveValues = [
            attributes[kAXIdentifierAttribute],
            attributes[kAXDescriptionAttribute],
            attributes[kAXRoleDescriptionAttribute],
            attributes[kAXPlaceholderValueAttribute],
            attributes[kAXTitleAttribute],
            attributes[kAXHelpAttribute]
        ]
        return descriptiveValues.contains { rawValue in
            let normalized = normalizedSemanticText(
                String(describing: rawValue ?? "")
            )
            return securePhrases.contains(where: normalized.contains)
                || normalized.range(
                    of: sensitiveTokenPattern,
                    options: .regularExpression
                ) != nil
        }
    }

    private static func isTerminalSurfaceMetadata(
        _ attributes: [String: Any]
    ) -> Bool {
        let metadata = [
            attributes[kAXIdentifierAttribute],
            attributes[kAXTitleAttribute],
            attributes[kAXDescriptionAttribute],
            attributes[kAXHelpAttribute],
            attributes[kAXRoleDescriptionAttribute]
        ]
        .compactMap { $0 }
        .map { String(describing: $0).lowercased() }
        .joined(separator: " ")
        return terminalKeywords.contains(where: metadata.contains)
    }

    private static func normalizedSemanticText(_ rawValue: String) -> String {
        rawValue
            .replacingOccurrences(
                of: #"([a-z0-9])([A-Z])"#,
                with: "$1 $2",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"[_./-]+"#,
                with: " ",
                options: .regularExpression
            )
            .lowercased()
    }

    private static func attributeValue(
        _ element: AXUIElement,
        _ attribute: String
    ) -> Any? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success ? value : nil
    }

    private static func directAttributeValues(
        _ element: AXUIElement,
        names: [String]
    ) -> [String: Any] {
        var result: [String: Any] = [:]
        for name in names {
            if let value = attributeValue(element, name) {
                result[name] = value
            }
        }
        return result
    }

    private static func frame(
        positionValue rawPositionValue: Any?,
        sizeValue rawSizeValue: Any?
    ) -> CGRect? {
        guard let rawPositionValue,
              CFGetTypeID(rawPositionValue as CFTypeRef)
                == AXValueGetTypeID(),
              let rawSizeValue,
              CFGetTypeID(rawSizeValue as CFTypeRef)
                == AXValueGetTypeID() else {
            return nil
        }
        let positionValue = rawPositionValue as! AXValue
        let sizeValue = rawSizeValue as! AXValue
        guard AXValueGetType(positionValue) == .cgPoint,
              AXValueGetType(sizeValue) == .cgSize else {
            return nil
        }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue, .cgSize, &size),
              origin.x.isFinite,
              origin.y.isFinite,
              size.width.isFinite,
              size.height.isFinite else {
            return nil
        }
        return CGRect(origin: origin, size: size)
    }
}
