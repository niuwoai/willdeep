---
name: notebook
description: Inspect and edit Jupyter notebook files with WillDeep's file tools while preserving valid notebook JSON and cell structure. Use for inserting, replacing, deleting, or reviewing cells in .ipynb files.
effects: read-only
---

# Jupyter Notebook Editing

1. Read the notebook with `read_file` and identify cells by stable `id` when available; use indexes only as a fallback.
2. Preserve top-level notebook metadata, `nbformat`, and `nbformat_minor`.
3. Make the smallest exact change with `edit_file` or `apply_patch`.
4. For a new code cell, include `cell_type`, `id`, `metadata`, `source`, `outputs`, and `execution_count`.
5. For a new Markdown cell, include `cell_type`, `id`, `metadata`, and `source`.
6. Keep source as an array of strings with newline conventions consistent with neighboring cells.
7. Validate JSON with `run_command` using `jq empty <notebook>` or an equivalent read-only parser.
8. Re-read the changed cells and review the diff.

Do not execute notebook cells unless the user asks. Preserve outputs by default; clear them only when requested. Avoid whole-file rewrites for a small cell change.
