---
name: web-search
description: Search the public web with WillDeep's built-in search provider for current information, primary documentation, error messages, releases, research, and fact-checking. Use whenever freshness or external verification matters.
---

# Web Search

1. Form a focused keyword-style query and include the current year when freshness matters.
2. Call `web_search`; use several focused queries for complex questions.
3. Prefer primary sources, official documentation, standards, and original research.
4. Call `web_fetch` on the most relevant public result when snippets are insufficient.
5. Use the browser tools for authenticated or interactive pages.
6. Cite the supporting URLs near the claims they support.

WillDeep uses the provider configured under Settings → Agent → Web tools and may fall back to managed search when the user's account supports it. Do not claim a specific provider was used unless the tool result says so.

For medical, legal, financial, security, or other high-stakes claims, cross-check authoritative sources and state uncertainty. Never fabricate a source or cite a search-result page as evidence.
