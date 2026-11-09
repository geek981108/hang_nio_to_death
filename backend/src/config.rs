use std::{collections::HashMap, env, net::SocketAddr, time::Duration};

use thiserror::Error;

#[derive(Clone)]
pub struct Config {
    pub bind_addr: SocketAddr,
    pub database_url: String,
    pub poll_interval: Duration,
    pub vehicle_unlocked_poll_interval: Duration,
    pub vehicle_locked_poll_interval: Duration,
    pub post_swap_poll_count: u32,
    pub service_order_poll_interval: Duration,
    pub match_window: Duration,
    pub api_key: Option<String>,
    pub mcp_oauth_issuer: Option<String>,
    pub mcp_oauth_login_secret: Option<String>,
    pub station: Option<StationConfig>,
    pub station_template: Option<StationTemplateConfig>,
    pub vehicle: Option<VehicleConfig>,
    pub login_profile: Option<crate::nio_login::LoginProfile>,
    pub service_orders: Option<ServiceOrderConfig>,
}

#[derive(Clone, Debug)]
pub struct StationConfig {
    pub key: String,
    pub name: String,
    pub url: String,
    pub headers: HashMap<String, String>,
}

#[derive(Clone)]
pub struct VehicleConfig {
    pub bearer_token: String,
    pub account_id: Option<String>,
    pub vehicle_id: String,
    pub device_id: String,
    pub app_id: String,
    pub app_version: String,
    pub region: String,
    pub language: String,
    pub vin_code: Option<String>,
}

#[derive(Clone, Debug)]
pub struct ServiceOrderConfig {
    pub url: String,
    pub headers: HashMap<String, String>,
    pub vehicle_id: Option<String>,
    pub vin_code: Option<String>,
    pub station_template: Option<StationTemplateConfig>,
}

#[derive(Clone, Debug)]
pub struct StationTemplateConfig {
    pub url_template: String,
    pub headers: HashMap<String, String>,
}

#[derive(Debug, Error)]
pub enum ConfigError {
    #[error("{name} is invalid: {message}")]
    Invalid { name: &'static str, message: String },
    #[error("STATION_URL and STATION_HEADERS_JSON must be configured together")]
    PartialStation,
    #[error("NIO_BEARER_TOKEN, NIO_VEHICLE_ID and NIO_DEVICE_ID must be configured together")]
    PartialVehicle,
    #[error(
        "SERVICE_ORDER_URL is required when service-order headers or credentials are configured"
    )]
    PartialServiceOrders,
    #[error("API_KEY is required when BIND_ADDR is not loopback")]
    MissingExternalApiKey,
    #[error("MCP_OAUTH_ISSUER and MCP_OAUTH_LOGIN_SECRET must be configured together")]
    PartialMcpOAuth,
}

impl Config {
    pub fn from_env() -> Result<Self, ConfigError> {
        Self::from_overrides(&HashMap::new(), true)
    }

    pub fn from_overrides(
        overrides: &HashMap<String, String>,
        inherit_tenant_env: bool,
    ) -> Result<Self, ConfigError> {
        let get = |name: &str| -> Option<String> {
            overrides.get(name).cloned().or_else(|| {
                if inherit_tenant_env || !is_tenant_specific(name) {
                    env::var(name).ok()
                } else {
                    None
                }
            })
        };
        let non_empty = |name: &str| {
            get(name)
                .map(|s| s.trim().to_owned())
                .filter(|s| !s.is_empty())
        };
        let bind_addr = get("BIND_ADDR")
            .unwrap_or_else(|| "127.0.0.1:8080".to_owned())
            .parse::<SocketAddr>()
            .map_err(|error| ConfigError::Invalid {
                name: "BIND_ADDR",
                message: error.to_string(),
            })?;

        let database_url = get("DATABASE_URL")
            .unwrap_or_else(|| "postgres://localhost/nio_swap_history".to_owned());
        if !database_url.starts_with("postgres://") && !database_url.starts_with("postgresql://") {
            return Err(ConfigError::Invalid {
                name: "DATABASE_URL",
                message: "a PostgreSQL URL is required".to_owned(),
            });
        }
        let poll_interval = duration_from_env("POLL_INTERVAL_SECONDS", 60)?;
        let vehicle_unlocked_poll_interval =
            if env::var_os("VEHICLE_UNLOCKED_POLL_INTERVAL_SECONDS").is_some() {
                duration_from_env("VEHICLE_UNLOCKED_POLL_INTERVAL_SECONDS", 3)?
            } else {
                duration_from_env("VEHICLE_POLL_INTERVAL_SECONDS", 3)?
            };
        let vehicle_locked_poll_interval =
            duration_from_env("VEHICLE_LOCKED_POLL_INTERVAL_SECONDS", 20)?;
        let post_swap_poll_count = get("POST_SWAP_POLL_COUNT")
            .unwrap_or_else(|| "60".to_owned())
            .parse::<u32>()
            .map_err(|error| ConfigError::Invalid {
                name: "POST_SWAP_POLL_COUNT",
                message: error.to_string(),
            })?;
        let service_order_poll_interval =
            duration_from_env("SERVICE_ORDER_POLL_INTERVAL_SECONDS", 15)?;
        let match_window = duration_from_env("MATCH_WINDOW_SECONDS", 1_800)?;
        let api_key = non_empty("API_KEY");
        let (mcp_oauth_issuer, mcp_oauth_login_secret) = match (
            non_empty("MCP_OAUTH_ISSUER"),
            non_empty("MCP_OAUTH_LOGIN_SECRET"),
        ) {
            (None, None) => (None, None),
            (Some(issuer), Some(secret)) => {
                let url = url::Url::parse(&issuer).map_err(|error| ConfigError::Invalid {
                    name: "MCP_OAUTH_ISSUER",
                    message: error.to_string(),
                })?;
                if url.scheme() != "https"
                    || url.host_str().is_none()
                    || url.path() != "/"
                    || url.query().is_some()
                    || url.fragment().is_some()
                    || !url.username().is_empty()
                    || url.password().is_some()
                    || secret.len() < 32
                {
                    return Err(ConfigError::Invalid {
                        name: "MCP_OAUTH_ISSUER",
                        message: "use an HTTPS origin without a path and a login secret of at least 32 bytes".to_owned(),
                    });
                }
                (Some(url.origin().ascii_serialization()), Some(secret))
            }
            _ => return Err(ConfigError::PartialMcpOAuth),
        };

        if !bind_addr.ip().is_loopback() && api_key.is_none() {
            return Err(ConfigError::MissingExternalApiKey);
        }
        if mcp_oauth_issuer.is_some() && api_key.is_none() {
            return Err(ConfigError::Invalid {
                name: "MCP_OAUTH_ISSUER",
                message: "API_KEY is required when MCP OAuth is enabled".to_owned(),
            });
        }
        if mcp_oauth_login_secret.as_deref() == api_key.as_deref()
            && mcp_oauth_login_secret.is_some()
        {
            return Err(ConfigError::Invalid {
                name: "MCP_OAUTH_LOGIN_SECRET",
                message: "must differ from API_KEY".to_owned(),
            });
        }

        let station_url = non_empty("STATION_URL");
        let station_headers = non_empty("STATION_HEADERS_JSON");
        let station = match (station_url, station_headers) {
            (None, None) => None,
            (Some(url), Some(raw_headers)) => {
                if !url.starts_with("https://") {
                    return Err(ConfigError::Invalid {
                        name: "STATION_URL",
                        message: "only HTTPS endpoints are accepted".to_owned(),
                    });
                }
                let headers = serde_json::from_str::<HashMap<String, String>>(&raw_headers)
                    .map_err(|error| ConfigError::Invalid {
                        name: "STATION_HEADERS_JSON",
                        message: error.to_string(),
                    })?;
                Some(StationConfig {
                    key: non_empty("STATION_KEY").unwrap_or_else(|| "default".to_owned()),
                    name: non_empty("STATION_NAME")
                        .unwrap_or_else(|| "Configured station".to_owned()),
                    url,
                    headers,
                })
            }
            _ => return Err(ConfigError::PartialStation),
        };

        let login_profile =
            non_empty("NIO_DEVICE_ID").map(|device_id| crate::nio_login::LoginProfile {
                app_id: non_empty("NIO_APP_ID").unwrap_or_else(|| "10002".to_owned()),
                region: non_empty("NIO_REGION").unwrap_or_else(|| "cn".to_owned()),
                lang: non_empty("NIO_LANGUAGE").unwrap_or_else(|| "zh-CN".to_owned()),
                app_ver: non_empty("NIO_APP_VERSION").unwrap_or_else(|| "6.9.0".to_owned()),
                device_id: device_id.to_ascii_lowercase(),
            });
        if let Some(profile) = &login_profile
            && (profile.device_id.len() != 32
                || !profile
                    .device_id
                    .bytes()
                    .all(|byte| byte.is_ascii_hexdigit()))
        {
            return Err(ConfigError::Invalid {
                name: "NIO_DEVICE_ID",
                message: "login device ID must contain 32 hexadecimal characters".to_owned(),
            });
        }
        let vehicle = match (
            non_empty("NIO_BEARER_TOKEN"),
            non_empty("NIO_VEHICLE_ID"),
            non_empty("NIO_DEVICE_ID"),
        ) {
            (None, None, None) => None,
            (None, None, Some(_)) => None,
            (Some(bearer_token), Some(vehicle_id), Some(device_id)) => {
                validate_identifier("NIO_VEHICLE_ID", &vehicle_id)?;
                validate_identifier("NIO_DEVICE_ID", &device_id)?;
                Some(VehicleConfig {
                    bearer_token,
                    account_id: non_empty("NIO_ACCOUNT_ID"),
                    vehicle_id,
                    device_id,
                    app_id: non_empty("NIO_APP_ID").unwrap_or_else(|| "10002".to_owned()),
                    app_version: non_empty("NIO_APP_VERSION").unwrap_or_else(|| "6.9.0".to_owned()),
                    region: non_empty("NIO_REGION").unwrap_or_else(|| "cn".to_owned()),
                    language: non_empty("NIO_LANGUAGE").unwrap_or_else(|| "zh-CN".to_owned()),
                    vin_code: non_empty("NIO_VEHICLE_VIN"),
                })
            }
            _ => return Err(ConfigError::PartialVehicle),
        };

        let service_order_url =
            non_empty("SERVICE_ORDER_URL").or_else(|| non_empty("NIO_CHANGE_API_URL"));
        let explicit_service_order_token = non_empty("SERVICE_ORDER_ACCESS_TOKEN")
            .or_else(|| non_empty("NIO_CHANGE_ACCESS_TOKEN"));
        let service_order_token = explicit_service_order_token.clone().or_else(|| {
            service_order_url
                .as_ref()
                .and_then(|_| non_empty("NIO_BEARER_TOKEN"))
        });
        let service_order_headers =
            non_empty("SERVICE_ORDER_HEADERS_JSON").or_else(|| non_empty("NIO_CHANGE_API_HEADERS"));
        let service_order_cookie =
            non_empty("SERVICE_ORDER_COOKIE").or_else(|| non_empty("NIO_CHANGE_COOKIE"));
        let station_template = station_template_from_env(vehicle.as_ref(), &non_empty)?;
        let service_orders = match service_order_url {
            Some(url) => {
                if !url.starts_with("https://") {
                    return Err(ConfigError::Invalid {
                        name: "SERVICE_ORDER_URL",
                        message: "only HTTPS endpoints are accepted".to_owned(),
                    });
                }
                let mut headers = match service_order_headers {
                    Some(raw_headers) => serde_json::from_str::<HashMap<String, String>>(
                        &raw_headers,
                    )
                    .map_err(|error| ConfigError::Invalid {
                        name: "SERVICE_ORDER_HEADERS_JSON",
                        message: error.to_string(),
                    })?,
                    None => HashMap::new(),
                };
                if let Some(token) = service_order_token
                    && !headers
                        .keys()
                        .any(|name| name.eq_ignore_ascii_case("authorization"))
                {
                    let token = token
                        .strip_prefix("Bearer ")
                        .or_else(|| token.strip_prefix("bearer "))
                        .unwrap_or(&token)
                        .trim();
                    headers.insert("Authorization".to_owned(), format!("Bearer {token}"));
                }
                if let Some(cookie) = service_order_cookie
                    && !headers
                        .keys()
                        .any(|name| name.eq_ignore_ascii_case("cookie"))
                {
                    headers.insert("Cookie".to_owned(), cookie);
                }
                Some(ServiceOrderConfig {
                    url,
                    headers,
                    vehicle_id: vehicle.as_ref().map(|config| config.vehicle_id.clone()),
                    vin_code: vehicle.as_ref().and_then(|config| config.vin_code.clone()),
                    station_template: station_template.clone(),
                })
            }
            None if explicit_service_order_token.is_some()
                || service_order_headers.is_some()
                || service_order_cookie.is_some() =>
            {
                return Err(ConfigError::PartialServiceOrders);
            }
            None => None,
        };

        Ok(Self {
            bind_addr,
            database_url,
            poll_interval,
            vehicle_unlocked_poll_interval,
            vehicle_locked_poll_interval,
            post_swap_poll_count,
            service_order_poll_interval,
            match_window,
            api_key,
            mcp_oauth_issuer,
            mcp_oauth_login_secret,
            station,
            station_template,
            vehicle,
            login_profile,
            service_orders,
        })
    }
}

fn station_template_from_env(
    vehicle: Option<&VehicleConfig>,
    non_empty: &impl Fn(&str) -> Option<String>,
) -> Result<Option<StationTemplateConfig>, ConfigError> {
    let template = non_empty("STATION_URL_TEMPLATE");
    let raw_headers = non_empty("STATION_TEMPLATE_HEADERS_JSON");
    let Some(mut url_template) = template else {
        if raw_headers.is_some() {
            return Err(ConfigError::Invalid {
                name: "STATION_TEMPLATE_HEADERS_JSON",
                message: "STATION_URL_TEMPLATE is required".to_owned(),
            });
        }
        return Ok(None);
    };
    if !url_template.starts_with("https://") || !url_template.contains("{station_id}") {
        return Err(ConfigError::Invalid {
            name: "STATION_URL_TEMPLATE",
            message: "must be an HTTPS URL containing {station_id}".to_owned(),
        });
    }
    if let Some(vehicle) = vehicle {
        url_template = url_template
            .replace("{vehicle_id}", &vehicle.vehicle_id)
            .replace("{device_id}", &vehicle.device_id)
            .replace("{app_id}", &vehicle.app_id)
            .replace("{app_version}", &vehicle.app_version)
            .replace("{region}", &vehicle.region)
            .replace("{language}", &vehicle.language);
    }
    if url_template.contains("{vehicle_id}")
        || url_template.contains("{device_id}")
        || url_template.contains("{app_id}")
        || url_template.contains("{app_version}")
        || url_template.contains("{region}")
        || url_template.contains("{language}")
    {
        return Err(ConfigError::Invalid {
            name: "STATION_URL_TEMPLATE",
            message: "vehicle placeholders require NIO vehicle configuration".to_owned(),
        });
    }

    let mut headers = match raw_headers {
        Some(raw_headers) => serde_json::from_str::<HashMap<String, String>>(&raw_headers)
            .map_err(|error| ConfigError::Invalid {
                name: "STATION_TEMPLATE_HEADERS_JSON",
                message: error.to_string(),
            })?,
        None => HashMap::new(),
    };
    if !headers
        .keys()
        .any(|name| name.eq_ignore_ascii_case("authorization"))
        && let Some(token) = non_empty("NIO_BEARER_TOKEN")
    {
        let token = token
            .strip_prefix("Bearer ")
            .or_else(|| token.strip_prefix("bearer "))
            .unwrap_or(&token)
            .trim();
        headers.insert("Authorization".to_owned(), format!("Bearer {token}"));
    }
    Ok(Some(StationTemplateConfig {
        url_template,
        headers,
    }))
}

fn is_tenant_specific(name: &str) -> bool {
    name == "API_KEY"
        || name.starts_with("NIO_")
        || name.starts_with("STATION_")
        || name.starts_with("SERVICE_ORDER_")
        || name.starts_with("MCP_OAUTH_")
}

fn validate_identifier(name: &'static str, value: &str) -> Result<(), ConfigError> {
    if value.len() > 128
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
    {
        return Err(ConfigError::Invalid {
            name,
            message: "must contain only ASCII letters, digits, '-' or '_'".to_owned(),
        });
    }
    Ok(())
}

fn duration_from_env(name: &'static str, default: u64) -> Result<Duration, ConfigError> {
    let seconds = match env::var(name) {
        Ok(value) => value.parse::<u64>().map_err(|error| ConfigError::Invalid {
            name,
            message: error.to_string(),
        })?,
        Err(_) => default,
    };
    if seconds == 0 {
        return Err(ConfigError::Invalid {
            name,
            message: "must be greater than zero".to_owned(),
        });
    }
    Ok(Duration::from_secs(seconds))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn loopback_addresses_are_detected_by_stdlib() {
        let address: SocketAddr = "127.0.0.1:8080".parse().unwrap();
        assert!(address.ip().is_loopback());
    }
}
