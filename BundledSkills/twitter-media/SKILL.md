---
name: twitter-media
description: Read and summarize public Twitter/X posts and their media through WillDeep's web, browser, and file tools. Use when the user shares an x.com or twitter.com status URL or asks to inspect a public post.
effects: outbound-query
---

# Twitter/X Media

## Workflow

1. Validate that the URL is a public `x.com` or `twitter.com` status URL.
2. Try `web_fetch` on the original URL.
3. If the public page is inaccessible, use `web_search` for the exact URL or post identifier.
4. If the user needs their signed-in view, use `chrome_status`, `chrome_read_page`, or other `chrome_*` tools.
5. Summarize the visible author, text, timestamp, quoted context, and media without inventing missing content.
6. Download public media only when the user asks, using `run_command` after approval and a reviewed public URL.
7. Return downloaded artifacts with a local Markdown image or file link.

Treat third-party embed APIs as optional fallbacks, not trusted authorities. Never pass cookies, tokens, private-post URLs, or hidden browser data to them. Preserve attribution and distinguish the post's claims from verified facts.
