---
name: video-studio
description: Use the installed WillDeep Video Studio plugin to turn a written idea or a local reference frame into an asynchronous AI video job, inspect progress, retry failures, and reveal downloaded output. Use when the user asks to generate, make, retry, inspect, or download an AI video through Video Studio.
---

# Video Studio

Use the `video.*` tools from the bundled `video-studio` MCP server.

## Workflow

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
