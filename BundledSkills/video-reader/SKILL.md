---
name: video-reader
description: Inspect local video or audio files with WillDeep and available system tools, extracting metadata, representative frames, and optional transcription through a configured provider. Use when the user asks what a video contains or says.
effects: read-only
---

# Video and Audio Inspection

## Workflow

1. Confirm the exact user-provided or workspace file path.
2. Use `run_command` to check whether `ffprobe` and `ffmpeg` are available.
3. Read duration, codecs, dimensions, frame rate, audio streams, and container metadata with `ffprobe`.
4. When visual understanding is needed, extract a small representative contact sheet into a workspace subdirectory and call `visual_qa_screenshot` after approval.
5. For speech transcription or native video understanding, discover a configured provider with `list_mcp_servers` and `list_mcp_tools`, then use `call_mcp_tool`.
6. If no transcription or video-understanding provider exists, report that limitation and offer `search_mcp_servers` or `suggest_mcp_server`.
7. Clean up temporary frame and audio artifacts after the user no longer needs them, using a precise recoverable operation where possible.

Do not claim that metadata or isolated frames reveal the full motion, audio, or narrative. Never upload private media without explicit approval, and do not silently retry a billable provider job.
