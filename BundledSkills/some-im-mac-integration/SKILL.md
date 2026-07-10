---
name: some-im-mac-integration
description: Guide WillDeep macOS app integration with some.im. Use when modifying or reviewing some.im account login, browser pairing, Keychain credential storage, Agent provider library sync, image/video generation routing, VL/image-understanding fallback, onboarding, or Settings some.im flows.
---

# some.im Mac Integration

Use this skill when working on WillDeep's macOS some.im integration. Keep the user-facing path simple: prefer browser sign-in to some.im, then let WillDeep receive credentials and configure chat, image/video generation, and vision fallback automatically.

## Start Here

1. Read `docs/SOME_IM_MAC_APP_INTEGRATION.md` when available; it is the canonical engineering guide for this integration.
2. Inspect current code before editing. The main files are:
   - `Xedit/SomeIMIntegration.swift`
   - `Xedit/Onboarding/OnboardingView.swift`
   - `Xedit/AppStateAgentSessions.swift`
   - `Xedit/AgentModels.swift`
   - `Xedit/SomeIMAsyncMediaIntegration.swift`
   - `Xedit/Localizable.xcstrings` and `Xedit/L10n.swift`
3. Preserve Keychain boundaries. API keys, customer session tokens, and any client-login secret must never be logged, shown in UI, committed, or embedded in examples.

## Integration Rules

- Browser login is the preferred account path. Generate a short device code plus hidden pair token, open some.im in the user's browser, poll browser-status, then save returned credentials locally.
- Do not show QR codes, raw login URLs, pair tokens, or email-code forms unless the user explicitly asks to reintroduce an advanced/debug path.
- Resolve the relay automatically through `GET https://some.im/api/v1/public/client-location`: use `https://api.niuwoai.com/v1` only for `country=CN`, otherwise use `https://some.im/v1`. Do not expose region, Base URL, enable, or API-key controls in the normal Settings flow.
- Save the some.im API key through `SomeIMIntegrationStore.saveAPIKey`; save non-secret routing settings through `SomeIMIntegrationStore.saveSettings`.
- After a successful account link, call both:
  - `appState.syncSomeIMProvider(settings:apiKey:)`
  - `appState.syncSomeIMImageUnderstanding(apiKey:)`
- For manual provider setup, detect text-only main models with `AgentConfiguration.modelAcceptsImageInput`. If the main model cannot accept images, require a VL/image-understanding provider, base URL, API key when required, and model id.
- Keep all visible strings localized through `L10n` and `Localizable.xcstrings`.
- Keep media defaults aligned with the product contract: `gpt-image-2` for images and `seedance-2.0` for video.

## Verification Checklist

Run the narrow checks that match the change:

```bash
rg -n "emailCodeLabel|sendCode\\(|verifyCode\\(|QRCode|pairToken|authorizationURL" Xedit/Onboarding/OnboardingView.swift Xedit/SomeIMIntegration.swift
ruby scripts/version_consistency.rb
ruby scripts/i18n_validate_translations.rb Xedit
xcodebuild -project Xedit.xcodeproj -scheme Xedit -configuration Debug -destination platform=macOS -derivedDataPath build/DerivedData build CODE_SIGNING_ALLOWED=NO
```

The `rg` command is a review aid, not a universal ban: some low-level client APIs may still contain email-code or pair-token fields for backward compatibility. User-facing onboarding/settings screens should not expose them in the simplified flow.

## Release Hygiene

When changing Swift code or bundled app behavior, bump the rc version, update `CHANGELOG.md`, and update `product-overview.md`. Keep frontend/backend-visible versions aligned through the repository's version consistency script.
