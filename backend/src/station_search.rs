//! Read-only remote NIO swap-station name search.

use std::{sync::Arc, time::Duration};

use aes::Aes128;
use base64::{Engine as _, engine::general_purpose::STANDARD as BASE64};
use cbc::cipher::{BlockDecryptMut, KeyIvInit, block_padding::Pkcs7};
use chrono::Utc;
use md5::{Digest as _, Md5};
use reqwest::{Client, StatusCode, redirect::Policy};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use url::Url;

use crate::config::VehicleConfig;

type Aes128CbcDec = cbc::Decryptor<Aes128>;

const APP_ORIGIN: &str = "https://app.nio.com";
const SEARCH_PATH: &str = "/app/api/pe/map/resources/v1/scene/search";
const SIGNING_SALT: &str = "2bc9b00fdcf8f7ded6d77afdd7077e79";
const RESPONSE_KEY: &[u8; 16] = b"kc1$[41_fpqxeg70";
const RESPONSE_IV: &[u8; 16] = b"g3QNdti5qCEoFVCj";

#[derive(Clone)]
pub struct NioStationSearchClient {
    profile: Arc<VehicleConfig>,
    http: Client,
}

#[derive(Debug, thiserror::Error)]
pub enum StationSearchError {
    #[error("station search name is invalid")]
    InvalidName,
    #[error("failed to construct NIO station-search request")]
    InvalidUrl,
    #[error("NIO station-search request failed")]
    Request(#[source] reqwest::Error),
    #[error("NIO station-search endpoint returned HTTP {0}")]
    HttpStatus(StatusCode),
    #[error("NIO station-search endpoint returned invalid JSON")]
    InvalidJson(#[source] reqwest::Error),
    #[error("NIO station-search request was rejected: {0}")]
    Rejected(String),
    #[error("NIO station-search response could not be decrypted")]
    Decryption,
    #[error("NIO station-search response was invalid")]
    InvalidResponse,
}

#[derive(Debug, Serialize, PartialEq)]
pub struct SwapStationSearchItem {
    pub station_id: String,
    pub name: String,
    pub address: Option<String>,
    pub longitude: Option<f64>,
    pub latitude: Option<f64>,
    pub icon_url: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct SwapStationSearchResult {
    pub query: String,
    pub source: String,
    pub request_id: Option<String>,
    pub stations: Vec<SwapStationSearchItem>,
}

#[derive(Debug, Deserialize)]
struct Envelope {
    result_code: String,
    #[serde(default)]
    data: Value,
    #[serde(default)]
    encrypt_type: u8,
    request_id: Option<String>,
    display_msg: Option<String>,
    debug_msg: Option<String>,
}

#[derive(Debug, Deserialize)]
struct SearchData {
    #[serde(default)]
    search_tabs: Vec<SearchTab>,
}

#[derive(Debug, Deserialize)]
struct SearchTab {
    #[serde(default)]
    tab_type: String,
    #[serde(default)]
    tab_data: Vec<SearchItem>,
}

#[derive(Debug, Deserialize)]
struct SearchItem {
    id: String,
    #[serde(default)]
    title: String,
    #[serde(default)]
    sub_title: String,
    location: String,
    #[serde(default)]
    sub_type: String,
    icon: Option<String>,
}

impl NioStationSearchClient {
    pub fn new(profile: VehicleConfig) -> Result<Self, StationSearchError> {
        let http = Client::builder()
            .timeout(Duration::from_secs(20))
            .redirect(Policy::none())
            .user_agent(format!(
                "NextevCar/{} (independent Rust station-search client)",
                profile.app_version
            ))
            .build()
            .map_err(StationSearchError::Request)?;
        Ok(Self {
            profile: Arc::new(profile),
            http,
        })
    }

    pub async fn search(&self, name: &str) -> Result<SwapStationSearchResult, StationSearchError> {
        let name = normalize_search_name(name)?;
        let query = vec![
            ("app_id".to_owned(), self.profile.app_id.clone()),
            ("region".to_owned(), self.profile.region.clone()),
            ("lang".to_owned(), self.profile.language.clone()),
            ("app_ver".to_owned(), self.profile.app_version.clone()),
            ("timestamp".to_owned(), Utc::now().timestamp().to_string()),
            ("device_id".to_owned(), self.profile.device_id.clone()),
            ("keywords".to_owned(), name.clone()),
            ("biz_type".to_owned(), "front_page".to_owned()),
        ];
        let url = signed_url(query, &self.profile.bearer_token)?;
        let response = self
            .http
            .get(url)
            .bearer_auth(&self.profile.bearer_token)
            .header("accept", "application/json,text/json,text/plain")
            .send()
            .await
            .map_err(StationSearchError::Request)?;
        let status = response.status();
        if !status.is_success() {
            return Err(StationSearchError::HttpStatus(status));
        }
        let envelope: Envelope = response
            .json()
            .await
            .map_err(StationSearchError::InvalidJson)?;
        if envelope.result_code != "success" && envelope.result_code != "0" {
            return Err(StationSearchError::Rejected(
                envelope
                    .display_msg
                    .or(envelope.debug_msg)
                    .unwrap_or(envelope.result_code),
            ));
        }
        let request_id = envelope.request_id.clone();
        let data: SearchData = serde_json::from_value(decode_data(&envelope)?)
            .map_err(|_| StationSearchError::InvalidResponse)?;
        Ok(SwapStationSearchResult {
            query: name,
            source: "remote".to_owned(),
            request_id,
            stations: parse_stations(data),
        })
    }
}

pub(crate) fn normalize_search_name(value: &str) -> Result<String, StationSearchError> {
    let value = value.trim();
    if value.is_empty()
        || value.chars().count() > 100
        || value.chars().any(|character| character.is_control())
    {
        return Err(StationSearchError::InvalidName);
    }
    Ok(value.to_owned())
}

fn signed_url(query: Vec<(String, String)>, bearer_token: &str) -> Result<Url, StationSearchError> {
    let mut canonical = query.clone();
    canonical.sort();
    let canonical = canonical
        .iter()
        .map(|(name, value)| format!("{name}={value}"))
        .collect::<Vec<_>>()
        .join("&");
    // This map endpoint signs decoded UTF-8 values. Url handles wire encoding
    // separately; percent-encoding the Chinese search term before hashing is rejected.
    let material = format!("GET{SEARCH_PATH}?{canonical}{SIGNING_SALT}Bearer {bearer_token}");
    let signature = format!("{:x}", Md5::digest(material.as_bytes()));
    let mut url = Url::parse(APP_ORIGIN).map_err(|_| StationSearchError::InvalidUrl)?;
    url.set_path(SEARCH_PATH);
    url.query_pairs_mut()
        .extend_pairs(query)
        .append_pair("sign", &signature);
    Ok(url)
}

fn decode_data(envelope: &Envelope) -> Result<Value, StationSearchError> {
    match envelope.encrypt_type {
        0 => Ok(envelope.data.clone()),
        1 => {
            let encoded = envelope
                .data
                .as_str()
                .ok_or(StationSearchError::InvalidResponse)?;
            let ciphertext = BASE64
                .decode(encoded)
                .map_err(|_| StationSearchError::Decryption)?;
            let plaintext = Aes128CbcDec::new(RESPONSE_KEY.into(), RESPONSE_IV.into())
                .decrypt_padded_vec_mut::<Pkcs7>(&ciphertext)
                .map_err(|_| StationSearchError::Decryption)?;
            serde_json::from_slice(&plaintext).map_err(|_| StationSearchError::InvalidResponse)
        }
        _ => Err(StationSearchError::InvalidResponse),
    }
}

fn parse_stations(data: SearchData) -> Vec<SwapStationSearchItem> {
    data.search_tabs
        .into_iter()
        .filter(|tab| tab.tab_type == "recharge")
        .flat_map(|tab| tab.tab_data)
        .filter(|item| item.sub_type == "PowerSwap" && item.id.starts_with("PS-NIO-"))
        .filter_map(|item| {
            let (longitude, latitude) = item.location.split_once(',')?;
            let longitude = longitude.parse::<f64>().ok()?;
            let latitude = latitude.parse::<f64>().ok()?;
            if !longitude.is_finite()
                || !latitude.is_finite()
                || !(-180.0..=180.0).contains(&longitude)
                || !(-90.0..=90.0).contains(&latitude)
            {
                return None;
            }
            Some(SwapStationSearchItem {
                station_id: item.id,
                name: item.title,
                address: (!item.sub_title.trim().is_empty()).then_some(item.sub_title),
                longitude: Some(longitude),
                latitude: Some(latitude),
                icon_url: item.icon,
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trims_and_validates_name() {
        assert_eq!(
            normalize_search_name("  红星美凯龙滨海  ").unwrap(),
            "红星美凯龙滨海"
        );
        assert!(normalize_search_name("\n").is_err());
        assert!(normalize_search_name(&"站".repeat(101)).is_err());
    }

    #[test]
    fn parses_only_valid_remote_swap_stations() {
        let data: SearchData = serde_json::from_value(serde_json::json!({
            "search_tabs": [{
                "tab_type": "recharge",
                "tab_data": [
                    {"id":"PS-NIO-test", "title":"测试换电站", "sub_title":"地址", "location":"117.6,39.0", "sub_type":"PowerSwap"},
                    {"id":"CS-test", "title":"充电站", "location":"117.6,39.0", "sub_type":"ChargeStation"},
                    {"id":"PS-NIO-bad", "title":"坏坐标", "location":"bad", "sub_type":"PowerSwap"}
                ]
            }]
        }))
        .unwrap();
        assert_eq!(
            parse_stations(data),
            vec![SwapStationSearchItem {
                station_id: "PS-NIO-test".to_owned(),
                name: "测试换电站".to_owned(),
                address: Some("地址".to_owned()),
                longitude: Some(117.6),
                latitude: Some(39.0),
                icon_url: None,
            }]
        );
    }

    #[test]
    fn signs_decoded_chinese_values_but_encodes_wire_query() {
        let url = signed_url(
            vec![("keywords".to_owned(), "红星美凯龙".to_owned())],
            "token",
        )
        .unwrap();
        assert!(url.as_str().contains("keywords=%E7%BA%A2%E6%98%9F"));
        assert!(url.query_pairs().any(|(name, _)| name == "sign"));
    }
}
