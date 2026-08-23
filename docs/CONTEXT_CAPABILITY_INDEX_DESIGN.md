# Context Capability Index Design

> Last updated: 2026-08-23 | Target version: v1.285.0-rc2

## Problem

Reducing `AGENTS.md` alone does not remove WillDeep's fixed context cost. The native registry currently contains 164 tool descriptors; repository audits estimate the complete tool Schema at roughly 37K tokens. Cached input is cheaper, but it still occupies the model context window.

Provider prefix caching also constrains the solution. The request prefix is effectively `[tools, system, history]`; changing the tool list changes the earliest bytes and invalidates the reusable prefix behind it.

## Existing lazy surfaces

- Skills already use a two-stage contract: `list_skills` discovers concise metadata and `read_skill` loads one `SKILL.md` or referenced resource.
- MCP already uses three stable gateway tools: `list_mcp_servers`, `list_mcp_tools`, and `call_mcp_tool`. Per-server MCP schemas are returned on demand rather than registered globally.
- Bundled Agent rules use a small global index and read individual Markdown documents from `BundledAgentRules` only when the task matches.

These surfaces should remain stable. Replacing them with direct registration of every Skill or MCP tool would increase baseline tokens and reduce cache reuse.

### Host-side Skill routing

The send path scores the user's text against the cached enabled-Skill catalog without reading Skill bodies. Scoring combines normalized identifier/name matches, inverse-document-frequency metadata terms, CJK n-grams, and a small cross-language alias table. Explicit `$skill` and unambiguous high-confidence matches may auto-attach at most one full Skill body. Ambiguous matches add at most three compact metadata candidates to the user-turn attachment block and require the model to call `read_skill` before claiming it applied one.

Manual picker selections and the dedicated Figma/Design-to-Code router are authoritative and suppress generic stacking. Disabled Skills are excluded. Candidate descriptions are marked as untrusted metadata, truncated, and placed in changing conversation history rather than the stable system/tool prefix.

## Native tool strategy

Native tools are split into a compact core plus deterministic capability packs:

1. Core: workspace search/read/write, shell, jobs, Skill routing, expert activation, subagents, user input, and `load_tool_pack`.
2. `terminal`: visible terminal tabs and saved terminal shortcuts.
3. `session_automation`: session navigation, workspace rebinding, workflows, scheduled tasks, and environment declarations.
4. `knowledge`: memory and user-authored Skill management.
5. `integrations`: MCP gateways, Lark, and installed external coding-agent CLIs.
6. `browser_web`: embedded browser, Chrome, and public-web research.
7. `computer_use`: native macOS accessibility and screenshot control.
8. `media`: image/video generation, editing, task tracking, import, visual QA, and widgets.
9. `plugins`: plugin drafting and inspection.
10. `short_drama`: the short-drama production domain, implicitly activated with its expert.

Pack membership and descriptor ordering are deterministic. A session starts with the 20-tool core and may add packs through `load_tool_pack`; `AgentRuntime.loadedToolPacks` is monotonic for the runtime lifetime. Request estimation and context-compression accounting use the same filtered descriptor set as the actual provider request. Expert activation implicitly adds its matching domain pack because it already changes the tool prefix.

## Cache rules

- Keep the initial pack set stable across common sessions so provider caches can reuse the same tool prefix.
- When the model needs an unregistered capability, it calls the always-present `load_tool_pack` router. The host activates one or several whole packs, pays one deliberate cache miss, and keeps them active for the rest of the runtime.
- Load clearly related packs together so one task does not incur a chain of avoidable prefix changes.
- Do not dynamically register individual tools every round.
- Keep rule, Skill and MCP details after the stable dynamic-context marker or in tool results; never splice them into the stable system prefix.
- Compaction may reset task-local detail, but the active pack manifest remains stable unless the task scope changes.

## Diagnostics and acceptance

The context UI should eventually report separate estimates for system text, global/project rules, native tool schemas, activated Skill bodies, MCP discovery results and conversation history. It should also show the active pack digest and provider-reported `cached_prompt_tokens / prompt_tokens`.

Acceptance criteria:

- A normal coding session starts with 20 native tool schemas (and must remain below 24 as the core evolves).
- Skill and MCP catalogs do not appear in the stable prompt body.
- Adding one capability pack changes the tool prefix once; later rounds are byte-stable.
- Full-registry fallback remains available for compatibility and debugging.
- Authorization and risk classification continue to use the underlying tool descriptor, never the pack or gateway name alone.
