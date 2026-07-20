# WillDeep Browser Extension

> Version: 1.192.0-rc15

This extension is the default Chrome profile bridge for WillDeep. It is meant
for workflows where the user wants WillDeep to operate already-signed-in pages,
such as Feishu, DingTalk, GitHub, CMS, dashboards, and internal tools.

## Shape

- Manifest V3 extension.
- Uses `nativeMessaging` to talk to `willdeep-agent chrome-native-host`.
- Uses content-script commands for page reading, selection, clicks, and typing.
- Reserves `chrome.debugger` for high-risk CDP commands on explicitly selected
  tabs.

## Install For Development

1. Build and launch WillDeep once. WillDeep registers its bundled
   `willdeep-agent` as the Chrome Native Messaging host automatically.
2. Load this directory from `chrome://extensions` with Developer Mode enabled.
3. Verify that the extension ID is `cokjjphgiflfnemlgjaeiicclgkijnia`. The
   checked-in manifest key keeps this ID stable across folders and updates.

For source-only agent development without the WillDeep app, copy
`native-host/com.willdeep.browser_bridge.example.json` to:

```text
~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.willdeep.browser_bridge.json
```

Then replace `path` with the absolute path to
`native-host/willdeep-chrome-native-host`. Ensure `willdeep-agent` is on
`PATH`, or set `WILLDEEP_AGENT` in the wrapper script to the absolute binary
path. The wrapper runs:

```text
willdeep-agent chrome-native-host
```

## Install From some.im

1. Install or update WillDeep, then launch it once so the native host is
   registered under the current macOS user.
2. Open `https://some.im/products/willdeep/browser-extension`.
3. Download and unzip the current release.
4. Open `chrome://extensions`, enable Developer Mode, and choose **Load unpacked**.
5. Select the unzipped `WillDeep-Browser` directory.
6. If an older unpacked build is present, remove it before loading this build.

This extension is not distributed through Chrome Web Store. Chrome therefore
does not permit a silent in-place update. The Options page checks the managed
some.im release plan after it opens, shortly after Chrome starts, and every six
hours. When a newer version is available, it shows a badge/notification and
opens the download page for an explicit manual replacement.

The managed release target is:

- `app_id`: `willdeep-browser-extension`
- `platform`: `chrome`
- `channel`: `stable` or `beta`
- public feed: `GET /api/v1/public/app-updates/latest`

For packaged releases, WillDeep writes the native host launcher and manifest at
app launch. The extension ID is deterministic, so moving or replacing the
unpacked directory does not invalidate `allowed_origins`.

## Safety

The default Chrome profile contains real cookies and active enterprise sessions.
Every Agent-facing write action should remain visible, logged, and approval
gated in the Mac app. The extension can be powerful; power is exactly why the UI
must keep domain allowlists and revocation obvious.
