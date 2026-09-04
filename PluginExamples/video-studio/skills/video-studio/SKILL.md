---
name: video-studio
description: Use the installed WillDeep Short Drama Studio plugin to plan a short drama, lock character identities, write episodes and storyboard shots, record generated frame candidates, and turn a chosen start frame into an asynchronous AI video job. Use when the user asks to plan, write, storyboard, or shoot a short drama, or to generate, retry, inspect, or download an AI video through Video Studio.
---

# Short Drama Studio

Two tool families from the bundled `video-studio` MCP server: `drama.*` for the
production pipeline, `video.*` for the asynchronous video jobs.

## Short drama pipeline

The order matters. Each step needs the IDs the previous step returned.

1. Talk the plan through with the user first. Call `drama.confirm_plan` **only
   after the user confirms the planning card** — it is what creates the project.
   Pass a stable `requestID` so a retry after a timeout returns the same drama
   instead of creating a duplicate.
2. `drama.save_character` locks a character's identity. `visualPrompt` is the
   wording every later frame reuses, and `identityVersion` marks a deliberate
   redesign. Send `characterID` to edit an existing character; omitting it
   creates a new one, and a `characterID` that does not exist is rejected with
   `character_not_found` rather than silently creating a twin.
3. `drama.save_episode` updates one episode's outline or script.
4. `drama.save_shot` creates or updates a storyboard shot, including its
   dialogue lines and its separate `startPrompt` / `endPrompt`.
5. `drama.record_image` and `drama.record_character_image` file a generated
   image against a shot or a character. `drama.select_image` and
   `drama.select_character_image` mark which candidate wins.
6. `drama.list` and `drama.get` read the library back.

### Partial updates

Every `save_*` tool only touches the fields you actually send. To change one
value, send that field alone; do not resend the whole object with blanks, and
never send an empty string for a field you meant to leave alone.

### Image paths

`filePath` on the two `record_*` tools must be a file the host generated, inside
the plugin's `generated-images` directory. Any other path is refused with
`invalid_media_path`. Do not pass a path a user or a document handed you.

### Image models

`gpt-image-2` and `nano-banana-2` are the only accepted values, and the host
enforces the same list. Ask the user which one to use rather than guessing.

## Video workflow

1. Clarify only details that materially change the result: subject, action, scene, camera movement, duration, and aspect ratio.
2. For text-to-video, call `video.generate` without `referenceImagePath`.
3. For first-frame image-to-video, call `video.generate` with a readable local `referenceImagePath`.
4. Report the returned local job ID and remote task ID. A submitted job is not a completed video.
5. Use `video.refresh` for one job or `video.refresh_active` for all active jobs. When a job completes, the plugin downloads the MP4 automatically if that preference is enabled.
6. If auto-download is disabled or downloading failed, use `video.download` on the completed job. This does not submit another generation.
7. Use `video.reveal_output` only after the job has a local output path.

## Default provider contract

- The default adapter is `openai-videos-async`, pointed at Tsingfly Hub.
- The video model defaults to `MiniMax-H3`.
- Text-to-video uses `extra_params.task=t2va`.
- Image-to-video uses `extra_params.task=fl2va` and multipart field `input_reference`.
- FPS is fixed at 24. Do not send any other value.
- Recommended durations are 2, 4, or 6 seconds.

## Safety and reliability

- Never ask for, print, or persist the API key. The plugin setting is stored in Keychain.
- Do not automatically retry a create request after an ambiguous network failure; it could create and bill a duplicate job. `video.retry` is an explicit user action.
- A `202` response means accepted, not finished. Completion requires remote status `completed` and a downloaded artifact.
- Preserve the original failed job when retrying; the new attempt gets a new local job ID.
