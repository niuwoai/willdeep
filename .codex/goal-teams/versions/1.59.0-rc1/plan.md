# WillDeep Rename Plan

## Clarification Status

- User goal: 用户已拿下 `willdeep.com`，要求项目改名为 `WillDeep` 并全面实施。
- Working assumption: “全面实施”覆盖对外品牌、Bundle 展示名、产品名、帮助文档、CLI、持久化路径、网络可观测 header、OpenRouter 署名、README、CHANGELOG、product-overview 和测试文档。
- Internal source folder and Xcode scheme may remain `Xedit` where renaming would require broad project surgery unrelated to user-facing brand. User-visible output must become `WillDeep`.

## Version

- Previous version: `1.58.0-rc18`
- Target version: `1.59.0-rc1`
- Reason: 品牌与域名切换属于功能/产品级变更，允许提升 minor 并重置 rc。

## Teams

| Member | Task | Deliverable | Validator |
| --- | --- | --- | --- |
| 需求-品牌改名范围确认 | 锁定 WillDeep / willdeep.com 改名边界 | Requirement Specification Card | Codex Lead |
| 产品-可见文案改名 | README、product-overview、TESTING、Help 文案 | 文档与帮助资源更新 | 测试-品牌验收 |
| 工程-品牌与版本一致性 | Bundle、product、CLI、headers、版本号 | Swift/Xcode 配置更新 | 测试-版本校验 |
| 测试-品牌验收 | 搜索、版本一致性、构建 | 验收记录 | Codex Lead |

## Stop Conditions

- 发现密钥、notary 凭据或个人隐私信息需要脱敏处理。
- Xcode project 无法解析或构建命令无法确认当前配置。
- 品牌改名需要 Apple Developer 证书、notary profile 或远程仓库状态才能继续。
