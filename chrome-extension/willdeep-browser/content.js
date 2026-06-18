(() => {
  if (globalThis.__willdeepBrowserBridgeInstalled) {
    return;
  }
  globalThis.__willdeepBrowserBridgeInstalled = true;

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
      case "clickSelector":
        return clickSelector(message.payload || {});
      case "typeSelector":
        return typeSelector(message.payload || {});
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
      }))
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
    const element = requireElement(payload.selector);
    element.scrollIntoView({ block: "center", inline: "center" });
    element.click();
    return { ok: true, selector: payload.selector };
  }

  function typeSelector(payload) {
    const element = requireElement(payload.selector);
    const text = String(payload.text || "");
    element.scrollIntoView({ block: "center", inline: "center" });
    element.focus();
    if ("value" in element) {
      element.value = text;
      element.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: text }));
      element.dispatchEvent(new Event("change", { bubbles: true }));
    } else {
      element.textContent = text;
      element.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: text }));
    }
    return { ok: true, selector: payload.selector };
  }

  function requireElement(selector) {
    const trimmed = String(selector || "").trim();
    if (!trimmed) {
      throw new Error("missing selector");
    }
    const element = document.querySelector(trimmed);
    if (!element) {
      throw new Error(`selector not found: ${trimmed}`);
    }
    return element;
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
