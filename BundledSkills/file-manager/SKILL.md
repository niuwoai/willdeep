---
name: file-manager
description: Find, inspect, organize, rename, move, compress, or clean up files with WillDeep's workspace tools and approved macOS app control. Use for file searches and file operations with explicit, bounded targets.
---

# File Management

## Workspace Files

- Search names with `search_files`.
- Search contents with `grep_files`.
- Inspect directories with `list_directory`.
- Read files with `read_file`.
- Create and edit text files with `create_file`, `edit_file`, or `apply_patch`.
- Use `run_command` for read-only metadata queries and standard archive tools when necessary.

## Files Outside the Workspace

Use Computer Use to operate Finder when the user asks to manage files outside the active workspace. Inspect the current app state before every action and verify the result.

## Safety

1. Resolve exact source and destination paths before changing anything.
2. Preview the affected file list before bulk operations.
3. Preserve unrelated files and existing user changes.
4. Prefer recoverable Finder Trash operations over permanent deletion.
5. Ask immediately before overwriting, deleting, emptying Trash, or moving a broad set of files.
6. Never target a home directory, filesystem root, workspace root, unresolved variable, or broad wildcard with a destructive command.
7. Report what changed and whether it is recoverable.
