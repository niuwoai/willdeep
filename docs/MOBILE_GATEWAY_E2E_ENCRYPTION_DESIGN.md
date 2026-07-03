# Mobile Gateway End-to-End Encryption — Design (deferred)

> Status: **design only, not implemented.** Written when relay became the
> default transport (v1.129.0-rc24). Implementation is a fast-follow that
> requires coordinated changes in the separate `willdeep-android` repo.

## Why

With the internet relay (`j.niuwoai.com`) as the default transport, every
Mobile Gateway envelope — session snapshots, message deltas, diffs, command
output, tool arguments — travels through a relay server the user does not
control. Today messages are **transport-encrypted only** (WSS/TLS to the
relay), then broadcast in plaintext to the room. The relay operator, or
anyone who compromises the relay, can read all content.

End-to-end encryption closes this: the Mac and the phone derive a shared key
at pairing time and encrypt envelope payloads so the relay only ever sees
ciphertext.

## Threat model

- **In scope:** a passive or active relay operator reading or tampering with
  message content; another party who learns only the relay *room name*.
- **Out of scope:** a compromised Mac or phone endpoint; the relay performing
  denial of service (it can always refuse to forward); traffic analysis
  (message sizes/timing remain visible).

## Key exchange

The QR pairing payload already carries a shared secret (`relay_token`). Two
options:

1. **PSK from the QR (simplest, ships first).** Derive a symmetric key from
   `relay_token` via HKDF-SHA256 with a fixed salt and an info string like
   `"willdeep-mobile-gateway-e2e-v1"`. Both sides already hold `relay_token`
   from pairing, so no extra round-trip. Downside: the key is only as strong
   as the QR secret and rotating it means re-pairing.

2. **ECDH at pairing (stronger, later).** Mac and phone each generate an
   X25519 keypair; public keys are exchanged inside the pairing handshake
   (Mac's public key goes in the QR payload; phone sends its public key as the
   first relay frame). Shared secret = X25519(mac_priv, phone_pub), run
   through HKDF. Gives forward secrecy across re-pairings and does not put the
   content key in the QR.

Ship option 1 first (minimal protocol change), migrate to option 2 behind a
`protocol_version` bump.

## Wire format

Encrypt only the `payload` object of the envelope, leaving routing fields
(`id`, `type`, `session_id`, `ts`) in clear so the relay and the existing
command router keep working:

```json
{
  "id": "…", "type": "message.delta", "session_id": "…", "ts": "…",
  "enc": {
    "v": 1,
    "alg": "chacha20poly1305",
    "nonce": "<base64 12 bytes>",
    "ct": "<base64 ciphertext+tag of the original payload JSON>"
  }
}
```

- Cipher: ChaCha20-Poly1305 (CryptoKit `ChaChaPoly`) — AEAD, no padding
  oracle, fast on both platforms.
- Nonce: 12 random bytes per message (CryptoKit generates one per seal).
- AAD: bind the clear routing fields (`type|session_id|id`) as additional
  authenticated data so the relay cannot swap a ciphertext onto a different
  envelope.
- Absent `enc` = plaintext (transition/back-compat); a peer negotiated into
  E2E mode rejects plaintext once both sides advertise support.

## Swift touch points (when implemented)

- `AgentMobileGatewayDesktopPeer.send` — seal `payload` before encoding the
  envelope; `handle(_:)` opens `enc` before routing.
- A new `AgentMobileGatewayCrypto` helper (CryptoKit) for HKDF derive +
  seal/open, unit-tested against a fixed vector shared with Android.
- `MobileGatewayCoordinator.relayPairingPayload` — for option 2, add the
  Mac's ephemeral public key; keep `relay_token` for option 1 PSK.
- Capability flag in the pairing payload / first frame so old phones still
  connect in plaintext until updated (or are refused, per a user setting).

## Android dependency

The `willdeep-android` client must implement the identical HKDF params,
cipher, nonce handling, and AAD binding. Until it does, enabling E2E on the
Mac breaks message exchange. Coordinate a `protocol_version` bump and a
capability negotiation so a mixed-version pair degrades predictably (either
plaintext with a visible warning, or refuse-to-connect, chosen by a Mac-side
setting).

## Rollout

1. Land Swift `AgentMobileGatewayCrypto` + tests behind a disabled flag.
2. Implement the matching Android crypto; agree on test vectors.
3. Add capability negotiation; default to "prefer E2E, allow plaintext with
   warning".
4. Flip default to "require E2E" once the Android install base has updated.
