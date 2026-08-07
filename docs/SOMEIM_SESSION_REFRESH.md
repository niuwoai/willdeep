# some.im 登录态续期与资料同步

> 状态：**待决策**（客户端侧的覆盖 bug 已在 1.230.0-rc4 修复；根因需要服务端改动）。
> 涉及仓库：`~/Sites/Xedit`（客户端）、`~/Sites/muchtoken`（服务端）。

## 1. 现象

用户反馈：「在某个时间，头像和昵称消失了，但 credits 点数还在显示。」

## 2. 根因（已在代码中核实）

客户端有**两套凭据**，寿命完全不同：

| 数据 | 接口 | 凭据 | 寿命 |
| --- | --- | --- | --- |
| 余额 / 点数 | `GET account/balance` | `api_key` | 长期 |
| 昵称 / 头像 | `GET /customer/me` | `session_token` | **7 天** |

服务端锚点：

- `internal/authapi/session.go:33` — 会话固定 `INTERVAL 7 DAY`，无滑动续期。
- `internal/authapi/router.go:166` — `/customer/me` 走 `authWrap`；`resolveAuthSession` 只查 `user_sessions` 表，**`api_key` 无法认证该接口**。
- `internal/authapi/client_login_email.go:465` — 登录响应的 `account` 块只有 `email / tenant_id / balance_usd / credits / credits_per_usd / default_model`，**不含 `nickname` / `avatar_url`**。
- 服务端全仓无 session 续期 / refresh 端点。

于是形成这条链：

1. 登录 → 存下 `api_key`（长期）+ `session_token`（7 天）。账户里此时**没有**昵称头像。
2. 随后某次余额刷新顺带调 `/customer/me` 成功 → 补上昵称头像。
3. 第 7 天后 `session_token` 过期 → `/customer/me` 401 → 资料无法再刷新。
4. 期间任何一次重新登录，会把只含 email/余额的登录结果**原样覆盖**本地账户 → 昵称头像被抹为空。
5. 此后余额仍走 `api_key` 正常刷新 → **点数在，名字和头像没了，且再也回不来**。

第 4 步已在客户端修复（`SomeIMAccount.preservingProfile(from:)`，1.230.0-rc4）。**第 3 步无法在客户端解决**——没有任何长期凭据能换回 `/customer/me` 的访问权。

## 3. 候选方案

### 方案 A：服务端新增「api_key 换 session」端点（推荐）

```
POST /public/client-login/session/exchange
Authorization: Bearer <api_key>
→ { "token": "...", "expires_at": "..." }
```

- 客户端：`/customer/me` 收到 401 时，用 `api_key` 静默换新 token 并重试一次；失败则保留现有资料并在账户菜单提示「登录态已过期，点击重新登录」。
- 优点：`api_key` 本就是长期凭据，语义清晰；服务端改动集中在一个新 handler，不动通用鉴权；客户端改动小且可测。
- 风险：`api_key` 泄露即可换取 session。但 `api_key` 本身已能调用计费 API，权限面并未实质扩大；可加频率限制与审计日志。

### 方案 B：让 `/customer/me` 接受 api_key

- 改 `resolveAuthSession`，允许用 `api_key` 解析出 user/tenant。
- 优点：客户端只需换一个 Authorization 来源，最省事。
- 风险：动的是**所有** customer 接口共用的鉴权中间件，影响面远大于 A，回归风险高。

### 方案 C：登录响应补上 nickname / avatar_url

- 只治标：登录当下有资料了，但用户之后在网页端改了昵称头像仍同步不过来，7 天后依旧失联。
- 建议作为 A 的补充一起做（登录即有资料，不必等第一次 `/customer/me`），不单独作为方案。

### 建议

**A + C**。A 解决「过期后无法自愈」，C 消除「刚登录还没资料」的空窗。二者都不触碰通用鉴权路径。

## 4. 若采纳，待办清单

**服务端（muchtoken）**

1. 新增 `POST /public/client-login/session/exchange`：校验 `api_key` → 查出 user/tenant → `createSession` → 返回 token 与 `expires_at`。
2. 该端点加频率限制（同一 key 每分钟若干次）与审计日志。
3. 在 `client-login/email/verify` 与 `browser-complete` 的 `account` 块补 `nickname`、`avatar_url`。
4. Go 单测：有效 key 换取成功、无效/停用 key 拒绝、限流生效。
5. 部署：按 `deployment.md` 走，先备份旧二进制并确认回滚命令。

**客户端（Xedit）**

6. `SomeIMClient` 增加 `exchangeSessionToken(apiKey:)`，`/customer/me` 401 时静默换取并重试一次（只重试一次，避免失效 key 打循环）。
7. 换取失败时保留既有资料，账户菜单显示「登录态已过期」与重新登录入口——静默失败正是这次问题拖了很久才被发现的原因。
8. 单测：401 触发换取、换取成功后重试、换取失败不清空资料且置位提示、不重复换取。

## 5. 尚未验证

- 线上实际的 session 过期分布（是否有用户因常在线而从未过期）。
- `/customer/me` 401 的具体响应体形状，客户端据此判定「确实是登录态失效」而非其它 4xx。
