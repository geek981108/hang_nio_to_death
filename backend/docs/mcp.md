# 后端 MCP 能力

本服务把后端 REST 接口包装成 MCP（Model Context Protocol）工具，供 Agent / ChatGPT 连接器调用。
实现在 [`src/api/mcp.rs`](../src/api/mcp.rs)，鉴权在 [`src/api/mcp_oauth.rs`](../src/api/mcp_oauth.rs)。

**一条主线**：MCP 是 REST 的薄代理 —— 一个工具对应一个 REST 路径，参数按 `id` / `query` / `body`
三段映射。唯一例外是 `nio_trips` 的轨迹字段，它在 MCP 层做富化，不进入 REST 契约。

---

## 1. 端点与协议

| 项 | 值 |
|---|---|
| 端点 | `POST /mcp` |
| 传输 | Streamable HTTP，JSON-RPC 2.0，无会话 |
| 现代协议 | `2026-07-28`：请求头 `Mcp-Protocol-Version`，body `_meta` 需带 `protocolVersion` 与 `clientCapabilities`；`tools/call` 还要求 `Mcp-Method`、`Mcp-Name` 分别与 `method`、`params.name` 一致 |
| 兼容协议 | `2025-11-25`：走 `initialize` → `notifications/initialized` |
| 版本头缺失 | 按兼容协议处理 |
| 其他版本 | 返回 `-32022 unsupported MCP protocol version` |
| 方法 | `initialize`、`server/discover`、`tools/list`、`tools/call`、`notifications/initialized` |

工具返回体是 `content[0].text`，内容为对应 REST 响应的 JSON 字符串；
现代协议额外附 `resultType: "complete"` 与 `_meta.io.modelcontextprotocol/serverInfo`。

### 工具定义缓存

`tools/list` 与 `server/discover` 的现代协议响应带 `ttlMs: 60000`、`cacheScope: private`。
也就是客户端最多缓存 1 分钟，之后会重新拉取——**服务端改了工具 schema 后，连接的客户端会在
1 分钟内自动同步，不需要重新授权**（令牌仍走 `mcp_oauth_tokens`，与工具定义无关）。

两点补充：

- 已经按旧 TTL（1 小时）缓存的会话不会因为这次改动立刻失效，需要客户端重新发起一次
  `tools/list`（重连或新建会话即可，不必重新授权）。之后按 1 分钟刷新。
- 兼容协议 `2025-11-25` 的响应不带 `ttlMs`，刷新时机由客户端决定；同样建议重连一次。
- 本服务是无会话实现，没有 `notifications/tools/list_changed` 这类服务端推送，TTL 是唯一的失效机制。

```bash
# 工具清单
curl -s -X POST http://127.0.0.1:8080/mcp \
  -H "X-API-Key: $API_KEY" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'

# 调用一个工具
curl -s -X POST http://127.0.0.1:8080/mcp \
  -H "X-API-Key: $API_KEY" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call",
       "params":{"name":"nio_trips","arguments":{"query":{"count":3,"track":true}}}}'
```

---

## 2. 鉴权

两种方式，二选一：

1. **API Key**：`X-API-Key: $API_KEY`，与受保护 REST 接口同一把钥匙。
2. **OAuth Bearer**（可选）：配置 `MCP_OAUTH_ISSUER` 与 `MCP_OAUTH_LOGIN_SECRET` 后启用，
   供 ChatGPT 这类连接器使用。

OAuth 细节：

| 项 | 值 |
|---|---|
| 元数据 | `/.well-known/oauth-protected-resource/mcp`、`/.well-known/oauth-authorization-server` |
| 动态客户端注册 | `POST /oauth/register`，`token_endpoint_auth_method=none` |
| 授权 | `GET /oauth/authorize` + `POST /oauth/authorize`，授权码 + PKCE S256 |
| 令牌 | `POST /oauth/token`，`authorization_code` 与 `refresh_token` |
| 有效期 | 授权码 5 分钟，访问令牌 1 小时，续期令牌 30 天（轮换） |
| Scope | `nio.mcp` |

- 令牌**只在 `/mcp` 有效**，不能拿去调 REST。
- 库里只存授权码与令牌的 SHA-256 摘要及有效期（`mcp_oauth_tokens`），不存明文。
- 客户端 ID 由注册回调地址 + 稳定登录口令派生；换口令会使旧令牌失效、客户端 ID 变化，需要重新注册。

**跨域**：请求带 `Origin` 头一律 `403`，浏览器页面无法驱动本 MCP。外部客户端应经 HTTPS 反向代理接入。

---

## 3. 工具清单（24 个）

### 健康与状态

| 工具 | 方法 | 路径 | query | 说明 |
|---|---|---|---|---|
| `nio_health` | GET | `/healthz` | — | 后端健康检查 |
| `nio_status` | GET | `/api/v1/status` | — | 轮询与后端状态 |

### 换电历史与统计

| 工具 | 方法 | 路径 | query | 说明 |
|---|---|---|---|---|
| `nio_swaps` | GET | `/api/v1/swaps` | `limit` `offset` `include_candidates` | 换电事件列表 |
| `nio_swap` | GET | `/api/v1/swaps/{id}` | — | 单条换电事件 |
| `nio_energy_stats` | GET | `/api/v1/energy/stats` | `from` `to`（**必填**，ISO-8601 UTC） | 区间换电次数、费用分项、优惠券、换电/充电电量 |

### 服务订单

| 工具 | 方法 | 路径 | query | 说明 |
|---|---|---|---|---|
| `nio_active_orders` | GET | `/api/v1/orders/active` | — | 最多 20 条进行中订单，含排队号、前方车辆数、预计等待；`null` 表示未知 |
| `nio_create_swap_order` | POST | `/api/v1/swap-orders` | — | **真实下单**，需 `X-Vehicle-Control-Key` + 精确确认文字，**禁止自动重试** |
| `nio_import_order` | POST | `/api/v1/orders/import` | — | 导入一条历史订单，写本地库 |

### 换电站

| 工具 | 方法 | 路径 | query | 说明 |
|---|---|---|---|---|
| `nio_stations` | GET | `/api/v1/stations` | `limit` `offset` `q` | 本地站点目录 |
| `nio_search_stations` | GET | `/api/v1/stations/search` | `name`（**必填**） | 先本地后远端，命中会写回目录 |
| `nio_nearby_swap_stations` | POST | `/api/v1/stations/nearby` | — | 上游地图视口查询，只返回换电站 pin 与直线距离；**不是半径完整列表**，不回显入参坐标 |
| `nio_station` | GET | `/api/v1/stations/{id}` | — | 站点详情 |
| `nio_station_live` | GET | `/api/v1/stations/{id}/live` | — | 实时费率、可用电池、排队观测、每槽倒计时 |
| `nio_straight_line_energy` | POST | `/api/v1/stations/{id}/straight-line-energy` | — | 读最近 100 km 能耗缓存 + 到站直线距离；`id` 需 `PS-NIO-` 前缀，未知站点可在 body 里补坐标 |

### 车辆

| 工具 | 方法 | 路径 | query | 说明 |
|---|---|---|---|---|
| `nio_vehicle_status` | GET | `/api/v1/vehicle/status` | — | 当前车辆状态；**会写入一条采样**（因此不算 read-only） |
| `nio_vehicle_history` | GET | `/api/v1/vehicle/history` | `limit` | 定位/状态采样，按时间倒序 |
| `nio_widget_info` | GET | `/api/v1/vehicle/widget-info` | — | Widget 综合信息 |
| `nio_trips` | GET | `/api/v1/vehicle/trips` | `count` `query_time` `track` | 已入库行程；**`track=true` 时才带轨迹**，详见第 4 节 |

### 充电

| 工具 | 方法 | 路径 | query | 说明 |
|---|---|---|---|---|
| `nio_charging_current` | GET | `/api/v1/vehicle/charging/current` | — | 最近一次充电会话的采样 |
| `nio_charging_sessions` | GET | `/api/v1/vehicle/charging/sessions` | `limit` | 充电会话摘要列表 |
| `nio_charging_session` | GET | `/api/v1/vehicle/charging/sessions/{id}` | — | 指定会话的完整曲线与积分电量 |

### 权益与运维

| 工具 | 方法 | 路径 | query | 说明 |
|---|---|---|---|---|
| `nio_available_coupons` | GET | `/api/v1/coupons/available` | `limit` `offset` | 可用卡券；`amount` 是合并条目数，券的张数看 `coupon_groups[].count` |
| `nio_check_in` | POST | `/api/v1/check-in` | — | 手动签到；同日重复返回 `409` |
| `nio_poll` | POST | `/api/v1/poll` | — | 触发一次站点轮询，会请求上游并写观测 |

---

## 4. `nio_trips` 的轨迹开关

行程接口默认不带轨迹，因为一条 27 分钟的行程就有约 150 个点（≈15 KB），`count=20` 会撑到 300 KB。

```json
{"query": {"count": 3, "track": true}}
```

`track=true` 时，每个 item 多一个字段：

```json
"track": {
  "source": "sampled" | "official",
  "points": [
    {"sampled_at": "...", "latitude": 39.1, "longitude": 117.7,
     "speed_kph": null, "power_consumption": null, "np_status": null}
  ]
}
```

选取规则：

1. **sampled**（优先）：`vehicle_snapshots` 中落在该行程 `[started_at, ended_at]` 窗口内的定位采样，
   按时间升序。状态报文没有逐点车速/功率，所以这三个字段是 `null`。
2. **official**（兜底）：窗口内没有采样点时，用 `vehicle_trip_tracks` 里的官方轨迹，字段完整。
3. **两者都没有**：整个 `track` 字段不出现（不是空数组），避免被误读成"轨迹为空"。

其他约定：

- `track` 是布尔，也接受 `"true"` / `"false"` 字符串；其他值返回 `-32602 track must be a boolean`。
- 这个参数**只在 MCP 层生效**，不会转发给后端 REST；`GET /api/v1/vehicle/trips` 的契约保持不变。
- 想拿全程路线时 `count` 给 1~3 即可；`track=false`（或缺省）是日常读法。

---

## 5. 参数约定

**路径参数 `id`**：非空、≤256 字节，只允许 ASCII 字母、数字、`-`、`_`、`:`，否则 `-32602 invalid id`。
`nio_straight_line_energy` 的 `id` 额外要求 `^PS-NIO-[A-Za-z0-9_-]+$`。

**query 对象**：可省略。键必须在工具声明的 `query_keys` 内，否则 `-32602 unknown query parameter`。
值支持字符串、数字、布尔。类型按名映射：`limit`/`offset`/`count`/`query_time` → integer，
`include_candidates`/`track` → boolean，其余 → string。
`nio_energy_stats` 的 `query` 必填（`from`、`to`），`nio_search_stations` 的 `query` 必填（`name`）。

**body**：仅 POST 工具有。
- `nio_create_swap_order`：`{"station_id": "PS-NIO-...", "confirmation": "CREATE SWAP ORDER"}`，两个字段都必填，不接受多余字段。
- `nio_nearby_swap_stations`：`{"latitude": ..., "longitude": ...}`，必填。
- `nio_straight_line_energy`：`{"latitude": ..., "longitude": ...}` 必填，可选成对的 `station_latitude` / `station_longitude`。
- `nio_import_order`：通用对象，按 REST `POST /api/v1/orders/import` 的形状。

---

## 6. 工具注解（annotations）

`tools/list` 会为每个工具返回四个 hint：

| hint | 规则 |
|---|---|
| `readOnlyHint` | 所有 GET 工具，**但 `nio_vehicle_status` 除外**（它会落一条采样）；`nio_nearby_swap_stations` 虽是 POST，但只做上游查询，也被标为只读 |
| `destructiveHint` | 仅 `nio_create_swap_order`、`nio_check_in` |
| `idempotentHint` | 与 `readOnlyHint` 相同 |
| `openWorldHint` | `nio_station_live`、`nio_straight_line_energy`、`nio_nearby_swap_stations`、`nio_search_stations`、`nio_trips`、`nio_available_coupons` |

⚠️ 注解是粗粒度的提示，**不能当作安全边界**：`nio_poll`、`nio_vehicle_status`、`nio_check_in`、
`nio_import_order` 实际都会触达上游或写本地库，但 `openWorldHint` 未标记。判断副作用请以第 3 节
的"方法 + 说明"为准。

---

## 7. 错误语义

两层：

1. **JSON-RPC 错误**（HTTP 400）：`-32600` 非法请求、`-32601` 未知方法、`-32602` 参数错误
   （未知工具/缺失 id/非法参数值等）、`-32020` 现代协议头部与 body 不一致、`-32022` 协议版本不支持。
2. **工具执行错误**：正常返回 `result`，但带 `"isError": true`，`content[0].text` 是
   `HTTP {status}: {body}` 或 `backend request failed` / `backend returned non-JSON`。

也就是说：参数问题走 JSON-RPC 错误码，业务失败走 `isError`。客户端要把两者都处理。

---

## 8. 重试建议

| 工具 | 重试 |
|---|---|
| 读类（`nio_swaps`、`nio_stations`、`nio_trips` …） | 可安全重试 |
| `nio_create_swap_order` | **绝不自动重试**（真实下单） |
| `nio_check_in` | 仅"请求尚未发出"的连接失败由服务端每日重试最多 3 次；可能已到达上游的失败不重试 |
| `nio_poll`、`nio_import_order`、`nio_vehicle_status` | 会写库，重试前先确认是否已生效 |
| `nio_trips` | 只读库；但每次读取会**异步排队**一次上游同步，需要更新数据时稍后重查，不要循环猛刷 |

---

## 9. 与 REST 的关系

- 工具 ↔ REST 一一对应，`openapi.json` 里的接口说明、错误码、字段单位同样适用于对应工具。
- 唯一增量是 `nio_trips` 的 `track`：只在本层附加，REST 响应不含该字段。
- 车控能力不在 MCP 暴露。
- 多租户模式下，MCP 与 REST 一样按租户前缀和各自的 API Key 隔离。

---

## 10. 部署检查清单

- [ ] `API_KEY` 已配置（MCP 与 REST 共用）；或在 `MCP_OAUTH_ISSUER` + `MCP_OAUTH_LOGIN_SECRET` 下启用 OAuth。
- [ ] 反向代理转发 `/mcp`、`/oauth/*`、`/.well-known/oauth-*`；`MCP_OAUTH_ISSUER` 是外部可达的 HTTPS 源。
- [ ] 不要把登录口令放进 URL，也不要在日志里打印 `Authorization` / `X-API-Key`。
- [ ] Claude/ChatGPT 等客户端只在服务端直连，浏览器页面会被 `Origin` 检查拒绝。
- [ ] 行程轨迹依赖后台同步/补数：升级后需执行 `backfill-tracks` 才有历史轨迹（见 [README](../README.md)）。
