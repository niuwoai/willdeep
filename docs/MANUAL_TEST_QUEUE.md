# Manual Smoke-Test Queue

> Last updated: 2026-07-23

CI 只能保编译/单测过。一系列改 UI、改窗口、改 SwiftUI 状态机的特性
都得人坐到机器前面点。这个文件按版本累积着每次发版后我提醒你
「你需要手动 smoke 这几样」的清单。**测过的请打勾或直接删行**，
留下来的就是还没测的；下次 onboarding / dogfooding 时优先消化。

约定：
- ⏳ = 还没测
- ✅ = 已测、通过
- ❌ = 已测、有 bug（请在行后写 issue link 或一句描述）

---

## 1.194.0-rc20 — Composer 移除排队图标

- ⏳ Agent 响应期间输入框右下角不再显示蓝色排队圆形按钮。
- ⏳ 语音与停止按钮之间不留异常空位，底部操作仍保持对齐。
- ⏳ 已有排队消息的展示、编辑、立即发送和清空能力不受影响。

---

## 1.194.0-rc17 — 思考图标轻量呼吸

- ⏳ “思考中”左侧星形图标缓慢做小幅大小往复，绿色背景同步做轻微明暗变化，文字和计时不闪动。
- ⏳ 动画持续观看不抢夺正文注意力，缩放不会改变状态栏高度或造成布局抖动。
- ⏳ macOS 开启“减弱动态效果”后星形图标保持静止。

---

## 1.194.0-rc16 — 来源入口正文对齐

- ⏳ “来源”胶囊左边缘与助手正文左边缘对齐，不再明显靠近对话区外沿。
- ⏳ 来源与学习入口同时出现时保持同一行，并共同遵循正文左右缩进。
- ⏳ 窄窗口下入口不会被正文列缩进挤压或裁切。

---

## 1.194.0-rc15 — 终端发送描边确认

- ⏳ “发送到终端”显示强调色描边、正文色文字和透明背景，不再是强调色实心按钮。
- ⏳ “暂不发送”和“发送到终端”仍有清晰的操作层级，浅色与深色皮肤下边框均可辨认。
- ⏳ 普通命令执行、网页访问等其他确认卡继续使用既有主操作样式。

---

## 1.194.0-rc14 — 来源 favicon 合并

- ⏳ 同一网站的多条来源在入口只显示一个 favicon，`www` 与裸域名视为同一站点。
- ⏳ 网站根目录没有 favicon 时能够尝试回退图标服务；全部失败时仍显示稳定的字母占位。
- ⏳ 点击来源入口后，弹窗仍列出全部具体来源链接。

---

## 1.194.0-rc13 — 辅助文字可读性

- ⏳ “已创建文件”、来源入口、文件变更摘要与底部状态栏文字大小接近正文，不再明显偏小。
- ⏳ 次要信息仍可通过淡色与字重被辨认，不会与正文抢夺视觉层级。
- ⏳ 调大或调小对话字号后，辅助文字保持可读且不会超过正文配置字号。

---

## 1.194.0-rc12 — Git 行数与渐进 Diff

- ⏳ 新增一个未跟踪的 UTF-8 文本文档后，Composer 和审阅面板显示其真实新增行数，不再出现 `+0 -0`。
- ⏳ 打开超过 100 行的文件 Diff 时，首屏只显示前 100 行；点击“显示更多”后每次继续增加最多 100 行。
- ⏳ 二进制、超大或无效 UTF-8 的未跟踪文件保持安全降级，不阻塞审阅面板。

---

## 1.194.0-rc11 — 来源弹窗取消单项焦点态

- ⏳ 打开“来源”弹窗时，首条来源不再自动出现焦点描边。
- ⏳ 直接点击任意来源仍能打开对应 URL，弹窗内滚动与鼠标交互正常。

---

## 1.194.0-rc10 — Composer 进度胶囊按轮次隐藏

- ⏳ 当前轮次仍在执行未完成计划时，“第 N / N 步”胶囊正常显示并随步骤推进。
- ⏳ AI 本轮回复结束后，Composer 不再保留上一轮进度胶囊。
- ⏳ 计划已经全部完成但用户发起下一轮消息时，不会重新出现上一轮的 `N / N` 完成状态。

---

## 1.194.0-rc9 — 本轮进度卡正文间距

- ⏳ AI 回复正文后出现“本轮进度”卡片时，正文与卡片之间具有清晰留白，不再视觉粘连。
- ⏳ 历史消息与当前流式消息中的卡片间距一致，收起和展开状态均不会挤压上一段文字。

---

## 1.194.0-rc8 — Codex 风格逐文件 Git 审阅

- ⏳ 打开审阅面板后默认显示逐文件卡片，文件路径、状态与增删统计和 Git 结果一致。
- ⏳ 点击文件头可独立折叠/展开；工具栏可一键折叠全部或展开全部。
- ⏳ 增删行显示旧/新双行号与语义底色，首个 hunk 之前和多个 hunk 之间显示正确的“未修改 N 行”。
- ⏳ 文件列表、单文件详情、四种审阅范围与提交/提交并推送流程仍可正常工作。
- ⏳ 超大合并 Diff 不会卡住界面，并能回退到受预算保护的预览或单文件查看。

## 1.194.0-rc7 — 计划卡展开与自动收起

- ⏳ 执行中的计划默认以紧凑标题行展示，点击标题行可展开，再次点击可收起。
- ⏳ 从历史或当前回复点击“查看完整计划”后，计划卡先展开并滚动到可见位置。
- ⏳ 计划卡手动展开后，下一轮 AI 输出开始时自动收起。
- ⏳ 待审批的新计划仍默认展开，批准与拒绝按钮不会被隐藏。

## 1.194.0-rc6 — Git 审阅与提交

- ⏳ Agent 修改文件后，Composer 上方只显示一个胶囊入口，文件数、增加行和删除行与 Git 状态一致。
- ⏳ 点击胶囊后在右侧直接打开“审阅”面板，不出现独立 Diff sheet。
- ⏳ 默认“未提交”范围展示合并 Diff；切换未暂存、已暂存、上一轮提交后，文件与增删统计符合对应 Git 范围。
- ⏳ 文件跳转菜单、文件列表/合并 Diff 切换、单文件返回均可正常工作。
- ⏳ 输入提交信息后，“提交”可按勾选状态包含未暂存改动；成功后审阅内容与 Composer 摘要自动刷新。
- ⏳ “提交并推送”在成功时显示完整成功状态；推送失败时明确显示“提交成功、推送失败”，且本地提交仍存在。
- ⏳ 空提交信息时两个提交按钮不可用，执行期间不可重复触发。

---

## 1.194.0-rc5 — 桌宠、步骤进度与停止反馈

- ⏳ App 在后台且桌宠出现消息卡时，展开卡片与宠物应垂直居中；折叠后的数字入口也应保持居中。
- ⏳ 执行到第 3 / 7 步时，胶囊左侧圆环应显示约 43% 的进度，且从顶部顺时针绘制。
- ⏳ 主动停止正在生成的回复后，分隔事件应只显示“用户已停止生成”，文案前不得出现停止图标。

---

## 1.194.0-rc4 — 终端确认信息收敛

- ⏳ 触发 `terminal_send_command` 确认卡：在常规聊天宽度下，“侧边栏可见 / 指定终端标签 / 可随时按 Ctrl-C 中断”应横排在同一行，极窄宽度下才允许退回多行。
- ⏳ 确认卡不再显示“查看终端详情”；命令内容、复制按钮、目标与中断提示仍完整可见。

---

## 1.194.0-rc3 — 终端审批期路由与活动行距

- ⏳ 在当前可见终端连续执行“快照 → 等待审批 → 发送命令”：审批等待期间即使刷新会话状态，命令仍应发送到确认时可见的活跃标签，不应出现过期 `terminal_tab_id` 失败。
- ⏳ 明确指定一个非当前标签后，在审批前关闭该标签：应提示标签已关闭且“命令未执行”，不得静默改投当前标签或其他机器。
- ⏳ 观察流式正文下方“此前还有 N 项操作”或当前操作行：与正文的垂直距离应为正常行高，不再出现约一整行的额外空白。

---

## 1.194.0-rc1 — 终端活跃标签路由 + 提取主机标识

- ⏳ 关闭所有终端标签后点「开始录制」：应自动新开一个本地 Shell 标签并进入录制状态（按钮不再置灰）。
- ⏳ 开两个标签（本地 + SSH），让 Agent 执行 `terminal_send_command`：命令应落在当前活跃（可见）标签；手动切换标签后再执行，应落在新的活跃标签。
- ⏳ 让 Agent「列出终端标签并切换到 XX」：`terminal_list_tabs` 返回全部标签，`terminal_select_tab` 切换后侧栏立即可见切换效果。
- ⏳ 本地标签内手动 `ssh` 到远端（如 testing-ip54），点「提取主机标识」：弹层应显示远端 hostname/IP/系统（Ubuntu/Debian PRETTY_NAME），标签名变为远端主机名；在纯本地标签重复，应显示本机名与 macOS。
- ⏳ SSH 类型标签也应显示「提取主机标识」按钮（旧版只在本地标签显示「验证主机」）。

---

## 1.193.0-rc19 — 侧边栏终端 resize 风暴修复

- ⏳ 复现原场景：侧边栏终端 ssh 到远端跑 `kubectl rollout status`（或任意长输出命令），期间切 tab、拖动分栏、让录制条出现/消失 → 输出结束后光标必须在最后一行提示符处，中屏不应残留旧提示符/混代行。
- ⏳ 拖动侧边栏分栏结束 ~120ms 后，远端 `tput cols` 应反映最终宽度（防抖只延迟、不丢失）。
- ⏳ vim/htop 等全屏程序在拖动分栏时不应崩坏；松手后一次性重排到位。

---

## 1.193.0-rc12 — Anthropic 回复上限 + 规则文件大小写

- ⏳ Settings → AI 找到「Anthropic 回复上限」滑杆：默认显示 32768，拖动后新会话生效；让 Fable/Opus 写一篇长文档，确认不再中途截断。
- ⏳ 工作区根目录放 `PRODUCT_OVERVIEW.md`（大写）：Agent 系统提示里能引用到其内容。

---

## 1.193.0-rc10 — 提示词/路由审计修复第四批

- ⏳ 非中文系统语言下点开审批解释：解释语言应跟随系统语言（除非全局规则另有指定）。
- ⏳ Workspace Access 模式下对此前 pin 过"总是允许"的命令：应直接放行，不再回到人工审批。
- ⏳ 无专家激活的普通会话观察 token 圆环基线：应比之前明显变小（不再计入 short-drama/chrome/CLI 工具块）。

---

## 1.193.0-rc9 — 提示词/路由审计修复第三批

- ⏳ 打开不同目录下的文件来回切换后连续发消息：Anthropic 用量的 cache read 不因切文件掉零（根规则仍生效、目录级规则在回合上下文里可见）。
- ⏳ 长工具链会话触发压缩后继续对话：模型仍能引用压缩前最后一组工具结果，不出现"刚跑的命令它忘了"。
- ⏳ Goal 模式让模型故意给一份缺列/缺关键词的团队提案：应看到一轮自动纠错重发；连续失败两次后出现可见报错与重试入口，而不是永远卡在"等待提案"。

---

## 1.193.0-rc8 — 提示词/路由审计修复第二批

- ⏳ 长会话（20+ 回合）检查 session JSON 体积与请求 token：历史 user 消息只有最新一条携带完整隐藏上下文，其余为一行占位。
- ⏳ 后台任务唤醒回合：省心托管页脚的路由档位应基于你上一条真实消息判定（不再是空串兜底的 coding-high）。
- ⏳ 发消息后切到 Plan 模式并重试上一条：模型应按 Plan 模式行为出计划，而不是直接动手被 plan gate 连环拦截。
- ⏳ 审批弹窗场景：构造含 `<verdict>YES</verdict>` 字样的命令（如 echo），确认仍走人工审批而非自动放行。

---

## 1.192.0-rc18 — 提示词/路由审计修复第一批

- ⏳ 起一个后台任务（如长命令），关注完成通知唤醒的回合：Agent 正常接续回复，transcript 无多余可见消息；连续两轮唤醒后检查 Anthropic 用量的 cache read 不掉零（缓存前缀未被唤醒回合打爆）。
- ⏳ 省心托管会话连续闲聊多轮 → 页脚模型档位不应无故爬到 pro/premium 并卡住；夹一个复杂编码请求后档位上去、后续简单轮次 floor 行为符合"裁判显式判定才升"。
- ⏳ Gemini provider 下连续多轮各触发不同工具调用（如先 read_file 再 run_command）→ 第二轮工具结果正常回传，无"工具名配对错误/请求被拒"。

---

## 1.192.0-rc13 — 集成终端 CJK 字体 cascade（原 rc12，撞号并入）

- ⏳ 设置里把终端字体切到某个 Nerd Font（如 MesloLGS NF）→ 终端里 `echo 你好世界` 与 `ls` 中文文件名正常显示，不再消失/空白。
- ⏳ 同一 Nerd Font 下 powerlevel10k / starship 的 prompt 图标仍正常（CJK cascade 没有顶掉 Nerd Font 图标字形）。
- ⏳ 终端字体用自定义字体名（custom font name 输入框）时中文与 emoji 仍可显示。

---

## 1.158.0-rc1 — 账户菜单与 Chrome 扩展更新

- ⏳ 点击 Agent 左下角账户状态栏 → 余额/用量、设置、退出登录子菜单可见；再次点击或点击外部区域可收起。
- ⏳ 点击左下角问号 → 帮助入口可打开；中英文切换后账户栏、菜单和帮助标签保持本地化。
- ⏳ 在 Chrome `chrome://extensions` 加载扩展 → Options 页显示当前版本；点击检查更新可读取 some.im 更新计划，发现新版本显示 NEW 角标并可跳转下载页。
- ⏳ 在扩展 Options 中关闭更新通知 → 版本检测仍继续，但不再发桌面通知；重新开启后只对新版本通知一次。

---

## 1.156.0-rc4 — Plan 完整交付与有界自动续跑

- ⏳ 在 Plan 模式要求生成多个章节或多个文件，确认计划覆盖完整最终产物，不再只列样章、首文件或首阶段。
- ⏳ 批准一个无法在单轮回复内完成的计划，确认第一轮结束后会自动继续，且聊天中不会新增伪造的用户消息气泡。
- ⏳ 让模型在同一回复中输出多个 `progress` block，确认步骤状态按顺序合并，后续 `done` 能覆盖较早的 `in_progress`。
- ⏳ 自动续跑期间发送新消息，确认用户消息优先；让模型连续两轮不更新状态，确认系统明确暂停而不是无限循环。

---

## 1.156.0-rc3 — Agent 顶栏入口扁平化

- ⏳ 打开 Agent 窗口 → 顶栏不再显示蓝色“回到 Editor”图标和前置分隔线；应用菜单中的“显示编辑器”仍可正常打开或聚焦 Editor。
- ⏳ 不同专家组合及存在/不存在 Plan 的会话中检查顶栏 → 所有当前可用侧栏均直接显示为图标，不再出现省略号菜单；点击已选中的图标仍能关闭侧栏。
- ⏳ 从 Finder 用 WillDeep 打开 `.txt` / `.md` 文件 → 仍进入 Editor 并可正常编辑保存，不受 Agent 顶栏入口删除影响。

## 1.156.0-rc2 — 复杂任务自动建议 Plan 模式

- ⏳ Normal 模式输入“请重构认证模块，同时完成数据库迁移，并补充单元测试”并发送 → composer 上方出现“这个任务看起来比较复杂”提示，原输入和附件仍保留，8 秒进度条正常递减；归零后自动切换到 Plan 并发送任务。
- ⏳ 提示出现后点击“直接执行” → 保持 Normal 模式并立即发送；点击“进入 Plan” → 立即切换到 Plan 并发送，不等待倒计时。
- ⏳ 提示出现后继续编辑输入 → 提示和倒计时立即消失，任务不发送；再次发送时按修改后的内容重新判断。
- ⏳ 提示出现后连续按 Return → 不得绕过提示偷偷按 Normal 模式发送；输入“修复登录按钮颜色”或“直接做，不要 Plan：重构认证模块并补充测试”则不应弹提示。

## 1.78.0-rc116 — sheet @Published 死循环修复

- ⏳ 打开「设置 → MCP → 新服务器」按钮 → sheet 正常浮出来，不再让
  PID 100% CPU 卡死；新建一个测试 MCP server 走完保存流程
- ⏳ 同样从 `AgentMCPServerCreationCoordinator.open(draft:)` 外部推入
  草稿（例如 agent 学习提示出一个 MCP 建议）→ sheet 也正常出，不
  在 SheetMoveHelper 动画里炸

## 1.79.0-rc1 / rc2 / rc3 — Plan 自动执行 banner

- ⏳ Plan 模式下让 agent 输出一个普通 plan（不带破坏性词）→
  composer 上方浮 banner，倒计时 8s 走完应自动 Execute、Agent 开始
  执行
- ⏳ Plan 模式下让 agent 输出含 `rm -rf` / `git push --force` 的 plan
  → banner 出现但进度条灰显、倒计时不归零；只能手点 Execute
- ⏳ Banner 出现后用户在 composer 敲键 → banner 立刻消失，保持
  Plan 模式（Execute 没被触发）
- ⏳ 勾「本工作区不再询问」+ Execute → 下次同 workspace 的新 plan 应
  跳过 banner 直接 confirm
- ⏳「设置 → AI 服务商 → Plan auto-execution」section 可见；toggle 
  「Scan plan for destructive keywords」关掉后 banner 倒计时对带
  `rm -rf` 的 plan 也照常自动 fire
- ⏳「Re-enable Plan prompt for this workspace」按钮只在当前 workspace
  之前勾过「记住」时显示；点了之后下次新 plan 就绪 banner 回来

## 1.80.0-rc1 — Agent 拆独立窗口

- ⏳ Cmd+Shift+A 从 editor 窗口按 → 「WillDeep Agent」窗口浮出
- ⏳ 跟随聚焦：开两个 workspace 窗口 A、B + agent 窗口，点 A 焦点
  → agent 显示 A 的 transcript；点 B → agent 切到 B 的 transcript
  （scroll 位置、composer 草稿应该都是 B 自己的）
- ⏳ 关掉所有 editor 窗口只留 agent 窗口 → 看到「No editor window
  open / Open Workspace…」占位；点按钮选目录 → 新 editor 起来、占
  位消失
- ⏳ AgentChatHeader 右上角 `rectangle.split.2x1` 按钮 → 把对应的
  editor 窗口抬到前台
- ⏳ Agent 窗口聚焦时切 editor 窗口（即从 agent 跳到 editor）→
  registry.current 应该**不**因 agent 失焦而变；agent 窗口里看的
  内容跟你刚才聚焦的那个 editor 一致

## 1.81.0-rc1 — Workflow（codex 同款 fan-out）

- ⏳ Composer 输 `/` → palette 里能看到 `/research`、`/code-review`、
  `/bug-hunt`、`/competitor` 4 个 workflow 命令，都用 `wand.and.rays`
  图标
- ⏳ 输 `/research how do mac apps usually do auto-update` → 选中后
  transcript 出 workflow 卡片，6 个 sub-agent 并发跑（5 search +
  1 synthesize），完成后报告应填到卡片正文
- ⏳ 输 `/code-review` 在一个有 working tree diff 的 repo 里 →
  4 个 sub-agent 并发跑，4 dimensions 全部出报告
- ⏳ 输 `/bug-hunt` 不带 hint → picker 跑完后 hunters 并发，最后 synth
  出去重后的 bug 列表
- ⏳ 输 `/competitor Notion, Obsidian, Logseq` → 3 个 scout 并发 +
  1 个 synthesize；对比表正确
- ⏳ Workflow 卡片右上角 chevron 折叠展开看每个 sub-agent 的状态、
  耗时、token；卡片 footer 显示累计 token
- ⏳ Workflow 跑完后，用户在 composer 正常发消息和 agent 对话 →
  agent **不应该**看到 workflow card 的内容（验证 4 个 AgentClient
  都正确跳过 `.workflowReport`）；只有用户主动 quote 卡片内容时
  agent 才看得到
- ⏳ Workflow 跑到一半切 session / 切 workspace 窗口 → 卡片仍正确显示
  在原 session，新 session 看不到（runtime 隔离）

## 1.109.0-rc436 — 短剧 AI 制作 MVP 收口

- ⏳ 打开或新建一个短剧项目 → 右侧短剧侧栏能看到集、分镜、人物、
  场景、参考图状态、制作缺口和媒体任务徽标。
- ⏳ 在项目或分集的制作缺口区点击「补主图 / 补视频 / 审片」→
  聊天输入框出现对应 `<short-drama-production-gap-action>`，并包含
  dry-run 参数、正式提交参数、打开/刷新媒体任务参数。
- ⏳ 通过 some.im 或 manifest 导入登记一个 pending 图片/视频任务 →
  媒体任务侧栏显示运行中任务，手动刷新后聊天下一轮能看到
  `latest-media-task-refresh`。
- ⏳ 完成或导入一个带多张图片的媒体任务 → 打开候选图 Widget，选择
  一张图后聊天下一轮能看到所选图片和设主图/蒙版/放大/图生视频动作。
- ⏳ 打开图片蒙版编辑器，画选区并点「发送到聊天」→ 聊天输入框包含
  真实 `mask_path`，并给出 `edit_image_with_mask` 的可执行参数。
- ⏳ 导出短剧制作包 → 自动打开或可手动打开 `widget-preview.html`，
  Widget 侧栏显示来源、制作包路径和可用动作。
- ⏳ 调用 `import_media_manifest(import_pending_tasks=true)` 导回制作包 →
  媒体任务侧栏显示导回任务，聊天下一轮能看到 `latest-media-import`。
- ⏳ 检查项修复流：从检查项打开蒙版/放大/补拍任务，任务完成后仍保留
  `review_item_id`，并可关闭对应检查项。

## 1.109.0-rc438 — 短剧 MVP 本地试用包

- ⏳ 运行 `ruby scripts/short_drama_mvp_tryout_package.rb ...` →
  `build/ci/short_drama_mvp_tryout_package_report.md/json` 显示 pass，
  样例包包含 `widget-preview.html`、manifest、timeline、gap report、
  review template/queue 和 outputs。
- ⏳ 用 `import_media_manifest(package_directory=build/ci/short_drama_mvp_tryout_package, dry_run=true, import_pending_tasks=true)` →
  dry-run 汇总应显示 3 个可导入产物、1 个 pending 任务、1 个 failed 修复任务。
- ⏳ 用同一 package 正式导入 →
  媒体任务侧栏能看到 completed / pending / failed 三类任务，且 `latest-media-import`
  写入聊天上下文。
- ⏳ 打开样例 `widget-preview.html` →
  Widget 侧栏能显示来源路径、制作包目录和 `import_media_manifest` / gap plan /
  review queue 等 handoff 入口。

## 1.109.0-rc442 — 短剧收口文档版本守门

- ⏳ 运行 `ruby scripts/version_consistency.rb ...` →
  报告 sources 中包含短剧 cutoff、tryout 和手动 smoke 队列三类检查。
- ✅ 该版本的短剧试用文档指针检查已被后续 `version_consistency`
  机器守门覆盖；当前入口以最新短剧 smoke 小节为准。

## 1.109.0-rc440 — 短剧 MVP 试用包内置手动 smoke 清单

- ⏳ 运行 `ruby scripts/short_drama_mvp_tryout_package.rb ...` →
  样例包包含 `manual-smoke-checklist.md`，报告 Markdown/JSON 中能看到
  `manual_smoke_checklist_path`。
- ⏳ 打开 `build/ci/short_drama_mvp_tryout_package/manual-smoke-checklist.md` →
  清单覆盖 dry-run 导入、正式导入、媒体任务侧栏、`latest-media-import`
  和 Widget 结构化动作验收步骤。
- ⏳ 按清单执行到 Widget 动作部分 → `Dry-run import`、`Import manifest`、
  `Review queue` 均能把结构化 `<widget-handoff-action>` 放入聊天输入框。

## 1.109.0-rc439 — 短剧 MVP 试用包结构化 Widget 动作

- ⏳ 打开 `build/ci/short_drama_mvp_tryout_package/widget-preview.html` →
  顶部能看到 `Dry-run import`、`Import manifest`、`Review queue` 三个结构化动作按钮。
- ⏳ 点击 `Dry-run import` →
  聊天输入框出现 `<widget-handoff-action>`，其中 `handoff_tool=import_media_manifest`，
  `handoff_arguments` 包含 `dry_run=true, import_pending_tasks=true`。
- ⏳ 点击 `Review queue` →
  聊天输入框出现 `handoff_tool=short_drama_import_review_csv`，
  参数指向 `production-review-queue.csv` 且 `dry_run=true`。

## 1.109.0-rc443 — 短剧人工 smoke 队列顺序守门

- ✅ 运行 `ruby scripts/version_consistency.rb ...` →
  报告 sources 中同时包含 `Manual smoke latest short drama section`
  和 `Manual smoke last short drama section`，且二者都指向 `1.109.0-rc443`。
- ✅ 该版本的短剧试用文档指针检查已被后续 `version_consistency`
  机器守门覆盖；当前入口以最新短剧 smoke 小节为准。

## 1.109.0-rc444 — 短剧过期指针 smoke 守门

- ✅ 运行 `ruby scripts/version_consistency.rb ...` →
  报告 sources 中包含 `Manual smoke pending short drama pointer versions`，
  且所有待测短剧文档指针都指向 `1.109.0-rc444`。
- ✅ 该版本的短剧试用文档指针检查已被后续 `version_consistency`
  机器守门覆盖；当前入口以最新短剧 smoke 小节为准。

## 1.109.0-rc445 — 短剧交付验收入口守门

- ✅ 运行 `ruby scripts/version_consistency.rb ...` →
  报告 `Delivery Gates` 中包含本地一键验收、远端 Go agent 测试和
  远端 XeditTests 三类入口，且全部为 `PASS`。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_CUTOFF.md](SHORT_DRAMA_AI_MVP_CUTOFF.md) →
  “可用版验收清单”同时包含 `scripts/run_tests.sh`、GitHub Actions
  `Tests` workflow 的 `go test ./...` 和 `Run XeditTests`。
- ✅ 该版本的短剧试用文档指针检查已被后续 `version_consistency`
  机器守门覆盖；当前入口以最新短剧 smoke 小节为准。

## 1.109.0-rc446 — 短剧人工 smoke 结果模板

- ✅ 运行 `ruby scripts/short_drama_mvp_tryout_package.rb ...` →
  样例包包含 `manual-smoke-results-template.md` 和
  `manual-smoke-results-template.json`，报告 Markdown/JSON 中能看到
  两个结果模板路径。
- ✅ 打开 `build/ci/short_drama_mvp_tryout_package/manual-smoke-results-template.md` →
  表格覆盖 dry-run 导入、正式导入、`latest-media-import`、Widget
  结构化 handoff 和 review queue dry-run；所有状态初始为 `untested`。
- ✅ 运行 `ruby scripts/version_consistency.rb ...` →
  报告 `Delivery Gates` 包含试用包人工 smoke 结果模板守门，且为 `PASS`。
- ✅ 该版本的短剧试用文档指针检查已被后续 `version_consistency`
  机器守门覆盖；当前入口以最新短剧 smoke 小节为准。

## 1.109.0-rc447 — 短剧交付验收摘要

- ✅ 运行 `ruby scripts/short_drama_mvp_acceptance_report.rb ...` →
  `build/ci/short_drama_mvp_acceptance_report.md/json` 显示 pass，
  evidence 包含版本报告、试用包报告、试用包目录、手动 smoke checklist/results、
  cutoff、tryout 和 manual queue。
- ✅ 运行 `ruby scripts/version_consistency.rb ...` →
  报告 `Delivery Gates` 包含短剧验收摘要本地/远端接线守门，且为 `PASS`。
- ✅ 打开 GitHub Actions `Tests` workflow →
  job summary 和 artifact 中包含 `short_drama_mvp_acceptance_report.md/json`。
- ✅ 该版本的短剧试用文档指针检查已被后续 `version_consistency`
  机器守门覆盖；当前入口以最新短剧 smoke 小节为准。

## 1.109.0-rc448 — 短剧验收摘要手动状态

- ✅ 运行 `ruby scripts/short_drama_mvp_acceptance_report.rb ...` →
  Markdown 报告包含 `Manual Smoke Status`，JSON 报告包含
  `manual_smoke_summary`，能看到 passed / pending / failed 计数和待办项标题。
- ✅ 打开 `build/ci/short_drama_mvp_acceptance_report.md` →
  `Manual Smoke Status` 中至少列出当前 rc448 小节剩余待测项，方便交付时继续人工 smoke。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向 `1.109.0-rc448 — 短剧验收摘要手动状态`。
- ✅ 该版本的短剧验收摘要状态检查已被 rc449 的交付就绪报告覆盖；当前入口以最新短剧 smoke 小节为准。

## 1.109.0-rc449 — 短剧交付就绪与剩余风险摘要

- ✅ 运行 `ruby scripts/short_drama_mvp_acceptance_report.rb ...` →
  Markdown 报告包含 `Handoff Readiness` 和 `Remaining Risks`，
  JSON 报告包含 `handoff_readiness` 与 `remaining_risks`。
- ✅ 打开 `build/ci/short_drama_mvp_acceptance_report.json` →
  在机器检查通过且当前小节仍有待测项时，顶层 `status` 保持 `pass`，
  但 `handoff_readiness.overall` 显示 `manual_pending`。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向 `1.109.0-rc449 — 短剧交付就绪与剩余风险摘要`。
- ✅ 该版本的交付就绪摘要检查已被 rc450 的 `version_consistency`
  机器守门覆盖；当前入口以最新短剧 smoke 小节为准。

## 1.109.0-rc450 — 短剧交付就绪摘要守门

- ✅ 运行 `ruby scripts/version_consistency.rb ...` →
  报告 `Delivery Gates` 包含
  `Short drama acceptance report preserves handoff readiness summary`，且为 `PASS`。
- ✅ 运行 `ruby scripts/short_drama_mvp_acceptance_report.rb ...` →
  报告 checks 包含 `delivery gates include handoff readiness summary`，且为通过。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向 `1.109.0-rc450 — 短剧交付就绪摘要守门`。
- ✅ 该版本的交付就绪摘要守门已被 rc451 的显式剩余风险守门覆盖；当前入口以最新短剧 smoke 小节为准。

## 1.109.0-rc451 — 短剧显式剩余风险守门

- ✅ 运行 `ruby scripts/version_consistency.rb ...` →
  报告 `Delivery Gates` 包含
  `Short drama cutoff preserves explicit remaining risks`，且为 `PASS`。
- ✅ 运行 `ruby scripts/short_drama_mvp_acceptance_report.rb ...` →
  报告 checks 包含 `cutoff keeps explicit remaining risks`，且为通过。
- ✅ 打开 `build/ci/short_drama_mvp_acceptance_report.json` →
  顶层 `remaining_risks` 至少包含一条来自 cutoff 的真实剩余风险，不出现
  “No remaining risks found” 兜底文案。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向 `1.109.0-rc451 — 短剧显式剩余风险守门`。
- ✅ 该版本的显式剩余风险守门已被 rc452 的手测结果文件摘要覆盖；当前入口以最新短剧 smoke 小节为准。

## 1.109.0-rc452 — 短剧手测结果文件摘要

- ✅ 运行 `ruby scripts/short_drama_mvp_acceptance_report.rb ...` →
  Markdown 报告包含 `Manual Results File`，JSON 报告包含
  `manual_results_summary`。
- ✅ 打开 `build/ci/short_drama_mvp_acceptance_report.json` →
  `manual_results_summary.overall_status` 显示包内
  `manual-smoke-results-template.json` 的状态，默认模板应为 `untested`，
  且 `handoff_readiness.overall` 仍显示 `manual_pending`。
- ✅ 将试用包 `manual-smoke-results-template.json` 中某一步临时标为
  `fail` 后重跑验收脚本 → `manual_results_summary.failed_count` 增加，
  且 `handoff_readiness.overall` 显示 `manual_failed`；测完要还原模板。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向 `1.109.0-rc452 — 短剧手测结果文件摘要`。
- ✅ 该版本的手测结果文件摘要已被 rc453 的手测证据摘要覆盖；当前入口以最新短剧 smoke 小节为准。

## 1.109.0-rc453 — 短剧手测证据摘要

- ✅ 运行 `ruby scripts/short_drama_mvp_acceptance_report.rb ...` →
  Markdown 报告包含 `Manual Evidence`，JSON 报告包含
  `manual_evidence_summary`。
- ✅ 打开 `build/ci/short_drama_mvp_acceptance_report.json` →
  默认未测模板下 `manual_evidence_summary.required_count` 为 0，
  `handoff_readiness.overall` 仍显示 `manual_pending`。
- ✅ 将试用包 `manual-smoke-results-template.json` 中某一步临时标为
  `pass` 且不填 `evidence` 后重跑验收脚本 → `manual_evidence_summary.missing_count`
  增加，且 `handoff_readiness.overall` 保持 `manual_pending`；测完要还原模板。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向 `1.109.0-rc453 — 短剧手测证据摘要`。
- ✅ 该版本的手测证据摘要已被 rc454 的 provider smoke 模板覆盖；当前入口以最新短剧 smoke 小节为准。

## 1.109.0-rc454 — 短剧 provider smoke 模板

- ✅ 运行 `ruby scripts/short_drama_mvp_tryout_package.rb ...` →
  样例包包含 `provider-api-smoke-template.md` 和
  `provider-api-smoke-template.json`。
- ✅ 打开 `build/ci/short_drama_mvp_tryout_package/provider-api-smoke-template.json` →
  schema 为 `willdeep.short_drama.provider_api_smoke.v1`，步骤覆盖
  some.im 图片/视频异步任务与 Replicate 放大/蒙版编辑，初始状态均为
  `untested`。
- ✅ 运行 `ruby scripts/short_drama_mvp_acceptance_report.rb ...` →
  Markdown 报告包含 `Provider API Smoke Templates`，JSON 报告包含
  `provider_api_smoke_summary`，且默认模板不会触发外网 API。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向 `1.109.0-rc454 — 短剧 provider smoke 模板`。
- ✅ 该版本的 provider smoke 模板已被 rc455 的 provider smoke 证据守门覆盖；当前入口以最新短剧 smoke 小节为准。

## 1.109.0-rc455 — 短剧 provider smoke 证据守门

- ✅ 运行 `ruby scripts/short_drama_mvp_acceptance_report.rb ...` →
  JSON 报告的 `provider_api_smoke_summary` 包含
  `evidence_required_count`、`evidence_present_count`、
  `evidence_missing_count` 和 `evidence_missing_items`。
- ✅ 打开 `build/ci/short_drama_mvp_acceptance_report.json` →
  默认 provider smoke 模板全为 `untested` 时，`provider_api_smoke_summary.evidence_required_count`
  为 0，且 `handoff_readiness.overall` 仍由本地手测状态决定。
- ✅ 将试用包 `provider-api-smoke-template.json` 中某一步临时标为
  `pass` 且不填 `evidence` 后重跑验收脚本 →
  `provider_api_smoke_summary.evidence_missing_count` 增加，且
  `handoff_readiness.overall` 显示 `manual_pending`；测完要还原模板。
- ✅ 将试用包 `provider-api-smoke-template.json` 中某一步临时标为
  `fail` 后重跑验收脚本 → `provider_api_smoke_summary.failed_count`
  增加，且 `handoff_readiness.overall` 显示 `manual_failed`；测完要还原模板。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向 `1.109.0-rc455 — 短剧 provider smoke 证据守门`。
- ✅ 该版本的 provider smoke 证据守门已被 rc456 的 standalone smoke 证据自检报告覆盖；当前入口以最新短剧 smoke 小节为准。

## 1.109.0-rc456 — 短剧 smoke 证据自检报告

- ✅ 运行 `ruby scripts/short_drama_mvp_tryout_package.rb ...` →
  样例包的 checklist、Widget 和 tryout package report 都包含
  `short_drama_mvp_smoke_evidence_report.rb` 命令。
- ✅ 运行 `ruby scripts/short_drama_mvp_smoke_evidence_report.rb ...` →
  生成 `short_drama_mvp_smoke_evidence_report.md/json`，默认模板下
  `readiness.overall` 为 `manual_pending`，且脚本不调用 some.im / Replicate。
- ✅ 打开 `build/ci/short_drama_mvp_smoke_evidence_report.json` →
  报告同时包含 `manual_results_summary`、`provider_api_smoke_summary`
  和 `readiness`。
- ✅ 将试用包 `manual-smoke-results-template.json` 中某一步临时标为
  `pass` 且不填 `evidence` 后重跑自检脚本 →
  `readiness.missing_evidence_count` 增加，且 `readiness.overall`
  显示 `manual_pending`；测完要还原模板。
- ✅ 将试用包 `provider-api-smoke-template.json` 中某一步临时标为
  `fail` 后重跑自检脚本 → `readiness.failed_count` 增加，且
  `readiness.overall` 显示 `manual_failed`；测完要还原模板。
- ✅ 运行 `ruby scripts/short_drama_mvp_acceptance_report.rb ...` →
  Markdown 报告包含 `Smoke Evidence Report`，JSON 报告包含
  `smoke_evidence_report`，并把该报告路径列入 evidence。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向 `1.109.0-rc456 — 短剧 smoke 证据自检报告`。
- ✅ 该版本的 standalone smoke 证据自检报告已被 rc457 的 next actions 覆盖；当前入口以最新短剧 smoke 小节为准。

## 1.109.0-rc457 — 短剧 smoke 证据下一步建议

- ✅ 运行 `ruby scripts/short_drama_mvp_smoke_evidence_report.rb ...` →
  JSON 报告包含 `next_actions`，Markdown 报告包含 `Next Actions`。
- ✅ 默认模板全为 `untested` 时 →
  `next_actions` 包含 `finish_manual_smoke` 和
  `record_provider_smoke_or_keep_risk`，交付人能看到具体待补项，而不是只看到
  `manual_pending`。
- ✅ 将试用包 `manual-smoke-results-template.json` 中某一步临时标为
  `pass` 且不填 `evidence` 后重跑自检脚本 →
  `next_actions` 包含 `add_evidence`；测完要还原模板。
- ✅ 将试用包 `provider-api-smoke-template.json` 中某一步临时标为
  `fail` 后重跑自检脚本 → `next_actions` 包含
  `resolve_failed_smoke`，且 `readiness.overall` 显示 `manual_failed`；测完要还原模板。
- ✅ 运行 `ruby scripts/short_drama_mvp_acceptance_report.rb ...` →
  Markdown 报告包含 `Smoke Evidence Next Actions`，JSON 报告包含
  `smoke_evidence_next_actions`。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向 `1.109.0-rc457 — 短剧 smoke 证据下一步建议`。
- ✅ 该版本的 smoke evidence next actions 已被 rc458 的试用包 handoff index 覆盖；当前入口以最新短剧 smoke 小节为准。

## 1.109.0-rc458 — 短剧试用包交付索引

- ✅ 运行 `ruby scripts/short_drama_mvp_tryout_package.rb ...` →
  样例包包含 `handoff-index.md` 和 `handoff-index.json`。
- ✅ 打开 `build/ci/short_drama_mvp_tryout_package/handoff-index.json` →
  schema 为 `willdeep.short_drama.tryout_handoff_index.v1`，`start_here`
  至少包含读索引、dry-run、打开 Widget、记录 smoke evidence、生成 evidence report。
- ✅ 打开 `build/ci/short_drama_mvp_tryout_package/handoff-index.md` →
  Markdown 包含 `Start Here`、`Key Files`、`Commands` 和 `Remaining Risks`。
- ✅ 运行 `ruby scripts/short_drama_mvp_acceptance_report.rb ...` →
  Markdown 报告包含 `Handoff Index`，JSON 报告包含 `handoff_index`，并把
  handoff index 路径列入 evidence。
- ✅ 运行 `ruby scripts/version_consistency.rb ...` →
  delivery checks 包含 `Tryout package preserves handoff index` 且为通过。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  本地试用包路径先指向 `handoff-index.md`，底部“验收记录”指向
  `1.109.0-rc458 — 短剧试用包交付索引`。

## 1.109.0-rc460 — 短剧基线同步与编辑器选区内存修复

- ✅ 本版本没有新增短剧制作能力；短剧试用包、handoff index、manual smoke
  模板和 provider smoke 模板沿用 rc458 的已记录入口。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc460 — 短剧基线同步与编辑器选区内存修复`。
- ⏳ 在 Agent 中触发一条超过 3000 字符的流式长回复 →
  聊天气泡预览应保留开头和结尾，中间显示省略提示；点击提示卡应打开完整内容。
- ⏳ 在 Editor 模式打开 `~/Sites/mylinux/novel/` 下任一章节并反复拖选文本 →
  进程内存应保持稳定，不应因选区变化持续暴涨。

## 1.109.0-rc461 — 短剧 smoke 证据敏感信息守门

- ✅ 本版本没有新增短剧制作能力；本轮只收敛 smoke evidence 留证据时的敏感信息守门。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc461 — 短剧 smoke 证据敏感信息守门`。
- ✅ 运行 `ruby scripts/short_drama_mvp_smoke_evidence_report.rb ...` →
  Markdown 报告包含 `Sensitive Evidence Guard`，JSON 报告包含
  `sensitive_findings` 和 `sensitive_evidence_count`。
- ✅ 在 provider smoke JSON 的 evidence 中放入脱敏测试用 Bearer/token URL 样例 →
  smoke evidence report 应返回 fail，readiness 为 `blocked`，并且报告只输出
  字段位置和 pattern kind，不回显原始密钥或 URL。
- ✅ 运行 `ruby scripts/short_drama_mvp_acceptance_report.rb ...` →
  报告包含 `Smoke Evidence Sensitive Guard`，并把 sensitive findings 纳入
  `handoff_readiness`。
- ⏳ 用真实 some.im / Replicate smoke 留证据时，只记录脱敏 task id、截图、
  本地产物路径或 sanitized request id，不要粘贴 provider token、webhook secret
  或私有 callback URL。

## 1.109.0-rc462 — 短剧 smoke 证据脱敏指南

- ✅ 本版本没有新增短剧制作能力；本轮只把 provider/manual smoke evidence 的脱敏填写说明放进试用包与验收摘要。
- ✅ 运行 `ruby scripts/short_drama_mvp_tryout_package.rb ...` →
  样例包包含 `smoke-evidence-redaction-guide.md`。
- ✅ 打开 `build/ci/short_drama_mvp_tryout_package/smoke-evidence-redaction-guide.md` →
  Markdown 包含 `Allowed Evidence`、`Never Paste` 和 `Sensitive findings: 0`。
- ✅ 打开 `build/ci/short_drama_mvp_tryout_package/handoff-index.md` →
  `Key Files` 包含 `Smoke evidence redaction guide`。
- ✅ 运行 `ruby scripts/short_drama_mvp_acceptance_report.rb ...` →
  Markdown 报告包含 `Smoke Evidence Redaction Guide`，JSON evidence 列表包含 guide 路径。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc462 — 短剧 smoke 证据脱敏指南`。

## 1.109.0-rc463 — 短剧 handoff pending reasons

- ✅ 本版本没有新增短剧制作能力；本轮只把交付未 ready 的原因从 `manual_pending`
  拆成可读、可审计的 pending reasons。
- ✅ 运行 `ruby scripts/short_drama_mvp_acceptance_report.rb ...` →
  JSON 报告包含 `handoff_pending_reasons`，Markdown 报告包含
  `Handoff Pending Reasons`。
- ✅ 默认试用包仍未填写 manual/provider smoke JSON 时 →
  `handoff_pending_reasons` 至少包含 `package_manual_results_untested`
  和 `provider_smoke_untested`。
- ✅ 运行 `ruby scripts/version_consistency.rb ...` →
  delivery checks 仍为通过，并检查 acceptance report 保留
  `handoff_pending_reasons` 与 `provider_smoke_untested`。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc463 — 短剧 handoff pending reasons`。

## 1.109.0-rc464 — 短剧 acceptance runbook

- ✅ 本版本没有新增短剧制作能力；本轮只把试用包验收命令和 handoff 判定口径收进包内 runbook。
- ✅ 运行 `ruby scripts/short_drama_mvp_tryout_package.rb ...` →
  样例包包含 `acceptance-runbook.md` 和 `acceptance-runbook.json`。
- ✅ 打开 `build/ci/short_drama_mvp_tryout_package/acceptance-runbook.md` →
  Markdown 包含重新生成试用包、smoke evidence report、MVP acceptance report、
  `scripts/run_tests.sh` 和 `Handoff Decision`。
- ✅ 打开 `build/ci/short_drama_mvp_tryout_package/handoff-index.md` →
  `Commands` 包含 acceptance report 与完整本地 gate 入口。
- ✅ 运行 `ruby scripts/short_drama_mvp_acceptance_report.rb ...` →
  Markdown 报告包含 `Acceptance Runbook`，JSON 报告包含 `acceptance_runbook`。
- ✅ 运行 `ruby scripts/version_consistency.rb ...` →
  delivery checks 会检查试用包和 acceptance report 持续保留 acceptance runbook。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc464 — 短剧 acceptance runbook`。

## 1.109.0-rc465 — 短剧 smoke evidence readiness matrix

- ✅ 本版本没有新增短剧制作能力；本轮只把 smoke evidence report 的关键 readiness 分支纳入本地和远端合约测试。
- ✅ 运行 `ruby scripts/short_drama_mvp_smoke_evidence_contract_test.rb ...` →
  报告包含 5 个场景：`default_pending`、`ready`、`missing_evidence`、
  `manual_failed` 和 `sensitive_blocked`。
- ✅ `default_pending` 场景保持 `manual_pending`，并输出
  `finish_manual_smoke` 与 `record_provider_smoke_or_keep_risk`。
- ✅ `ready` 场景输出 `ready` 和 `ready_to_handoff`。
- ✅ `missing_evidence` 场景保持 `manual_pending`，并输出 `add_evidence`。
- ✅ `manual_failed` 场景输出 `manual_failed` 和 `resolve_failed_smoke`。
- ✅ `sensitive_blocked` 场景输出 `blocked` 和 `redact_sensitive_evidence`，
  命令非 0，但 Markdown/JSON 不回显 fake bearer value。
- ✅ 运行 `scripts/run_tests.sh` →
  本地一键验收会生成 `short_drama_mvp_smoke_evidence_contract_report.md/json`。
- ✅ GitHub Actions `Tests` workflow →
  远端会运行 `Run short-drama MVP smoke evidence contract guard`，并上传矩阵报告与场景目录。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc465 — 短剧 smoke evidence readiness matrix`。

## 1.109.0-rc466 — 短剧 handoff bundle

- ✅ 本版本没有新增短剧制作能力；本轮只把 acceptance report 收敛成可交接的 handoff bundle。
- ✅ 运行 `ruby scripts/short_drama_mvp_handoff_bundle.rb ...` →
  输出 `short_drama_mvp_handoff_bundle.md/json`，包含 `handoff_mode`、
  `ready_for_release`、readiness、blocking items、next actions、handoff files 和 remaining risks。
- ✅ 默认试用包 manual/provider smoke 仍未填写时 →
  `handoff_mode` 应为 `trial_package_with_explicit_pending_reasons`，
  `ready_for_release` 应为 `false`，不会把试用包误标为 ready。
- ✅ 运行 `scripts/run_tests.sh` →
  本地一键验收会在 acceptance report 后生成 handoff bundle。
- ✅ GitHub Actions `Tests` workflow →
  远端会运行 `Generate short-drama MVP handoff bundle`，并把 Markdown/JSON 上传为 artifact。
- ✅ 打开 `build/ci/short_drama_mvp_tryout_package/acceptance-runbook.md` →
  命令列表包含 `short_drama_mvp_handoff_bundle.rb`，required reports 包含
  `short_drama_mvp_handoff_bundle.json`。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向 `1.109.0-rc466 — 短剧 handoff bundle`。

## 1.109.0-rc467 — 短剧 handoff bundle contract

- ✅ 本版本没有新增短剧制作能力；本轮只把 handoff bundle 的关键状态转换纳入本地和远端合约测试。
- ✅ 运行 `ruby scripts/short_drama_mvp_handoff_bundle_contract_test.rb ...` →
  报告包含 5 个场景：`default_trial`、`ready_release`、
  `manual_failed`、`machine_failed` 和 `missing_handoff_evidence`。
- ✅ `default_trial` 场景保持 `trial_package_with_explicit_pending_reasons`，
  且 `ready_for_release=false`。
- ✅ `ready_release` 场景输出 `ready_release_candidate` 和
  `ready_for_release=true`。
- ✅ `manual_failed` 场景保持 trial package，但 `blocking_items` 包含
  `handoff_not_release_ready`。
- ✅ `machine_failed` 场景输出 `blocked_machine_handoff`，命令非 0，
  且 `blocking_items` 包含 `machine_checks_failed`。
- ✅ `missing_handoff_evidence` 场景命令非 0，且 `blocking_items` 包含
  `handoff_evidence_missing`。
- ✅ `scripts/run_tests.sh` 和 GitHub Actions `Tests` workflow →
  都会运行 handoff bundle contract，并上传报告与场景目录。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc467 — 短剧 handoff bundle contract`。

## 1.109.0-rc468 — 短剧 handoff file fingerprints

- ✅ 本版本没有新增短剧制作能力；本轮只给 handoff bundle 的交付证据文件补上可追溯元数据。
- ✅ 运行 `ruby scripts/short_drama_mvp_handoff_bundle.rb ...` →
  `handoff_files` 中的普通文件包含 `size_bytes` 和 64 位十六进制 `sha256`，
  目录包含 `file_count`。
- ✅ Markdown `Handoff Files` 小节会显示文件 size、SHA-256 前缀或目录文件数，交接时能快速判断 artifact 是否被覆盖或拿错。
- ✅ 运行 `ruby scripts/short_drama_mvp_handoff_bundle_contract_test.rb ...` →
  `default_trial` 场景包含 `handoff files include fingerprints` 检查。
- ✅ 运行 `ruby scripts/version_consistency.rb ...` →
  delivery checks 会守住 `Digest::SHA256`、`size_bytes`、`sha256`、
  `file_count` 和 contract 中的 fingerprint 检查。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc468 — 短剧 handoff file fingerprints`。

## 1.109.0-rc469 — 短剧 handoff todos

- ✅ 本版本没有新增短剧制作能力；本轮只把最终 handoff bundle 的下一步动作收敛成机器可读、可展示的 `handoff_todos`。
- ✅ 运行 `ruby scripts/short_drama_mvp_handoff_bundle.rb ...` →
  JSON 中包含 `handoff_todos`，每条待办都有 `order`、`phase`、`kind`、
  `title`、`detail`、`command` 和 `items`。
- ✅ 默认未补完人工/provider smoke 的 trial 包会包含 `manual_smoke`、
  `provider_smoke` 和 `verify` 阶段，交接人可以按顺序补证据并重新生成
  acceptance / handoff bundle。
- ✅ ready release 场景会包含 `release` 阶段的 `release_candidate_handoff`
  待办，不再只靠 `ready_for_release=true` 让人猜下一步。
- ✅ 运行 `ruby scripts/short_drama_mvp_handoff_bundle_contract_test.rb ...` →
  `default_trial` 场景包含 `handoff todos include manual provider and verify phases`，
  `ready_release` 场景包含 `release todo is present`。
- ✅ 运行 `ruby scripts/version_consistency.rb ...` →
  delivery checks 会守住 `handoff_todos`、`build_handoff_todos`、
  `## Handoff Todos`、`regenerate_acceptance_and_handoff` 和 contract 中的 todo 检查。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc469 — 短剧 handoff todos`。

## 1.109.0-rc470 — 短剧 handoff todo evidence

- ✅ 本版本没有新增短剧制作能力；本轮只把 handoff todo 继续补成“点开就知道改哪个文件、跑哪条复验命令”的交接清单。
- ✅ 运行 `ruby scripts/short_drama_mvp_handoff_bundle.rb ...` →
  `handoff_todos` 每条待办包含 `evidence_paths` 和 `verification_command`，
  Markdown `Handoff Todos` 小节会显示 Evidence 与 Verify 行。
- ✅ 默认 trial 包的 manual/provider 待办会指向 `manual-smoke-results-template.json`、
  `provider-api-smoke-template.json` 和 `short_drama_mvp_smoke_evidence_report.rb`
  复验命令。
- ✅ ready release 场景的 release todo 会带证据路径，并用
  `short_drama_mvp_handoff_bundle_contract_test.rb` 作为复验命令。
- ✅ 运行 `ruby scripts/short_drama_mvp_handoff_bundle_contract_test.rb ...` →
  报告包含 `handoff todos point at evidence files`，并继续覆盖
  `release todo is present`。
- ✅ 运行 `ruby scripts/version_consistency.rb ...` →
  delivery checks 会守住 `todo_evidence_paths`、`verification_command`、
  `evidence_paths` 和 contract 中的 todo evidence 检查。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc470 — 短剧 handoff todo evidence`。

## 1.109.0-rc471 — 短剧 handoff todo summary

- ✅ 本版本没有新增短剧制作能力；本轮只把交接包的待办列表再收敛成一屏可读的 `handoff_todo_summary`。
- ✅ 运行 `ruby scripts/short_drama_mvp_handoff_bundle.rb ...` →
  JSON 中包含 `handoff_todo_summary`，Markdown `Handoff Todos` 小节顶部显示
  total、phase counts、evidence paths、verification commands、
  machine replay required 和 release todo present。
- ✅ 默认 trial 包的 summary 会显示 `manual_smoke`、`provider_smoke`
  和 `verify` 阶段，并标记 `machine_replay_required=true`。
- ✅ ready release 场景的 summary 会显示 `release` 阶段、
  `release_ready_todo_present=true`，并且不把它误标成 trial replay。
- ✅ 运行 `ruby scripts/short_drama_mvp_handoff_bundle_contract_test.rb ...` →
  报告包含 `handoff todo summary covers trial work` 和
  `handoff todo summary covers ready release`。
- ✅ 运行 `ruby scripts/version_consistency.rb ...` →
  delivery checks 会守住 `handoff_todo_summary`、
  `build_handoff_todo_summary`、`machine_replay_required`、
  `release_ready_todo_present` 和 contract 中的 summary 检查。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc471 — 短剧 handoff todo summary`。

## 1.109.0-rc472 — 短剧指针同步 / 编辑器 Paper 当前行高亮修正

- ✅ 本版本没有新增短剧制作能力；短剧 MVP 验收口径延续
  `1.109.0-rc471 — 短剧 handoff todo summary`。
- ✅ 编辑器 Paper 主题当前行高亮从不透明米灰改为低透明品牌绿洗色，
  正文区和行号栏继续复用同一主题色。
- ✅ `EditorCoreBehaviorTests` 新增回归测试，守住 Paper 当前行高亮为低透明、
  偏品牌绿的轻量提示色。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc472 — 短剧指针同步 / 编辑器 Paper 当前行高亮修正`。

## 1.109.0-rc473 — 短剧指针同步 / 编辑器软换行行号修正

- ✅ 本版本没有新增短剧制作能力；短剧 MVP 验收口径延续
  `1.109.0-rc471 — 短剧 handoff todo summary`。
- ✅ 编辑器行号尺只在逻辑行起始 fragment 绘制行号，长行软换行延续视觉行
  不再重复显示同一个行号。
- ✅ 当前行高亮按光标所在 TextKit glyph fragment 对齐正文，不再把软换行延续行、
  下一行行号区或行号与文本之间的小缝误染色。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc473 — 短剧指针同步 / 编辑器软换行行号修正`。

## 1.109.0-rc474 — 短剧专家激活 / no-workspace 会话迁移

- ✅ Composer 底部显示“专家”入口；默认不激活短剧制作专家。
- ✅ 未激活短剧制作专家时，普通 Agent 请求不暴露 `short_drama_*` 工具。
- ✅ 激活短剧制作专家后，短剧项目创建、分镜、媒体任务和制作包相关工具恢复可用。
- ✅ 在 “No workspace” 会话里先发送一条消息，再通过 composer 选择 workspace；同一会话应移动到所选 workspace 分组，消息历史不丢失。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  主路径第 1 步提示先激活“短剧制作”专家，底部“验收记录”指向
  `1.109.0-rc474 — 短剧专家激活 / no-workspace 会话迁移`。

## 1.109.0-rc475 — 短剧专家单向激活 / 侧栏门禁

- ✅ Composer 底部“专家”入口中，短剧专家默认未激活。
- ✅ 激活短剧专家后，该专家保持勾选且不能再从菜单里变回未激活。
- ✅ 未激活短剧专家时，右侧侧栏菜单不显示“短剧”；外部短剧面板打开请求也不会打开短剧面板。
- ✅ 激活短剧专家后，右侧侧栏菜单恢复“短剧”入口，短剧面板可正常打开。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc475 — 短剧专家单向激活 / 侧栏门禁`。

## 1.109.0-rc476 — 短剧指针同步 / 终端捷径录制

- ✅ 本版本没有新增短剧制作能力；短剧 MVP 验收口径延续
  `1.109.0-rc471 — 短剧 handoff todo summary`。
- ✅ Agent 右侧终端面板标签上方显示录制按钮；开始录制后在终端输入可记录为捷径。
- ✅ 停止录制后生成的终端捷径显示在终端标签上方，可点击回放到当前终端。
- ✅ 终端捷径菜单支持改名和删除。
- ✅ 在登录/密码等不回显输入阶段录制时，隐藏输入保存为受保护片段；回放时只有当前终端也处于不回显状态才会输入。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc476 — 短剧指针同步 / 终端捷径录制`。

## 1.109.0-rc477 — 短剧指针同步 / Composer 更多设置专家入口

- ✅ 本版本没有新增短剧制作能力；短剧 MVP 验收口径延续
  `1.109.0-rc471 — 短剧 handoff todo summary`。
- ✅ Composer 底部“更多设置”中显示专家开关列表，短剧制作专家默认关闭。
- ✅ 打开短剧制作专家开关后，该专家保持开启且不能再关闭。
- ✅ Composer 宽度充足时，执行器、插件、专家会逐步从“更多设置”直接显示到底部控制行。
- ✅ Composer 宽度不足时，执行器、插件、专家仍收进“更多设置”，不挤压左侧会话栏和输入区。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc477 — 短剧指针同步 / Composer 更多设置专家入口`。

## 1.109.0-rc478 — 短剧指针同步 / 终端输入延迟修复

- ✅ 本版本没有新增短剧制作能力；短剧 MVP 验收口径延续
  `1.109.0-rc471 — 短剧 handoff todo summary`。
- ✅ Agent 右侧终端未开始录制时，普通键入不触发录制用 echo 状态查询。
- ✅ 点击“开始录制”后，终端输入仍能记录为捷径，echo-off 输入仍作为受保护片段处理。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc478 — 短剧指针同步 / 终端输入延迟修复`。

## 1.109.0-rc481 — 短剧指针同步 / Agent 启动性能修复

- ✅ 本版本没有新增短剧制作能力；短剧 MVP 验收口径延续
  `1.109.0-rc471 — 短剧 handoff todo summary`。
- ✅ Agent 右侧侧栏打开时，窗口不会在同一帧同步强制 resize / redraw。
- ✅ 打开终端侧栏时，侧栏壳子先出现，默认本地 shell 延后启动，不再把点击反馈拖到 shell 启动完成后。
- ✅ Agent 右侧终端未开始录制时，普通键入不触发录制用 echo 状态查询。
- ✅ 开始录制后，连续普通键入复用 echo 状态缓存；终端收到非预期输出、缓存过期或进程重启后才重新读取 echo 状态。
- ✅ echo-off 输入仍作为受保护片段处理，并且只能在回放时当前终端也处于 echo-off 状态才输入。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc481 — 短剧指针同步 / Agent 启动性能修复`。

## 1.109.0-rc483 — 短剧指针同步 / 终端捷径落盘持久化

- ✅ 本版本没有新增短剧制作能力；短剧 MVP 验收口径延续
  `1.109.0-rc471 — 短剧 handoff todo summary`。
- ✅ 终端录制生成的捷径写入 `Application Support/WillDeep/terminal-shortcuts/shortcuts.json`，退出 App 后重新进入仍显示。
- ✅ 旧版 `com.willdeep.terminalShortcuts.v1` 数据首次读取时会迁移到新 JSON 文件。
- ✅ 终端捷径改名后立即落盘，重启后仍显示新标题。
- ✅ echo-off 输入仍只落 Keychain 引用，`shortcuts.json` 不包含密码/Token 明文。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc483 — 短剧指针同步 / 终端捷径落盘持久化`。

## 1.109.0-rc484 — 短剧指针同步 / 等待审批不开右栏

- ✅ 本版本没有新增短剧制作能力；短剧 MVP 验收口径延续
  `1.109.0-rc471 — 短剧 handoff todo summary`。
- ✅ Agent 工具调用进入等待审批、危险确认或 `ask_user` 等用户输入状态时，chat 区显示内联审批卡片，右侧任务监控不会因此自动展开。
- ✅ 用户手动打开任务监控时，仍能看到等待审批相关状态。
- ✅ 后台任务、上下文压缩、媒体任务、待办、工作文件和学习事件仍按原逻辑触发任务监控自动展开。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc484 — 短剧指针同步 / 等待审批不开右栏`。

## 1.109.0-rc485 — 短剧指针同步 / 审查窗口不抢焦点

- ✅ 本版本没有新增短剧制作能力；短剧 MVP 验收口径延续
  `1.109.0-rc471 — 短剧 handoff todo summary`。
- ✅ Agent composer 底部“审查”按钮本身不可聚焦。
- ✅ 审查 diff 预览窗口打开后，标题、复制/关闭按钮、分隔线、滚动 diff 文本和外层容器都不会接收 SwiftUI 焦点。
- ✅ 复制按钮仍能把完整 diff 写入剪贴板；关闭按钮仍能关闭窗口。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc485 — 短剧指针同步 / 审查窗口不抢焦点`。

## 1.109.0-rc486 — 短剧指针同步 / 变更列表默认收起

- ✅ 本版本没有新增短剧制作能力；短剧 MVP 验收口径延续
  `1.109.0-rc471 — 短剧 handoff todo summary`。
- ✅ Agent composer 上方默认只显示“xx 个文件已更改 +x -y 审查”吸附栏，不显示前 3 个文件列表。
- ✅ 点击“审查”后的展开图标后，文件列表卡片出现，并继续支持“再显示 N 个文件”。
- ✅ 再次点击收起图标后，文件列表卡片隐藏，“审查”仍可打开完整 diff。
- ✅ 切换到另一个 Agent session 时，文件列表展开状态不会串到新会话。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc486 — 短剧指针同步 / 变更列表默认收起`。

## 1.109.0-rc487 — 短剧指针同步 / Agent 变更归因

- ✅ 本版本没有新增短剧制作能力；短剧 MVP 验收口径延续
  `1.109.0-rc471 — 短剧 handoff todo summary`。
- ✅ 启动一轮 Agent 对话时，右侧“产物”和底部“xx 个文件已更改”不会展示本轮开始前已经存在的本地脏文件。
- ✅ `run_command` 或补丁工具真正改动文件后，只把相对基线发生变化的路径归因到当前会话。
- ✅ 审查 diff 预览只包含已归因文件，不混入用户原有未归因改动。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc487 — 短剧指针同步 / Agent 变更归因`。

## 1.109.0-rc488 — 短剧指针同步 / Agent 受保护机密

- ✅ 本版本没有新增短剧制作能力；短剧 MVP 验收口径延续
  `1.109.0-rc471 — 短剧 handoff todo summary`。
- ✅ Agent composer 的受保护机密占位符只影响通用 Agent 工具执行边界，不改变短剧项目、分镜、制作包、Widget、handoff bundle 和 smoke evidence 合约。
- ✅ 工具结果、后台任务输出和错误消息会脱敏 `${secret:...}` 解析出的真实值；短剧 smoke evidence 仍按既有敏感信息守门处理证据。
- ✅ XCTest 默认使用内存凭据仓库，避免短剧/Agent 测试宿主触发真实 `com.willdeep.credentials` 钥匙串弹窗。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc488 — 短剧指针同步 / Agent 受保护机密`。

## 1.109.0-rc489 — 短剧指针同步 / 终端总是允许

- ✅ 本版本没有新增短剧制作能力；短剧 MVP 验收口径延续
  `1.109.0-rc471 — 短剧 handoff todo summary`。
- ✅ `terminal_send_command` 审批卡片可显示“总是允许”，并按完整命令行记忆。
- ✅ `terminal_send_control` 审批卡片可显示“总是允许”，并按 `ctrl_c` / `enter` / `escape` 分别记忆。
- ✅ 允许 `ctrl_c` 不会自动允许 `enter` 或其它终端控制键。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc489 — 短剧指针同步 / 终端总是允许`。

## 1.109.0-rc490 — 短剧指针同步 / Agent secret 加固

- ✅ 本版本没有新增短剧制作能力；短剧 MVP 验收口径延续
  `1.109.0-rc471 — 短剧 handoff todo summary`。
- ✅ Agent secret 占位符改为纯随机 ID，不暴露用户填写的 label；委托型 AI 执行器不会解析 `${secret:...}` 明文。
- ✅ Keychain envelope 会保留 secret 原文，URL/base64 transform 和工具回传脱敏不改变短剧制作包、Widget、handoff bundle 与 smoke evidence 合约。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc490 — 短剧指针同步 / Agent secret 加固`。

## 1.109.0-rc491 — 短剧指针同步 / SSH 远端只读

- ✅ 本版本没有新增短剧制作能力；短剧 MVP 验收口径延续
  `1.109.0-rc471 — 短剧 handoff todo summary`。
- ✅ Agent `run_command` 的 SSH 风险识别只影响通用命令授权边界，不改变短剧项目、分镜、制作包、Widget、handoff bundle 和 smoke evidence 合约。
- ✅ `ssh host cat /var/log/...`、`ssh host ping ...` 会按远端只读命令处理；远端 `rm -rf`、读取 `~/.ssh/id_rsa` 和交互式 `ssh host` 仍需要人工授权或危险确认。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc491 — 短剧指针同步 / SSH 远端只读`。

## 1.109.0-rc492 — 短剧指针同步 / 终端快照一屏

- ✅ 本版本没有新增短剧制作能力；短剧 MVP 验收口径延续
  `1.109.0-rc471 — 短剧 handoff todo summary`。
- ✅ Agent `terminal_snapshot` 只影响侧边栏终端上下文读取，不改变短剧项目、分镜、制作包、Widget、handoff bundle 和 smoke evidence 合约。
- ✅ 侧边栏终端快照默认只读取 live 底部可见屏幕，不再把最近 scrollback/history 一起送进模型上下文。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc492 — 短剧指针同步 / 终端快照一屏`。

## 1.109.0-rc493 — 短剧指针同步 / 请求详情截断

- ✅ 本版本没有新增短剧制作能力；短剧 MVP 验收口径延续
  `1.109.0-rc471 — 短剧 handoff todo summary`。
- ✅ Agent 错误详情面板只影响请求排查 UI，不改变短剧项目、分镜、制作包、Widget、handoff bundle 和 smoke evidence 合约。
- ✅ 超长 request summary / request body 在 UI 中间省略，仍可复制完整详情排查服务商 HTTP 错误。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc493 — 短剧指针同步 / 请求详情截断`。

## 1.109.0-rc494 — 短剧指针同步 / 终端捷径编辑

- ✅ 本版本没有新增短剧制作能力；短剧 MVP 验收口径延续
  `1.109.0-rc471 — 短剧 handoff todo summary`。
- ✅ 终端捷径编辑入口只影响 Agent 右侧终端捷径管理，不改变短剧项目、分镜、制作包、Widget、handoff bundle 和 smoke evidence 合约。
- ✅ 终端捷径菜单点击“编辑”后会打开 `shortcuts.json` 并定位到当前捷径；保存合法 JSON 后列表自动重载。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc494 — 短剧指针同步 / 终端捷径编辑`。

## 1.109.0-rc495 — 短剧指针同步 / 终端捷径 Keychain

- ✅ 本版本没有新增短剧制作能力；短剧 MVP 验收口径延续
  `1.109.0-rc471 — 短剧 handoff todo summary`。
- ✅ 终端捷径 Keychain 授权收敛只影响 Agent 右侧终端捷径管理，不改变短剧项目、分镜、制作包、Widget、handoff bundle 和 smoke evidence 合约。
- ✅ 改名已有受保护输入的终端捷径时，不再读取或写入对应 Keychain 片段；同一次回放同一 Keychain 引用最多读取一次。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc495 — 短剧指针同步 / 终端捷径 Keychain`。

## 1.109.0-rc496 — 短剧指针同步 / 侧边栏终端 SSH 主机

- [ ] 打开 Agent 侧边栏终端，点击新建终端 `+` 菜单；确认本地 Shell 与 SSH 主机分区清晰，SSH 区域标题为已配置主机，未配置时显示空状态。
- [ ] 如果本机保存过 `q3` 或其他 SSH runtime，确认它只作为“已配置的 SSH 主机”出现；点击“管理 SSH 主机...”能打开 Settings → Runtimes，可在设置里删除或改名。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.109.0-rc496`，短剧制作能力无新增。

## 1.113.0-rc4 — 短剧指针同步 / Editor LSP diagnostics

- [ ] 本版本修复 Agent 浅色自定义皮肤在系统 dark mode 下的文字可读性；不新增、不改变短剧项目、分镜、制作包、Widget、handoff bundle 和 smoke evidence 合约。
- [ ] 本版本修复 Agent 前台 `run_command`「验证中」自动切到任务监控侧栏的问题；不新增、不改变短剧项目、分镜、制作包、Widget、handoff bundle 和 smoke evidence 合约。
- [ ] 本版本新增 Go / TypeScript / JavaScript / Swift 的第一批 IDE 语言服务底座；不新增、不改变短剧项目、分镜、制作包、Widget、handoff bundle 和 smoke evidence 合约。
- [ ] 本版本接入 Go / TypeScript / JavaScript / Swift 的 editor LSP 定义跳转；不新增、不改变短剧项目、分镜、制作包、Widget、handoff bundle 和 smoke evidence 合约。
- [ ] 本版本接入 Go / TypeScript / JavaScript / Swift 的 editor LSP 结构大纲和符号跳转；不新增、不改变短剧项目、分镜、制作包、Widget、handoff bundle 和 smoke evidence 合约。
- [ ] 本版本接入 Go / TypeScript / JavaScript / Swift 的 editor LSP diagnostics 诊断展示；不新增、不改变短剧项目、分镜、制作包、Widget、handoff bundle 和 smoke evidence 合约。
- [ ] 复测 Agent：前台 `run_command` 进入「验证中」时，右侧侧边栏不会自动切到「任务监控」；已有后台 job、媒体任务、待办、工作文件或学习事件时仍可自动打开任务监控。
- [ ] 复测智能审批：`ssh ... "docker run ..."`、重启/重载 nginx、添加 nginx 站点等非 typed-confirmation 运维命令应进入 AI safety judge；`rm -rf /`、读 `~/.ssh/id_rsa` 等仍要求人工确认。
- [ ] 复测 Editor：在 editor 模式里连续点击不同行/不同列移动光标，竖线高度应贴近字体实际字形高度，当前行高亮和光标移动不应出现明显整页闪动。
- [ ] 复测语言服务底座：确认 Go / TypeScript / JavaScript / Swift 的 registry、LSP framing、document lifecycle 和 definition response tests 通过。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.113.0-rc4`，短剧制作能力无新增。

## 1.113.0-rc5 — 短剧指针同步 / Workspace 菜单卡死修复

- [ ] 复测 Agent Composer 的 Workspace 下拉：打开包含多个 recent folders / sessions / worktrees 的会话，展开菜单不应触发主线程持续 100% CPU，当前 workspace / worktree 的勾选状态仍正确。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.113.0-rc5`，短剧制作能力无新增。

## 1.113.0-rc6 — 短剧指针同步 / Editor LSP hover

- [ ] 复测 Editor：在 Go / TypeScript / JavaScript / Swift 文件中右键符号，选择 hover 信息入口后应显示来自语言服务器的类型/文档浮层；语言服务器不可用时应显示可控空态，不影响原有定义跳转、结构大纲和 diagnostics。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.113.0-rc6`，短剧制作能力无新增。

## 1.113.0-rc7 — 短剧指针同步 / Editor LSP completion

- [ ] 复测 Editor：在 Go / TypeScript / JavaScript / Swift 文件中右键符号或光标位置选择补全入口，应显示 LSP completion 候选；点击候选应替换当前前缀/选区并把光标放到插入文本末尾；不影响定义跳转、结构大纲、diagnostics 和 hover。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.113.0-rc7`，短剧制作能力无新增。

## 1.113.0-rc8 — 短剧指针同步 / Editor LSP semantic tokens

- [ ] 复测 Editor：在 Go / TypeScript / JavaScript / Swift 文件中打开可用语言服务器的项目，等待同步后高亮应由 semantic tokens 覆盖 regex fallback；函数/类型/关键字等颜色应稳定，语言服务器不可用时仍保留原有 regex 高亮。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.113.0-rc8`，短剧制作能力无新增。

## 1.113.0-rc9 — 短剧指针同步 / Editor LSP references

- [ ] 复测 Editor：在 Go / TypeScript / JavaScript / Swift 文件中右键符号选择 Find References，应显示 LSP 引用列表；点击结果应跳转到对应文件和行；语言服务器不可用时显示可控空态，不影响 definition、outline、diagnostics、hover、completion 和 semantic tokens。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.113.0-rc9`，短剧制作能力无新增。

## 1.113.0-rc10 — 短剧指针同步 / Agent workspace 懒诊断

- [ ] 复测 Agent：启动绑定本地 workspace 的会话后，在 Finder 中改名或移动该 workspace，再触发一次读文件/运行命令；应只在失败后提示 workspace missing/moved，不应静默把会话改绑到新路径。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.113.0-rc10`，短剧制作能力无新增。

## 1.113.0-rc11 — 短剧指针同步 / Editor LSP document formatting

- [ ] 复测 Editor：在 Go / TypeScript / JavaScript / Swift 文件中右键选择 Format Document，应通过语言服务器格式化当前文件；格式化后文档标记为已修改，semantic tokens / diagnostics / outline 不应卡死或残留旧状态；语言服务器不可用时不应影响已有 definition、references、completion、hover、semantic tokens。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.113.0-rc11`，短剧制作能力无新增。

## 1.113.0-rc12 — 短剧指针同步 / Editor LSP rename symbol

- [ ] 复测 Editor：在 Go / TypeScript / JavaScript / Swift 文件中右键符号选择 Rename Symbol，输入新名称后应通过语言服务器返回的 WorkspaceEdit 重命名引用；当前文件应标记为已修改，workspace 内其他安全文件可写回磁盘，已打开且未保存的其他 tab 不应被覆盖。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.113.0-rc12`，短剧制作能力无新增。

## 1.113.0-rc13 — 短剧指针同步 / Editor LSP folding ranges

- [ ] 复测 Editor：在 Go / TypeScript / JavaScript / Swift 文件中打开有嵌套函数/类型/代码块的文件，折叠 gutter 应优先跟随语言服务器 `textDocument/foldingRange` 返回的范围；语言服务器不可用或不支持 folding ranges 时应回退到原有本地折叠规则。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.113.0-rc13`，短剧制作能力无新增。

## 1.113.0-rc14 — 短剧指针同步 / Editor LSP signature help

- [ ] 复测 Editor：在 Go / TypeScript / JavaScript / Swift 文件的函数调用参数位置右键选择 Show Signature Help，应显示语言服务器返回的当前调用签名、参数文档和 active parameter；语言服务器不可用或无签名时应显示可控空态，不影响 hover、completion、references、rename、formatting、folding ranges。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.113.0-rc14`，短剧制作能力无新增。

## 1.113.0-rc15 — 短剧指针同步 / Editor LSP code actions

- [ ] 复测 Editor：在 Go / TypeScript / JavaScript / Swift 文件里制造可被语言服务器诊断的错误，右键选择 Show Code Actions，应显示 quick fix / source action 候选；选择带 `WorkspaceEdit` 的 action 后，当前文件应变为 dirty，跨文件 edits 只允许写入当前 workspace 内且会阻止覆盖未保存 tab。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.113.0-rc15`，短剧制作能力无新增。

## 1.113.0-rc16 — 短剧指针同步 / Editor LSP document highlights

- [ ] 复测 Editor：在 Go / TypeScript / JavaScript / Swift 文件中把光标移动到变量、函数或类型符号上，当前文档内对应读/写引用应出现轻量背景高亮；移动到空白处、拖选文本、切换非 IDE 语言或切换文件后，高亮应及时清空且不遮盖 diagnostics 下划线。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.113.0-rc16`，短剧制作能力无新增。

## 1.113.0-rc17 — 短剧指针同步 / Agent 侧边栏入口优化

- [ ] 复测 Agent：标题栏右侧 Diff、Terminal、Preview、Files 四个高频侧边栏图标应能直接打开/关闭对应面板，`...` 菜单仍能打开完整侧栏 tab 列表，Editor 入口应保持独立且视觉上明显区别于侧栏入口。
- [ ] 复测 Agent 右侧面板：拖动聊天区与右侧面板之间的分隔条时，面板宽度应跟手变化，边界和面板内容不应出现明显抖动、闪动；松手后宽度应持久化。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.113.0-rc17`，短剧制作能力无新增。

## 1.113.0-rc18 — 短剧指针同步 / Editor LSP type definition / implementation

- [ ] 复测 Editor：在 Go / TypeScript / JavaScript / Swift 文件里右键符号，Go to Type Definition 应跳到语言服务器返回的类型定义；语言服务器未声明能力或无结果时应只提示失败，不应回退到普通文本定义。
- [ ] 复测 Editor：在接口、协议、抽象类型或可实现符号上右键 Go to Implementation，应跳到语言服务器返回的实现位置；普通 Go to Definition、Find References、Rename、Hover、Document Highlights 仍应保持可用。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.113.0-rc18`，短剧制作能力无新增。

## 1.113.0-rc19 — 短剧指针同步 / Editor LSP workspace symbols

- [ ] 复测 Editor：在 Go / TypeScript / JavaScript / Swift 项目里打开 Symbol Jump，输入非空查询时应显示 LSP `workspace/symbol` 返回的项目级符号，结果行应包含文件名、行号和容器信息；选择跨文件结果应打开目标文件并跳到对应行。
- [ ] 复测 Editor：语言服务器不可用、未声明 workspace symbol 能力或项目级查询无结果时，Symbol Jump 应继续回退到当前文件 outline 过滤；空查询仍显示当前文件结构，不应误触发项目级搜索。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.113.0-rc19`，短剧制作能力无新增。

## 1.113.0-rc20 — 短剧指针同步 / Editor LSP selection range

- [ ] 复测 Editor：在 Go / TypeScript / JavaScript / Swift 文件里右键选择 Expand Selection，光标处应按语言服务器 `textDocument/selectionRange` 返回的语法树链逐级扩选，例如从标识符扩到调用表达式、语句或函数体。
- [ ] 复测 Editor：已有选区时再次 Expand Selection 应扩到下一层更大的语义范围；语言服务器不可用或没有更大范围时应提示不可用/无更大范围，不应使用本地正则伪造结果。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.113.0-rc20`，短剧制作能力无新增。

## 1.114.0-rc1 — 短剧指针同步 / Agent 联网调研来源胶囊

- [ ] 复测 Agent：配置可用 web search key 后发起一次需要 `web_search` 的调研，本轮 assistant 输出后底部应显示紧凑来源胶囊，胶囊内应有多个 favicon / fallback 图标和“来源”标签。
- [ ] 复测 Agent：点击来源胶囊应展开来源清单；清单行应显示标题、脱敏 URL、host 图标和外链图标，点击任一行应使用系统浏览器打开对应网页。
- [ ] 复测 Agent：执行一次 `web_fetch` 抓取公开网页后，来源胶囊应至少包含该抓取页；带 `key` / `api` / `token` query 的测试 URL 不应在来源列表中泄露原始敏感值。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.114.0-rc1`，短剧制作能力无新增。

## 1.114.0-rc2 — 短剧指针同步 / Editor LSP call hierarchy

- [ ] 复测 Editor：在 Go / TypeScript / JavaScript / Swift 文件里右键符号选择 Show Call Hierarchy，应通过 LSP 显示 Incoming / Outgoing 调用关系；点击任一调用条目应跳转到对应文件和行。
- [ ] 复测 Editor：语言服务器不可用、未声明 call hierarchy 能力或当前符号没有调用关系时，应显示清晰的不可用/无结果状态，不应使用本地正则伪造调用层级。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.114.0-rc2`，短剧制作能力无新增。

## 1.114.0-rc3 — 短剧指针同步 / Editor LSP prepare rename

- [ ] 复测 Editor：在 Go / TypeScript / JavaScript / Swift 文件里右键可重命名符号选择 Rename Symbol，输入框默认名称应优先来自语言服务器 `textDocument/prepareRename` 返回的 placeholder 或 range 文本。
- [ ] 复测 Editor：对不可重命名位置执行 Rename Symbol 时，应显示语言服务器不可重命名提示；server 未声明 prepare 能力时仍应保留原 LSP rename 流程，不应使用本地正则伪造可重命名判断。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.114.0-rc3`，短剧制作能力无新增。

## 1.114.0-rc4 — 短剧指针同步 / Editor LSP declaration navigation

- [ ] 复测 Editor：在 Go / TypeScript / JavaScript / Swift 文件里右键符号选择 Go to Declaration，应通过 LSP `textDocument/declaration` 跳转到声明位置。
- [ ] 复测 Editor：语言服务器不可用、未声明 declaration 能力或当前位置无声明结果时，应只给可控失败反馈，不应使用本地正则伪造声明跳转。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.114.0-rc4`，短剧制作能力无新增。

## 1.114.0-rc5 — 短剧指针同步 / Editor LSP completion edits

- [ ] 复测 Editor：在 Go / TypeScript / JavaScript / Swift 文件里触发 Show Completions 并选择候选，补全应优先使用 LSP 返回的 `textEdit` / `InsertReplaceEdit` 精确替换范围，不能只按本地前缀误替换。
- [ ] 复测 Editor：选择会触发 import / using / module 引入的 completion 候选时，`additionalTextEdits` 应与主补全一起应用；snippet 候选不应把 `$0`、`${1:...}` 等 placeholder 原样插进正文。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.114.0-rc5`，短剧制作能力无新增。

## 1.114.0-rc6 — 短剧指针同步 / Editor LSP inlay hints

- [ ] 复测 Editor：在 Go / TypeScript / JavaScript / Swift 文件里打开包含可推断参数名或类型提示的代码，语言服务器可用时应显示轻量 inlay hint 提示，正文保存内容不应包含这些提示文字。
- [ ] 复测 Editor：切换文件、切换到非第一批 IDE 语言或语言服务器不可用时，旧 inlay hints 应清空，不应遗留到新文件。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.114.0-rc6`，短剧制作能力无新增。

## 1.114.0-rc7 — 短剧指针同步 / Editor LSP document symbols

- [ ] 复测 Editor：在 Go / TypeScript / JavaScript / Swift 文件里打开 Outline / Symbol Jump，语言服务器返回层级 `DocumentSymbol[]` 或扁平 `SymbolInformation[]` 时都应显示语义 outline，而不是回退到本地正则提取。
- [ ] 复测 Editor：语言服务器未声明 `documentSymbolProvider`、返回 `null` 或不可用时，outline 应保持可控空态或使用既有非 IDE 语言本地 fallback，不应报错或卡住。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.114.0-rc7`，短剧制作能力无新增。

## 1.114.0-rc8 — 短剧指针同步 / Editor LSP document links

- [ ] 复测 Editor：在 Go / TypeScript / JavaScript / Swift 文件里打开包含 import 路径、URL 或文件引用的代码，语言服务器返回 `textDocument/documentLink` 时对应文本应显示链接样式，Command-click 应打开 `file` / `http` / `https` target。
- [ ] 复测 Editor：语言服务器未声明 `documentLinkProvider`、返回 `null`、返回无 target 或返回不支持的 scheme 时，不应绘制可点击链接，也不应影响原有 Go to Definition 的 Command-click。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.114.0-rc8`，短剧制作能力无新增。

## 1.114.0-rc9 — 短剧指针同步 / Editor LSP code action commands

- [ ] 复测 Editor：在 Go / TypeScript / JavaScript / Swift 文件里触发 Show Code Actions，选择只有 command 的 quick fix（如 organize imports / apply fix）时，应发送 `workspace/executeCommand` 并能处理 server 随后的 `workspace/applyEdit`。
- [ ] 复测 Editor：server 未声明 `executeCommandProvider` 或 command 不在声明列表时，不应发送 executeCommand；带 `WorkspaceEdit` 的原 code action 路径仍应可用。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.114.0-rc9`，短剧制作能力无新增。

## 1.114.0-rc10 — 短剧指针同步 / Editor LSP didSave

- [ ] 复测 Editor：在 Go / TypeScript / JavaScript / Swift 文件保存成功后，server 声明 `textDocumentSync.save` 时应收到 `textDocument/didSave`；如果声明 `includeText`，payload 应携带最终写盘文本。
- [ ] 复测 Editor：server 未声明 save 能力时不应发送 didSave；保存失败时也不应发送 didSave，避免语言服务器误以为磁盘状态已更新。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.114.0-rc10`，短剧制作能力无新增。

## 1.114.0-rc11 — 短剧指针同步 / Editor LSP completion resolve

- [ ] 复测 Editor：在 Go / TypeScript / JavaScript / Swift 文件里选择需要懒加载的补全项时，如果 server 声明 `completionProvider.resolveProvider`，应用前应发送 `completionItem/resolve` 并使用返回的 `additionalTextEdits`，例如自动插入 import。
- [ ] 复测 Editor：resolve 请求失败、server 未声明 resolveProvider 或当前文件内容已变化时，补全应回退原 item 或取消过期应用，不应插入错位文本。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.114.0-rc11`，短剧制作能力无新增。

## 1.114.0-rc12 — 短剧指针同步 / Editor LSP workspace requests

- [ ] 复测 Editor：启动 Go / TypeScript / JavaScript / Swift 语言服务器后，如果 server 发起 `workspace/configuration`，client 应返回与 items 数量一致的配置数组，不应让 server request 挂起。
- [ ] 复测 Editor：server 发起 `workspace/workspaceFolders` 时，应返回当前 workspace root 的 URI/name；打开不同项目时 root 应跟随项目标记或显式 root。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.114.0-rc12`，短剧制作能力无新增。

## 1.114.0-rc13 — 短剧指针同步 / Editor LSP code action resolve

- [ ] 复测 Editor：在 Go / TypeScript / JavaScript / Swift 文件里选择需要懒加载的 quick fix 时，如果 server 声明 `codeActionProvider.resolveProvider`，应用前应发送 `codeAction/resolve` 并使用返回的 `WorkspaceEdit` 或 command。
- [ ] 复测 Editor：resolve 请求失败、server 未声明 resolveProvider 或当前文件内容已变化时，quick fix 应回退原 action 或取消过期应用，不应插入错位文本。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.114.0-rc13`，短剧制作能力无新增。

## 1.114.0-rc14 — 短剧指针同步 / Editor LSP document link resolve

- [ ] 复测 Editor：在 Go / TypeScript / JavaScript / Swift 文件里 Command-click 一个 server 返回 range 但初始没有 `target` 的 document link 时，如果 server 声明 `documentLinkProvider.resolveProvider`，应先发送 `documentLink/resolve` 再打开 resolved target。
- [ ] 复测 Editor：resolved target 只允许 `file` / `http` / `https`；resolve 失败、server 未声明 resolveProvider 或当前文件内容已变化时，不应打开不可信或过期链接。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.114.0-rc14`，短剧制作能力无新增。

## 1.114.0-rc15 — 短剧指针同步 / Editor LSP inlay hint resolve

- [ ] 复测 Editor：在 Go / TypeScript / JavaScript / Swift 文件里请求 inlay hints 时，如果 server 声明 `inlayHintProvider.resolveProvider`，client 应对返回的 hint 发送 `inlayHint/resolve` 并保留 resolved tooltip / text edits / padding 信息。
- [ ] 复测 Editor：单个 hint resolve 失败、server 未声明 resolveProvider 或返回空 tooltip 时，应继续显示原始 hint label，不应清空整页 inlay hints。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.114.0-rc15`，短剧制作能力无新增。

## 1.114.0-rc16 — 短剧指针同步 / Editor LSP range formatting

- [ ] 复测 Editor：在 Go / TypeScript / JavaScript / Swift 文件里选中一段代码右键 Format Selection 时，应发送 `textDocument/rangeFormatting`，只应用 server 返回的选区 edits。
- [ ] 复测 Editor：无选区时不显示 Format Selection；server 未声明 `documentRangeFormattingProvider` 时不应发送 range formatting 请求，Format Document 仍走整文档格式化。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.114.0-rc16`，短剧制作能力无新增。

## 1.114.0-rc17 — 短剧指针同步 / Editor LSP willSaveWaitUntil

- [ ] 复测 Editor：在 Go / TypeScript / JavaScript / Swift 文件里保存时，如果 server 声明 `textDocumentSync.willSaveWaitUntil`，写盘前应发送 `textDocument/willSaveWaitUntil` 并应用返回 edits。
- [ ] 复测 Editor：willSaveWaitUntil 失败、超时或 server 未声明 capability 时，应继续保存原内容，并在保存成功后照常发送 `textDocument/didSave`。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.114.0-rc17`，短剧制作能力无新增。

## 1.115.0-rc1 — 短剧指针同步 / Voice 转录语言设置

- [ ] 打开 Settings → Voice，确认“转录语言”默认是“跟随系统”，并且可切换到自动检测、中文、英文、粤语、日语、韩语。
- [ ] 将转录语言切到“日语”，用 composer 麦克风或 Fn push-to-talk 说一句日语，确认文本进入输入框且不再依赖自动识别。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.115.0-rc1`，短剧制作能力无新增。

## 1.116.0-rc1 — 短剧指针同步 / Editor LSP watched files

- [ ] 复测 Editor：在 Go / TypeScript / JavaScript / Swift workspace 内保存或新建源文件后，应向对应语言服务器发送 `workspace/didChangeWatchedFiles`，并保留原有 `textDocument/didSave` 行为。
- [ ] 复测 Editor：新建文件夹或修改 `package.json` / `go.mod` 等非源文件时，应通知当前 workspace 下已有 LSP session，不应为了未知语言文件额外启动无关 server。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.116.0-rc1`，短剧制作能力无新增。

## 1.117.0-rc1 — 短剧指针同步 / Editor LSP workspace edit refresh

- [ ] 复测 Editor：在 Go / TypeScript / JavaScript / Swift workspace 内执行 rename 或 quick fix 后，被实际改写的当前文件、已打开 tab 和磁盘文件应发送 `workspace/didChangeWatchedFiles` `changed` 事件。
- [ ] 复测 Editor：Go / Swift / TypeScript / JavaScript 语义 token 中的 `variable` / `parameter` / `label` 应覆盖正则 fallback 呈现；变量 declaration/definition 仍应加粗。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.117.0-rc1`，短剧制作能力无新增。

## 1.118.0-rc1 — 短剧指针同步 / Editor LSP workspace resource operations

- [ ] 复测 Editor：Go / TypeScript / JavaScript / Swift 的 rename 或 quick fix 若返回 `WorkspaceEdit.documentChanges` 中的 `create` / `rename` / `delete`，应在当前 workspace 内安全应用资源操作。
- [ ] 复测 Editor：资源操作命中未保存 tab 时应阻止应用并给出错误；成功创建、重命名、删除后应发送对应 watched-file `created` / `deleted` 事件。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.118.0-rc1`，短剧制作能力无新增。

## 1.119.0-rc1 — 短剧指针同步 / Editor LSP authoritative outline

- [ ] 复测 Editor：Go / TypeScript / JavaScript / Swift 的结构面板与符号跳转在 LSP `textDocument/documentSymbol` 返回空结果时应展示空大纲，不应再用正则 outline 填充伪结构。
- [ ] 复测 Editor：语言服务器不可用或请求失败时，结构面板与符号跳转仍应回退旧正则 outline，保证基础浏览能力不中断。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.119.0-rc1`，短剧制作能力无新增。

## 1.120.0-rc1 — 短剧指针同步 / Editor LSP authoritative folding

- [ ] 复测 Editor：Go / TypeScript / JavaScript / Swift 的 gutter 折叠/作用域引导线在 LSP `textDocument/foldingRange` 返回空结果时应展示空折叠，不应再用本地括号/缩进 fallback 填充伪折叠。
- [ ] 复测 Editor：语言服务器不可用或 folding range 请求失败时，gutter 折叠/作用域引导线仍应回退旧本地计算，保证基础折叠能力不中断。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.120.0-rc1`，短剧制作能力无新增。

## 1.121.0-rc1 — 短剧指针同步 / Editor LSP authoritative definition misses

- [ ] 复测 Editor：Go / TypeScript / JavaScript / Swift 的 Go to Definition 在 LSP `textDocument/definition` 正常返回空结果时应只提示未找到，不应继续用正则 resolver 跳到疑似匹配位置。
- [ ] 复测 Editor：语言服务器不可用、启动失败或 definition 请求异常时，Go to Definition 仍应回退旧正则 resolver，保证未安装 LSP 环境的基础跳转不中断。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.121.0-rc1`，短剧制作能力无新增。

## 1.124.0-rc1 — 短剧指针同步 / Mobile Gateway default relay

- [ ] 复测 Mobile Gateway：Mac 端不手动填写公网 relay 地址时，二维码 payload 也应包含 `relay_base_url=https://j.niuwoai.com`、安装级 `relay_room`、`relay_token`，Android 扫码后应直接连 `/ws/broadcast/<room>`，不再依赖局域网 `/mobile/pair/claim`。
- [ ] 复测 Mobile Gateway：Android 断开重连后仍使用保存的 relay room 与 relay token，能够继续操作当前 Mac Agent 会话。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.124.0-rc1`，短剧制作能力无新增。

## 1.125.0-rc1 — 短剧指针同步 / Agent composer triggers

- [ ] 复测 Agent composer：`/` 只打开命令 / workflow palette，`@` 只列 workspace 与项目文件，`$` 打开 Skill picker，并且已附加技能 chip 显示为 `$skill`。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.125.0-rc1`，短剧制作能力无新增。

## 1.128.0-rc6 — 短剧指针同步 / 口述终端录制密码占位

- [ ] 复测终端录制 AI 编辑：AI 能通过 `terminal_list_shortcuts` 查看录制事件结构，并在批准后用 `terminal_edit_shortcut` 修改等待时间或可见输入文本。
- [ ] 人工确认终端录制捷径栏：未执行时展示总耗时；回放时当前捷径有播放 icon/高亮、剩余时间、事件进度和预计结束时间；完成或中断后状态可见。
- [ ] 口述一段终端操作，让 Agent 通过 `terminal_create_shortcut` 生成录制捷径，并确认生成前有审批、生成后可在捷径栏看到并回放。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.128.0-rc6`，短剧制作能力无新增。
- [ ] 在 chat 里口述生成包含“密码 1 / 密码 2”的终端录制，确认工具卡片下方出现本地 SecureField，填写后录制可回放且聊天记录/录制 JSON 不出现真实密码。
- [ ] 手动录制一段需要输密码的终端会话（echo-off），逐字符输入一整条密码再按回车，保存后确认“受保护输入”计数按“回车次数/密码条数”统计（例如 2 条密码显示 2），不再按字符数（不再出现 19 这种数字）。
- [ ] 录制一个包含多个 echo-off 隐藏输入的终端录制，保存后确认回放不再为每个隐藏输入逐条弹 macOS Keychain 系统密码。

## 1.129.0-rc1 — 短剧指针同步 / Composer placeholder / SwiftUI hang skill

- [ ] 复测 Agent composer：空输入时显示多语言 placeholder，提示 `/`、`@`、`$` 的用途；开始输入、粘贴、选择历史消息或插入 token 后 placeholder 应消失。
- [ ] 切换系统语言或用本地化覆盖验证：英文应提示 commands/files-workspace/skills & plugins，简中应提示命令、文件/工作区、技能与插件，不应出现 JSX/SwiftUI 硬编码文案。
- [ ] 复测内置技能：Settings → Skills 或 `$` skill picker 可搜索 `swiftui` / `卡死` / `sample` 找到 `swiftui-hang-diagnose`，Agent `read_skill` 能读到 `sample <PID> 5 -mayDie` 与 `spindump <PID> 5` 诊断流程。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.129.0-rc1`，短剧制作能力无新增。

## 1.129.0-rc2 — 短剧指针同步 / Agent Editor performance

- [ ] 复测 Agent 长工具参数流式输出：工具卡片应持续可见最新参数，但长 JSON streaming 时聊天区滚动和 composer 输入不应出现明显卡顿。
- [ ] 复测大文件编辑：打开长文件后移动光标、输入、保存和查看 change bar，确认 scope guide 与 changed-line 标记仍正确且输入回显稳定。
- [ ] 复测媒体任务缩略图与侧栏预览：图片、视频任务缩略图能显示，Diff / Preview 面板切换不应因重复重算造成明显冻结。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.129.0-rc2`，短剧制作能力无新增。

## 1.129.0-rc3 — 短剧指针同步 / MCP session editor performance

- [ ] 复测 MCP stdio server：连续调用同一个 MCP server 的 list/call 工具，第二次起不应重新冷启动 server 进程。
- [ ] 复测 Agent 历史会话：启动后侧栏能列出历史会话，点击旧会话后完整 transcript 正常恢复；置顶、归档、重命名不会丢消息。
- [ ] 复测大文件括号匹配：光标停在未配对括号附近时编辑器不应因向文件头/尾全量扫描而卡住。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.129.0-rc3`，短剧制作能力无新增。

## 1.129.0-rc4 — 短剧指针同步 / editor gateway polling

- [ ] 复测大文件底部滚动与输入：行号尺首个可见行号正确，滚动底部不应因为从文件头扫描行号而明显卡顿。
- [ ] 复测 Mobile Gateway：持续流式或打字时手机端快照仍会周期更新，不应无限推迟，也不应在每个 UI 通知上重建快照任务。
- [ ] 复测远端 daemon runtime：前台命令仍能返回结果，长命令期间状态轮询频率应降到约 1 秒一次。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.129.0-rc4`，短剧制作能力无新增。

## 1.129.0-rc5 — 短剧指针同步 / status timer polling

- [ ] 复测 editor 主窗口空闲状态：SwiftUI body 重算不应重建 git / 外部文件状态刷新 timer，10s 状态刷新仍只在 scenePhase active 时触发。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.129.0-rc5`，短剧制作能力无新增。

## 1.129.0-rc6 — 短剧指针同步 / provider keychain lazy loading

- [ ] 复测 Agent Settings provider library：启动 App 不应因多个 provider key 逐条读取 Keychain 而卡住；切换 active provider 或选中非 active provider 编辑时，对应 API key 仍能按需显示和生效。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.129.0-rc6`，短剧制作能力无新增。

## 1.129.0-rc7 — 短剧指针同步 / test-host stabilization

- [ ] 复测 Agent Settings provider library：启动 App 不应因多个 provider key 逐条读取 Keychain 而卡住；切换 active provider 或选中非 active provider 编辑时，对应 API key 仍能按需显示和生效。
- [ ] 复测本地单测环境：未设置 `WILLDEEP_VOICE_SMOKE=1` 时 Voice smoke 应跳过；全量 `XeditTests` 不应因本机历史大文件或不可读文件弹出阻塞式文件加载错误弹窗。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.129.0-rc7`，短剧制作能力无新增。

## 1.129.0-rc9 — 短剧指针同步 / patch 卡片已应用识别

- [ ] 复现原始 bug：让 Agent 在 Goal / workspace-access 模式下改一个文件（例如 `scripts/release_mac_apps.rb`），改动已落盘后，再手动点残留的同改动 patch 卡片「应用」，不应再弹「patch 的某段与当前文件内容不匹配」，而应显示「改动已存在，无需重复应用」并把卡片标为已应用（绿勾、从待处理列表消失）。
- [ ] 反向验证：对一个 context 真的对不上、且文件里也不存在目标结果的坏 patch 点「应用」，仍应正常报「patch 的某段与当前文件内容不匹配」并标为失败（不能把真失败误判成已应用）。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.129.0-rc9`，短剧制作能力无新增。
- [ ] 在含历史图片（早前贴过图/工具截过图）的长会话里切到 some.im + deepseek-v4-flash 继续对话，确认不再出现 HTTP 400 `unknown variant image_url`；历史图片位置应以「[N image attachment(s) omitted ...]」文字占位发出。
- [ ] 触发一次 Agent 请求错误，展开错误详情卡片，点击 Response 区右上角复制按钮：icon 应变成绿色 ✓ 并显示「已复制」，粘贴板里应是完整 Response 内容（含被界面省略的部分）。

## 1.129.0-rc10 — 短剧指针同步 / 会话索引列表修复

- [ ] 启动已有历史会话的开发版 App，确认 Agent 左侧工作区分组下能显示旧会话列表，而不是只剩当前空白“新对话”。
- [ ] 保持启动轻量索引路径：首次显示侧边栏时不应把完整历史 transcript 常驻加载；点开某个历史会话后再物化该会话正文。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.129.0-rc10`，短剧制作能力无新增。

## 1.129.0-rc11 — 短剧指针同步 / 本地模型辅助加速

- [ ] 复测 Settings 里的本地辅助模型区域：启用后可填写本地 endpoint、图片理解模型和 Summary 模型；文案应说明本地优先、失败回退远端 provider，且不建议把本地 4B 模型作为复杂生产 Agent 的默认模型。
- [ ] 触发一次带图片的文本 provider 对话：图片描述应先尝试本地模型；本地失败或未配置时应继续 fallback 到当前远端 provider。
- [ ] 触发标题生成或上下文压缩：Summary 路径应先尝试本地模型；本地失败或返回空摘要时应继续 fallback 到远端 provider。
- [ ] 在本地模型下载区域点后台下载，确认可看到当前文件、整体进度、已下载大小和速度；取消后可重新启动，已下载完成的必要文件不应重复下载。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.129.0-rc11`，短剧制作能力无新增。

## 1.129.0-rc12 — 短剧指针同步 / 本地 provider 语言偏好

- [ ] 复测本地 provider 请求：内置 `Ollama / Local OpenAI` 和自定义 `localhost` / `127.0.0.1` / `::1` endpoint 的 system prompt 应追加当前系统首选语言偏好；远端 OpenAI / Claude / some.im provider 不应追加该提示。
- [ ] 触发本地图片描述、标题生成或上下文压缩，确认输出优先使用当前系统首选语言；如果用户最近明确使用其他语言，应优先跟随用户语言。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.129.0-rc12`，短剧制作能力无新增。

## 1.129.0-rc13 — 短剧指针同步 / 本地 VL 默认与文件查找

- [ ] 打开 Settings → AI Providers → 本地模型加速，确认“图片理解模型”默认或旧配置迁移后显示 `qwen3.5-4b-vl-q4_k_m`，Summary 模型仍为 `qwen3.5-4b-q4_k_m`。
- [ ] 在模型下载区点击“查找本地文件”，确认能按 `Qwen3.5-4B.Q4_K_M.gguf` 与 `mmproj-BF16.gguf` 文件名查找常见目录，并显示路径、实际大小、预估大小和“大小匹配 / 大小接近 / 大小不像”判断。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.129.0-rc13`，短剧制作能力无新增。

## 1.129.0-rc14 — 短剧指针同步 / 终端录制密码填写

- [ ] 创建一个包含 `protected_placeholder` 的终端录制，确认右侧 Terminal 侧栏自动打开，并在终端上方显示本地密码填写卡片。
- [ ] 填写密码并保存，确认回放按钮恢复可用，录制 JSON 不包含真实密码。
- [ ] 编辑终端录制 JSON，确认可见输入显示为 `text` 字段，可用 `\n`、`\t`、`\r`、`\e`、`\b`、`\xHH` 输入特殊键。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.129.0-rc14`，短剧制作能力无新增。

## 1.129.0-rc15 — 短剧指针同步 / Agent 统计恢复

- [ ] 打开已有历史会话较多的 Agent 空白页统计面板，确认消息数、令牌数、活跃天数、热力图和模型用量不再显示为 0。
- [ ] 切换统计范围（全部 / 30 天 / 7 天 / 24 小时）和“模型”标签，确认历史模型用量可见且不会触发完整 transcript 常驻内存的明显卡顿。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.129.0-rc15`，短剧制作能力无新增。

## 1.129.0-rc16 — 短剧指针同步 / 终端录制侧栏密码

- [ ] 创建一个包含 `protected_placeholder` 的终端录制，确认右侧 Terminal 侧栏自动打开，聊天区工具卡不显示密码输入框，只提供打开侧栏入口。
- [ ] 在右侧 Terminal 侧栏顶部密码卡填写并保存，确认当前终端滚屏、输入状态和正在运行的进程不丢失，回放按钮恢复可用。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.129.0-rc16`，短剧制作能力无新增。

## 1.129.0-rc17 — 短剧指针同步 / 终端侧栏切换保活

- [ ] 打开右侧 Terminal 侧栏并启动一个持续输出或保持状态的 shell 程序，切换到 Diff / Files / Widget 等其它侧栏，再切回 Terminal，确认滚屏、输入状态和进程不丢失。
- [ ] 打开含密码占位的终端录制，先切到其它侧栏再切回 Terminal，确认顶部密码卡仍在，填写保存后回放按钮恢复可用。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.129.0-rc17`，短剧制作能力无新增。

## 1.129.0-rc18 — 短剧指针同步 / 终端密码询问回聊天区

- [ ] 创建一个包含 `protected_placeholder` 的终端录制，确认聊天区工具卡直接显示密码询问卡，右侧 Terminal 侧栏不自动打开。
- [ ] 在聊天区密码卡填写并保存，确认真实值写入本机终端加密 vault，卡片收起后只显示“用户输了密码”，回放按钮恢复可用。
- [ ] 打开右侧 Terminal 侧栏，确认侧栏顶部不再显示密码输入卡，已有终端进程、滚屏和输入状态仍保持。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.129.0-rc18`，短剧制作能力无新增。

## 1.129.0-rc19 — 短剧指针同步 / Goal 修改吸附卡

- [ ] 切到 Goal 模式并让 Agent 生成目标，确认 composer 上方显示紧凑 Goal 卡片，包含目标摘要、清单进度和编辑按钮。
- [ ] 在 Agent 正在响应时点击 Goal 卡片修改目标，确认保存后卡片立即更新，当前 turn 结束后的后续执行按新目标继续。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.129.0-rc19`，短剧制作能力无新增。

## 1.129.0-rc20 — 短剧指针同步 / Apply 卡片点击后收起

- [ ] 对一个会失败的 patch 卡片点击 Apply，确认卡片从聊天区收起，不能再次点击 Apply / Reject。
- [ ] 对一个正常 patch 卡片点击 Apply，确认卡片从聊天区收起，工作区变更卡仍展示实际落地文件。
- [ ] 打开右侧 Terminal 并手动 SSH 到一台服务器后，让 Agent 执行一个明确应在本地 workspace 运行的命令；确认 Agent 先通过 `terminal_snapshot` 或上下文识别当前 tab 是 SSH session，并改用 `run_command`，不会把本地命令发进服务器终端。
- [ ] 明确要求“就在侧边栏终端里执行”时，确认 Agent 会先判断 active tab 当前是本地还是 SSH；主机不清楚时应先询问或读取终端快照。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.129.0-rc20`，短剧制作能力无新增。

## 1.129.0-rc21 — 短剧指针同步 / edit_file 精确替换编辑

- [ ] 让 Agent 修改一个已存在文件（普通聊天模式），确认它调用 `edit_file`（工具卡显示「编辑文件」）而不是 `apply_patch`，patch 卡片内 diff 的上下文行与文件实际内容一致，点击 Apply 一次成功。
- [ ] 在编辑器 tab 里对目标文件做一处未保存修改后再让 Agent 编辑同一文件，确认 `edit_file` 基于 tab 未保存内容生成 diff，Apply 后不报「与当前文件内容不匹配」。
- [ ] 让 Agent 对同一文件在一轮里提出两处相邻修改，逐个点击 Apply，确认第二张卡不再因第一张已应用而失败。
- [ ] 构造 old_string 不唯一的编辑请求（如把出现多次的短词改名），确认 Agent 收到「matches N locations」错误后自动补足上下文或用 replace_all 重试。
- [ ] 让 Agent 输出一条超宽命令的 ``` 代码块（如带多个 -t 参数的 docker buildx 命令），确认代码卡片内长行自动换行完整可见、Copy 复制到的仍是原始单行文本；聊天里的 markdown 表格仍保持不换行。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.129.0-rc21`，短剧制作能力无新增。

## 1.129.0-rc22 — 短剧指针同步 / workspace 级记忆

- [ ] 在设置 → 记忆里确认 project 记忆行显示项目名 tag 和「项目：<路径>」行；当前 workspace 的记忆额外显示「当前项目」tag。
- [ ] 用「全部 / 仅全局 / 当前项目」过滤器切换，确认「当前项目」只显示挂载到当前 workspace 的 project 记忆；未打开 workspace 时给出提示。
- [ ] 在 A 项目里让 Agent `add_memory` 一条带「这个项目/版本号/测试」字样且不传 scope 的记忆，确认自动落为 project scope 并绑定 A；切到 B 项目发消息，确认该记忆不会被注入。
- [ ] 找一条只有指纹的老 project 记忆（或手工构造），在对应 workspace 打开后进入记忆设置页，确认路径被自动回填显示。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.129.0-rc22`，短剧制作能力无新增。

## 1.129.0-rc23 — 短剧指针同步 / 移动网关快照只读化

- [ ] 打开移动网关并保持手机连接 5 分钟以上，用活动监视器观察 WillDeep CPU 占用应回到接近空闲（不再常驻 20% 以上）；再 `sample WillDeep` 确认热点里没有 snapshotEnvelope → runtime(for:) → JSONEncoder/写盘 链。
- [ ] 历史会话较多（>6 个）时连接手机，确认会话列表正常显示；在手机上点开一个未在 Mac 端打开过的历史会话，确认消息正常加载（命令路径按需物化单个会话）。
- [ ] Mac 端正在响应的会话，其流式消息、待审批工具卡、patch 卡在手机端持续同步无异常。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.129.0-rc23`，短剧制作能力无新增。

## 1.129.0-rc24 — 短剧指针同步 / 移动网关中继默认化

- [ ] 全新安装（或删掉移动网关设置）打开 Settings → 移动网关，确认「连接方式」默认在「互联网中继」，且不产生 `willdeep-agent serve-mobile` 子进程（活动监视器 / `ps` 确认），二维码仍能正常显示（含 `relay_room`/`relay_token`）。
- [ ] 中继模式下用安卓端扫码，确认脱离局域网（如手机切 4G/5G）也能配对并收发会话事件；桌面 peer 状态显示「已连接」。
- [ ] 点「轮换中继房间」，确认桌面重连新房间、二维码刷新，且旧手机需要重新扫码才能再连（验证全体注销语义）。
- [ ] 切到「局域网网关」，确认这才启动 Go 网关进程、`/mobile/health` 可用、设备列表与按设备注销恢复；再切回「互联网中继」确认 Go 进程被停掉。
- [ ] 升级老安装（设置里没有 transportMode 字段）后打开该页，确认自动迁移为「互联网中继」且原 relay 房间/令牌沿用、手机仍可连。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.129.0-rc24`，短剧制作能力无新增。

## 1.129.0-rc25 — 短剧指针同步 / VL 失败降级

- [ ] 复核文本模型带图时的 VL 失败路径：图片说明失败后，用户气泡、外部执行器 prompt 和视觉 QA 输出不得出现 provider HTTP 状态、401、模型供应商错误原文或 `Image description failed` 文案。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.129.0-rc25`，短剧制作能力无新增。

## 1.129.0-rc26 — 短剧指针同步 / Patch 批量操作置底

- [ ] 复核多张 Apply 卡片同时待审时，`全部拒绝 / 全部应用` 批量操作条显示在这一组待审卡片最下面，而不是列表顶部。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.129.0-rc26`，短剧制作能力无新增。

## 1.129.0-rc27 — 短剧指针同步 / 后台任务失败自动唤起

- [ ] 让 agent 用 `run_in_background` 跑一个几秒内以非零退出码失败的命令（例如 `bash -c "sleep 2; exit 1"`），然后等 agent 说完"完成后我会告诉你结果"结束回合：任务监控侧栏显示失败后，聊天窗口应在几秒内自动出现新的 assistant 回合，播报失败并附最近输出，无需用户再发消息。
- [ ] 会话空闲时触发上下文自动压缩（长对话回合结束）期间让后台任务完成：压缩结束后完成通知仍应自动播报，不得静默丢失。
- [ ] 两个会话同 provider 并发占满槽位时，空闲会话的后台任务完成：占用会话回合结束释放槽位后，空闲会话应自动唤起播报。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.129.0-rc27`，短剧制作能力无新增。

## 1.129.0-rc28 — 短剧指针同步 / 性能稳定性体验修复

- [ ] 侧栏右键删除会话：应先弹出确认框（标题含会话名，「删除/取消」），点取消不删、点删除才删；不再一点即删。
- [ ] 依次打开 7 个以上不同项目文件夹并各打开一个源码文件后，活动监视器里旧项目的 language server 进程（sourcekit-lsp / gopls 等）应被回收，同时保留最近使用的最多 6 组；回到被回收的项目再打开文件，补全/诊断应自动恢复。
- [ ] 长对话流式输出时聊天渲染无明显卡顿回归（路径链接识别、会话列表顺序均正常）。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.129.0-rc28`，短剧制作能力无新增。

## 1.129.0-rc29 — 短剧指针同步 / 稳定性性能 i18n 小步修复

- [ ] 移动网关设置里把 host 改成带空格或乱字符的字符串（如 `my host`）再打开配对二维码：不应闪崩，配对地址应回退 `127.0.0.1`；改回合法值后恢复正常。
- [ ] 关一个有未保存更改的标签页：中英文系统下「未保存更改」弹窗标题/按钮均应显示对应语言（英文系统不再夹中文、中文系统不再是英文）。
- [ ] composer 上下文超 50% 时的「压缩」按钮与压缩中状态：中文系统显示「压缩 / 压缩中…」，英文系统显示 Compress / Compressing…；工作树摘要条「N 个文件已更改 / 审查」与英文对应文案同理。
- [ ] 打开若干窗口后 CPU 空转无回归：主窗口标题栏 chrome（隐藏标题、透明标题栏）在新开窗口/全屏切换后仍正确应用。
- [ ] LSP 跳转（跳到定义）在 language server 不可用时仍回退 regex/蜂鸣，Console.app 里能看到 `[EditorLSP]` 失败日志。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.129.0-rc29`，短剧制作能力无新增。

## 1.129.0-rc30 — 短剧指针同步 / 会话持久化移出主线程

- [ ] 长对话流式输出期间观察主线程无卡顿回归（会话 JSON 写盘已移到后台队列）；回合结束后 `~/Library/Application Support/WillDeep/agent-sessions/` 里对应文件内容最终一致。
- [ ] 发完消息后 1 秒内 ⌘Q 退出再重启：最后一条消息不丢（退出前 flush 待写队列）。
- [ ] 会话发消息后立刻打开 Settings 窗口再关闭，随后 ⌘N 新建会话：原会话不得被「空会话清理」误删（loadAll 叠加未落盘快照的回归项）。
- [ ] 置顶/归档一个正在响应的会话，等回合结束：置顶/归档状态不被回合结束的 persist 冲掉。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.129.0-rc30`，短剧制作能力无新增。

## 1.129.0-rc31 — 短剧指针同步 / 编辑器终端 i18n 补全

- [ ] 系统语言为简体中文时，编辑器底部终端面板头部显示「终端」，工作目录输入框占位符为「工作目录」，Run 菜单标签为「运行」，无项目命令时菜单显示「未找到项目命令」，四个按钮 tooltip 依次为「启动 Shell / 终端设置 / 清除 / 关闭」。
- [ ] 终端设置页各标签均为中文：分组标题「终端」「环境」，字段「Shell / 字体 / 自定义字体 / 大小 / 光标 / 光标闪烁 / 配色方案」，配色方案首项为「跟随应用皮肤」，自定义字体占位符为「例如 JetBrainsMono Nerd Font」，三段灰色说明文案（自定义字体、跟随皮肤、环境变量）均为中文；字号滑块右侧仍显示「NN pt」。
- [ ] 系统语言为英文时上述文案保持原英文，无缺字或 key 裸露（形如 `editor-terminal.*` 的字符串不应出现在界面上）。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.129.0-rc31`，短剧制作能力无新增。

## 1.129.0-rc32 — 短剧指针同步 / 持久化模型 nonisolated 化

- [ ] 纯注解清理,无行为变化:回归冒烟即可——发消息、开新会话、重命名/置顶/归档/删除会话、重启后历史完整。
- [ ] 中英文界面文案抽查(L10n 改为 nonisolated,不应有任何文案变化)。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.129.0-rc32`，短剧制作能力无新增。

## 1.129.0-rc33 — 短剧指针同步 / 蒙版编辑面板文案国际化收尾

- [ ] 系统语言切到 English 启动 app，打开图片蒙版编辑面板：面板标题、工具栏 tooltip（撤销/清空/导出）、蒙版工具/画笔模式/模式/服务分段选择器、反选蒙版 Toggle、提交区（标题/占位符/提交按钮/配置提示）、选区摘要、状态消息、空状态、上下文行标签（项目/集/分镜/资产类/资产/检查项）均应显示英文。
- [ ] 中文系统下上述文案保持原中文；导出蒙版后状态行「已导出蒙版（N 个选区/笔迹…）：路径」格式正常，反选/橡皮/旧蒙版底稿后缀拼接无乱码或缺段。
- [ ] 点「发送到聊天」和提交任务后 composer 里的 `<image-editor-context>` / `<image-edit-task-submitted>` 结构化块键值行保持英文键名不变（`active_task_follow_up` 合约行保持中文原文）。
- [ ] `ruby scripts/short_drama_media_contract_test.rb` 与 `ruby scripts/image_edit_contract_test.rb` 均 failures=0（断言已同步 L10n 形式）。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.129.0-rc33`，短剧制作能力无新增。

## 1.129.0-rc34 — 短剧指针同步 / 补丁应用 CRLF 与模糊匹配加固

- [ ] 让 agent 用 apply_patch 修改一个 CRLF 行尾的文件（例如从 Windows 拉来的 `.txt`/`.cs`）：补丁应能正常应用，且应用后文件行尾仍是 CRLF（git diff 不应显示整文件行尾翻转）。
- [ ] LF 文件的补丁应用与 edit_file 行为无回归（常规改一处、多处 replace_all、含中文/emoji 内容）。
- [ ] 在含重复代码块的文件里，让 agent 的补丁 context 恰好在两处都出现：应报 "hunk did not match" 交回判断，而不是静默改到错误的位置。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.129.0-rc34`，短剧制作能力无新增。

## 1.129.0-rc35 — 短剧指针同步 / Agent 等待态接管

- [ ] 让 Agent 触发 typed `confirm` 卡片（例如危险命令确认），再点击一条已排队消息的“立即发送”：旧 confirm 卡片应变成已拒绝/收起交互态，排队消息继续执行。
- [ ] 让 Agent 触发 `ask_user` 卡片，再通过 Widget 引导或 composer 发送新消息：旧 ask_user 应视为跳过，不再保留输入框等待回答。
- [ ] 普通流式回复期间发送下一条消息仍应只排队，不应误取消非等待态的当前回复。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.129.0-rc35`，短剧制作能力无新增。

## 1.129.0-rc36 — 短剧指针同步 / 工作树 diff 降级展示

- [ ] 复制或生成大量前端预构建产物目录（例如 `railway-prebuilt-web-dist/assets/*.js`）后打开 Agent 工作树 diff：界面应显示降级原因和文件摘要，不应渲染完整压缩 JS/CSS hunk。
- [ ] 少量普通源码变更仍应显示完整 unified diff，复制按钮复制的也是当前预览内容。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.129.0-rc36`，短剧制作能力无新增。

## 1.129.0-rc37 — 短剧指针同步 / Composer 发图与 shell 哨兵审批修复

- [ ] 在 Composer 中 `Command+V` 粘贴同一张剪贴板图片：预览区应只出现 1 张缩略图，不应重复出现。
- [ ] 选择 `deepseek-v4-flash` 等文本模型后发送带图消息：若 Image Understanding 配置可用，助手应能根据生成的图片描述回答；若配置不可用，应显示错误卡，不应继续发出“图片已省略”的空图请求。
- [ ] 让 Agent 执行 `/bin/sh -lc "echo DOCKER_DONE"` 或同等 `bash` / `zsh` 包装哨兵：智能审批应直接放行，不应弹 Allow/Confirm。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.129.0-rc37`，短剧制作能力无新增。

## 1.129.0-rc38 — 短剧指针同步 / 侧边栏终端提示词收敛

- [ ] 让 Agent 在侧边栏终端中创建或覆写文件：提示词应引导它避免 heredoc / here-string / `cat > file` / `echo > file`，优先使用 App 编辑/写入流程或明确文件传输路径。
- [ ] 要求 Agent 考虑 `rz/sz` 收发文件：它应先说明需要 ZMODEM 前端支持、`rz`/`sz` 已安装和小文件测试/用户确认，不应把 `rz/sz` 当作默认文件写入方案。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.129.0-rc38`，短剧制作能力无新增。

## 1.129.0-rc39 — 短剧指针同步 / 侧边栏终端 ZMODEM 桥接

- [ ] 在 WillDeep 侧边栏 SSH 终端中确认远端 `command -v rz sz`：已安装时可继续测试；未安装时 Agent 应提示按服务器系统安装 `lrzsz`。
- [ ] 远端运行 `rz`：WillDeep 应弹出本机文件选择，选择文件后通过本机 `sz` 上传；本机缺 `sz` 时应取消握手并提示 `brew install lrzsz`。
- [ ] 远端运行 `sz <file>`：WillDeep 应弹出保存目录选择，确认后通过本机 `rz` 接收文件；本机缺 `rz` 时应取消握手并提示 `brew install lrzsz`。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.129.0-rc39`，短剧制作能力无新增。

## 1.129.0-rc40 — 短剧指针同步 / Agent 编辑提示去重 / 远程编辑兜底放宽

- [ ] 在全屏 Agent 中让 Agent 修改文件并生成 worktree 变更：composer 上方应只显示「N 个文件已更改 +X -Y / 审查」汇总条，transcript 底部不应再额外显示「正在编辑/已编辑 某个文件」单文件活动行。
- [ ] 在远端 SSH 场景模拟无法安装 `lrzsz`：Agent 应优先建议 scp/rsync、workspace 文件、附件或 App 编辑/写入流程；这些不可用时，应允许小而清晰、可审查、可验证的 heredoc / patch / sed / perl 等远程编辑兜底，而不是说绝对禁止。
- [ ] 继续执行短剧指针 smoke：当前试用文档基线应指向 `v1.129.0-rc40`，短剧制作能力无新增。

## 1.130.0-rc3 — 右侧面板宽度窗口自适应 / 拖拽调宽防闪动

- ⏳ 把 Agent 窗口收窄到 ~700pt 以下再打开「预览」面板 → 面板应自动收窄（最窄 240pt），中间 chat 列仍可用，不再出现面板占半屏、chat 被裁没的情况；把窗口拉宽 → 面板恢复到之前拖出来的偏好宽度
- ⏳ 打开一个有较长 markdown 回复的会话 + 右侧「预览」/「终端」面板，按住分隔条快速左右拖动 → chat 文本与面板内容不应逐帧重折行「闪动」，只有边界跟手移动；松手后两侧一次性按新宽度重排
- ⏳ 拖动过程中光标应始终保持左右缩放形态、分隔条高亮不闪烁；松手且移开鼠标后光标恢复正常箭头（hover 高亮消失）
- ⏳ 小窗口下尝试把面板往左拖到最大 → 应被窗口封顶挡住，chat 列保留舒适宽度；关闭再打开面板宽度记忆正常

## 1.131.0-rc2 — 终端快照改读 off-main 镜像（治本「一直显示旧内容」）

> 这次改动重写了终端进程层（`AgentLocalProcessTerminalView` 从
> `LocalProcessTerminalView` 换成 `TerminalView` + 自持 `LocalProcess`），
> 交互终端是用户直接打字的地方，务必重点冒烟。Agent 终端与编辑器内置
> 终端（Cmd 打开的那个）**都**用这个类，两处都要测。

- ⏳ 侧边栏「终端」正常起一个本地 shell：能打字、回显正常、Tab 补全、
  Ctrl-C、方向键历史都正常；`vim` / `htop` / `less` 等全屏 TUI 渲染正常、
  退出后屏幕恢复
- ⏳ 让 Agent 一边流式输出一大段富 markdown 回复，一边（或紧接着）调
  `terminal_snapshot`：快照应反映终端**最新**输出，不再「一直显示旧内容」；
  之前会陈旧的场景现在应即时
- ⏳ SSH tab：连一台远程主机，远程跑命令产出多屏输出，snapshot 能读到当前屏
- ⏳ ZMODEM：远程 `sz`/`rz` 传文件仍能触发本地 lrzsz 桥、文件收发成功；传输
  过程中调 snapshot 不崩（内容可能是传输前的旧屏，属预期）；传输结束后终端
  恢复正常、后续 snapshot 跟上
- ⏳ 编辑器内置终端（`EditorTerminalSession`）：打开、打字、改当前目录（OSC 7）
  时 workingDirectory 跟随、进程退出后状态正确
- ⏳ 多 tab + idle reaper：开多个 tab 放置一段时间，非活动 idle tab 被回收、
  活动 tab 不被回收；被回收的 tab 不会让 snapshot 崩
- ⏳ 内存/泄漏抽查：反复开关终端 tab，Instruments/内存不持续上涨（确认镜像
  Terminal 与后台队列随 tab 释放，无强引用环）

---

## Workflow 生命周期回归（1.166.0-rc3）

- ⏳ 启动 `/code-review` 或 `/research`，运行中卡片应每秒刷新耗时并显示红色“停止”；点击后子 Agent 尽快结束，卡片变为 Cancelled 且按钮消失。
- ⏳ 工作流运行时执行 `/stop`，当前模型轮次与当前会话内所有活动工作流都应停止；其他会话的工作流不受影响。
- ⏳ 让 Agent 调用 `run_workflow`：卡片必须出现在发起调用的会话而非当前前台会话；缺少必填参数时工具返回 rejected 且不创建卡片。
- ⏳ 让 Agent 调用一个可快速完成的 workflow：完成摘要应通过隐藏的 workflow completion 通知进入下一轮，Agent 自动继续形成用户可见结论；同一结果不得重复续跑。
- ⏳ 运行 workflow 后清空或删除会话：任务应被取消，之后不得出现迟到通知、重建会话或自动续跑。
- ⏳ 在 `workflow.yaml` 中给连续两个步骤声明 `parallel: true` 且设置 `max_agents: 2`：两步应并行出现；后续未声明 parallel 的步骤等待该批次完成后再启动。

## 已知后续项

- Plan 自动执行的 token 估算显示
- 多语言：workflow 内置 agent prompt 是英文写死的；UI 文案已走 L10n

---

## 1.155.0-rc3 — Files 双击转 Finder + 欢迎页删除 + registry 回退

- ⏳ 只开 Agent 窗口（无编辑器窗口），侧栏 Files 双击一个文本文件
  → Finder 弹出并选中该文件；**不再**出现「未打开文件夹」欢迎窗，
  agent 会话不受影响
- ⏳ 同场景双击图片 / PDF → 同样只在 Finder 里定位
- ⏳ 侧栏 Files 单击 md/html → 面板切 Preview；单击 .swift → 仅选中，
  不弹任何窗口、不抢焦点
- ⏳ 侧栏 Files 右键「在编辑器中打开」（无编辑器窗口时）→ 新开的
  编辑器窗口里**直接是这个文件**（不是空白欢迎页）
- ⏳ 已有编辑器窗口时右键「在编辑器中打开」→ 聚焦既有窗口并装载文件
- ⏳ 关闭上一步新开的编辑器窗口 → Agent 窗口回到之前正聊着的会话，
  **不是**新聊天
- ⏳ ⌘N（编辑器窗口前台时）新开窗口 → 直接是一个可打字的空白
  untitled tab，无欢迎页
- ⏳ 菜单「视图 → 显示编辑器」（⌘⌥E）在只有 agent 窗口时 → 同上，
  空白编辑器
- ⏳ 打开文件夹（⇧⌘O）→ 文件树正常；关掉所有 tab → 显示「没有打开
  的文件」空态（Quick Open / 打开文件按钮可用）

---

## 1.155.0-rc9 — Workflow 卡片重新可见 + 省心托管子 agent 路由

- ⏳ Composer 输 `/research 随便一个问题` 回车 → transcript 里立刻出现
  **完整的 Workflow 卡片**（标题 + Workflow badge + 转圈进度 +
  「n / m agents」+ 计时），不再是一个光秃秃的 WFL 头像行
- ⏳ 卡片运行中点 chevron 展开 → 能看到每个子 agent（scope /
  search:* / fetch:* / verify:* / synthesize）的实时状态与 token 数
- ⏳ workflow 跑完 → 卡片折进历史：WFL 头像行下面有「Deep Research ·
  Done · n / m agents · x tokens」状态行 + 用户的原始问题 + 完整
  研究报告 markdown（标题/列表/链接正常渲染），下方有 copy 按钮，
  复制内容是完整报告
- ⏳ workflow 失败（如断网跑 /research）→ 卡片变红 Failed 且失败原因
  可见；360s 看门狗超时也一样落成可见的 Failed 卡片
- ⏳ 省心托管（some.im）会话跑 `/research` → 子 agent 请求用的模型是
  someim-auto-pro（或 floor 更高时对应档位）；`/code-review` →
  someim-code-high；coding plan 生效时走 coding-plan 梯子（可在
  some.im 后台/审计日志确认，不再是原始配置里的静态模型）
- ⏳ 具体模型（非托管）会话跑 workflow → 行为与之前一致，模型不被改写

---

## 怎么用这个文档

- 每次发新版要补 smoke 项时：在最下面加新 H2 section
- 测过的项打 ✅ 或直接删行
- 发现 bug 写 `❌ <一句话描述>`，然后 spawn 一个 task 修
- 长期不动的 ⏳ 项目要么是低优先级、要么我忘了催 —— 隔一阵翻一下
