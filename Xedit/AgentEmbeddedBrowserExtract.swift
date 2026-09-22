//
//  AgentEmbeddedBrowserExtract.swift
//  WillDeep
//
//  Declarative extraction for the embedded browser: "for every element that
//  matches this selector, give me these fields". It covers what the model
//  used to write embedded_browser_eval for (search result lists, ad markers,
//  real link targets) without running arbitrary script, so it is read-only
//  and needs no approval.
//

import Foundation
import WebKit

nonisolated struct AgentBrowserExtractField: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        /// innerText of the matched element (or of the sub-element).
        case text
        /// An attribute such as href, src, class, data-*; href/src resolve
        /// to absolute URLs.
        case attribute(String)
        /// Whether the sub-selector matches anything inside the item.
        case exists
        /// How many elements the sub-selector matches inside the item.
        case count
    }

    let name: String
    /// Selector relative to the item; nil means the item itself.
    let selector: String?
    let source: Source

    static let defaultLimit = 20
    static let maximumLimit = 200
    static let defaultMaxChars = 300
    static let maximumMaxChars = 2_000
    static let maximumFields = 20

    /// Parses `name=sub selector@attr` specs. `@text` (default), `@exists`,
    /// `@count` or any attribute name; the selector part may be empty to
    /// read the item itself (`classes=@class`).
    static func parse(_ spec: String) throws -> AgentBrowserExtractField {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let equals = trimmed.firstIndex(of: "="),
              case let name = trimmed[..<equals].trimmingCharacters(in: .whitespaces),
              !name.isEmpty,
              name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
            throw AgentToolError.invalidArgument(
                "Field \"\(spec)\" must look like name=selector@attr, e.g. title=h3, link=a@href, ad=.ad-mark@exists."
            )
        }
        var rest = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        var source = Source.text
        if let at = rest.lastIndex(of: "@"), !rest[rest.index(after: at)...].contains(where: { $0 == " " || $0 == "]" }) {
            let token = String(rest[rest.index(after: at)...]).trimmingCharacters(in: .whitespaces)
            rest = String(rest[..<at]).trimmingCharacters(in: .whitespaces)
            switch token.lowercased() {
            case "", "text": source = .text
            case "exists": source = .exists
            case "count": source = .count
            default: source = .attribute(token)
            }
        }
        return AgentBrowserExtractField(name: name, selector: rest.isEmpty ? nil : rest, source: source)
    }

    var javaScriptSpec: [String: Any] {
        var spec: [String: Any] = ["name": name, "selector": selector ?? ""]
        switch source {
        case .text: spec["kind"] = "text"
        case .attribute(let attribute): spec["kind"] = "attr"; spec["attr"] = attribute
        case .exists: spec["kind"] = "exists"
        case .count: spec["kind"] = "count"
        }
        return spec
    }
}

extension AgentEmbeddedBrowserController {
    func extract(
        selector: String,
        fields: [AgentBrowserExtractField],
        limit: Int,
        maxChars: Int
    ) async throws -> [String: Any] {
        let trimmedSelector = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSelector.isEmpty else {
            throw AgentToolError.invalidArgument("selector is required, e.g. #content_left > div.result.")
        }
        let specData = try JSONSerialization.data(withJSONObject: fields.map(\.javaScriptSpec))
        let specJSON = String(decoding: specData, as: UTF8.self)
        let script = """
        (() => {
          \(Self.sensitiveValueScript)
          const selector = \(try Self.javaScriptLiteral(trimmedSelector));
          const fields = \(specJSON);
          const limit = \(max(1, min(limit, AgentBrowserExtractField.maximumLimit)));
          const maxChars = \(max(20, min(maxChars, AgentBrowserExtractField.maximumMaxChars)));
          const clip = (value) => String(value ?? '').replace(/\\s+/g, ' ').trim().slice(0, maxChars);
          const textOf = (el) => clip(el ? (el.innerText || el.getAttribute('aria-label') || wdSafeValue(el) || '') : '');
          const attrOf = (el, attr) => {
            if (!el) return null;
            const lower = attr.toLowerCase();
            if (lower === 'value') return wdIsSensitiveInput(el) ? null : clip(wdSafeValue(el));
            if ((lower === 'href' || lower === 'src') && el[lower]) return clip(el[lower]);
            const raw = el.getAttribute(attr);
            return raw === null ? null : clip(raw);
          };
          let items;
          try { items = Array.from(document.querySelectorAll(selector)); }
          catch (error) { return { ok: false, error: 'Invalid selector: ' + String(error && error.message || error) }; }
          const out = items.slice(0, limit).map((item, index) => {
            const row = { index };
            if (!fields.length) {
              row.text = textOf(item);
              const link = item.matches('a[href]') ? item : item.querySelector('a[href]');
              if (link) row.href = clip(link.href);
              return row;
            }
            for (const field of fields) {
              let target = item;
              try {
                if (field.kind === 'exists') { row[field.name] = field.selector ? !!item.querySelector(field.selector) : true; continue; }
                if (field.kind === 'count') { row[field.name] = field.selector ? item.querySelectorAll(field.selector).length : 1; continue; }
                if (field.selector) target = item.querySelector(field.selector);
              } catch (error) { row[field.name] = null; continue; }
              row[field.name] = field.kind === 'attr' ? attrOf(target, field.attr) : (target ? textOf(target) : null);
            }
            return row;
          });
          return { ok: true, url: location.href, title: document.title || '', matched: items.length, returned: out.length, items: out };
        })()
        """
        await waitForDocumentContent()
        var payload = try await evaluateObject(script)
        if payload["ok"] as? Bool == false {
            throw AgentToolError.invalidArgument(payload["error"] as? String ?? "Extraction failed.")
        }
        payload.removeValue(forKey: "ok")
        Self.flagBlockedPage(&payload, httpStatus: lastHTTPStatus)
        return payload
    }
}

extension AgentEmbeddedBrowserTools {
    static func extract(arguments: [String: AgentJSONValue], runtimeID: UUID? = nil) async throws -> AgentToolResult {
        guard let selector = arguments["selector"]?.stringValue(),
              !selector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentToolError.missingArgument("selector")
        }
        let specs = arguments["fields"]?.stringArrayValue() ?? []
        guard specs.count <= AgentBrowserExtractField.maximumFields else {
            throw AgentToolError.invalidArgument("At most \(AgentBrowserExtractField.maximumFields) fields per call.")
        }
        let fields = try specs.map(AgentBrowserExtractField.parse)
        let payload = try await AgentEmbeddedBrowserController.controller(for: runtimeID).extract(
            selector: selector,
            fields: fields,
            limit: arguments["limit"]?.intValue() ?? AgentBrowserExtractField.defaultLimit,
            maxChars: arguments["max_chars"]?.intValue() ?? AgentBrowserExtractField.defaultMaxChars
        )
        return AgentToolResult(summary: "Extracted embedded browser elements", payload: prettyJSONString(payload))
    }
}
