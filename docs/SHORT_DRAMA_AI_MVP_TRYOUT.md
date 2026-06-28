# Short Drama AI MVP Tryout

> Last updated: 2026-06-28 | Baseline version: v1.109.0-rc436

这份文档用于试用当前短剧 AI MVP。它不是完整产品手册，只覆盖“不完美但可用”的主路径。

## 试用前准备

- 打开 `build/DerivedData/Build/Products/Debug/WillDeep.app`，或使用同版本打包产物。
- 在 Settings 里配置可用的 Agent 模型。
- 如需真实提交媒体任务，配置 some.im / Replicate 相关 token 和 workflow version。
- 如果不想打真实外网 API，可以只走 dry-run、manifest 导入和本地 Widget 验证。

## 主路径

1. 切到 Agent 模式，创建或打开一个短剧项目。
2. 在短剧侧栏确认能看到集、分镜、人物、场景和制作缺口。
3. 点击制作缺口里的「补主图」「补视频」或「审片」。
4. 检查聊天输入框里的结构化上下文：
   - `<short-drama-production-gap-action>`
   - `dry_run_arguments`
   - `submit_arguments`
   - `open_tasks_arguments`
   - `refresh_tasks_arguments`
5. 先让 Agent 执行 dry-run，确认范围合理后再正式提交。
6. 打开媒体任务侧栏，观察 pending / running / failed / completed 状态。
7. 刷新任务后，下一轮聊天应能接收到 `latest-media-task-refresh`。
8. 任务完成或 manifest 导回后，下一轮聊天应能接收到：
   - `latest-media-task-completion`
   - 或 `latest-media-import`
9. 如果有多张图片，打开候选图 Widget，选择一张图。
10. 对选中图片继续做设主图、图生视频、蒙版编辑、擦除或放大。

## 制作包路径

1. 在短剧侧栏导出制作包。
2. 打开右侧 Widget 预览 `widget-preview.html`。
3. 如果使用 Ruby 或第三方 API 脚本，先看导出的：
   - `production-timeline.json`
   - `production-gap-report.json`
   - `production-shot-list.csv`
   - `media-import-manifest-template.json`
   - `production-review-template.csv`
   - `production-review-queue.csv`
4. 脚本生成本地产物后，调用 `import_media_manifest` 正式导回。
5. 脚本只提交远端异步任务、尚无本地产物时，调用：

```text
import_media_manifest(package_directory=<制作包目录>, dry_run=false, import_pending_tasks=true)
```

6. 导回后检查媒体任务侧栏，并确认聊天下一轮包含 `latest-media-import`。

## 图片编辑路径

1. 从候选图、媒体任务缩略图或检查项打开图片编辑器。
2. 画蒙版区域。
3. 点「发送到聊天」，确认上下文包含真实 `mask_path`。
4. 让 Agent 调用 `edit_image_with_mask`。
5. 提交后打开媒体任务侧栏查看 Replicate / some.im 编辑任务状态。

## 已知限制

- 当前 MVP 不承诺完整剪辑/NLE 自动装配。
- 当前 MVP 不新增更多 provider 专用 UI。
- 真实 some.im / Replicate 任务依赖外部账号、额度、网络和 provider 当前 API 行为。
- CI 只验证本地合约和构建；真实 API smoke 需要人工执行。

## 验收记录

人工 smoke 结果请记录到 [MANUAL_TEST_QUEUE.md](MANUAL_TEST_QUEUE.md) 的 `1.109.0-rc436 — 短剧 AI 制作 MVP 收口` 小节。
