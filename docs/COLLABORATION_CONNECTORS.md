# Collaboration Connectors

> Last updated: 2026-09-02 | Current version: v1.315.0-rc17

WillDeep treats Feishu, DingTalk, WeCom, and WeChat/Claw as collaboration
connectors. The Mac app owns local user intent, preview, and Keychain-backed
credentials. The relay owns SaaS callback intake and optional long-connection
clients for platforms that support server-initiated event delivery.

## Official Feishu/Lark CLI

Feishu defaults to the official `@larksuite/cli` path in the Mac settings UI.
This keeps app creation/configuration, user login, schema discovery, and most
document/message operations inside the official local CLI instead of asking the
model to assemble ad-hoc shell commands.

Recommended local setup:

```bash
npx --yes @larksuite/cli@latest install
lark-cli config init --new
lark-cli auth login --recommend
lark-cli auth status
```

WillDeep exposes the same capability to the Agent through the dedicated
`lark_cli` tool. Models pass only argument arrays, for example
`["auth", "status"]` or `["docs", "+create", "--dry-run"]`; the app adds the
`lark-cli` executable, renders a safe command preview, and classifies approval
risk before execution.

Approval rules:

- `auth status`, `config show`, `schema`, `--help`, and `--dry-run` are read-only.
- Create, send, update, publish, approve, and reject style operations require
  normal write approval because they can mutate Feishu data.
- Delete, revoke, permission, role, scope, token, and secret operations require
  dangerous confirmation.

The public relay remains useful for OAuth callback intake, QR setup pages, and
server-side long-connection event delivery. The official CLI path is the
preferred local setup and operation path when the user has Feishu installed and
can scan/login interactively.

## Public Relay

Default public base URL:

```text
https://fly.niuwoai.com
```

Run the relay from the existing Go agent:

```bash
willdeep-agent serve-collab-relay \
  --host 127.0.0.1 \
  --port 8899 \
  --public-base-url https://fly.niuwoai.com \
  --feishu-app-id "$WILLDEEP_FEISHU_APP_ID" \
  --feishu-app-secret-file /opt/willdeep/feishu-app-secret \
  --feishu-long-connection \
  --event-store-file /var/lib/willdeep/collab-relay-events.json \
  --token-file /opt/willdeep/collab-relay.token
```

Place Nginx, Caddy, or a cloud load balancer in front of it:

```text
https://fly.niuwoai.com/collab/health
https://fly.niuwoai.com/oauth/feishu/callback
https://fly.niuwoai.com/oauth/dingtalk/callback
https://fly.niuwoai.com/events/feishu
https://fly.niuwoai.com/events/dingtalk
```

Sensitive values stay out of the app settings and source tree:

- Relay poll token: file or environment on the server.
- Feishu/DingTalk app secret: macOS Keychain for desktop tokens, or a server
  secret file/environment for relay long-connection mode.
- OAuth access/refresh tokens: macOS Keychain.
- SaaS HTTPS callbacks must carry the Relay token as a Bearer token or protected
  query parameter at the edge. Prefer the authenticated Feishu long connection;
  production signature/encryption verification remains required before exposing
  a platform callback directly.
- Feishu setup QR requires only the public app id on the relay
  (`WILLDEEP_FEISHU_APP_ID` or `--feishu-app-id`). It does not require Redis or
  a database. Callback events are retained in the Relay's mode-0600 durable
  journal until the desktop explicitly acknowledges them; the same journal
  persists received, acknowledged, dropped, and deduplicated counters.

### Feishu Event Delivery

Feishu can deliver robot events in two ways:

- **Long connection**: select "use long connection to receive events" in the
  Feishu app console. The relay starts the official Feishu SDK client with
  `WILLDEEP_FEISHU_APP_ID` plus `WILLDEEP_FEISHU_APP_SECRET` or
  `--feishu-app-secret-file`, then queues events for `/events/poll`. This mode
  does not require a public event callback URL or callback encryption strategy.
- **HTTPS callback**: select "send events to developer server" and register
  `https://fly.niuwoai.com/events/feishu?token=<relay-token>`. This remains useful
  when the relay should receive events through a public edge, but it requires
  reachable HTTPS, edge log redaction for the query token, and production
  signature/encryption verification. A reverse proxy that injects a Bearer token
  after platform verification is preferable.

The relay defaults long-connection subscriptions to `im.message.receive_v1` and
`application.bot.menu_v6`. Override with
`WILLDEEP_FEISHU_LONG_CONNECTION_EVENT_TYPES` or
`--feishu-long-connection-event-types` when the app enables more Feishu events.

## Feishu Target Depth

Feishu is the primary L4/L5 connector.

### L4 Document Creation And Editing

Expected capabilities:

- Create a new Feishu document.
- Write headings, paragraphs, tables, lists, and task lists.
- Generate docs from a local file, transcript, meeting notes, or GitHub issue.
- Update specific sections in an existing document.
- Generate PRDs, weekly reports, meeting minutes, and technical plans.
- Send the resulting document link to a Feishu chat.

Implementation shape:

1. Mac app prepares a short-lived setup session.
2. Settings immediately shows a WillDeep Cloud Relay setup QR code at
   `https://fly.niuwoai.com/connectors/feishu/setup?...`, so the user can scan
   it with Feishu without filling OAuth fields first.
3. The setup page handles the Feishu app authorization path. Advanced users can
   still provide a custom Feishu App ID to generate a direct Open Platform OAuth
   URL.
4. Feishu redirects to the relay.
5. Relay redirects the browser back to
   `willdeep://oauth/feishu/callback?...`.
6. Mac exchanges the authorization code for tokens and stores them in Keychain.
7. AI produces an internal document plan.
8. User previews the generated document.
9. WillDeep writes blocks through Feishu Docs OpenAPI.
10. WillDeep sends the link to the configured Feishu chat when approved.

For Feishu, the normal Settings path should expose the QR code first, plus
refresh/open/copy setup actions. App ID, tenant ID, redirect URI,
authorization URL, Keychain reference, and credential cleanup are diagnostics
and belong behind the advanced configuration disclosure.

### L5 Collaboration Agent

Expected flow:

```text
GitHub issue -> generate Feishu PRD -> send review request -> collect comments
-> update document -> generate implementation tasks
```

The relay receives Feishu events, writes them to a durable local journal, and
exposes authenticated poll/ACK delivery for the Mac side or a future worker.
Feishu events may arrive through either the protected `/events/feishu` callback
or the official SDK long connection. PostgreSQL/Redis can replace the journal
once multi-instance callback volume justifies it.

## DingTalk Target Depth

DingTalk is the second priority connector.

Expected capabilities:

- Active tool calls through the official DingTalk MCP server:
  `npx -y dingtalk-mcp@latest`.
- The MCP server is configured as a stdio user MCP with
  `DINGTALK_Client_ID` and `DINGTALK_Client_Secret` environment variables from
  the DingTalk developer console. Keep the secret in Keychain or local private
  config, never in git.
- OAuth callback through `https://fly.niuwoai.com/oauth/dingtalk/callback`.
- Bot/webhook notifications for build results, review requests, and task
  summaries.
- Event callback intake through `https://fly.niuwoai.com/events/dingtalk`.
- Approval/task workflow hooks after the bot and event paths stabilize.

DingTalk does not currently have a lark-cli-style official CLI in WillDeep's
integration model. Prefer MCP for active operations, and use DingTalk Stream
Mode SDK or relay callbacks for inbound robot events. Callback
encryption/signature verification should be enabled before production traffic.
The current relay stores selected headers and raw JSON so the verification
layer can be added without changing the Mac app contract.

## Relay API

### Health

```http
GET /collab/health
```

Returns version, protocol, OAuth callback URLs, event callback URLs, and queue
depth. The response also includes event transport status such as
`event_transports.feishu_long_connection`.

### OAuth Callback

```http
GET /oauth/{platform}/callback?code=...&state=...
```

Supported platforms:

- `feishu`
- `dingtalk`
- `wecom`

Default behavior is a `302` redirect to:

```text
willdeep://oauth/{platform}/callback?code=...&state=...
```

Use `format=json` during tests to return the desktop redirect URL as JSON.

### Event Callback

```http
POST /events/{platform}
Authorization: Bearer <relay-token>
```

The relay accepts authenticated JSON bodies up to 1 MiB. A top-level
`challenge` receives the platform's raw verification response after transport
authentication succeeds.

### Poll Events

```http
GET /events/poll
Authorization: Bearer <relay-token>
```

Returns up to the requested number of queued events without removing them.
Consumers must durably persist each event before acknowledging it:

```http
POST /events/ack
Authorization: Bearer <relay-token>
Content-Type: application/json

{"event_ids":["event-id"]}
```

Only acknowledged IDs are removed from the durable journal. Poll and ACK
responses expose `X-WillDeep-Relay-Protocol: collab-relay.v2`; the current Mac
client rejects older destructive-poll relays. When a platform supplies its own
event or message id, the relay hashes it into a stable opaque relay id so a
platform retry does not append a second unacknowledged copy.

### Desktop Runtime Event Routing

WillDeep 1.315.0-rc17 can poll this endpoint from **Settings → Connectors →
Runtime Event Routing**. The relay token is stored in macOS Keychain. Incoming
events are routed to a dedicated background Event Orchestrator session and
enter the host-owned Runtime event kernel; see
[`AGENT_RUNTIME_KERNEL.md`](AGENT_RUNTIME_KERNEL.md).

Transport authentication does not make the platform payload trusted. The
desktop always treats relay bodies as untrusted data, prevents them from
requesting hard preemption, and keeps every terminal/file/browser/MCP action
behind the existing approval policy.

## Production Checklist

- [ ] DNS `fly.niuwoai.com` points to the relay edge.
- [ ] TLS certificate is active.
- [ ] `/collab/health` returns `X-WillDeep-App-Version` and
  `X-WillDeep-Server-Version` plus `X-WillDeep-Relay-Protocol`; upstream proxies may add their own
  `X-App-Version` / `X-Server-Version` headers.
- [ ] OAuth redirect URLs are registered in Feishu and DingTalk app consoles.
- [ ] Feishu event delivery is configured as either long connection or HTTPS
  callback.
- [ ] Event callback URLs are registered in Feishu and DingTalk app consoles
  when HTTPS callback delivery is selected.
- [ ] `--event-store-file` points to a persistent, mode-0600-capable volume and
  survives Relay restarts.
- [ ] Relay token is stored outside git.
- [ ] Feishu/DingTalk app secrets are stored in macOS Keychain.
- [ ] Feishu app secret is stored outside git when long connection is enabled.
- [ ] Feishu event signature verification is implemented before production when
  HTTPS callback delivery is selected.
- [ ] DingTalk encrypted callback verification is implemented before
  production.
