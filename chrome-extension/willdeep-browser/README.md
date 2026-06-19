# WillDeep Browser Extension

> Version: 1.91.0-rc14

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

1. Build or locate `willdeep-agent`.
2. Copy `native-host/com.willdeep.browser_bridge.example.json` to:

   ```text
   ~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.willdeep.browser_bridge.json
   ```

3. Replace `path` with the absolute path to
   `native-host/willdeep-chrome-native-host`.
4. Load this directory from `chrome://extensions` with Developer Mode enabled.
5. Copy the unpacked extension ID into `allowed_origins`.
6. Ensure `willdeep-agent` is on `PATH`, or set `WILLDEEP_AGENT` in the wrapper
   script to the absolute binary path. The wrapper runs:

   ```text
   willdeep-agent chrome-native-host
   ```

For packaged releases, WillDeep should generate the native host manifest after
the extension ID is known.

## Safety

The default Chrome profile contains real cookies and active enterprise sessions.
Every Agent-facing write action should remain visible, logged, and approval
gated in the Mac app. The extension can be powerful; power is exactly why the UI
must keep domain allowlists and revocation obvious.
