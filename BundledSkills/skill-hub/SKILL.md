---
name: skill-hub
description: Inspect and maintain WillDeep's built-in, user-created, and plugin-provided skills with the supported skill tools. Use when the user wants to browse skills, read instructions, create or update a reusable user skill, or remove a user skill.
---

# WillDeep Skill Hub

## Browse and Read

1. Call `list_skills`, optionally with a query.
2. Select the exact returned identifier.
3. Call `read_skill` for `SKILL.md` or a referenced resource.
4. Follow the selected skill's instructions.

## Maintain User Skills

- Create: `create_user_skill`
- Update: `update_user_skill`
- Delete: `delete_user_skill`

Only user skills under WillDeep's user skill roots can be changed or deleted. Bundled and plugin skills are read-only at runtime. Ask for confirmation before deletion and never put secrets or stale outputs into a skill.

WillDeep does not provide a generic remote skill-registry installer tool. If the missing capability is an external integration, use `search_mcp_servers` and `suggest_mcp_server`. If a reusable local workflow is needed, create a user skill only when the user asks or approves.
