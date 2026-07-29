# WillDeep Mobile Gateway Requirements

> Last updated: 2026-07-28 | Target version: v1.210.0-rc20

## Summary

Mobile Gateway lets an Android client connect to WillDeep over the default public relay at `https://j.niuwoai.com`, or over the local network as a fallback. The phone is a display and control surface; the Mac remains the authority for Agent execution, tool approval, patch application, workspace access, and safety gates.

This Mac repository implements the Go gateway, Swift desktop peer, protocol contract, and Umeng U-Push trigger path. The Android client is developed in the separate `willdeep-android` repository; the public relay is provided by `cdnproxy` at `/ws/broadcast/*`, while this repository still does not allow direct mobile access to filesystem and shell APIs.

## Transport Modes

Since v1.129.0-rc24 the gateway has two selectable transports (Settings → Mobile Gateway → Connection):

- **Internet relay (default).** No local process runs. The Swift desktop peer connects directly to the relay room (`wss://j.niuwoai.com/ws/broadcast/{room}`) and the app builds the QR pairing payload itself from its own relay settings (`relay_base_url` / `relay_room` / `relay_token`). The phone joins the same room with the shared `relay_token` — works off the local network with nothing to install. Liveness is the desktop peer's own WebSocket state (no `/mobile/health`). De-authorization is all-or-nothing: rotate the room + token, which forces every paired device to re-scan. Content is transport-encrypted (WSS) but not yet end-to-end — see [MOBILE_GATEWAY_E2E_ENCRYPTION_DESIGN.md](MOBILE_GATEWAY_E2E_ENCRYPTION_DESIGN.md).
- **Local network gateway (fallback, off by default).** Launches the bundled Go `willdeep-agent serve-mobile` process for same-network HTTP pairing (`/mobile/pair/claim`) with per-device tokens and per-device revoke. Use offline / on isolated networks, or when the phone needs the HTTP claim flow. This is the pre-rc24 behavior, now opt-in.

The Go gateway does **not** itself dial the relay; in the pre-rc24 design it only advertised the relay coordinates inside the pairing payload. The relay bus is, and always was, the Swift desktop peer connecting directly. That is why relay mode can run with no Go process at all.

The HTTP API, pairing, device, and WebSocket sections below describe the **local network gateway** transport. In relay mode those HTTP endpoints do not exist; the QR payload's `relay_*` fields are the entire pairing contract.

## Product Goals

- Allow the Mac to expose an opt-in gateway for paired mobile devices, with LAN fallback and default public relay support.
- Pair a device by scanning a short-lived QR payload generated on the Mac.
- Let a paired device subscribe to Agent session events and send control commands.
- Keep Agent decisions inside the desktop app so mobile commands reuse existing Plan gate, danger confirmation, workspace path guard, MCP trust, patch review, and approval behavior.
- Make the protocol stable enough for a native Android app to implement later.

## Non-Goals

- No Android project in this phase.
- No same-network anonymous access.
- No mobile-side model provider credentials.
- No push provider server secrets in git, app logs, QR payloads, or mobile WebSocket payloads.
- No direct mobile calls to `/v1/fs/*`, `/v1/run/*`, or other remote-runtime execution APIs.

## Gateway Roles

### Desktop Peer

The Swift macOS app connects to the gateway as the desktop peer using the desktop bearer token. The first desktop peer bridge is implemented in `AgentMobileGatewayBridge.swift`: it decodes gateway envelopes, routes supported mobile commands back through `AppState`, and publishes state snapshots/events through the gateway. It is the only peer allowed to:

- fetch or rotate the current pairing payload;
- revoke devices;
- receive mobile commands;
- publish desktop events such as session snapshots, message deltas, tool states, patch proposals, and worktree updates.
- consume mobile approval decisions and route them back through the existing macOS tool / patch approval machinery.

The current Swift bridge supports the first command set needed for phone-to-Mac task dispatch:

- `session.list`
- `session.create`
- `session.select`
- `message.send`
- `turn.stop`
- `tool.decide`
- `patch.decide`
- `diff.get`
- `job.kill`
- `file.read`
- `queue.update`
- `capabilities.get`
- `push.register`

Commands that touch files and queues remain desktop-mediated and must not bypass existing safety gates.

`push.register` is a local capability command. Android sends its remote-push provider and device token after the SDK registration succeeds. In local network gateway mode, the Go gateway stores that token and acknowledges the command without forwarding it to Swift. In internet relay mode, the Swift desktop peer receives the command, stores the token in local user defaults, and acknowledges it.

## Remote Push

WillDeep uses Umeng U-Push as the first remote push provider. The client contract is intentionally small: Android registers its Umeng device token with `push.register`, and the Mac triggers a short custom payload when the desktop needs attention.

Mac-side configuration is local-only. Put values in environment variables or in an ignored `local.properties` file:

```properties
UMENG_PUSH_ENABLED=true
UMENG_APPKEY=your_umeng_appkey
UMENG_APP_MASTER_SECRET=your_umeng_app_master_secret
UMENG_PRODUCTION_MODE=false
```

`UMENG_MASTER_SECRET` is accepted as an alias for `UMENG_APP_MASTER_SECRET`; `UMENG_MESSAGE_SECRET` is accepted only as a local-development fallback because some dashboards label secrets differently. Server-side secrets must not be written to tracked source files.

The Android-to-Mac registration command:

```json
{
  "type": "push.register",
  "payload": {
    "provider": "umeng",
    "client_id": "android-umeng-device-token",
    "app_id": "umeng-appkey",
    "platform": "android",
    "app_version": "1.22.0-rc3"
  }
}
```

Mac triggers remote push for desktop attention events:

- `tool.pending`
- `patch.upsert`

The custom payload contains only routing and display-safe summary fields such as `target_type`, `target_id`, `session_id`, `title`, `summary`, `tool_name`, `input_preview`, `requires_answer`, and `requires_confirmation`. Full command arguments, diffs, workspace contents, and secrets stay behind the authenticated gateway. Pushes are de-duplicated per target for 24 hours so periodic Mobile Gateway snapshots do not spam the phone.

### Mobile Peer

A paired mobile device connects using a device bearer token. It may:

- send allowed mobile commands;
- receive desktop events;
- receive immediate `ack` or `error` responses from the gateway.

The gateway does not execute the command. It forwards the command to the desktop peer with `_device_id` added to the payload.

## HTTP API

All Mobile Gateway HTTP responses must include:

- `X-App-Version: 1.210.0-rc20`
- `X-Server-Version: 1.210.0-rc20`

### `GET /mobile/health`

Public liveness endpoint.

Response data:

```json
{
  "version": {
    "name": "willdeep-agent",
    "version": "1.210.0-rc20",
    "go_version": "go1.23.x",
    "os": "darwin",
    "arch": "arm64"
  },
  "protocol_version": "mobile-gateway.v1",
  "desktop_name": "Rocky's Mac",
  "pairing_allowed": true,
  "desktop_peer_connected": true
}
```

The public health response must not include the pairing token. `desktop_peer_connected` is required for live Android acceptance because a standalone Go gateway can accept pairing but cannot forward `session.list` or `message.send` to the macOS Agent runtime.

### `GET /mobile/pairing`

Desktop-only endpoint. Requires `Authorization: Bearer <desktop_token>`.

Response data:

```json
{
  "pairing_payload": {
    "base_url": "http://192.168.1.20:8877",
    "fallback_base_urls": ["http://100.90.80.70:8877"],
    "pairing_token": "short-lived-token",
    "protocol_version": "mobile-gateway.v1",
    "desktop_name": "Rocky's Mac",
    "expires_at": "2026-06-13T12:02:00Z"
  }
}
```

The macOS UI should render this payload as a QR code. The pairing token is single-use and defaults to a 2-minute lifetime. When the gateway is listening on a wildcard host and macOS has a Tailscale IPv4 address in `100.64.0.0/10`, the QR payload may include `fallback_base_urls` so Android can try the Tailscale address after the LAN address fails.

### `POST /mobile/pairing/rotate`

Desktop-only endpoint. Requires `Authorization: Bearer <desktop_token>`.

Rotates the short-lived pairing token without restarting the gateway and returns the new QR payload. This is used by macOS Settings and live Android smoke automation when an old token was claimed or expired.

Response data:

```json
{
  "pairing_payload": {
    "base_url": "http://192.168.1.20:8877",
    "fallback_base_urls": ["http://100.90.80.70:8877"],
    "pairing_token": "new-short-lived-token",
    "protocol_version": "mobile-gateway.v1",
    "desktop_name": "Rocky's Mac",
    "expires_at": "2026-06-13T12:04:00Z"
  }
}
```

The endpoint returns `403` when new device pairing is disabled.

### `POST /mobile/pair/claim`

Mobile endpoint. Exchanges a QR pairing token for a device token.

Request:

```json
{
  "pairing_token": "short-lived-token",
  "device_name": "Pixel 9"
}
```

Response data:

```json
{
  "device": {
    "id": "dev_xxx",
    "name": "Pixel 9",
    "created_at": "2026-06-13T12:00:00Z"
  },
  "device_token": "long-lived-device-token",
  "protocol_version": "mobile-gateway.v1"
}
```

Device tokens must be stored hashed by the gateway and stored securely by the client.

### `GET /mobile/devices`

Desktop-only endpoint. Requires `Authorization: Bearer <desktop_token>`. Lists paired device metadata for the macOS Settings UI. The response must never include device tokens or token hashes.

Response data:

```json
{
  "devices": [
    {
      "id": "dev_xxx",
      "name": "Pixel 9",
      "created_at": "2026-06-13T12:00:00Z",
      "last_connected_at": "2026-06-13T12:01:00Z",
      "revoked_at": null
    }
  ]
}
```

### `POST /mobile/devices/revoke`

Desktop-only endpoint. Requires `Authorization: Bearer <desktop_token>`.

Request:

```json
{
  "device_id": "dev_xxx"
}
```

Response data:

```json
{
  "revoked": true
}
```

Revoking a device must close any active WebSocket for that device and reject future reconnects with the old token.

### `GET /mobile/ws`

WebSocket endpoint. Requires `Authorization: Bearer <desktop_token>` for the desktop peer or `Authorization: Bearer <device_token>` for a mobile peer.

The same path is used for both roles. The token determines the role.

## WebSocket Envelope

All messages use one envelope shape:

```json
{
  "id": "message-id",
  "type": "message.send",
  "session_id": "session-id",
  "payload": {},
  "ts": "2026-06-13T12:00:00Z"
}
```

Fields:

- `id`: optional client-generated correlation id.
- `type`: required event or command type.
- `session_id`: optional Agent session id.
- `payload`: optional object payload.
- `ts`: optional ISO-8601 timestamp; the gateway fills it when missing.
## Desktop Events

The desktop peer may broadcast:

- `state.snapshot`
- `session.upsert`
- `message.append`
- `message.delta`
- `message.done`
- `tool.pending`
- `tool.updated`
- `patch.upsert`
- `job.updated`
- `worktree.updated`
- `workspace.list`
- `capabilities.updated`
- `error`
- `ack`
- `command.error`

Unknown desktop event types are transformed into an `error` event before being broadcast to mobile peers.

## Mobile Commands

Allowed mobile commands:

- `session.list`
- `session.create`
- `session.select`
- `message.send`
- `turn.stop`
- `queue.update`
- `tool.decide`
- `patch.decide`
- `file.read`
- `diff.get`
- `job.kill`

Gateway behavior:

- If the command type is unknown, return `error` to the mobile peer.
- If no desktop peer is connected, return `error` to the mobile peer.
- Otherwise, forward the command to the desktop peer and immediately return `ack` to the mobile peer.
- The forwarded payload includes `_device_id`.

The desktop app remains responsible for the actual command result and subsequent state events.

`session.create` and `message.send` may include `payload.workspace_path`. When present, Swift routes the command into a local Mac Agent session bound to that workspace path. Android live acceptance uses this field to make phone-originated coding requests land in the intended Mac repository instead of a generic "No workspace" session.

`message.send` and `queue.update` may include `payload.images` as an array of image data URLs or OpenAI-compatible `{ "type": "image_url", "image_url": { "url": "data:image/png;base64,..." } }` objects. The Swift desktop bridge validates `image/*` base64 data URLs, converts them into `AgentImageAttachment`, and sends them through the existing Mac Agent composer / queued message / Image Understanding flow. Image-only sends are allowed when at least one valid image is present.

Current desktop bridge behavior:

- `state.snapshot` includes session summaries, pending tool approvals, patch proposals, background jobs, queued message previews, recent conversation messages, and `worktree_changes` summaries.
- The Swift desktop peer emits `message.append`, `message.delta`, and `message.done` from AppState message changes, then debounces and republishes snapshots while connected so mobile clients can follow Agent progress during long turns.
- `publishSnapshot()` also emits `tool.pending` and `patch.upsert` envelopes for currently blocked work.
- `tool.decide` resolves `.pendingApproval` tool calls through the same runtime continuation as the Mac UI.
- `.awaitingConfirm` danger-tier tool calls still require `payload.typed_confirmation == "confirm"`; a mobile approve without that field returns `command.error`.
- Pending danger-tier tool snapshots include `requires_confirmation: true` so Android can show a typed confirmation field before sending `tool.decide`.
- `.awaitingUserAnswer` tool calls require `payload.answer`; empty answers return `command.error`.
- `patch.decide` selects the target session and calls the existing patch apply/reject entry points.
- `diff.get` returns the pending patch unified diff in an `ack` payload with `patch_id`, `title`, and `diff`; it does not grant mobile direct filesystem access.
- `state.snapshot` includes background job metadata, and `publishSnapshot()` also emits `job.updated` envelopes for current jobs.
- `state.snapshot` includes desktop worktree changed-file metadata, and `publishSnapshot()` also emits `worktree.updated` envelopes for current changed files.
- `job.kill` resolves a session-scoped job handle and calls the existing `AgentJobRegistry.kill` path; it does not grant mobile process handles or shell access.
- `file.read` reads only text files inside the selected local session workspace, rejects path escapes/directories/binary files, and returns `path`, `content`, `truncated`, and `byte_count` in an `ack` payload.
- `queue.update` controls only the selected session queue through desktop AppState: `add` queues text and optional images, `remove` deletes a queued message by id, `clear` removes all queued messages for the session, and `send_now` promotes a queued message through the same Mac-side send-now path used by the desktop UI.

## Security Requirements

- LAN listening is opt-in from the macOS app.
- Pairing tokens are short-lived, single-use, and never exposed by public health endpoints.
- Device tokens are stored hashed by the gateway.
- Bearer tokens and pairing payloads must not be logged in full.
- Revoked devices must be disconnected immediately.
- Mobile commands must not bypass existing WillDeep approval and safety gates.
- The gateway must not expose raw filesystem, shell, patch, MCP, or model-provider APIs to mobile devices.

## macOS Settings Requirements

The macOS app includes a Mobile Gateway settings section:

- lazy-start `willdeep-agent serve-mobile` only when the user opens Settings → Mobile Gateway, so normal editor launches do not read the Mobile Gateway Keychain token or show a Keychain prompt;
- keep the gateway running for the current app session after the settings tab starts it, so paired mobile devices remain connected after Settings is closed;
- apply settings changes by restarting the gateway;
- show the selected LAN address, port, and resolved gateway executable;
- edit the port with a numeric-only text input, defaulting to `8877`;
- show protocol version;
- show QR pairing payload;
- refresh the short-lived QR pairing payload without restarting the gateway;
- list paired devices with last connected time;
- revoke a paired device.

The Swift coordinator uses the bundled `willdeep-agent` resource by default, allows an explicit executable path as a fallback, passes the desktop bearer token through a protected token file instead of the process argument list, fetches pairing/device metadata through desktop-authenticated HTTP, and connects the desktop peer bridge to `/mobile/ws`. Starting in v1.89.0-rc2, the bundled gateway executable must be a macOS universal Mach-O built from both `darwin/arm64` and `darwin/amd64`, so the same app bundle can run the Mobile Gateway on Apple Silicon and Intel Macs.

All user-visible SwiftUI text must go through `Localizable.xcstrings` and `L10n.swift`.

## Acceptance Criteria

- `willdeep-agent serve-mobile` starts a Mobile Gateway.
- `GET /mobile/health` reports version, protocol, desktop name, and pairing availability with version headers.
- Desktop-authenticated callers can fetch a QR pairing payload.
- Desktop-authenticated callers can rotate and fetch a new QR pairing payload without restarting the gateway.
- A mobile caller can claim a valid pairing token once and receive a device token.
- A paired device can connect to `/mobile/ws`.
- A desktop peer can connect to `/mobile/ws`.
- Mobile commands are acknowledged and forwarded to the desktop peer.
- Desktop events are broadcast to mobile peers.
- Unknown commands return `error`.
- Revoking a device closes its active WebSocket and rejects reconnect.

## Test Requirements

- Go unit tests must cover pairing token claim, expiration, one-time use, desktop-authenticated pairing rotation, health version headers, WebSocket auth, command forwarding, desktop event broadcast including `message.append`, `message.delta`, and `message.done`, unknown command errors, and revoke behavior.
- Swift tests cover state snapshot conversion, command routing into existing Agent runtime methods, real `AppState.mobileGatewaySendMessage` dispatch into `sendAgentMessage()`, message append/delta/done event generation, `AppState` workspace path guard enforcement for `file.read`, danger-tier typed confirmation enforcement for `tool.decide`, `ask_user` answer enforcement, and patch apply/reject routing through the existing desktop patch state machine.
- `scripts/mobile_gateway_integration_test.rb` starts a real local gateway, simulates desktop and mobile peers, verifies pairing, desktop-authenticated pairing rotation, command forwarding, ack, unknown-command errors, ordered message stream event broadcast, worktree event broadcast, device revocation disconnect/reconnect rejection, and emits JSON plus Markdown reports with acceptance evidence.
- `scripts/mobile_gateway_live_readiness.rb` checks a running Mac Gateway before Android live acceptance by probing public health, verifying the live server version matches the repository Go agent version, verifying the default desktop-token file exists, rotating a pairing payload through desktop auth, and writing JSON plus Markdown readiness reports without printing bearer or pairing tokens.
- `scripts/mobile_gateway_end_to_end_acceptance.rb` is the final cross-repository gate: it runs Mac live readiness first, skips Android live acceptance when Mac readiness fails, runs the Android live acceptance wrapper when Mac readiness passes, checks that Android requires the target file even when an existing path is updated rather than newly added, verifies Android live scripts default to desktop port `8877`, and writes JSON plus Markdown combined evidence.
