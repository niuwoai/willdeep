---
name: voice
description: Create a local text-to-speech audio file with macOS system voices, or use a configured TTS MCP provider when higher-quality speech is requested. Use when the user asks for narration, a voice reply, or an audio rendering of text.
---

# Text to Speech

## Local macOS Path

1. Confirm the text, language, desired voice, and output format.
2. Use `run_command` to list available system voices with `/usr/bin/say -v '?'` when needed.
3. Write long or user-provided text to a workspace text file with `create_file`.
4. Run `/usr/bin/say` with the selected voice, input file, and an explicit workspace output path.
5. Verify that the audio file exists and has nonzero size.
6. Return it with a local Markdown file link.

Avoid interpolating untrusted text directly into a shell command; use an input file.

## Configured Provider

For neural voices, voice cloning, emotion control, or formats unavailable from `say`, discover a TTS integration with `list_mcp_servers` and `list_mcp_tools`, then call the exact provider tool. Obtain explicit consent before uploading text or reference audio. Never clone a person's voice without authorization.
