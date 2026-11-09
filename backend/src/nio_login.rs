use std::{
    sync::Mutex,
    time::{Duration, Instant},
};

use aes::Aes256;
use base64::{Engine, engine::general_purpose::STANDARD};
use cbc::cipher::{BlockEncryptMut, KeyIvInit, block_padding::Pkcs7};
use chrono::Utc;
use md5::{Digest, Md5};
use rand::{Rng, distributions::Uniform};
use reqwest::{
    Client,
    header::{HeaderMap, SET_COOKIE},
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use thiserror::Error;
use url::Url;
use uuid::Uuid;

const ORIGIN: &str = "https://app.nio.com";
const SMS_PATH: &str = "/n/a/user/encryption/access/verification_code";
const LOGIN_PATH: &str = "/n/a/user/encryption/access/app/login";
const SALT: &str = "2bc9b00fdcf8f7ded6d77afdd7077e79";
// NIO App 6.9.0 AccountUtils protocol constants. They only obfuscate the phone field.
const MOBILE_KEY: &[u8; 32] = b"13579bdf02468ace13579bdf02468ace";
const MOBILE_IV: &[u8; 16] = b"2468ace13579bdf0";

#[derive(Clone)]
pub struct LoginProfile {
    pub app_id: String,
    pub region: String,
    pub lang: String,
    pub app_ver: String,
    pub device_id: String,
}

pub struct NioLogin {
    client: Client,
    profile: LoginProfile,
    sms_gate: tokio::sync::Mutex<()>,
    pending: Mutex<Option<Pending>>,
}

struct Pending {
    id: Uuid,
    mobile: String,
    cookie: String,
    session_id: Uuid,
    created: Instant,
}

#[derive(Deserialize)]
pub struct SmsInput {
    pub mobile: String,
}

#[derive(Deserialize)]
pub struct LoginInput {
    pub challenge_id: Uuid,
    pub verification_code: String,
}

#[derive(Serialize)]
pub struct SmsOutcome {
    pub challenge_id: Uuid,
    pub expires_in_seconds: u64,
}

#[derive(Debug, Error)]
pub enum LoginError {
    #[error("invalid mobile number or verification code")]
    InvalidInput,
    #[error("no matching unexpired SMS challenge")]
    NoChallenge,
    #[error("NIO login request failed")]
    Transport(#[source] reqwest::Error),
    #[error("NIO login returned an invalid response")]
    InvalidResponse,
    #[error("NIO login returned HTTP {0}")]
    HttpStatus(reqwest::StatusCode),
    #[error("NIO login was rejected: {code}")]
    Rejected {
        code: String,
        message: Option<String>,
        display_msg: Option<String>,
    },
}

impl NioLogin {
    pub fn new(profile: LoginProfile) -> Result<Self, reqwest::Error> {
        Ok(Self {
            client: Client::builder()
                .timeout(Duration::from_secs(20))
                .redirect(reqwest::redirect::Policy::none())
                .build()?,
            profile,
            sms_gate: tokio::sync::Mutex::new(()),
            pending: Mutex::new(None),
        })
    }

    pub async fn send_sms(&self, input: SmsInput) -> Result<SmsOutcome, LoginError> {
        if input.mobile.len() != 11
            || !matches!(input.mobile.as_bytes().get(1), Some(b'3'..=b'9'))
            || !input.mobile.bytes().all(|b| b.is_ascii_digit())
        {
            return Err(LoginError::InvalidInput);
        }
        let _sms_guard = self.sms_gate.lock().await;
        let mobile = encrypt_mobile(&input.mobile)?;
        // A new SMS request supersedes the previous challenge, including when it fails.
        *self.pending.lock().unwrap() = None;
        let session_id = Uuid::new_v4();
        let nonce: String = rand::thread_rng()
            .sample_iter(Uniform::new_inclusive(b'A', b'Z'))
            .take(32)
            .map(char::from)
            .collect();
        let form = vec![
            ("classifier", "login".to_owned()),
            ("client_id", self.profile.device_id.clone()),
            ("country_code", "86".to_owned()),
            ("device_id", self.profile.device_id.clone()),
            ("mobile", mobile.clone()),
            ("nonce", nonce),
            ("terminal", r#"{"model":"iPad","name":"iPad"}"#.to_owned()),
        ];
        let (payload, headers) = self.post(SMS_PATH, &form, session_id, None).await?;
        check_business(&payload)?;
        let cookie = routing_cookie(&headers)?;
        let id = Uuid::new_v4();
        *self.pending.lock().unwrap() = Some(Pending {
            id,
            mobile,
            cookie,
            session_id,
            created: Instant::now(),
        });
        Ok(SmsOutcome {
            challenge_id: id,
            expires_in_seconds: 600,
        })
    }

    pub async fn login(&self, input: LoginInput) -> Result<Value, LoginError> {
        if input.verification_code.len() != 6
            || !input.verification_code.bytes().all(|b| b.is_ascii_digit())
        {
            return Err(LoginError::InvalidInput);
        }
        // Consume before sending: an ambiguous network result must not be replayed.
        let pending = {
            let mut guard = self.pending.lock().unwrap();
            if !guard.as_ref().is_some_and(|pending| {
                pending.id == input.challenge_id
                    && pending.created.elapsed() <= Duration::from_secs(600)
            }) {
                return Err(LoginError::NoChallenge);
            }
            guard.take().unwrap()
        };
        let form = vec![
            ("client_id", self.profile.device_id.clone()),
            ("country_code", "86".to_owned()),
            ("device_id", self.profile.device_id.clone()),
            ("mobile", pending.mobile),
            ("terminal", r#"{"name":"iPad","model":"iPad"}"#.to_owned()),
            ("verification_code", input.verification_code),
        ];
        let (payload, _) = self
            .post(LOGIN_PATH, &form, pending.session_id, Some(&pending.cookie))
            .await?;
        check_business(&payload)?;
        let data = payload
            .get("data")
            .and_then(Value::as_object)
            .ok_or(LoginError::InvalidResponse)?;
        for key in ["access_token", "refresh_token", "token_key", "token_type"] {
            let value = data
                .get(key)
                .and_then(Value::as_str)
                .ok_or(LoginError::InvalidResponse)?;
            if value.is_empty() || value.len() > 4096 || value.chars().any(char::is_whitespace) {
                return Err(LoginError::InvalidResponse);
            }
        }
        if !data["token_type"]
            .as_str()
            .unwrap()
            .eq_ignore_ascii_case("bearer")
        {
            return Err(LoginError::InvalidResponse);
        }
        Ok(json!({ "result_code": "success", "data": data }))
    }

    async fn post(
        &self,
        path: &str,
        form: &[(&str, String)],
        session_id: Uuid,
        cookie: Option<&str>,
    ) -> Result<(Value, HeaderMap), LoginError> {
        let query = vec![
            ("app_id", self.profile.app_id.clone()),
            ("region", self.profile.region.clone()),
            ("lang", self.profile.lang.clone()),
            ("app_ver", self.profile.app_ver.clone()),
            ("timestamp", Utc::now().timestamp().to_string()),
            ("device_id", self.profile.device_id.clone()),
        ];
        let url = signed_url(path, &query, form)?;
        let mut request = self
            .client
            .post(url)
            .header("Accept", "application/json,text/json,text/plain")
            .header("Accept-Language", "zh-CN")
            .header(
                "User-Agent",
                format!("NextevCar/{} (iPad; iOS)", self.profile.app_ver),
            )
            .header("x-request-session-id", session_id.to_string())
            .form(form);
        if let Some(cookie) = cookie {
            request = request.header("Cookie", cookie);
        }
        let response = request.send().await.map_err(LoginError::Transport)?;
        if !response.status().is_success() {
            return Err(LoginError::HttpStatus(response.status()));
        }
        let headers = response.headers().clone();
        let raw = response.bytes().await.map_err(LoginError::Transport)?;
        if raw.len() > 1024 * 1024 {
            return Err(LoginError::InvalidResponse);
        }
        let payload = serde_json::from_slice(&raw).map_err(|_| LoginError::InvalidResponse)?;
        Ok((payload, headers))
    }
}

fn encrypt_mobile(mobile: &str) -> Result<String, LoginError> {
    let cipher = cbc::Encryptor::<Aes256>::new(MOBILE_KEY.into(), MOBILE_IV.into());
    Ok(STANDARD.encode(cipher.encrypt_padded_vec_mut::<Pkcs7>(mobile.as_bytes())))
}

fn signed_url(
    path: &str,
    query: &[(&str, String)],
    form: &[(&str, String)],
) -> Result<Url, LoginError> {
    let query_encoded: Vec<String> = query
        .iter()
        .map(|(k, v)| {
            let mut serializer = url::form_urlencoded::Serializer::new(String::new());
            serializer.append_pair(k, v);
            serializer.finish()
        })
        .collect();
    let mut canonical = query_encoded.clone();
    canonical.extend(form.iter().map(|(k, v)| format!("{k}={v}")));
    canonical.sort();
    let material = format!("POST{path}?{}{}", canonical.join("&"), SALT);
    let sign = format!("{:x}", Md5::digest(material.as_bytes()));
    let mut url =
        Url::parse(&format!("{ORIGIN}{path}")).map_err(|_| LoginError::InvalidResponse)?;
    url.query_pairs_mut()
        .extend_pairs(query.iter().map(|(k, v)| (*k, v.as_str())))
        .append_pair("sign", &sign);
    Ok(url)
}

fn routing_cookie(headers: &HeaderMap) -> Result<String, LoginError> {
    let routes = headers
        .get_all(SET_COOKIE)
        .iter()
        .filter_map(|value| value.to_str().ok())
        .filter_map(|value| value.split(';').next())
        .filter_map(|value| value.strip_prefix("tgw_l7_route="))
        .collect::<Vec<_>>();
    if routes.len() != 1
        || routes[0].is_empty()
        || routes[0].len() > 4096
        || routes[0]
            .chars()
            .any(|c| c.is_control() || c == ',' || c == ';' || c.is_whitespace())
    {
        return Err(LoginError::InvalidResponse);
    }
    Ok(format!("tgw_l7_route={}", routes[0]))
}

fn check_business(payload: &Value) -> Result<(), LoginError> {
    if payload.get("result_code").and_then(Value::as_str) == Some("success") {
        return Ok(());
    }
    let code = payload
        .get("result_code")
        .and_then(Value::as_str)
        .unwrap_or("unknown")
        .to_owned();
    let safe = |key| {
        payload
            .get(key)
            .and_then(Value::as_str)
            .filter(|s| s.len() <= 500)
            .map(str::to_owned)
    };
    Err(LoginError::Rejected {
        code,
        message: safe("message"),
        display_msg: safe("display_msg"),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mobile_encryption_matches_independent_openssl_vector() {
        assert_eq!(
            encrypt_mobile("13800138000").unwrap(),
            "IPPex/GQGfxQsJle8zdUaQ=="
        );
    }

    #[test]
    fn sms_signature_matches_python_client_vector() {
        let device = "a".repeat(32);
        let query = vec![
            ("app_id", "10002".into()),
            ("region", "cn".into()),
            ("lang", "zh-CN".into()),
            ("app_ver", "6.9.0".into()),
            ("timestamp", "1700000000".into()),
            ("device_id", device.clone()),
        ];
        let form = vec![
            ("classifier", "login".into()),
            ("client_id", device.clone()),
            ("country_code", "86".into()),
            ("device_id", device),
            ("mobile", "IPPex/GQGfxQsJle8zdUaQ==".into()),
            ("nonce", "A".repeat(32)),
            ("terminal", r#"{"model":"iPad","name":"iPad"}"#.into()),
        ];
        let url = signed_url(SMS_PATH, &query, &form).unwrap();
        assert_eq!(
            url.query_pairs().find(|(key, _)| key == "sign").unwrap().1,
            "962bf54bd43c41ebc93bb6fbcbbcb93c"
        );
    }

    #[test]
    fn routing_cookie_must_be_unique() {
        let mut headers = HeaderMap::new();
        headers.append(SET_COOKIE, "tgw_l7_route=fresh; Path=/".parse().unwrap());
        assert_eq!(routing_cookie(&headers).unwrap(), "tgw_l7_route=fresh");
        headers.append(SET_COOKIE, "tgw_l7_route=other; Path=/".parse().unwrap());
        assert!(routing_cookie(&headers).is_err());
    }
}
