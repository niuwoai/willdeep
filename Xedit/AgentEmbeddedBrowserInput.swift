//
//  AgentEmbeddedBrowserInput.swift
//  WillDeep
//
//  Keyboard, scrolling and file upload for the embedded browser. The page
//  scripts mirror the Chrome extension's content.js (`pressKey`,
//  `scrollPage`) so both browser surfaces behave the same; synthetic key
//  events are untrusted, so each key also gets its default action applied
//  when the page did not cancel it.
//

import Foundation
import WebKit

extension AgentEmbeddedBrowserController {
    struct KeyModifiers {
        var alt = false
        var ctrl = false
        var meta = false
        var shift = false
    }

    func pressKey(key: String, selector: String?, code: String?, modifiers: KeyModifiers) async throws -> [String: Any] {
        // " " (Space) is a real key, so no trimming here.
        guard !key.isEmpty else {
            throw AgentToolError.invalidArgument("key is required, e.g. Enter, Tab, Escape, ArrowDown or a.")
        }
        let script = """
        (() => {
          const selector = \(try Self.javaScriptLiteral(selector ?? ""));
          const key = \(try Self.javaScriptLiteral(key));
          const code = \(try Self.javaScriptLiteral(code ?? ""));
          const mods = { altKey: \(modifiers.alt), ctrlKey: \(modifiers.ctrl), metaKey: \(modifiers.meta), shiftKey: \(modifiers.shift) };
          const element = selector ? document.querySelector(selector) : (document.activeElement || document.body);
          if (!element) return { ok: false, error: selector ? `No element matched selector: ${selector}` : 'No focused element.' };
          // setRangeText throws on checkbox/number/etc., so only text-like
          // inputs count as text controls.
          const textInputTypes = ['', 'text', 'search', 'email', 'url', 'tel', 'password'];
          const isTextControl = element instanceof HTMLTextAreaElement
            || (element instanceof HTMLInputElement && textInputTypes.includes(String(element.type || '').toLowerCase()));
          const wasFocused = document.activeElement === element;
          if (selector && typeof element.focus === 'function') element.focus();
          // A field newly focused through a selector gets its caret at the
          // end, so typing continues the existing text like a user would.
          if (selector && !wasFocused && isTextControl) {
            const end = String(element.value || '').length;
            element.setSelectionRange(end, end);
          }
          const editable = isTextControl || element.isContentEditable;
          const init = { key, code, bubbles: true, cancelable: true, composed: true, ...mods };
          const accepted = element.dispatchEvent(new KeyboardEvent('keydown', init));
          if (accepted && key.length === 1) element.dispatchEvent(new KeyboardEvent('keypress', init));
          element.dispatchEvent(new KeyboardEvent('keyup', init));
          let action = accepted ? 'none' : 'prevented_by_page';
          const insert = (text) => {
            if (isTextControl) {
              const start = element.selectionStart ?? element.value.length;
              const end = element.selectionEnd ?? start;
              element.setRangeText(text, start, end, 'end');
              element.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: text }));
            } else {
              document.execCommand('insertText', false, text);
            }
          };
          const scrollStep = (dy) => window.scrollBy({ top: dy, behavior: 'instant' });
          const hasShortcutModifier = mods.ctrlKey || mods.metaKey || mods.altKey;
          if (accepted) {
            if (key === 'Tab') {
              const focusable = Array.from(document.querySelectorAll(
                "a[href],button,input,textarea,select,summary,[tabindex]:not([tabindex='-1']),[contenteditable=true]"
              )).filter((el) => !el.disabled && el.getAttribute('aria-disabled') !== 'true' && el.getClientRects().length > 0);
              if (focusable.length) {
                const index = focusable.indexOf(element);
                const next = index < 0 ? (mods.shiftKey ? focusable.length - 1 : 0)
                  : (index + (mods.shiftKey ? -1 : 1) + focusable.length) % focusable.length;
                focusable[next].focus();
              }
              action = 'focus_moved';
            } else if (key === 'Escape') {
              if (typeof element.blur === 'function') element.blur();
              action = 'blurred';
            } else if ((key === 'Backspace' || key === 'Delete') && editable) {
              if (isTextControl) {
                const value = String(element.value || '');
                const start = element.selectionStart ?? value.length;
                const end = element.selectionEnd ?? start;
                const back = key === 'Backspace';
                const from = start === end && back ? Math.max(0, start - 1) : start;
                const to = start === end && !back ? Math.min(value.length, end + 1) : end;
                element.setRangeText('', from, to, 'end');
                element.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: back ? 'deleteContentBackward' : 'deleteContentForward' }));
              } else {
                document.execCommand(key === 'Backspace' ? 'delete' : 'forwardDelete');
              }
              action = 'deleted';
            } else if (key === ' ' && element.matches('input[type=checkbox],input[type=radio],[role=checkbox],[role=switch]')) {
              element.click();
              action = 'toggled';
            } else if ((key === 'Enter' || key === ' ') && element.matches('button,a[href],[role=button],summary')) {
              element.click();
              action = 'activated';
            } else if (key === 'Enter' && element instanceof HTMLInputElement && element.form) {
              if (typeof element.form.requestSubmit === 'function') element.form.requestSubmit(); else element.form.submit();
              action = 'submitted';
            } else if (key === 'Enter' && editable) {
              insert('\\n');
              action = 'inserted';
            } else if ((key === 'ArrowDown' || key === 'ArrowUp') && element instanceof HTMLSelectElement) {
              const delta = key === 'ArrowDown' ? 1 : -1;
              element.selectedIndex = Math.max(0, Math.min(element.options.length - 1, element.selectedIndex + delta));
              element.dispatchEvent(new Event('input', { bubbles: true }));
              element.dispatchEvent(new Event('change', { bubbles: true }));
              action = 'option_changed';
            } else if (key.length === 1 && editable && !hasShortcutModifier) {
              insert(key);
              action = 'inserted';
            } else if (!editable && ['PageDown', 'PageUp', ' ', 'Home', 'End', 'ArrowDown', 'ArrowUp'].includes(key)) {
              const page = innerHeight * 0.82;
              if (key === 'Home') window.scrollTo({ top: 0, behavior: 'instant' });
              else if (key === 'End') window.scrollTo({ top: document.documentElement.scrollHeight, behavior: 'instant' });
              else if (key === 'PageDown' || (key === ' ' && !mods.shiftKey)) scrollStep(page);
              else if (key === 'PageUp' || key === ' ') scrollStep(-page);
              else scrollStep(key === 'ArrowDown' ? 40 : -40);
              action = 'scrolled';
            }
          }
          const focused = document.activeElement;
          return {
            ok: true,
            key,
            action,
            tag: element.tagName ? element.tagName.toLowerCase() : '',
            focused: focused && focused !== document.body
              ? `${focused.tagName.toLowerCase()}${focused.id ? '#' + focused.id : ''}` : '',
            scroll_y: Math.round(scrollY)
          };
        })()
        """
        let marker = interactionMarker()
        let payload = try await evaluateObject(script)
        guard payload["ok"] as? Bool == true else { return payload }
        return await finishInteraction(payload, since: marker)
    }

    /// Scroll the page or a scrollable element, or bring an element into
    /// view. Waits briefly afterwards so lazy-loaded content can render.
    func scroll(direction: String, pages: Int, selector: String?) async throws -> [String: Any] {
        let normalized = direction.lowercased()
        guard ["up", "down", "left", "right", "top", "bottom", "into_view"].contains(normalized) else {
            throw AgentToolError.invalidArgument("direction must be up, down, left, right, top, bottom, or into_view.")
        }
        if normalized == "into_view", (selector ?? "").isEmpty {
            throw AgentToolError.invalidArgument("direction=into_view needs a selector.")
        }
        let script = """
        (() => {
          const selector = \(try Self.javaScriptLiteral(selector ?? ""));
          const direction = \(try Self.javaScriptLiteral(normalized));
          const pages = \(max(1, min(pages, 8)));
          let target = window;
          let element = null;
          if (selector) {
            element = document.querySelector(selector);
            if (!element) return { ok: false, error: `No element matched selector: ${selector}` };
            const scrollable = element.scrollHeight > element.clientHeight + 1 || element.scrollWidth > element.clientWidth + 1;
            if (direction === 'into_view' || !scrollable) {
              element.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
              return { ok: true, direction: 'into_view', scroll_x: Math.round(scrollX), scroll_y: Math.round(scrollY) };
            }
            target = element;
          }
          const box = target === window
            ? { w: innerWidth, h: innerHeight, maxY: document.documentElement.scrollHeight - innerHeight }
            : { w: element.clientWidth, h: element.clientHeight, maxY: element.scrollHeight - element.clientHeight };
          if (direction === 'top') target.scrollTo({ top: 0, behavior: 'instant' });
          else if (direction === 'bottom') target.scrollTo({ top: box.maxY + box.h, behavior: 'instant' });
          else {
            const vertical = direction === 'up' || direction === 'down';
            const sign = direction === 'up' || direction === 'left' ? -1 : 1;
            const amount = sign * pages * (vertical ? box.h : box.w) * 0.82;
            target.scrollBy({ left: vertical ? 0 : amount, top: vertical ? amount : 0, behavior: 'instant' });
          }
          const y = target === window ? scrollY : element.scrollTop;
          const x = target === window ? scrollX : element.scrollLeft;
          const maxY = target === window ? document.documentElement.scrollHeight - innerHeight : element.scrollHeight - element.clientHeight;
          return {
            ok: true,
            direction,
            scroll_x: Math.round(x),
            scroll_y: Math.round(y),
            at_top: y <= 1,
            at_bottom: y >= maxY - 1
          };
        })()
        """
        let payload = try await evaluateObject(script)
        guard payload["ok"] as? Bool == true else { return payload }
        // Infinite lists and lazy images load on scroll; give them a beat so
        // the next read sees the new content.
        try? await Task.sleep(for: Self.scrollSettleDelay)
        return payload
    }

    /// Put local files into a page's file input. An `<input type=file>` gets
    /// them through DataTransfer; any other element (a styled "Upload"
    /// button) is clicked with the files staged for the file chooser it opens.
    func uploadFiles(selector: String, files: [URL]) async throws -> [String: Any] {
        guard !files.isEmpty else { throw AgentToolError.invalidArgument("paths must name at least one file.") }
        let encoded: [[String: Any]] = try files.map { url in
            let data = try Data(contentsOf: url)
            return [
                "name": url.lastPathComponent,
                "type": Self.mimeType(forPathExtension: url.pathExtension),
                "base64": data.base64EncodedString(),
            ]
        }
        let body = """
        const element = document.querySelector(selector);
        if (!element) return { ok: false, error: `No element matched selector: ${selector}` };
        if (!(element instanceof HTMLInputElement && element.type === 'file')) {
          return { ok: true, mode: 'file_chooser' };
        }
        if (!element.multiple && files.length > 1) {
          return { ok: false, error: 'This file input accepts a single file; pass one path.' };
        }
        const transfer = new DataTransfer();
        for (const file of files) {
          const bytes = Uint8Array.from(atob(file.base64), (c) => c.charCodeAt(0));
          transfer.items.add(new File([bytes], file.name, { type: file.type }));
        }
        element.files = transfer.files;
        element.dispatchEvent(new Event('input', { bubbles: true }));
        element.dispatchEvent(new Event('change', { bubbles: true }));
        return { ok: true, mode: 'input', files: Array.from(element.files).map((f) => ({ name: f.name, size: f.size, type: f.type })) };
        """
        let webView = ensureWebView()
        let raw = try await awaitWebKitCallback(timeout: Self.scriptTimeout, what: "file upload") { finish in
            webView.callAsyncJavaScript(
                body,
                arguments: ["selector": selector, "files": encoded],
                in: nil,
                in: .page
            ) { result in
                finish(result.map { $0 as Any }.mapError { Self.describedScriptError($0) })
            }
        }
        guard var payload = raw as? [String: Any] else {
            throw AgentToolError.invalidArgument("Embedded browser upload returned an invalid response.")
        }
        guard payload["ok"] as? Bool == true else { return payload }
        guard payload["mode"] as? String == "file_chooser" else { return payload }

        // A custom button: stage the files, click it, and hand them to the
        // file chooser the page opens (WKUIDelegate runOpenPanel).
        pendingOpenPanelFiles = files
        pendingOpenPanelDeadline = Date().addingTimeInterval(Self.stagedUploadLifetime)
        defer {
            pendingOpenPanelFiles = []
            pendingOpenPanelDeadline = nil
        }
        let dialogsBefore = recentDialogs.count
        var clicked = try await click(selector: selector)
        let newDialogs = recentDialogs.suffix(max(0, recentDialogs.count - dialogsBefore))
        let provided = newDialogs.contains { ($0["answer"] as? String)?.hasPrefix("provided") == true }
        clicked["mode"] = "file_chooser"
        clicked["files_provided"] = provided
        if !provided, clicked["ok"] as? Bool == true {
            clicked["note"] = "The element was clicked but the page did not open a file chooser. Target the page's <input type=file> (snapshot or eval `document.querySelectorAll('input[type=file]')`) instead."
        }
        payload = clicked
        return payload
    }

    static let scrollSettleDelay: Duration = .milliseconds(300)
    /// How long staged files wait for the page to open its file chooser.
    static let stagedUploadLifetime: TimeInterval = 5

    static func mimeType(forPathExtension ext: String) -> String {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "pdf": return "application/pdf"
        case "txt", "log": return "text/plain"
        case "csv": return "text/csv"
        case "json": return "application/json"
        case "html", "htm": return "text/html"
        case "zip": return "application/zip"
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mp3": return "audio/mpeg"
        case "doc": return "application/msword"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "pptx": return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        default: return "application/octet-stream"
        }
    }
}

/// Which local files the Agent may hand to a web page. Uploading is data
/// leaving the machine, so it is limited to the session workspace, never
/// includes credential-looking files, and is size-capped.
nonisolated enum AgentEmbeddedBrowserUploadPolicy {
    static let maxFileCount = 10
    static let maxTotalBytes = 25 * 1_024 * 1_024

    enum Decision: Equatable {
        case allow([URL])
        case reject(String)
    }

    static func evaluate(paths: [String], workspaceRoots: [URL]) -> Decision {
        guard !paths.isEmpty else { return .reject("paths must name at least one file.") }
        guard paths.count <= maxFileCount else { return .reject("At most \(maxFileCount) files per upload.") }
        guard let base = workspaceRoots.first else {
            return .reject("File upload needs a session workspace; files outside a workspace cannot be uploaded.")
        }
        var resolved: [URL] = []
        var totalBytes = 0
        for raw in paths {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let expanded = (trimmed as NSString).expandingTildeInPath
            let url = expanded.hasPrefix("/")
                ? URL(fileURLWithPath: expanded)
                : base.appendingPathComponent(expanded)
            let real = url.standardizedFileURL.resolvingSymlinksInPath()
            let inside = workspaceRoots.contains { root in
                let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
                return real.path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
            }
            guard inside else {
                return .reject("\(trimmed) is outside the session workspace; only workspace files can be uploaded.")
            }
            guard WillDeepCLIHandoff.sensitivePaths(in: [real.path]).isEmpty else {
                return .reject("\(trimmed) looks like a credential or key file and will not be uploaded to a web page.")
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: real.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                return .reject("\(trimmed) is not an existing file.")
            }
            let size = (try? real.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            totalBytes += size
            guard totalBytes <= maxTotalBytes else {
                return .reject("Upload is limited to \(maxTotalBytes / 1_024 / 1_024) MB in total.")
            }
            resolved.append(real)
        }
        return .allow(resolved)
    }
}

extension AgentEmbeddedBrowserTools {
    static func pressKey(arguments: [String: AgentJSONValue], runtimeID: UUID? = nil) async throws -> AgentToolResult {
        let key = try requiredArgument("key", arguments: arguments)
        let modifiers = AgentEmbeddedBrowserController.KeyModifiers(
            alt: arguments["alt_key"]?.boolValue() ?? false,
            ctrl: arguments["ctrl_key"]?.boolValue() ?? false,
            meta: arguments["meta_key"]?.boolValue() ?? false,
            shift: arguments["shift_key"]?.boolValue() ?? false
        )
        let payload = try await AgentEmbeddedBrowserController.controller(for: runtimeID).pressKey(
            key: key,
            selector: arguments["selector"]?.stringValue(),
            code: arguments["code"]?.stringValue(),
            modifiers: modifiers
        )
        return AgentToolResult(summary: "Pressed key in embedded browser", payload: prettyJSONString(payload))
    }

    static func scroll(arguments: [String: AgentJSONValue], runtimeID: UUID? = nil) async throws -> AgentToolResult {
        let direction = try requiredArgument("direction", arguments: arguments)
        let payload = try await AgentEmbeddedBrowserController.controller(for: runtimeID).scroll(
            direction: direction,
            pages: arguments["pages"]?.intValue() ?? 1,
            selector: arguments["selector"]?.stringValue()
        )
        return AgentToolResult(summary: "Scrolled embedded browser", payload: prettyJSONString(payload))
    }

    static func uploadFile(
        arguments: [String: AgentJSONValue],
        runtimeID: UUID? = nil,
        workspaceRoots: [URL] = []
    ) async throws -> AgentToolResult {
        let selector = try requiredArgument("selector", arguments: arguments)
        let paths = arguments["paths"]?.stringArrayValue()
            ?? arguments["path"]?.stringValue().map { [$0] }
            ?? []
        let files: [URL]
        switch AgentEmbeddedBrowserUploadPolicy.evaluate(paths: paths, workspaceRoots: workspaceRoots) {
        case .allow(let allowed):
            files = allowed
        case .reject(let reason):
            throw AgentToolError.invalidArgument(reason)
        }
        let payload = try await AgentEmbeddedBrowserController.controller(for: runtimeID).uploadFiles(
            selector: selector,
            files: files
        )
        return AgentToolResult(summary: "Uploaded files in embedded browser", payload: prettyJSONString(payload))
    }

    private static func requiredArgument(_ name: String, arguments: [String: AgentJSONValue]) throws -> String {
        guard let value = arguments[name]?.stringValue(), !value.isEmpty else {
            throw AgentToolError.invalidArgument("\(name) is required.")
        }
        return value
    }
}
