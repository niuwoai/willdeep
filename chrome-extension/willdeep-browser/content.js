(() => {
  if (globalThis.__willdeepBrowserBridgeInstalled) {
    return;
  }
  globalThis.__willdeepBrowserBridgeInstalled = true;
  const snapshotElements = new Map();
  let snapshotSequence = 0;

  chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    handleMessage(message)
      .then(sendResponse)
      .catch((error) => sendResponse({ ok: false, error: String(error?.message || error) }));
    return true;
  });

  async function handleMessage(message) {
    switch (message?.type) {
      case "probe":
        return { ok: true };
      case "readPage":
        return readPage(message.payload || {});
      case "readSelection":
        return readSelection();
      case "snapshot":
        return snapshotPage(message.payload || {});
      case "clickSelector":
        return clickSelector(message.payload || {});
      case "typeSelector":
        return typeSelector(message.payload || {});
      case "hoverSelector":
        return hoverSelector(message.payload || {});
      case "selectOption":
        return selectOption(message.payload || {});
      case "pressKey":
        return pressKey(message.payload || {});
      case "scrollPage":
        return scrollPage(message.payload || {});
      case "waitFor":
        return waitFor(message.payload || {});
      default:
        return { ok: false, error: `unknown content command: ${message?.type || ""}` };
    }
  }

  function readPage(payload) {
    const maxChars = clampNumber(payload.maxChars, 20000, 1000, 100000);
    const text = (document.body?.innerText || "").slice(0, maxChars);
    return {
      ok: true,
      title: document.title,
      url: location.href,
      selection: String(getSelection() || ""),
      text,
      links: Array.from(document.links).slice(0, 80).map((link) => ({
        text: compact(link.innerText || link.getAttribute("aria-label") || link.href),
        href: link.href
      })),
      forms: Array.from(document.forms).slice(0, 20).map((form) => ({
        id: form.id || "",
        name: form.getAttribute("name") || "",
        action: form.action || "",
        inputs: Array.from(form.elements).slice(0, 80).map((input) => ({
          tag: input.tagName.toLowerCase(),
          type: input.getAttribute("type") || "",
          name: input.getAttribute("name") || "",
          id: input.id || "",
          placeholder: input.getAttribute("placeholder") || ""
        }))
      })),
      interactive_elements: snapshotPage({ maxElements: payload.maxElements || 240 }).elements
    };
  }

  function readSelection() {
    return {
      ok: true,
      title: document.title,
      url: location.href,
      selection: String(getSelection() || "")
    };
  }

  function clickSelector(payload) {
    const element = requireElement(payload);
    element.scrollIntoView({ block: "center", inline: "center" });
    element.click();
    return { ok: true, ref: payload.ref || "", selector: selectorFor(element) };
  }

  function typeSelector(payload) {
    const element = requireElement(payload);
    const text = String(payload.text || "");
    element.scrollIntoView({ block: "center", inline: "center" });
    element.focus();
    if ("value" in element) {
      setNativeValue(element, text);
      element.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertReplacementText", data: text }));
      element.dispatchEvent(new Event("change", { bubbles: true }));
    } else {
      element.textContent = text;
      element.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: text }));
    }
    return { ok: true, ref: payload.ref || "", selector: selectorFor(element) };
  }

  function hoverSelector(payload) {
    const element = requireElement(payload);
    element.scrollIntoView({ block: "center", inline: "center" });
    for (const type of ["pointerover", "mouseover", "mouseenter", "pointermove", "mousemove"]) {
      const EventType = type.startsWith("pointer") ? PointerEvent : MouseEvent;
      element.dispatchEvent(new EventType(type, { bubbles: true, cancelable: true, view: window }));
    }
    return { ok: true, ref: payload.ref || "", selector: selectorFor(element) };
  }

  function selectOption(payload) {
    const element = requireElement(payload);
    if (!(element instanceof HTMLSelectElement)) throw new Error("target is not a select element");
    const value = String(payload.value || "");
    const label = String(payload.label || "");
    if (!value && !label) throw new Error("missing option value or label");
    if (value && label) throw new Error("provide option value or label, not both");
    const options = Array.from(element.options);
    const option = value
      ? options.find((candidate) => candidate.value === value)
      : options.find((candidate) => compact(candidate.textContent) === compact(label));
    if (!option) throw new Error(`option not found: ${value || label}`);
    element.scrollIntoView({ block: "center", inline: "center" });
    element.focus();
    setNativeValue(element, option.value);
    option.selected = true;
    element.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertReplacementText", data: option.value }));
    element.dispatchEvent(new Event("change", { bubbles: true }));
    return {
      ok: true,
      ref: payload.ref || "",
      selector: selectorFor(element),
      value: option.value,
      label: compact(option.textContent)
    };
  }

  function snapshotPage(payload) {
    const maxElements = clampNumber(payload.maxElements, 240, 1, 600);
    const snapshotId = `dom-${Date.now().toString(36)}-${++snapshotSequence}`;
    snapshotElements.clear();
    const candidates = Array.from(document.querySelectorAll(
      "a[href],button,input,textarea,select,summary,[role],[tabindex],[contenteditable=true],h1,h2,h3,h4,h5,h6"
    ));
    const elements = [];
    for (const element of candidates) {
      if (elements.length >= maxElements || !isVisible(element)) {
        continue;
      }
      const ref = `${snapshotId}:e${elements.length + 1}`;
      snapshotElements.set(ref, element);
      const rect = element.getBoundingClientRect();
      const entry = {
        ref,
        tag: element.tagName.toLowerCase(),
        role: element.getAttribute("role") || implicitRole(element),
        name: accessibleName(element),
        text: compact(element.innerText || element.textContent || ""),
        selector: selectorFor(element),
        disabled: Boolean(element.disabled || element.getAttribute("aria-disabled") === "true"),
        focused: document.activeElement === element,
        rect: roundedRect(rect)
      };
      if ("checked" in element) entry.checked = Boolean(element.checked);
      if ("selected" in element) entry.selected = Boolean(element.selected);
      if ("expanded" in element || element.hasAttribute("aria-expanded")) {
        entry.expanded = element.getAttribute("aria-expanded") === "true";
      }
      if ("value" in element && !isSensitiveInput(element)) {
        entry.value = compact(String(element.value || ""));
      }
      elements.push(entry);
    }
    return {
      ok: true,
      snapshot_id: snapshotId,
      title: document.title,
      url: location.href,
      viewport: { width: innerWidth, height: innerHeight, scroll_x: scrollX, scroll_y: scrollY },
      elements
    };
  }

  function pressKey(payload) {
    const element = payload.ref || payload.selector ? requireElement(payload) : document.activeElement;
    if (!element) throw new Error("no focused element");
    const key = String(payload.key || "").trim();
    if (!key) throw new Error("missing key");
    element.focus();
    const options = {
      key,
      code: String(payload.code || ""),
      bubbles: true,
      cancelable: true,
      altKey: Boolean(payload.alt_key),
      ctrlKey: Boolean(payload.ctrl_key),
      metaKey: Boolean(payload.meta_key),
      shiftKey: Boolean(payload.shift_key)
    };
    const accepted = element.dispatchEvent(new KeyboardEvent("keydown", options));
    element.dispatchEvent(new KeyboardEvent("keyup", options));
    let focusedElement = element;
    if (accepted) {
      if (key === "Tab") {
        focusedElement = focusRelative(element, Boolean(payload.shift_key));
      } else if (key === "Escape") {
        element.blur();
      } else if ((key === "Backspace" || key === "Delete") && isTextControl(element)) {
        deleteFromTextControl(element, key === "Backspace");
      } else if ((key === "Enter" || key === " ") && element.matches("button,a[href],[role=button]")) {
        element.click();
      } else if (key === "Enter" && isTextControl(element) && element.form) {
        element.form.requestSubmit();
      }
    }
    return {
      ok: true,
      key,
      ref: payload.ref || "",
      selector: selectorFor(element),
      focused_selector: document.activeElement instanceof Element ? selectorFor(document.activeElement) : "",
      focus_moved: focusedElement !== element
    };
  }

  function focusRelative(current, reverse) {
    const focusable = Array.from(document.querySelectorAll(
      "a[href],button,input,textarea,select,summary,[tabindex]:not([tabindex='-1']),[contenteditable=true]"
    )).filter((element) => isVisible(element) && !element.disabled && element.getAttribute("aria-disabled") !== "true");
    if (!focusable.length) return current;
    const currentIndex = focusable.indexOf(current);
    const delta = reverse ? -1 : 1;
    const nextIndex = currentIndex < 0
      ? (reverse ? focusable.length - 1 : 0)
      : (currentIndex + delta + focusable.length) % focusable.length;
    focusable[nextIndex].focus();
    return focusable[nextIndex];
  }

  function isTextControl(element) {
    return element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement;
  }

  function deleteFromTextControl(element, backward) {
    const start = element.selectionStart ?? String(element.value || "").length;
    const end = element.selectionEnd ?? start;
    const from = start === end && backward ? Math.max(0, start - 1) : start;
    const to = start === end && !backward ? Math.min(String(element.value || "").length, end + 1) : end;
    element.setRangeText("", from, to, "end");
    element.dispatchEvent(new InputEvent("input", {
      bubbles: true,
      inputType: backward ? "deleteContentBackward" : "deleteContentForward",
      data: null
    }));
  }

  function scrollPage(payload) {
    const direction = String(payload.direction || "down").toLowerCase();
    const pages = clampNumber(payload.pages, 1, 1, 8);
    const target = payload.ref || payload.selector ? requireElement(payload) : window;
    const vertical = direction === "up" || direction === "down";
    const sign = direction === "up" || direction === "left" ? -1 : 1;
    const amount = sign * pages * (vertical ? innerHeight * 0.82 : innerWidth * 0.82);
    target.scrollBy({
      left: vertical ? 0 : amount,
      top: vertical ? amount : 0,
      behavior: payload.behavior === "smooth" ? "smooth" : "instant"
    });
    return { ok: true, direction, pages, scroll_x: scrollX, scroll_y: scrollY };
  }

  async function waitFor(payload) {
    const condition = String(payload.condition || "selector");
    const value = String(payload.value || "");
    if (!value) throw new Error("missing wait value");
    const timeoutMs = clampNumber(payload.timeoutMs, 10000, 100, 30000);
    const deadline = Date.now() + timeoutMs;
    while (Date.now() <= deadline) {
      const matched = condition === "selector" ? Boolean(document.querySelector(value))
        : condition === "text" ? String(document.body?.innerText || "").includes(value)
          : condition === "url_contains" ? location.href.includes(value)
            : condition === "title_contains" ? document.title.includes(value)
              : false;
      if (matched) return { ok: true, condition, value, url: location.href, title: document.title };
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    throw new Error(`timed out waiting for ${condition}: ${value}`);
  }

  function requireElement(payload) {
    const ref = String(payload.ref || "").trim();
    if (ref) {
      const element = snapshotElements.get(ref);
      if (!element || !element.isConnected) throw new Error(`stale or missing element ref: ${ref}`);
      return element;
    }
    const trimmed = String(payload.selector || "").trim();
    if (!trimmed) throw new Error("missing ref or selector");
    const matches = document.querySelectorAll(trimmed);
    if (matches.length > 1) throw new Error(`selector matched ${matches.length} elements: ${trimmed}`);
    const element = matches[0];
    if (!element) {
      throw new Error(`selector not found: ${trimmed}`);
    }
    return element;
  }

  function setNativeValue(element, value) {
    const own = Object.getOwnPropertyDescriptor(element, "value")?.set;
    const prototype = Object.getPrototypeOf(element);
    const inherited = Object.getOwnPropertyDescriptor(prototype, "value")?.set;
    if (inherited && own !== inherited) inherited.call(element, value);
    else if (own) own.call(element, value);
    else element.value = value;
  }

  function accessibleName(element) {
    const labelledBy = element.getAttribute("aria-labelledby");
    const labelledText = labelledBy
      ? labelledBy.split(/\s+/).map((id) => document.getElementById(id)?.innerText || "").join(" ")
      : "";
    const labels = "labels" in element && element.labels
      ? Array.from(element.labels).map((label) => label.innerText || "").join(" ")
      : "";
    return compact(
      element.getAttribute("aria-label") || labelledText || labels || element.getAttribute("alt") ||
      element.getAttribute("title") || element.innerText || element.getAttribute("placeholder") || ""
    );
  }

  function implicitRole(element) {
    const tag = element.tagName.toLowerCase();
    if (tag === "a" && element.hasAttribute("href")) return "link";
    if (tag === "button") return "button";
    if (tag === "textarea") return "textbox";
    if (tag === "select") return "combobox";
    if (tag === "input") {
      const type = (element.getAttribute("type") || "text").toLowerCase();
      if (type === "checkbox") return "checkbox";
      if (type === "radio") return "radio";
      if (["button", "submit", "reset"].includes(type)) return "button";
      return "textbox";
    }
    if (/^h[1-6]$/.test(tag)) return "heading";
    return "";
  }

  function selectorFor(element) {
    if (element.id) return `#${CSS.escape(element.id)}`;
    const testId = element.getAttribute("data-testid");
    if (testId) return `[data-testid="${CSS.escape(testId)}"]`;
    const name = element.getAttribute("name");
    if (name) return `${element.tagName.toLowerCase()}[name="${CSS.escape(name)}"]`;
    const parts = [];
    let current = element;
    while (current && current.nodeType === Node.ELEMENT_NODE && parts.length < 5) {
      let part = current.tagName.toLowerCase();
      const siblings = current.parentElement
        ? Array.from(current.parentElement.children).filter((child) => child.tagName === current.tagName)
        : [];
      if (siblings.length > 1) part += `:nth-of-type(${siblings.indexOf(current) + 1})`;
      parts.unshift(part);
      current = current.parentElement;
    }
    return parts.join(" > ");
  }

  function isVisible(element) {
    const style = getComputedStyle(element);
    const rect = element.getBoundingClientRect();
    return style.visibility !== "hidden" && style.display !== "none" && Number(style.opacity || 1) > 0 && rect.width > 0 && rect.height > 0;
  }

  function isSensitiveInput(element) {
    const type = String(element.getAttribute("type") || "").toLowerCase();
    const name = `${element.getAttribute("name") || ""} ${element.id || ""} ${element.getAttribute("autocomplete") || ""}`.toLowerCase();
    return type === "password" || /(password|passwd|secret|token|otp|one.?time|credit.?card|cvv)/.test(name);
  }

  function roundedRect(rect) {
    return {
      x: Math.round(rect.x), y: Math.round(rect.y),
      width: Math.round(rect.width), height: Math.round(rect.height)
    };
  }

  function compact(value) {
    return String(value || "").replace(/\s+/g, " ").trim().slice(0, 180);
  }

  function clampNumber(value, fallback, min, max) {
    const number = Number(value);
    if (!Number.isFinite(number)) {
      return fallback;
    }
    return Math.min(Math.max(number, min), max);
  }
})();
