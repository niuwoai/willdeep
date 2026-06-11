# Progress

| Member | Claimed Tasks | Status | Evidence | Next |
| --- | --- | --- | --- | --- |
| 需求-品牌改名范围确认 | 改名范围、版本策略 | Done | plan.md / decisions.md | 交给实施 |
| 产品-可见文案改名 | README、product-overview、Help、TESTING | Done | `rg` 未在当前源码/文档中发现旧品牌残留 | 验收归档 |
| 工程-品牌与版本一致性 | Bundle、CLI、headers、版本号 | Done | `xcodebuild build ... CODE_SIGNING_ALLOWED=NO` 通过，产物 `WillDeep.app` | 验收归档 |
| 测试-品牌验收 | 搜索、版本一致性、构建 | Done with Environment Note | plist 校验通过；单测执行被 testmanagerd 沙箱限制阻止 | 记录风险 |
