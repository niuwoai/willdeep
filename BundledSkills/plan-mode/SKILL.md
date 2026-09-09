---
name: plan-mode
description: Produce a structured, evidence-based implementation plan without changing files or external state. Use when the user asks to plan, evaluate approaches, identify risks, or review a complex task before execution.
effects: read-only
---

# Planning

Planning is a task phase inside ordinary conversation, not an app interaction mode. Do not claim that a mode changed.

## Workflow

1. Inspect the relevant workspace, code, documentation, and current state with read-only tools.
2. State the goal, constraints, assumptions, and evidence.
3. Resolve unknowns from local context when possible.
4. Compare meaningful alternatives and record the decision.
5. Produce ordered, verifiable steps with affected components, tests, risks, and rollback notes.
6. Separate required work from optional follow-ups.
7. Stop before implementation only when the user explicitly asked for planning or analysis without execution.

For a persistent checklist, load the `todo` skill. The skill never changes the app's conversation mode.
