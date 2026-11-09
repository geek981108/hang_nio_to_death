//! MCP OAuth facade backed by PostgreSQL; credentials survive restarts.
use crate::store::Store;
use actix_web::{
    HttpResponse,
    http::{StatusCode, header},
    web,
};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use chrono::Utc;
use rand::{RngCore, rngs::OsRng};
use serde::Deserialize;
use serde_json::json;
use sha2::{Digest, Sha256};
use std::{sync::Arc, time::Duration};
use subtle::ConstantTimeEq;
use url::Url;

const CODE_TTL: Duration = Duration::from_secs(300);
const ACCESS_TTL: Duration = Duration::from_secs(3600);
const REFRESH_TTL: Duration = Duration::from_secs(30 * 86400);
const SCOPE: &str = "nio.mcp";

#[derive(Clone)]
pub struct OAuthServer {
    issuer: String,
    secret: Arc<str>,
    token_namespace: Arc<str>,
    store: Store,
}
#[derive(Deserialize)]
pub struct Registration {
    redirect_uris: Vec<String>,
    token_endpoint_auth_method: Option<String>,
    client_name: Option<String>,
}
#[derive(Deserialize)]
pub struct AuthQuery {
    response_type: String,
    client_id: String,
    redirect_uri: String,
    code_challenge: String,
    code_challenge_method: String,
    state: Option<String>,
    resource: Option<String>,
    scope: Option<String>,
}
#[derive(Deserialize)]
pub struct Login {
    login_secret: String,
}
#[derive(Deserialize)]
pub struct TokenForm {
    grant_type: String,
    client_id: String,
    code: Option<String>,
    redirect_uri: Option<String>,
    code_verifier: Option<String>,
    refresh_token: Option<String>,
    resource: Option<String>,
}

fn random() -> String {
    let mut bytes = [0u8; 32];
    OsRng.fill_bytes(&mut bytes);
    URL_SAFE_NO_PAD.encode(bytes)
}
fn hmac_sha256(key: &[u8], message: &[u8]) -> [u8; 32] {
    let mut block = [0u8; 64];
    if key.len() > 64 {
        block[..32].copy_from_slice(&Sha256::digest(key));
    } else {
        block[..key.len()].copy_from_slice(key);
    }
    let mut inner = [0x36u8; 64];
    let mut outer = [0x5cu8; 64];
    for (index, byte) in block.iter().enumerate() {
        inner[index] ^= byte;
        outer[index] ^= byte;
    }
    let mut hash = Sha256::new();
    hash.update(inner);
    hash.update(message);
    let inner_hash = hash.finalize();
    let mut hash = Sha256::new();
    hash.update(outer);
    hash.update(inner_hash);
    hash.finalize().into()
}
fn err(status: StatusCode, code: &str) -> HttpResponse {
    HttpResponse::build(status)
        .insert_header((header::CACHE_CONTROL, "no-store"))
        .json(json!({"error":code}))
}
impl OAuthServer {
    pub fn new(issuer: String, secret: String, store: Store) -> Self {
        let namespace = format!(
            "{}:{}",
            issuer,
            URL_SAFE_NO_PAD.encode(hmac_sha256(secret.as_bytes(), b"nio-mcp-token-namespace"))
        );
        Self {
            issuer,
            secret: Arc::from(secret),
            token_namespace: Arc::from(namespace),
            store,
        }
    }
    fn resource(&self) -> String {
        format!("{}/mcp", self.issuer)
    }
    fn client_id(&self, redirect_uri: &str) -> String {
        format!(
            "nio-{}",
            URL_SAFE_NO_PAD.encode(hmac_sha256(self.secret.as_bytes(), redirect_uri.as_bytes()))
        )
    }
    pub async fn valid_access(&self, token: &str) -> bool {
        if token.len() > 256 {
            return false;
        }
        match self
            .store
            .oauth_access_valid(&self.token_namespace, token)
            .await
        {
            Ok(valid) => valid,
            Err(error) => {
                tracing::error!(%error, "MCP OAuth token validation failed");
                false
            }
        }
    }
    pub fn challenge(&self) -> HttpResponse {
        HttpResponse::Unauthorized()
            .insert_header((
                header::WWW_AUTHENTICATE,
                format!(
                    "Bearer resource_metadata=\"{}/.well-known/oauth-protected-resource/mcp\"",
                    self.issuer
                ),
            ))
            .json(json!({"error":"unauthorized"}))
    }
    fn valid_auth(&self, q: &AuthQuery) -> bool {
        if q.response_type != "code"
            || q.code_challenge_method != "S256"
            || q.resource.as_deref() != Some(self.resource().as_str())
            || q.scope.as_deref().is_some_and(|s| s != SCOPE)
            || q.state.as_deref().is_some_and(|s| s.len() > 1024)
            || q.code_challenge.len() != 43
            || !q
                .code_challenge
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_'))
        {
            return false;
        }
        let expected = self.client_id(&q.redirect_uri);
        bool::from(expected.as_bytes().ct_eq(q.client_id.as_bytes()))
    }
}
pub async fn protected_resource(state: web::Data<Option<OAuthServer>>) -> HttpResponse {
    let Some(o) = state.as_ref() else {
        return HttpResponse::NotFound().finish();
    };
    HttpResponse::Ok().json(json!({"resource":o.resource(),"authorization_servers":[o.issuer],"scopes_supported":[SCOPE],"bearer_methods_supported":["header"]}))
}
pub async fn authorization_server(state: web::Data<Option<OAuthServer>>) -> HttpResponse {
    let Some(o) = state.as_ref() else {
        return HttpResponse::NotFound().finish();
    };
    HttpResponse::Ok().json(json!({"issuer":o.issuer,"authorization_endpoint":format!("{}/oauth/authorize",o.issuer),
        "token_endpoint":format!("{}/oauth/token",o.issuer),"registration_endpoint":format!("{}/oauth/register",o.issuer),
        "response_types_supported":["code"],"grant_types_supported":["authorization_code","refresh_token"],
        "code_challenge_methods_supported":["S256"],"token_endpoint_auth_methods_supported":["none"],"scopes_supported":[SCOPE]}))
}
pub async fn register(
    state: web::Data<Option<OAuthServer>>,
    input: web::Json<Registration>,
) -> HttpResponse {
    let Some(o) = state.as_ref() else {
        return HttpResponse::NotFound().finish();
    };
    if input.redirect_uris.len() != 1
        || input.client_name.as_deref().is_some_and(|s| s.len() > 128)
        || input
            .token_endpoint_auth_method
            .as_deref()
            .is_some_and(|s| s != "none")
        || input.redirect_uris.iter().any(|s| {
            if s.len() > 2048 {
                return true;
            }
            Url::parse(s).map_or(true, |u| {
                u.scheme() != "https"
                    || u.host_str().is_none()
                    || u.fragment().is_some()
                    || !u.username().is_empty()
                    || u.password().is_some()
                    || u.query().is_some()
            })
        })
    {
        return err(StatusCode::BAD_REQUEST, "invalid_client_metadata");
    }
    let client = o.client_id(&input.redirect_uris[0]);
    HttpResponse::Created().insert_header((header::CACHE_CONTROL,"no-store")).json(json!({"client_id":client,
        "redirect_uris":input.redirect_uris,"token_endpoint_auth_method":"none","grant_types":["authorization_code","refresh_token"],
        "response_types":["code"],"client_name":input.client_name}))
}
pub async fn authorize_page(
    state: web::Data<Option<OAuthServer>>,
    q: web::Query<AuthQuery>,
) -> HttpResponse {
    let Some(o) = state.as_ref() else {
        return HttpResponse::NotFound().finish();
    };

    if !o.valid_auth(&q) {
        return err(StatusCode::BAD_REQUEST, "invalid_request");
    }

    HttpResponse::Ok()
        .insert_header((header::CACHE_CONTROL, "no-store"))
        .insert_header((
            header::CONTENT_SECURITY_POLICY,
            "default-src 'none'; \
             style-src 'unsafe-inline'; \
             form-action 'self' https://chatgpt.com; \
             base-uri 'none'; \
             frame-ancestors 'none'",
        ))
        .content_type("text/html; charset=utf-8")
        .body(
            "<!doctype html><html lang=zh><meta charset=utf-8>\
             <title>NIO MCP 授权</title>\
             <style>body{font:16px system-ui;max-width:32rem;margin:4rem auto;padding:0 1rem}\
             input{display:block;width:100%;padding:.7rem;box-sizing:border-box}\
             button{margin-top:1rem;padding:.7rem}</style>\
             <h1>连接 NIO MCP</h1>\
             <p>授权后，ChatGPT 可调用此 MCP 的全部工具，包括签到、导入记录和创建换电订单。\
             创建订单仍需独立车控密钥和确认文字。</p>\
             <form method=post>\
             <label>OAuth 登录口令\
             <input name=login_secret type=password required autocomplete=off></label>\
             <button>授权连接</button>\
             </form></html>",
        )
}

pub async fn authorize_submit(
    state: web::Data<Option<OAuthServer>>,
    q: web::Query<AuthQuery>,
    login: web::Form<Login>,
) -> HttpResponse {
    let Some(o) = state.as_ref() else {
        return HttpResponse::NotFound().finish();
    };
    if !o.valid_auth(&q) {
        return err(StatusCode::BAD_REQUEST, "invalid_request");
    }
    if !bool::from(o.secret.as_bytes().ct_eq(login.login_secret.as_bytes())) {
        return err(StatusCode::UNAUTHORIZED, "access_denied");
    }
    let code = random();
    if let Err(error) = o
        .store
        .save_oauth_code(
            &o.token_namespace,
            &code,
            &q.client_id,
            &q.redirect_uri,
            &q.code_challenge,
            Utc::now() + chrono::Duration::from_std(CODE_TTL).unwrap(),
        )
        .await
    {
        tracing::error!(%error, "failed to persist MCP OAuth code");
        return err(StatusCode::INTERNAL_SERVER_ERROR, "server_error");
    }
    let mut url = Url::parse(&q.redirect_uri).expect("validated registration URL");
    url.query_pairs_mut().append_pair("code", &code);
    if let Some(state) = &q.state {
        url.query_pairs_mut().append_pair("state", state);
    }
    HttpResponse::Found()
        .insert_header((header::LOCATION, url.as_str()))
        .insert_header((header::CACHE_CONTROL, "no-store"))
        .finish()
}
pub async fn token(
    state: web::Data<Option<OAuthServer>>,
    form: web::Form<TokenForm>,
) -> HttpResponse {
    let Some(o) = state.as_ref() else {
        return HttpResponse::NotFound().finish();
    };
    if form.resource.as_deref() != Some(o.resource().as_str()) {
        return err(StatusCode::BAD_REQUEST, "invalid_target");
    }
    let access = random();
    let refresh = random();
    let now = Utc::now();
    let result = match form.grant_type.as_str() {
        "authorization_code" => {
            let Some(v) = form.code_verifier.as_deref() else {
                return err(StatusCode::BAD_REQUEST, "invalid_grant");
            };
            if !(v.len() >= 43
                && v.len() <= 128
                && v.bytes()
                    .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~'))
                && form.redirect_uri.is_some())
            {
                return err(StatusCode::BAD_REQUEST, "invalid_grant");
            }
            let Some(code) = form.code.as_deref() else {
                return err(StatusCode::BAD_REQUEST, "invalid_grant");
            };
            o.store
                .exchange_oauth_code(
                    &o.token_namespace,
                    code,
                    &form.client_id,
                    form.redirect_uri.as_deref().unwrap(),
                    &URL_SAFE_NO_PAD.encode(Sha256::digest(v.as_bytes())),
                    &access,
                    &refresh,
                    now + chrono::Duration::from_std(ACCESS_TTL).unwrap(),
                    now + chrono::Duration::from_std(REFRESH_TTL).unwrap(),
                )
                .await
        }
        "refresh_token" => {
            let Some(old) = form.refresh_token.as_deref() else {
                return err(StatusCode::BAD_REQUEST, "invalid_grant");
            };
            o.store
                .rotate_oauth_refresh(
                    &o.token_namespace,
                    old,
                    &form.client_id,
                    &access,
                    &refresh,
                    now + chrono::Duration::from_std(ACCESS_TTL).unwrap(),
                    now + chrono::Duration::from_std(REFRESH_TTL).unwrap(),
                )
                .await
        }
        _ => return err(StatusCode::BAD_REQUEST, "unsupported_grant_type"),
    };
    match result {
        Ok(true) => {}
        Ok(false) => return err(StatusCode::BAD_REQUEST, "invalid_grant"),
        Err(error) => {
            tracing::error!(%error, "failed to exchange MCP OAuth token");
            return err(StatusCode::INTERNAL_SERVER_ERROR, "server_error");
        }
    }
    HttpResponse::Ok().insert_header((header::CACHE_CONTROL,"no-store")).json(json!({"access_token":access,"token_type":"Bearer","expires_in":ACCESS_TTL.as_secs(),"refresh_token":refresh,"scope":SCOPE}))
}

#[cfg(test)]
mod tests {
    use super::*;
    use actix_web::{App, test};

    #[actix_web::test]
    async fn pkce_code_is_single_use_and_refresh_rotates() {
        let store = match Store::in_memory().await {
            Ok(store) => store,
            Err(_) if std::env::var_os("NIO_TEST_POSTGRES_URL").is_none() => return,
            Err(error) => panic!("PostgreSQL test setup failed: {error}"),
        };
        let oauth = OAuthServer::new(
            "https://mcp.example.test".into(),
            "a-private-login-secret-with-32-bytes".into(),
            store.clone(),
        );
        let app = test::init_service(
            App::new()
                .app_data(web::Data::new(Some(oauth.clone())))
                .route("/oauth/register", web::post().to(register))
                .route("/oauth/authorize", web::post().to(authorize_submit))
                .route("/oauth/token", web::post().to(token)),
        )
        .await;
        let r = test::call_service(
            &app,
            test::TestRequest::post()
                .uri("/oauth/register")
                .set_json(json!({"redirect_uris":["https://chatgpt.example.test/callback"]}))
                .to_request(),
        )
        .await;
        assert_eq!(r.status(), StatusCode::CREATED);
        let reg: serde_json::Value = test::read_body_json(r).await;
        let client = reg["client_id"].as_str().unwrap();
        assert_eq!(
            client,
            OAuthServer::new(
                "https://mcp.example.test".into(),
                "a-private-login-secret-with-32-bytes".into(),
                store.clone(),
            )
            .client_id("https://chatgpt.example.test/callback")
        );
        let verifier = "correct-horse-battery-staple-correct-horse-battery-staple";
        let challenge = URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()));
        let mut url = Url::parse("http://localhost/oauth/authorize").unwrap();
        url.query_pairs_mut()
            .append_pair("response_type", "code")
            .append_pair("client_id", client)
            .append_pair("redirect_uri", "https://chatgpt.example.test/callback")
            .append_pair("code_challenge", &challenge)
            .append_pair("code_challenge_method", "S256")
            .append_pair("resource", "https://mcp.example.test/mcp")
            .append_pair("state", "state-123");
        let uri = format!("{}?{}", url.path(), url.query().unwrap());
        let wrong = test::call_service(
            &app,
            test::TestRequest::post()
                .uri(&uri)
                .insert_header((header::CONTENT_TYPE, "application/x-www-form-urlencoded"))
                .set_payload("login_secret=wrong")
                .to_request(),
        )
        .await;
        assert_eq!(wrong.status(), StatusCode::UNAUTHORIZED);
        let accepted = test::call_service(
            &app,
            test::TestRequest::post()
                .uri(&uri)
                .insert_header((header::CONTENT_TYPE, "application/x-www-form-urlencoded"))
                .set_payload("login_secret=a-private-login-secret-with-32-bytes")
                .to_request(),
        )
        .await;
        assert_eq!(accepted.status(), StatusCode::FOUND);
        let location = accepted
            .headers()
            .get(header::LOCATION)
            .unwrap()
            .to_str()
            .unwrap();
        let redirect = Url::parse(location).unwrap();
        assert_eq!(redirect.host_str(), Some("chatgpt.example.test"));
        assert_eq!(
            redirect
                .query_pairs()
                .find(|(k, _)| k == "state")
                .unwrap()
                .1,
            "state-123"
        );
        let code = redirect
            .query_pairs()
            .find(|(k, _)| k == "code")
            .unwrap()
            .1
            .into_owned();
        let form = url::form_urlencoded::Serializer::new(String::new())
            .append_pair("grant_type", "authorization_code")
            .append_pair("client_id", client)
            .append_pair("code", &code)
            .append_pair("code_verifier", verifier)
            .append_pair("redirect_uri", "https://chatgpt.example.test/callback")
            .append_pair("resource", "https://mcp.example.test/mcp")
            .finish();
        let wrong_resource = form.replace(
            "https%3A%2F%2Fmcp.example.test%2Fmcp",
            "https%3A%2F%2Fother.example.test%2Fmcp",
        );
        let rejected = test::call_service(
            &app,
            test::TestRequest::post()
                .uri("/oauth/token")
                .insert_header((header::CONTENT_TYPE, "application/x-www-form-urlencoded"))
                .set_payload(wrong_resource)
                .to_request(),
        )
        .await;
        assert_eq!(rejected.status(), StatusCode::BAD_REQUEST);
        let exchanged = test::call_service(
            &app,
            test::TestRequest::post()
                .uri("/oauth/token")
                .insert_header((header::CONTENT_TYPE, "application/x-www-form-urlencoded"))
                .set_payload(form.clone())
                .to_request(),
        )
        .await;
        assert_eq!(exchanged.status(), StatusCode::OK);
        let issued: serde_json::Value = test::read_body_json(exchanged).await;
        let restarted = OAuthServer::new(
            "https://mcp.example.test".into(),
            "a-private-login-secret-with-32-bytes".into(),
            store.clone(),
        );
        assert!(
            restarted
                .valid_access(issued["access_token"].as_str().unwrap())
                .await
        );
        assert!(
            !OAuthServer::new(
                "https://mcp.example.test".into(),
                "a-different-private-login-secret-32-bytes".into(),
                store.clone(),
            )
            .valid_access(issued["access_token"].as_str().unwrap())
            .await
        );
        let replay = test::call_service(
            &app,
            test::TestRequest::post()
                .uri("/oauth/token")
                .insert_header((header::CONTENT_TYPE, "application/x-www-form-urlencoded"))
                .set_payload(form)
                .to_request(),
        )
        .await;
        assert_eq!(replay.status(), StatusCode::BAD_REQUEST);
        let refresh = url::form_urlencoded::Serializer::new(String::new())
            .append_pair("grant_type", "refresh_token")
            .append_pair("client_id", client)
            .append_pair("refresh_token", issued["refresh_token"].as_str().unwrap())
            .append_pair("resource", "https://mcp.example.test/mcp")
            .finish();
        let renewed = test::call_service(
            &app,
            test::TestRequest::post()
                .uri("/oauth/token")
                .insert_header((header::CONTENT_TYPE, "application/x-www-form-urlencoded"))
                .set_payload(refresh.clone())
                .to_request(),
        )
        .await;
        assert_eq!(renewed.status(), StatusCode::OK);
        let renewed: serde_json::Value = test::read_body_json(renewed).await;
        assert_ne!(renewed["refresh_token"], issued["refresh_token"]);
        assert!(
            restarted
                .valid_access(renewed["access_token"].as_str().unwrap())
                .await
        );
        let replay = test::call_service(
            &app,
            test::TestRequest::post()
                .uri("/oauth/token")
                .insert_header((header::CONTENT_TYPE, "application/x-www-form-urlencoded"))
                .set_payload(refresh)
                .to_request(),
        )
        .await;
        assert_eq!(replay.status(), StatusCode::BAD_REQUEST);
    }
}
