export const UPDATE_APP_ID = "willdeep-browser-extension";
export const UPDATE_PLATFORM = "chrome";
export const UPDATE_ENDPOINT = "https://some.im/api/v1/public/app-updates/latest";
export const UPDATE_DOWNLOAD_PAGE = "https://some.im/products/willdeep/browser-extension";
export const UPDATE_ALARM_NAME = "willdeep-browser-extension-update-check";
export const UPDATE_CHECK_INTERVAL_MINUTES = 6 * 60;
export const UPDATE_STATE_KEY = "managedUpdateState";
export const UPDATE_PREFERENCES_KEY = "managedUpdatePreferences";

const DEFAULT_PREFERENCES = Object.freeze({
  autoCheckEnabled: true,
  notificationsEnabled: true,
  channel: "stable"
});

export function currentExtensionVersion() {
  const manifest = chrome.runtime.getManifest();
  return String(manifest.version_name || manifest.version || "").trim();
}

export async function loadUpdatePreferences() {
  const stored = await chrome.storage.sync.get(UPDATE_PREFERENCES_KEY);
  const value = stored?.[UPDATE_PREFERENCES_KEY] || {};
  return normalizePreferences({ ...DEFAULT_PREFERENCES, ...value });
}

export async function saveUpdatePreferences(patch) {
  const current = await loadUpdatePreferences();
  const next = normalizePreferences({ ...current, ...patch });
  await chrome.storage.sync.set({ [UPDATE_PREFERENCES_KEY]: next });
  return next;
}

export async function loadUpdateState() {
  const stored = await chrome.storage.local.get(UPDATE_STATE_KEY);
  return stored?.[UPDATE_STATE_KEY] || null;
}

export async function checkForManagedUpdate() {
  const currentVersion = currentExtensionVersion();
  const preferences = await loadUpdatePreferences();
  const url = new URL(UPDATE_ENDPOINT);
  url.searchParams.set("app_id", UPDATE_APP_ID);
  url.searchParams.set("platform", UPDATE_PLATFORM);
  url.searchParams.set("channel", preferences.channel);
  url.searchParams.set("current_version", currentVersion);

  let state;
  try {
    const response = await fetch(url, {
      method: "GET",
      cache: "no-store",
      credentials: "omit",
      headers: {
        Accept: "application/json",
        "X-App-Version": currentVersion
      }
    });
    if (!response.ok) {
      throw new Error(`update endpoint returned ${response.status}`);
    }
    const json = await response.json();
    const payload = json?.data || json || {};
    const item = payload?.item || null;
    const latestVersion = String(item?.latest_version || item?.version || payload?.latest_version || "").trim();
    const updateAvailable = Boolean(
      item && latestVersion && (payload?.update_available ?? compareVersions(latestVersion, currentVersion) > 0)
    );
    state = {
      status: updateAvailable ? "available" : "current",
      currentVersion,
      latestVersion: latestVersion || currentVersion,
      downloadURL: updateAvailable ? validatedHTTPSURL(item?.download_url) : null,
      downloadPageURL: UPDATE_DOWNLOAD_PAGE,
      releaseNotes: updateAvailable ? String(item?.release_notes || item?.notes || "").trim() : "",
      sha256: updateAvailable ? String(item?.sha256 || "").trim() : "",
      fileSizeBytes: normalizeFileSize(item?.file_size_bytes),
      checkedAt: new Date().toISOString(),
      channel: preferences.channel
    };
  } catch (error) {
    state = {
      status: "error",
      currentVersion,
      latestVersion: "",
      downloadURL: null,
      downloadPageURL: UPDATE_DOWNLOAD_PAGE,
      releaseNotes: "",
      sha256: "",
      fileSizeBytes: null,
      checkedAt: new Date().toISOString(),
      channel: preferences.channel,
      error: String(error?.message || error)
    };
  }

  await chrome.storage.local.set({ [UPDATE_STATE_KEY]: state });
  return state;
}

export function compareVersions(left, right) {
  const a = parseVersion(left);
  const b = parseVersion(right);
  if (!a || !b) {
    return String(left).localeCompare(String(right), undefined, { numeric: true, sensitivity: "base" });
  }
  for (let index = 0; index < Math.max(a.numbers.length, b.numbers.length); index += 1) {
    const delta = (a.numbers[index] || 0) - (b.numbers[index] || 0);
    if (delta !== 0) {
      return delta < 0 ? -1 : 1;
    }
  }
  if (!a.prerelease && b.prerelease) {
    return 1;
  }
  if (a.prerelease && !b.prerelease) {
    return -1;
  }
  if (!a.prerelease && !b.prerelease) {
    return 0;
  }
  const nameDelta = a.prerelease.name.localeCompare(b.prerelease.name);
  if (nameDelta !== 0) {
    return nameDelta < 0 ? -1 : 1;
  }
  return Math.sign(a.prerelease.number - b.prerelease.number);
}

function parseVersion(value) {
  const match = String(value || "").trim().replace(/^[vV]/, "").match(/^(\d+(?:\.\d+)*)(?:-([a-zA-Z-]+)(\d*)?)?$/);
  if (!match) {
    return null;
  }
  return {
    numbers: match[1].split(".").map((part) => Number(part)),
    prerelease: match[2]
      ? { name: match[2].toLowerCase(), number: Number(match[3] || 0) }
      : null
  };
}

function normalizePreferences(value) {
  return {
    autoCheckEnabled: value.autoCheckEnabled !== false,
    notificationsEnabled: value.notificationsEnabled !== false,
    channel: value.channel === "beta" ? "beta" : "stable"
  };
}

function validatedHTTPSURL(value) {
  try {
    const url = new URL(String(value || ""));
    return url.protocol === "https:" ? url.toString() : null;
  } catch {
    return null;
  }
}

function normalizeFileSize(value) {
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : null;
}
