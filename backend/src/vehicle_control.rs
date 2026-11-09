//! Explicit, opt-in vehicle commands. No network operation occurs while building a request.
//! Wire contracts mirror the independently tested Python client in tools/nio-cert-flow-client.

use base64::{
    Engine as _,
    engine::general_purpose::{STANDARD, URL_SAFE},
};
use md5::{Digest as _, Md5};
use rand::{RngCore, rngs::OsRng};
use reqwest::{Client, Method, redirect::Policy};
use rsa::{BigUint, RsaPublicKey, pkcs8::DecodePublicKey, traits::PublicKeyParts};
use rustls::{
    ClientConfig, DigitallySignedStruct, Error as TlsError, RootCertStore, SignatureScheme,
    client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier},
    client::verify_server_cert_signed_by_trust_anchor,
    crypto::{WebPkiSupportedAlgorithms, aws_lc_rs::default_provider},
    server::ParsedCertificate,
};
use rustls_pki_types::{CertificateDer, PrivateKeyDer, ServerName, UnixTime, pem::PemObject};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::Sha256;
use std::{
    env, fmt, fs,
    path::{Path, PathBuf},
    sync::Arc,
    time::{Duration, Instant},
};
use tiny_keccak::{Hasher, Sha3};
use tokio::{
    net::TcpStream,
    sync::Mutex,
    time::{sleep, timeout},
};
use tokio_rustls::TlsConnector;
use url::Url;
use zeroize::Zeroizing;

use crate::{config::VehicleConfig, pin_secret};

const SIGNING_SALT: &str = "2bc9b00fdcf8f7ded6d77afdd7077e79";
const PIN_SALTS: [&str; 10] = [
    "2976ae25f6b04f719f351e2fd890fa50",
    "ed8abe8d1fc3456a8a1e366151c2a6b7",
    "6b10b3f89d1c4bfa8199ff3f74aa2887",
    "a76d51834a4f4609a38d1a0f5e3d6465",
    "e6be849e07c64511a17b777743021af3",
    "3edb5e23e8b34f848af4888feb169e9b",
    "c527b8e5816346c6a586e7ea9db27fa5",
    "bb719cd4f60d4567a19103187e855b30",
    "85c9ff17d6cf46bbbea8e8671d25a944",
    "9341dc8b84bb422598a890273a28fe09",
];

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum VehicleAction {
    UnlockDoors,
    UnlockStart,
    Lock,
    GuardOn,
    GuardOff,
    MirrorExpand,
    Find,
    FindStop,
    AcOn,
    AcOff,
    SeatHeatOff,
}

impl VehicleAction {
    pub fn confirmation(self) -> &'static str {
        match self {
            Self::UnlockDoors => "UNLOCK DOORS",
            Self::UnlockStart => "UNLOCK AND START",
            Self::Lock => "LOCK VEHICLE",
            Self::GuardOn => "ENABLE GUARD MODE",
            Self::GuardOff => "DISABLE GUARD MODE",
            Self::MirrorExpand => "EXPAND MIRRORS",
            Self::Find => "FIND VEHICLE",
            Self::FindStop => "STOP FINDING",
            Self::AcOn => "START AC",
            Self::AcOff => "STOP AC",
            Self::SeatHeatOff => "STOP SEAT HEATING",
        }
    }

    pub fn needs_pin(self) -> bool {
        matches!(self, Self::UnlockDoors | Self::UnlockStart)
    }

    pub fn requires_parked(self) -> bool {
        // Door-only unlock deliberately delegates the App's Park requirement
        // to the upstream service; that enforcement is not independently proven.
        !matches!(self, Self::FindStop | Self::UnlockDoors)
    }

    fn polls_state(self) -> bool {
        matches!(
            self,
            Self::UnlockStart
                | Self::Lock
                | Self::GuardOn
                | Self::GuardOff
                | Self::AcOn
                | Self::AcOff
        )
    }

    fn verified_after_poll(self) -> bool {
        matches!(
            self,
            Self::Lock | Self::GuardOn | Self::GuardOff | Self::AcOn | Self::AcOff
        )
    }
}

#[derive(Debug, thiserror::Error)]
pub enum ControlError {
    #[error("invalid vehicle command input: {0}")]
    InvalidInput(&'static str),
    #[error("invalid PIN encryption public key")]
    InvalidPublicKey,
    #[error("PIN encryption failed")]
    Encryption,
    #[error("invalid signed URL")]
    InvalidUrl,
    #[error("vehicle control configuration is invalid: {0}")]
    InvalidConfig(&'static str),
    #[error("server-side vehicle PIN is unavailable")]
    PinUnavailable,
    #[error("vehicle TLS preflight failed")]
    TlsPreflight,
    #[error("upstream vehicle request failed")]
    Transport,
    #[error("upstream vehicle response was rejected (HTTP {0})")]
    Http(u16),
    #[error("upstream vehicle response was invalid")]
    InvalidResponse,
    #[error("upstream vehicle command was not explicitly accepted")]
    NotAccepted,
    #[error("vehicle state is not safe or unambiguous for this action")]
    UnsafeState,
    #[error("vehicle command was accepted but its desired state was not observed")]
    NotVerified,
}

#[derive(Clone)]
pub struct ControlRuntime {
    pub key: Arc<str>,
    client: Arc<ControlClient>,
}

struct ControlClient {
    profile: VehicleConfig,
    pin_file: Option<PathBuf>,
    app_http: Client,
    vehicle_http: Client,
    gate: Mutex<()>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ActionInput {
    pub action: VehicleAction,
    pub confirmation: String,
    #[serde(default)]
    pub temperature: Option<f64>,
    #[serde(default)]
    pub recirculation: Option<u8>,
    #[serde(default)]
    pub expand_mirrors: bool,
    #[serde(default)]
    pub mirror_confirmation: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct ActionOutcome {
    pub action: VehicleAction,
    pub status: &'static str,
    pub verified: bool,
    pub mirrors: Option<&'static str>,
}

const APP_ORIGIN: &str = "https://app.nio.com";
const CONTROL_ORIGIN: &str = "https://icar.nio.com:4430";
const CONTROL_LEAF_SHA256: &str =
    "4dc4fd9558e3aa8932934e40539515066852b0930375d4bfb2fd18132527d673";
const MAX_PEM: u64 = 1024 * 1024;
const MAX_RESPONSE: usize = 1024 * 1024;

/// The fixed NIO leaf has no SAN. Accept that one exact leaf only after
/// validating its CA chain, validity and serverAuth usage. TLS handshake
/// signatures are still checked by rustls; no other hostname bypass exists.
#[derive(Debug)]
struct PinnedIcarVerifier {
    roots: RootCertStore,
    algorithms: WebPkiSupportedAlgorithms,
}

impl ServerCertVerifier for PinnedIcarVerifier {
    fn verify_server_cert(
        &self,
        leaf: &CertificateDer<'_>,
        intermediates: &[CertificateDer<'_>],
        server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        now: UnixTime,
    ) -> Result<ServerCertVerified, TlsError> {
        if !matches!(server_name, ServerName::DnsName(name) if name.as_ref() == "icar.nio.com")
            || format!("{:x}", Sha256::digest(leaf.as_ref())) != CONTROL_LEAF_SHA256
        {
            return Err(TlsError::InvalidCertificate(
                rustls::CertificateError::NotValidForName,
            ));
        }
        let parsed = ParsedCertificate::try_from(leaf)?;
        verify_server_cert_signed_by_trust_anchor(
            &parsed,
            &self.roots,
            intermediates,
            now,
            self.algorithms.all,
        )?;
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, TlsError> {
        rustls::crypto::verify_tls12_signature(message, cert, dss, &self.algorithms)
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, TlsError> {
        rustls::crypto::verify_tls13_signature(message, cert, dss, &self.algorithms)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.algorithms.supported_schemes()
    }
}

pub(crate) fn pinned_icar_tls_config(
    roots: RootCertStore,
    certs: Vec<CertificateDer<'static>>,
    private: PrivateKeyDer<'static>,
) -> Result<ClientConfig, TlsError> {
    let algorithms = default_provider().signature_verification_algorithms;
    let verifier = Arc::new(PinnedIcarVerifier { roots, algorithms });
    ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(verifier)
        .with_client_auth_cert(certs, private)
}

impl ControlRuntime {
    /// An absent control key leaves the entire control surface disabled. No
    /// credential file is read until the operator explicitly opts in.
    pub fn from_env(
        profile: Option<VehicleConfig>,
        ordinary_api_key: Option<&str>,
    ) -> Result<Option<Self>, ControlError> {
        let Some(key) = nonempty_env("NIO_CONTROL_API_KEY") else {
            return Ok(None);
        };
        let profile = profile.ok_or(ControlError::InvalidConfig(
            "vehicle session is required for control",
        ))?;
        if key.len() < 32 {
            return Err(ControlError::InvalidConfig(
                "control key must be at least 32 characters",
            ));
        }
        if ordinary_api_key == Some(key.as_str())
            && nonempty_env("NIO_CONTROL_ALLOW_SHARED_API_KEY").as_deref() != Some("true")
        {
            return Err(ControlError::InvalidConfig(
                "shared API key requires NIO_CONTROL_ALLOW_SHARED_API_KEY=true",
            ));
        }
        let cert_path = configured_path("NIO_CONTROL_TLS_CERT_PATH")?;
        let key_path = configured_path("NIO_CONTROL_TLS_KEY_PATH")?;
        let ca_path = configured_path("NIO_CONTROL_CA_PATH")?;
        let pin_file = pin_secret::configured_path().map_err(ControlError::InvalidConfig)?;
        require_owner_only(&key_path)?;
        let cert_pem = bounded_file(&cert_path)?;
        let key_pem = bounded_file(&key_path)?;
        let ca_pem = bounded_file(&ca_path)?;
        let user_agent = format!(
            "NextevCar/{} (independent Rust client)",
            profile.app_version
        );
        let mut roots = RootCertStore::empty();
        for cert in CertificateDer::pem_slice_iter(&ca_pem) {
            roots
                .add(cert.map_err(|_| ControlError::InvalidConfig("server CA bundle is invalid"))?)
                .map_err(|_| ControlError::InvalidConfig("server CA bundle is invalid"))?;
        }
        if roots.is_empty() {
            return Err(ControlError::InvalidConfig("server CA bundle is empty"));
        }
        let certs = CertificateDer::pem_slice_iter(&cert_pem)
            .collect::<Result<Vec<_>, _>>()
            .map_err(|_| ControlError::InvalidConfig("client certificate is invalid"))?;
        if certs.is_empty() {
            return Err(ControlError::InvalidConfig("client certificate is empty"));
        }
        let private = PrivateKeyDer::from_pem_slice(&key_pem)
            .map_err(|_| ControlError::InvalidConfig("client private key is invalid"))?;
        let tls = pinned_icar_tls_config(roots, certs, private)
            .map_err(|_| ControlError::InvalidConfig("mTLS identity is invalid"))?;
        let vehicle_http = Client::builder()
            .timeout(Duration::from_secs(20))
            .redirect(Policy::none())
            .user_agent(user_agent.clone())
            .use_preconfigured_tls(tls.clone())
            .build()
            .map_err(|_| ControlError::InvalidConfig("mTLS client could not be initialized"))?;
        let app_http = Client::builder()
            .timeout(Duration::from_secs(20))
            .redirect(Policy::none())
            .user_agent(user_agent)
            .build()
            .map_err(|_| ControlError::InvalidConfig("app client could not be initialized"))?;
        Ok(Some(Self {
            key: Arc::from(key),
            client: Arc::new(ControlClient {
                profile,
                pin_file,
                app_http,
                vehicle_http,
                gate: Mutex::new(()),
            }),
        }))
    }

    pub async fn execute(&self, input: ActionInput) -> Result<ActionOutcome, ControlError> {
        self.client.execute(input).await
    }
}

fn nonempty_env(name: &str) -> Option<String> {
    env::var(name)
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
}

fn configured_path(name: &str) -> Result<PathBuf, ControlError> {
    let path = PathBuf::from(nonempty_env(name).ok_or(ControlError::InvalidConfig(
        "control certificate, key, and CA paths are all required",
    ))?);
    if !path.is_absolute() {
        return Err(ControlError::InvalidConfig(
            "control credential paths must be absolute",
        ));
    }
    Ok(path)
}

fn bounded_file(path: &Path) -> Result<Vec<u8>, ControlError> {
    let meta = fs::metadata(path)
        .map_err(|_| ControlError::InvalidConfig("control credential file is missing"))?;
    if !meta.is_file() || meta.len() == 0 || meta.len() > MAX_PEM {
        return Err(ControlError::InvalidConfig(
            "control credential file must be regular and at most 1 MiB",
        ));
    }
    fs::read(path)
        .map_err(|_| ControlError::InvalidConfig("control credential file could not be read"))
}

#[cfg(unix)]
fn require_owner_only(path: &Path) -> Result<(), ControlError> {
    use std::os::unix::fs::PermissionsExt;
    let mode = fs::metadata(path)
        .map_err(|_| ControlError::InvalidConfig("client key is missing"))?
        .permissions()
        .mode();
    if mode & 0o077 != 0 {
        return Err(ControlError::InvalidConfig(
            "client key must be owner-only (0600)",
        ));
    }
    Ok(())
}

#[cfg(not(unix))]
fn require_owner_only(_path: &Path) -> Result<(), ControlError> {
    Err(ControlError::InvalidConfig(
        "control credentials require a Unix host",
    ))
}

pub(crate) async fn verify_pinned_icar_leaf(
    tls_config: Arc<ClientConfig>,
) -> Result<(), ControlError> {
    let tcp = timeout(
        Duration::from_secs(20),
        TcpStream::connect(("icar.nio.com", 4430)),
    )
    .await
    .map_err(|_| ControlError::TlsPreflight)?
    .map_err(|_| ControlError::TlsPreflight)?;
    let server = ServerName::try_from("icar.nio.com").map_err(|_| ControlError::TlsPreflight)?;
    let tls = timeout(
        Duration::from_secs(20),
        TlsConnector::from(tls_config).connect(server, tcp),
    )
    .await
    .map_err(|_| ControlError::TlsPreflight)?
    .map_err(|error| {
        tracing::warn!(%error, "NIO pinned TLS handshake failed");
        ControlError::TlsPreflight
    })?;
    let leaf = tls
        .get_ref()
        .1
        .peer_certificates()
        .and_then(|certs| certs.first())
        .ok_or(ControlError::TlsPreflight)?;
    let digest = Sha256::digest(leaf.as_ref());
    if format!("{digest:x}") != CONTROL_LEAF_SHA256 {
        return Err(ControlError::TlsPreflight);
    }
    Ok(())
}

fn state_poll_delay(attempt: usize) -> Duration {
    if attempt == 0 {
        Duration::ZERO
    } else if attempt <= 3 {
        Duration::from_secs(1)
    } else {
        Duration::from_secs(3)
    }
}

impl ControlClient {
    async fn request(
        &self,
        method: Method,
        origin: &str,
        path: &str,
        extra_query: &[(String, String)],
        form: Option<&[(String, String)]>,
        headers: &[(&str, &str)],
    ) -> Result<Value, ControlError> {
        let url = signed_url(
            origin,
            method.as_str(),
            path,
            &self.profile,
            chrono::Utc::now().timestamp(),
            extra_query,
            form,
        )?;
        let client = if origin == CONTROL_ORIGIN {
            &self.vehicle_http
        } else {
            &self.app_http
        };
        let mut request = client
            .request(method, url)
            .bearer_auth(&self.profile.bearer_token)
            .header("Accept", "application/json,text/json,text/plain")
            .header("Accept-Language", "zh-CN,zh-Hans;q=0.9");
        for (name, value) in headers {
            request = request.header(*name, *value);
        }
        if let Some(fields) = form {
            request = request.form(fields);
        }
        let mut response = request.send().await.map_err(|_| ControlError::Transport)?;
        let status = response.status();
        let mut body = Vec::new();
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|_| ControlError::Transport)?
        {
            if body.len().saturating_add(chunk.len()) > MAX_RESPONSE {
                return Err(ControlError::InvalidResponse);
            }
            body.extend_from_slice(&chunk);
        }
        if !status.is_success() {
            return Err(ControlError::Http(status.as_u16()));
        }
        let payload: Value =
            serde_json::from_slice(&body).map_err(|_| ControlError::InvalidResponse)?;
        if !business_success(&payload) {
            return Err(ControlError::InvalidResponse);
        }
        Ok(payload)
    }

    async fn status_field(&self, field: &str) -> Result<Value, ControlError> {
        let path = format!(
            "/api/2/rvs/vehicle/{}/status",
            quote(&self.profile.vehicle_id)
        );
        self.request(
            Method::GET,
            CONTROL_ORIGIN,
            &path,
            &[("field".into(), field.into())],
            None,
            &[],
        )
        .await
    }

    async fn require_parked(&self) -> Result<(), ControlError> {
        let payload = self.status_field("exterior").await?;
        if unique_i64(&payload, "vehicle_state") != Some(2) {
            return Err(ControlError::UnsafeState);
        }
        Ok(())
    }

    async fn e2e_type(&self) -> Result<i64, ControlError> {
        let payload = self
            .request(
                Method::GET,
                APP_ORIGIN,
                "/app/api/icar/v2/switch/cars",
                &[],
                None,
                &[],
            )
            .await?;
        let mut matches = Vec::new();
        fn walk(value: &Value, vehicle_id: &str, matches: &mut Vec<i64>) {
            match value {
                Value::Object(map) => {
                    if map
                        .get("vehicle_profile")
                        .and_then(|entry| entry.get("vehicle_id"))
                        .and_then(Value::as_str)
                        == Some(vehicle_id)
                        && let Some(mode) = map.get("e2e_type").and_then(Value::as_i64)
                    {
                        matches.push(mode);
                    }
                    for child in map.values() {
                        walk(child, vehicle_id, matches);
                    }
                }
                Value::Array(items) => {
                    for child in items {
                        walk(child, vehicle_id, matches);
                    }
                }
                _ => {}
            }
        }
        walk(&payload, &self.profile.vehicle_id, &mut matches);
        match matches.as_slice() {
            [mode] => Ok(*mode),
            _ => Err(ControlError::UnsafeState),
        }
    }

    async fn door_state(&self) -> Result<(i64, bool), ControlError> {
        let payload = self.status_field("door").await?;
        let lock = unique_i64(&payload, "vehicle_lock_status").ok_or(ControlError::UnsafeState)?;
        if lock != 0 && lock != 1 {
            return Err(ControlError::UnsafeState);
        }
        let closed = [
            "door_ajar_front_left_status",
            "door_ajar_front_right_status",
            "door_ajar_rear_left_status",
            "door_ajar_rear_right_status",
        ]
        .iter()
        .map(|name| unique_i64(&payload, name))
        .collect::<Vec<_>>();
        if closed.iter().any(Option::is_none) {
            return Err(ControlError::UnsafeState);
        }
        Ok((lock, closed.iter().all(|value| *value == Some(1))))
    }

    async fn guard_enabled(&self) -> Result<bool, ControlError> {
        let payload = self.status_field("offcar_mode_status").await?;
        let mut modes = Vec::new();
        collect_values(&payload, "offcar_mode_status", &mut |value| {
            if let Some(mode) = value.get("defender_mode").and_then(Value::as_i64) {
                modes.push(mode);
            }
        });
        match modes.as_slice() {
            [0] => Ok(false),
            [2] => Ok(true),
            _ => Err(ControlError::UnsafeState),
        }
    }

    async fn mirrors_expanded(&self) -> Result<bool, ControlError> {
        let payload = self.status_field("window").await?;
        let left = unique_i64(&payload, "mirr_frnt_le_sts").ok_or(ControlError::UnsafeState)?;
        let right = unique_i64(&payload, "mirr_frnt_ri_sts").ok_or(ControlError::UnsafeState)?;
        if left != right || !matches!(left, 0 | 1) {
            return Err(ControlError::UnsafeState);
        }
        Ok(left == 0)
    }

    async fn ac_enabled(&self) -> Result<bool, ControlError> {
        let payload = self.status_field("hvac").await?;
        unique_bool(&payload, "air_conditioner_on").ok_or(ControlError::UnsafeState)
    }

    async fn pin_key(&self) -> Result<(String, String), ControlError> {
        let mut bytes = [0u8; 32];
        OsRng
            .try_fill_bytes(&mut bytes)
            .map_err(|_| ControlError::Encryption)?;
        let nonce = bytes
            .iter()
            .map(|byte| char::from(b'A' + byte % 26))
            .collect::<String>();
        let payload = self
            .request(
                Method::GET,
                APP_ORIGIN,
                "/acc/2/get_encryption",
                &[("nonce".into(), nonce)],
                None,
                &[],
            )
            .await?;
        let key = unique_string(&payload, "key").ok_or(ControlError::InvalidResponse)?;
        let id = unique_string(&payload, "key_id").ok_or(ControlError::InvalidResponse)?;
        if key.is_empty() || id.is_empty() {
            return Err(ControlError::InvalidResponse);
        }
        Ok((key, id))
    }

    async fn send(
        &self,
        action: VehicleAction,
        encrypted_pin: Option<&str>,
        key_id: Option<&str>,
        temperature: Option<f64>,
        recirculation: Option<u8>,
    ) -> Result<(), ControlError> {
        let plan = build_command(
            action,
            &self.profile.vehicle_id,
            &self.profile.device_id,
            encrypted_pin,
            key_id,
            temperature,
            recirculation,
        )?;
        // This is the only POST site. It is deliberately not retried.
        let payload = self
            .request(
                Method::POST,
                CONTROL_ORIGIN,
                &plan.path,
                &plan.query,
                plan.form.as_deref(),
                &plan.headers,
            )
            .await?;
        if !command_accepted(&payload) {
            return Err(ControlError::NotAccepted);
        }
        Ok(())
    }

    async fn poll_state(&self, action: VehicleAction) -> Result<(), ControlError> {
        for attempt in 0..18 {
            if attempt != 0 {
                sleep(state_poll_delay(attempt)).await;
            }
            let observed = match action {
                VehicleAction::UnlockStart => self.door_state().await?.0 == 0,
                VehicleAction::Lock => self.door_state().await?.0 == 1,
                VehicleAction::GuardOn => self.guard_enabled().await?,
                VehicleAction::GuardOff => !self.guard_enabled().await?,
                VehicleAction::AcOn => self.ac_enabled().await?,
                VehicleAction::AcOff => !self.ac_enabled().await?,
                _ => return Ok(()),
            };
            if observed {
                return Ok(());
            }
        }
        Err(ControlError::NotVerified)
    }

    async fn execute(&self, input: ActionInput) -> Result<ActionOutcome, ControlError> {
        if input.confirmation != input.action.confirmation() {
            return Err(ControlError::InvalidInput(
                "typed confirmation does not match action",
            ));
        }
        if input.expand_mirrors
            != input
                .mirror_confirmation
                .as_deref()
                .is_some_and(|value| value == "EXPAND MIRRORS")
        {
            return Err(ControlError::InvalidInput(
                "mirror expansion needs its own exact confirmation",
            ));
        }
        if input.expand_mirrors
            && !matches!(
                input.action,
                VehicleAction::GuardOn | VehicleAction::GuardOff
            )
        {
            return Err(ControlError::InvalidInput(
                "mirror expansion is only available with guard mode",
            ));
        }
        if input.action.needs_pin() && self.pin_file.is_none() {
            return Err(ControlError::PinUnavailable);
        }
        // Validate ordinary action parameters before any credential-bearing request.
        build_command(
            input.action,
            &self.profile.vehicle_id,
            &self.profile.device_id,
            if input.action.needs_pin() {
                Some("placeholder")
            } else {
                None
            },
            if input.action.needs_pin() {
                Some("placeholder")
            } else {
                None
            },
            input.temperature,
            input.recirculation,
        )?;
        let started = Instant::now();
        let _guard = self.gate.lock().await;
        let queue_ms = started.elapsed().as_millis() as u64;
        // The persistent reqwest client uses PinnedIcarVerifier on every new
        // TLS connection. A separate preflight handshake here was redundant.
        let checked_door_action = matches!(
            input.action,
            VehicleAction::UnlockStart | VehicleAction::Lock
        );
        let door_state = if checked_door_action {
            let (e2e, (), doors) =
                tokio::try_join!(self.e2e_type(), self.require_parked(), self.door_state())?;
            if e2e != 0 {
                return Err(ControlError::UnsafeState);
            }
            Some(doors)
        } else {
            None
        };
        if input.action == VehicleAction::UnlockDoors && self.e2e_type().await? != 0 {
            return Err(ControlError::UnsafeState);
        }
        if !checked_door_action && input.action.requires_parked() {
            self.require_parked().await?;
        }
        if let Some((lock, closed)) = door_state {
            if input.action == VehicleAction::Lock && lock == 1 {
                return Ok(ActionOutcome {
                    action: input.action,
                    status: "already_desired",
                    verified: true,
                    mirrors: None,
                });
            }
            if !closed {
                return Err(ControlError::UnsafeState);
            }
        }
        let safety_ms = started.elapsed().as_millis() as u64 - queue_ms;
        let guard_already_desired = if matches!(
            input.action,
            VehicleAction::GuardOn | VehicleAction::GuardOff
        ) {
            self.guard_enabled().await? == (input.action == VehicleAction::GuardOn)
        } else {
            false
        };
        if input.action == VehicleAction::MirrorExpand && self.mirrors_expanded().await? {
            return Ok(ActionOutcome {
                action: input.action,
                status: "already_desired",
                verified: true,
                mirrors: None,
            });
        }
        let mut encrypted_pin = None;
        let mut key_id = None;
        let pin_started = Instant::now();
        if input.action.needs_pin() {
            let pin_path = self
                .pin_file
                .as_deref()
                .ok_or(ControlError::PinUnavailable)?;
            let pin = Zeroizing::new(
                pin_secret::read_pin(pin_path, &self.profile.vehicle_id)
                    .map_err(|_| ControlError::PinUnavailable)?,
            );
            let (public, id) = self.pin_key().await?;
            encrypted_pin = Some(encrypt_pin(pin.as_str(), &public)?);
            key_id = Some(id);
        }
        let pin_ms = pin_started.elapsed().as_millis() as u64;
        let mut command_ms = 0;
        let mut verify_ms = 0;
        let mut command_to_verified_ms = None;
        if !guard_already_desired {
            let command_started = Instant::now();
            self.send(
                input.action,
                encrypted_pin.as_deref(),
                key_id.as_deref(),
                input.temperature,
                input.recirculation,
            )
            .await?;
            command_ms = command_started.elapsed().as_millis() as u64;
            if input.action.polls_state() {
                let verify_started = Instant::now();
                self.poll_state(input.action).await?;
                verify_ms = verify_started.elapsed().as_millis() as u64;
                command_to_verified_ms = Some(command_ms + verify_ms);
            }
        }
        let mut mirrors = None;
        if input.expand_mirrors {
            if self.mirrors_expanded().await? {
                mirrors = Some("already_expanded");
            } else {
                self.send(VehicleAction::MirrorExpand, None, None, None, None)
                    .await?;
                mirrors = Some("accepted_unverified");
            }
        }
        tracing::info!(
            action = ?input.action,
            queue_ms,
            safety_ms,
            pin_ms,
            command_ms,
            verify_ms,
            command_to_verified_ms = ?command_to_verified_ms,
            total_ms = started.elapsed().as_millis() as u64,
            "NIO vehicle action timing"
        );
        let verified = input.action.verified_after_poll();
        Ok(ActionOutcome {
            action: input.action,
            status: if guard_already_desired {
                "already_desired"
            } else if verified {
                "verified"
            } else {
                "accepted_unverified"
            },
            verified,
            mirrors,
        })
    }
}

fn collect_values<'a>(value: &'a Value, key: &str, visit: &mut impl FnMut(&'a Value)) {
    match value {
        Value::Object(map) => {
            for (name, child) in map {
                if name == key {
                    visit(child);
                }
                collect_values(child, key, visit);
            }
        }
        Value::Array(items) => {
            for child in items {
                collect_values(child, key, visit);
            }
        }
        _ => {}
    }
}

fn unique_i64(payload: &Value, key: &str) -> Option<i64> {
    let mut found = Vec::new();
    collect_values(payload, key, &mut |value| found.push(value.as_i64()));
    match found.as_slice() {
        [Some(value)] => Some(*value),
        _ => None,
    }
}

fn unique_bool(payload: &Value, key: &str) -> Option<bool> {
    let mut found = Vec::new();
    collect_values(payload, key, &mut |value| found.push(value.as_bool()));
    match found.as_slice() {
        [Some(value)] => Some(*value),
        _ => None,
    }
}

fn unique_string(payload: &Value, key: &str) -> Option<String> {
    let mut found = Vec::new();
    collect_values(payload, key, &mut |value| found.push(value.as_str()));
    match found.as_slice() {
        [Some(value)] => Some((*value).to_owned()),
        _ => None,
    }
}

/// Distinguish an absent status field from a present but ambiguous/malformed one.
fn status_value(payload: &Value, key: &str) -> Option<Option<String>> {
    let mut found = Vec::new();
    collect_values(payload, key, &mut |value| found.push(value));
    match found.as_slice() {
        [] => None,
        [Value::String(value)] => Some(Some(value.clone())),
        [Value::Number(value)] => Some(Some(value.to_string())),
        [_] | [_, ..] => Some(None),
    }
}

fn business_success(payload: &Value) -> bool {
    for key in ["result_code", "code"] {
        if let Some(value) = status_value(payload, key) {
            return value.is_some_and(|value| {
                matches!(
                    value.trim().to_ascii_lowercase().as_str(),
                    "0" | "200" | "ok" | "success" | "succeeded"
                )
            });
        }
    }
    true
}

fn command_accepted(payload: &Value) -> bool {
    for key in ["result_code", "code", "command_status"] {
        if let Some(value) = status_value(payload, key) {
            return value.is_some_and(|value| {
                matches!(
                    value.trim().to_ascii_lowercase().as_str(),
                    "0" | "200"
                        | "ok"
                        | "success"
                        | "succeeded"
                        | "accepted"
                        | "pending"
                        | "running"
                )
            });
        }
    }
    unique_string(payload, "command_id").is_some_and(|value| !value.trim().is_empty())
}

/// Secrets are not included in Debug output.
pub struct CommandPlan {
    pub path: String,
    pub query: Vec<(String, String)>,
    pub form: Option<Vec<(String, String)>>,
    pub headers: Vec<(&'static str, &'static str)>,
}

impl fmt::Debug for CommandPlan {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("CommandPlan")
            .field("path", &self.path)
            .finish_non_exhaustive()
    }
}

pub fn build_command(
    action: VehicleAction,
    vehicle_id: &str,
    device_id: &str,
    encrypted_pin: Option<&str>,
    key_id: Option<&str>,
    temperature: Option<f64>,
    recirculation: Option<u8>,
) -> Result<CommandPlan, ControlError> {
    if vehicle_id.is_empty() || device_id.is_empty() {
        return Err(ControlError::InvalidInput(
            "vehicle and device IDs are required",
        ));
    }
    if action != VehicleAction::AcOn && (temperature.is_some() || recirculation.is_some()) {
        return Err(ControlError::InvalidInput("AC settings require ac-on"));
    }
    let path_prefix = format!("/api/1/vehicle/{}/command/", quote(vehicle_id));
    let mut form = Some(vec![("device_id".into(), device_id.into())]);
    let mut query = Vec::new();
    let mut headers = vec![("X-Requested-Type", "RemoveDeviceId")];
    let route = match action {
        VehicleAction::UnlockDoors | VehicleAction::UnlockStart => {
            let pin = encrypted_pin
                .filter(|value| !value.is_empty())
                .ok_or(ControlError::InvalidInput("encrypted PIN is required"))?;
            let key = key_id
                .filter(|value| !value.is_empty())
                .ok_or(ControlError::InvalidInput("PIN key ID is required"))?;
            let fields = form.as_mut().expect("initial form");
            fields.extend([
                ("pin_code_key_id".into(), key.into()),
                ("pin_code".into(), pin.into()),
                ("operation_confirmed".into(), "true".into()),
            ]);
            headers.push(("X-E2e-Signature-Enable", "true"));
            if action == VehicleAction::UnlockDoors {
                fields.push(("key_id".into(), key.into()));
                headers.push(("X-Scene-Type", "TestDrive"));
                "unlock_all_doors"
            } else {
                "unlock_immo"
            }
        }
        VehicleAction::Lock => {
            form.as_mut()
                .expect("initial form")
                .push(("operation_confirmed".into(), "false".into()));
            headers.push(("X-E2e-Signature-Enable", "true"));
            "lock_doors"
        }
        VehicleAction::GuardOn => {
            form = Some(vec![("vid".into(), vehicle_id.into())]);
            query.push(("operation_confirmed".into(), "true".into()));
            headers.push(("X-Scene-Type", "TestDrive"));
            "turn_on_defender_mode"
        }
        VehicleAction::GuardOff => {
            form = Some(vec![("vid".into(), vehicle_id.into())]);
            "turn_off_defender_mode"
        }
        VehicleAction::MirrorExpand => {
            form = None;
            headers.push(("Content-Type", "application/x-www-form-urlencoded"));
            "stretch_rearview_mirror"
        }
        VehicleAction::Find => "findme",
        VehicleAction::FindStop => "stop_findme",
        VehicleAction::AcOn => {
            let fields = form.as_mut().expect("initial form");
            fields.push(("operation_confirmed".into(), "false".into()));
            if let Some(value) = temperature {
                if !value.is_finite() || !(16.0..=30.0).contains(&value) {
                    return Err(ControlError::InvalidInput("AC temperature must be 16–30 C"));
                }
                fields.push(("temperature".into(), value.to_string()));
            }
            if let Some(value) = recirculation {
                if value > 1 {
                    return Err(ControlError::InvalidInput("recirculation must be 0 or 1"));
                }
                fields.push(("recirculation".into(), value.to_string()));
            }
            headers.push(("exclude-confirmed", "false"));
            "turn_on_air_conditioner"
        }
        VehicleAction::AcOff => {
            headers.push(("cbn-ovr-ht-confirm", "false"));
            "turn_off_air_conditioner"
        }
        VehicleAction::SeatHeatOff => "turn_off_seats_heating",
    };
    Ok(CommandPlan {
        path: path_prefix + route,
        query,
        form,
        headers,
    })
}

pub(crate) fn quote(value: &str) -> String {
    let mut result = String::new();
    for byte in value.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b'~') {
            result.push(char::from(byte));
        } else {
            result.push_str(&format!("%{byte:02X}"));
        }
    }
    result
}

pub fn signed_url(
    origin: &str,
    method: &str,
    path: &str,
    config: &VehicleConfig,
    timestamp: i64,
    extra_query: &[(String, String)],
    form: Option<&[(String, String)]>,
) -> Result<Url, ControlError> {
    if !path.starts_with('/') || path.contains(['?', '#']) {
        return Err(ControlError::InvalidUrl);
    }
    let mut pairs = vec![
        ("app_id".into(), config.app_id.clone()),
        ("region".into(), config.region.clone()),
        ("lang".into(), config.language.clone()),
        ("app_ver".into(), config.app_version.clone()),
        ("timestamp".into(), timestamp.to_string()),
        ("device_id".into(), config.device_id.clone()),
    ];
    pairs.extend_from_slice(extra_query);
    let encoded = pairs
        .iter()
        .map(|(key, value)| format!("{}={}", quote(key), quote(value)))
        .collect::<Vec<_>>();
    let mut canonical = encoded.clone();
    if let Some(fields) = form {
        canonical.extend(
            fields
                .iter()
                .filter(|(name, _)| !name.is_empty())
                .map(|(name, value)| format!("{name}={value}")),
        );
    }
    canonical.sort();
    let material = format!(
        "{}{}?{}{}Bearer {}",
        method.to_ascii_uppercase(),
        path,
        canonical.join("&"),
        SIGNING_SALT,
        config.bearer_token
    );
    let sign = format!("{:x}", Md5::digest(material.as_bytes()));
    let mut url = Url::parse(&format!("{origin}{path}")).map_err(|_| ControlError::InvalidUrl)?;
    // The wire query is separately encoded by Url, but the signature is over
    // Python/Android-style RFC 3986 encoded key-value pairs above.
    url.query_pairs_mut()
        .extend_pairs(&pairs)
        .append_pair("sign", &sign);
    Ok(url)
}

fn sha3_256(data: &[u8]) -> [u8; 32] {
    let mut hasher = Sha3::v256();
    hasher.update(data);
    let mut digest = [0; 32];
    hasher.finalize(&mut digest);
    digest
}

fn mgf1_sha256(seed: &[u8], length: usize) -> Vec<u8> {
    let mut result = Vec::with_capacity(length);
    for counter in 0..length.div_ceil(32) {
        result.extend(Sha256::digest(
            [seed, &(counter as u32).to_be_bytes()].concat(),
        ));
    }
    result.truncate(length);
    result
}

/// SHA3-256(PIN + App salt) as hex, RSAES-OAEP/SHA3-256/MGF1-SHA256,
/// URL-safe Base64. The random seed means ciphertext must not be cached.
pub fn encrypt_pin(pin: &str, public_key_text: &str) -> Result<String, ControlError> {
    let first = pin
        .chars()
        .next()
        .ok_or(ControlError::InvalidInput("PIN is empty"))?;
    let salt = PIN_SALTS[(first as usize) % PIN_SALTS.len()];
    let digest = sha3_256(format!("{pin}{salt}").as_bytes());
    let message = digest
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    let key_text = public_key_text.trim();
    let key = if key_text.contains("BEGIN") {
        RsaPublicKey::from_public_key_pem(key_text).map_err(|_| ControlError::InvalidPublicKey)?
    } else {
        let mut compact = key_text
            .split_whitespace()
            .collect::<String>()
            .replace('-', "+")
            .replace('_', "/");
        while compact.len() % 4 != 0 {
            compact.push('=');
        }
        let der = STANDARD
            .decode(compact)
            .map_err(|_| ControlError::InvalidPublicKey)?;
        RsaPublicKey::from_public_key_der(&der).map_err(|_| ControlError::InvalidPublicKey)?
    };
    if key.size() < 128 {
        return Err(ControlError::InvalidPublicKey);
    }
    let size = key.size();
    let hash_size = 32;
    if message.len() > size - 2 * hash_size - 2 {
        return Err(ControlError::Encryption);
    }
    let mut block = Vec::with_capacity(size - hash_size - 1);
    block.extend(sha3_256(b""));
    block.resize(size - message.len() - hash_size - 2, 0);
    block.push(1);
    block.extend(message.as_bytes());
    let mut seed = [0u8; 32];
    OsRng
        .try_fill_bytes(&mut seed)
        .map_err(|_| ControlError::Encryption)?;
    let mask = mgf1_sha256(&seed, block.len());
    for (value, mask) in block.iter_mut().zip(mask) {
        *value ^= mask;
    }
    let seed_mask = mgf1_sha256(&block, hash_size);
    for (value, mask) in seed.iter_mut().zip(seed_mask) {
        *value ^= mask;
    }
    let mut encoded = Vec::with_capacity(size);
    encoded.push(0);
    encoded.extend(seed);
    encoded.extend(block);
    let encoded_number = BigUint::from_bytes_be(&encoded);
    if &encoded_number >= key.n() {
        return Err(ControlError::Encryption);
    }
    let encrypted = encoded_number.modpow(key.e(), key.n());
    let mut bytes = encrypted.to_bytes_be();
    if bytes.len() > size {
        return Err(ControlError::Encryption);
    }
    let mut padded = vec![0u8; size - bytes.len()];
    padded.append(&mut bytes);
    Ok(URL_SAFE.encode(padded))
}

#[cfg(test)]
mod tests {
    use super::*;
    use rsa::{
        RsaPrivateKey,
        pkcs8::EncodePublicKey,
        traits::{PrivateKeyParts, PublicKeyParts},
    };

    fn profile() -> VehicleConfig {
        VehicleConfig {
            bearer_token: "test-token".into(),
            account_id: None,
            vehicle_id: "v".into(),
            device_id: "d".into(),
            app_id: "10002".into(),
            app_version: "6.9.0".into(),
            region: "cn".into(),
            language: "zh-CN".into(),
            vin_code: None,
        }
    }

    #[test]
    fn command_routes_and_fields_keep_unlock_start_separate() {
        let doors = build_command(
            VehicleAction::UnlockDoors,
            "v/1",
            "d",
            Some("cipher"),
            Some("key"),
            None,
            None,
        )
        .unwrap();
        let start = build_command(
            VehicleAction::UnlockStart,
            "v/1",
            "d",
            Some("cipher"),
            Some("key"),
            None,
            None,
        )
        .unwrap();
        assert!(doors.path.ends_with("/v%2F1/command/unlock_all_doors"));
        assert!(start.path.ends_with("/v%2F1/command/unlock_immo"));
        assert!(
            doors
                .form
                .as_ref()
                .unwrap()
                .iter()
                .any(|field| field == &("key_id".into(), "key".into()))
        );
        assert!(
            !start
                .form
                .as_ref()
                .unwrap()
                .iter()
                .any(|field| field.0 == "key_id")
        );
        assert_eq!(
            VehicleAction::UnlockStart.confirmation(),
            "UNLOCK AND START"
        );
    }

    #[test]
    fn ac_range_and_guard_fields_are_explicit() {
        assert!(build_command(VehicleAction::AcOn, "v", "d", None, None, Some(24.0), None).is_ok());
        assert!(
            build_command(
                VehicleAction::AcOn,
                "v",
                "d",
                None,
                None,
                Some(f64::NAN),
                None
            )
            .is_err()
        );
        assert!(
            build_command(VehicleAction::AcOn, "v", "d", None, None, Some(31.0), None).is_err()
        );
        let guard =
            build_command(VehicleAction::GuardOn, "v", "d", None, None, None, None).unwrap();
        assert_eq!(guard.form.unwrap(), vec![("vid".into(), "v".into())]);
        assert_eq!(
            guard.query,
            vec![("operation_confirmed".into(), "true".into())]
        );
    }

    #[test]
    fn ambiguous_or_failed_upstream_status_fails_closed() {
        assert!(command_accepted(
            &serde_json::json!({"result_code":"success"})
        ));
        assert!(!command_accepted(
            &serde_json::json!({"result_code":"pin_code_not_correct"})
        ));
        assert!(!business_success(&serde_json::json!({"result_code":null})));
        assert!(!business_success(
            &serde_json::json!({"a":{"code":"success"},"b":{"code":"failed"}})
        ));
        assert_eq!(
            unique_i64(
                &serde_json::json!({"data":{"vehicle_state":2}}),
                "vehicle_state"
            ),
            Some(2)
        );
        assert_eq!(
            unique_i64(
                &serde_json::json!({"a":{"vehicle_state":2},"b":{"vehicle_state":2}}),
                "vehicle_state"
            ),
            None
        );
    }

    #[tokio::test]
    async fn invalid_confirmation_stops_before_tls_or_vehicle_request() {
        let client = ControlClient {
            profile: profile(),
            pin_file: None,
            app_http: Client::new(),
            vehicle_http: Client::new(),
            gate: Mutex::new(()),
        };
        let input = ActionInput {
            action: VehicleAction::UnlockStart,
            confirmation: "UNLOCK DOORS".into(),
            temperature: None,
            recirculation: None,
            expand_mirrors: false,
            mirror_confirmation: None,
        };
        let result = timeout(Duration::from_millis(100), client.execute(input))
            .await
            .unwrap();
        assert!(matches!(result, Err(ControlError::InvalidInput(_))));
    }

    #[tokio::test]
    async fn unlock_without_server_pin_stops_before_network() {
        let client = ControlClient {
            profile: profile(),
            pin_file: None,
            app_http: Client::new(),
            vehicle_http: Client::new(),
            gate: Mutex::new(()),
        };
        let input = serde_json::from_value::<ActionInput>(serde_json::json!({
            "action": "unlock-doors", "confirmation": "UNLOCK DOORS"
        }))
        .unwrap();
        let result = timeout(Duration::from_millis(100), client.execute(input))
            .await
            .unwrap();
        assert!(matches!(result, Err(ControlError::PinUnavailable)));
    }

    #[test]
    fn action_body_rejects_client_supplied_pin() {
        assert!(
            serde_json::from_value::<ActionInput>(serde_json::json!({
                "action": "unlock-doors", "confirmation": "UNLOCK DOORS"
            }))
            .is_ok()
        );
        assert!(
            serde_json::from_value::<ActionInput>(serde_json::json!({
                "action": "unlock-doors", "confirmation": "UNLOCK DOORS", "pin": "123456"
            }))
            .is_err()
        );
    }

    #[test]
    fn state_poll_starts_immediately_then_backs_off() {
        assert_eq!(state_poll_delay(0), Duration::ZERO);
        assert_eq!(state_poll_delay(1), Duration::from_secs(1));
        assert_eq!(state_poll_delay(3), Duration::from_secs(1));
        assert_eq!(state_poll_delay(4), Duration::from_secs(3));
        assert_eq!(
            (1..18).map(state_poll_delay).sum::<Duration>(),
            Duration::from_secs(45)
        );
    }

    #[test]
    fn door_only_unlock_returns_acceptance_without_client_state_checks() {
        assert!(VehicleAction::UnlockDoors.needs_pin());
        assert!(!VehicleAction::UnlockDoors.requires_parked());
        assert!(!VehicleAction::UnlockDoors.polls_state());
        assert!(!VehicleAction::UnlockDoors.verified_after_poll());
        assert!(VehicleAction::UnlockStart.requires_parked());
        assert!(VehicleAction::UnlockStart.polls_state());
        assert!(VehicleAction::Lock.requires_parked());
        assert!(VehicleAction::Lock.polls_state());
    }

    #[test]
    fn signature_is_stable_and_covers_decoded_form_fields() {
        let plan =
            build_command(VehicleAction::AcOn, "v", "d", None, None, Some(24.0), None).unwrap();
        let first = signed_url(
            "https://icar.nio.com:4430",
            "POST",
            &plan.path,
            &profile(),
            1_700_000_000,
            &plan.query,
            plan.form.as_deref(),
        )
        .unwrap();
        let second = signed_url(
            "https://icar.nio.com:4430",
            "POST",
            &plan.path,
            &profile(),
            1_700_000_000,
            &plan.query,
            plan.form.as_deref(),
        )
        .unwrap();
        assert_eq!(first, second);
        assert!(
            first
                .as_str()
                .ends_with("sign=da0c05ce8d5ac29562559ab44d98df60")
        );
    }

    #[test]
    fn pin_ciphertext_decrypts_to_salted_sha3_digest() {
        let mut rng = OsRng;
        let key = RsaPrivateKey::new(&mut rng, 2048).unwrap();
        let public = key
            .to_public_key()
            .to_public_key_pem(Default::default())
            .unwrap();
        let encoded = encrypt_pin("123456", &public).unwrap();
        let encrypted = URL_SAFE.decode(encoded).unwrap();
        assert_eq!(encrypted.len(), 256);
        let encoded = BigUint::from_bytes_be(&encrypted)
            .modpow(key.d(), key.n())
            .to_bytes_be();
        let mut encoded = [vec![0u8; 256 - encoded.len()], encoded].concat();
        assert_eq!(encoded.remove(0), 0);
        let mut seed = encoded.drain(..32).collect::<Vec<_>>();
        let mut block = encoded;
        let seed_mask = mgf1_sha256(&block, 32);
        for (value, mask) in seed.iter_mut().zip(seed_mask) {
            *value ^= mask;
        }
        let block_mask = mgf1_sha256(&seed, block.len());
        for (value, mask) in block.iter_mut().zip(block_mask) {
            *value ^= mask;
        }
        assert_eq!(&block[..32], &sha3_256(b""));
        let separator = block.iter().position(|byte| *byte == 1).unwrap();
        assert!(block[32..separator].iter().all(|byte| *byte == 0));
        let expected = sha3_256(format!("123456{}", PIN_SALTS[49 % 10]).as_bytes())
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>();
        assert_eq!(&block[separator + 1..], expected.as_bytes());
    }
}
