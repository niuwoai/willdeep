# Chrome Browser Automation

> Last updated: 2026-06-19 | Current version: v1.91.0-rc13

WillDeep supports two Chrome automation modes:

- Default-profile extension mode for already-signed-in business sites.
- Isolated Chrome DevTools Protocol mode for repeatable automation and testing.

The default-profile path is intentionally extension-based. Modern Chrome no
longer respects `--remote-debugging-port` or `--remote-debugging-pipe` when they
target the default Chrome data directory. This protects cookies and credentials,
so WillDeep should not try to bypass it.

## Default Profile Mode

Directory:

```text
chrome-extension/willdeep-browser
```

Capabilities:

- Read the active tab URL, title, selected text, page text, links, and form
  summaries.
- Click and type through content-script commands.
- Capture the visible tab.
- Reserve `chrome.debugger` for explicit high-risk CDP commands on the selected
  tab.
- Use Chrome Native Messaging to connect to `willdeep-agent chrome-native-host`.

This mode can use the user's existing login sessions because the extension is
installed in the user's normal Chrome profile.

## Native Host

Chrome starts a native host process through a registered manifest:

```text
~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.willdeep.browser_bridge.json
```

The manifest points to a wrapper script:

```text
chrome-extension/willdeep-browser/native-host/willdeep-chrome-native-host
```

The wrapper runs:

```text
willdeep-agent chrome-native-host
```

Native Messaging frames are JSON messages with a 32-bit little-endian length
prefix. The first protocol version is `chrome-native-host.v1`.

The native host also opens a loopback HTTP bridge for the Mac app:

```text
GET  http://127.0.0.1:8797/chrome/health
POST http://127.0.0.1:8797/chrome/request
```

`WILLDEEP_CHROME_BRIDGE_PORT` can override the port. The request endpoint
accepts:

```json
{
  "type": "page.read",
  "payload": { "maxChars": 20000 },
  "timeout_ms": 8000
}
```

The bridge forwards the request to the extension over Native Messaging and
waits for the extension reply.

## Isolated CDP Mode

For automated tests and repeatable browser work, launch Chrome with a dedicated
profile:

```text
/Applications/Google Chrome.app/Contents/MacOS/Google Chrome \
  --remote-debugging-port=0 \
  --remote-debugging-address=127.0.0.1 \
  --user-data-dir="$HOME/Library/Application Support/WillDeep/ChromeProfiles/agent" \
  --no-first-run \
  --no-default-browser-check
```

This mode should remain separate from default-profile extension mode. It is
cleaner for screenshots, scraping public pages, and deterministic browser tasks.

## Agent Tools

Read tier:

- `chrome_status`
- `chrome_read_page`
- `chrome_read_selection`

Write tier:

- `chrome_click`
- `chrome_type`
- `chrome_capture_tab`

Danger tier:

- `chrome_debugger_command`
- cookie/session inspection
- downloads or file uploads
- operations on banking, identity, admin, and credential-management domains

All write and danger tier calls must be visible in the transcript and approval
gated unless a user explicitly grants a domain-scoped allow rule.

## Safety Checklist

- [ ] Extension installed only by explicit user action.
- [ ] Native host manifest uses a concrete extension ID in `allowed_origins`.
- [ ] Mac app shows whether the default-profile bridge is connected.
- [ ] Domain allowlist is visible and revocable.
- [ ] Page reads are capped and scrubbed before sending to the model.
- [ ] Form values and cookies are never read by default.
- [ ] Debugger attach always requires explicit approval.
