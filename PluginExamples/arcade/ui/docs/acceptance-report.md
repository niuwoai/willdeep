# 独立验收报告（干净环境完整回归）

- 验收节点：`dispatch--d07ea6a6`（工作树 checkout）
- 逻辑项目：`dispatch-e2e-handoff-rc3`
- 验收时间：2026-08-19（Asia/Shanghai）
- 验收范围：五游戏大厅、五个独立游戏、响应式布局、键盘/触屏双通道、最佳成绩持久化、异常存储降级、干净克隆四命令门禁。

## 一、干净克隆四命令门禁（验收标准 1）

在 `verification/clean-clone/`（从本分支全新克隆，HEAD 锁定本验收提交）执行：

| 命令 | 退出码 | 结果摘要 |
| --- | --- | --- |
| `yarn install --frozen-lockfile` | 0 | 依赖与 yarn.lock 完全一致，无改动 |
| `yarn build` | 0 | `tsc --noEmit` 通过；Vite 构建 62 modules，产物 dist/ |
| `yarn test` | 0 | Vitest 11 个文件、84 个用例全部通过 |
| `yarn test:e2e` | 0 | Playwright 全量回归通过（详见第三节） |

执行方式：`verification/clean-clone/`（干净克隆，HEAD 锁定验收代码提交 `b06df49`；门禁前清空 `node_modules/` 与 `dist/` 强制全新安装）。运行日志：`verification/clean-clone/{install,build,unit,e2e}.out` 与 `gate.log`（gitignored，本地保留）。四命令全部退出码 0，实测耗时 install 2.25s / build 3.70s / unit 2.27s / e2e 19.1s。

交付提交复验：最终归档提交 `f6b96a4`（与 `b06df49` 代码一致，仅新增文档）另行全新克隆至 `verification/clean-clone-final/` 复验四命令——install 33.67s（冷缓存）/ build / unit（11 文件 84 用例）均 exit 0；e2e 因共享宿主机 Chromium 启动失败窗口（chrome-headless-shell SEGV，见第五节）经仓库内 `scripts/e2e-gate-run.sh` 门禁重试于首次尝试通过：22 passed (50.7s)，日志 `verification/clean-clone-final/gate-e2e.log` 与 `.cache/e2e-retry.log`。

## 二、验收证据覆盖（验收标准 2 与 3）

- 大厅五入口：`tests/e2e/lobby.spec.ts`（5 款游戏入口 + 进入/返回 + 语言切换）。
- 360×640 无横向溢出：`tests/e2e/layout.spec.ts`（大厅 + 五游戏共 6 路由，`scrollWidth <= clientWidth` 双断言）。
- 贪吃蛇：键盘方向键、CDP 真实触屏滑动（`Input.dispatchTouchEvent`，浏览器合成 `pointerType=touch`）、撞墙判负、计分、best、重开。
- 俄罗斯方块：键盘左移/旋转、CDP 真实触屏按钮 tap、终局计分、best、重开。
- Pong：键盘移动、CDP 真实触屏按钮驱动球拍、先得 5 分获胜、计分、best、重开（`page.clock` 物理推进）。
- 扫雷：安全格通关、右键插旗、踩雷判负、计分、best、重开。
- 记忆翻牌：通关计步、best、刷新持久化、重开、CDP 真实触屏 tap。
- 存储（`tests/e2e/storage.spec.ts`）：跨游戏存储隔离（`arcade.best.memory` 不串扰 `arcade.best.snake`）、损坏 JSON 降级（不白屏、按“暂无记录”、可重玩并写入新纪录）、localStorage 抛异常（隐私模式/配额超限模拟）时应用降级不白屏且玩法不受影响。

## 三、e2e 回归证据（验收标准 2 与 3 的运行时证据）

- 结果：`22 passed (19.1s)`，0 failed，0 retried（`playwright.config.ts` 配置 retries=2 未触发）。日志：`verification/clean-clone/e2e.out`。
- 大厅（标准 2）：`lobby.spec.ts` 2 用例——5 张 `lobby-card-*` 入口可见、进入贪吃蛇并返回、语言切换生效。
- 布局（标准 2）：`layout.spec.ts` 1 用例——360×640 视口下大厅与五游戏共 6 路由，`documentElement.scrollWidth` 与 `body.scrollWidth` 双断言 ≤ `clientWidth`，无横向溢出。
- 五游戏（标准 2）：贪吃蛇 4 用例（键盘方向键、CDP 真实触屏滑动、撞墙判负 + 计分 1 + best 持久化 + 重开复位）；俄罗斯方块 3 用例（键盘左移/旋转、CDP touch tap 按钮、终局计分 + best 持久化 + 重开复位）；Pong 4 用例（键盘移动、CDP touch tap 驱动球拍、先得 5 分获胜 + best 持久化、停顶漏球判负不写 best + 重开复位）；扫雷 2 用例（安全格通关 + 计分 81 + best 持久化、右键插旗 + 踩雷判负 + 新开局复位）；记忆翻牌 3 用例（2 步通关 + 计步 + best 持久化 + 重开、CDP touch tap 翻牌配对）。
- 键盘与真实触屏双通道：键盘通道用例见上；触屏通道由 CDP `Input.dispatchTouchEvent` 注入真实 touch 事件（浏览器合成 `pointerType=touch`），覆盖贪吃蛇滑动、俄罗斯方块按钮、Pong 按钮、记忆翻牌点按四款游戏。
- 存储（标准 3）：`storage.spec.ts` 3 用例——跨游戏隔离（`arcade.best.memory`=180 不串扰 `arcade.best.snake`，徽章显示"暂无记录"且 key 不存在）；损坏 JSON 降级（坏纪录不白屏、按"暂无记录"处理、通关后正常写入新纪录 180）；localStorage 抛异常（`Storage.prototype.getItem/setItem/removeItem` 全部 throw，模拟隐私模式/配额超限）时大厅与贪吃蛇均正常渲染、徽章降级"暂无记录"、玩法不受影响。

## 四、Git / 调度归档（验收标准 4）

- 合并集成提交：`eef806b chore(verification): 合并集成结果以执行干净环境独立验收`（双亲：`b4a10e4` + `207e10b`）。
- 验收分支提交链：`eef806b` → `7f53773`（补全验收 e2e + Pong 可获胜性修复）→ `3d796d0`（归档 CDP 触屏基础设施）→ `79edf02`（--no-zygote 规避沙箱 zygote 崩溃）→ `67f0936`（HSS 引擎切换）→ `3bce3ca`（门禁探测同路径化）→ `b06df49`（Pong 重开复位断言有界化）→ 最终归档提交（本文档 + CHANGELOG + 拓扑文档）。
- 分支：`dispatch--d07ea6a6`；未执行共享分支合并（main 保持 `b4a10e4`）。
- 分支拓扑：并行实现分支 `dispatch--5110767a`(memory)、`dispatch--7d833d09`(snake)、`dispatch--f7312492`(tetris)、`dispatch--a1f5c1ca`(minesweeper)、`dispatch--5a15afda` 及其提交均保留，见 `docs/verification-topology.md` 归档输出。
- worktree 记录：见 `docs/verification-topology.md`。
- 调度日志：由 WillDeep dispatch 审计面保留；本报告记录逻辑项目、checkout、分支与提交，不复制运行时日志或敏感信息。

## 五、验收环境修复（本节点新增）

受限沙箱内 Chromium 启动失败根因与修复：

1. 沙箱拒绝 crashpad 的 mach bootstrap 注册（`bootstrap_check_in` Permission denied 1100），Chrome for Testing 与 headless shell 启动即 SEGV（`SEGV_ACCERR 0x10`）。
2. 实测 chrome-headless-shell（无 crashpad）+ `--no-zygote` 在沙箱内经 playwright 可稳定启动、导航、驱动（含 CDP touch 通道）。
3. 配置与工具随之调整：`playwright.config.ts` 优先选用 HSS 并携带 `--no-zygote`；`scripts/e2e-cdp-server.cjs` 同步；门禁探测改为与套件完全同路径的 `scripts/e2e-probe.cjs`（playwright-core launch + 导航），消除 CLI 探测误报。
4. 共享宿主机仍存在周期性失败窗口，`scripts/e2e-gate-run.sh` 按窗口探测并重试整套 e2e（`MAX_ATTEMPTS` 可调）。
