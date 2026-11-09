//! Explicit CLI-only TLS certificate issuance. The server never exposes this as an HTTP API.
//! Digital-key enrollment is intentionally absent: it has not passed production validation.

use std::{
    fs::{self, File, OpenOptions},
    io::{self, Write},
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};

use base64::{Engine as _, engine::general_purpose::STANDARD};
use chrono::Utc;
use p256::{
    SecretKey,
    pkcs8::{EncodePrivateKey, EncodePublicKey, LineEnding},
};
use rand::{RngCore, rngs::OsRng};
use reqwest::{Client, Method, redirect::Policy};
use rustls::{ClientConfig, RootCertStore};
use rustls_pki_types::{CertificateDer, PrivateKeyDer, pem::PemObject};
use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};
use webpki::EndEntityCert;

use crate::{
    config::VehicleConfig,
    pin_secret,
    vehicle_control::{
        encrypt_pin, pinned_icar_tls_config, quote, signed_url, verify_pinned_icar_leaf,
    },
};

const APP_ORIGIN: &str = "https://app.nio.com";
const ICAR_ORIGIN: &str = "https://icar.nio.com:4430";
const ISSUE_PATH: &str = "/api/1/sec/mobile/user_device_cert";
const MAX_FILE: u64 = 1024 * 1024;
const MAX_RESPONSE: usize = 1024 * 1024;

#[derive(Debug, thiserror::Error)]
pub enum IssueError {
    #[error(
        "usage: issue-identity --live --output-dir ABSOLUTE_PATH --bootstrap-cert ABSOLUTE_PATH --bootstrap-key ABSOLUTE_PATH --server-ca ABSOLUTE_PATH [--pin-file ABSOLUTE_PATH]; configure NIO_CONTROL_PIN_FILE if --pin-file is omitted"
    )]
    Usage,
    #[error(
        "usage: verify-bootstrap --live --bootstrap-cert ABSOLUTE_PATH --bootstrap-key ABSOLUTE_PATH --server-ca ABSOLUTE_PATH"
    )]
    BootstrapUsage,
    #[error("certificate issuance is inert without --live")]
    NotLive,
    #[error("vehicle session is not configured")]
    NoSession,
    #[error("invalid issuance input: {0}")]
    InvalidInput(&'static str),
    #[error("TLS preflight failed before credential-bearing requests")]
    TlsPreflight,
    #[error("upstream request failed before a usable response")]
    Transport,
    #[error("upstream returned HTTP {0}")]
    Http(u16),
    #[error("upstream response was invalid or rejected")]
    InvalidResponse,
    #[error("returned TLS certificate did not match the locally generated private key")]
    CertificateMismatch,
    #[error(
        "identity was saved, but a read-only mTLS status check failed; do not reissue automatically"
    )]
    PostIssueVerification,
    #[error("identity could not be saved safely")]
    Save,
}

#[derive(Debug)]
struct Options {
    output_dir: PathBuf,
    pin_file: Option<PathBuf>,
    bootstrap_cert: PathBuf,
    bootstrap_key: PathBuf,
    server_ca: PathBuf,
}

#[derive(Debug)]
struct BootstrapOptions {
    certificate: PathBuf,
    private_key: PathBuf,
    server_ca: PathBuf,
}

fn parse_bootstrap_options(args: &[String]) -> Result<BootstrapOptions, IssueError> {
    let mut live = false;
    let mut certificate = None;
    let mut private_key = None;
    let mut server_ca = None;
    let mut rest = args.iter();
    while let Some(arg) = rest.next() {
        let slot = match arg.as_str() {
            "--live" if !live => {
                live = true;
                continue;
            }
            "--bootstrap-cert" => &mut certificate,
            "--bootstrap-key" => &mut private_key,
            "--server-ca" => &mut server_ca,
            _ => return Err(IssueError::BootstrapUsage),
        };
        if slot.is_some() {
            return Err(IssueError::BootstrapUsage);
        }
        let value = rest.next().ok_or(IssueError::BootstrapUsage)?;
        let path = PathBuf::from(value);
        if !path.is_absolute() {
            return Err(IssueError::BootstrapUsage);
        }
        *slot = Some(path);
    }
    if !live {
        return Err(IssueError::NotLive);
    }
    Ok(BootstrapOptions {
        certificate: certificate.ok_or(IssueError::BootstrapUsage)?,
        private_key: private_key.ok_or(IssueError::BootstrapUsage)?,
        server_ca: server_ca.ok_or(IssueError::BootstrapUsage)?,
    })
}

pub async fn verify_bootstrap_cli(args: &[String]) -> Result<(), IssueError> {
    let options = parse_bootstrap_options(args)?;
    owner_only(&options.private_key)?;
    let cert = read_bounded(
        &options.certificate,
        "bootstrap certificate is missing or too large",
    )?;
    let key = read_bounded(
        &options.private_key,
        "bootstrap private key is missing or too large",
    )?;
    let ca = read_bounded(&options.server_ca, "server CA is missing or too large")?;
    let config = pem_tls_config(load_roots(&ca)?, &cert, &key)?;
    verify_pinned_icar_leaf(config)
        .await
        .map_err(|_| IssueError::TlsPreflight)?;
    println!(
        "Pinned client-authenticated TLS handshake passed. No HTTP request, token, PIN, certificate issuance, or vehicle command was sent."
    );
    Ok(())
}

fn parse_options(args: &[String]) -> Result<Options, IssueError> {
    let mut live = false;
    let mut output_dir = None;
    let mut pin_file = None;
    let mut bootstrap_cert = None;
    let mut bootstrap_key = None;
    let mut server_ca = None;
    let mut rest = args.iter();
    while let Some(arg) = rest.next() {
        let slot = match arg.as_str() {
            "--live" if !live => {
                live = true;
                continue;
            }
            "--output-dir" => &mut output_dir,
            "--pin-file" => &mut pin_file,
            "--bootstrap-cert" => &mut bootstrap_cert,
            "--bootstrap-key" => &mut bootstrap_key,
            "--server-ca" => &mut server_ca,
            _ => return Err(IssueError::Usage),
        };
        if slot.is_some() {
            return Err(IssueError::Usage);
        }
        let value = rest.next().ok_or(IssueError::Usage)?;
        if value.starts_with("--") {
            return Err(IssueError::Usage);
        }
        let path = PathBuf::from(value);
        if !path.is_absolute() {
            return Err(IssueError::Usage);
        }
        *slot = Some(path);
    }
    if !live {
        return Err(IssueError::NotLive);
    }
    let output_dir = output_dir.ok_or(IssueError::Usage)?;
    if output_dir == Path::new("/") || output_dir.exists() {
        return Err(IssueError::InvalidInput(
            "output directory must be a new, non-root path",
        ));
    }
    Ok(Options {
        output_dir,
        pin_file,
        bootstrap_cert: bootstrap_cert.ok_or(IssueError::Usage)?,
        bootstrap_key: bootstrap_key.ok_or(IssueError::Usage)?,
        server_ca: server_ca.ok_or(IssueError::Usage)?,
    })
}

fn read_bounded(path: &Path, label: &'static str) -> Result<Vec<u8>, IssueError> {
    let metadata = fs::symlink_metadata(path).map_err(|_| IssueError::InvalidInput(label))?;
    if !metadata.is_file() || metadata.len() == 0 || metadata.len() > MAX_FILE {
        return Err(IssueError::InvalidInput(label));
    }
    fs::read(path).map_err(|_| IssueError::InvalidInput(label))
}

#[cfg(unix)]
fn owner_only(path: &Path) -> Result<(), IssueError> {
    use std::os::unix::fs::PermissionsExt;
    let metadata = fs::symlink_metadata(path)
        .map_err(|_| IssueError::InvalidInput("private file is missing"))?;
    if !metadata.file_type().is_file() {
        return Err(IssueError::InvalidInput("private file must be regular"));
    }
    let mode = metadata.permissions().mode();
    if mode & 0o077 != 0 {
        return Err(IssueError::InvalidInput(
            "private file must be owner-only (0600)",
        ));
    }
    Ok(())
}

#[cfg(not(unix))]
fn owner_only(_path: &Path) -> Result<(), IssueError> {
    Err(IssueError::InvalidInput("issuance requires a Unix host"))
}

struct IssuerHttp {
    profile: VehicleConfig,
    app: Client,
    icar: Client,
    roots: RootCertStore,
}

fn load_roots(ca_pem: &[u8]) -> Result<RootCertStore, IssueError> {
    let mut roots = RootCertStore::empty();
    for cert in CertificateDer::pem_slice_iter(ca_pem) {
        roots
            .add(cert.map_err(|_| IssueError::InvalidInput("server CA bundle is invalid"))?)
            .map_err(|_| IssueError::InvalidInput("server CA bundle is invalid"))?;
    }
    if roots.is_empty() {
        return Err(IssueError::InvalidInput("server CA bundle is empty"));
    }
    Ok(roots)
}

fn pem_tls_config(
    roots: RootCertStore,
    cert_pem: &[u8],
    key_pem: &[u8],
) -> Result<Arc<ClientConfig>, IssueError> {
    let certs = CertificateDer::pem_slice_iter(cert_pem)
        .collect::<Result<Vec<_>, _>>()
        .map_err(|_| IssueError::InvalidInput("client certificate is invalid"))?;
    if certs.is_empty() {
        return Err(IssueError::InvalidInput("client certificate is empty"));
    }
    let key = PrivateKeyDer::from_pem_slice(key_pem)
        .map_err(|_| IssueError::InvalidInput("client private key is invalid"))?;
    let config = pinned_icar_tls_config(roots, certs, key)
        .map_err(|_| IssueError::InvalidInput("client identity is invalid"))?;
    Ok(Arc::new(config))
}

impl IssuerHttp {
    fn new(
        profile: VehicleConfig,
        cert_pem: &[u8],
        key_pem: &[u8],
        ca_pem: &[u8],
    ) -> Result<Self, IssueError> {
        let roots = load_roots(ca_pem)?;
        let tls = pem_tls_config(roots.clone(), cert_pem, key_pem)?;
        let user_agent = format!(
            "NextevCar/{} (independent Rust issuer)",
            profile.app_version
        );
        let icar = Client::builder()
            .timeout(Duration::from_secs(20))
            .redirect(Policy::none())
            .user_agent(user_agent.clone())
            .use_preconfigured_tls(tls.as_ref().clone())
            .build()
            .map_err(|_| IssueError::InvalidInput("mTLS client could not be initialized"))?;
        let app = Client::builder()
            .timeout(Duration::from_secs(20))
            .redirect(Policy::none())
            .user_agent(user_agent)
            .build()
            .map_err(|_| IssueError::InvalidInput("app client could not be initialized"))?;
        Ok(Self {
            profile,
            app,
            icar,
            roots,
        })
    }

    fn tls_config(&self, cert_pem: &[u8], key_pem: &[u8]) -> Result<Arc<ClientConfig>, IssueError> {
        pem_tls_config(self.roots.clone(), cert_pem, key_pem)
    }

    async fn request(
        &self,
        method: Method,
        origin: &str,
        path: &str,
        query: &[(String, String)],
        form: Option<&[(String, String)]>,
        headers: &[(&str, &str)],
    ) -> Result<Value, IssueError> {
        let url = signed_url(
            origin,
            method.as_str(),
            path,
            &self.profile,
            Utc::now().timestamp(),
            query,
            form,
        )
        .map_err(|_| IssueError::InvalidInput("request could not be signed"))?;
        let client = if origin == ICAR_ORIGIN {
            &self.icar
        } else {
            &self.app
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
        let mut response = request.send().await.map_err(|_| IssueError::Transport)?;
        let status = response.status();
        let mut body = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(|_| IssueError::Transport)? {
            if body.len().saturating_add(chunk.len()) > MAX_RESPONSE {
                return Err(IssueError::InvalidResponse);
            }
            body.extend_from_slice(&chunk);
        }
        if !status.is_success() {
            return Err(IssueError::Http(status.as_u16()));
        }
        let payload: Value =
            serde_json::from_slice(&body).map_err(|_| IssueError::InvalidResponse)?;
        if !business_success(&payload) {
            return Err(IssueError::InvalidResponse);
        }
        Ok(payload)
    }
}

fn collect<'a>(value: &'a Value, key: &str, values: &mut Vec<&'a Value>) {
    match value {
        Value::Object(map) => {
            for (name, child) in map {
                if name == key {
                    values.push(child);
                }
                collect(child, key, values);
            }
        }
        Value::Array(items) => {
            for child in items {
                collect(child, key, values);
            }
        }
        _ => {}
    }
}

fn single_string(value: &Value, key: &str) -> Result<String, IssueError> {
    let mut found = Vec::new();
    collect(value, key, &mut found);
    match found.as_slice() {
        [Value::String(text)] if !text.trim().is_empty() => Ok(text.clone()),
        _ => Err(IssueError::InvalidResponse),
    }
}

fn business_success(value: &Value) -> bool {
    let mut found = Vec::new();
    collect(value, "result_code", &mut found);
    match found.as_slice() {
        [Value::String(text)] => matches!(text.as_str(), "success" | "0"),
        [Value::Number(number)] => number.as_i64() == Some(0),
        _ => false,
    }
}

fn rejects_server_private_key(value: &Value) -> bool {
    ["tls_private_key", "virtualkey_private_key"]
        .iter()
        .any(|name| {
            let mut found = Vec::new();
            collect(value, name, &mut found);
            found
                .iter()
                .any(|item| !item.is_null() && item.as_str() != Some(""))
        })
}

fn cert_pem(der: &[u8]) -> String {
    let encoded = STANDARD.encode(der);
    let mut pem = String::from("-----BEGIN CERTIFICATE-----\n");
    for chunk in encoded.as_bytes().chunks(64) {
        pem.push_str(std::str::from_utf8(chunk).expect("Base64 is ASCII"));
        pem.push('\n');
    }
    pem.push_str("-----END CERTIFICATE-----\n");
    pem
}

fn decode_cert_bundle(text: &str) -> Result<(CertificateDer<'static>, Vec<u8>), IssueError> {
    let certs = if text.contains("-----BEGIN CERTIFICATE-----") {
        CertificateDer::pem_slice_iter(text.as_bytes())
            .collect::<Result<Vec<_>, _>>()
            .map_err(|_| IssueError::InvalidResponse)?
    } else {
        let compact = text.split_whitespace().collect::<String>();
        let der = STANDARD
            .decode(compact)
            .map_err(|_| IssueError::InvalidResponse)?;
        vec![CertificateDer::from(der)]
    };
    let leaf = certs.first().ok_or(IssueError::InvalidResponse)?.clone();
    let mut bundle = Vec::new();
    for cert in &certs {
        bundle.extend_from_slice(cert_pem(cert.as_ref()).as_bytes());
    }
    Ok((leaf, bundle))
}

fn ensure_matches_local_key(
    cert: &CertificateDer<'_>,
    public_spki: &[u8],
) -> Result<(), IssueError> {
    let parsed = EndEntityCert::try_from(cert).map_err(|_| IssueError::InvalidResponse)?;
    if parsed.subject_public_key_info().as_ref() != public_spki {
        return Err(IssueError::CertificateMismatch);
    }
    Ok(())
}

#[cfg(unix)]
fn write_private(path: &Path, data: &[u8]) -> Result<(), IssueError> {
    use std::os::unix::fs::OpenOptionsExt;
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .map_err(|_| IssueError::Save)?;
    file.write_all(data)
        .and_then(|_| file.sync_all())
        .map_err(|_| IssueError::Save)
}

#[cfg(not(unix))]
fn write_private(_path: &Path, _data: &[u8]) -> Result<(), IssueError> {
    Err(IssueError::Save)
}

#[cfg(unix)]
fn create_private_dir(path: &Path) -> Result<(), IssueError> {
    use std::os::unix::fs::DirBuilderExt;
    fs::DirBuilder::new()
        .mode(0o700)
        .create(path)
        .map_err(|_| IssueError::Save)
}

#[cfg(not(unix))]
fn create_private_dir(_path: &Path) -> Result<(), IssueError> {
    Err(IssueError::Save)
}

fn sync_private_dir(path: &Path) -> Result<(), IssueError> {
    File::open(path)
        .and_then(|dir| dir.sync_all())
        .map_err(|_| IssueError::Save)
}

fn prepare_identity(path: &Path, key_pem: &[u8]) -> Result<(), IssueError> {
    create_private_dir(path)?;
    let key_path = path.join("tls-private-key.pem");
    let pending_path = path.join("issuance-pending.json");
    let pending = json!({
        "prepared_at": Utc::now().to_rfc3339(),
        "status": "issuance_outcome_unknown",
        "note": "A local private key was saved before the issuance POST. Do not automatically retry or delete this directory."
    });
    let data = (|| {
        write_private(&key_path, key_pem)?;
        write_private(
            &pending_path,
            serde_json::to_string_pretty(&pending)
                .map_err(|_| IssueError::Save)?
                .as_bytes(),
        )?;
        sync_private_dir(path)
    })();
    // No production POST has occurred yet; only our newly created files are removed.
    if data.is_err() {
        for file in [&key_path, &pending_path] {
            let _ = fs::remove_file(file);
        }
        let _ = fs::remove_dir(path);
    }
    data
}

fn finish_identity(
    path: &Path,
    cert_pem: &[u8],
    leaf: &CertificateDer<'_>,
) -> Result<(), IssueError> {
    let cert_path = path.join("tls-certificate.pem");
    let metadata_path = path.join("metadata.json");
    let metadata = json!({
        "created_at": Utc::now().to_rfc3339(),
        "tls_certificate_sha256": format!("{:x}", Sha256::digest(leaf.as_ref())),
        "digital_key_status": "not_requested",
        "note": "PIN and bearer token are intentionally absent."
    });
    // After the POST, never delete the locally generated key on a write error.
    write_private(&cert_path, cert_pem)?;
    write_private(
        &metadata_path,
        serde_json::to_string_pretty(&metadata)
            .map_err(|_| IssueError::Save)?
            .as_bytes(),
    )?;
    sync_private_dir(path)?;
    let _ = fs::remove_file(path.join("issuance-pending.json"));
    Ok(())
}

fn confirm() -> Result<(), IssueError> {
    println!("Type ISSUE TLS CERTIFICATE to make one production issuance POST (no retry):");
    io::stdout()
        .flush()
        .map_err(|_| IssueError::InvalidInput("confirmation unavailable"))?;
    let mut line = String::new();
    io::stdin()
        .read_line(&mut line)
        .map_err(|_| IssueError::InvalidInput("confirmation unavailable"))?;
    if line.trim_end_matches(['\r', '\n']) != "ISSUE TLS CERTIFICATE" {
        return Err(IssueError::InvalidInput("confirmation did not match"));
    }
    Ok(())
}

pub async fn run_cli(args: &[String], profile: Option<VehicleConfig>) -> Result<(), IssueError> {
    let options = parse_options(args)?;
    let profile = profile.ok_or(IssueError::NoSession)?;
    owner_only(&options.bootstrap_key)?;
    let pin_path = match options.pin_file {
        Some(path) => path,
        None => pin_secret::configured_path()
            .map_err(IssueError::InvalidInput)?
            .ok_or(IssueError::InvalidInput(
                "NIO_CONTROL_PIN_FILE or --pin-file is required",
            ))?,
    };
    let pin =
        pin_secret::read_pin(&pin_path, &profile.vehicle_id).map_err(IssueError::InvalidInput)?;
    let bootstrap_cert = read_bounded(
        &options.bootstrap_cert,
        "bootstrap certificate is missing or too large",
    )?;
    let bootstrap_key = read_bounded(
        &options.bootstrap_key,
        "bootstrap private key is missing or too large",
    )?;
    let ca = read_bounded(&options.server_ca, "server CA is missing or too large")?;
    let issuer = IssuerHttp::new(profile, &bootstrap_cert, &bootstrap_key, &ca)?;
    let bootstrap_tls = issuer.tls_config(&bootstrap_cert, &bootstrap_key)?;
    confirm()?;
    verify_pinned_icar_leaf(bootstrap_tls)
        .await
        .map_err(|_| IssueError::TlsPreflight)?;
    let mut nonce_bytes = [0u8; 32];
    OsRng
        .try_fill_bytes(&mut nonce_bytes)
        .map_err(|_| IssueError::InvalidInput("secure randomness unavailable"))?;
    let nonce = nonce_bytes
        .iter()
        .map(|byte| char::from(b'A' + byte % 26))
        .collect::<String>();
    let key_payload = issuer
        .request(
            Method::GET,
            APP_ORIGIN,
            "/acc/2/get_encryption",
            &[("nonce".into(), nonce)],
            None,
            &[],
        )
        .await?;
    let key = single_string(&key_payload, "key")?;
    let key_id = single_string(&key_payload, "key_id")?;
    let encrypted_pin = encrypt_pin(&pin, &key)
        .map_err(|_| IssueError::InvalidInput("PIN could not be encrypted"))?;
    let local_key = SecretKey::random(&mut OsRng);
    let public_spki = local_key
        .public_key()
        .to_public_key_der()
        .map_err(|_| IssueError::InvalidInput("local P-256 public key could not be encoded"))?;
    let private_pem = local_key
        .to_pkcs8_pem(LineEnding::LF)
        .map_err(|_| IssueError::Save)?;
    let public_wire = STANDARD.encode(public_spki.as_bytes());
    let form = vec![
        ("key_id".into(), key_id),
        ("pin_code".into(), encrypted_pin),
        ("mobile_public_key".into(), public_wire),
        ("device_id".into(), issuer.profile.device_id.clone()),
        ("mode".into(), "ecc".into()),
        ("with_tls".into(), "true".into()),
        ("with_dk".into(), "false".into()),
    ];
    prepare_identity(&options.output_dir, private_pem.as_bytes())?;
    println!(
        "Local private key prepared in {}. If issuance fails, retain this directory and do not automatically retry.",
        options.output_dir.display()
    );
    let response = issuer
        .request(
            Method::POST,
            ICAR_ORIGIN,
            ISSUE_PATH,
            &[],
            Some(&form),
            &[("X-Requested-Type", "RemoveDeviceId")],
        )
        .await?;
    if rejects_server_private_key(&response) {
        return Err(IssueError::InvalidResponse);
    }
    let cert_text = single_string(&response, "tls_cert")?;
    let (leaf, certificate_bundle) = decode_cert_bundle(&cert_text)?;
    ensure_matches_local_key(&leaf, public_spki.as_bytes())?;
    finish_identity(&options.output_dir, &certificate_bundle, &leaf)?;
    println!(
        "TLS identity saved in an owner-only directory: {}",
        options.output_dir.display()
    );
    let new_issuer = IssuerHttp::new(
        issuer.profile,
        &certificate_bundle,
        private_pem.as_bytes(),
        &ca,
    )?;
    let new_tls = new_issuer.tls_config(&certificate_bundle, private_pem.as_bytes())?;
    verify_pinned_icar_leaf(new_tls)
        .await
        .map_err(|_| IssueError::PostIssueVerification)?;
    let path = format!(
        "/api/2/rvs/vehicle/{}/status",
        quote(&new_issuer.profile.vehicle_id)
    );
    new_issuer
        .request(
            Method::GET,
            ICAR_ORIGIN,
            &path,
            &[("field".into(), "offcar_mode_status".into())],
            None,
            &[
                ("widget_family", "accessoryCircular"),
                ("widget_identifier", "widget.small.watch.nio.guardian"),
            ],
        )
        .await
        .map_err(|_| IssueError::PostIssueVerification)?;
    println!("Read-only mTLS vehicle status check passed; no vehicle command was sent.");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_inert_and_no_existing_output_overwrite() {
        assert!(matches!(parse_options(&[]), Err(IssueError::NotLive)));
        assert!(matches!(
            parse_bootstrap_options(&[]),
            Err(IssueError::NotLive)
        ));
        let args = [
            "--live",
            "--output-dir",
            "/",
            "--pin-file",
            "/p",
            "--bootstrap-cert",
            "/c",
            "--bootstrap-key",
            "/k",
            "--server-ca",
            "/a",
        ]
        .map(str::to_owned);
        assert!(matches!(
            parse_options(&args),
            Err(IssueError::InvalidInput(_))
        ));
        let unique_output = std::env::temp_dir().join(format!(
            "nio-identity-test-{}-{}",
            std::process::id(),
            rand::random::<u64>()
        ));
        let args_without_pin = vec![
            "--live".to_owned(),
            "--output-dir".to_owned(),
            unique_output.display().to_string(),
            "--bootstrap-cert".to_owned(),
            "/c".to_owned(),
            "--bootstrap-key".to_owned(),
            "/k".to_owned(),
            "--server-ca".to_owned(),
            "/a".to_owned(),
        ];
        let parsed = parse_options(&args_without_pin).unwrap();
        assert!(parsed.pin_file.is_none());
        let verify_args = [
            "--live",
            "--bootstrap-cert",
            "/c",
            "--bootstrap-key",
            "/k",
            "--server-ca",
            "/a",
        ]
        .map(str::to_owned);
        assert!(parse_bootstrap_options(&verify_args).is_ok());
    }

    #[test]
    fn rejects_server_private_key_material() {
        assert!(!rejects_server_private_key(
            &json!({"tls_private_key":null})
        ));
        assert!(rejects_server_private_key(
            &json!({"data":{"tls_private_key":"secret"}})
        ));
        assert!(!business_success(
            &json!({"result_code":"pin_code_not_correct"})
        ));
        assert!(business_success(&json!({"result_code":"success"})));
    }

    #[test]
    fn parses_certificate_spki_without_trusting_server_private_key() {
        let _ = cert_pem(&[1, 2, 3]);
        assert!(decode_cert_bundle("not-a-certificate").is_err());
        assert!(single_string(&json!({"data":{"key_id":"a"}}), "key_id").is_ok());
        assert!(single_string(&json!({"a":{"key_id":"a"},"b":{"key_id":"b"}}), "key_id").is_err());
    }

    #[cfg(unix)]
    #[test]
    fn prepared_identity_keeps_key_if_completion_fails() {
        use std::os::unix::fs::PermissionsExt;
        let path = std::env::temp_dir().join(format!(
            "nio-issuer-test-{}-{}",
            std::process::id(),
            rand::random::<u64>()
        ));
        prepare_identity(&path, b"synthetic-key").unwrap();
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o700
        );
        let key_path = path.join("tls-private-key.pem");
        assert_eq!(fs::read(&key_path).unwrap(), b"synthetic-key");
        assert_eq!(
            fs::metadata(&key_path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert!(path.join("issuance-pending.json").exists());
        // A local write collision after a hypothetical POST must not erase the key.
        fs::write(path.join("tls-certificate.pem"), b"collision").unwrap();
        let invalid_leaf = CertificateDer::from(vec![1, 2, 3]);
        assert!(finish_identity(&path, b"synthetic-certificate", &invalid_leaf).is_err());
        assert!(key_path.exists());
        assert!(path.join("issuance-pending.json").exists());
        fs::remove_file(path.join("tls-private-key.pem")).unwrap();
        fs::remove_file(path.join("tls-certificate.pem")).unwrap();
        fs::remove_file(path.join("issuance-pending.json")).unwrap();
        fs::remove_dir(path).unwrap();
    }
}
