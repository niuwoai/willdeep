---
name: music-listener
description: Inspect a local audio file's metadata and technical properties, and use a configured audio-analysis or transcription MCP tool when semantic listening is required. Use for duration, codec, channels, tags, transcription, lyrics, genre, mood, or tempo questions.
---

# Music and Audio Inspection

## Local Inspection

1. Confirm the exact local audio path.
2. Use `run_command` to check for `afinfo` or `ffprobe`.
3. Read only metadata and technical properties such as duration, codec, sample rate, channels, bitrate, and embedded tags.
4. Do not infer genre, mood, lyrics, speaker identity, or song identity from metadata alone.

## Semantic Analysis

For transcription, lyrics, genre, mood, or deeper audio understanding:

1. Call `list_mcp_servers`.
2. Inspect a configured audio-capable server with `list_mcp_tools`.
3. Call the exact tool through `call_mcp_tool`.
4. If no capability exists, use `search_mcp_servers` or `suggest_mcp_server`, and explain the limitation.

Never upload an audio file to an external provider without the user's approval. Do not expose private local paths or embedded personal metadata unnecessarily.
