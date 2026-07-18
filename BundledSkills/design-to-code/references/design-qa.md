# Design-to-Code QA Gate

Do not hand off a Design-to-Code implementation without both a source visual and a rendered implementation.

## Evidence

Collect and record:

- Source visual path, attachment, or Figma node.
- Implementation screenshot path.
- Viewport dimensions and pixel density when known.
- Route, theme, content, and interaction state.
- Build/test result and browser-console result.

Capture the implementation with `embedded_browser_capture_screenshot` when the in-app browser is available. Fall back to `chrome_capture_tab`, then Computer Use for a running browser or native app. Use `visual_qa_screenshot` when approved and helpful. Compare both visuals at the same viewport and state, then call `design_to_code_acceptance`; a final answer requires its `PASS` result.

## Required review surfaces

1. **Composition and layout** — frame size, grid, region proportions, alignment, padding, gaps, overflow, radii, borders, and shadows.
2. **Typography** — font family and fallback, weight, size, line height, letter spacing, wrapping, hierarchy, and truncation.
3. **Colors and tokens** — foreground/background balance, sampled palette, semantic colors, opacity, gradients, and contrast.
4. **Assets and icons** — correct subject, crop, scale, sharpness, masks, logos, imagery, icon family, and absence of placeholder or improvised code art.
5. **Copy and content** — wording, data density, localization, labels, and value formatting.
6. **Interaction and responsiveness** — primary actions, navigation, form controls, hover/focus/selected/open states, loading/empty/error/success states, and key breakpoints.
7. **Accessibility** — semantic elements, labels, keyboard reachability, focus visibility, contrast, target size, and reduced motion.

## Severity

- `P0`: Core flow is unusable, layout is broken, or accessibility failure blocks use.
- `P1`: Major visible mismatch or interaction failure.
- `P2`: Moderate fidelity, responsive, or state mismatch that should be fixed before handoff.
- `P3`: Minor polish that may remain as a follow-up.

Fix every P0, P1, and P2. After each fix, capture the same state again and recompare. Do not count compilation or server troubleshooting as a visual-QA iteration.

## Required report

`design_to_code_acceptance` writes project-root `design-qa.md` and `.willdeep/design-to-code/visual-diff.png`. Add human/VL findings when useful, but do not replace or remove the machine-generated metrics and capture-surface evidence.

The report must contain:

```markdown
# Design QA

- Source: ...
- Implementation: ...
- Viewport: ...
- State: ...

## Findings
- [P1] Location — source differs from implementation; impact; concrete fix.

## Comparison history
- Pass 1: findings, fixes, and new evidence.

## Verification
- Build/tests: ...
- Primary interactions: ...
- Browser console: ...

final result: passed
```

Acceptance status must be `PASS` only when the tool threshold is met and no actionable P0/P1/P2 remains. Keep `NEEDS_ITERATION` when the threshold or material review fails. If every browser and Computer Use capture route was attempted and unavailable, state the exact blocker; never relabel an unverified result as passed.
