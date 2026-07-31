---
name: tasks
description: "Route multi-step work to WillDeep's supported task mechanisms: a workspace todo file for current work, a scheduled task for recurring follow-up, and session metadata for workspace conversations. Use when work spans several steps or turns."
---

# Task Coordination

Choose one mechanism:

- Current multi-step workspace work: load the `todo` skill with `read_skill` and maintain its Markdown checklist.
- Recurring or daily follow-up: load the `scheduler` skill and call `schedule_task`.
- Inspect pending user messages before heavy work: call `list_queued_tasks`.
- Review conversations in the current workspace: call `list_workspace_sessions`.

Do not treat `list_queued_tasks` as a project task database. WillDeep does not expose a bundled global task CRUD API, so do not invent task IDs or persistence guarantees.

Keep progress current, mark completed work promptly, preserve blockers with a concrete reason, and report the actual storage or scheduling mechanism used.
