//! Persistent hashed OAuth credentials, scoped to the configured issuer.
use chrono::{DateTime, Utc};
use sha2::{Digest, Sha256};

use crate::{
    diesel_query as db,
    store::{Store, StoreError},
};

fn hash(token: &str) -> String {
    format!("{:x}", Sha256::digest(token.as_bytes()))
}

impl Store {
    pub async fn save_oauth_code(
        &self,
        issuer: &str,
        code: &str,
        client: &str,
        redirect: &str,
        challenge: &str,
        expires: DateTime<Utc>,
    ) -> Result<(), StoreError> {
        db::query("DELETE FROM mcp_oauth_tokens WHERE expires_at <= NOW()")
            .execute(&self.pool)
            .await?;
        db::query("INSERT INTO mcp_oauth_tokens (token_hash, issuer, kind, client_id, redirect_uri, challenge, expires_at) VALUES (?, ?, 'code', ?, ?, ?, ?)")
            .bind(hash(code)).bind(issuer).bind(client).bind(redirect).bind(challenge).bind(expires)
            .execute(&self.pool).await?;
        Ok(())
    }

    pub async fn oauth_access_valid(&self, issuer: &str, token: &str) -> Result<bool, StoreError> {
        Ok(db::query_scalar::<bool>("SELECT EXISTS (SELECT 1 FROM mcp_oauth_tokens WHERE token_hash = ? AND issuer = ? AND kind = 'access' AND expires_at > NOW())")
            .bind(hash(token)).bind(issuer).fetch_one(&self.pool).await?)
    }

    pub async fn exchange_oauth_code(
        &self,
        issuer: &str,
        code: &str,
        client: &str,
        redirect: &str,
        challenge: &str,
        access: &str,
        refresh: &str,
        access_expires: DateTime<Utc>,
        refresh_expires: DateTime<Utc>,
    ) -> Result<bool, StoreError> {
        let updated = db::query("WITH used AS (DELETE FROM mcp_oauth_tokens WHERE token_hash = ? AND issuer = ? AND kind = 'code' AND client_id = ? AND redirect_uri = ? AND challenge = ? AND expires_at > NOW() RETURNING client_id), \
            access AS (INSERT INTO mcp_oauth_tokens (token_hash, issuer, kind, client_id, expires_at) SELECT ?, ?, 'access', client_id, ? FROM used RETURNING client_id) \
            INSERT INTO mcp_oauth_tokens (token_hash, issuer, kind, client_id, expires_at) SELECT ?, ?, 'refresh', client_id, ? FROM access")
            .bind(hash(code)).bind(issuer).bind(client).bind(redirect).bind(challenge)
            .bind(hash(access)).bind(issuer).bind(access_expires)
            .bind(hash(refresh)).bind(issuer).bind(refresh_expires)
            .execute(&self.pool).await?.rows_affected() == 1;
        Ok(updated)
    }

    pub async fn rotate_oauth_refresh(
        &self,
        issuer: &str,
        old: &str,
        client: &str,
        access: &str,
        refresh: &str,
        access_expires: DateTime<Utc>,
        refresh_expires: DateTime<Utc>,
    ) -> Result<bool, StoreError> {
        let updated = db::query("WITH used AS (DELETE FROM mcp_oauth_tokens WHERE token_hash = ? AND issuer = ? AND kind = 'refresh' AND client_id = ? AND expires_at > NOW() RETURNING client_id), \
            access AS (INSERT INTO mcp_oauth_tokens (token_hash, issuer, kind, client_id, expires_at) SELECT ?, ?, 'access', client_id, ? FROM used RETURNING client_id) \
            INSERT INTO mcp_oauth_tokens (token_hash, issuer, kind, client_id, expires_at) SELECT ?, ?, 'refresh', client_id, ? FROM access")
            .bind(hash(old)).bind(issuer).bind(client)
            .bind(hash(access)).bind(issuer).bind(access_expires)
            .bind(hash(refresh)).bind(issuer).bind(refresh_expires)
            .execute(&self.pool).await?.rows_affected() == 1;
        Ok(updated)
    }
}
