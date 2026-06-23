---
name: browser
description: Browser automation for AI agents. Use when the user needs to interact with websites — navigating, filling forms, clicking buttons, extracting data, taking screenshots, or automating any browser task. PinchTab is primary for fresh automation, Playwright MCP is preferred for structured browser QA and local web app testing when configured, and Chrome Relay is fallback for the user's existing browser tabs.
allowed-tools:
  - Bash
  - Read
---

# Browser Skill

Three engines, pick the right one:

| Engine | When to Use | How |
|--------|-------------|-----|
| **PinchTab** | Fresh automation, scraping, form filling, stealth browsing, any task that doesn't need the user's existing login | `pinchtab` CLI |
| **Playwright MCP** | Structured browser QA, local web app testing, screenshots, console/network inspection, accessibility snapshots; best when the user configured the Playwright MCP preset | MCP server `playwright` |
| **Chrome Relay** | Reading/interacting with tabs the user already has open, using their existing cookies/logins | `alma browser` CLI |

## Playwright MCP (Structured Browser QA)

Use Playwright MCP when the task is browser QA rather than authenticated user-session work: local web apps, visual checks, form flows, screenshots, console/network debugging, and repeatable automation. Prefer it over ad-hoc shell scripts when a configured MCP server named `playwright` is available.

### Recommended Setup

WillDeep Settings -> MCP has two one-click Playwright presets:

```json
{
  "command": "/usr/bin/env",
  "args": ["npx", "-y", "@playwright/mcp@latest"]
}
```

For users in China, use the mirror preset:

```json
{
  "command": "/usr/bin/env",
  "args": ["npx", "-y", "@playwright/mcp@latest"],
  "env": {
    "npm_config_registry": "https://registry.npmmirror.com"
  }
}
```

Important:
- Keep `-y`; it prevents npm's first-run `Ok to proceed?` prompt from hanging the GUI.
- Do not add `@playwright/mcp` to the user's project dependencies unless the user explicitly asks for a project-level test runner.
- Do not switch to `pnpm dlx` or `yarn dlx` by default; they are fine for advanced custom configs but are less likely to exist on every machine.

### MCP Workflow

1. Confirm the server is configured: call `list_mcp_servers` and look for `playwright`.
2. Inspect tools: call `list_mcp_tools` with `server: "playwright"`.
3. Use the Playwright MCP tools for navigation, accessibility snapshots, screenshots, clicks, typing, console/network diagnostics, and page evaluation.
4. Re-snapshot after interactions that navigate or change dynamic content.
5. For color/theme/layout/accessibility QA, pass the saved screenshot path to `visual_qa_screenshot` after the user has approved the screenshot capture. Use `allow_vl=false` when local palette/OCR is enough; leave it true when the configured Image Understanding provider may review the image.
6. If the user needs their existing Chrome login/session, switch to Chrome Relay instead.

## PinchTab (Primary Engine)

PinchTab is a standalone HTTP server that controls Chrome via accessibility tree refs. 12MB Go binary, zero dependencies, token-efficient.

### Installation

```bash
# macOS / Linux
curl -fsSL https://pinchtab.com/install.sh | bash

# Or via npm
npm install -g pinchtab
```

### Setup

PinchTab server must be running. Start it in the background if needed:

```bash
# Check if already running, install if missing
which pinchtab || curl -fsSL https://pinchtab.com/install.sh | bash
curl -s http://localhost:9867/health 2>/dev/null || pinchtab &
```

### Core Workflow

Every PinchTab automation follows: Navigate → Snapshot → Interact → Re-snapshot

```bash
# 1. Navigate
pinchtab nav https://example.com

# 2. Get interactive elements (refs like e1, e2...)
pinchtab snap -i -c

# 3. Interact using refs
pinchtab click e5
pinchtab fill e3 "user@example.com"
pinchtab press e7 Enter

# 4. Re-snapshot after any page change
pinchtab snap -i
```

### Essential Commands

```bash
# Navigation
pinchtab nav <url>                    # Navigate to URL
pinchtab nav <url> --new              # Open in new tab

# Snapshot (get element refs)
pinchtab snap -i                      # Interactive elements only (recommended)
pinchtab snap -i -c                   # Include cursor-interactive elements
pinchtab snap                         # Full accessibility tree

# Interaction (use refs from snap)
pinchtab click e1                     # Click element
pinchtab fill e2 "text"               # Clear field and type
pinchtab type e2 "text"               # Type without clearing
pinchtab press e1 Enter               # Press key
pinchtab select e3 "option"           # Select dropdown option

# Text extraction (token-efficient ~800 tokens/page)
pinchtab text                         # Extract readable text

# Screenshots
pinchtab screenshot                   # Take screenshot (JPEG)
pinchtab screenshot --full            # Full page screenshot

# JavaScript
pinchtab eval 'document.title'        # Run JS in page context

# Tab management
pinchtab tabs                         # List tabs
pinchtab tab close <tabId>            # Close tab

# Multi-instance (parallel browsing)
pinchtab instances                    # List instances
pinchtab instances create --profile=work  # Create isolated instance
```

### Ref Lifecycle

Refs (e1, e2...) are invalidated when the page changes. ALWAYS re-snapshot after:
- Clicking links/buttons that navigate
- Form submissions
- Dynamic content loading (modals, dropdowns)

```bash
pinchtab click e5              # Navigates to new page
pinchtab snap -i               # MUST re-snapshot
pinchtab click e1              # Now use new refs
```

### Profile Persistence (Login Once, Reuse)

```bash
# Start with a named profile — cookies/sessions persist
pinchtab --profile myapp nav https://app.example.com/login
pinchtab snap -i
pinchtab fill e1 "user@example.com"
pinchtab fill e2 "password123"
pinchtab click e3

# Next time, the profile remembers the login
pinchtab --profile myapp nav https://app.example.com/dashboard
```

### Stealth Mode

PinchTab patches navigator.webdriver, spoofs UA, hides automation flags:

```bash
# Stealth is on by default, check status
pinchtab stealth-status
```

### Batch Actions

```bash
# Multiple actions in one call
pinchtab action --batch '[{"kind":"fill","ref":"e1","value":"user@example.com"},{"kind":"fill","ref":"e2","value":"pass123"},{"kind":"click","ref":"e3"}]'
```

## Chrome Relay (Fallback — User's Real Browser)

Use when you need the user's existing Chrome tabs, cookies, and login sessions.

```bash
# Check connection
alma browser status

# List user's open tabs
alma browser tabs

# Read content from an existing tab
alma browser read <tabId>

# Interact with existing tabs
alma browser click <tabId> <cssSelector>
alma browser type <tabId> <cssSelector> "text" [--enter]
alma browser eval <tabId> "javascript code"
alma browser screenshot [tabId]
alma browser read-dom <tabId>          # List interactive elements
alma browser scroll <tabId> <up|down> [amount]
alma browser goto <tabId> <url>
alma browser open [url]                # New tab
alma browser back <tabId>
alma browser forward <tabId>
```

## Decision Guide

- Need to scrape/automate a site from scratch? → PinchTab
- Need stealth to avoid bot detection? → PinchTab
- Need local app QA, screenshots, console/network inspection, or accessibility snapshots and Playwright MCP is configured? → Playwright MCP
- Need color/theme/layout/accessibility review from an approved screenshot? → Capture with Playwright MCP / PinchTab / Chrome Relay, then call `visual_qa_screenshot`
- Need to avoid npm's install confirmation prompt for Playwright MCP? → Use the WillDeep preset with `npx -y @playwright/mcp@latest`
- User is in China and npm is slow/unreachable? → Use the Playwright MCP China mirror preset with `npm_config_registry=https://registry.npmmirror.com`
- Need to read what the user is currently looking at? → Chrome Relay
- Need the user's existing login session? → Chrome Relay (or PinchTab with saved profile if you've logged in before)
- Need parallel sessions? → PinchTab (multi-instance)
- Need token efficiency? → PinchTab (text extraction ~800 tokens vs screenshots ~10k tokens)
