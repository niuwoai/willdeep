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

1. Make the prompt self-contained because every run starts as a fresh session.
2. Include the target system, scope, expected output, and safety constraints.
3. Add a concise title.
4. Add a goal only when the task should remove itself after success.
5. Call `schedule_task` once and report the returned task identifier.
6. During a goal-based scheduled run, call `complete_scheduled_task` only when the stated goal is actually met and the current context includes the task identifier.

The bundled tool does not expose arbitrary cron expressions, one-shot timers, job history, or general list/update/delete operations. Do not invent those capabilities; direct the user to the scheduled-task card or WillDeep UI when management is needed.
