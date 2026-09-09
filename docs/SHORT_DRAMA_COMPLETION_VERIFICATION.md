# 短剧共创修复验收

日期：2026-09-09。插件版本：0.15.0；宿主版本位点：1.357.0-rc1。

## 修复范围与证据

| 问题 | 实现 | 验证 |
| --- | --- | --- |
| 空分镜无法让 AI 首次生成 | 本集正文进入上下文；显式创建草稿分镜，已有分镜时拒绝重复创建 | App 测试、DramaService 测试、浏览器从空列表生成并采用 |
| 分镜草稿存入后不显示、不能采用 | 草稿优先显示，字段前后对比，保存、采用、丢弃；丢弃新分镜移除草稿空壳 | App 采用测试、Ruby 采用/丢弃测试 |
| 首尾帧描述只能手填 | 独立 frames 聊天、共享角色与分镜资料、可编辑创作技能、草稿描述与停止请求 | App frames 聊天测试、浏览器两轮修改并采用，第二轮只改尾帧时保留首帧 |
| 结构约束零散 | `schemas/creative-v1.json` 同时被前端解析和 Ruby 服务使用，覆盖策划、角色、分集、分镜、选段和首尾帧字段 | Schema 单测、Ruby 非法类型/超长字段/整批拒绝测试 |
| AI 或旧确认覆盖更新内容 | 分镜批量写入检查本集和各镜修订号，采用同时校验正式与草稿修订号；未保存编辑先保存 | 过期批量原子拒绝测试、过期采用测试、前端不将冲突误报成功 |
| 长列表和大空白让聊天难用 | 角色简介截断并限制列表高度；宽窗口内容与聊天分栏，窄窗口上下排列；模型独占一行 | 浏览器 1440px、900px 截图，无水平溢出、模型控件宽度检查 |

## 可重跑验证

在仓库根目录执行：

```sh
yarn --cwd PluginExamples/video-studio/ui test
yarn --cwd PluginExamples/video-studio/ui build
/usr/bin/ruby scripts/video_studio_drama_test.rb
/usr/bin/ruby scripts/video_studio_skill_test.rb
/usr/bin/ruby scripts/video_studio_server_test.rb
ruby scripts/version_consistency.rb
ruby scripts/package_video_studio.rb
```

- 前端：157 项通过。
- 数据服务：48 项通过。
- 创作技能：12 项通过。
- MCP/服务集成：59 项通过，使用本机模拟网关。
- 浏览器脚本：`scripts/video_studio_browser_smoke.cjs`。先启动 5178 端口的 Vite 服务，再指定可用的 Playwright 模块运行脚本。脚本覆盖生成、预览、采用、二次局部修订和响应式布局，输出截图与 `report.json`。

浏览器使用确定性测试模型与桥接数据；真实 Ruby 数据保存和 MCP 命令由另外两组测试验证。此次未调用付费生图/视频接口，不将这些测试等同于提供商生成质量验收。

## 兼容与交付

旧存档缺少修订号仍按 0 读取；候选图片与正式内容不会被 AI 返回的额外字段改写。新生成分镜用 `draftOnly` 标记，采用后移除该标记并进入制作状态。未采用的分镜草稿不能直接进入生图/视频生成。

安装包包含共享 Schema、服务端、技能模板及构建后的前端。此次修复和打包不包含公开发布、主分支集成或本机安装。
