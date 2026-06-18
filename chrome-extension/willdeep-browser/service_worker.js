const HOST_NAME = "com.willdeep.browser_bridge";
const CONTENT_SCRIPT = "content.js";

let nativePort = null;
let nativeReady = false;
const pendingNative = new Map();

chrome.runtime.onInstalled.addListener(() => {
  connectNativeHost();
});

chrome.runtime.onStartup.addListener(() => {
  connectNativeHost();
});

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  handleRuntimeMessage(message, sender)
    .then(sendResponse)
    .catch((error) => sendResponse({ ok: false, error: String(error?.message || error) }));
  return true;
});

function connectNativeHost() {
  try {
    nativePort = chrome.runtime.connectNative(HOST_NAME);
    nativeReady = true;
    nativePort.onMessage.addListener(handleNativeMessage);
    nativePort.onDisconnect.addListener(() => {
      nativeReady = false;
      nativePort = null;
      for (const [id, pending] of pendingNative) {
        pending.resolve({ ok: false, error: "native host disconnected", id });
      }
      pendingNative.clear();
    });
    postNative("hello", { extensionVersion: chrome.runtime.getManifest().version }).catch(() => {});
  } catch {
    nativeReady = false;
    nativePort = null;
  }
}

async function handleRuntimeMessage(message) {
  switch (message?.type) {
    case "native.ping":
      return nativePing();
    case "page.read":
      return withActiveTab((tab) => sendContentCommand(tab.id, "readPage", message.payload));
    case "page.selection":
      return withActiveTab((tab) => sendContentCommand(tab.id, "readSelection", message.payload));
    case "page.click":
      return withActiveTab((tab) => sendContentCommand(tab.id, "clickSelector", message.payload));
    case "page.type":
      return withActiveTab((tab) => sendContentCommand(tab.id, "typeSelector", message.payload));
    case "tab.capture":
      return captureActiveTab();
    case "debugger.command":
      return withActiveTab((tab) => debuggerCommand(tab.id, message.payload));
    default:
      return { ok: false, error: `unknown message type: ${message?.type || ""}` };
  }
}

async function nativePing() {
  if (!nativePort) {
    connectNativeHost();
  }
  if (!nativePort) {
    return { ok: false, connected: false };
  }
  const response = await postNative("ping", {});
  return { ok: Boolean(response?.ok), connected: nativeReady, native: response };
}

function postNative(type, payload) {
  if (!nativePort) {
    return Promise.resolve({ ok: false, error: "native host unavailable" });
  }
  const id = crypto.randomUUID();
  return new Promise((resolve) => {
    pendingNative.set(id, { resolve });
    nativePort.postMessage({ id, type, payload });
    setTimeout(() => {
      const pending = pendingNative.get(id);
      if (!pending) {
        return;
      }
      pendingNative.delete(id);
      pending.resolve({ ok: false, error: "native host timeout", id });
    }, 5000);
  });
}

function handleNativeMessage(message) {
  if (message?.reply_to && pendingNative.has(message.reply_to)) {
    const pending = pendingNative.get(message.reply_to);
    pendingNative.delete(message.reply_to);
    pending.resolve(message);
    return;
  }
  if (!message?.id || !message?.type) {
    return;
  }
  handleRuntimeMessage({ type: message.type, payload: message.payload || {} })
    .then((result) => {
      const ok = Boolean(result?.ok);
      nativePort?.postMessage({
        reply_to: message.id,
        ok,
        error: ok ? undefined : String(result?.error || "browser command failed"),
        data: result
      });
    })
    .catch((error) => nativePort?.postMessage({ reply_to: message.id, ok: false, error: String(error?.message || error) }));
}

async function withActiveTab(action) {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab?.id) {
    return { ok: false, error: "no active tab" };
  }
  return action(tab);
}

async function ensureContentScript(tabId) {
  try {
    await chrome.tabs.sendMessage(tabId, { type: "probe" });
  } catch {
    await chrome.scripting.executeScript({
      target: { tabId },
      files: [CONTENT_SCRIPT]
    });
  }
}

async function sendContentCommand(tabId, command, payload = {}) {
  await ensureContentScript(tabId);
  return chrome.tabs.sendMessage(tabId, { type: command, payload });
}

async function captureActiveTab() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab?.windowId) {
    return { ok: false, error: "no active tab" };
  }
  const dataURL = await chrome.tabs.captureVisibleTab(tab.windowId, { format: "png" });
  return {
    ok: true,
    tab: { id: tab.id, title: tab.title, url: tab.url },
    image_data_url: dataURL
  };
}

async function debuggerCommand(tabId, payload = {}) {
  const method = String(payload.method || "");
  if (!method) {
    return { ok: false, error: "missing debugger method" };
  }
  const target = { tabId };
  await chrome.debugger.attach(target, payload.protocolVersion || "1.3");
  try {
    const result = await chrome.debugger.sendCommand(target, method, payload.params || {});
    return { ok: true, result };
  } finally {
    await chrome.debugger.detach(target);
  }
}
