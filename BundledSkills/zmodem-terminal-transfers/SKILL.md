---
name: zmodem-terminal-transfers
description: Transfer files between the local Mac and a remote SSH host through WillDeep's side-panel terminal using rz/sz ZMODEM. Use when the user asks to upload or download files over the visible terminal's SSH session, or when scp/rsync is unavailable and the terminal is the only channel to the host.
---

# ZMODEM transfers in the side-panel terminal

WillDeep's visible side-panel terminal supports rz/sz ZMODEM transfers by
intercepting lrzsz handshakes.

## Driving a transfer with terminal_send_command

- Upload (Mac → remote): send the remote `rz` command and pass
  `zmodem_upload_paths` alongside it to preselect the local files to upload.
- Download (remote → Mac): send `sz <file>` on the remote side and pass
  `zmodem_download_directory` to preselect the local destination directory.
- Omit both arguments only when the user should pick files or the
  destination through the macOS file panel themselves.

## Preconditions

- Before asking a remote shell to use `rz` or `sz`, check availability with
  `command -v rz sz`. If missing, tell the user how to install lrzsz for
  that server OS (for example `apt/yum/dnf/apk install lrzsz`, or
  `brew install lrzsz` on macOS hosts).
- The local Mac also needs lrzsz; WillDeep prompts for
  `brew install lrzsz` when local `rz`/`sz` is missing.

## Fallbacks when ZMODEM cannot work

If the remote host cannot install lrzsz or the ZMODEM setup fails, fall
back to (in order of preference): scp/rsync, workspace files, chat
attachments, the App's edit/write flow, apply_patch for local files, or a
careful remote shell edit fallback. Verify the transferred or written
result afterwards.
