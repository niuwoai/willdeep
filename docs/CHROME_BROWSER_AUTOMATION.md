# Chrome Browser Automation

> Last updated: 2026-07-15 | Current version: v1.163.0-rc1

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

WillDeep creates or repairs this manifest whenever the app launches. The Chrome
extension includes a stable public manifest key, so unpacked installs always use
extension ID `cokjjphgiflfnemlgjaeiicclgkijnia` and the manifest can safely use
a concrete `allowed_origins` entry.

The manifest points to a generated wrapper script:

```text
~/Library/Application Support/WillDeep/ChromeNativeHost/willdeep-chrome-native-host
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

`WILLDEEP_CHROME_BRIDGE_PORT` can override the port.

The bridge is authenticated (1.396.0-rc3). Each time the host wins the port it
writes a fresh random token to
`~/Library/Application Support/WillDeep/ChromeNativeHost/bridge-token` (mode
0600, atomic rename; `WILLDEEP_CHROME_BRIDGE_TOKEN_FILE` overrides the path).
Every request must carry it in `X-WillDeep-Bridge-Token`. The bridge also
rejects requests with an `Origin` header (web pages), a `Host` other than
`127.0.0.1:<port>` / `localhost:<port>` (DNS rebinding), and POST bodies that
are not `application/json` (CORS-simple `text/plain` posts). A host that fails
to bind the port — e.g. a second Chrome profile — does not touch the token.

Agent tab (1.397.0-rc2):

- Page and tab commands no longer re-query "the active tab" each time. The
  extension keeps the tab the Agent is working in (`willdeepAgentTabId` in
  `chrome.storage.session`, so a service-worker restart keeps it) and targets,
  in order: an explicit `payload.tabId` (which also becomes the Agent's tab),
  the pinned Agent tab, or the active tab (which then gets pinned).
  `tab.activate` and `tab.navigate` move the pin. A user switching tabs
  mid-task therefore no longer redirects the Agent's clicks and typing.
- Every targeted response carries `tab_id`, `tab_title`, `tab_url`; if the
  pinned tab was closed the command falls back to the active tab and adds a
  `retargeted` note. An unknown explicit `tabId` is an error, never a silent
  fallback. `tab.list` reports `agent_tab_id` and an `agent_target` flag.
- `tab.capture` can only grab the tab a window is showing, so a background
  Agent tab is refused with instructions instead of switching the user's tab.
- The popup's own buttons send `useActiveTab: true`: they act on the page the
  user is looking at and never move the Agent's pin.
- Behavior is covered by `scripts/chrome_extension_agent_tab_test.rb`, which
  loads the real service worker in Node with a fake `chrome` API.

Resilience (1.396.0-rc5):

- A host that loses the port race retries the bind every 5 s, so closing the
  profile that owned the bridge hands it to another open profile instead of
  leaving the bridge dark. The owner deletes its token file on shutdown
  unless a newer host already replaced it.
- The extension reconnects the native port on every service-worker wake-up
  and, after a disconnect, retries through a 30-second `chrome.alarms` alarm.
  Opening the popup is no longer needed to revive the bridge.
- `tab.navigate` waits for the tab to reach `status: "complete"` (up to 10 s)
  and returns the real URL/title plus `settled`. The app gives navigation a
  15 s bridge budget; every HTTP request outlives the bridge timeout by 5 s,
  and a timeout is reported as "Chrome did not answer; the action may still
  have run" instead of "install the extension".

The request endpoint accepts:

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
