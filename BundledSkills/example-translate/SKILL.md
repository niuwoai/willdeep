---
name: example-translate
description: Example declarative workflow shipped with WillDeep. Run `/translate-cn <text>` to translate anything into Simplified Chinese. Use this file as a template — copy it to `~/.willdeep/skills/my-skill/` and edit `workflow.yaml`.
---

# Example Translate Skill

This skill bundles a **declarative workflow** defined entirely in
`workflow.yaml` — no Swift code required. It's the simplest possible
example for users who want to author their own workflows.

## Try it

```
/translate-cn Hello, how are you today?
```

WillDeep dispatches your text into the `translate` step, which calls the
configured LLM with the prompt template in `workflow.yaml`, then renders
the `summary` template with the step's output.

## Make your own

1. `mkdir -p ~/.willdeep/skills/my-skill`
2. Copy this folder's `workflow.yaml` over and edit:
   - `slash_command`: pick a unique slash (built-in commands win on conflict)
   - `steps`: each step is one sub-agent call; chain them by referring to
     earlier outputs via `{{steps.<id>.output}}`
   - `parallel: true`: consecutive marked steps run as one batch, capped by
     `max_agents`; a parallel batch can reference only outputs from earlier
     batches or sequential steps
   - `summary`: the markdown rendered into the report card
3. Restart WillDeep (or wait for next workflow dispatch — discovery is
   re-scanned on every dispatch).

## Placeholders

- `{{args}}` — whatever the user typed after the slash command
- `{{steps.<step-id>.output}}` — the text returned by an earlier step
