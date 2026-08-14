//
//  AgentToolArgumentValidation.swift
//  WillDeep
//
//  Schema-level argument validation performed before tool authorization.
//

import Foundation

extension AgentToolRegistry {
    /// Validate the schema-level contract before risk classification or user
    /// approval. A malformed call must go back to the model for correction;
    /// asking the user to approve it would expose host-only metadata while
    /// still leaving the tool with nothing executable.
    static func argumentValidationError(
        for name: String,
        arguments: [String: AgentJSONValue]
    ) -> String? {
        guard let descriptor = descriptor(for: name) else { return nil }

        var missing: [String] = []
        var invalid: [String] = []
        for parameter in descriptor.parameters where parameter.required {
            guard let value = arguments[parameter.name], value != .null else {
                missing.append(parameter.name)
                continue
            }
            if !value.matches(parameter.type) {
                invalid.append(parameter.name)
            }
        }

        var details: [String] = []
        if !missing.isEmpty {
            details.append("missing required argument(s): \(missing.joined(separator: ", "))")
        }
        if !invalid.isEmpty {
            details.append("wrong type for required argument(s): \(invalid.joined(separator: ", "))")
        }
        guard !details.isEmpty else { return nil }
        return "Invalid tool arguments for \(name): \(details.joined(separator: "; "))."
    }
}

private extension AgentJSONValue {
    func matches(_ parameterType: AgentToolParameter.ParameterType) -> Bool {
        switch parameterType {
        case .string:
            return stringValue() != nil
        case .integer:
            return intValue() != nil
        case .boolean:
            return boolValue() != nil
        case .stringArray:
            return stringArrayValue() != nil
        }
    }
}
