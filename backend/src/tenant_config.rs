//! Encrypted, tenant-scoped NIO configuration. The master key never enters PostgreSQL.
use std::{
    collections::HashMap,
    env,
    sync::{Arc, Mutex},
};

use base64::{Engine, engine::general_purpose::STANDARD};
use rand::RngCore;
use ring::aead::{self, Aad, LessSafeKey, Nonce, UnboundKey};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use thiserror::Error;
use zeroize::Zeroize;

use crate::{diesel_query as db, pg_store::PgPool};

const CONFIG_AAD_PREFIX: &str = "nio-tenant-config-v1:";

fn allowed_extra(name: &str) -> bool {
    matches!(
        name,
        "NIO_ACCOUNT_ID"
            | "NIO_VEHICLE_VIN"
            | "STATION_KEY"
            | "STATION_NAME"
            | "STATION_URL"
            | "STATION_HEADERS_JSON"
            | "STATION_URL_TEMPLATE"
            | "STATION_TEMPLATE_HEADERS_JSON"
            | "SERVICE_ORDER_URL"
            | "SERVICE_ORDER_ACCESS_TOKEN"
            | "SERVICE_ORDER_HEADERS_JSON"
            | "SERVICE_ORDER_COOKIE"
    )
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TenantCredentials {
    pub api_key: String,
    pub nio_bearer_token: String,
    pub nio_vehicle_id: String,
    pub nio_device_id: String,
    pub nio_app_id: String,
    pub nio_app_version: String,
    pub nio_region: String,
    pub nio_language: String,
    #[serde(default)]
    pub nio_refresh_token: Option<String>,
    #[serde(default)]
    pub extra: HashMap<String, String>,
}

impl TenantCredentials {
    pub fn from_input(input: &str) -> Result<Self, TenantError> {
        let config = if input.trim_start().starts_with('{') {
            serde_json::from_str(input).map_err(|_| TenantError::InvalidConfig)?
        } else {
            let mut values = HashMap::new();
            for line in input.lines() {
                let line = line.trim();
                if line.is_empty() || line.starts_with('#') {
                    continue;
                }
                let (name, raw) = line.split_once('=').ok_or(TenantError::InvalidConfig)?;
                if !matches!(
                    name,
                    "API_KEY"
                        | "NIO_BEARER_TOKEN"
                        | "NIO_VEHICLE_ID"
                        | "NIO_DEVICE_ID"
                        | "NIO_APP_ID"
                        | "NIO_APP_VERSION"
                        | "NIO_REGION"
                        | "NIO_LANGUAGE"
                        | "NIO_REFRESH_TOKEN"
                ) && !allowed_extra(name)
                {
                    continue;
                }
                let raw = raw.trim();
                let value = if raw.len() >= 2
                    && ((raw.starts_with('"') && raw.ends_with('"'))
                        || (raw.starts_with('\'') && raw.ends_with('\'')))
                {
                    &raw[1..raw.len() - 1]
                } else {
                    raw
                };
                if values.insert(name.to_owned(), value.to_owned()).is_some() {
                    return Err(TenantError::InvalidConfig);
                }
            }
            let mut required = |key: &str| values.remove(key).ok_or(TenantError::InvalidConfig);
            Self {
                api_key: required("API_KEY")?,
                nio_bearer_token: required("NIO_BEARER_TOKEN")?,
                nio_vehicle_id: required("NIO_VEHICLE_ID")?,
                nio_device_id: required("NIO_DEVICE_ID")?,
                nio_app_id: required("NIO_APP_ID")?,
                nio_app_version: required("NIO_APP_VERSION")?,
                nio_region: required("NIO_REGION")?,
                nio_language: required("NIO_LANGUAGE")?,
                nio_refresh_token: values.remove("NIO_REFRESH_TOKEN"),
                extra: values,
            }
        };
        config.validate()?;
        Ok(config)
    }

    fn validate(&self) -> Result<(), TenantError> {
        if self.api_key.len() < 32
            || self.api_key.len() > 512
            || self.nio_bearer_token.is_empty()
            || self.nio_bearer_token.len() > 4096
            || self.nio_vehicle_id.is_empty()
            || self.nio_vehicle_id.len() > 128
            || self.nio_device_id.len() != 32
            || !self.nio_device_id.bytes().all(|b| b.is_ascii_hexdigit())
            || self
                .nio_refresh_token
                .as_ref()
                .is_some_and(|value| value.len() > 4096)
            || self
                .extra
                .iter()
                .any(|(key, value)| !allowed_extra(key) || value.len() > 8192)
            || [
                &self.nio_app_id,
                &self.nio_app_version,
                &self.nio_region,
                &self.nio_language,
            ]
            .iter()
            .any(|value| value.is_empty() || value.len() > 128)
        {
            return Err(TenantError::InvalidConfig);
        }
        Ok(())
    }

    pub fn overrides(&self) -> HashMap<String, String> {
        let mut values = HashMap::from([
            ("API_KEY".into(), self.api_key.clone()),
            ("NIO_BEARER_TOKEN".into(), self.nio_bearer_token.clone()),
            ("NIO_VEHICLE_ID".into(), self.nio_vehicle_id.clone()),
            ("NIO_DEVICE_ID".into(), self.nio_device_id.clone()),
            ("NIO_APP_ID".into(), self.nio_app_id.clone()),
            ("NIO_APP_VERSION".into(), self.nio_app_version.clone()),
            ("NIO_REGION".into(), self.nio_region.clone()),
            ("NIO_LANGUAGE".into(), self.nio_language.clone()),
        ]);
        values.extend(self.extra.clone());
        values
    }
}

#[derive(Debug, Error)]
pub enum TenantError {
    #[error("NIO_CONFIG_MASTER_KEY must be 64 hexadecimal characters")]
    InvalidMasterKey,
    #[error("tenant slug is invalid")]
    InvalidSlug,
    #[error("tenant configuration is invalid")]
    InvalidConfig,
    #[error("tenant configuration could not be decrypted")]
    Decrypt,
    #[error("tenant database operation failed: {0}")]
    Database(#[from] db::Error),
    #[error("invalid database URL")]
    DatabaseUrl,
}

#[derive(Deserialize)]
struct TenantRow {
    slug: String,
    schema_name: String,
    config_nonce: String,
    config_ciphertext: String,
}

pub struct TenantEntry {
    pub slug: String,
    pub schema_name: String,
    pub credentials: TenantCredentials,
}

pub struct TenantPersistence {
    pool: PgPool,
    cipher: Arc<ConfigCipher>,
    slug: String,
    credentials: Mutex<TenantCredentials>,
}

impl TenantPersistence {
    pub fn new(
        pool: PgPool,
        cipher: Arc<ConfigCipher>,
        slug: String,
        credentials: TenantCredentials,
    ) -> Self {
        Self {
            pool,
            cipher,
            slug,
            credentials: Mutex::new(credentials),
        }
    }

    pub async fn save_login(
        &self,
        access_token: &str,
        refresh_token: &str,
    ) -> Result<(), TenantError> {
        if access_token.is_empty()
            || refresh_token.is_empty()
            || access_token.len() > 4096
            || refresh_token.len() > 4096
        {
            return Err(TenantError::InvalidConfig);
        }
        let mut next = self.credentials.lock().unwrap().clone();
        next.nio_bearer_token = access_token.to_owned();
        next.nio_refresh_token = Some(refresh_token.to_owned());
        upsert(&self.pool, &self.cipher, &self.slug, &next).await?;
        *self.credentials.lock().unwrap() = next;
        Ok(())
    }
}

pub struct ConfigCipher(LessSafeKey);

impl ConfigCipher {
    pub fn from_env() -> Result<Option<Self>, TenantError> {
        let Some(hex) = env::var("NIO_CONFIG_MASTER_KEY")
            .ok()
            .filter(|s| !s.is_empty())
        else {
            return Ok(None);
        };
        if hex.len() != 64 {
            return Err(TenantError::InvalidMasterKey);
        }
        let mut key = [0u8; 32];
        for (index, chunk) in hex.as_bytes().chunks_exact(2).enumerate() {
            let digit = |b: u8| -> Option<u8> {
                match b {
                    b'0'..=b'9' => Some(b - b'0'),
                    b'a'..=b'f' => Some(b - b'a' + 10),
                    b'A'..=b'F' => Some(b - b'A' + 10),
                    _ => None,
                }
            };
            key[index] = (digit(chunk[0]).ok_or(TenantError::InvalidMasterKey)? << 4)
                | digit(chunk[1]).ok_or(TenantError::InvalidMasterKey)?;
        }
        let unbound =
            UnboundKey::new(&aead::AES_256_GCM, &key).map_err(|_| TenantError::InvalidMasterKey)?;
        key.zeroize();
        Ok(Some(Self(LessSafeKey::new(unbound))))
    }

    fn seal(
        &self,
        slug: &str,
        config: &TenantCredentials,
    ) -> Result<(String, String), TenantError> {
        config.validate()?;
        let mut nonce = [0u8; 12];
        rand::thread_rng().fill_bytes(&mut nonce);
        let mut data = serde_json::to_vec(config).map_err(|_| TenantError::InvalidConfig)?;
        self.0
            .seal_in_place_append_tag(
                Nonce::assume_unique_for_key(nonce),
                Aad::from(format!("{CONFIG_AAD_PREFIX}{slug}").as_bytes()),
                &mut data,
            )
            .map_err(|_| TenantError::InvalidConfig)?;
        let encoded = STANDARD.encode(&data);
        data.zeroize();
        Ok((STANDARD.encode(nonce), encoded))
    }

    fn open(
        &self,
        slug: &str,
        nonce: &str,
        ciphertext: &str,
    ) -> Result<TenantCredentials, TenantError> {
        let nonce = STANDARD.decode(nonce).map_err(|_| TenantError::Decrypt)?;
        let nonce: [u8; 12] = nonce.try_into().map_err(|_| TenantError::Decrypt)?;
        let mut data = STANDARD
            .decode(ciphertext)
            .map_err(|_| TenantError::Decrypt)?;
        let plain = self
            .0
            .open_in_place(
                Nonce::assume_unique_for_key(nonce),
                Aad::from(format!("{CONFIG_AAD_PREFIX}{slug}").as_bytes()),
                &mut data,
            )
            .map_err(|_| TenantError::Decrypt)?;
        let config: TenantCredentials =
            serde_json::from_slice(plain).map_err(|_| TenantError::Decrypt)?;
        data.zeroize();
        config.validate()?;
        Ok(config)
    }
}

pub fn schema_for(slug: &str) -> Result<String, TenantError> {
    if slug.is_empty()
        || slug.len() > 48
        || !slug.starts_with(|c: char| c.is_ascii_lowercase())
        || !slug
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_')
    {
        return Err(TenantError::InvalidSlug);
    }
    Ok(if slug == "default" {
        "public".into()
    } else {
        format!("tenant_{slug}")
    })
}

pub fn schema_database_url(database_url: &str, schema: &str) -> Result<String, TenantError> {
    if schema != "public" && !schema.starts_with("tenant_") {
        return Err(TenantError::InvalidSlug);
    }
    let mut url = url::Url::parse(database_url).map_err(|_| TenantError::DatabaseUrl)?;
    if url.query_pairs().any(|(key, _)| key == "options") {
        return Err(TenantError::DatabaseUrl);
    }
    url.query_pairs_mut()
        .append_pair("options", &format!("-csearch_path={schema}"));
    Ok(url.to_string())
}

pub async fn load(pool: &PgPool, cipher: &ConfigCipher) -> Result<Vec<TenantEntry>, TenantError> {
    let rows: Vec<TenantRow> = db::query_as(
        "SELECT slug, schema_name, config_nonce, config_ciphertext FROM public.tenant_configs WHERE enabled ORDER BY slug"
    ).fetch_all(pool).await?;
    rows.into_iter()
        .map(|row| {
            let expected = schema_for(&row.slug)?;
            if expected != row.schema_name {
                return Err(TenantError::InvalidConfig);
            }
            Ok(TenantEntry {
                slug: row.slug.clone(),
                schema_name: row.schema_name,
                credentials: cipher.open(&row.slug, &row.config_nonce, &row.config_ciphertext)?,
            })
        })
        .collect()
}

pub async fn upsert(
    pool: &PgPool,
    cipher: &ConfigCipher,
    slug: &str,
    config: &TenantCredentials,
) -> Result<(), TenantError> {
    let schema = schema_for(slug)?;
    let (nonce, ciphertext) = cipher.seal(slug, config)?;
    let key_hash = format!("{:x}", Sha256::digest(config.api_key.as_bytes()));
    db::query(
        "INSERT INTO public.tenant_configs \
        (slug, schema_name, api_key_sha256, config_nonce, config_ciphertext) \
        VALUES (?, ?, ?, ?, ?) ON CONFLICT (slug) DO UPDATE SET \
        api_key_sha256 = EXCLUDED.api_key_sha256, config_nonce = EXCLUDED.config_nonce, \
        config_ciphertext = EXCLUDED.config_ciphertext, updated_at = NOW()",
    )
    .bind(slug)
    .bind(schema)
    .bind(key_hash)
    .bind(nonce)
    .bind(ciphertext)
    .execute(pool)
    .await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn config_cipher_binds_ciphertext_to_tenant() {
        let key = UnboundKey::new(&aead::AES_256_GCM, &[7u8; 32]).unwrap();
        let cipher = ConfigCipher(LessSafeKey::new(key));
        let input = TenantCredentials {
            api_key: "a".repeat(64),
            nio_bearer_token: "synthetic-token".into(),
            nio_vehicle_id: "vehicle-test".into(),
            nio_device_id: "b".repeat(32),
            nio_app_id: "10002".into(),
            nio_app_version: "6.9.0".into(),
            nio_region: "cn".into(),
            nio_language: "zh-CN".into(),
            nio_refresh_token: None,
            extra: HashMap::new(),
        };
        let (nonce, ciphertext) = cipher.seal("default", &input).unwrap();
        assert!(!ciphertext.contains("synthetic-token"));
        assert_eq!(
            cipher.open("default", &nonce, &ciphertext).unwrap().api_key,
            input.api_key
        );
        assert!(cipher.open("other", &nonce, &ciphertext).is_err());
    }

    #[test]
    fn schema_names_are_unambiguous() {
        assert_eq!(schema_for("default").unwrap(), "public");
        assert_eq!(schema_for("alice_2").unwrap(), "tenant_alice_2");
        assert!(schema_for("a-b").is_err());
        let url = schema_database_url("postgres://localhost/nio", "tenant_alice_2").unwrap();
        assert!(url.contains("search_path%3Dtenant_alice_2"));
    }
}
