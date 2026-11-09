//! NIO CN coupon wallet and single-attempt daily check-in request.
//! Paths and request shapes come from the CN 6.9.6 app capture. Credentials
//! always come from the configured vehicle profile, never from that capture.

use std::{sync::Arc, time::Duration};

use chrono::Utc;
use reqwest::{Client, StatusCode};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest as _, Sha256};
use url::Url;

use crate::config::VehicleConfig;

const COUPON_ORIGIN: &str = "https://gateway-front-external.nio.com";
const COUPON_PATH: &str = "/moat/10086/n/c/uds/api/coupon/list";
const CHECKIN_ORIGIN: &str = "https://app.nio.com";
const CHECKIN_PATH: &str = "/c/award_cn/checkin";
const SIGNING_SALT: &str = "2bc9b00fdcf8f7ded6d77afdd7077e79";

#[derive(Clone)]
pub struct NioRewardsClient {
    profile: Arc<VehicleConfig>,
    http: Client,
}

#[derive(Debug, thiserror::Error)]
pub enum RewardsError {
    #[error("failed to construct NIO rewards request")]
    InvalidUrl,
    #[error("NIO rewards request failed")]
    Request(#[source] reqwest::Error),
    #[error("NIO rewards endpoint returned HTTP {0}")]
    HttpStatus(StatusCode),
    #[error("NIO rewards endpoint returned invalid JSON")]
    InvalidJson,
    #[error("NIO rewards request was rejected: {0}")]
    Rejected(String),
    #[error("NIO rewards response has an unexpected shape")]
    InvalidResponse,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct AvailableCouponsPage {
    /// Upstream count of merged coupon entries, not physical coupon quantity.
    pub amount: u64,
    pub coupons: Vec<Value>,
    pub has_more: bool,
    #[serde(skip_deserializing)]
    pub coupon_groups: Vec<CouponGroupCount>,
    #[serde(skip_deserializing)]
    pub page_coupon_count: Option<u64>,
    #[serde(skip_deserializing)]
    pub total_coupon_count: Option<u64>,
    #[serde(skip_deserializing)]
    pub limit: u32,
    #[serde(skip_deserializing)]
    pub offset: u32,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct CouponGroupCount {
    pub title: String,
    pub classification: Option<String>,
    pub count: Option<u64>,
    pub count_source: String,
    pub face_value_cny: Option<u32>,
    pub face_value_source: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct CheckInOutcome {
    pub checked_in: bool,
    pub tip: String,
    pub credit: i64,
    pub server_time: i64,
    pub checkin_time: i64,
    pub continuous_days: i64,
    pub credit_amount: i64,
}

#[derive(Deserialize)]
struct Envelope {
    result_code: String,
    data: Option<Value>,
}

impl NioRewardsClient {
    pub fn new(profile: VehicleConfig) -> Result<Self, RewardsError> {
        let http = Client::builder()
            .timeout(Duration::from_secs(20))
            .user_agent(format!("NIO/{}", profile.app_version))
            .build()
            .map_err(|error| RewardsError::Request(error.without_url()))?;
        Ok(Self {
            profile: Arc::new(profile),
            http,
        })
    }

    pub async fn available_coupons(
        &self,
        limit: u32,
        offset: u32,
    ) -> Result<AvailableCouponsPage, RewardsError> {
        let url = coupon_url(limit, offset, &self.profile.app_version)?;
        let response = self
            .http
            .get(url)
            .bearer_auth(&self.profile.bearer_token)
            .send()
            .await
            .map_err(|error| RewardsError::Request(error.without_url()))?;
        let data = read_data(response).await?;
        let mut page: AvailableCouponsPage =
            serde_json::from_value(data).map_err(|_| RewardsError::InvalidResponse)?;
        page.limit = limit;
        page.offset = offset;
        enrich_coupon_page(&mut page);
        Ok(page)
    }

    /// One explicit upstream POST per call. Do not retry on ambiguous failures.
    pub async fn check_in(&self) -> Result<CheckInOutcome, RewardsError> {
        let url = checkin_url(&self.profile, Utc::now().timestamp())?;
        let response = self
            .http
            .post(url)
            .bearer_auth(&self.profile.bearer_token)
            .header("content-type", "application/x-www-form-urlencoded")
            .body("event=checkin")
            .send()
            .await
            .map_err(|error| RewardsError::Request(error.without_url()))?;
        let data = read_data(response).await?;
        let stats = data.get("stats").ok_or(RewardsError::InvalidResponse)?;
        Ok(CheckInOutcome {
            checked_in: data
                .get("checked_in")
                .and_then(Value::as_bool)
                .ok_or(RewardsError::InvalidResponse)?,
            tip: data
                .get("tip")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned(),
            credit: data
                .get("credit")
                .and_then(Value::as_i64)
                .ok_or(RewardsError::InvalidResponse)?,
            server_time: data
                .get("server_time")
                .and_then(Value::as_i64)
                .ok_or(RewardsError::InvalidResponse)?,
            checkin_time: stats
                .get("checkin_time")
                .and_then(Value::as_i64)
                .ok_or(RewardsError::InvalidResponse)?,
            continuous_days: stats
                .get("continuous_days")
                .and_then(Value::as_i64)
                .ok_or(RewardsError::InvalidResponse)?,
            credit_amount: stats
                .get("credit_amount")
                .and_then(Value::as_i64)
                .ok_or(RewardsError::InvalidResponse)?,
        })
    }
}

fn enrich_coupon_page(page: &mut AvailableCouponsPage) {
    page.coupon_groups = page.coupons.iter().map(summarize_coupon_group).collect();
    page.page_coupon_count = page
        .coupon_groups
        .iter()
        .try_fold(0u64, |sum, group| sum.checked_add(group.count?));
    page.total_coupon_count =
        (page.offset == 0 && !page.has_more && page.coupons.len() as u64 == page.amount)
            .then_some(page.page_coupon_count)
            .flatten();
}

fn summarize_coupon_group(value: &Value) -> CouponGroupCount {
    let title_from_upstream = value
        .get("coupon_title")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty());
    let (title, title_source) = if let Some(title) = title_from_upstream {
        (title.to_owned(), "coupon_title")
    } else {
        (
            value
                .get("coupon_name")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned(),
            "coupon_name",
        )
    };
    let (count, count_source) = match value.get("merge_count") {
        None | Some(Value::Null) => (Some(1), "single_item"),
        Some(value) => {
            let count = value
                .as_u64()
                .or_else(|| value.as_str().and_then(|text| text.parse().ok()))
                .filter(|count| *count > 0);
            (count, "merge_count")
        }
    };
    let face_value_cny = title.find("元优惠券").and_then(|position| {
        let digits = title[..position]
            .chars()
            .rev()
            .take_while(char::is_ascii_digit)
            .collect::<String>();
        digits.chars().rev().collect::<String>().parse::<u32>().ok()
    });
    CouponGroupCount {
        title,
        classification: value
            .get("coupon_classification")
            .and_then(Value::as_str)
            .map(str::to_owned),
        count,
        count_source: count_source.to_owned(),
        face_value_cny,
        face_value_source: face_value_cny.map(|_| title_source.to_owned()),
    }
}

async fn read_data(response: reqwest::Response) -> Result<Value, RewardsError> {
    if !response.status().is_success() {
        return Err(RewardsError::HttpStatus(response.status()));
    }
    let envelope = response
        .json::<Envelope>()
        .await
        .map_err(|_| RewardsError::InvalidJson)?;
    if envelope.result_code != "success" {
        return Err(RewardsError::Rejected(envelope.result_code));
    }
    envelope.data.ok_or(RewardsError::InvalidResponse)
}

fn coupon_url(limit: u32, offset: u32, app_version: &str) -> Result<Url, RewardsError> {
    let mut url = Url::parse(COUPON_ORIGIN).map_err(|_| RewardsError::InvalidUrl)?;
    url.set_path(COUPON_PATH);
    url.query_pairs_mut()
        .append_pair("hash_type", "sha256")
        .append_pair("status", "available")
        .append_pair("merge", "true")
        .append_pair("biz_category", "all")
        .append_pair("sort_type", "receive_new")
        .append_pair("offset", &offset.to_string())
        .append_pair("count", &limit.to_string())
        .append_pair("app_ver", app_version);
    Ok(url)
}

fn checkin_url(profile: &VehicleConfig, timestamp: i64) -> Result<Url, RewardsError> {
    let mut url = Url::parse(CHECKIN_ORIGIN).map_err(|_| RewardsError::InvalidUrl)?;
    url.set_path(CHECKIN_PATH);
    let mut pairs = vec![
        ("hash_type", "sha256".to_owned()),
        (
            "lang",
            profile.language.replace('-', "_").to_ascii_lowercase(),
        ),
        ("timestamp", timestamp.to_string()),
        ("app_ver", profile.app_version.clone()),
        ("region", profile.region.clone()),
        ("device_id", profile.device_id.clone()),
        ("app_id", profile.app_id.clone()),
    ];
    let mut signing_pairs = pairs.clone();
    signing_pairs.push(("event", "checkin".to_owned()));
    signing_pairs.sort_by(|a, b| a.0.cmp(b.0).then(a.1.cmp(&b.1)));
    let canonical = signing_pairs
        .iter()
        .map(|(key, value)| format!("{key}={value}"))
        .collect::<Vec<_>>()
        .join("&");
    let material = format!(
        "POST{CHECKIN_PATH}?{canonical}{SIGNING_SALT}Bearer {}",
        profile.bearer_token
    );
    let sign = format!("{:x}", Sha256::digest(material.as_bytes()));
    pairs.push(("sign", sign));
    url.query_pairs_mut().extend_pairs(pairs);
    Ok(url)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn coupon_query_is_fixed_to_available_wallet_items() {
        let url = coupon_url(10, 20, "6.9.6").unwrap();
        let query: std::collections::HashMap<_, _> = url.query_pairs().into_owned().collect();
        assert_eq!(url.path(), COUPON_PATH);
        assert_eq!(query.get("status"), Some(&"available".to_owned()));
        assert_eq!(query.get("offset"), Some(&"20".to_owned()));
        assert_eq!(query.get("count"), Some(&"10".to_owned()));
    }

    #[test]
    fn merged_coupon_count_is_distinct_from_entry_count_and_face_value_is_labeled() {
        let mut page: AvailableCouponsPage = serde_json::from_value(serde_json::json!({
            "amount": 3,
            "coupons": [
                {"coupon_title":"换电服务费10元优惠券","coupon_classification":"exchange","merge_count":7},
                {"coupon_title":"换电服务费5元优惠券","coupon_classification":"exchange","merge_count":"8"},
                {"coupon_title":"其他礼券","coupon_classification":"discount"}
            ],
            "has_more": false
        })).unwrap();
        page.offset = 0;
        page.limit = 20;
        enrich_coupon_page(&mut page);
        assert_eq!(page.amount, 3);
        assert_eq!(page.page_coupon_count, Some(16));
        assert_eq!(page.total_coupon_count, Some(16));
        assert_eq!(page.coupon_groups[0].count, Some(7));
        assert_eq!(page.coupon_groups[0].face_value_cny, Some(10));
        assert_eq!(page.coupon_groups[1].count, Some(8));
        assert_eq!(page.coupon_groups[1].face_value_cny, Some(5));
        assert_eq!(page.coupon_groups[2].count_source, "single_item");
        assert_eq!(page.coupon_groups[2].face_value_cny, None);
        page.has_more = true;
        enrich_coupon_page(&mut page);
        assert_eq!(page.total_coupon_count, None);
    }

    #[test]
    fn checkin_signs_form_field_with_sha256() {
        let profile = VehicleConfig {
            bearer_token: "example-token".to_owned(),
            account_id: None,
            vehicle_id: "vehicle".to_owned(),
            device_id: "device".to_owned(),
            app_id: "10002".to_owned(),
            app_version: "6.9.6".to_owned(),
            region: "cn".to_owned(),
            language: "zh-CN".to_owned(),
            vin_code: None,
        };
        let url = checkin_url(&profile, 1_793_344_197).unwrap();
        let query: std::collections::HashMap<_, _> = url.query_pairs().into_owned().collect();
        assert_eq!(url.path(), CHECKIN_PATH);
        assert_eq!(query.get("hash_type"), Some(&"sha256".to_owned()));
        assert_eq!(query.get("lang"), Some(&"zh_cn".to_owned()));
        assert_eq!(
            query.get("sign").map(String::as_str),
            Some("159ffb554b5961dfddb9b8fe90d178046c9651b61f7825fe4f63c0e36435adf6")
        );
    }
}
