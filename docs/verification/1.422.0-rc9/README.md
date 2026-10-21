# 智能体与 RSI 设置一致性验证

本次修改仅调整设置页的字体、留白、系统背景和只读指令展示，并保存历史
`user/rsi-reviewer 1.0.0-rc5` 原包。没有扩大工具权限或启动真实模型评测。
本机启用状态见 `reviewer-activation.json`；这不是修改云端官方版本，也不改变
所有内置 `reviewer` 别名的路由。

## 定向验证

- `AgentDefinitionRegistryTests`、`AgentWorkspacePresentationTests`、`AgentRSITests`：48/48 通过。
- 覆盖候选 revision、原始指令、Worker 投影、只读工具边界及旧版本回退。
- 本地浅色、深色组件截图已检查；发布后另外在 `/Applications/WillDeep.app` 检查
  智能体库和 RSI 实际界面，确认重复大标题消除、系统字体生效及 rc5 固定状态保留。

## 初次失败及处理

- 初次完整回归：5066 通过、2 失败、1 跳过，总计 5069。
- OCR 日志显示 Apple Vision 的应用缓存缺少 `model.anehash`。将该应用的可再生
  模型缓存可逆移至临时备份后，原断言通过；没有修改 OCR 实现、文档或测试断言。
- 用量库并发测试一次打开 SQLite 返回 nil；隔离两个相关套件 22/22 通过，
  用量套件 14 个测试各重复 10 次通过。尚未确认首次失败根因，不能声称修复了数据库竞态。
- 第二次完整回归：5067 通过、1 失败、1 跳过。唯一失败来自免费审查 fixture 的
  固定输出目录已存在；产品按设计拒绝覆盖并返回 `paidNotApproved`。归档旧输出后
  重新验证，没有放宽付费授权、路径或不可覆盖保护。
- 单方法筛选曾匹配到零测试，报告器正确拒绝将其标为通过；该次不计入通过证据。

原始完整报告、日志及 xcresult 在本工作树的 `build/full-initial/`、
`build/full-second/`，重复验证日志在 `build/usage-repeat/`。这些包含本机运行路径的
原始产物不作为发布附件；此处仅记录脱敏结果。

## 最终完整回归

`ruby scripts/run_tests_fast.rb --without-building -parallel-testing-enabled NO`：
5068 通过、0 失败、1 跳过，总计 5069，退出码 0。源码指纹校验通过后复用同一
测试二进制；缓存恢复、旧 mock 输出归档均未改变源码或断言。跳过项是未授权执行的
真实模型工种靶场，不纳入已通过项。

最终原始报告在 `build/fast-tests/`；脱敏机器摘要见 `tests.json`。

## 发布及本机安装

- 发布源码与 tag：`b19d95024c89f44bde06dafdca07adefa2a1918f` / `v1.422.0-rc9`。
- App、DMG 均经 Apple 公证并 staple；本机严格签名和 Gatekeeper 验证通过。
- 实际安装版本 `1.422.0-rc9 (931)`，可执行文件含 arm64 和 x86_64。
- GitHub 公开预发布、版本化 DMG、latest 和 appcast 已更新；公开下载校验值与
  GitHub 资产 digest 相同，见 `release.json`。Homebrew tap 已推送同一校验值。
- Homebrew 显示 WillDeep 升级成功，但随后全局清理因另一个未信任 cask 返回非零；
  没有扩大 tap 信任。安装结果通过版本、架构、签名、公证和实际启动单独核验。
- 升级前 365 份会话已在本机私有目录备份；升级后 365 份全部可解析、无丢失。
  364 份文件逐字节不变，另 1 份仅 `sidePanelState` 改变，消息内容不变。
- 本机 `user/rsi-reviewer` rc5 保持启用且固定；原官方 rc1 停用、保留可回退。
  不改变云端官方 head 或所有内置 reviewer 别名。

本节为发布后的文档补充，版本 tag 保留指向实际构建源码，不移动已发布 tag。
