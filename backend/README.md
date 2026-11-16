# NIO 换电记录后端

这是一个基于 Actix Web、可常驻运行的 Rust 服务，用 PostgreSQL 及 Diesel 保存：

- 每次站点轮询的电池快照；
- 进行中订单对应的站点库存变化，包括只先出现换上电池的部分候选；
- 历史换电订单的完成时间、换电站、状态、价格与支付明细；
- 订单确认后可核验的换上/换下电池、生产日期与换电量；
- 每次轮询的成功、跳过或失败状态。

服务不会把推断值伪装成精确值。`exact_energy_kwh` 只来自订单导入；站点快照只能计算
`estimated_energy_kwh`。同理，站点差分记录的状态是 `observed_candidate`，与用户订单匹配后才变成
`confirmed`。

### 数据库

服务只支持 PostgreSQL。启动时由 `pg_store` 内嵌并执行 `pg_migrations/` 中的 Diesel 迁移；旧版
SQLite 存储结构、迁移脚本与导入工具均已移除，不再提供从 SQLite 导入数据的入口。

### 区间统计与 MCP

`GET /api/v1/energy/stats?from=...&to=...` 按左闭右开 UTC 区间统计换电次数、已知费用分项、
优惠券、实际支付、换电电量和充电电量；另给出北京时间当前自然月换电次数。充电电量逐个采样段
优先按功率积分；缺有效功率时，仅在最近一次已确认换电有可信换上电池容量、该段无换电且 SOC
有效上升时，使用容量 × SOC 增量估算。响应分列两种来源和未覆盖段数；占比始终按已知电量计算，
`energy_coverage_complete=false` 表示实际总量仍有缺口，此时占比仅代表已知部分。
普通 PostgreSQL 的时间索引已足够支撑当前采样率，暂不引入额外时序库。

完整的 MCP 说明（协议版本、鉴权、24 个工具的参数与副作用、`nio_trips` 的轨迹开关）见
[docs/mcp.md](docs/mcp.md)。

`POST /mcp` 提供 MCP Streamable HTTP JSON-RPC（支持 `2026-07-28` 无会话请求和
`2025-11-25` 初始化请求），默认使用与受保护 REST 接口相同的 `API_KEY`。配置
`MCP_OAUTH_ISSUER` 和 `MCP_OAUTH_LOGIN_SECRET` 后，也接受 OAuth Bearer 令牌，供 ChatGPT MCP
连接器使用。授权服务器提供资源与服务器元数据、动态客户端注册、授权码 + PKCE S256、短期访问令牌
和轮换续期令牌。授权页要求独立登录口令，授权后可访问现有全部 MCP 工具；令牌只在 MCP 上有效，
不能直接调用 REST 接口。客户端 ID 由注册回调地址和稳定的登录口令生成；授权码及访问/续期令牌的
SHA-256 摘要、有效期保存在 PostgreSQL 的 `mcp_oauth_tokens`（不保存明文），重启后仍有效；
授权码只能兑换一次，续期令牌轮换也在数据库中原子完成。凭据同时绑定源地址和登录口令；更换登录口令会使旧令牌失效并改变客户端 ID，旧客户端需重新注册。
`MCP_OAUTH_ISSUER` 必须是可由 ChatGPT 访问的 HTTPS 源地址，反向代理应转发 `/mcp`、
`/oauth/*` 和 `/.well-known/oauth-*`；不得把登录口令放进 URL。工具覆盖健康与状态、换电
历史及统计、订单状态、站点、车辆状态及历史、充电会话、行程、Widget 信息、手动轮询、订单导入和真实换电下单。
同时暴露可用卡券查询和立即签到。
车控能力不暴露。真实换电下单的 MCP 请求还须带 `X-Vehicle-Control-Key`，请求体仍须提供精确确认文字；服务端只执行一次，不自动重试。手动轮询和订单导入会写入本地历史。
跨域浏览器请求带 `Origin` 时会被拒绝；外部 MCP 客户端应通过 HTTPS 反向代理访问。

`GET /api/v1/coupons/available?limit=20&offset=0` 用现有 NIO 账号查询国内版卡包的
`available` 分页结果，单页 1–100 个合并条目。`amount` 是合并条目总数；
`coupon_groups[].count` 取上游 `merge_count`，未合并条目计 1，`page_coupon_count` 为当前页实际张数。
只有首页已包含全部条目且数量均可确认时，`total_coupon_count` 才返回实际总张数；
`face_value_cny` 仅从明确写有“X元优惠券”的标题识别，不推断礼券价值。
后端会为每个北京时间自然日生成一次随机签到时刻，
将计划和尝试记录持久化在 PostgreSQL；进程重启沿用原计划，发出上游请求前先原子占用当天名额。
连接失败等**明确未发出**请求的错误会释放当天名额，按 5 分钟、10 分钟退避最多尝试 3 次；
HTTP 状态、超时和响应解析等**可能已被上游处理**的失败不重试。`NIO_DAILY_CHECKIN_ENABLED=false`
可关闭自动任务（手动接口仍可用）。服务离线跨过整天时不会补签。已有的 `POST /api/v1/check-in`
保留给手动调用，与自动任务共用当天去重记录，重复调用返回 409；成功时返回签到状态、积分及连续天数。
签到成功后若结果无法写入数据库，接口返回 500 `check_in_result_not_recorded`，不会报告为成功。
两个接口均要求普通 `API_KEY`，也作为 MCP 工具暴露；App 不调用签到接口。

## 启动

### Linux systemd 单二进制安装

Ubuntu 服务器固定使用 `/root/nio` 作为工作目录，并从该目录权限为 `0600` 的 `.env` 加载现有
PostgreSQL、NIO 账号和 API 配置。把编译好的 Linux 二进制先上传到临时路径，再以 root 执行：

```bash
sudo /tmp/nio-swap-history-backend.new install
/root/nio/nio-swap-history-backend status
```

`install` 会将自身复制到同目录临时文件、同步并原子替换 `/root/nio/nio-swap-history-backend`，
生成 `/etc/systemd/system/nio-swap-history-backend.service`，执行 `systemd-analyze verify`、
`systemctl daemon-reload`、`enable`、`start` 或 `restart`，并等待本机 `/healthz` 返回 200。
失败时尝试恢复旧二进制和 Unit，并报告回滚是否完整。成功后 systemd 在进程退出及服务器重启后
自动拉起服务；升级继续使用同一 `install` 命令。`status` 不需要 root；`uninstall` 会停止、禁用并
删除 Unit，但保留二进制、`.env` 与数据。`serve` 是 systemd 使用的显式运行命令；无参数启动仍兼容。

当前生产凭据和文件均在 root 管理的 `/root/nio` 下，因此 Unit 延续 root 身份，并启用
`NoNewPrivileges`、`PrivateTmp` 与 `ProtectSystem=full`。迁移到独立服务账号需先迁移这些文件及权限。

### 直接运行与容器

```bash
cd backend
cp .env.example .env
# 编辑 .env，填入 PostgreSQL URL、站点 URL、请求头和随机 API_KEY
cargo run --release
```

默认仅监听 `127.0.0.1:8080`。未配置 `STATION_URL` 时服务仍会启动，订单导入和查询可以使用，
`GET /api/v1/status` 会显示 `station_configured: false`。

也可以用 Docker 常驻运行：

```bash
docker compose up -d --build
```

Compose 只把端口发布到宿主机 `127.0.0.1`，PostgreSQL 数据放在命名卷中。启动前在 Compose 环境设置强随机 `POSTGRES_PASSWORD`。若要对外提供服务，应在前面放
HTTPS 反向代理，保留 `API_KEY`，不要直接暴露 Rust 端口。

基础 `compose.yaml` 不挂载车控凭据。确需在容器中启用车控时，使用可选的
`compose.control.yaml`，先在 Compose 变量中设置四个宿主机绝对路径
`NIO_CONTROL_TLS_CERT_HOST_PATH`、`NIO_CONTROL_TLS_KEY_HOST_PATH`、
`NIO_CONTROL_CA_HOST_PATH`、`NIO_CONTROL_PIN_HOST_PATH`，并配置独立的
`NIO_CONTROL_API_KEY`。四个文件以只读方式挂载，不会在缺失时自动创建。
容器以 UID 10001 运行：宿主机私钥和 PIN 文件仍应是 owner-only，且必须能由容器内该用户读取；
先运行 `docker compose -f compose.yaml -f compose.control.yaml config -q` 检查配置。
这只是部署配置，不代表已进行实车验收。

## 配置

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `BIND_ADDR` | `127.0.0.1:8080` | 监听地址；非回环地址必须配置 `API_KEY` |
| `DATABASE_URL` | `postgres://localhost/nio_swap_history` | PostgreSQL 连接地址；启动时执行内嵌 Diesel 迁移 |
| `POLL_INTERVAL_SECONDS` | `60` | 站点轮询间隔 |
| `VEHICLE_UNLOCKED_POLL_INTERVAL_SECONDS` | `3` | 未锁车或锁车状态未知时的车辆状态检查间隔；优先于旧变量 `VEHICLE_POLL_INTERVAL_SECONDS` |
| `VEHICLE_LOCKED_POLL_INTERVAL_SECONDS` | `20` | 已锁车时的车辆状态检查间隔；请求失败后也以此间隔重试 |
| `NIO_TRIP_ENERGY_TIME` | `03:00` | 每日最近 100 公里行程能耗缓存计算时间，Asia/Shanghai HH:MM |
| `POST_SWAP_POLL_COUNT` | `60` | 退出换电状态后继续复查站点的次数；实际时长随锁车状态变化 |
| `SERVICE_ORDER_POLL_INTERVAL_SECONDS` | `15` | 进行中服务订单轮询间隔 |
| `MATCH_WINDOW_SECONDS` | `1800` | 订单与候选快照的最大匹配时间差 |
| `NIO_DAILY_CHECKIN_ENABLED` | `true` | 是否自动执行每日随机签到；`false` 只关闭后台任务，手动 `POST /api/v1/check-in` 仍可用 |
| `API_KEY` | 空 | 写接口密钥；可用 `openssl rand -hex 32` 生成 |
| `NIO_CONFIG_MASTER_KEY` | 空 | 可选的 32 字节 AES-GCM 主密钥，表示为 64 位十六进制；启用 PostgreSQL 多租户配置后必须保留在服务端环境变量，不能存入数据库 |
| `MCP_OAUTH_ISSUER` | 空 | 可选的 MCP OAuth 公网 HTTPS 源地址，如 `https://example.com`；需与登录口令一起配置 |
| `MCP_OAUTH_LOGIN_SECRET` | 空 | 独立的至少 32 字节登录口令；只放在服务端私有环境变量，不能提交到仓库 |
| `STATION_KEY` | `default` | 稳定的站点标识 |
| `STATION_NAME` | `Configured station` | 展示名称 |
| `STATION_URL` | 空 | iOS 端已验证的 HTTPS 站点接口 URL |
| `STATION_HEADERS_JSON` | 空 | 请求头 JSON，通常包含 Bearer Token |
| `NIO_BEARER_TOKEN` | 空 | NIO App Bearer Token，只能存放在 `.env` 或密钥管理系统 |
| `NIO_ACCOUNT_ID` | 空 | 可选账户标识；仅在上游行程详情接口要求时补充 |
| `NIO_VEHICLE_ID` | 空 | 车辆标识，与 Token 一起配置 |
| `NIO_DEVICE_ID` | 空 | 32 位十六进制 App 设备标识；可单独配置供短信登录使用 |
| `NIO_APP_ID` | `10002` | NIO App ID |
| `NIO_APP_VERSION` | `6.9.0` | 上游请求使用的 App 版本 |
| `NIO_REGION` | `cn` | 区域 |
| `NIO_LANGUAGE` | `zh-CN` | 上游请求语言 |
| `NIO_VEHICLE_VIN` | 空 | 可选 VIN；订单带 `vinCode` 时用于二次过滤 |
| `NIO_CONTROL_API_KEY` | 空 | 32–512 字节车控密钥；未配置则车控 API 不启用，默认要求与 `API_KEY` 独立 |
| `NIO_CONTROL_TLS_CERT_PATH` | 空 | 已签发的 TLS 客户端证书的绝对路径 |
| `NIO_CONTROL_TLS_KEY_PATH` | 空 | 对应私钥的绝对路径；必须仅所有者可读写（0600） |
| `NIO_CONTROL_CA_PATH` | 空 | icar 服务端 CA bundle 的绝对路径 |
| `NIO_CONTROL_PIN_FILE` | 空 | 解锁和手动签发共用的 PIN 密钥文件绝对路径；文件必须为 0600，内容须绑定当前 `NIO_VEHICLE_ID` |
| `NIO_CONTROL_ALLOW_SHARED_API_KEY` | `false` | 仅显式设为 `true` 时允许与普通 API Key 相同；调用车控仍需两个请求头 |
| `NIO_SWAP_MODEL_TYPE` | `ET5T` | 真实下单使用的车型；由服务端配置，客户端不能覆盖 |
| `NIO_SWAP_MODEL_TYPE_YEAR` | `G1.2` | 真实下单发送的 `model_type_year`，需与车辆年款一致（如 2026 款 ES8 为 `G1.1`）；只允许字母、数字和点 |
| `NIO_SWAP_TARGET_BATTERY_CAP_LEVEL` | `1` | 目标电池档位，允许 1、2 或 8（8 为 102 kWh 电池）；由服务端配置，客户端不能覆盖 |
| `SERVICE_ORDER_URL` | 空 | 服务订单完整 HTTPS URL；配置后启用订单轮询 |
| `SERVICE_ORDER_ACCESS_TOKEN` | 空 | 服务订单 Bearer Token；未填时沿用 `NIO_BEARER_TOKEN` |
| `SERVICE_ORDER_HEADERS_JSON` | `{}` | 可选的服务订单请求头 JSON |
| `SERVICE_ORDER_COOKIE` | 空 | 可选 Cookie |
| `STATION_URL_TEMPLATE` | 空 | 目标站接口模板，必须含 `{station_id}`；可复用车辆配置占位符 |
| `STATION_TEMPLATE_HEADERS_JSON` | `{}` | 目标站请求头；未填 Authorization 时沿用 `NIO_BEARER_TOKEN` |

换电下单的 `model_type_year` 读取 `NIO_SWAP_MODEL_TYPE_YEAR`，未配置时发送 `G1.2`。


`STATION_URL` 与 `STATION_HEADERS_JSON` 必须同时配置。服务会为已验证的
`app.nio.com/nio/app/bff/map/resources/v1/swap/` 路径自动刷新 `timestamp` 和 `sign`，再解密响应。
Bearer Token 仍可能过期，需要在部署环境里更新；真实 Token 只放 `.env` 或密钥管理系统，不能提交。

配置 `NIO_BEARER_TOKEN`、`NIO_VEHICLE_ID` 和 `NIO_DEVICE_ID` 后，服务会动态刷新车辆状态和
Widget 请求的 `timestamp`、按参数名和值排序后生成 `sign`。车辆数据功能需这三个变量同时存在；短信登录只需 `NIO_DEVICE_ID`。服务日志和
HTTP 错误不会回显 Token。

### 手机号与短信验证码登录

配置 `API_KEY` 和 32 位十六进制 `NIO_DEVICE_ID` 后，可调用：

1. `POST /api/v1/auth/sms`，JSON 为 `{"mobile":"手机号"}`，返回 `challenge_id` 和 600 秒有效期；
2. `POST /api/v1/auth/login`，JSON 为 `{"challenge_id":"上一步的 UUID","verification_code":"6 位验证码"}`，成功时返回 NIO 的 token 数据。

两步均须使用普通 `API_KEY`；即使只监听回环地址也不开放匿名登录。后端按已验证的 iPad 请求字段、手机号 AES-CBC 转换、POST 签名和短信响应的新路由 Cookie 调用 NIO，省略 `Black-Box`。一个进程只保留一个未完成挑战，重启后挑战失效；验证码提交前即消费挑战，不自动重试。token 响应设置 `Cache-Control: no-store`，客户端应妥善保管。

在原有 `.env` 单租户模式，登录接口只获取凭据，运行中的业务客户端仍使用启动时读取的 `NIO_BEARER_TOKEN`。要让这些客户端使用新 token，需更新部署环境并重启服务；登录成功不自动写入 `.env`。在下述 PostgreSQL 租户模式，登录成功会加密回写对应租户配置。

### PostgreSQL 租户配置

设置 `NIO_CONFIG_MASTER_KEY` 后，服务从 `public.tenant_configs` 读取租户配置。该表只保存 API key 的 SHA-256 摘要和 AES-256-GCM 密文；主密钥仍必须放在数据库外的私有环境变量中，且所有服务实例使用同一主密钥。`default` 租户沿用现有 `public` 业务表与原有 API 路径。其他租户各有 `tenant_<slug>` schema、独立的表和后台任务，路径前缀为 `/t/<slug>`，需使用该租户自己的 API key。iOS 的后端基础 URL 可包含该前缀。租户名只允许小写字母开头，后跟小写字母、数字或下划线；新增或修改配置后重启服务加载。

先备份数据库和原 `.env`，再在部署主机的私有环境中配置随机 `NIO_CONFIG_MASTER_KEY`。通过标准输入导入原有 `KEY=value` 文件或同字段的 JSON，不要把凭据写到命令行参数：

```bash
./nio-swap-history-backend upsert-tenant default < /private/path/current-account.env
./nio-swap-history-backend upsert-tenant second_account < /private/path/second-account.env
./nio-swap-history-backend validate-tenants
```

输入必须包含 `API_KEY`、`NIO_BEARER_TOKEN`、`NIO_VEHICLE_ID`、`NIO_DEVICE_ID`、`NIO_APP_ID`、`NIO_APP_VERSION`、`NIO_REGION` 和 `NIO_LANGUAGE`。可选的账户、站点与服务订单配置也按租户加密保存。导入 `default` 后，先用 `validate-tenants` 和原账号接口验证，再从 `.env` 移除已迁入的 API key 与 NIO 凭据；`DATABASE_URL`、`BIND_ADDR` 和主密钥继续留在私有环境。启用租户模式后，`status`、换电列表和详情也要求 API key；`healthz` 仍可用于健康检查。

短信登录成功后，新 access/refresh token 会加密保存到该租户配置，响应中的 `backend_config_saved` 表示是否写入成功。现有业务客户端在进程启动时建立，需重启后才会使用新 access token。第二租户的车控和真实换电下单默认禁用，避免复用默认租户的证书、PIN 和车控密钥；这些能力需要单独完成租户级凭据隔离后才能启用。

### OpenAPI JSON

`openapi.json` 是可导入的 OpenAPI 3.1 文档，覆盖全部 HTTP 路由。接口、字段、单位、
鉴权、错误码及副作用说明均写在 `description` 中，文件保持严格 JSON 格式。

```bash
cd backend
cargo run --locked -- export-openapi
# 可选：cargo run --locked -- export-openapi /absolute/path/nio-openapi.json
```

导出命令在加载 `.env`、数据库或后台监控之前执行，不需要凭证，也不发送上游请求。
接口修改后重新导出；`cargo test --locked` 会检查路由/方法、模型字段、引用、操作 ID、
公开接口及车控双密钥契约，并校验导出文件与当前生成器一致。

`GET /healthz`、`GET /api/v1/status` 和两个换电历史查询保留现有公开只读行为。
其余接口在配置 `API_KEY` 后使用 Bearer 或 `X-API-Key`；车控另需
`X-Vehicle-Control-Key`；真实换电下单复用同一个车控 Key。导入订单、手动轮询、
车控和换电下单具有副作用，文档中分别标注。

### 一键换电下单（默认关闭）

`POST /api/v1/swap-orders` 是唯一对 App 暴露的下单入口。客户端只提交换电站 ID 与精确
确认文字；后端依次执行：查询并解密站点详情、从 `location`（经度,纬度）解析坐标、发送一次
`/swap/scan`、再发送一次真实 `/swap` 下单。车辆 ID、车型、年款、电池档位和坐标均由后端
取得，客户端额外提交这些字段会因 `deny_unknown_fields` 被拒绝。任何上游请求都不会自动重试。

```http
POST /api/v1/swap-orders
Authorization: Bearer <API_KEY>
X-Vehicle-Control-Key: <NIO_CONTROL_API_KEY>
Content-Type: application/json

{
  "station_id": "PS-NIO-3606da31-f8539ae9",
  "confirmation": "CREATE SWAP ORDER"
}
```

只有车控运行时、车辆会话和 `STATION_URL_TEMPLATE` 均已配置时接口才启用。下单与车控使用相同的
`NIO_CONTROL_API_KEY` / `X-Vehicle-Control-Key`，仍需同时提供普通 `API_KEY`。

### 本地优先的换电站名称搜索

`GET /api/v1/stations/search?name=红星美凯龙滨海` 先搜索本地 `swap_stations`；只有本地无结果时
才调用蔚来地图。后端只保留远端 `recharge` 分类中 `sub_type=PowerSwap` 且 ID 为 `PS-NIO-*`
的结果，并把名称、ID、地址和经纬度幂等写回本地。响应 `source` 为 `local` 或 `remote`。

### 周边地图查询与到站粗估

`POST /api/v1/stations/nearby` 接收 JSON `latitude` 和 `longitude`，调用 NIO CN 只读地图
`around/recall` 接口并只返回换电站图钉，附地理直线距离。结果来自固定地图视窗，不能当作指定
半径内的完整站点名单。查询坐标不会出现在响应中。此接口也以 `nio_nearby_swap_stations`
暴露给 MCP；`/swap/scan` 属于可能创建订单的换电流程，不用于周边搜索。

`GET /api/v1/stations/{id}/live` 返回完整分时费率、当前费率及站点说明；队列与电池就绪
数据保留上游可验证字段，未知值返回 `null`，充电倒计时不保证到站可换。
`GET /api/v1/stations/nearest` 读取一次车辆定位，经地图接口找到直线距离最近的换电站，再返回与
`/live` 相同的实时数据，并附 `straight_line_distance_km`；车辆坐标不出现在响应中。
`POST /api/v1/stations/{id}/straight-line-energy` 用请求坐标和站点坐标算地理直线距离，
能耗仅读取后台每日持久化的最近累计 100 公里行程结果，不在本次请求中拉取行程或写库。
已知目录站点优先使用目录坐标；周边地图新发现但目录尚无的站点，可将地图结果的
`latitude`/`longitude` 作为 `station_latitude`/`station_longitude` 成对传入。
服务端校验站点 ID 与坐标范围，但不独立证明调用方坐标确实属于该站点；响应标明坐标来源。
查询坐标不回显，站点目录也不会因试算被隐式写入。

后台默认每天北京时间 **03:00** 计算一次（可用 `NIO_TRIP_ENERGY_TIME=HH:MM` 调整）。
启动晚于当日计划时间时只尝试当日，不补算历史日期；PostgreSQL 的每日唯一记录防止多实例
重复执行。行程按结束时间从新到旧累计 100 公里；若最后一段行程仅取部分里程，其能耗按
整段平均比例折算，并用 `boundary_method=proportional_from_trip_average` 标记，绝非分段实测。
缺能耗行程保留在最近 100 公里时间窗口中，单独报告缺口，不按零能耗处理，也不拿更旧行程
悄悄补足。不足 100 公里返回实际覆盖里程和 `insufficient_distance`；后台最多读取 10 页、200 条行程，达到安全上限则返回
`query_limit_reached`。计算失败保留最后一次成功结果，并标明 `last_attempt_failed`/`stale`；
首次尚无结果时 `energy_cache.summary` 与估算电量均为 `null`。
道路距离、路况、通行费均不在结果中。工具只提供数据和计算依据，不自动选择站点。
本地命中只需要普通 `API_KEY`；远端兜底还要求已配置 NIO 车辆会话。

迁移 `0011_swap_station_coordinates.sql` 为站点目录增加可空的 `latitude`、`longitude`。
服务启动且已配置 `STATION_URL_TEMPLATE` 时，会顺序查询所有缺坐标的存量站点并补全；单站失败不会
中断其他站点，下一次启动会继续处理仍缺坐标的记录。

### 车辆控制（默认关闭）

Rust 后端的 `POST /api/v1/vehicle/action` 只在车控密钥、已有 TLS 客户端身份、服务端 CA 和车辆会话全部配置后启用；不会自动签发证书、复制本地 Python 凭据或刷新过期 Token。调用时既需普通 `API_KEY`（如已配置），还需 `X-Vehicle-Control-Key`。默认要求车控密钥独立；只有显式设置 `NIO_CONTROL_ALLOW_SHARED_API_KEY=true`，才允许 `NIO_CONTROL_API_KEY` 与普通 `API_KEY` 相同。复用时，所有持有普通 API key 的客户端也具有车控授权，属于权限扩大。部署在非本机时必须使用 HTTPS 反向代理或受控的加密专用网络，不要把密钥放进 URL、日志或 shell 历史。解锁所需 PIN 从 `NIO_CONTROL_PIN_FILE` 读取，不接受请求体中的 PIN；未配置时其他无 PIN 动作仍可使用，解锁返回配置不可用。

Rust 版的 `verify-bootstrap` 对应 Python 的 TLS-only 诊断；必须显式传
`--live`，但只执行客户端认证 TLS 握手，不发送 HTTP、Token 或 PIN：

`icar.nio.com:4430` 当前叶证书缺少 SAN；Rust 只对固定的该叶证书指纹兼容这一点，同时仍验证服务端 CA 链、有效期、serverAuth 和 TLS 握手签名。其他叶证书或主机名不会绕过校验。

```bash
cd backend
cargo run --release -- verify-bootstrap --live \
  --bootstrap-cert /absolute/bootstrap/client_certificate.pem \
  --bootstrap-key /absolute/owner-only/bootstrap/private.pem \
  --server-ca /absolute/bootstrap/trust_chain.pem
```

如需独立获取 TLS 客户端身份，可在受控终端手动运行 Rust 命令行签发器。它不属于 HTTP API，也不会在服务启动或车控请求期间自动运行：

```bash
cd backend
cargo run --release -- issue-identity --live \
  --output-dir /absolute/new/identity-directory \
  --bootstrap-cert /absolute/bootstrap/client_certificate.pem \
  --bootstrap-key /absolute/owner-only/bootstrap/private.pem \
  --server-ca /absolute/bootstrap/trust_chain.pem
```

`NIO_CONTROL_PIN_FILE` 所指文件只包含 `NIO_VEHICLE_ID=...` 与 `PIN=...`，权限须为 0600；也可在命令中用 `--pin-file` 显式覆盖此路径。bootstrap 私钥须仅所有者可读写。程序要求目标目录不存在并再次键入 `ISSUE TLS CERTIFICATE`，先核对服务端 TLS 链及固定叶证书指纹，然后获取新的 PIN 加密公钥、在本地生成 P-256 私钥。**发送唯一一次签发 POST 之前，先把本地私钥保存在新建的 0700 目录中。** 请求或后续写入失败时保留私钥与 `issuance-pending.json`，不可直接自动重试；证书与本地公钥匹配、且响应没有非空服务端私钥后才写入最终证书和元数据，并进行只读 mTLS 车辆状态核验。不会申请 digital-key 证书，也不会发送车控指令。保存后的 `tls-certificate.pem`、`tls-private-key.pem` 可分别配置给 `NIO_CONTROL_TLS_CERT_PATH`、`NIO_CONTROL_TLS_KEY_PATH`；`NIO_CONTROL_CA_PATH` 使用同一服务端 CA bundle。

这条 Rust 签发路径目前只通过离线测试，未在生产环境执行；此前的生产通过证据来自独立 Python 客户端，不能直接当作 Rust 路径验收。

与 Python 的能力对应关系：Rust 的手动签发命令对应其 TLS-only 签发，`verify-bootstrap` 对应无 HTTP 的引导身份核验，车控 HTTP API 覆盖 Python `vehicle-action` 的已实现动作；Python 的 `guard-existing` 与 `unlock-existing` 是其中两个动作的便捷入口。Rust 不导入 Surge 登录抓包或 PKCS#12，引导身份目前要求 PEM 证书/私钥。Python 的 digital-key 分支尚未闭环，因此 Rust 不开放该分支；两端均未实现座椅加热开启、座椅通风和 Token 自动刷新。

请求体以 `action` 选择 `unlock-doors`、`unlock-start`、`lock`、`guard-on`、`guard-off`、`mirror-expand`、`find`、`find-stop`、`ac-on`、`ac-off`、`seat-heat-off`。`confirmation` 必须是对应动作的完整大写短语，例如空调开启为 `START AC`；`ac-on` 可加 `temperature`（16–30）与 `recirculation`（0 或 1）。PIN 不属于请求字段，也不写入后端数据库。`unlock-start` 可能允许车辆启动，与仅开门不同。守卫模式可选 `expand_mirrors: true`，但还必须额外提供 `mirror_confirmation: "EXPAND MIRRORS"`，这可能产生第二条独立车控指令。

仅解锁车门的请求体为 `{"action":"unlock-doors","confirmation":"UNLOCK DOORS"}`；不要传 `pin` 字段，额外字段会被拒绝。请求仍须同时携带 `X-API-Key` 与 `X-Vehicle-Control-Key`；在显式启用共享密钥的部署中，两者使用同一个值。此动作保留 E2E 类型核验，从 0600 PIN 文件读取 PIN、获取新的加密公钥并只发送一次上游命令；不再在客户端查询 P 挡、四门或已有锁状态，也不等待解锁后的状态更新。上游接受时返回 `status: "accepted_unverified"`、`verified: false`，并不证明车门已解锁；响应不确定时不可直接重试。蔚来 ET5 Touring 手册仍要求 App 远程解锁时车辆挂 P 挡且四门关闭；上游是否独立强制这些条件尚未验证，操作者必须现场确认。程序不会自动重新上锁。

当前实现不读取 `NIO_CONTROL_ALLOW_UNVERIFIED_ACTIONS`。配置启用车控后，服务端按动作确认文字、PIN、TLS 身份与状态检查处理上述已实现动作；静态/离线实现不代表每个动作都已完成实车验收。

车控 HTTP 客户端复用连接，并在每次新 TLS 握手时验证服务端 CA 链及固定叶证书指纹，不为每个动作额外建立重复的预检连接。`unlock-doors` 只查询 E2E 类型，不查询 P 挡/车门、不做状态轮询；`lock` 和 `unlock-start` 仍并行核验 E2E、P 挡和车门状态，其他动作保留既有检查。PIN 公钥按次获取（有效期与跨动作复用规则未经验证），车控 POST 不自动重试。需要验证的动作在 POST 后立即检查目标状态，未达到时前三次间隔 1 秒、之后间隔 3 秒，最多检查到约 45 秒。成功动作在服务日志记录 `queue_ms`、`safety_ms`、`pin_ms`、`command_ms`、`verify_ms`、`total_ms`；只对确实完成状态轮询的动作记录 `command_to_verified_ms`，不记录 PIN、Token、VIN 或响应体。`GET /api/v1/vehicle/status` 是独立只读状态接口，向上游请求 `door` 字段；App 后续可单独调用以观察锁状态，但当前 Swift 状态模型尚未解码该字段，需要另行接入，且不得把命令接受等同于已解锁。寻车、后视镜、座椅加热关闭也只能报告上游接受；`unlock-start` 的门锁状态不能证明防启动锁或可行驶状态。

配置 `SERVICE_ORDER_URL` 后，后端以通用的 `ServiceOrderProvider` 调用
`serviceOrder/getTabOrder`。它会强制把查询参数改为
`orderTypes=pe_shaman_change`，进行中订单使用 `inProgressStatus=true`，历史订单使用
`inProgressStatus=false`，再在响应内复核 `orderType`，并在订单携带
`vehicleId` / `vinCode` 时与本车配置比对。也兼容 NIO-Dash 的
`NIO_CHANGE_API_URL`、`NIO_CHANGE_ACCESS_TOKEN`、`NIO_CHANGE_API_HEADERS`、
`NIO_CHANGE_COOKIE` 变量名。

首次看到订单或目标站变化时，订单会先持久化到 `service_orders`。只有订单中的站点 ID 或规范化后的
站名与当前 `STATION_KEY` / `STATION_NAME` 相符，才抓取站点基线；抓取失败会在下一轮重试。若配置了
`STATION_URL_TEMPLATE`，后端会在进行中订单的任意层级查找格式为 `PS-NIO-*` 的站点 ID，替换模板中的
`{station_id}` 后直接抓取目标站，无需预先配置固定站点。模板还支持 `{vehicle_id}`、`{device_id}`、
`{app_id}`、`{app_version}`、`{region}`、`{language}`，这些值在启动时由车辆配置填入。订单只负责
提供“本车可能即将去哪个站”的证据，不会因此直接生成 `confirmed` 换电记录，也不会猜测分配电池。
进行中订单每轮都会调用官方订单详情，以刷新换电号和目标电池档位，并调用官方订单状态
`GET /app/api/pe/v1/swap/order/{orderId}/status`。订单状态中的 `waiting_count` 是本车前方排队数，
`swap_wait_expected_time` 是官方预计等待分钟数，`swap_number` 是换电号；加密的 `data` 会按官方响应
协议解密后再解析。站点详情中的 `estimated_wait_in_line` 表示“到站预计排队数”，不是分钟数，不会再
作为等待时间使用。订单详情返回有效 `resource_id` 后会回写进行中订单、站点目录和动态目标站，再抓取
换电前基线。详情暂未返回站点 ID 或请求失败时不会阻断订单监控，并会在下一轮重试。动态目标站同时按
目标电池档位读取 `wait_in_line`，作为官方订单状态暂不可用时的排队数回退。官方分钟数存在时
`estimated_wait_source=swap_order_status`；缺失时才按每辆约 5 分钟估算并标记为
`station_queue_estimate`，避免将估算值冒充官方数据。
动态目标站会共享给车辆换电状态监控：进入、换电中、退出以及退出后的复查均继续查询同一站点；订单
不再出现后最多保留两小时，避免后续换电误用过期目标站。

历史订单在启动后立即同步，此后每 10 分钟同步一次。只有状态码为 `100` / `1000`，或状态名称明确
包含“完成”/“已支付”的换电订单才写入 `confirmed` 记录。服务订单列表已不再返回 `extendInfo`，
因此记录时间优先采用订单详情的 `finish_time`（缺失时才回退到 `createTime`），金额采用详情结算后的
`actual_price`（优惠前 `priceCash` 仅在详情缺失时使用）。费用明细由详情分别生成电费（`origin_electricity_price`）、
服务费（`origin_service_price`）和优惠券（`coupon_info.deducted_*_fee`，单位分，记为负数），三项之和等于
`actual_price`，实付金额仍保存在 `price_amount`。配置车辆凭据后，服务端还会调用官方订单详情
`GET https://app.nio.com/app/api/pe/v1/swap/order/{orderId}`，将 `data.energy` 作为精确换得电量保存到
`exact_energy_kwh`；每轮最多回填 20 笔缺失记录，失败会在后续轮询重试，不会用价格或 SOC 猜造。
同一详情中的 `resource_id` 与 `resource_name` 会幂等写入 `swap_stations` 站点目录，并同步回换电记录的
`station_key` / `station_name`；同时保留运营方和已知地址。站点地址来自站点详情接口的 `address` 字段（如
“红星美凯龙(云山道店)”）：轮询到站点时写入目录，启动时对缺失坐标或地址的目录站点做一次回填，
并把目录地址补到仍为空的换电记录上。后续历史同步会复用已保存的 `orderDetail`，
因此重启后可以重建站点目录，而不必为已有详情重复请求上游。
历史订单仍没有稳定的电池编号字段。进行中订单的基线后若连续两次唯一少了
同一块电池，会先把它作为“换上”证据保存，不再因“换下”电池尚未入仓而丢弃。
后续若出现新增电池，会用换电前车辆 SOC 辅助唯一匹配并补全“换下”；两侧齐全后才会计算估算电量。

当车辆从非换电状态进入 `special_status.swapping` 后，后端会立即保存站点快照，换电过程中按
锁车时每 20 秒、未锁车时每 3 秒持续检查（均可配置），退出换电状态后再按 `POST_SWAP_POLL_COUNT` 复查。
近实时导入的订单也会触发一次站点快照。移出站点的电池视为换入车辆，新增到站点的电池视为车辆换下。
进行中订单的部分候选会保留已经稳定观测到的一侧；最近 15 分钟内已记录换电起始 SOC 的订单即使刚离开 active 列表，
仍可在退出换电后的复查期间补全另一侧。只有订单或明确的车辆分配
证据能够归属到本车时才应确认；`battery_occupied` 本身不能证明是哪个车牌。

## HTTP API

### 前台变化通知（SSE）

默认租户订阅 `GET /api/v1/events`；其他租户订阅 `GET /t/{tenant}/api/v1/events`。使用该租户的 `X-API-Key` 或 `Authorization: Bearer` 鉴权。连接建立时发送 `ready`，App 随即通过现有 REST 接口刷新 dashboard 和 `/api/v1/orders/active`。后续 `vehicle_changed`、`active_orders_changed` 只提示对应数据变化，事件体不含完整车辆或订单信息。每个租户有独立的 PostgreSQL 事件表、连续增长的事件 ID 和最多 256 条重放窗口。采集失败不发送变化事件。

```text
id: 42
event: ready
retry: 3000
data: {"schema_version":1,"occurred_at":"2026-11-05T00:00:00Z","revision":42,"reason":"initial_connect"}

id: 43
event: vehicle_changed
retry: 3000
data: {"schema_version":1,"occurred_at":"2026-11-05T00:00:03Z","revision":43,"reason":"vehicle_status_changed"}

: heartbeat

```

断线重连时发送 `Last-Event-ID: 43`。游标仍在保留窗口内会按 ID 补发缺失业务事件；游标过旧、未知或订阅者落后时发送 `resync`（`reason` 为 `cursor_unavailable`、`consumer_lag` 或 `event_gap`），App 应合并防抖后全量刷新。`ready` 和 `resync` 的 `id` 表示当前游标，业务事件的 `id` 为租户内递增整数。心跳是每 15 秒一条 SSE comment，不能触发 REST 刷新。响应使用 `text/event-stream`、`Cache-Control: no-cache`、`Connection: keep-alive` 和 `X-Accel-Buffering: no`。反向代理需关闭响应缓冲，并设置至少 75 秒的读取超时。

App 在前台只维持一条 SSE 连接，切到后台或主动退出时取消旧连接。按 ID 去重并按序处理；遇到缺口、`ready` 或 `resync` 时，合并多次触发为一次全量 REST 刷新。`vehicle_changed` 刷新车辆 dashboard，`active_orders_changed` 刷新进行中订单。网络断开、429、5xx 或超时可用带 jitter 的指数退避重连（1 秒、2 秒、4 秒，最高 30 秒）；稳定连接后重置退避。401/403 应等待凭证刷新或重新取得后再连，避免无限重试。服务端 `retry: 3000` 是基础建议值。重连携带最后**已处理**事件 ID；不要把心跳当作新游标。

只读接口：

- `GET /healthz`
- `GET /api/v1/status`
- `GET /api/v1/swaps?limit=50&offset=0`
- `GET /api/v1/swaps?include_candidates=true`
- `GET /api/v1/swaps/{id}`

写接口需要 `Authorization: Bearer $API_KEY` 或 `X-API-Key: $API_KEY`：

- `POST /api/v1/poll`：立即轮询一次站点；
- `POST /api/v1/orders/import`：幂等导入订单，并尝试与前后 30 分钟内的候选记录合并。

以下车辆接口会返回私有车辆信息，即使是 GET 也必须提供同一个后端 `API_KEY`：

- `GET /api/v1/orders/active`：返回上游当前仍列为进行中的换电订单，以及换电号、前方车辆数、预计等待时间和数据更新时间；订单从进行中列表消失后自动移除；
- `GET /api/v1/vehicle/status`：实时车辆状态，并把有效位置写入采样历史；电池和充电信息由 `field=soc` 返回在 `soc_status`；
- `GET /api/v1/vehicle/widget-info`：Widget 综合信息。当前版本的电池电量、续航、充电功率/电压/电流和充电上限位于 `data.status.soc_status`，不是独立的 `battery_status`；
- `GET /api/v1/vehicle/profile`：车辆身份与图片地址。启动后后台会调用一次上游 `GET /app/api/icar/v2/switch/cars`（带 `device_id`、`app_id`、`app_ver`、`region`、`lang` 和签名），按 `NIO_VEHICLE_ID` 选中对应车辆（单车账号无匹配 ID 时直接取唯一一辆，多车账号必须精确匹配），把显示名、车型、颜色、`image` 地址写入当前租户 schema 的 `vehicle_profile` 表，并**下载图片字节一起入库**。图片按上游 URL 缓存：**URL 不变就一直复用已存字节，不再重复下载**；只有 URL 变化或本地缺字节时才重新下载。不按天轮询，变更在下一次启动（或按需补拉）时生效。启动失败按 5 分钟重试。接口返回 `image_available` 表示字节是否已缓存，读取时若还没有记录会同步补拉一次，仍失败返回 `404 vehicle_profile_not_found`。
- `GET /api/v1/vehicle/image`：返回数据库中缓存的车辆图片字节，`Content-Type` 取自上游响应（PNG/JPEG，单张上限 4 MiB），响应带 `Cache-Control: public, max-age=86400` 与 `ETag`（图片 sha256），`If-None-Match` 命中返回 `304`——客户端可以一直用到 URL 变化为止。图片未缓存时返回 `404 vehicle_image_not_found`。这样客户端只依赖后端，不必访问 NIO CDN。
  多租户下每个租户独立拉取、独立存表（`public` / `tenant_<slug>`），图片和画像互不影响；图片刷新失败时保留上一次缓存，不会把已有图片清空。
- `GET /api/v1/vehicle/history?limit=2000`：后端轮询形成的位置采样，仅用于当前位置回退和采样轨迹；
- `GET /api/v1/vehicle/charging/current`：最近一次连续充电会话的后端采样，包含 SOC、电压、电流和功率；充电中即使车辆已锁也按快速间隔采集。响应中的 `energy_kwh` 按相邻功率采样做梯形积分，充电中每次请求实时计算；
- `GET /api/v1/vehicle/charging/sessions?limit=50`：按时间倒序返回充电会话摘要；连续采样间隔超过 15 分钟时拆分为下一次充电；
- `GET /api/v1/vehicle/charging/sessions/{id}`：返回指定充电会话的完整曲线点位和积分电量。检测到充电结束时将电量写入 `vehicle_charging_session_energy`；历史会话缺少电量时，详情请求会重新积分并回写；
- `GET /api/v1/vehicle/trips?count=20`：立即按时间倒序返回数据库中已保存的行程，不等待蔚来；每次读取会排队触发一次异步同步，并发请求合并，需再次查询才能看到更新。首次回填尚未完成时可能返回空页或部分历史。包含起止时间、地点、里程、时长、驾驶统计及上游详情中的 `trip_eng` 耗电量。列表 `distance` 为整公里；若详情的 `start_odo`/`end_odo` 差值有效且落在同一整公里区间，则用该差值保留小数，否则仍用列表值。百公里能耗按实际 `trip_eng / distance × 100` 计算，不凭 SOC 或电池容量估算。可用 `query_time`（Unix 秒、不含）向前分页，响应中的 `next_query_time` 是下一页游标。同一秒内的行程不拆页，因此结果可能略超 `count`。数据库响应的 `server_time` 为 null。
  每条行程返回 `maximum_speed_kph`、`odometer_kilometers`、`rapid_acceleration_count`、`rapid_deceleration_count` 和 `rapid_swerve_count`；优先使用列表值，缺失时尝试使用详情中的对应字段，累计里程还可使用详情的 `end_odo`。上游未提供有效数据时返回 `null`，不会默认填零。
  同一轮详情请求里的 `track` 会写入 `vehicle_trip_tracks`，见下面的轨迹接口。

- `GET /api/v1/vehicle/trips/{journey_id}/track`：按采样时间升序返回该行程已保存的官方 GPS 轨迹点，每点包含 `sampled_at`、`latitude`、`longitude`、`speed_kph`、`power_consumption` 和 `np_status`，数值按上游原样保存。数据来自上游行程详情的 `track`（约每 10 秒一个采样点），不插值、不平滑，也不与其他行程拼接。坐标非法或缺少时间戳的点直接丢弃，不猜测补齐；上游返回空 `track` 的行程（例如极短行程）没有轨迹，接口返回 `404 trip_track_not_found`。`journey_id` 只接受 ASCII 字母、数字、连字符和下划线，最长 128 字节。轨迹只在行程点数变化时重写：未结束的行程会随点数增加而更新，稳定状态下不会重复写已有采样点。

  升级到带轨迹的版本后，已经入库的历史行程**不会**自动补轨迹：`vehicle_trip_sync.backfill_completed` 为真时同步只拉最新 10 条，老行程的详情不会再被请求。一次性补全用：

```bash
cargo run --locked -- backfill-tracks --dry-run      # 先看待补数量，不请求上游
cargo run --locked -- backfill-tracks                # 全部补齐
cargo run --locked -- backfill-tracks --limit 500    # 只补最新 500 条，可反复执行
cargo run --locked -- backfill-tracks --tenant alice # 多租户时只处理指定租户
cargo run --locked -- backfill-tracks --concurrency 20  # 上游限流时降低并发
```

  命令按 `started_at` 从新到旧分批请求详情：默认每批 100 个并发请求，整批返回后在一个事务里写库，批次之间暂停 200 ms；`--concurrency` 取值 1…256。每批打印耗时、`stored/empty/failed`，结尾给出总耗时。写入 `vehicle_trip_tracks` 并把 `vehicle_trips.track_scanned_at` 置为当前时间。按上游实测每趟约 165 点，3000 趟约 50 万点。上游返回空 `track` 的行程会被标记为已扫描，重复执行不会再次请求；请求失败的不做标记，重跑即可重试，结尾会报出失败条数并以非零退出。多租户模式下自动遍历已配置租户，只处理有车辆凭据的。

  独立后台同步将获取到的行程按车辆 ID 和行程 ID 写入 `vehicle_trips` 表；每日能耗计算只计算能耗缓存，不再重复写行程。重复获取时更新记录，缺失的可选字段不会覆盖已有值，详情获取失败时整数公里不会覆盖已保存的小数公里。启动后以每页 20 条分页回填上游可用历史，游标写入 `vehicle_trip_sync`，失败/重启后从检查点继续；每轮最多五页、页间暂停两秒。回填期间每分钟继续下一轮并从最新页追赶新增行程，回填结束后每五分钟先拉最新 10 条；若尚未覆盖上次完整同步时间之前的已存行程，则继续按每页 20 条补齐（即使 App 已写入最新一页也不会提前停止）。若上游分页游标不前进，同步会保留检查点并重试、记录警告，而不会跳过数据；上游不再提供的旧行程无法回填。

以下站点目录接口也必须提供同一个后端 `API_KEY`：

- `GET /api/v1/stations?limit=100&offset=0&q=滨海`：按站点 ID、名称、地址或运营方搜索，结果按最近一次换电时间倒序返回；`q` 可省略；
- `GET /api/v1/stations/search?name=红星美凯龙滨海`：先查本地目录，本地无结果时才远端搜索，并把换电站名称、ID、地址和经纬度写回本地；
- `GET /api/v1/stations/{station_id}`：按站点 ID 查询单个映射，未收录时返回 `404 station_not_found`。
- `GET /api/v1/stations/{station_id}/live`：使用后端站点请求模板实时返回当前费率和 75 kWh 可用电池数量；可用口径与 App 一致，为未占用且 SOC 不低于 92%。新版上游不再返回电池 ID，容量优先按 `battery_cap_series` 判断：`0=70 kWh`、`3=75 kWh`、`2=400V 100 kWh`、`8=102 kWh`；描述明确写着 102 kWh 时以描述为准。生产日期仅在旧版响应仍带电池 ID 时可解析。

`history` 与 `trips` 的语义严格分离：GPS 采样点不会被拼装成历史行程，采样点之间的距离也不会冒充官方行程里程。

订单导入示例：

```bash
curl -X POST http://127.0.0.1:8080/api/v1/orders/import \
  -H "Authorization: Bearer $API_KEY" \
  -H 'Content-Type: application/json' \
  --data '{
    "order_no": "example-order-001",
    "occurred_at": "2026-10-09T12:30:00+08:00",
    "station_key": "my-station",
    "station_name": "常用换电站",
    "energy_kwh": 55.2,
    "outgoing_battery": {
      "battery_id": "outgoing-id",
      "production_date": "2021-04-08",
      "capacity_kwh": 75,
      "soc_percent": 18
    },
    "incoming_battery": {
      "battery_id": "incoming-id",
      "production_date": "2024-03-28",
      "capacity_kwh": 100,
      "soc_percent": 93
    }
  }'
```

旧版响应的生产日期会从站点电池编号的第 11–15 位解析：前三位是年内日序，后两位是年份，例如
`08824` 转换为 `2024-03-28`。新版响应不再返回电池 ID，因此生产日期为空；无效日序同样保留为空，
不会制造日期。

## 当前证据边界

站点清单差分可以发现一次站级电池交换，却不能单独证明它属于哪个用户；精确换电量也不能从站点清单
可靠得到。因此默认列表只返回 `confirmed` 订单，候选记录需要显式传 `include_candidates=true`。
历史服务订单可以确认本车的换电时间、地点、订单状态和价格；进行中订单用于提前抓站点基线。但当前
参考响应没有稳定的“分配给本车的电池编号”或精确换电量字段，所以电池编号只在订单与库存差分能够
唯一匹配时展示，电量也会明确区分订单值与站点估算值。

## 验证

### 整理与性能边界

- iOS 连接配置切换会使旧请求失效；同一轮刷新共享任务，各数据区独立更新，单项失败不丢弃已成功的数据。
- 车辆轨迹在历史响应更新时构建，日期解析器复用并保护并发访问；充电曲线选择使用有序样本查找。
- 后端轮询使用取消安全的进度标志；实时站点请求复用 HTTP 客户端连接，不缓存实时电池库存。
- PostgreSQL 的 `0009_query_indexes` 和 `0013_charging_time_index` 只增加查询索引，不修改历史行或订单确认规则。
- 车控仍需独立密钥和人工确认，不自动重发；调试设计预览使用隔离示例数据，拒绝车控与设置保存。
- OpenAPI 导出不加载配置或凭证，也不启动数据库、监控和车辆请求。JSON 的说明使用标准 `description` 字段，而非非法 JSON 注释。

```bash
cargo fmt -- --check
cargo test
cargo clippy --all-targets -- -D warnings
```
