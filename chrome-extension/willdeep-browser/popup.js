function t(key) {
  return chrome.i18n.getMessage(key) || key;
}

function localize() {
  document.querySelectorAll("[data-i18n]").forEach((node) => {
    node.textContent = t(node.dataset.i18n);
  });
}

function setStatus(ok, text) {
  const dot = document.getElementById("status-dot");
  const label = document.getElementById("status-text");
  dot.classList.toggle("ok", ok === true);
  dot.classList.toggle("fail", ok === false);
  label.textContent = text;
}

function showResult(value) {
  document.getElementById("result").textContent = JSON.stringify(value, null, 2);
}

async function request(type, payload = {}) {
  return chrome.runtime.sendMessage({ type, payload });
}

async function checkHost() {
  try {
    const response = await request("native.ping");
    setStatus(Boolean(response?.ok), response?.ok ? t("statusConnected") : t("statusDisconnected"));
  } catch {
    setStatus(false, t("statusDisconnected"));
  }
}

async function checkUpdateStatus() {
  try {
    const response = await request("update.status");
    const state = response?.state;
    if (state?.status === "available") {
      document.getElementById("update-version").textContent = state.latestVersion;
      document.getElementById("update-banner").hidden = false;
    }
  } catch {
    document.getElementById("update-banner").hidden = true;
  }
}

localize();
checkHost();
checkUpdateStatus();

// Popup buttons act on the page the user is looking at, not on the tab the
// Agent is working in, and must not move the Agent's pinned tab.
document.getElementById("read-page").addEventListener("click", async () => {
  showResult(await request("page.read", { useActiveTab: true }));
});

document.getElementById("read-selection").addEventListener("click", async () => {
  showResult(await request("page.selection", { useActiveTab: true }));
});

document.getElementById("capture-tab").addEventListener("click", async () => {
  showResult(await request("tab.capture", { useActiveTab: true }));
});

document.getElementById("update-banner").addEventListener("click", () => {
  request("update.open-download-page");
});

document.getElementById("open-options").addEventListener("click", () => {
  chrome.runtime.openOptionsPage();
});
