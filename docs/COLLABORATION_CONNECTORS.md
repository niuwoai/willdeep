# Collaboration Connectors

> Last updated: 2026-06-18 | Current version: v1.90.0-rc4

WillDeep treats Feishu, DingTalk, WeCom, and WeChat/Claw as collaboration
connectors. The Mac app owns local user intent, preview, and Keychain-backed
credentials. The public relay owns HTTPS callback endpoints required by SaaS
platforms.

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
- Feishu/DingTalk app secret: macOS Keychain via `AgentCredentialStore`.
- OAuth access/refresh tokens: macOS Keychain.
- SaaS event verification secrets: future server-side secret store, not
  UserDefaults.

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

1. Mac app prepares OAuth with redirect URI
   `https://fly.niuwoai.com/oauth/feishu/callback`.
2. Feishu redirects to the relay.
3. Relay redirects the browser back to
   `willdeep://oauth/feishu/callback?...`.
4. Mac exchanges the authorization code for tokens and stores them in Keychain.
5. AI produces an internal document plan.
6. User previews the generated document.
7. WillDeep writes blocks through Feishu Docs OpenAPI.
8. WillDeep sends the link to the configured Feishu chat when approved.

### L5 Collaboration Agent

Expected flow:

```text
GitHub issue -> generate Feishu PRD -> send review request -> collect comments
-> update document -> generate implementation tasks
```

The relay receives Feishu events, queues them, and exposes authenticated polling
for the Mac side or a future worker. The current relay intentionally keeps an
in-memory queue; production storage can become PostgreSQL/Redis once callback
volume justifies it.

## DingTalk Target Depth

DingTalk is the second priority connector.

Expected capabilities:

- OAuth callback through `https://fly.niuwoai.com/oauth/dingtalk/callback`.
- Bot/webhook notifications for build results, review requests, and task
  summaries.
- Event callback intake through `https://fly.niuwoai.com/events/dingtalk`.
- Approval/task workflow hooks after the bot and event paths stabilize.

DingTalk callback encryption/signature verification should be enabled before
production traffic. The current relay stores selected headers and raw JSON so
the verification layer can be added without changing the Mac app contract.

## Relay API

### Health

```http
GET /collab/health
```

Returns version, protocol, OAuth callback URLs, event callback URLs, and queue
depth.

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
```

The relay accepts JSON bodies up to 1 MiB. If the body contains a top-level
`challenge`, it returns the raw challenge response for platform URL
verification.

### Poll Events

```http
GET /events/poll
Authorization: Bearer <relay-token>
```

Returns queued events and removes the returned batch from memory.

## Production Checklist

- [ ] DNS `fly.niuwoai.com` points to the relay edge.
- [ ] TLS certificate is active.
- [ ] `/collab/health` returns `X-App-Version` and `X-Server-Version`.
- [ ] OAuth redirect URLs are registered in Feishu and DingTalk app consoles.
- [ ] Event callback URLs are registered in Feishu and DingTalk app consoles.
- [ ] Relay token is stored outside git.
- [ ] Feishu/DingTalk app secrets are stored in macOS Keychain.
- [ ] Feishu event signature verification is implemented before production.
- [ ] DingTalk encrypted callback verification is implemented before
  production.
