# Changelog

## [0.7.0] - 2026-09-09

### Added
- 分集剧本共创：整集生成与只改选中那一段，两个围栏分开。选区记位置不记文本。
- 上游资料不含本集正文全文，避免撞上宿主的输入上限。
- 分集差异对长正文只报字数变化。

### Changed
- 策划、角色、剧本的流式改为显示正在生成的字段值，不再刷 JSON 原文也不再只给占位。

## [0.6.0] - 2026-09-09

### Added
- 分集剧本阶段检测剧本里的新面孔并提示建成角色，只提示不自动建，建出来只有名字。
- 检测规则：名字 2 到 6 字、冒号后须有台词、功能性称谓不算、至少出现两次。刻意不调模型，手写剧本一样有效。

## [0.5.0] - 2026-09-09

### Added
- 策划输出带出角色骨架（名字加一句话定位），确认时一并落库；视觉提示词留空等角色阶段单独出稿。
- 角色阶段的「AI 出第一稿」与「给空角色批量出稿」，批量串行并显示进度。
- 角色表为空时的提示。

### Fixed
- 落库时过滤重名、无名与非对象的角色条目；`characters` 缺失或类型不对时按空数组处理。

## [0.4.1] - 2026-09-09

### Fixed
- 策划失败时问题退回输入框、不再把失败那轮的消息留在历史里，模型原文进聊天记录。
- 策划失败原因区分「没给数据 / 格式错 / 输出被截断 / 缺剧名」四种，各给对应处置建议。
- JSON 提取改用括号配平扫描，接受 ```json、裸围栏与 ```short_drama_plan JSON 变体，前后夹带解释也不再毁掉解析。
- 策划提示词收紧围栏标记与输出长度要求；流式行补停止按钮。

## [0.4.0] - 2026-09-09

### Added
- 角色阶段支持与 AI 持续共创：按角色选中、阶段聊天持久化、草稿预览与逐字段差异、手改与 AI 交替编辑、明确采用、停止生成。模型回复不带围栏时按闲聊处理，不动草稿。
- 存档为短剧、角色、分集、分镜加入 `rev` / `draftRev` / `draft`，并新增 `drama.save_draft`、`drama.commit_draft`、`drama.discard_draft`。草稿写入按 `expectedDraftRev` 比对，定稿按 `expectedRev` 比对，重复确认返回冲突而非重复写入。
- 共创聊天按剧存独立文件，新增 `chat.append`、`chat.list`、`chat.clear`。
- 角色草稿只接受 `name`、`description`、`visualPrompt` 三个字段，模型返回的 id、候选图、身份版本一律丢弃。

### Changed
- 要求宿主 1.343.0-rc1 及以上：停止生成依赖桥 2.3.0 的 `ai.cancel`。
- 不再向宿主传 `maxOutputTokens`，该参数已在宿主侧删除。

## [0.3.2] - 2026-09-07

### Changed

- 不再向聊天选区菜单贡献「发送到短剧工坊」。这一项来自清单里的 `menus["chat.selection"]`，对着聊天正文划词时用不上它，白占一格。命令 `video.createDraft` 保留，MCP 工具 `video.create_draft` 与插件页内的入口都不受影响。
- MCP 服务端 `serverInfo.version` 从 `0.2.0` 对齐到插件版本 `0.3.2`。此前两者各走各的，服务端报的版本从 0.2.0 起就没跟过。

## [0.3.1] - 2026-09-04

### Fixed

- Every command failed against a real host. The page treated the host's MCP result envelope as the business payload, so `payload.ok` was always undefined and the library never loaded.

### Added

- The planner shows a live line of generated text above the composer while it waits, and the model picker now lists every model configured on the provider.

## [0.3.0] - 2026-09-04

### Added

- The planning conversation now supports `$` to reference a WillDeep skill. Typing `$` opens a picker, choosing an entry removes the token and adds a chip above the composer, and the request carries only the skill identifier. The host reads the skill body and injects it; the page never sees it.

## [0.2.1] - 2026-09-04

### Fixed

- Every input field was unusable: the workspace defined its sections as functions inside the component and rendered them as JSX elements, so each keystroke remounted the whole tree and dropped focus after one character.
- The English dictionary spread the Chinese one and only overrode part of it, leaving 89 keys, including the planner system prompt sent to the model, showing Chinese to English users.
- The image model is now `nano-banana-2`. The underscore spelling does not match the gateway's routing prefix and would have been rejected as an unconfigured model.
- `crypto.randomUUID` is only defined in a secure context, and the plugin page is served from a custom scheme. A guarded fallback replaces every call, including the one on first render.
- Candidate draws run concurrently and report per-item outcomes, so a failure partway through no longer hides the images that were already generated and billed.
- Generating frames no longer unlocks its own button mid-run, which used to let a second click start another paid round.
- Each draw in a batch varies its prompt, since the gateway forces `n` to 1 for the gpt-image family and drops `seed` on some upstream paths.
- Drafting a new shot no longer shows the first shot's candidates, and picking one no longer writes back to that shot.
- The theme now follows the host when only the color scheme changes, notifications are announced and keyboard dismissible, the page no longer forces a 700px minimum width, and status pills have dark-theme colors.
- Saving the first shot moves a drama from planning into production, so the library's status filters are no longer permanently empty. Filter chips show counts and disable themselves when empty.
- Development-only cover images are no longer copied into the production bundle.

## [0.2.0] - 2026-09-04

### Fixed

- Storyboard saves no longer crash on the pinned `/usr/bin/ruby` 2.6 interpreter; dialogue normalization dropped the Ruby 2.7 `filter_map` call.
- Partial saves keep untouched fields. Renaming a character no longer wipes its description, identity prompt, and identity version.
- An unreadable archive now refuses the write instead of overwriting it with an empty one, so a truncated file no longer costs the user every drama and job record.
- Generated-image paths are confined to the host's `generated-images` directory and symlinks are rejected.
- Stale `characterID` / `shotID` values are reported instead of silently creating duplicates, and `drama.confirm_plan` accepts a `requestID` for idempotent retries.
- Job and drama archives now share the host's per-plugin directory, with a non-destructive copy of any legacy job store on startup.

### Added

- Added a named short-drama library, AI planning confirmation cards, character identity locking, episode switching, editable scripts/dialogue, and per-shot start/end frame design.
- Added permission-scoped some.im image generation with selectable `gpt-image-2` and `nano-banana-2` models plus configurable candidate counts.
- Added multiple video draws per shot and explicit capability messaging when the default Tsingfly adapter cannot accept an end frame.

### Changed

- Redesigned the React workspace around the full short-drama production pipeline with the approved light macOS sidebar, searchable/status-filtered drama list, recent-work continuation, and responsive narrow-window layout.
- Reworked planning from a one-shot form into contextual AI chat with a persistent transcript and a separately confirmable structured card; all visible copy remains in i18n dictionaries.
- Added three optimized 600×800 WebP cover assets for development previews without increasing the host plugin-size limit.

## [0.1.0] - 2026-09-04

### Added

- Added text-to-video and first-frame image-to-video workflows through a provider-neutral asynchronous video adapter.
- Added Tsingfly Hub `POST /v1/videos` and `GET /v1/videos/{id}` support with multipart uploads, task persistence, polling, explicit retry, and automatic MP4 download.
- Added an AI creative-director workflow that reuses WillDeep's configured chat providers and models without exposing their credentials to the plugin.
- Added bilingual React UI, chat-selection capture, local reference-image picker, output reveal action, and a bundled Agent skill.
- Added manual downloads, in-page paid retry/removal confirmation, non-overlapping polling, Retry-After backoff, interrupted-submission recovery, and runtime-only ZIP packaging.
