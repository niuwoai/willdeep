---
name: web-search
description: Search the web for information using the built-in WebSearch tool. Use when users ask questions requiring up-to-date information, research, or fact-checking.
allowed-tools:
  - Bash
  - web_search
  - web_fetch
---

# Web Search Skill

Search the web using WillDeep's built-in **web_search** tool. It uses the configured search provider from Settings → Agent → Web tools:

- **Auto**: tries Exa first when an Exa key is present, then Brave.
- **Exa**: AI-oriented search with highlights and metadata.
- **Brave**: standard web/news search fallback for existing setups.

Use this skill when a task needs fresh public information, current documentation, release notes, error messages, product comparisons, or fact-checking beyond the local workspace.

## web_search Tool (Primary)

```
web_search(query="your search query", count=5)
```

- Returns structured results with title, URL, snippet/highlight, and available metadata.
- Requires an Exa or Brave key in Settings → Agent → Web tools.
- Is read-only and safe for public lookups.
- Does not use the user's browser session or cookies.

## Fetching Page Content

After finding URLs from search, use **web_fetch** to get the actual public page content:

```
web_fetch(url="https://example.com/article", max_chars=20000)
```

- Fetches public http(s) URLs only.
- Refuses private, loopback, and link-local hosts.
- Reduces HTML to readable text; JSON/plain text passes through.
- Requires user approval per domain.

## Chrome Relay / Browser Fallback

If a page requires login, user cookies, CAPTCHA handling, or multi-step browser navigation, use the Chrome Relay / browser tools instead of `web_fetch`. Those tools operate in the user's real browser context and are the right path for authenticated or JavaScript-heavy pages.

Do not ask `web_fetch` to access internal network targets, local services, or authenticated pages.

## Tips

- For complex questions, issue several focused searches rather than one huge query.
- Always summarize findings for the user rather than dumping raw results
- For freshness queries (`today`, `latest`, `今天`, `最新`), use the **current year** from runtime context instead of hardcoding a fixed year
- Use `count` to control the number of search results returned
- Prefer primary sources for technical, legal, medical, financial, or vendor-specific claims.

## Examples

**"Latest AI news":**
```
web_search(query="latest AI news <current_year>", count=5)
```

**"Python 3.13 new features":**
```
web_search(query="python 3.13 new features", count=5)
```

**Fetch a specific article after search:**
```
web_fetch(url="https://docs.python.org/3.13/whatsnew/3.13.html", max_chars=20000)
```
