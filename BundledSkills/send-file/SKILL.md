---
name: send-file
description: Deliver a local file, image, audio clip, video, or document through the current WillDeep conversation. Use when the user asks to see, open, download, or receive a generated or existing artifact.
effects: side-effects
---

# Send a File

## WillDeep Conversation

1. Verify that the file exists and is the intended artifact.
2. For an image, video, or audio file, embed it with Markdown image syntax using the absolute local path, on a line of its own.
3. For code, documents, archives, and other downloadable files, use a Markdown link with an absolute local path.
4. Use a concise descriptive label instead of exposing an unexplained raw path.
5. Mention the file type and what it contains.

How WillDeep shows media once the reply finishes:

- A line that is only `![label](/absolute/path/clip.mp4)` becomes an inline player with its own play/pause, seek bar, and volume. A line that is only `[label](/absolute/path/clip.mp4)` does the same.
- Playable inline: video `mp4`, `mov`, `m4v`; audio `mp3`, `m4a`, `wav`, `aac`, `aiff`, `caf`, `flac`.
- Other formats (for example `avi`, `mkv`, `webm`, `ogg`) and missing files show the file name with a "Show in Finder" link instead of a player. Convert to a playable format first when the user wants to watch or listen in the conversation.
- A media reference inside a sentence, a list item, or a code block stays text. Remote `http(s)` media is never loaded; download it to a local file first.
- While the reply is still streaming, the media line shows as a file-name placeholder; the player appears when the turn ends.

Examples:

```markdown
![界面截图](/absolute/path/screenshot.png)
![产品演示](/absolute/path/demo.mp4)
![会议录音](/absolute/path/meeting.m4a)
[下载报告](/absolute/path/report.pdf)
```

## External Channels

For Discord, Telegram, Feishu, or another channel, use only a configured connector:

1. Discover it with `list_mcp_servers` and `list_mcp_tools`, or use `lark_cli` for supported Feishu operations.
2. Confirm the target conversation.
3. Call the exact discovered upload or send tool.

Never invent an upload command. Do not send secrets, credentials, unrelated private files, or artifacts outside the user's requested destination.
