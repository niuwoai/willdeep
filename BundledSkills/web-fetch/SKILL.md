---
name: web-fetch
description: Fetch and read a known public web page or HTTP API with WillDeep's built-in web tool, using Chrome or the Embedded Browser only when authentication or interaction is required. Use when the user provides a URL or a search result needs full-page content.
---

# Web Fetch

## Public Content

1. Validate that the URL is absolute HTTP or HTTPS.
2. Call `web_fetch` with a suitable character cap.
3. Read the returned text, JSON, or reduced HTML.
4. Cite the source URL and distinguish facts from inference.

`web_fetch` refuses private, loopback, and link-local targets, including redirects. Do not use it for local services, intranet pages, authenticated pages, or cookie-dependent content.

## Authenticated or Interactive Content

- Use `chrome_status` and the `chrome_*` tools for the user's existing signed-in Chrome tabs.
- Use `embedded_browser_*` tools for an isolated in-app browsing session.
- Load the `browser` skill for multi-step interaction.

Never extract cookies, tokens, passwords, hidden form values, or unrelated private page data. Use `web_search` first when the exact URL is unknown.
