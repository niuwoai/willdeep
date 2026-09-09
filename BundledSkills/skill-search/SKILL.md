---
name: skill-search
description: Find the best installed WillDeep skill for a task, then identify whether a missing capability should be handled by a new user skill or an MCP integration. Use when the current workflow or tool set is insufficient.
effects: read-only
---

# Skill Search

1. Call `list_skills` with a focused query.
2. Read promising candidates with `read_skill`.
3. Prefer an installed skill that matches the task over creating a duplicate.
4. If the gap is reusable instructions or project knowledge, offer to create one user skill with `create_user_skill`, or use one `create_user_skills` batch when two or more skills are requested.
5. If the gap requires an external service or tool, call `search_mcp_servers`, then `suggest_mcp_server` when appropriate.
6. Configure an MCP server only from user-provided, reviewed configuration through `configure_mcp_server`.

Do not claim that searching a skill catalog installs software. Do not invent registry commands, package names, credentials, or integrations.
