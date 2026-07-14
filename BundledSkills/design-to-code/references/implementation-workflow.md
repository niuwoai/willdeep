# Design-to-Code Implementation Workflow

## 1. Resolve the visual truth

- Identify one exact source: attached image, local screenshot, Figma frame, mockup, or generated-image result.
- Prefer an explicit file, node, or selected image over an ordinal such as “the first one.”
- If several references conflict, ask which one controls before editing.
- Record the target viewport, theme, route, and visible interaction state.

## 2. Inspect the destination

- Read the repository instructions and inspect the package manager, framework, routes, component library, CSS strategy, design tokens, fonts, assets, and localization resources.
- Find the closest existing screen and reusable components before creating new ones.
- Preserve the project stack. For a new web project, prefer React + TypeScript; use the repository's preferred package manager.
- Never hardcode React UI copy when the project uses or requires i18n.

## 3. Decompose and measure

Create a compact implementation map covering:

- Page regions and hierarchy.
- Container widths, columns, alignment, gaps, padding, and responsive breakpoints.
- Typography family, weight, size, line height, wrapping, and truncation.
- Colors, opacity, borders, radii, elevation, and state tokens.
- Every image, logo, illustration, icon, texture, and decorative asset.
- Core controls and their visible interaction states.

Inspect the actual source at useful zoom levels. Do not infer small details from memory.

## 4. Acquire assets

- Reuse supplied or repository assets when available.
- Use the closest matching installed icon library for standard UI icons.
- Do not use emoji, text glyphs, CSS art, div art, placeholder rectangles, or handcrafted inline SVG as substitutes for visible source assets.
- Use `generate_image` only for genuinely missing raster artwork, matching the required crop, dimensions, focal point, palette, and art direction.
- Keep text inside an image when the source clearly treats it as part of the artwork; keep editable UI copy as real localized text.

## 5. Implement in source order

1. Establish page shell, responsive frame, and major regions.
2. Map repeated values to existing or newly named tokens rather than scattering magic numbers.
3. Place final assets, not placeholders.
4. Implement typography and dense alignment after the major geometry is stable.
5. Implement the primary journey and visible states. Navigation, tabs, menus, inputs, filters, toggles, selections, forms, and primary actions shown in the main experience should work with realistic local data unless the user requested a static mock.
6. Preserve accessibility semantics, keyboard focus, labels, contrast, and reduced-motion behavior.

Do not add backend services, authentication, persistence, new routes, or broad refactors unless the user requested them or the existing code requires them for the visible core flow.

## 6. Build and render

- Run the repository's normal formatter, type check, tests, and build in proportion to the change.
- Start the existing development command rather than replacing project tooling.
- Use WillDeep's in-app browser tools when available: navigate to the local page, inspect the visible page, exercise primary interactions, read console errors, and capture a screenshot.
- Match the source viewport, route, theme, content, and interaction state before comparing.
- A successful build or HTTP response is not visual verification.

## 7. Compare and iterate

- Read `references/design-qa.md`.
- Compare the source and implementation captures together, not from memory.
- Fix all material layout, typography, color, asset, copy, responsive, and interaction mismatches.
- Repeat capture and comparison after fixes until no actionable high- or medium-impact mismatch remains.
- Save the final evidence and result in project-root `design-qa.md`.
