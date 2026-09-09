# Design QA — Workshop Run 0.1.0

final result: passed

Scope: selected desktop comic lobby and playable desktop first release; not native host installation or mobile release acceptance.

## Evidence and comparison

The selected first ImageGen result `exec-07906914-cd76-4852-88da-a93463a65203.png` (1672×941) and revised `evidence/lobby-final.jpg` (1280×720) were opened together in one image comparison call. Both are effectively 16:9 and were compared proportionally, not claimed pixel-identical. Initial capture: `evidence/lobby-before.jpg`. Gameplay: `evidence/game-final.jpg`.

## Findings

- P2 resolved: ordinary initial title lettering lost the comic identity. A generated two-line transparent Chinese wordmark now matches the intended thick, slanted comic treatment; revised screenshot checked.
- P3: desktop title is more compact than the concept; character rows use gameplay cutouts rather than separate busts. No overlap or blocked desktop controls.
- Intentional: supervisor is marked as coming later; first-release scope is the runaway against AI. Background artwork is regenerated without embedded UI so real controls and translations work.

## Five fidelity surfaces

- Typography: Chinese wordmark characters verified; body uses offline system Chinese fonts; English heading is live text.
- Spacing: left menu, right chase illustration, character rows, large start action and footer retained. At 1280×720 document dimensions equal viewport dimensions; no overflow.
- Color: navy, cream, warning yellow, blue supervisor and cold workshop palette retained.
- Images: original generated hero, characters, rack, prank and wordmark. Transparent sprite alpha checked. Actual playfield is rendered from assets, not a screenshot.
- Copy: title/tagline retained; unavailable mode explicit; settings, tutorial, results and HUD translated.

## Interaction checks

Compiled page loaded with networking disabled by CSP. Throw consumed one ammo; dash reduced stamina to 72; pause retained time and ammo across a later observation. Idle capture produced the failure result; restart reset ammo. Settings changed visible UI to English and back. No warning/error console entries were observed. Eighteen tests pass, including a continuous moving playthrough against live guards.

Narrow 390×844 DOM showed no overflow and accessible start/settings/help. The browser returned inconsistently scaled screenshots for that override, so this is not full mobile visual acceptance. Temporary viewport overrides were reset.

Native WKWebView installation, cross-plugin switching and Rust Web compatibility remain unverified. Characters use single-frame cutouts with movement feedback. No outstanding desktop P0/P1/P2 finding in this review.
