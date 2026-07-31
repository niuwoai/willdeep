---
name: send-file
description: Deliver a local file, image, audio clip, video, or document through the current WillDeep conversation. Use when the user asks to see, open, download, or receive a generated or existing artifact.
---

# Send a File

## WillDeep Conversation

1. Verify that the file exists and is the intended artifact.
2. For an image, video, or audio file, embed it with Markdown image syntax using the absolute local path.
3. For code, documents, archives, and other downloadable files, use a Markdown link with an absolute local path.
4. Use a concise descriptive label instead of exposing an unexplained raw path.
5. Mention the file type and what it contains.

Examples:

```markdown
![界面截图](/absolute/path/screenshot.png)
[下载报告](/absolute/path/report.pdf)
```

## External Channels

For Discord, Telegram, Feishu, or another channel, use only a configured connector:

1. Discover it with `list_mcp_servers` and `list_mcp_tools`, or use `lark_cli` for supported Feishu operations.
2. Confirm the target conversation.
3. Call the exact discovered upload or send tool.

Never invent an upload command. Do not send secrets, credentials, unrelated private files, or artifacts outside the user's requested destination.
