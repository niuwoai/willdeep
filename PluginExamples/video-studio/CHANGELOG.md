# Changelog

## [0.11.0] - 2026-09-09

### Added
- 分镜聊天微调：只改一镜或整集微调两种粒度，按镜号对齐写入。
- `drama.list_shots` 给模型的裁剪清单（不带候选图数组）与 `drama.save_shot_drafts` 批量草稿写入。

### Fixed
- 围栏匹配加边界，避免单镜围栏名认下整集围栏（前缀冲突）。
- 空分镜的提示改为「还没有分镜」；台词空数组按合法意图处理。

## [0.10.0] - 2026-09-09

### Added
- 「AI 串起全部 N 集」：整季分批丰富，默认十集一批，串行并显示进度，每批带相邻批次梗概做衔接。
- `drama.save_episode_drafts`：一次落一批草稿的原子写入，按集号对齐，找不到的集号报出来而不是静默丢。
- 一批格式坏了只跳过那一批，其余继续；单次批量上限三十集。

## [0.9.0] - 2026-09-09

### Added
- 各阶段的系统提示词搬到可维护的创作技能 markdown：策划、角色设定、多集剧情串联、单集剧本、局部改写、分镜六份阶段技能，加去 AI 味、言情、穿越与重生三份可勾选的通用技能。
- 技能存储分两层：插件包里那份是只读模板，用户编辑的副本落在插件数据目录，首次读取时复制过去。模板更新不会覆盖改过的副本，界面提供恢复内置版本。技能全局一份，改了对所有短剧生效。
- 新增 `skill.list` / `skill.get` / `skill.save` / `skill.reset` / `skill.compose` 五个工具。拼装顺序（阶段技能在前、通用技能按勾选顺序追加）与「阶段技能不能当通用技能挂上去」都由存储层保证。
- 策划页可勾选通用技能，勾选记在插件存储里，换短剧不用重勾。技能读不出来时回落到内置提示词，而不是发一个没有系统提示的请求——后者会让模型完全不知道输出格式，整轮白跑。

## [0.8.0] - 2026-09-09

### Added
- 提示消息改成队列（最多十条、带相对时间、十秒后收起成入口）。
- 生图两路有限并发 + 相邻请求至少隔一秒；生成中按钮换文案并显示进度。
- 按钮四态与候选图选中态；角色页动作分组重排、左列纵向堆叠。

### Fixed
- 修一处拼错的文案键名，并加守卫扫描所有 `t(...)` 引用。

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
