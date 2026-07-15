import { currentExtensionVersion } from "./update_checker.js";

const elements = {
  badge: document.getElementById("update-badge"),
  summary: document.getElementById("update-summary"),
  currentVersion: document.getElementById("current-version"),
  latestVersion: document.getElementById("latest-version"),
  lastChecked: document.getElementById("last-checked"),
  checkButton: document.getElementById("check-update"),
  downloadButton: document.getElementById("open-download"),
  autoCheck: document.getElementById("auto-check"),
  notifications: document.getElementById("notifications"),
  channel: document.getElementById("update-channel"),
  hostStatus: document.getElementById("host-status"),
  helpButton: document.getElementById("open-help")
};

function t(key, substitutions) {
  return chrome.i18n.getMessage(key, substitutions) || key;
}

function localize() {
  document.documentElement.lang = chrome.i18n.getUILanguage();
  document.title = t("optionsTitle");
  document.querySelectorAll("[data-i18n]").forEach((node) => {
    node.textContent = t(node.dataset.i18n);
  });
}

async function request(type, payload = {}) {
  return chrome.runtime.sendMessage({ type, payload });
}

function renderState(state) {
  const status = state?.status || "checking";
  const statusKeys = {
    available: ["updateStatusAvailable", "updateAvailableDetail"],
    current: ["updateStatusCurrent", "updateCurrentDetail"],
    error: ["updateStatusError", "updateErrorDetail"],
    checking: ["updateStatusChecking", "updateStatusCheckingDetail"]
  };
  const [badgeKey, summaryKey] = statusKeys[status] || statusKeys.checking;
  elements.badge.className = `status-badge ${status}`;
  elements.badge.textContent = t(badgeKey);
  elements.summary.textContent = status === "available"
    ? t(summaryKey, [state.latestVersion])
    : t(summaryKey);
  elements.currentVersion.textContent = state?.currentVersion || currentExtensionVersion();
  elements.latestVersion.textContent = state?.latestVersion || "—";
  elements.lastChecked.textContent = state?.checkedAt
    ? new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(new Date(state.checkedAt))
    : "—";
  elements.downloadButton.hidden = status !== "available";
}

function renderPreferences(preferences) {
  elements.autoCheck.checked = preferences?.autoCheckEnabled !== false;
  elements.notifications.checked = preferences?.notificationsEnabled !== false;
  elements.channel.value = preferences?.channel === "beta" ? "beta" : "stable";
}

async function load() {
  localize();
  elements.currentVersion.textContent = currentExtensionVersion();
  const statusResponse = await request("update.status");
  renderPreferences(statusResponse?.preferences || {});
  renderState(statusResponse?.state);
  await checkNow();
  await checkHost();
}

async function checkNow() {
  elements.checkButton.disabled = true;
  renderState({ status: "checking", currentVersion: currentExtensionVersion() });
  try {
    const response = await request("update.check");
    renderState(response?.state);
  } catch {
    renderState({ status: "error", currentVersion: currentExtensionVersion() });
  } finally {
    elements.checkButton.disabled = false;
  }
}

async function checkHost() {
  try {
    const response = await request("native.ping");
    elements.hostStatus.textContent = response?.ok ? t("statusConnected") : t("statusDisconnected");
  } catch {
    elements.hostStatus.textContent = t("statusDisconnected");
  }
}

async function savePreferences() {
  const response = await request("update.preferences", {
    autoCheckEnabled: elements.autoCheck.checked,
    notificationsEnabled: elements.notifications.checked,
    channel: elements.channel.value
  });
  renderPreferences(response?.preferences || {});
  await checkNow();
}

elements.checkButton.addEventListener("click", checkNow);
elements.downloadButton.addEventListener("click", () => request("update.open-download-page"));
elements.helpButton.addEventListener("click", () => request("update.open-download-page"));
elements.autoCheck.addEventListener("change", savePreferences);
elements.notifications.addEventListener("change", savePreferences);
elements.channel.addEventListener("change", savePreferences);

void load();
