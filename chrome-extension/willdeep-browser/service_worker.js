import {
  UPDATE_ALARM_NAME,
  UPDATE_CHECK_INTERVAL_MINUTES,
  UPDATE_DOWNLOAD_PAGE,
  checkForManagedUpdate,
  loadUpdatePreferences,
  loadUpdateState,
  saveUpdatePreferences
} from "./update_checker.js";

const HOST_NAME = "com.willdeep.browser_bridge";
const CONTENT_SCRIPT = "content.js";
// Chrome's minimum alarm period. A host crash, a service-worker restart or a
// host manifest that was not installed yet at Chrome startup used to leave
// the bridge dead until the user opened the popup or restarted Chrome.
const NATIVE_RECONNECT_ALARM = "willdeep-native-reconnect";
const NATIVE_RECONNECT_MINUTES = 0.5;
const NAVIGATION_SETTLE_TIMEOUT_MS = 10000;

let nativePort = null;
let nativeReady = false;
let nativeConnectionError = null;
const pendingNative = new Map();

chrome.runtime.onInstalled.addListener(() => {
  connectNativeHost();
  void initializeUpdateChecks(true);
});

chrome.runtime.onStartup.addListener(() => {
  connectNativeHost();
  void initializeUpdateChecks(false);
});

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === UPDATE_ALARM_NAME) {
    void runManagedUpdateCheck({ notify: true });
  } else if (alarm.name === NATIVE_RECONNECT_ALARM && !nativePort) {
    connectNativeHost();
  }
});

// Every service-worker wake-up (not just install/startup) re-establishes the
// native connection, so the loopback bridge comes back without user action.
if (!nativePort) {
  connectNativeHost();
}

chrome.notifications.onClicked.addListener((notificationId) => {
  if (notificationId.startsWith("willdeep-browser-update:")) {
    void chrome.tabs.create({ url: UPDATE_DOWNLOAD_PAGE });
    chrome.notifications.clear(notificationId);
  }
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
    nativeConnectionError = null;
    nativePort.onMessage.addListener(handleNativeMessage);
    nativePort.onDisconnect.addListener(() => {
      // Reading lastError inside the callback marks the expected connection
      // failure as handled, so Chrome does not report an unchecked runtime
      // error while WillDeep is still installing or upgrading the host.
      nativeConnectionError = chrome.runtime.lastError?.message || "native host disconnected";
      nativeReady = false;
      nativePort = null;
      for (const [id, pending] of pendingNative) {
        pending.resolve({ ok: false, error: "native host disconnected", id });
      }
      pendingNative.clear();
      scheduleNativeReconnect();
    });
    void chrome.alarms.clear(NATIVE_RECONNECT_ALARM);
    postNative("hello", { extensionVersion: chrome.runtime.getManifest().version }).catch(() => {});
  } catch {
    nativeReady = false;
    nativePort = null;
    scheduleNativeReconnect();
  }
}

function scheduleNativeReconnect() {
  void chrome.alarms.create(NATIVE_RECONNECT_ALARM, {
    delayInMinutes: NATIVE_RECONNECT_MINUTES,
    periodInMinutes: NATIVE_RECONNECT_MINUTES
  });
}

async function handleRuntimeMessage(message) {
  switch (message?.type) {
    case "native.ping":
      return nativePing();
    case "page.read":
      return withActiveTab((tab) => sendContentCommand(tab.id, "readPage", message.payload));
    case "page.selection":
      return withActiveTab((tab) => sendContentCommand(tab.id, "readSelection", message.payload));
    case "page.snapshot":
      return withActiveTab((tab) => sendContentCommand(tab.id, "snapshot", message.payload));
    case "page.click":
      return withActiveTab((tab) => sendContentCommand(tab.id, "clickSelector", message.payload));
    case "page.type":
      return withActiveTab((tab) => sendContentCommand(tab.id, "typeSelector", message.payload));
    case "page.hover":
      return withActiveTab((tab) => sendContentCommand(tab.id, "hoverSelector", message.payload));
    case "page.select_option":
      return withActiveTab((tab) => sendContentCommand(tab.id, "selectOption", message.payload));
    case "page.key":
      return withActiveTab((tab) => sendContentCommand(tab.id, "pressKey", message.payload));
    case "page.scroll":
      return withActiveTab((tab) => sendContentCommand(tab.id, "scrollPage", message.payload));
    case "page.wait":
      return withActiveTab((tab) => sendContentCommand(tab.id, "waitFor", message.payload));
    case "tab.list":
      return listTabs();
    case "tab.activate":
      return activateTab(message.payload || {});
    case "tab.navigate":
      return navigateActiveTab(message.payload || {});
    case "tab.history":
      return navigateHistory(message.payload || {});
    case "tab.capture":
      return captureActiveTab();
    case "debugger.command":
      return withActiveTab((tab) => debuggerCommand(tab.id, message.payload));
    case "update.status":
      return {
        ok: true,
        state: await loadUpdateState(),
        preferences: await loadUpdatePreferences()
      };
    case "update.check":
      return { ok: true, state: await runManagedUpdateCheck({ notify: false }) };
    case "update.preferences": {
      const preferences = await saveUpdatePreferences(message.payload || {});
      await scheduleUpdateAlarm(preferences.autoCheckEnabled);
      return { ok: true, preferences };
    }
    case "update.open-download-page":
      await chrome.tabs.create({ url: UPDATE_DOWNLOAD_PAGE });
      return { ok: true };
    default:
      return { ok: false, error: `unknown message type: ${message?.type || ""}` };
  }
}

async function initializeUpdateChecks(checkNow) {
  const preferences = await loadUpdatePreferences();
  await scheduleUpdateAlarm(preferences.autoCheckEnabled);
  const state = checkNow ? await runManagedUpdateCheck({ notify: false }) : await loadUpdateState();
  await updateActionBadge(state);
}

async function scheduleUpdateAlarm(enabled) {
  await chrome.alarms.clear(UPDATE_ALARM_NAME);
  if (enabled) {
    chrome.alarms.create(UPDATE_ALARM_NAME, {
      delayInMinutes: 2,
      periodInMinutes: UPDATE_CHECK_INTERVAL_MINUTES
    });
  }
}

async function runManagedUpdateCheck({ notify }) {
  const previous = await loadUpdateState();
  const state = await checkForManagedUpdate();
  await updateActionBadge(state);
  if (notify && state.status === "available" && state.latestVersion !== previous?.latestVersion) {
    const preferences = await loadUpdatePreferences();
    if (preferences.notificationsEnabled) {
      const notificationId = `willdeep-browser-update:${state.latestVersion}`;
      chrome.notifications.create(notificationId, {
        type: "basic",
        iconUrl: "icons/icon128.png",
        title: chrome.i18n.getMessage("updateNotificationTitle"),
        message: chrome.i18n.getMessage("updateNotificationMessage", [state.latestVersion])
      });
    }
  }
  return state;
}

async function updateActionBadge(state) {
  if (state?.status === "available") {
    await chrome.action.setBadgeBackgroundColor({ color: "#1677ff" });
    await chrome.action.setBadgeText({ text: "NEW" });
    return;
  }
  await chrome.action.setBadgeText({ text: "" });
}

async function nativePing() {
  if (!nativePort) {
    connectNativeHost();
  }
  if (!nativePort) {
    return { ok: false, connected: false, error: nativeConnectionError };
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

async function listTabs() {
  const tabs = await chrome.tabs.query({});
  return {
    ok: true,
    tabs: tabs.map((tab) => ({
      id: tab.id,
      window_id: tab.windowId,
      active: Boolean(tab.active),
      pinned: Boolean(tab.pinned),
      title: tab.title || "",
      url: tab.url || ""
    }))
  };
}

async function activateTab(payload) {
  const tabId = Number(payload.tabId);
  if (!Number.isInteger(tabId)) return { ok: false, error: "missing tabId" };
  const tab = await chrome.tabs.update(tabId, { active: true });
  if (tab.windowId) await chrome.windows.update(tab.windowId, { focused: true });
  return { ok: true, tab: { id: tab.id, window_id: tab.windowId, title: tab.title || "", url: tab.url || "" } };
}

async function navigateActiveTab(payload) {
  const url = normalizeNavigationURL(payload.url);
  const [active] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!active?.id) return { ok: false, error: "no active tab" };
  await chrome.tabs.update(active.id, { url });
  // tabs.update resolves before the navigation commits; returning then let a
  // follow-up page.read hit the old document's content script.
  const settled = await waitForTabComplete(active.id, NAVIGATION_SETTLE_TIMEOUT_MS);
  const tab = await chrome.tabs.get(active.id);
  return {
    ok: true,
    settled,
    tab: { id: tab.id, title: tab.title || "", url: tab.url || tab.pendingUrl || url, status: tab.status || "" }
  };
}

function waitForTabComplete(tabId, timeoutMs) {
  return new Promise((resolve) => {
    let finished = false;
    const finish = (value) => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      chrome.tabs.onUpdated.removeListener(listener);
      resolve(value);
    };
    const listener = (updatedId, changeInfo) => {
      if (updatedId === tabId && changeInfo.status === "complete") finish(true);
    };
    const timer = setTimeout(() => finish(false), timeoutMs);
    chrome.tabs.onUpdated.addListener(listener);
    // A cached page can finish before the listener is attached. While a
    // navigation is pending the tab carries `pendingUrl`, so an old page's
    // "complete" is not mistaken for the new one.
    chrome.tabs.get(tabId).then((tab) => {
      if (tab.status === "complete" && !tab.pendingUrl) finish(true);
    }).catch(() => finish(false));
  });
}

async function navigateHistory(payload) {
  const direction = String(payload.direction || "reload").toLowerCase();
  const [active] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!active?.id) return { ok: false, error: "no active tab" };
  if (direction === "back") await chrome.tabs.goBack(active.id);
  else if (direction === "forward") await chrome.tabs.goForward(active.id);
  else if (direction === "reload") await chrome.tabs.reload(active.id, { bypassCache: Boolean(payload.bypassCache) });
  else return { ok: false, error: "direction must be back, forward, or reload" };
  return { ok: true, tab_id: active.id, direction };
}

function normalizeNavigationURL(value) {
  const raw = String(value || "").trim();
  if (!raw) throw new Error("missing url");
  const candidate = /^https?:\/\//i.test(raw) ? raw : `https://${raw}`;
  const url = new URL(candidate);
  if (url.protocol !== "http:" && url.protocol !== "https:") throw new Error("only http and https URLs are supported");
  return url.href;
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
