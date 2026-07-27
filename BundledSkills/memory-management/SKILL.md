---
name: memory-management
description: Save durable user preferences, project rules, recurring facts, or reusable constraints with WillDeep's memory tool, and explain the limits of currently recalled context. Use when the user says “remember this” or establishes a rule that should affect future turns.
---

# Memory Management

Use `add_memory` only for compact, durable information that will matter in future conversations.

## Save a Memory

1. Extract one clear fact or rule.
2. Choose `global` for user-wide preferences or `project` for conventions tied to the current workspace.
3. Choose `longTerm` for durable rules and `transient` only for short-lived context.
4. Exclude secrets, credentials, private keys, one-time codes, and unnecessary personal data.
5. Call `add_memory`; outside autonomous modes, let WillDeep request approval.
6. Tell the user exactly what was saved.

WillDeep may inject relevant memories automatically. There is no bundled Agent tool for listing, semantic-searching, editing, or deleting the entire memory store. Direct the user to Settings → Memory for those operations instead of inventing a command.

When asked about past conversations, answer only from recalled context and available workspace session metadata. Clearly say when the evidence is insufficient.
