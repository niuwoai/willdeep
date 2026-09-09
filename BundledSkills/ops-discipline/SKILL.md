---
name: ops-discipline
description: Cross-project discipline for changing something that is already running: back up before you replace, verify before you shift traffic, and know your rollback command before you start. Use for deploys, rollouts, image or config changes, service restarts, and production incidents — including when a project-specific runbook is also in play.
tier: worker
effects: read-only
---

# 运维变更纪律

这份技能不替代任何项目的发版流程。项目流程说「怎么做」，这里说「哪几步不许省」。
两者同时在场时，项目流程给步骤，这份纪律给底线。

## 动手前

1. **先确认你在哪台机器上。** 命令要落在远端时，读一遍终端快照里的 Host 行；
   显示 unknown 就当成可能是远端，别假设本机。张冠李戴的一条命令比没执行更糟。
2. **备份当前正在运行的东西。** 二进制、镜像标签、配置文件、数据库快照，取决于你在换什么。
   没有备份就没有回滚，"改回去" 不算回滚。
3. **写下回滚命令。** 不是"出问题再想"，是现在就写进汇报里。用户在你失败时读到的
   第一句话应该是怎么恢复。
4. **确认变更范围。** 只动被授权的那几个对象。namespace、服务名、路径都要对齐清单，
   不顺手清理"看起来没用"的东西。

## 执行中

- **一步一验证。** 每个改动之后确认它真的生效了再走下一步，不要把五步连成一条命令。
- **失败就停。** 中途任何一步报错，停下来如实汇报命令与输出。不要绕过报错继续，
  也不要自己发明补救步骤。
- **不要重复不幂等的操作。** 超时不等于没生效。重试之前先查当前状态。
- **高风险动作交回去。** 删数据、删资源、不带条件的批量更新、`migrate down`、
  强制推送共享分支、改安全设置：这些不属于你，报告给父会话让人决定。

## 收尾

汇报里必须有这几样，缺一样就是没交付：

- 实际执行的命令与它们的真实输出，不是你以为会发生的事。
- 当前状态的证据：版本号、镜像标签、健康检查结果、Pod 状态，看什么取决于你在换什么。
- 备份放在哪里，以及具体的回滚命令。
- 跳过的步骤和原因。测试没跑就说没跑，别把未验证的说成已完成。

## 出事时

1. **先保留现场再动手。** 日志、进程状态、资源占用、最近的变更记录，
   先取证。重启会把证据一起清掉。
2. **回滚优先于修复。** 先让服务恢复，再慢慢找根因。不要在生产上调试。
3. **说清影响面。** 谁受影响、从什么时候开始、现在恢复了没有。
