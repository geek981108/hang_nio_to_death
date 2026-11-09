//! Offline API-contract export. It never loads credentials, starts monitors,
//! opens a database, or sends an upstream/vehicle request.
//!
//! JSON uses `description` for human-readable comments. Models and operations
//! are kept explicit because vehicle/widget responses pass through upstream
//! JSON while the history and order endpoints have stable Rust models.

use std::path::Path;

use serde_json::{Map, Value, json};

use crate::vehicle_control::VehicleAction;

pub fn export(path: &Path) -> Result<(), Box<dyn std::error::Error>> {
    let mut output = serde_json::to_string_pretty(&document())?;
    output.push('\n');
    std::fs::write(path, output)?;
    Ok(())
}

pub fn document() -> Value {
    let mut paths = Map::new();
    let mut add = |path: &str, method: &str, operation: Value| {
        paths.insert(path.to_owned(), json!({method: operation}));
    };
    add(
        "/healthz",
        "get",
        operation(
            "health",
            "健康检查",
            "只确认 HTTP 服务可响应，不代表上游凭证、车控或数据同步已就绪。",
            "服务",
            "HealthResponse",
            false,
        ),
    );
    add(
        "/api/v1/status",
        "get",
        operation(
            "serviceStatus",
            "服务配置与轮询状态",
            "返回配置标志、轮询状态与本地数据库计数。原有单租户模式公开；PostgreSQL 多租户模式要求租户 API key。",
            "服务",
            "ServiceStatus",
            false,
        ),
    );
    let mut events = operation(
        "subscribeEvents",
        "订阅租户车辆与进行中订单变化",
        "只读 SSE。首次连接发送 ready；Last-Event-ID 在最近 256 条窗口内按序补发，否则发送 resync。车辆与订单事件仅在规范化状态变化时发送；15 秒 comment heartbeat 不触发刷新。每租户独立事件表和广播通道。App 应在 ready/resync 后合并防抖地刷新 dashboard 和 active orders；业务事件按 id 去重并刷新对应 REST 接口。断线重连使用 Last-Event-ID，401/403 等待凭证更新，429/5xx/超时使用带 jitter 的指数退避（1s、2s、4s，最高 30s）。前台只保持一条连接，进入后台取消连接。",
        "服务",
        "Error",
        true,
    );
    events["parameters"] = json!([{"name":"Last-Event-ID","in":"header","required":false,"schema":{"type":"string"},"description":"上次已处理的业务事件 id；省略时发送 ready。"}]);
    events["responses"]["200"] = json!({"description":"SSE stream；retry: 3000，id 为租户内递增整数；响应头含 no-cache 和 X-Accel-Buffering: no。","content":{"text/event-stream":{"schema":{"type":"string"},"examples":{"ready":{"value":"id: 42\nevent: ready\nretry: 3000\ndata: {\"schema_version\":1,\"revision\":42,\"reason\":\"initial_connect\",\"occurred_at\":\"2026-11-05T00:00:00Z\"}\n\n"},"changed":{"value":"id: 43\nevent: vehicle_changed\nretry: 3000\ndata: {\"schema_version\":1,\"revision\":43,\"reason\":\"vehicle_status_changed\",\"occurred_at\":\"2026-11-05T00:00:03Z\"}\n\n"},"resync":{"value":"id: 43\nevent: resync\nretry: 3000\ndata: {\"schema_version\":1,\"revision\":43,\"reason\":\"cursor_unavailable\",\"occurred_at\":\"2026-11-05T00:01:00Z\"}\n\n"}}}}});
    add("/api/v1/events", "get", events);

    let mut sms = operation(
        "sendNioLoginSms",
        "发送 NIO 登录验证码",
        "需配置 API_KEY 与 32 位 NIO_DEVICE_ID；每次调用只向 NIO 发送一条短信请求。进程内只保留一个挑战，600 秒有效；不自动重试。上游请求不带 Black-Box。",
        "账户",
        "NioSmsChallenge",
        true,
    );
    sms["requestBody"] = request_body("NioSmsInput", "中国大陆 11 位手机号；只用于本次上游请求。");
    error(&mut sms, "400", "手机号无效。");
    error(&mut sms, "502", "NIO 拒绝请求或上游不可用。");
    error(&mut sms, "503", "缺少 API_KEY 或 NIO_DEVICE_ID。");
    add("/api/v1/auth/sms", "post", sms);
    let mut login = operation(
        "loginWithNioSms",
        "提交 NIO 短信验证码",
        "挑战在发送上游请求前即消费；请求结果不明时也不重试。成功响应含敏感 token，Cache-Control: no-store。租户模式加密回写 PostgreSQL，需重启后供现有业务客户端使用。",
        "账户",
        "NioLoginResult",
        true,
    );
    login["requestBody"] = request_body(
        "NioLoginInput",
        "使用最近一条短信请求的 challenge_id 与 6 位验证码。",
    );
    error(&mut login, "400", "验证码或挑战无效、过期、已使用。");
    error(&mut login, "502", "NIO 拒绝登录或上游不可用。");
    error(&mut login, "503", "缺少 API_KEY 或 NIO_DEVICE_ID。");
    add("/api/v1/auth/login", "post", login);

    let mut swaps = operation(
        "listSwaps",
        "换电历史",
        "默认只返回 confirmed 记录；include_candidates=true 时包含站点观察候选。多租户模式要求租户 API key。",
        "换电与订单",
        "SwapEventPage",
        false,
    );
    swaps["parameters"] = json!([
        integer_query(
            "limit",
            50,
            1,
            200,
            "每页条数；服务端会将越界数值夹到 1…200。"
        ),
        offset_query(),
        query(
            "include_candidates",
            json!({"type":"boolean", "default":false}),
            "是否包含未由订单确认的候选记录。"
        )
    ]);
    query_errors(&mut swaps);
    add("/api/v1/swaps", "get", swaps);
    let mut stats = operation(
        "energyStats",
        "换电与充电区间统计",
        "按 [from,to) 统计已确认换电；当月换电次数按北京时间自然月单独统计。费用和换电电量仅汇总已知数据并附覆盖条数；充电电量优先由相邻功率采样积分，缺功率时用最近一次换上电池容量乘 SOC 增量估算；超过 15 分钟的采样间隔不推算。",
        "换电与订单",
        "EnergyStats",
        true,
    );
    stats["parameters"] = json!([
        {"name":"from","in":"query","required":true,"schema":{"type":"string","format":"date-time"},"description":"起点，含；RFC3339。"},
        {"name":"to","in":"query","required":true,"schema":{"type":"string","format":"date-time"},"description":"终点，不含；RFC3339，最多十年。"}
    ]);
    query_errors(&mut stats);
    add("/api/v1/energy/stats", "get", stats);

    let mut swap = operation(
        "getSwap",
        "换电记录详情",
        "按本地记录 ID 查询，不以订单号替代记录 ID。多租户模式要求租户 API key。",
        "换电与订单",
        "SwapEvent",
        false,
    );
    swap["parameters"] = json!([path_parameter("id", "本地换电记录 ID。")]);
    error(&mut swap, "404", "not_found：记录不存在。");
    add("/api/v1/swaps/{id}", "get", swap);
    add(
        "/api/v1/orders/active",
        "get",
        operation(
            "activeOrders",
            "进行中服务订单",
            "最多返回 20 条当前进行中的订单，与已完成换电历史分开。站点身份只有取得可核验 ID 后才补充。",
            "换电与订单",
            "ActiveServiceOrderPage",
            true,
        ),
    );
    let mut create_swap_order = operation(
        "createSwapOrder",
        "一键创建换电订单",
        "有真实订单副作用。客户端只提交换电站 ID 和精确确认文字；后端先通过加密站点详情接口解析 location（经度,纬度），再顺序执行一次 /swap/scan 和一次 /swap。请求字段与国内 6.9.6 客户端对齐（scan 仅传 spot_id/vehicle_id，create 传 action/service_type/scene，model_type_year 固定为 G1.2）。车辆、车型和目标电池档位全部来自服务端配置，任何一步失败都不会自动重试。",
        "换电与订单",
        "CreateSwapOrderOutcome",
        true,
    );
    create_swap_order["security"] = json!([
        {"BearerAuth":[], "VehicleControlKey":[]}, {"ApiKeyAuth":[], "VehicleControlKey":[]}
    ]);
    create_swap_order["requestBody"] = request_body(
        "CreateSwapOrderInput",
        "仅接受站点 ID 和精确确认文字；不接受客户端坐标、车辆 ID、车型或电池档位。",
    );
    error(
        &mut create_swap_order,
        "400",
        "invalid_request / invalid_swap_order：JSON、站点 ID 或确认文字无效。",
    );
    error(
        &mut create_swap_order,
        "401",
        "unauthorized：普通 API Key 或复用的车控 Key 缺失/不匹配。",
    );
    error(
        &mut create_swap_order,
        "409",
        "swap_order_rejected：scan 或真实下单被上游业务拒绝；不得自动重试。",
    );
    error(
        &mut create_swap_order,
        "502",
        "upstream_error / swap_order_failed：站点查询、解密、签名、传输或响应处理失败。",
    );
    error(
        &mut create_swap_order,
        "503",
        "swap_order_disabled / station_template_not_configured：换电下单或站点模板未配置。",
    );
    create_swap_order["x-side-effects"] = json!("creates-real-swap-order");
    create_swap_order["x-no-automatic-retry"] = json!(true);
    add("/api/v1/swap-orders", "post", create_swap_order);

    let mut coupons = operation(
        "availableCoupons",
        "可用卡券",
        "按国内版卡包的 available 状态查询，可分页；使用服务端已配置的 NIO 账号，不接受客户端上游凭据。",
        "卡券与签到",
        "AvailableCouponsPage",
        true,
    );
    coupons["parameters"] = json!([
        integer_query("limit", 20, 1, 100, "每页条数，1…100。"),
        offset_query()
    ]);
    query_errors(&mut coupons);
    upstream_errors(&mut coupons, "rewards_disabled：NIO 账号未配置。");
    add("/api/v1/coupons/available", "get", coupons);

    let mut check_in = operation(
        "checkIn",
        "立即签到",
        "手动调用一次国内版每日签到，与服务器每日随机签到共用北京时间日期去重记录。请求明确未发出（连接失败）时最多自动重试 3 次；可能已被上游处理的失败不重试。返回本次签到状态、积分和连续天数。",
        "卡券与签到",
        "CheckInOutcome",
        true,
    );
    upstream_errors(&mut check_in, "rewards_disabled：NIO 账号未配置。");
    error(
        &mut check_in,
        "409",
        "check_in_already_attempted：该北京时间日期已有签到尝试。",
    );
    error(
        &mut check_in,
        "500",
        "check_in_result_not_recorded：签到结果未能写入数据库；请先核对 App 内签到状态。",
    );
    check_in["x-side-effects"] = json!("performs-daily-check-in");
    check_in["x-retry-policy"] = json!(
        "Retry only connection failures before the request is sent, up to 3 attempts per Beijing day; ambiguous failures are not retried."
    );
    add("/api/v1/check-in", "post", check_in);

    let mut stations = operation(
        "listStations",
        "站点目录与搜索",
        "读取由订单同步发现的站点目录；不是全量蔚来地图站点搜索。",
        "站点",
        "SwapStationPage",
        true,
    );
    stations["parameters"] = json!([
        integer_query("limit", 50, 1, 200, "每页条数，越界数值夹到 1…200。"),
        offset_query(),
        query(
            "q",
            json!({"type":"string"}),
            "可选搜索词，去除前后空白；在站点 ID、名称、地址和运营商名称中做不区分大小写的包含匹配。"
        )
    ]);
    query_errors(&mut stations);
    add("/api/v1/stations", "get", stations);
    let mut remote_station_search = operation(
        "searchSwapStations",
        "本地优先按名称搜索换电站",
        "先在本地 swap_stations 目录按名称搜索；有结果时直接返回。没有结果时请求蔚来远端地图，仅保留 recharge 分类中 sub_type=PowerSwap 且 ID 为 PS-NIO-* 的项目，并把名称、ID、地址和经纬度幂等写回本地目录。",
        "站点",
        "SwapStationSearchResult",
        true,
    );
    remote_station_search["parameters"] = json!([{
        "name":"name", "in":"query", "required":true,
        "description":"换电站名称关键词；服务端移除首尾空白，限制为 1…100 个非控制字符。",
        "schema":{"type":"string", "minLength":1, "maxLength":100}
    }]);
    error(
        &mut remote_station_search,
        "400",
        "invalid_request：名称为空、过长或含控制字符。",
    );
    upstream_errors(
        &mut remote_station_search,
        "vehicle_not_configured：远端搜索所需 NIO 会话未配置。",
    );
    add("/api/v1/stations/search", "get", remote_station_search);
    let mut nearby = operation(
        "nearbySwapStations",
        "附近换电站地图结果",
        "使用 NIO CN 只读地图接口按给定坐标查询当前视窗中的换电站图钉。结果不是半径内完整站点列表，不返回输入坐标。",
        "站点",
        "NearbyStationResult",
        true,
    );
    nearby["requestBody"] = request_body(
        "NearbyStationsRequest",
        "搜索中心坐标仅发送给上游地图接口，不写入响应。",
    );
    error(&mut nearby, "400", "invalid_request：经纬度无效。");
    upstream_errors(&mut nearby, "vehicle_not_configured：NIO 会话未配置。");
    nearby["x-read-only-calculation"] = json!(true);
    add("/api/v1/stations/nearby", "post", nearby);
    let mut station = operation(
        "getStation",
        "站点目录详情",
        "只读取本地站点目录，不请求实时库存。",
        "站点",
        "SwapStation",
        true,
    );
    station["parameters"] = json!([path_parameter("id", "站点 ID。")]);
    error(
        &mut station,
        "404",
        "station_not_found：目录中不存在该站点。",
    );
    add("/api/v1/stations/{id}", "get", station);
    let mut live = operation(
        "liveStation",
        "站点实时库存与费率",
        "通过已配置站点模板发送一次实时只读请求。保留上游完整分时费率、当前费率和说明，队列及电池充电时间字段明确区分未知；可换 75 kWh 电池仍按容量=75、未占用、progress≥92 筛选，但不保证到站即可换。未知目录 ID 仍可通过有效模板查询。",
        "站点",
        "StationLiveStatus",
        true,
    );
    live["parameters"] = json!([{
        "name":"id", "in":"path", "required":true, "description":"PS-NIO- 开头的站点 ID，最长 128 字节，只允许 ASCII 字母、数字、连字符与下划线。",
        "schema":{"type":"string", "pattern":"^PS-NIO-[A-Za-z0-9_-]*$", "maxLength":128}
    }]);
    error(&mut live, "400", "invalid_request：站点 ID 无效。");
    upstream_errors(
        &mut live,
        "station_template_not_configured：站点请求模板未配置。",
    );
    add("/api/v1/stations/{id}/live", "get", live);

    let mut straight_line = operation(
        "estimateStraightLineEnergy",
        "直线距离与粗估电耗",
        "只读试算：使用请求体中的车辆坐标与站点坐标计算地理直线距离，能耗只读取后端每日计算并持久化的最近累计100公里缓存；本请求不查询行程上游、不写数据库。未知目录站点可同时提供附近查询得到的站点坐标，坐标只做范围校验，不独立核验其与站点ID的对应关系。不会返回车辆原始坐标；不是道路驾车路线，不含实时路况或通行费。",
        "站点",
        "StraightLineEnergyEstimate",
        true,
    );
    straight_line["parameters"] = json!([{
        "name":"id", "in":"path", "required":true,
        "description":"PS-NIO- 开头的站点 ID；目录未知时需在请求体提供站点坐标。",
        "schema":{"type":"string","pattern":"^PS-NIO-[A-Za-z0-9_-]+$","maxLength":128}
    }]);
    straight_line["requestBody"] = request_body(
        "StraightLineEnergyRequest",
        "车辆坐标只用于本次直线计算，不写入结果；可选站点坐标必须成对提供。",
    );
    error(
        &mut straight_line,
        "400",
        "invalid_request：站点 ID、车辆坐标或可选站点坐标无效。",
    );
    error(
        &mut straight_line,
        "404",
        "station_not_found：目录中不存在该站点，且未提供站点坐标。",
    );
    error(
        &mut straight_line,
        "422",
        "station_coordinates_unavailable：目录站点无有效坐标，且未提供站点坐标。",
    );
    error(
        &mut straight_line,
        "500",
        "energy_cache_error：每日能耗缓存读取失败。",
    );
    straight_line["x-read-only-calculation"] = json!(true);
    add(
        "/api/v1/stations/{id}/straight-line-energy",
        "post",
        straight_line,
    );

    let mut status = operation(
        "vehicleStatus",
        "车辆状态",
        "透传 NIO 车辆状态 JSON；有有效 GPS 时尝试保存本地快照。保存失败只记录日志，不丢弃成功的上游状态响应。",
        "车辆",
        "UpstreamVehicleStatus",
        true,
    );
    upstream_errors(&mut status, "vehicle_not_configured：车辆凭证未配置。");
    add("/api/v1/vehicle/status", "get", status);
    let mut widget = operation(
        "vehicleWidgetInfo",
        "车辆 Widget 状态",
        "透传 NIO Widget 信息 JSON。调用方需检查 result_code，并与车辆状态接口核对 vehicle_id。",
        "车辆",
        "UpstreamWidgetInfo",
        true,
    );
    upstream_errors(&mut widget, "vehicle_not_configured：车辆凭证未配置。");
    add("/api/v1/vehicle/widget-info", "get", widget);
    let mut history = operation(
        "vehicleHistory",
        "本地位置采样历史",
        "按采样时间倒序返回历史 GPS 点；采样轨迹不等同于 NIO 官方行程，不能用它替代行程里程或推导能耗。",
        "车辆",
        "VehicleSnapshotPage",
        true,
    );
    history["parameters"] = json!([integer_query(
        "limit",
        2000,
        1,
        2000,
        "单次返回点数，越界数值夹到 1…2000；历史采样不再滚动删除。"
    )]);
    query_errors(&mut history);
    add("/api/v1/vehicle/history", "get", history);

    let mut current = operation(
        "currentCharging",
        "最新充电会话采样",
        "读取最近最多 5000 个充电采样点，按车辆变化或相邻点间隔超过 15 分钟划分会话，再以时间正序返回最新会话。最新会话不必仍在充电。",
        "充电",
        "VehicleChargingSamplePage",
        true,
    );
    current["responses"]["200"]["description"] = json!("最新充电会话采样；没有数据时 items=[]。");
    add("/api/v1/vehicle/charging/current", "get", current);
    let mut sessions = operation(
        "chargingSessions",
        "充电会话列表",
        "从历史充电采样点生成会话摘要；保留现有 15 分钟分段规则，以最新会话在前返回。",
        "充电",
        "VehicleChargingSessionPage",
        true,
    );
    sessions["parameters"] = json!([integer_query(
        "limit",
        50,
        1,
        100,
        "会话数，越界数值夹到 1…100。"
    )]);
    query_errors(&mut sessions);
    add("/api/v1/vehicle/charging/sessions", "get", sessions);
    let mut session = operation(
        "chargingSession",
        "指定充电会话采样",
        "使用会话列表返回的 ID 查询，采样按时间正序返回。ID 由会话起点生成。",
        "充电",
        "VehicleChargingSamplePage",
        true,
    );
    session["parameters"] = json!([path_parameter(
        "id",
        "会话列表返回的 ID，例如 1791534600000:vehicle-example；作为路径片段需 URL 编码。"
    )]);
    error(
        &mut session,
        "404",
        "charging_session_not_found：历史数据中找不到会话。",
    );
    add("/api/v1/vehicle/charging/sessions/{id}", "get", session);

    let mut trips = operation(
        "vehicleTrips",
        "已保存行程",
        "立即返回数据库中已保存的行程，不等待上游；每次读取异步触发一次去重的上游同步，更新后的数据需再次查询才能看到。首次回填过程中可能返回空页或不完整历史。最高速度、累计里程及急加速/急减速/急转弯次数为可选字段，上游缺失时为 null。能耗只接受上游详情实际返回的 trip_eng，不从 SOC、价格或电池容量猜测。",
        "行程",
        "VehicleTripPage",
        true,
    );
    trips["parameters"] = json!([
        integer_query(
            "count",
            20,
            1,
            100,
            "目标条数，越界数值夹到 1…100；同一秒内的行程不会跨页拆分，实际数量可能略多。"
        ),
        query(
            "query_time",
            json!({"type":"integer", "format":"int64"}),
            "数据库查询时间上界（不含），Unix 秒。省略时从最新开始；下一页使用响应的 next_query_time。"
        )
    ]);
    query_errors(&mut trips);
    error(&mut trips, "500", "database_error：行程表读取失败。");
    error(
        &mut trips,
        "503",
        "vehicle_not_configured：车辆凭证未配置。",
    );
    add("/api/v1/vehicle/trips", "get", trips);

    let mut action = operation(
        "vehicleAction",
        "远程车辆指令",
        "有真实车辆副作用。需普通 API Key 和独立车控 Key；车控默认关闭。客户端必须显式确认，禁止自动重试。解锁车门与启动授权是不同动作。服务端保留车控配置、PIN、TLS、状态检查和单指令互斥规则。",
        "车控",
        "ActionOutcome",
        true,
    );
    action["security"] = json!([
        {"BearerAuth":[], "VehicleControlKey":[]}, {"ApiKeyAuth":[], "VehicleControlKey":[]}
    ]);
    action["requestBody"] = request_body(
        "ActionInput",
        "单次车控指令。PIN、Token 与证书始终来自服务端，不能由客户端提交。",
    );
    error(
        &mut action,
        "401",
        "unauthorized：普通 API Key 或独立车控 Key 缺失/不匹配。",
    );
    error(
        &mut action,
        "400",
        "invalid_request / invalid_vehicle_action：JSON、确认文字或动作参数无效。",
    );
    error(
        &mut action,
        "409",
        "vehicle_state_unsafe / vehicle_action_unverified：状态不安全，或已接受指令但未确认目标状态；不得自动重试。",
    );
    error(
        &mut action,
        "502",
        "vehicle_action_failed：TLS、上游传输、动作接受或响应处理失败。",
    );
    error(
        &mut action,
        "503",
        "vehicle_control_disabled / vehicle_pin_unavailable：服务端车控未配置或缺少可用 PIN。",
    );
    action["x-side-effects"] = json!("physical-vehicle-control");
    add("/api/v1/vehicle/action", "post", action);

    let mut poll = operation(
        "manualPoll",
        "手动站点轮询",
        "请求一次已配置站点库存读取并保存快照，可能形成站点差分候选。已有轮询时返回 skipped；不会排队重复请求。候选不等同于已确认订单。",
        "维护",
        "PollOutcome",
        true,
    );
    upstream_errors(&mut poll, "station_not_configured：站点轮询未配置。");
    poll["x-side-effects"] = json!("database-write-and-upstream-read");
    add("/api/v1/poll", "post", poll);
    let mut import = operation(
        "importOrder",
        "导入已完成换电订单",
        "按 order_no 幂等插入或更新本地记录，保留现有候选匹配与电量来源规则。满足匹配窗口和站点条件时会异步触发一次站点轮询。请求体上限 256 KiB。",
        "维护",
        "SwapEvent",
        true,
    );
    import["requestBody"] = request_body(
        "ImportedOrder",
        "已完成订单资料；精确换电量仅由 energy_kwh 提供。",
    );
    error(
        &mut import,
        "400",
        "invalid_request：JSON、订单号或电池/电量数值无效。",
    );
    import["x-side-effects"] = json!("database-write-and-conditional-upstream-read");
    add("/api/v1/orders/import", "post", import);
    add(
        "/mcp",
        "post",
        json!({
            "operationId":"mcpJsonRpc",
            "summary":"MCP Streamable HTTP endpoint",
            "description":"受 API_KEY 或已启用的 OAuth Bearer token 保护的 MCP JSON-RPC 端点，支持 2026-07-28 无会话协议及 2025-11-25 初始化。暴露除车控外的后端能力，包括可用卡券、签到和真实换电下单。换电下单仍要求 X-Vehicle-Control-Key；签到仅对未发出的连接失败重试，下单不自动重试。",
            "tags":["服务"],
            "security":[{"ApiKeyAuth":[]},{"BearerAuth":[]}],
            "requestBody":{"required":true,"content":{"application/json":{"schema":{"type":"object"}}}},
            "responses":{"200":{"description":"MCP JSON-RPC response"},"401":{"description":"Unauthorized"}}
        }),
    );
    add(
        "/.well-known/oauth-protected-resource/mcp",
        "get",
        json!({"operationId":"mcpProtectedResourceMetadata","summary":"MCP OAuth 资源元数据","responses":{"200":{"description":"OAuth 已启用"},"404":{"description":"OAuth 未启用"}}}),
    );
    add(
        "/.well-known/oauth-authorization-server",
        "get",
        json!({"operationId":"mcpAuthorizationServerMetadata","summary":"OAuth 授权服务器元数据","responses":{"200":{"description":"OAuth 已启用"},"404":{"description":"OAuth 未启用"}}}),
    );
    add(
        "/oauth/register",
        "post",
        json!({"operationId":"registerMcpClient","summary":"注册 OAuth 公共客户端","responses":{"201":{"description":"客户端已注册"},"400":{"description":"回调地址无效"}}}),
    );
    add(
        "/oauth/token",
        "post",
        json!({"operationId":"exchangeMcpToken","summary":"兑换或续期 MCP OAuth 令牌","responses":{"200":{"description":"令牌"},"400":{"description":"授权无效"}}}),
    );
    paths.insert("/oauth/authorize".to_owned(),json!({
        "get":{"operationId":"mcpAuthorizePage","summary":"显示 MCP 授权页面","responses":{"200":{"description":"登录表单"},"400":{"description":"授权请求无效"}}},
        "post":{"operationId":"mcpAuthorizeSubmit","summary":"提交 MCP 授权","responses":{"302":{"description":"回调并携带授权码"},"401":{"description":"登录失败"}}}
    }));

    json!({
        "openapi":"3.1.0", "jsonSchemaDialect":"https://json-schema.org/draft/2020-12/schema",
        "info":{
            "title":"NIOPowerSwapAssist Rust API", "version":env!("CARGO_PKG_VERSION"),
            "description":"Actix Web / PostgreSQL + Diesel 后端的实际 HTTP 契约。注释写在 description 中，文件保持合法 JSON。所有日期时间为 RFC3339，距离为 km，功率为 W，电量为 kWh。车控、订单确认、候选匹配、分组与采样分段规则以服务端实现为准。公开只读接口与受保护接口的区别在每个 operation 中明确标注。export-openapi 是离线文档命令，不会启动服务或发送车辆指令。"
        },
        "servers":[
            {"url":"http://127.0.0.1:8080", "description":"默认租户；实际部署请替换为自己的 HTTPS 服务地址。"},
            {"url":"http://127.0.0.1:8080/t/{tenant}", "description":"额外租户的独立业务 schema 和 API key。", "variables":{"tenant":{"default":"second_account","description":"租户 slug。"}}}
        ],
        "tags":[
            {"name":"服务", "description":"健康、配置标志与轮询状态。"},
            {"name":"账户", "description":"手机号短信验证码登录 NIO。"},
            {"name":"车辆", "description":"上游车辆状态与本地 GPS 采样。"},
            {"name":"站点", "description":"本地站点目录和实时可换电池。"},
            {"name":"换电与订单", "description":"已确认历史与进行中订单分开返回。"},
            {"name":"卡券与签到", "description":"国内版可用卡券与每日签到。"},
            {"name":"充电", "description":"充电采样与会话摘要。"},
            {"name":"行程", "description":"NIO 官方行程与实际详情能耗。"},
            {"name":"车控", "description":"需明确确认的真实车辆动作。"},
            {"name":"维护", "description":"会写入数据库的轮询和导入操作。"}
        ],
        "paths":paths,
        "components":{
            "securitySchemes":{
                "BearerAuth":{"type":"http", "scheme":"bearer", "description":"普通 API_KEY。配置后按 Bearer <key> 比较；不在文档中保存真实密钥。"},
                "ApiKeyAuth":{"type":"apiKey", "in":"header", "name":"X-API-Key", "description":"普通 API_KEY 的另一种传法。若同时提供该头和 Bearer，服务端优先检查 X-API-Key。仅 loopback 环境可不配置 API_KEY。"},
                "VehicleControlKey":{"type":"apiKey", "in":"header", "name":"X-Vehicle-Control-Key", "description":"独立 NIO_CONTROL_API_KEY，用于车控和真实换电下单，不能代替普通 API_KEY。App 保存该 Key 不会启用服务端能力。"},
            },
            "schemas":schemas()
        }
    })
}

fn operation(
    id: &str,
    summary: &str,
    description: &str,
    tag: &str,
    response: &str,
    protected: bool,
) -> Value {
    let mut value = json!({
        "operationId":id, "summary":summary, "description":description, "tags":[tag],
        "security":if protected {json!([{"BearerAuth":[]},{"ApiKeyAuth":[]}])} else {json!([])},
        "responses":{
            "200":{"description":"请求成功。", "content":{"application/json":{"schema":reference(response)}}},
            "500":{"description":"database_error：本地数据库操作失败。", "content":{"application/json":{"schema":reference("Error")}}}
        }
    });
    if protected {
        error(
            &mut value,
            "401",
            "unauthorized：普通 API Key 缺失/不匹配。",
        );
    }
    if matches!(
        id,
        "health" | "vehicleStatus" | "vehicleWidgetInfo" | "vehicleTrips" | "vehicleAction"
    ) {
        value["responses"].as_object_mut().unwrap().remove("500");
    }
    value
}

fn error(operation: &mut Value, status: &str, description: &str) {
    operation["responses"][status] = json!({"description":description, "content":{"application/json":{"schema":reference("Error")}}});
}

fn upstream_errors(operation: &mut Value, unavailable: &str) {
    error(
        operation,
        "502",
        "upstream_error：上游 HTTP、协议、解密或数据形状失败。",
    );
    error(operation, "503", unavailable);
}

fn query_errors(operation: &mut Value) {
    operation["responses"]["400"] = json!({
        "description":"查询参数类型无法解析；Actix Query 提取器返回文本错误。",
        "content":{"text/plain":{"schema":{"type":"string"}}}
    });
}

fn request_body(schema: &str, description: &str) -> Value {
    json!({"required":true,"description":description,"content":{"application/json":{"schema":reference(schema)}}})
}

fn query(name: &str, schema: Value, description: &str) -> Value {
    json!({"name":name,"in":"query","required":false,"description":description,"schema":schema})
}

fn integer_query(name: &str, default: u32, min: u32, max: u32, description: &str) -> Value {
    query(
        name,
        json!({"type":"integer","minimum":min,"maximum":max,"default":default}),
        description,
    )
}

fn offset_query() -> Value {
    query(
        "offset",
        json!({"type":"integer","minimum":0,"default":0,"maximum":u32::MAX}),
        "从 0 开始的分页偏移。",
    )
}

fn path_parameter(name: &str, description: &str) -> Value {
    json!({"name":name,"in":"path","required":true,"description":description,"schema":{"type":"string"}})
}

fn reference(name: &str) -> Value {
    json!({"$ref":format!("#/components/schemas/{name}")})
}
fn nullable(schema: Value) -> Value {
    json!({"anyOf":[schema,{"type":"null"}]})
}
fn text(description: &str) -> Value {
    json!({"type":"string","description":description})
}
fn number(description: &str) -> Value {
    json!({"type":"number","description":description})
}
fn integer(description: &str) -> Value {
    json!({"type":"integer","description":description})
}
fn boolean(description: &str) -> Value {
    json!({"type":"boolean","description":description})
}
fn date_time(description: &str) -> Value {
    json!({"type":"string","format":"date-time","description":description})
}
fn date(description: &str) -> Value {
    json!({"type":"string","format":"date","description":description})
}
fn array(schema: &str, description: &str) -> Value {
    json!({"type":"array","items":reference(schema),"description":description})
}
fn opt(schema: Value, description: &str) -> Value {
    let mut schema = nullable(schema);
    schema["description"] = json!(description);
    schema
}
fn bounded_number(description: &str, max: f64) -> Value {
    json!({"type":"number","minimum":0,"maximum":max,"description":description})
}

fn object(description: &str, properties: &[(&str, Value)], required: Option<&[&str]>) -> Value {
    let fields: Map<String, Value> = properties
        .iter()
        .map(|(name, value)| ((*name).to_owned(), value.clone()))
        .collect();
    let required: Vec<&str> = required
        .map(|items| items.to_vec())
        .unwrap_or_else(|| properties.iter().map(|(name, _)| *name).collect());
    json!({"type":"object","description":description,"properties":fields,"required":required})
}

fn schemas() -> Value {
    let mut schemas = Map::new();
    let mut add = |name: &str, schema: Value| {
        schemas.insert(name.to_owned(), schema);
    };

    add(
        "NioSmsInput",
        object(
            "发送登录短信。",
            &[("mobile", text("中国大陆 11 位手机号。"))],
            None,
        ),
    );
    add(
        "NioSmsChallenge",
        object(
            "单次登录挑战。",
            &[
                ("challenge_id", text("UUID，提交验证码时原样带回。")),
                ("expires_in_seconds", integer("有效期，固定 600 秒。")),
            ],
            None,
        ),
    );
    add(
        "NioLoginInput",
        object(
            "提交短信验证码。",
            &[
                ("challenge_id", text("前一步返回的 UUID。")),
                ("verification_code", text("6 位数字验证码。")),
            ],
            None,
        ),
    );
    add(
        "NioLoginResult",
        object(
            "敏感的 NIO 登录凭据；不要写入日志。",
            &[
                ("result_code", text("成功时为 success。")),
                (
                    "data",
                    json!({"type":"object","description":"NIO 返回的 access_token、refresh_token、token_key、token_type、过期时间及账户字段。","additionalProperties":true}),
                ),
                (
                    "backend_config_saved",
                    opt(
                        boolean("租户模式下，新 token 是否已加密写入 PostgreSQL。"),
                        "原有单租户模式不返回此字段。",
                    ),
                ),
            ],
            Some(&["result_code", "data"]),
        ),
    );

    add(
        "CouponGroupCount",
        object(
            "合并卡券条目的实际张数。面额仅从明确的券标题识别，不能用 full_price 门槛代替。",
            &[
                ("title", text("券标题。")),
                (
                    "classification",
                    opt(text("上游卡券分类。"), "缺失时为 null。"),
                ),
                (
                    "count",
                    opt(
                        integer("该合并条目代表的实际张数。"),
                        "merge_count 无效时为 null。",
                    ),
                ),
                ("count_source", text("merge_count 或 single_item。")),
                (
                    "face_value_cny",
                    opt(
                        integer("从明确的“X元优惠券”标题解析的面额，人民币元。"),
                        "标题不明确时为 null。",
                    ),
                ),
                (
                    "face_value_source",
                    opt(
                        text("面额来源，为 coupon_title 或 coupon_name。"),
                        "面额未知时为 null。",
                    ),
                ),
            ],
            None,
        ),
    );
    add(
        "AvailableCouponsPage",
        object(
            "当前账号可用卡券分页结果；amount 是上游合并条目数，实际券张数看 coupon_groups 和 page_coupon_count。原始 coupon 对象仍保留上游字段。",
            &[
                (
                    "amount",
                    integer("上游返回的合并条目总数，不是实际券张数。"),
                ),
                (
                    "coupons",
                    json!({"type":"array","items":{"type":"object","additionalProperties":true}}),
                ),
                ("has_more", json!({"type":"boolean"})),
                (
                    "coupon_groups",
                    array(
                        "CouponGroupCount",
                        "当前页每个合并条目的实际张数、分类和可识别面额。",
                    ),
                ),
                (
                    "page_coupon_count",
                    opt(
                        integer("当前页实际券张数之和。"),
                        "任一条目数量无效时为 null。",
                    ),
                ),
                (
                    "total_coupon_count",
                    opt(
                        integer("所有页的实际券张数。"),
                        "只有从第0页取全且上游无更多页时才有值；否则为 null。",
                    ),
                ),
                ("limit", integer("本次每页条数。")),
                ("offset", integer("本次偏移。")),
            ],
            None,
        ),
    );
    add(
        "CheckInOutcome",
        object(
            "一次每日签到的结果；时间戳为上游秒级 Unix 时间。",
            &[
                ("checked_in", json!({"type":"boolean"})),
                ("tip", json!({"type":"string"})),
                ("credit", integer("本次获得的积分。")),
                ("server_time", integer("上游服务时间。")),
                ("checkin_time", integer("签到时间。")),
                ("continuous_days", integer("连续签到天数。")),
                ("credit_amount", integer("连续签到统计中的积分数。")),
            ],
            None,
        ),
    );

    add(
        "EnergyStats",
        object(
            "区间统计；known 字段只汇总有证据的记录，充电电量优先功率积分，缺功率时依据最近换上电池容量与 SOC 增量估算。",
            &[
                ("from", date_time("含起点。")),
                ("to", date_time("不含终点。")),
                ("swap_count", integer("区间换电次数。")),
                (
                    "swap_electricity_fee_cny_known",
                    number("已知换电电费，元。"),
                ),
                ("swap_service_fee_cny_known", number("已知换电服务费，元。")),
                (
                    "swap_total_fee_cny_known",
                    number("已知换电电费与服务费之和，元。"),
                ),
                (
                    "coupon_discount_cny_known",
                    number("已知优惠券减免额，元，正数。"),
                ),
                ("actual_paid_cny_known", number("已知实际支付额，元。")),
                (
                    "fee_breakdown_covered_count",
                    integer("具有费用分项的换电笔数。"),
                ),
                (
                    "paid_amount_covered_count",
                    integer("具有实际支付额的换电笔数。"),
                ),
                ("swap_energy_kwh_known", number("已知换电电量，kWh。")),
                (
                    "swap_energy_covered_count",
                    integer("具有精确换电电量的笔数。"),
                ),
                (
                    "charging_energy_kwh_estimated",
                    opt(
                        number("按功率积分或电池容量乘 SOC 增量估算的充电电量，kWh。"),
                        "没有可估算采样段时为 null。",
                    ),
                ),
                (
                    "charging_energy_kwh_from_power",
                    number("功率积分得到的充电电量，kWh。"),
                ),
                (
                    "charging_energy_kwh_from_soc",
                    number("缺功率时由上次换上电池容量与 SOC 增量估算的充电电量，kWh。"),
                ),
                (
                    "charging_segments_from_power",
                    integer("功率积分覆盖的采样段数。"),
                ),
                (
                    "charging_segments_from_soc",
                    integer("SOC 回退覆盖的采样段数。"),
                ),
                (
                    "charging_segments_uncovered",
                    integer("缺功率且缺少可信容量或 SOC 的采样段数。"),
                ),
                (
                    "charging_sample_count",
                    integer("纳入计算窗口的充电采样数。"),
                ),
                (
                    "total_energy_kwh_known",
                    number("已知换电电量与估算充电电量之和，kWh。"),
                ),
                (
                    "swap_energy_share_percent_of_known",
                    opt(
                        number("换电电量在已知总量中的比例。"),
                        "总量为零时为 null。",
                    ),
                ),
                (
                    "charging_energy_share_percent_of_known",
                    opt(
                        number("充电电量在已知总量中的比例。"),
                        "总量为零时为 null。",
                    ),
                ),
                (
                    "energy_coverage_complete",
                    json!({"type":"boolean","description":"换电电量全部有记录且充电采样段无缺口时为 true；为 false 时占比仅代表已知部分。"}),
                ),
                (
                    "current_month_swap_count",
                    integer("北京时间当前自然月换电次数。"),
                ),
                (
                    "current_month_timezone",
                    json!({"type":"string","const":"Asia/Shanghai"}),
                ),
            ],
            None,
        ),
    );
    add(
        "HealthResponse",
        object(
            "HTTP 服务健康。",
            &[(
                "status",
                json!({"type":"string","const":"ok","description":"服务可响应。"}),
            )],
            None,
        ),
    );
    add(
        "Error",
        object(
            "服务端 JSON 错误；查询参数提取错误可能使用 text/plain。",
            &[
                ("error", text("稳定错误代码。")),
                ("message", text("可读错误说明；不包含密钥或 PIN。")),
            ],
            None,
        ),
    );
    add(
        "PollRunSummary",
        object(
            "最近一次站点轮询记录。",
            &[
                ("started_at", date_time("轮询开始时间。")),
                ("finished_at", date_time("轮询结束时间。")),
                ("outcome", text("success、skipped 或 error。")),
                (
                    "snapshot_id",
                    opt(text("快照 ID。"), "成功保存的快照 ID，失败/跳过时为 null。"),
                ),
                ("message", opt(text("说明。"), "轮询结果说明。")),
            ],
            None,
        ),
    );
    add(
        "ServiceStatus",
        object(
            "配置、轮询状态和本地数据量。",
            &[
                ("station_configured", boolean("默认站点轮询是否已配置。")),
                ("vehicle_configured", boolean("车辆只读凭证是否已配置。")),
                ("service_order_configured", boolean("订单同步是否已配置。")),
                (
                    "station_template_configured",
                    boolean("动态站点请求模板是否已配置。"),
                ),
                ("poll_interval_seconds", integer("默认站点轮询间隔，秒。")),
                (
                    "service_order_poll_interval_seconds",
                    integer("订单同步间隔，秒。"),
                ),
                ("poll_in_progress", boolean("站点轮询当前是否占用执行锁。")),
                (
                    "last_poll",
                    opt(
                        reference("PollRunSummary"),
                        "最近站点轮询；尚未轮询时为 null。",
                    ),
                ),
                ("snapshot_count", integer("站点快照数量。")),
                ("candidate_count", integer("未确认候选数量。")),
                ("confirmed_count", integer("已确认换电记录数量。")),
                (
                    "observed_service_order_count",
                    integer("观察到的订单数量。"),
                ),
            ],
            None,
        ),
    );
    add(
        "PollOutcome",
        object(
            "单次站点轮询结果。",
            &[
                (
                    "outcome",
                    text("success 或 skipped；执行失败使用 HTTP 错误响应。"),
                ),
                ("snapshot_id", opt(text("快照 ID。"), "保存的快照 ID。")),
                (
                    "candidate_event_id",
                    opt(text("候选 ID。"), "形成唯一站点差分候选时返回 ID。"),
                ),
                (
                    "battery_count",
                    opt(integer("电池数。"), "快照中的电池数量；跳过时为 null。"),
                ),
                ("message", text("含触发来源和结果的说明。")),
            ],
            None,
        ),
    );
    add(
        "BatteryObservation",
        object(
            "站点观察到的单块电池。",
            &[
                ("battery_id", text("电池 ID。")),
                (
                    "slot_id",
                    opt(integer("仓位。"), "仓位编号，无法解析时为 null。"),
                ),
                ("battery_type", opt(text("类型。"), "上游电池类型文字。")),
                (
                    "capacity_kwh",
                    opt(number("容量，kWh。"), "解析出的容量，kWh。"),
                ),
                (
                    "soc_percent",
                    opt(number("电量，%。"), "电量，%；无法取得时为 null。"),
                ),
                ("occupied", boolean("是否被占用。")),
                (
                    "production_date",
                    opt(date("生产日期。"), "可核验生产日期；无法解析时为 null。"),
                ),
            ],
            None,
        ),
    );
    add(
        "StationFeeItem",
        object(
            "站点实时费率分项，金额保留上游字符串。",
            &[
                (
                    "fee_type",
                    opt(text("上游费用类型。"), "上游缺失时为 null。"),
                ),
                ("name", text("费用分项名称。")),
                ("fee", text("金额字符串。")),
                ("unit", text("上游计费单位。")),
                ("currency", text("上游货币符号。")),
                ("is_total", boolean("是否为总费用；不能与分项再次相加。")),
            ],
            None,
        ),
    );
    add(
        "StationFeePeriod",
        object(
            "上游给出的完整分时费率。时间段保留原文，不推断缺失的时区。",
            &[
                ("time_period", text("上游原始时段文字。")),
                (
                    "fees",
                    array(
                        "StationFeeItem",
                        "该时段全部费用分项，含服务费、电费和总额（若上游提供）。",
                    ),
                ),
            ],
            None,
        ),
    );
    add(
        "StationLiveQueue",
        object(
            "站点详情中的排队观察；该接口没有已验证的预计等待分钟数或上游更新时间字段。",
            &[
                (
                    "vehicles_ahead",
                    opt(integer("排在前方的车辆数。"), "上游缺失时为 null。"),
                ),
                (
                    "waiting_description",
                    opt(text("上游排队说明。"), "缺失时为 null。"),
                ),
                (
                    "navigation_count",
                    opt(integer("上游导航前往站点的数量。"), "缺失时为 null。"),
                ),
                (
                    "estimated_wait_minutes",
                    opt(
                        integer("预计等待分钟数。"),
                        "该站点响应未提供已验证字段时为 null；可另看进行中订单的估算。",
                    ),
                ),
                (
                    "upstream_updated_at",
                    opt(date_time("上游队列更新时间。"), "无法确认时为 null。"),
                ),
                ("observed_at", date_time("后端收到这次站点响应的时间。")),
            ],
            None,
        ),
    );
    add(
        "StationBatteryReadiness",
        object(
            "站内电池充电进度与预计完成时间；充电完成不保证可立即换入。不会返回电池 ID。",
            &[
                (
                    "slot_id",
                    opt(integer("站内槽位编号。"), "上游缺失时为 null。"),
                ),
                (
                    "capacity_kwh",
                    opt(
                        number("由上游电池描述识别的容量，kWh。"),
                        "无法识别时为 null。",
                    ),
                ),
                (
                    "progress_percent",
                    opt(
                        number("上游 progress 百分比。"),
                        "上游缺失或超范围时为 null。",
                    ),
                ),
                (
                    "battery_occupied",
                    opt(
                        boolean("上游 battery_occupied 标志。"),
                        "上游缺失时为 null。",
                    ),
                ),
                (
                    "charging_time_description",
                    opt(
                        text("上游 charging_time_desc 原文。"),
                        "上游缺失时为 null。",
                    ),
                ),
                (
                    "charging_remaining_minutes",
                    opt(
                        integer("上游明确给出的剩余分钟数。"),
                        "非纯数字或无效时为 null。",
                    ),
                ),
                (
                    "estimated_charge_complete_at",
                    opt(
                        date_time("接收时间加上上游剩余分钟数得到的估计充电完成时间。"),
                        "无可信分钟数时为 null；不是保证可换时间。",
                    ),
                ),
            ],
            None,
        ),
    );
    add(
        "StationLiveStatus",
        object(
            "一次实时站点查询结果。",
            &[
                ("station_id", text("站点 ID。")),
                ("station_name", text("目录名称，未知目录时使用站点 ID。")),
                ("captured_at", date_time("查询完成时间。")),
                ("current_fees", array("StationFeeItem", "当前费率分项。")),
                (
                    "fee_periods",
                    array("StationFeePeriod", "上游完整分时费率，不只包含当前时段。"),
                ),
                (
                    "fee_notices",
                    json!({"type":"array","items":{"type":"string"},"description":"上游费率特殊说明和适用条件。"}),
                ),
                (
                    "fee_timezone",
                    opt(
                        text("上游显式提供的费率时区。"),
                        "未提供时为 null；time_period 保留原文。",
                    ),
                ),
                ("queue", reference("StationLiveQueue")),
                (
                    "battery_readiness",
                    array(
                        "StationBatteryReadiness",
                        "站内电池充电进度，不等于保证可换。",
                    ),
                ),
                (
                    "available_75_count",
                    integer("满足可换筛选条件的 75 kWh 电池数量。"),
                ),
                (
                    "available_75_batteries",
                    array(
                        "BatteryObservation",
                        "所有可换 75 kWh 电池，未截断到 Widget 展示条数。",
                    ),
                ),
            ],
            None,
        ),
    );
    add(
        "NearbyStationsRequest",
        object(
            "地图查询中心坐标。",
            &[
                (
                    "latitude",
                    json!({"type":"number","minimum":-90,"maximum":90}),
                ),
                (
                    "longitude",
                    json!({"type":"number","minimum":-180,"maximum":180}),
                ),
            ],
            Some(&["latitude", "longitude"]),
        ),
    );
    add(
        "NearbyStation",
        object(
            "上游视窗内的换电站图钉。",
            &[
                ("station_id", text("站点 ID。")),
                ("name", opt(text("站点名称。"), "上游详情缺失时为 null。")),
                ("latitude", number("站点纬度。")),
                ("longitude", number("站点经度。")),
                (
                    "straight_line_distance_km",
                    number("从查询中心到站点的地理直线距离，公里。"),
                ),
            ],
            None,
        ),
    );
    add(
        "NearbyStationResult",
        object(
            "NIO 地图视窗搜索结果，不保证半径内完整。",
            &[
                ("source", text("数据源，固定 nio_cn_around_recall。")),
                ("fetched_at", date_time("查询完成时间。")),
                ("viewport_zoom_level", integer("请求的地图缩放等级。")),
                ("viewport_screen_ratio", number("请求的屏幕比例。")),
                ("coverage", text("结果覆盖范围说明。")),
                ("stations", array("NearbyStation", "换电站图钉。")),
            ],
            None,
        ),
    );
    let mut straight_line_request = object(
        "车辆坐标只用于本次计算，不写入响应。可选站点坐标从附近查询取得，必须成对提供。",
        &[
            (
                "latitude",
                json!({"type":"number","minimum":-90,"maximum":90,"description":"车辆纬度。"}),
            ),
            (
                "longitude",
                json!({"type":"number","minimum":-180,"maximum":180,"description":"车辆经度。"}),
            ),
            (
                "station_latitude",
                opt(
                    json!({"type":"number","minimum":-90,"maximum":90}),
                    "目录无有效坐标时可提供附近查询结果的站点纬度；不独立验证站点身份。",
                ),
            ),
            (
                "station_longitude",
                opt(
                    json!({"type":"number","minimum":-180,"maximum":180}),
                    "目录无有效坐标时可提供附近查询结果的站点经度；必须与 station_latitude 成对。",
                ),
            ),
        ],
        Some(&["latitude", "longitude"]),
    );
    straight_line_request["dependentRequired"] = json!({
        "station_latitude": ["station_longitude"],
        "station_longitude": ["station_latitude"]
    });
    straight_line_request["additionalProperties"] = json!(false);
    add("StraightLineEnergyRequest", straight_line_request);
    add(
        "TripEnergySummary",
        object(
            "后台每日取最近累计100公里行程后写入的结果。边界行程若只需部分距离，以整段平均能耗按比例折算，绝非该段实测；缺能耗行程占据时间窗口，但不以零能耗计入。",
            &[
                ("target_distance_km", number("目标里程，固定100公里。")),
                (
                    "actual_distance_km",
                    number("时间序列窗口中纳入的实际里程，最多100公里，含缺能耗行程。"),
                ),
                ("covered_distance_km", number("窗口中有有效能耗的里程。")),
                (
                    "missing_energy_distance_km",
                    number("窗口中能耗未知的里程。"),
                ),
                (
                    "included_energy_kwh",
                    number("已知能耗之和；边界行程可能使用整段平均比例折算。"),
                ),
                (
                    "consumption_kwh_per_100km",
                    opt(
                        number("已知能耗/已覆盖里程×100；有缺口时只代表已知部分。"),
                        "无有效能耗时为 null。",
                    ),
                ),
                (
                    "window_start",
                    opt(
                        date_time("窗口最早纳入行程的开始时间；部分边界行程无法给出精确分段时间。"),
                        "无行程时为 null。",
                    ),
                ),
                (
                    "window_end",
                    opt(
                        date_time("窗口最新纳入行程的结束时间。"),
                        "无行程时为 null。",
                    ),
                ),
                (
                    "sample_cutoff_at",
                    date_time("后台查询行程时的样本截止时间。"),
                ),
                ("computed_at", date_time("后台完成计算的时间。")),
                (
                    "included_trip_count",
                    integer("纳入时间窗口的行程数，含缺能耗行程。"),
                ),
                (
                    "energy_known_trip_count",
                    integer("纳入窗口且能耗已知的行程数。"),
                ),
                (
                    "missing_energy_trip_count",
                    integer("纳入窗口但能耗未知的行程数。"),
                ),
                (
                    "skipped_invalid_trip_count",
                    integer("因时间或距离无效而跳过的行程数。"),
                ),
                (
                    "inspected_trip_count",
                    integer("后台实际检查的去重行程数。"),
                ),
                ("pages_fetched", integer("后台获取的行程分页数。")),
                (
                    "coverage_complete",
                    boolean("是否完整覆盖最近100公里且无已知缺口。"),
                ),
                (
                    "coverage_status",
                    text(
                        "complete、incomplete_data、insufficient_distance 或 query_limit_reached。",
                    ),
                ),
                (
                    "boundary_method",
                    text(
                        "whole_trips、proportional_from_trip_average 或 distance_only_energy_unavailable。",
                    ),
                ),
                (
                    "boundary_trip_used_distance_km",
                    opt(
                        number("边界行程纳入的里程。"),
                        "没有部分边界行程时为 null。",
                    ),
                ),
                (
                    "boundary_trip_full_distance_km",
                    opt(number("边界行程完整里程。"), "没有部分边界行程时为 null。"),
                ),
                (
                    "history_fetch_incomplete",
                    boolean("达到分页上限或游标停滞且不足100公里。"),
                ),
            ],
            None,
        ),
    );
    add(
        "TripEnergyCacheState",
        object(
            "最近一次成功计算的持久化缓存与最近尝试状态；读取不会触发行程请求或数据库写入。",
            &[
                (
                    "status",
                    text("fresh、stale、last_attempt_failed、attempt_incomplete 或 unknown。"),
                ),
                ("stale", boolean("缓存已过36小时，或最近计算失败/中断。")),
                ("last_attempt_failed", boolean("最近一次后台计算是否失败。")),
                (
                    "last_attempt_day",
                    opt(
                        date("最近一次后台计算尝试的北京时间日期。"),
                        "未曾尝试时为 null。",
                    ),
                ),
                (
                    "last_attempt_status",
                    opt(text("最近一次任务状态。"), "未曾尝试时为 null。"),
                ),
                (
                    "summary",
                    opt(
                        reference("TripEnergySummary"),
                        "首次尚无成功结果时为 null，不默认零。",
                    ),
                ),
            ],
            None,
        ),
    );
    add(
        "StraightLineEnergyEstimate",
        object(
            "地理直线距离与每日最近100公里能耗缓存的只读试算；不代表道路绕行成本。",
            &[
                ("station_id", text("站点 ID。")),
                (
                    "station_coordinates_source",
                    text(
                        "known_directory 或 caller_supplied；后者只校验范围、不核验与站点ID的关联。",
                    ),
                ),
                (
                    "station_record_updated_at",
                    opt(
                        date_time("本地站点记录更新时间；不代表坐标实测时间。"),
                        "使用调用方提供的站点坐标时为 null。",
                    ),
                ),
                (
                    "straight_line_distance_km",
                    number("地理直线距离，保留一位小数，公里。"),
                ),
                ("energy_cache", reference("TripEnergyCacheState")),
                (
                    "estimated_energy_for_straight_line_kwh",
                    opt(
                        number("直线距离×缓存百公里能耗/100；缓存不完整时仅为已知部分粗估。"),
                        "首次无缓存或无有效能耗时为 null；实际驾车耗电通常不同。",
                    ),
                ),
                ("distance_kind", text("固定为 geodesic_straight_line。")),
                (
                    "road_distance_km",
                    opt(number("道路行驶距离。"), "当前无路线服务，始终为 null。"),
                ),
                (
                    "road_travel_time_minutes",
                    opt(number("道路行驶时间。"), "当前无路线服务，始终为 null。"),
                ),
                ("traffic_and_tolls_included", boolean("固定为 false。")),
            ],
            None,
        ),
    );
    add(
        "SwapStation",
        object(
            "由订单观察建立的本地站点目录项。",
            &[
                ("station_id", text("稳定站点 ID。")),
                ("station_name", text("站点名称。")),
                ("station_address", opt(text("地址。"), "站点地址。")),
                (
                    "latitude",
                    opt(number("纬度。"), "尚未完成坐标补全时为 null。"),
                ),
                (
                    "longitude",
                    opt(number("经度。"), "尚未完成坐标补全时为 null。"),
                ),
                ("operator_id", opt(text("运营商 ID。"), "运营商 ID。")),
                ("operator_name", opt(text("运营商名称。"), "运营商名称。")),
                (
                    "source_order_no",
                    opt(text("来源订单。"), "发现该站点的订单号。"),
                ),
                ("first_seen_at", date_time("首次观察时间。")),
                ("last_seen_at", date_time("最近观察时间。")),
                ("updated_at", date_time("目录更新记录时间。")),
            ],
            None,
        ),
    );
    add("SwapStationPage", page("SwapStation", true));
    add(
        "SwapStationSearchItem",
        object(
            "名称搜索返回的换电站。本地旧记录在后台补全完成前可能暂时缺少坐标。",
            &[
                ("station_id", text("PS-NIO-* 换电站 ID。")),
                ("name", text("站点名称。")),
                ("address", opt(text("站点地址。"), "未知时为 null。")),
                (
                    "longitude",
                    opt(number("经度。"), "本地旧记录尚未补全时为 null。"),
                ),
                (
                    "latitude",
                    opt(number("纬度。"), "本地旧记录尚未补全时为 null。"),
                ),
                (
                    "icon_url",
                    opt(text("远端图标 URL。"), "上游未提供时为 null。"),
                ),
            ],
            None,
        ),
    );
    add(
        "SwapStationSearchResult",
        object(
            "一次本地优先的名称搜索结果；远端兜底结果已过滤掉普通 POI、充电站、洗车和福利项目。",
            &[
                ("query", text("去除首尾空白后的名称关键词。")),
                (
                    "source",
                    json!({"type":"string","enum":["local","remote"],"description":"本次结果来自本地目录还是远端兜底。"}),
                ),
                (
                    "request_id",
                    opt(text("上游请求 ID。"), "上游未提供时为 null。"),
                ),
                ("stations", array("SwapStationSearchItem", "匹配的换电站。")),
            ],
            None,
        ),
    );
    add(
        "SwapPaymentItem",
        object(
            "订单支付分项。",
            &[
                ("name", text("支付分项名称。")),
                (
                    "amount",
                    number("金额；货币由所属订单 price_currency 指定。"),
                ),
                (
                    "payment_type",
                    opt(integer("支付类型代码。"), "上游支付类型代码。"),
                ),
            ],
            Some(&["name", "amount"]),
        ),
    );
    add(
        "ImportedBattery",
        object(
            "订单导入可提供的电池资料，所有字段都可省略或为 null。",
            &[
                (
                    "battery_id",
                    opt(text("电池 ID。"), "前后空白会移除，空字符串规范为 null。"),
                ),
                (
                    "production_date",
                    opt(date("生产日期。"), "ISO 日期 yyyy-MM-dd。"),
                ),
                (
                    "capacity_kwh",
                    opt(bounded_number("容量，kWh。", 300.0), "容量，0…300 kWh。"),
                ),
                (
                    "soc_percent",
                    opt(bounded_number("SOC，%。", 100.0), "电量，0…100%。"),
                ),
            ],
            Some(&[]),
        ),
    );
    add(
        "ImportedOrder",
        object(
            "按订单号幂等导入。未提供的可选字段不会要求客户端推算。",
            &[
                (
                    "order_no",
                    json!({"type":"string","minLength":1,"maxLength":256,"description":"前后空白移除后的订单号；服务端按 UTF-8 字节长度限制到 256。"}),
                ),
                ("occurred_at", date_time("订单完成/发生时间。")),
                (
                    "station_key",
                    opt(
                        text("站点 ID。"),
                        "可选站点 ID；去除空白，空值规范为 null。",
                    ),
                ),
                (
                    "station_name",
                    opt(text("站名。"), "站名；去除空白，空值规范为 null。"),
                ),
                ("station_address", opt(text("站点地址。"), "站点地址。")),
                (
                    "order_status_name",
                    opt(text("订单状态。"), "订单状态名称。"),
                ),
                (
                    "price_amount",
                    opt(number("订单金额。"), "精确金额（若上游有返回）。"),
                ),
                (
                    "price_currency",
                    opt(text("货币。"), "货币代码，例如 CNY。"),
                ),
                (
                    "price_description",
                    opt(text("支付说明。"), "支付说明文字。"),
                ),
                (
                    "payment_items",
                    array(
                        "SwapPaymentItem",
                        "支付分项，省略时默认空数组；不要把总费用与分项重复加总。",
                    ),
                ),
                (
                    "energy_kwh",
                    opt(
                        bounded_number("订单精确换电量，kWh。", 300.0),
                        "订单给出的精确换电量，0…300 kWh；缺失时为 null。",
                    ),
                ),
                (
                    "outgoing_battery",
                    opt(reference("ImportedBattery"), "从车上换下的电池。"),
                ),
                (
                    "incoming_battery",
                    opt(reference("ImportedBattery"), "换到车上的电池。"),
                ),
                (
                    "raw_payload",
                    json!({"description":"可选原始订单 JSON，用于保留证据；请勿提交 Token、PIN 或私钥。"}),
                ),
            ],
            Some(&["order_no", "occurred_at"]),
        ),
    );
    let mut event = vec![
        ("id", text("本地记录 ID。")),
        ("status", text("confirmed 或 observed_candidate。")),
        ("occurred_at", date_time("换电记录时间。")),
        ("station_key", opt(text("站点 ID。"), "站点 ID。")),
        ("station_name", opt(text("站名。"), "站点名称。")),
        ("station_address", opt(text("地址。"), "站点地址。")),
        (
            "order_no",
            opt(
                text("订单号。"),
                "匹配的订单号；站点候选尚未匹配时为 null。",
            ),
        ),
        ("order_status_name", opt(text("状态。"), "订单状态名称。")),
        ("price_amount", opt(number("金额。"), "订单金额。")),
        ("price_currency", opt(text("货币。"), "货币代码。")),
        ("price_description", opt(text("支付说明。"), "支付说明。")),
        ("payment_items", array("SwapPaymentItem", "支付分项。")),
        (
            "exact_energy_kwh",
            opt(number("精确电量。"), "仅来自订单的精确换电量，kWh。"),
        ),
        (
            "estimated_energy_kwh",
            opt(
                number("估算电量。"),
                "站点证据产生的估算量，kWh；不是精确值。",
            ),
        ),
        ("energy_source", text("换电量来源标志，按实现实际值返回。")),
        ("battery_source", text("电池身份来源标志。")),
        ("confidence", text("记录证据可信度标志。")),
        (
            "evidence",
            json!({"description":"站点差分和订单匹配证据，或 null。"}),
        ),
        ("created_at", date_time("本地记录创建时间。")),
        ("updated_at", date_time("本地记录更新时间。")),
    ];
    for (id, date, capacity, soc, description) in [
        (
            "outgoing_battery_id",
            "outgoing_production_date",
            "outgoing_capacity_kwh",
            "outgoing_soc_percent",
            "从车上换下",
        ),
        (
            "incoming_battery_id",
            "incoming_production_date",
            "incoming_capacity_kwh",
            "incoming_soc_percent",
            "换到车上",
        ),
    ] {
        event.push((
            id,
            opt(text("电池 ID。"), &format!("{description}的电池 ID。")),
        ));
        event.push((
            date,
            opt(
                self::date("生产日期。"),
                &format!("{description}的电池生产日期。"),
            ),
        ));
        event.push((
            capacity,
            opt(number("容量。"), &format!("{description}的电池容量，kWh。")),
        ));
        event.push((
            soc,
            opt(number("SOC。"), &format!("{description}的电池电量，%。")),
        ));
    }
    add(
        "SwapEvent",
        object("换电记录，候选与订单确认的数据来源分开标注。", &event, None),
    );
    add("SwapEventPage", page("SwapEvent", true));
    add(
        "ActiveServiceOrder",
        object(
            "当前进行中的服务订单，不等同于已完成换电记录。",
            &[
                ("order_no", text("订单号。")),
                ("order_type", text("订单类型。")),
                ("order_status", opt(text("状态代码。"), "上游状态代码。")),
                (
                    "order_status_name",
                    opt(text("状态名称。"), "订单状态名称。"),
                ),
                ("order_created_at", date_time("上游订单创建时间。")),
                (
                    "station_key",
                    opt(text("站点 ID。"), "从订单详情补充的稳定站点 ID。"),
                ),
                ("station_name", opt(text("站名。"), "站点名称。")),
                ("station_address", opt(text("地址。"), "站点地址。")),
                (
                    "baseline_captured_at",
                    opt(date_time("基线时间。"), "为订单获取站点库存基线的时间。"),
                ),
                (
                    "queue_number",
                    opt(integer("换电号。"), "订单详情返回的换电号。"),
                ),
                (
                    "target_battery_cap_level",
                    opt(integer("目标电池档位。"), "1 为标续，2 为长续。"),
                ),
                (
                    "vehicles_ahead",
                    opt(
                        integer("前方车辆数。"),
                        "优先使用官方订单状态 waiting_count；缺失时回退到目标电池档位的实时排队数。",
                    ),
                ),
                (
                    "estimated_wait_minutes",
                    opt(
                        integer("预计等待分钟数。"),
                        "优先使用官方订单状态 swap_wait_expected_time；否则按前方车辆数估算。",
                    ),
                ),
                (
                    "estimated_wait_source",
                    opt(
                        text("等待时间来源。"),
                        "swap_order_status 或 station_queue_estimate。",
                    ),
                ),
                (
                    "queue_status_text",
                    opt(
                        text("排队状态文案。"),
                        "优先使用订单详情的 order_title（如“等待换电”），缺失时回退到官方状态描述或站点排队文案。",
                    ),
                ),
                (
                    "queue_updated_at",
                    opt(
                        date_time("排队信息更新时间。"),
                        "最近一次成功读取站点排队信息的时间。",
                    ),
                ),
                ("first_seen_at", date_time("首次观察时间。")),
                ("last_seen_at", date_time("最近观察时间。")),
            ],
            None,
        ),
    );
    add(
        "ActiveServiceOrderPage",
        object(
            "进行中订单集合。",
            &[(
                "items",
                array("ActiveServiceOrder", "当前进行中的订单，最多 20 条。"),
            )],
            None,
        ),
    );
    add(
        "VehicleSnapshot",
        object(
            "车辆 GPS 采样；不能替代官方行程。",
            &[
                ("vehicle_id", text("车辆 ID。")),
                ("sampled_at", date_time("车辆位置采样时间。")),
                ("latitude", number("纬度，度。")),
                ("longitude", number("经度，度。")),
                ("soc", opt(number("SOC。"), "车辆电量，%。")),
                (
                    "remaining_range",
                    opt(number("标准续航。"), "标准剩余续航，km。"),
                ),
                (
                    "remaining_actual_range",
                    opt(number("动态续航。"), "动态剩余续航，km。"),
                ),
                ("mileage", opt(number("里程。"), "车辆累计里程，km。")),
                ("inside_temperature", opt(number("温度。"), "车内温度，℃。")),
                (
                    "outside_temperature",
                    opt(number("温度。"), "车外温度，℃。"),
                ),
            ],
            None,
        ),
    );
    add("VehicleSnapshotPage", page("VehicleSnapshot", false));
    add(
        "VehicleChargingSample",
        object(
            "一次充电状态采样。",
            &[
                ("vehicle_id", text("车辆 ID。")),
                ("sampled_at", date_time("采样时间。")),
                ("soc", opt(number("SOC。"), "电量，%。")),
                (
                    "charge_state",
                    integer("上游充电状态代码；会话采样保留实际原始值。"),
                ),
                ("charging_current", opt(number("电流。"), "充电电流，A。")),
                (
                    "charging_power",
                    opt(number("功率。"), "充电功率，W；UI 展示 kW 时需除以 1000。"),
                ),
                ("charging_voltage", opt(number("电压。"), "充电电压，V。")),
            ],
            None,
        ),
    );
    add(
        "VehicleChargingSamplePage",
        object(
            "按时间正序排列的会话采样及功率曲线积分电量。充电中每次请求实时计算；结束后固化，历史缺失时在详情请求中补算。",
            &[
                (
                    "items",
                    array("VehicleChargingSample", "采样点；无数据时空数组。"),
                ),
                (
                    "energy_kwh",
                    opt(
                        number("积分电量。"),
                        "按相邻功率采样梯形积分得到的充入电量，kWh；不足两个有效点时为空。",
                    ),
                ),
                (
                    "energy_finalized",
                    boolean("true 表示充电结束后已持久化；false 表示当前请求实时计算。"),
                ),
            ],
            None,
        ),
    );
    add(
        "VehicleChargingSession",
        object(
            "按历史采样生成的充电会话摘要。",
            &[
                ("id", text("起始采样 Unix 毫秒与车辆 ID 组合的会话 ID。")),
                ("vehicle_id", text("车辆 ID。")),
                ("started_at", date_time("会话起始采样时间。")),
                (
                    "ended_at",
                    date_time("会话最新采样时间，不必是实际充电结束时间。"),
                ),
                ("duration_seconds", integer("首末采样间隔，秒。")),
                ("start_soc", opt(number("SOC。"), "最早可用 SOC，%。")),
                ("end_soc", opt(number("SOC。"), "最新可用 SOC，%。")),
                (
                    "peak_power_watts",
                    opt(number("峰值功率。"), "历史采样中的峰值功率，W。"),
                ),
                (
                    "energy_kwh",
                    opt(number("积分电量。"), "已结束会话持久化的充入电量，kWh。"),
                ),
                ("sample_count", integer("会话采样点数量。")),
            ],
            None,
        ),
    );
    add(
        "VehicleChargingSessionPage",
        page("VehicleChargingSession", false),
    );
    let mut location = Vec::new();
    for (name, description) in [
        ("address", "完整地址"),
        ("poi", "地点名称"),
        ("road_name", "道路名称"),
        ("town", "乡镇/街道"),
        ("district", "区县"),
        ("city", "城市"),
        ("province", "省份"),
    ] {
        location.push((name, opt(text(description), description)));
    }
    location.push(("latitude", opt(number("纬度。"), "纬度，度。")));
    location.push(("longitude", opt(number("经度。"), "经度，度。")));
    add(
        "VehicleTripLocation",
        object(
            "官方行程地点；地址字段可缺失，不按 GPS 采样拼造地点。",
            &location,
            None,
        ),
    );
    add(
        "VehicleTrip",
        object(
            "NIO 官方行程及实际详情返回的能耗。",
            &[
                ("id", text("上游 journey_id。")),
                (
                    "trip_id",
                    opt(text("单次行程 ID。"), "上游 trip_id，可能为空。"),
                ),
                ("started_at", date_time("开始时间。")),
                ("ended_at", date_time("结束时间。")),
                (
                    "distance_kilometers",
                    number(
                        "行程里程，km。列表 distance 为整公里；若详情里程表差值有效且落在同一整公里区间，使用差值保留小数，否则保留列表值。",
                    ),
                ),
                ("duration_minutes", integer("行程时长，分钟。")),
                ("start_location", reference("VehicleTripLocation")),
                ("end_location", reference("VehicleTripLocation")),
                (
                    "average_speed_kph",
                    opt(number("平均速度。"), "平均速度，km/h。"),
                ),
                (
                    "average_energy_consumption_kwh_per_100km",
                    opt(
                        number("百公里能耗。"),
                        "仅在详情提供可用 trip_eng 且距离>0 时计算，kWh/100km；缺失为 null。",
                    ),
                ),
                (
                    "energy_consumed_kwh",
                    opt(
                        number("能耗。"),
                        "详情 trip_eng 的实际行程耗电量，kWh；缺失为 null。",
                    ),
                ),
                (
                    "maximum_speed_kph",
                    opt(number("最高速度。"), "最高速度，km/h。"),
                ),
                (
                    "odometer_kilometers",
                    opt(number("累计里程。"), "行程时车辆里程表，km。"),
                ),
                (
                    "rapid_acceleration_count",
                    opt(integer("急加速次数。"), "急加速次数。"),
                ),
                (
                    "rapid_deceleration_count",
                    opt(integer("急减速次数。"), "急减速次数。"),
                ),
                (
                    "rapid_swerve_count",
                    opt(integer("急转弯次数。"), "急转弯次数。"),
                ),
                ("is_combined", boolean("是否为上游合并行程。")),
            ],
            None,
        ),
    );
    add(
        "VehicleTripPage",
        object(
            "数据库中已保存的行程分页结果。",
            &[
                ("items", array("VehicleTrip", "行程列表。")),
                ("has_more", boolean("数据库中是否有更早的行程。")),
                (
                    "next_query_time",
                    opt(integer("分页时间。"), "下一页 query_time，Unix 秒。"),
                ),
                (
                    "server_time",
                    opt(integer("上游时间。"), "数据库查询时为 null。"),
                ),
            ],
            None,
        ),
    );
    let actions = [
        VehicleAction::UnlockDoors,
        VehicleAction::UnlockStart,
        VehicleAction::Lock,
        VehicleAction::GuardOn,
        VehicleAction::GuardOff,
        VehicleAction::MirrorExpand,
        VehicleAction::Find,
        VehicleAction::FindStop,
        VehicleAction::AcOn,
        VehicleAction::AcOff,
        VehicleAction::SeatHeatOff,
    ];
    let names: Vec<Value> = actions
        .iter()
        .map(|action| serde_json::to_value(action).unwrap())
        .collect();
    let confirmations: Map<String, Value> = actions
        .iter()
        .map(|action| {
            (
                serde_json::to_value(action)
                    .unwrap()
                    .as_str()
                    .unwrap()
                    .to_owned(),
                json!(action.confirmation()),
            )
        })
        .collect();
    add(
        "VehicleAction",
        json!({"type":"string","enum":names,"description":"服务端支持的动作名称，不代表所有动作默认已启用。unlock-start 涉及启动授权，与 unlock-doors 不同。", "x-confirmations":confirmations}),
    );
    let mut create_swap_input = object(
        "一键换电下单输入。服务端拒绝坐标、车辆、车型、电池档位等额外字段。",
        &[
            (
                "station_id",
                json!({"type":"string","pattern":"^PS-NIO-[A-Za-z0-9_-]*$","maxLength":128,"description":"目标换电站 ID。"}),
            ),
            (
                "confirmation",
                json!({"type":"string","const":"CREATE SWAP ORDER","description":"必须精确匹配，表示用户确认创建真实订单。"}),
            ),
        ],
        Some(&["station_id", "confirmation"]),
    );
    create_swap_input["additionalProperties"] = json!(false);
    add("CreateSwapOrderInput", create_swap_input);
    add(
        "CreateSwapOrderOutcome",
        object(
            "完成站点定位查询、scan 预检和真实下单后的结果。上游创建响应可能暂时返回电池档位 0，requested_battery_cap_level 保留服务端实际请求值。",
            &[
                ("station_id", text("目标换电站 ID。")),
                ("latitude", number("从站点详情 location 解析出的纬度。")),
                ("longitude", number("从站点详情 location 解析出的经度。")),
                (
                    "scan_request_id",
                    opt(text("scan 请求 ID。"), "上游未返回时为 null。"),
                ),
                (
                    "request_id",
                    opt(text("创建订单请求 ID。"), "上游未返回时为 null。"),
                ),
                (
                    "server_time",
                    opt(
                        integer("创建响应服务端 Unix 毫秒时间。"),
                        "上游未返回时为 null。",
                    ),
                ),
                ("order_id", text("已创建的真实换电订单号。")),
                (
                    "requested_battery_cap_level",
                    integer("服务端配置并实际发送的目标电池档位。"),
                ),
                (
                    "battery_cap_level",
                    opt(integer("上游创建响应电池档位。"), "响应未给出时为 null。"),
                ),
                (
                    "target_battery_cap_level",
                    opt(integer("上游创建响应目标档位。"), "响应未给出时为 null。"),
                ),
                (
                    "ps_resource_model",
                    opt(text("换电站设备型号。"), "响应未给出时为 null。"),
                ),
            ],
            None,
        ),
    );
    let mut input = object(
        "单次车辆指令。只接受以下字段，不允许传入 PIN、Token、证书或其他未定义字段。",
        &[
            ("action", reference("VehicleAction")),
            (
                "confirmation",
                text("必须与 action 对应的确认文字完全一致，见 VehicleAction.x-confirmations。"),
            ),
            (
                "temperature",
                opt(
                    json!({"type":"number","minimum":16,"maximum":30}),
                    "仅 ac-on 可提供，范围 16…30℃；可省略，其他动作提供该参数会被拒绝。",
                ),
            ),
            (
                "recirculation",
                opt(
                    json!({"type":"integer","enum":[0,1]}),
                    "仅 ac-on 可提供，取值 0 或 1；其他动作提供该参数会被拒绝。",
                ),
            ),
            (
                "expand_mirrors",
                json!({"type":"boolean","default":false,"description":"仅 guard-on / guard-off 可追加展开后视镜；需要独立确认，不是解锁的副作用。"}),
            ),
            (
                "mirror_confirmation",
                opt(
                    text("后视镜确认。"),
                    "expand_mirrors=true 时必须为 EXPAND MIRRORS；不展开时不能提供该精确确认文字。",
                ),
            ),
        ],
        Some(&["action", "confirmation"]),
    );
    input["additionalProperties"] = json!(false);
    let mut conditions: Vec<Value> = actions
        .iter()
        .map(|action| {
            json!({
                "if":{"properties":{"action":{"const":action}},"required":["action"]},
                "then":{"properties":{"confirmation":{"const":action.confirmation()}}}
            })
        })
        .collect();
    conditions.push(json!({
        "if":{"properties":{"action":{"const":"ac-on"}},"required":["action"]},
        "else":{"properties":{"temperature":{"type":"null"},"recirculation":{"type":"null"}}}
    }));
    conditions.push(json!({
        "if":{"properties":{"expand_mirrors":{"const":true}},"required":["expand_mirrors"]},
        "then":{"properties":{"action":{"enum":["guard-on","guard-off"]},"mirror_confirmation":{"const":"EXPAND MIRRORS"}},"required":["mirror_confirmation"]}
    }));
    conditions.push(json!({
        "if":{"properties":{"mirror_confirmation":{"const":"EXPAND MIRRORS"}},"required":["mirror_confirmation"]},
        "then":{"properties":{"expand_mirrors":{"const":true}},"required":["expand_mirrors"]}
    }));
    input["allOf"] = json!(conditions);
    add("ActionInput", input);
    add(
        "ActionOutcome",
        object(
            "车辆指令结果；accepted_unverified 不是已确认成功。",
            &[
                ("action", reference("VehicleAction")),
                (
                    "status",
                    text("already_desired、verified 或 accepted_unverified。"),
                ),
                (
                    "verified",
                    boolean("服务端是否确认目标状态或已处于目标状态。"),
                ),
                (
                    "mirrors",
                    opt(
                        text("后视镜结果。"),
                        "追加后视镜动作的结果，无追加动作时为 null。",
                    ),
                ),
            ],
            None,
        ),
    );
    add(
        "UpstreamVehicleStatus",
        upstream(
            "NIO 车辆状态透传 JSON。仅约束信封，不承诺固定字段集合；调用方需检查 result_code。",
        ),
    );
    add(
        "UpstreamWidgetInfo",
        upstream("NIO Widget 信息透传 JSON，车辆状态通常位于 data.status。"),
    );
    Value::Object(schemas)
}

fn page(item: &str, offset: bool) -> Value {
    let mut fields = vec![
        ("items", array(item, "返回的数据项。")),
        ("limit", integer("本次请求经夹取后的条数上限。")),
    ];
    if offset {
        fields.push(("offset", integer("分页偏移。")));
    }
    object("分页集合。", &fields, None)
}

fn upstream(description: &str) -> Value {
    object(
        description,
        &[
            (
                "result_code",
                text("NIO 业务结果码，例如 success；HTTP 200 不自动等于业务成功。"),
            ),
            (
                "server_time",
                json!({"description":"上游时间，字段形状由 NIO 协议决定。"}),
            ),
            (
                "data",
                json!({"description":"原样透传的上游 data，允许任意 JSON 类型与字段。"}),
            ),
        ],
        Some(&[]),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeSet;

    #[test]
    fn every_http_route_is_documented_with_correct_method() {
        let spec = document();
        let mut expected = BTreeSet::new();
        for route in include_str!("api.rs").split(".route(").skip(1) {
            let path = route.split('"').nth(1).unwrap();
            let method = if route.contains("web::post()") {
                "post"
            } else {
                "get"
            };
            expected.insert((path.to_owned(), method.to_owned()));
        }
        let actual: BTreeSet<_> = spec["paths"]
            .as_object()
            .unwrap()
            .iter()
            .flat_map(|(path, methods)| {
                methods
                    .as_object()
                    .unwrap()
                    .keys()
                    .map(move |method| (path.clone(), method.clone()))
            })
            .collect();
        assert_eq!(actual, expected);
    }

    #[test]
    fn documented_model_properties_match_rust_fields() {
        let spec = document();
        let source = include_str!("models.rs");
        for name in [
            "BatteryObservation",
            "StationFeeItem",
            "StationLiveStatus",
            "SwapStation",
            "SwapStationPage",
            "SwapPaymentItem",
            "ImportedBattery",
            "ImportedOrder",
            "SwapEvent",
            "SwapEventPage",
            "ActiveServiceOrder",
            "ActiveServiceOrderPage",
            "PollOutcome",
            "ServiceStatus",
            "PollRunSummary",
            "VehicleSnapshot",
            "VehicleSnapshotPage",
            "VehicleChargingSample",
            "VehicleChargingSamplePage",
            "VehicleChargingSession",
            "VehicleChargingSessionPage",
            "VehicleTripLocation",
            "VehicleTrip",
            "VehicleTripPage",
        ] {
            let marker = format!("pub struct {name} {{");
            let body = source
                .split_once(&marker)
                .unwrap()
                .1
                .split_once('}')
                .unwrap()
                .0;
            let rust_fields: BTreeSet<_> = body
                .lines()
                .filter_map(|line| {
                    line.trim()
                        .strip_prefix("pub ")
                        .and_then(|field| field.split_once(':'))
                        .map(|(name, _)| name.trim())
                })
                .collect();
            let documented_fields: BTreeSet<_> = spec["components"]["schemas"][name]["properties"]
                .as_object()
                .unwrap()
                .keys()
                .map(String::as_str)
                .collect();
            assert_eq!(
                rust_fields, documented_fields,
                "schema fields changed for {name}"
            );
        }
        let control = include_str!("vehicle_control.rs");
        for name in ["ActionInput", "ActionOutcome"] {
            let marker = format!("pub struct {name} {{");
            let body = control
                .split_once(&marker)
                .unwrap()
                .1
                .split_once('}')
                .unwrap()
                .0;
            let rust_fields: BTreeSet<_> = body
                .lines()
                .filter_map(|line| {
                    line.trim()
                        .strip_prefix("pub ")
                        .and_then(|field| field.split_once(':'))
                        .map(|(name, _)| name.trim())
                })
                .collect();
            let documented_fields: BTreeSet<_> = spec["components"]["schemas"][name]["properties"]
                .as_object()
                .unwrap()
                .keys()
                .map(String::as_str)
                .collect();
            assert_eq!(
                rust_fields, documented_fields,
                "schema fields changed for {name}"
            );
        }
    }

    #[test]
    fn schema_references_resolve_and_operation_ids_are_unique() {
        let spec = document();
        fn walk(value: &Value, root: &Value) {
            match value {
                Value::Object(fields) => {
                    if let Some(reference) = fields.get("$ref").and_then(Value::as_str) {
                        assert!(
                            root.pointer(reference.strip_prefix('#').unwrap()).is_some(),
                            "missing {reference}"
                        );
                    }
                    for value in fields.values() {
                        walk(value, root);
                    }
                }
                Value::Array(items) => {
                    for value in items {
                        walk(value, root);
                    }
                }
                _ => {}
            }
        }
        walk(&spec, &spec);
        let mut ids = BTreeSet::new();
        for path in spec["paths"].as_object().unwrap().values() {
            for op in path.as_object().unwrap().values() {
                assert!(ids.insert(op["operationId"].as_str().unwrap()));
            }
        }
    }

    #[test]
    fn existing_public_routes_and_dual_key_control_contract_are_preserved() {
        let spec = document();
        for path in [
            "/healthz",
            "/api/v1/status",
            "/api/v1/swaps",
            "/api/v1/swaps/{id}",
        ] {
            assert_eq!(spec["paths"][path]["get"]["security"], json!([]));
        }
        let control = &spec["paths"]["/api/v1/vehicle/action"]["post"];
        for requirement in control["security"].as_array().unwrap() {
            assert!(requirement.get("VehicleControlKey").is_some());
            assert!(
                requirement.get("BearerAuth").is_some() || requirement.get("ApiKeyAuth").is_some()
            );
        }
        let swap_order = &spec["paths"]["/api/v1/swap-orders"]["post"];
        assert_eq!(swap_order["x-side-effects"], "creates-real-swap-order");
        assert_eq!(swap_order["x-no-automatic-retry"], true);
        for requirement in swap_order["security"].as_array().unwrap() {
            assert!(requirement.get("VehicleControlKey").is_some());
        }
        assert_eq!(
            spec["components"]["schemas"]["CreateSwapOrderInput"]["properties"]
                .as_object()
                .unwrap()
                .keys()
                .cloned()
                .collect::<BTreeSet<_>>(),
            BTreeSet::from(["confirmation".to_owned(), "station_id".to_owned(),])
        );
        assert_eq!(
            spec["components"]["schemas"]["ActionInput"]["additionalProperties"],
            false
        );
    }

    #[test]
    fn exported_json_matches_the_current_generator() {
        let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("openapi.json");
        let saved: Value = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
        assert_eq!(
            saved,
            document(),
            "run cargo run -- export-openapi after API documentation changes"
        );
    }
}
