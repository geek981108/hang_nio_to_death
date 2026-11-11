//! Stateless Streamable HTTP MCP endpoint for the backend API, excluding vehicle control.
use actix_web::{HttpRequest, HttpResponse, ResponseError, web};
use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use super::{AppState, authorize};
use crate::models::VehicleTripTrackPoint;

const MODERN: &str = "2026-07-28";
const LEGACY: &str = "2025-11-25";
/// How long a modern client may cache `tools/list` and `server/discover`.
/// Long enough to avoid re-listing on every call, short enough that a deployed
/// tool-schema change reaches connected clients without re-authorization.
const LIST_TTL_MS: u64 = 60_000;

struct ToolSpec {
    name: &'static str,
    description: &'static str,
    method: &'static str,
    path: &'static str,
    query_keys: &'static [&'static str],
    body: bool,
}

const TOOLS: &[ToolSpec] = &[
    ToolSpec {
        name: "nio_health",
        description: "Backend health check.",
        method: "GET",
        path: "/healthz",
        query_keys: &[],
        body: false,
    },
    ToolSpec {
        name: "nio_status",
        description: "Polling and backend status.",
        method: "GET",
        path: "/api/v1/status",
        query_keys: &[],
        body: false,
    },
    ToolSpec {
        name: "nio_swaps",
        description: "List swap events; query supports limit, offset and include_candidates.",
        method: "GET",
        path: "/api/v1/swaps",
        query_keys: &["limit", "offset", "include_candidates"],
        body: false,
    },
    ToolSpec {
        name: "nio_swap",
        description: "Get one swap event by id.",
        method: "GET",
        path: "/api/v1/swaps/{id}",
        query_keys: &[],
        body: false,
    },
    ToolSpec {
        name: "nio_energy_stats",
        description: "Aggregate swap costs, counts and swap/charge energy in a UTC interval. Query requires ISO-8601 from and to.",
        method: "GET",
        path: "/api/v1/energy/stats",
        query_keys: &["from", "to"],
        body: false,
    },
    ToolSpec {
        name: "nio_active_orders",
        description: "List up to 20 active service orders, including queue_number, vehicles_ahead, estimated_wait_minutes, estimated_wait_source and queue_updated_at when known. Null fields mean unknown.",
        method: "GET",
        path: "/api/v1/orders/active",
        query_keys: &[],
        body: false,
    },
    ToolSpec {
        name: "nio_create_swap_order",
        description: "Create one real swap order. Requires X-Vehicle-Control-Key on this MCP request and the exact confirmation text in body. Never retry automatically.",
        method: "POST",
        path: "/api/v1/swap-orders",
        query_keys: &[],
        body: true,
    },
    ToolSpec {
        name: "nio_available_coupons",
        description: "List available CN account coupons; query supports limit and offset. amount counts merged entries, while coupon_groups[].count and page_coupon_count count actual coupons; total_coupon_count is null until all entries fit on the first page. face_value_cny is parsed only from explicit denomination text.",
        method: "GET",
        path: "/api/v1/coupons/available",
        query_keys: &["limit", "offset"],
        body: false,
    },
    ToolSpec {
        name: "nio_check_in",
        description: "Manually attempt CN daily check-in. The server schedules one random Beijing-time attempt each day unless NIO_DAILY_CHECKIN_ENABLED=false; a prior attempt returns 409. Connection failures before the request is sent are retried up to 3 times per day; failures that may have reached upstream are never retried.",
        method: "POST",
        path: "/api/v1/check-in",
        query_keys: &[],
        body: false,
    },
    ToolSpec {
        name: "nio_stations",
        description: "List known swap stations; query supports limit, offset and q.",
        method: "GET",
        path: "/api/v1/stations",
        query_keys: &["limit", "offset", "q"],
        body: false,
    },
    ToolSpec {
        name: "nio_search_stations",
        description: "Search stations locally, then remotely if needed; query requires name.",
        method: "GET",
        path: "/api/v1/stations/search",
        query_keys: &["name"],
        body: false,
    },
    ToolSpec {
        name: "nio_nearby_swap_stations",
        description: "Read-only NIO CN map viewport lookup for power-swap stations near supplied coordinates. Returns only PS station pins and straight-line distances; upstream viewport results are not a radius-complete list. Does not echo the input coordinates.",
        method: "POST",
        path: "/api/v1/stations/nearby",
        query_keys: &[],
        body: true,
    },
    ToolSpec {
        name: "nio_station",
        description: "Get a station by id.",
        method: "GET",
        path: "/api/v1/stations/{id}",
        query_keys: &[],
        body: false,
    },
    ToolSpec {
        name: "nio_station_live",
        description: "Fetch one read-only station detail by id. Returns current_fees and every fee_period with units/currency/notices/timezone if supplied, queue observations, and per-slot charging countdown; estimated charge completion does not guarantee swap availability.",
        method: "GET",
        path: "/api/v1/stations/{id}/live",
        query_keys: &[],
        body: false,
    },
    ToolSpec {
        name: "nio_straight_line_energy",
        description: "Read the persisted daily latest-100-km energy cache and calculate geodesic straight-line distance to a station. For a station absent from the known directory, supply station_latitude and station_longitude from nio_nearby_swap_stations; these caller coordinates are range-checked, not independently identity-verified, and nothing is written. The tool never fetches trips. The cache reports computed_at, stale status, completeness, missing energy, proportional boundary estimation and failures. Vehicle coordinates are never echoed; no road route, traffic or tolls are included.",
        method: "POST",
        path: "/api/v1/stations/{id}/straight-line-energy",
        query_keys: &[],
        body: true,
    },
    ToolSpec {
        name: "nio_vehicle_status",
        description: "Read current vehicle status; this can save an observation.",
        method: "GET",
        path: "/api/v1/vehicle/status",
        query_keys: &[],
        body: false,
    },
    ToolSpec {
        name: "nio_vehicle_history",
        description: "List saved vehicle location and status samples; query supports limit.",
        method: "GET",
        path: "/api/v1/vehicle/history",
        query_keys: &["limit"],
        body: false,
    },
    ToolSpec {
        name: "nio_charging_current",
        description: "Get samples from the latest charging session.",
        method: "GET",
        path: "/api/v1/vehicle/charging/current",
        query_keys: &[],
        body: false,
    },
    ToolSpec {
        name: "nio_charging_sessions",
        description: "List charging session summaries; query supports limit.",
        method: "GET",
        path: "/api/v1/vehicle/charging/sessions",
        query_keys: &["limit"],
        body: false,
    },
    ToolSpec {
        name: "nio_charging_session",
        description: "Get samples for a charging session by id.",
        method: "GET",
        path: "/api/v1/vehicle/charging/sessions/{id}",
        query_keys: &[],
        body: false,
    },
    ToolSpec {
        name: "nio_trips",
        description: "Read persisted vehicle trips immediately and queue an asynchronous upstream sync; query supports count and query_time. Re-query later to see updates. Each trip carries a track with its source: sampled means the App's own position samples inside that journey's window (no per-point speed or power), official means the upstream journey track. Tracks are only attached when track=true is passed, and are large; request a small count when only the route is needed.",
        method: "GET",
        path: "/api/v1/vehicle/trips",
        query_keys: &["count", "query_time", "track"],
        body: false,
    },
    ToolSpec {
        name: "nio_widget_info",
        description: "Read widget vehicle information.",
        method: "GET",
        path: "/api/v1/vehicle/widget-info",
        query_keys: &[],
        body: false,
    },
    ToolSpec {
        name: "nio_poll",
        description: "Trigger one station poll; may contact upstream and write observations.",
        method: "POST",
        path: "/api/v1/poll",
        query_keys: &[],
        body: false,
    },
    ToolSpec {
        name: "nio_import_order",
        description: "Import one historical swap order. Supply the normal REST request in body; writes local history.",
        method: "POST",
        path: "/api/v1/orders/import",
        query_keys: &[],
        body: true,
    },
];

fn server_meta() -> Value {
    json!({"io.modelcontextprotocol/serverInfo": {"name":"nio-swap-history-backend","version":env!("CARGO_PKG_VERSION")}})
}

fn rpc_result(id: Value, result: Value) -> HttpResponse {
    HttpResponse::Ok().json(json!({"jsonrpc":"2.0","id":id,"result":result}))
}

fn rpc_error(id: Value, code: i64, message: &str) -> HttpResponse {
    HttpResponse::BadRequest()
        .json(json!({"jsonrpc":"2.0","id":id,"error":{"code":code,"message":message}}))
}

fn tool_list(modern: bool) -> Value {
    let tools: Vec<Value> = TOOLS.iter().map(|spec| {
        let mut properties = serde_json::Map::new();
        let mut required = Vec::new();
        if spec.path.contains("{id}") {
            let id_schema = if spec.name == "nio_straight_line_energy" {
                json!({"type":"string","pattern":"^PS-NIO-[A-Za-z0-9_-]+$","maxLength":128,
                    "description":"Power-swap station ID; when unknown to the directory, supply station coordinates in body."})
            } else {
                json!({"type":"string","description":"Stable record identifier."})
            };
            properties.insert("id".into(), id_schema);
            required.push("id");
        }
        if !spec.query_keys.is_empty() {
            let mut query_properties = serde_json::Map::new();
            for key in spec.query_keys {
                let kind = if matches!(*key, "limit" | "offset" | "count" | "query_time") { "integer" }
                    else if matches!(*key, "include_candidates" | "track") { "boolean" } else { "string" };
                query_properties.insert((*key).into(), json!({"type":kind}));
            }
            let query_required: &[&str] = match spec.name {
                "nio_energy_stats" => &["from", "to"],
                "nio_search_stations" => &["name"],
                _ => &[],
            };
            properties.insert("query".into(), json!({"type":"object","properties":query_properties,
                "required":query_required,"additionalProperties":false}));
            if !query_required.is_empty() { required.push("query"); }
        }
        if spec.body {
            let schema = if spec.name == "nio_create_swap_order" {
                json!({"type":"object","properties":{
                    "station_id":{"type":"string","pattern":"^PS-NIO-[A-Za-z0-9_-]+$"},
                    "confirmation":{"type":"string","const":"CREATE SWAP ORDER"}
                },"required":["station_id","confirmation"],"additionalProperties":false})
            } else if spec.name == "nio_straight_line_energy" {
                json!({"type":"object","properties":{
                    "latitude":{"type":"number","minimum":-90,"maximum":90,"description":"Vehicle latitude; used only for calculation, never echoed."},
                    "longitude":{"type":"number","minimum":-180,"maximum":180,"description":"Vehicle longitude; used only for calculation, never echoed."},
                    "station_latitude":{"type":"number","minimum":-90,"maximum":90,"description":"Optional station latitude from nio_nearby_swap_stations; required together with station_longitude when the station is absent from the known directory."},
                    "station_longitude":{"type":"number","minimum":-180,"maximum":180,"description":"Optional station longitude from nio_nearby_swap_stations; required together with station_latitude when the station is absent from the known directory."}
                },"required":["latitude","longitude"],"dependentRequired":{
                    "station_latitude":["station_longitude"],
                    "station_longitude":["station_latitude"]
                },"additionalProperties":false})
            } else if spec.name == "nio_nearby_swap_stations" {
                json!({"type":"object","properties":{
                    "latitude":{"type":"number","minimum":-90,"maximum":90,"description":"Search center latitude; not echoed."},
                    "longitude":{"type":"number","minimum":-180,"maximum":180,"description":"Search center longitude; not echoed."}
                },"required":["latitude","longitude"],"additionalProperties":false})
            } else {
                json!({"type":"object","description":"REST import-order JSON body."})
            };
            properties.insert("body".into(), schema);
            required.push("body");
        }
        let read_only = (spec.method == "GET" && spec.name != "nio_vehicle_status")
            || matches!(spec.name, "nio_straight_line_energy" | "nio_nearby_swap_stations");
        let open_world = matches!(spec.name, "nio_station_live" | "nio_straight_line_energy" | "nio_nearby_swap_stations" | "nio_search_stations" | "nio_trips" | "nio_available_coupons");
        json!({"name":spec.name,"description":spec.description,
            "inputSchema":{"type":"object","properties":properties,"required":required,"additionalProperties":false},
            "annotations":{"readOnlyHint":read_only,
                "destructiveHint":matches!(spec.name, "nio_create_swap_order" | "nio_check_in"),
                "idempotentHint":read_only,
                "openWorldHint":open_world}})
    }).collect();
    if modern {
        json!({"resultType":"complete","tools":tools,"ttlMs":LIST_TTL_MS,"cacheScope":"private","_meta":server_meta()})
    } else {
        json!({"tools":tools})
    }
}

/// The tool list is a deployment artifact: an intermediary must never cache it
/// on top of the explicit `ttlMs` hint, or a schema update stays invisible long
/// after the server starts serving it.
pub async fn handle(
    state: web::Data<AppState>,
    request: HttpRequest,
    input: web::Json<Value>,
) -> HttpResponse {
    let mut response = handle_inner(state, request, input).await;
    response.headers_mut().insert(
        actix_web::http::header::CACHE_CONTROL,
        actix_web::http::header::HeaderValue::from_static("no-store"),
    );
    response
}

async fn handle_inner(
    state: web::Data<AppState>,
    request: HttpRequest,
    input: web::Json<Value>,
) -> HttpResponse {
    if authorize(&state, &request).is_err() {
        let bearer = request
            .headers()
            .get(actix_web::http::header::AUTHORIZATION)
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.strip_prefix("Bearer "));
        let valid = if let (Some(token), Some(oauth)) = (bearer, state.mcp_oauth.as_ref()) {
            oauth.valid_access(token).await
        } else {
            false
        };
        if !valid {
            return state.mcp_oauth.as_ref().map_or_else(
                || super::ApiError::unauthorized().error_response(),
                |oauth| oauth.challenge(),
            );
        }
    }
    // A cross-origin browser must never be able to drive local or remote MCP tools.
    if request.headers().contains_key("origin") {
        return HttpResponse::Forbidden().finish();
    }
    let message = input.into_inner();
    let id = message.get("id").cloned().unwrap_or(Value::Null);
    if message.get("jsonrpc").and_then(Value::as_str) != Some("2.0") {
        return rpc_error(id, -32600, "invalid JSON-RPC request");
    }
    let Some(method) = message.get("method").and_then(Value::as_str) else {
        return rpc_error(id, -32600, "missing method");
    };
    let version = request
        .headers()
        .get("mcp-protocol-version")
        .and_then(|v| v.to_str().ok());
    let modern = version == Some(MODERN);
    if modern {
        let body_version = message
            .pointer("/params/_meta/io.modelcontextprotocol~1protocolVersion")
            .and_then(Value::as_str);
        let capabilities =
            message.pointer("/params/_meta/io.modelcontextprotocol~1clientCapabilities");
        if body_version != Some(MODERN) || !capabilities.is_some_and(Value::is_object) {
            return rpc_error(id, -32602, "missing modern MCP request metadata");
        }
        let header_method = request
            .headers()
            .get("mcp-method")
            .and_then(|v| v.to_str().ok());
        if header_method != Some(method) {
            return rpc_error(id, -32020, "Mcp-Method header mismatch");
        }
        if method == "tools/call" {
            let name = message.pointer("/params/name").and_then(Value::as_str);
            let header_name = request
                .headers()
                .get("mcp-name")
                .and_then(|v| v.to_str().ok());
            if name.is_none() || header_name != name {
                return rpc_error(id, -32020, "Mcp-Name header mismatch");
            }
        }
    } else if version.is_some_and(|v| v != LEGACY) {
        return rpc_error(id, -32022, "unsupported MCP protocol version");
    }
    match method {
        "server/discover" if modern => rpc_result(
            id,
            json!({
                "resultType":"complete","supportedVersions":[MODERN,LEGACY],
                "capabilities":{"tools":{}},"instructions":"NIO history, vehicle data, coupons, daily check-in and swap orders. Vehicle control is unavailable. Check-in retries only connection failures before the request is sent; swap-order creation must never be retried automatically. Creating a swap order also requires X-Vehicle-Control-Key.",
                "ttlMs":LIST_TTL_MS,"cacheScope":"private","_meta":server_meta()
            }),
        ),
        "initialize" if !modern => rpc_result(
            id,
            json!({
                "protocolVersion":LEGACY,"capabilities":{"tools":{}},
                "serverInfo":{"name":"nio-swap-history-backend","version":env!("CARGO_PKG_VERSION")},
                "instructions":"NIO history, stations, vehicle data, coupons, daily check-in and swap orders. Vehicle control is unavailable. Check-in retries only connection failures before the request is sent; swap orders must never be retried automatically and also require X-Vehicle-Control-Key."
            }),
        ),
        "notifications/initialized" if !modern => HttpResponse::Accepted().finish(),
        "tools/list" => rpc_result(id, tool_list(modern)),
        "tools/call" => call_tool(&state, &request, id, &message, modern).await,
        _ => rpc_error(id, -32601, "method not found"),
    }
}

async fn call_tool(
    state: &AppState,
    request: &HttpRequest,
    id: Value,
    message: &Value,
    modern: bool,
) -> HttpResponse {
    let Some(name) = message.pointer("/params/name").and_then(Value::as_str) else {
        return rpc_error(id, -32602, "missing tool name");
    };
    let Some(spec) = TOOLS.iter().find(|tool| tool.name == name) else {
        return rpc_error(id, -32602, "unknown tool");
    };
    let args = message
        .pointer("/params/arguments")
        .cloned()
        .unwrap_or_else(|| json!({}));
    let Some(args) = args.as_object() else {
        return rpc_error(id, -32602, "arguments must be an object");
    };
    // `track` is a MCP-only switch: it decides whether this layer enriches the
    // proxied trips page, and is never forwarded to the backend.
    let wants_track = if spec.name == "nio_trips" {
        match track_requested(args) {
            Ok(requested) => requested,
            Err(message) => return rpc_error(id, -32602, message),
        }
    } else {
        false
    };
    let mut path = spec.path.to_owned();
    if spec.path.contains("{id}") {
        let Some(record_id) = args.get("id").and_then(Value::as_str) else {
            return rpc_error(id, -32602, "id is required");
        };
        if record_id.is_empty()
            || record_id.len() > 256
            || !record_id
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b':'))
        {
            return rpc_error(id, -32602, "invalid id");
        }
        path = path.replace("{id}", record_id);
    }
    let mut url = match url::Url::parse(&format!("{}{}", state.mcp_origin, path)) {
        Ok(url) => url,
        Err(_) => return rpc_error(id, -32603, "internal URL error"),
    };
    if let Some(query) = args.get("query") {
        let Some(query) = query.as_object() else {
            return rpc_error(id, -32602, "query must be an object");
        };
        if query
            .keys()
            .any(|key| !spec.query_keys.contains(&key.as_str()))
        {
            return rpc_error(id, -32602, "unknown query parameter");
        }
        let mut pairs = url.query_pairs_mut();
        for (key, value) in query {
            if spec.name == "nio_trips" && key == "track" {
                continue;
            }
            let text = match value {
                Value::String(s) => s.clone(),
                Value::Number(n) => n.to_string(),
                Value::Bool(b) => b.to_string(),
                _ => return rpc_error(id, -32602, "query values must be scalar"),
            };
            pairs.append_pair(key, &text);
        }
    }
    let method = if spec.method == "POST" {
        reqwest::Method::POST
    } else {
        reqwest::Method::GET
    };
    let mut upstream = state.mcp_client.request(method, url);
    if let Some(api_key) = &state.api_key {
        upstream = upstream.header("x-api-key", api_key.as_ref());
    }
    if spec.name == "nio_create_swap_order" {
        let Some(control_key) = request
            .headers()
            .get("x-vehicle-control-key")
            .and_then(|value| value.to_str().ok())
        else {
            return tool_error(id, "X-Vehicle-Control-Key header is required", modern);
        };
        upstream = upstream.header("x-vehicle-control-key", control_key);
    }
    if spec.body {
        let Some(body) = args.get("body").filter(|value| value.is_object()) else {
            return rpc_error(id, -32602, "body is required");
        };
        upstream = upstream.json(body);
    } else if args.contains_key("body") {
        return rpc_error(id, -32602, "body is not accepted for this tool");
    }
    let response = match upstream.send().await {
        Ok(response) => response,
        Err(_) => return tool_error(id, "backend request failed", modern),
    };
    let success = response.status().is_success();
    let status = response.status();
    let value = match response.json::<Value>().await {
        Ok(value) => value,
        Err(_) => return tool_error(id, "backend returned non-JSON", modern),
    };
    let value = if success && wants_track {
        attach_trip_tracks(state, value).await
    } else {
        value
    };
    let content = if success {
        value.to_string()
    } else {
        format!("HTTP {status}: {value}")
    };
    let mut result = json!({"content":[{"type":"text","text":content}],"isError":!success});
    if modern {
        result["resultType"] = json!("complete");
        result["_meta"] = server_meta();
    }
    rpc_result(id, result)
}

/// `track` defaults to false so a plain trips read stays small. Booleans and
/// the "true"/"false" strings are both accepted, matching how query values are
/// otherwise relaxed.
fn track_requested(args: &serde_json::Map<String, Value>) -> Result<bool, &'static str> {
    let Some(value) = args.get("query").and_then(|query| query.get("track")) else {
        return Ok(false);
    };
    match value {
        Value::Bool(requested) => Ok(*requested),
        Value::String(text) if text == "true" => Ok(true),
        Value::String(text) if text == "false" => Ok(false),
        _ => Err("track must be a boolean"),
    }
}

/// The App's own samples win only when they cover the journey from end to end
/// without a long gap. Otherwise the complete official upstream track wins.
fn sampled_track_has_full_coverage(
    sampled: &[VehicleTripTrackPoint],
    started_at: DateTime<Utc>,
    ended_at: DateTime<Utc>,
) -> bool {
    let duration = (ended_at - started_at).num_seconds();
    if sampled.len() < 2 || duration <= 0 {
        return false;
    }
    let edge_tolerance = (duration / 10).clamp(30, 120);
    let covers_edges = sampled.first().is_some_and(|point| {
        point.sampled_at <= started_at + chrono::Duration::seconds(edge_tolerance)
    }) && sampled.last().is_some_and(|point| {
        point.sampled_at >= ended_at - chrono::Duration::seconds(edge_tolerance)
    });
    let has_no_long_gap = sampled
        .windows(2)
        .all(|pair| (pair[1].sampled_at - pair[0].sampled_at).num_seconds() <= 60);
    covers_edges && has_no_long_gap
}

fn pick_track(
    sampled: Vec<VehicleTripTrackPoint>,
    official: Vec<VehicleTripTrackPoint>,
    started_at: DateTime<Utc>,
    ended_at: DateTime<Utc>,
) -> Option<(&'static str, Vec<VehicleTripTrackPoint>)> {
    if sampled_track_has_full_coverage(&sampled, started_at, ended_at) {
        Some(("sampled", sampled))
    } else if !official.is_empty() {
        Some(("official", official))
    } else if !sampled.is_empty() {
        // A partial observed route is still better than no route when upstream
        // has no official track, but it must not displace a complete source.
        Some(("sampled", sampled))
    } else {
        None
    }
}

/// Attach `track` to each trip in a `nio_trips` result. A trip with neither
/// source keeps no track field at all rather than an empty one.
async fn attach_trip_tracks(state: &AppState, mut page: Value) -> Value {
    let Some(vehicle) = state.vehicle.as_ref() else {
        return page;
    };
    let vehicle_id = vehicle.vehicle_id().to_owned();
    let journeys = page
        .get("items")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .enumerate()
                .filter_map(|(index, item)| {
                    let id = item.get("id")?.as_str()?.to_owned();
                    let started_at = item
                        .get("started_at")?
                        .as_str()?
                        .parse::<DateTime<Utc>>()
                        .ok()?;
                    let ended_at = item
                        .get("ended_at")?
                        .as_str()?
                        .parse::<DateTime<Utc>>()
                        .ok()?;
                    Some((index, id, started_at, ended_at))
                })
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    let mut tracks = Vec::new();
    for (index, journey_id, started_at, ended_at) in journeys {
        let sampled = match state
            .store
            .vehicle_trip_sampled_points(&vehicle_id, &journey_id)
            .await
        {
            Ok(points) => points,
            Err(error) => {
                tracing::warn!(%error, journey_id, "failed to read sampled trip positions");
                Vec::new()
            }
        };
        let official = if !sampled_track_has_full_coverage(&sampled, started_at, ended_at) {
            match state
                .store
                .vehicle_trip_track(&vehicle_id, &journey_id)
                .await
            {
                Ok(points) => points,
                Err(error) => {
                    tracing::warn!(%error, journey_id, "failed to read official trip track");
                    Vec::new()
                }
            }
        } else {
            Vec::new()
        };
        if let Some(picked) = pick_track(sampled, official, started_at, ended_at) {
            tracks.push((index, picked));
        }
    }
    for (index, (source, points)) in tracks {
        if let Some(item) = page.get_mut("items").and_then(|items| items.get_mut(index))
            && let Some(object) = item.as_object_mut()
        {
            object.insert(
                "track".to_owned(),
                json!({"source": source, "points": points}),
            );
        }
    }
    page
}

fn tool_error(id: Value, message: &str, modern: bool) -> HttpResponse {
    let mut result = json!({"content":[{"type":"text","text":message}],"isError":true});
    if modern {
        result["resultType"] = json!("complete");
        result["_meta"] = server_meta();
    }
    rpc_result(id, result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{TimeZone, Utc};

    fn point(minute: u32) -> VehicleTripTrackPoint {
        VehicleTripTrackPoint {
            sampled_at: Utc.with_ymd_and_hms(2026, 11, 10, 5, minute, 0).unwrap(),
            latitude: 39.0,
            longitude: 117.0,
            speed_kph: None,
            power_consumption: None,
            np_status: None,
        }
    }

    /// The connector only learns about `track` through `tools/list`, so the
    /// schema path is pinned here.
    #[test]
    fn tools_list_exposes_track_as_a_boolean_on_trips() {
        let list = tool_list(true);
        assert_eq!(list["ttlMs"], json!(LIST_TTL_MS));
        let trips = list["tools"]
            .as_array()
            .unwrap()
            .iter()
            .find(|tool| tool["name"] == "nio_trips")
            .expect("nio_trips must be exposed");
        assert_eq!(
            trips["inputSchema"]["properties"]["query"]["properties"]["track"],
            json!({"type": "boolean"})
        );
        assert!(
            trips["description"]
                .as_str()
                .unwrap()
                .contains("track=true")
        );
    }

    #[test]
    fn track_flag_defaults_to_off_and_accepts_boolean_or_text() {
        let parse = |value: Value| track_requested(value.as_object().unwrap()).map_err(|_| ());
        assert_eq!(parse(json!({})), Ok(false));
        assert_eq!(parse(json!({"query": {}})), Ok(false));
        assert_eq!(parse(json!({"query": {"track": true}})), Ok(true));
        assert_eq!(parse(json!({"query": {"track": false}})), Ok(false));
        assert_eq!(parse(json!({"query": {"track": "true"}})), Ok(true));
        assert_eq!(parse(json!({"query": {"track": "false"}})), Ok(false));
        assert!(parse(json!({"query": {"track": 1}})).is_err());
        assert!(parse(json!({"query": {"track": "yes"}})).is_err());
    }

    #[test]
    fn sampled_positions_win_and_official_track_is_the_fallback() {
        let started_at = Utc.with_ymd_and_hms(2026, 11, 10, 5, 0, 0).unwrap();
        let ended_at = Utc.with_ymd_and_hms(2026, 11, 10, 5, 2, 0).unwrap();
        assert_eq!(
            pick_track(
                vec![point(0), point(1), point(2)],
                vec![point(1)],
                started_at,
                ended_at
            ),
            Some(("sampled", vec![point(0), point(1), point(2)]))
        );
        assert_eq!(
            pick_track(
                vec![point(1)],
                vec![point(0), point(2)],
                started_at,
                ended_at
            ),
            Some(("official", vec![point(0), point(2)]))
        );
        assert_eq!(
            pick_track(Vec::new(), vec![point(1)], started_at, ended_at),
            Some(("official", vec![point(1)]))
        );
        assert_eq!(
            pick_track(vec![point(1)], Vec::new(), started_at, ended_at),
            Some(("sampled", vec![point(1)]))
        );
        assert_eq!(
            pick_track(Vec::new(), Vec::new(), started_at, ended_at),
            None
        );
    }
}
