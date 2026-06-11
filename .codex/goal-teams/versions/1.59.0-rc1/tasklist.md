# Tasklist

| ID | Owner | Status | Claimed By | Locked Scope | Deliverable | Done Criteria | Verification |
| --- | --- | --- | --- | --- | --- | --- | --- |
| WD-001 | 需求-品牌改名范围确认 | Done | Codex | Goal docs | 改名范围与版本策略 | WillDeep / willdeep.com / 1.59.0-rc1 明确 | 文档存在 |
| WD-002 | 工程-品牌与版本一致性 | Done | Codex | Xcode project、Info.plist、Help plist | Bundle 与 product 改名 | app product、bundle name、版本号一致 | rg + xcodebuild build |
| WD-003 | 工程-品牌与版本一致性 | Done | Codex | Swift brand constants、CLI、network headers | 运行时品牌改名 | User-Agent、X-Title、MCP clientInfo、CLI 命令改为 WillDeep/willdeep | rg + build |
| WD-004 | 产品-可见文案改名 | Done | Codex | README、product-overview、TESTING、Help HTML | 对外文档改名 | 用户可见旧品牌不再作为主名出现 | rg |
| WD-005 | 测试-品牌验收 | Done with Environment Note | Codex | 本地验证 | 验收记录 | 搜索与构建通过；单测执行被沙箱 testmanagerd 阻止 | acceptance.md |
