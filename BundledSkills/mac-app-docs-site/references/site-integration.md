# Documentation website integration

## Contents

1. Reuse before invention
2. Content loading
3. Routing and navigation
4. Rendering and internationalization
5. Verification

## Reuse before invention

Inspect the target repository before selecting an implementation. Find the nearest page with the same content shape and reuse its:

- Public route and locale-prefix convention.
- Page shell, sidebar, table of contents, previous/next navigation, and responsive behavior.
- Markdown parser and sanitization policy.
- Static asset import or copy strategy.
- SEO metadata, canonical URL, SSR/static generation, and cache behavior.
- Test helpers and deployment/build commands.

If the repository already renders one app tutorial, generalize that implementation to accept an app key and content directory instead of cloning the entire component tree.

## Content loading

Markdown remains canonical. The website adapter may build a manifest, use `import.meta.glob`, read files server-side, or copy content at build time according to the existing architecture.

The loader must:

- Strip and parse front matter safely.
- Sort by numeric `order` with filename as a stable tie-breaker.
- Map `README.md` to the landing page.
- Preserve headings, lists, tables, code, blockquotes, links, and images used by the source.
- Resolve assets relative to the page's Markdown file.
- Reject unknown slugs with the site's normal not-found behavior.
- Avoid `dangerouslySetInnerHTML` unless rendered HTML is sanitized under the repository's established policy.

## Routing and navigation

Use stable mappings such as:

```text
/<locale>/apps/<app>/docs                  -> README.md
/<locale>/apps/<app>/docs/<chapter-slug>   -> NN-<chapter-slug>.md
```

Adapt the exact prefix to the existing site. Generate navigation from metadata or the README index; do not maintain a second hand-written order unless the framework requires it. Make direct browser refresh and server rendering work for every valid chapter.

## Rendering and internationalization

- Reuse existing typography and colors; a tutorial should look native to the product site.
- Keep navigation usable on narrow screens and long chapter titles.
- Route shell labels, errors, buttons, and accessibility text through i18n resources.
- Treat Markdown content locale separately from shell locale. If only one content locale exists, define and test a deliberate fallback.
- Preserve meaningful alt text from Markdown.
- Make external links distinguishable and safe according to project conventions.

## Verification

At minimum verify:

1. Landing route and one deep chapter route render directly.
2. All front-matter slugs are accepted; an unknown slug returns the intended not-found state.
3. Relative chapter links and every referenced image resolve in production output.
4. Sidebar order and previous/next links match the Markdown order.
5. Locale switching or fallback does not produce blank content.
6. Narrow viewport navigation remains reachable.
7. The repository's unit/route/SSR tests and production build pass.

Deployment is a separate phase. Do not publish merely because the local production build succeeds.
