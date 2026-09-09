---
name: daily-report
description: Build an evidence-based work report for a day or date range from the current WillDeep workspace, Git history, working-tree changes, and visible session metadata. Use for daily reports, weekly recaps, work journals, and questions such as “我今天做了什么”.
effects: read-only
---

# Daily Report

Create a concise report from evidence WillDeep can actually inspect. Never imply that WillDeep recorded the user's whole screen or every activity.

## Evidence Order

1. Confirm the requested date or range using the runtime date and timezone.
2. Call `git_status` when the workspace is a Git repository.
3. Use `run_command` for read-only Git history scoped to the requested period, including commits, authors, changed paths, and tags when relevant.
4. Call `list_workspace_sessions` for session titles and timestamps in the current workspace when that context helps.
5. Read relevant changelog or product overview entries only when they fall in the requested period.
6. Ask for additional sources only when the available evidence cannot answer an important part of the request.

## Output

Group the report by project or theme rather than minute-by-minute chronology. Separate:

- Completed work
- In-progress work
- Decisions or design changes
- Tests and verification
- Releases or version changes
- Open risks and next steps

State the evidence boundary, especially when the report covers only the current repository. Do not fabricate meetings, messages, pull requests, people, versions, or decisions.
