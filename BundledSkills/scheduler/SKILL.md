---
name: scheduler
description: Create recurring WillDeep tasks that run at a fixed minute interval or a daily local time, and complete goal-based scheduled tasks when their goal is met. Use for periodic checks, recurring summaries, monitors, and daily reminders.
effects: side-effects
---

# Scheduler

Use WillDeep's `schedule_task` tool. It supports:

- `interval_minutes`: run every N minutes
- `daily_at`: run every day at local `HH:MM`
- `goal`: optional completion condition for a self-completing watch task

Exactly one of `interval_minutes` or `daily_at` is required.

## Workflow

1. Chat-created tasks belong to and continue the current conversation. Include a clear instruction to inspect prior results and verify improvements; the original model and permissions are retained. Busy or archived conversations are skipped with a recorded reason. Legacy standalone tasks still use a fresh session.
2. Include the target system, scope, expected output, and safety constraints.
3. Add a concise title.
4. Add a goal only when the task should stop future triggers once verified as complete; configuration and history remain available.
5. Call `schedule_task` once and report the returned task identifier.
6. During a goal-based scheduled run, call `complete_scheduled_task` only when the stated goal is actually met and the current context includes the task identifier.

Use `list_scheduled_tasks` to view this conversation's tasks and run history. Use `manage_scheduled_task` with `task_id` and `action` (`pause` or `resume`) to change future triggers. Pausing does not stop an active run. The bundled tool does not expose arbitrary cron expressions or one-shot timers. The conversation's scheduled-task section and card open the management UI.
