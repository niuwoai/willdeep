---
name: todo
description: Maintain a structured Markdown checklist inside the current workspace for complex multi-step work. Use when the task needs explicit progress, blockers, or a resumable plan tied to repository files.
---

# Workspace Todo

Store the checklist at `.willdeep/todos/<session-id>.md` when the current session identifier is available. Otherwise use `.willdeep/todos.md`.

Use `read_file`, `create_file`, and `edit_file`; do not rely on generic tool names that are not present in WillDeep.

## Format

```markdown
# Task

## In Progress
- [ ] Current step

## Pending
- [ ] Later step

## Completed
- [x] Finished step

## Blocked
- [ ] Blocked step — reason and required input
```

## Rules

1. Read the existing file before updating it.
2. Keep only actionable steps.
3. Move finished items to Completed immediately.
4. Record a concrete blocker instead of leaving ambiguous pending work.
5. Preserve user-authored notes.
6. Do not commit `.willdeep` artifacts unless the repository already tracks them or the user requests it.
7. Remove the todo file only when the user asks; otherwise leave it as a resumable record.
