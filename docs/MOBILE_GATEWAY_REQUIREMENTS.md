# WillDeep Mobile Gateway Requirements

> Last updated: 2026-06-15 | Target version: v1.78.0-rc29

## Summary

Mobile Gateway lets an Android client connect to WillDeep over the local network. The phone is a display and control surface; the Mac remains the authority for Agent execution, tool approval, patch application, workspace access, and safety gates.

This Mac repository implements the Go gateway, Swift desktop peer, and protocol contract. The Android client is developed in the separate `willdeep-android` repository; this repository does not ship cloud relay, public tunnel, push notifications, or direct mobile access to filesystem and shell APIs.

## Product Goals

- Allow the Mac to expose an opt-in LAN gateway for paired mobile devices.
- Pair a device by scanning a short-lived QR payload generated on the Mac.
- Let a paired device subscribe to Agent session events and send control commands.
- Keep Agent decisions inside the desktop app so mobile commands reuse existing Plan gate, danger confirmation, workspace path guard, MCP trust, patch review, and approval behavior.
- Make the protocol stable enough for a native Android app to implement later.

## Non-Goals

- No Android project in this phase.
- No same-network anonymous access.
- No cloud account, NAT traversal, hosted relay, or remote push.
- No direct mobile calls to `/v1/fs/*`, `/v1/run/*`, or other remote-runtime execution APIs.
- No mobile-side model provider credentials.

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

Commands that touch files and queues remain desktop-mediated and must not bypass existing safety gates.

### Mobile Peer

A paired mobile device connects using a device bearer token. It may:

- send allowed mobile commands;
- receive desktop events;
- receive immediate `ack` or `error` responses from the gateway.

The gateway does not execute the command. It forwards the command to the desktop peer with `_device_id` added to the payload.

## HTTP API

All Mobile Gateway HTTP responses must include:

- `X-App-Version: 1.78.0-rc29`
- `X-Server-Version: 1.78.0-rc29`

### `GET /mobile/health`

Public liveness endpoint.

Response data:

```json
{
  "version": {
    "name": "willdeep-agent",
    "version": "1.78.0-rc29",
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
    "pairing_token": "short-lived-token",
    "protocol_version": "mobile-gateway.v1",
    "desktop_name": "Rocky's Mac",
    "expires_at": "2026-06-13T12:02:00Z"
  }
}
```

The macOS UI should render this payload as a QR code. The pairing token is single-use and defaults to a 2-minute lifetime.

### `POST /mobile/pairing/rotate`

Desktop-only endpoint. Requires `Authorization: Bearer <desktop_token>`.

Rotates the short-lived pairing token without restarting the gateway and returns the new QR payload. This is used by macOS Settings and live Android smoke automation when an old token was claimed or expired.

Response data:

```json
{
  "pairing_payload": {
    "base_url": "http://192.168.1.20:8877",
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
- `queue.update` controls only the selected session queue through desktop AppState: `add` queues text, `remove` deletes a queued message by id, `clear` removes all queued messages for the session, and `send_now` promotes a queued message through the same Mac-side send-now path used by the desktop UI.

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

- enable or disable LAN access;
- start or stop `willdeep-agent serve-mobile`;
- show the selected LAN address, port, and resolved gateway executable;
- edit the port with a numeric-only text input, defaulting to `8877`;
- show protocol version;
- show QR pairing payload;
- refresh the short-lived QR pairing payload without restarting the gateway;
- list paired devices with last connected time;
- revoke a paired device.

The Swift coordinator uses the bundled `willdeep-agent` resource by default, allows an explicit executable path as a fallback, passes the desktop bearer token through a protected token file instead of the process argument list, fetches pairing/device metadata through desktop-authenticated HTTP, and connects the desktop peer bridge to `/mobile/ws`.

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
