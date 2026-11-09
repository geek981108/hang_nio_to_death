//! Owner-only PIN source shared by CLI issuance and protected vehicle actions.
//! The PIN is never serialized into an API request or stored in backend state.

use std::{
    env, fs,
    path::{Path, PathBuf},
};

const MAX_SECRET_FILE: u64 = 1024 * 1024;

pub fn configured_path() -> Result<Option<PathBuf>, &'static str> {
    let Some(raw) = env::var("NIO_CONTROL_PIN_FILE")
        .ok()
        .filter(|s| !s.trim().is_empty())
    else {
        return Ok(None);
    };
    let path = PathBuf::from(raw);
    if !path.is_absolute() {
        return Err("NIO_CONTROL_PIN_FILE must be an absolute path");
    }
    Ok(Some(path))
}

#[cfg(unix)]
pub fn read_pin(path: &Path, configured_vehicle: &str) -> Result<String, &'static str> {
    use std::os::unix::fs::PermissionsExt;
    let metadata = fs::symlink_metadata(path).map_err(|_| "PIN file is missing")?;
    if !metadata.file_type().is_file() || metadata.len() == 0 || metadata.len() > MAX_SECRET_FILE {
        return Err("PIN file must be a regular file no larger than 1 MiB");
    }
    if metadata.permissions().mode() & 0o077 != 0 {
        return Err("PIN file must be owner-only (0600)");
    }
    let raw = fs::read(path).map_err(|_| "PIN file could not be read")?;
    if raw.len() > MAX_SECRET_FILE as usize {
        return Err("PIN file is too large");
    }
    let text = std::str::from_utf8(&raw).map_err(|_| "PIN file must be UTF-8")?;
    parse_pin(text, configured_vehicle)
}

#[cfg(not(unix))]
pub fn read_pin(_path: &Path, _configured_vehicle: &str) -> Result<String, &'static str> {
    Err("PIN file requires a Unix host")
}

fn parse_pin(text: &str, configured_vehicle: &str) -> Result<String, &'static str> {
    let mut pin = None;
    let mut vehicle = None;
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let (name, value) = line
            .split_once('=')
            .ok_or("PIN file contains a malformed line")?;
        let value = value.trim().trim_matches(|ch| ch == '\'' || ch == '"');
        match name.trim() {
            "PIN" if pin.is_none() => pin = Some(value.to_owned()),
            "NIO_VEHICLE_ID" if vehicle.is_none() => vehicle = Some(value.to_owned()),
            _ => return Err("PIN file has an unknown or duplicate field"),
        }
    }
    if vehicle.as_deref() != Some(configured_vehicle) {
        return Err("PIN file vehicle does not match the session");
    }
    let pin = pin.ok_or("PIN is missing")?;
    if pin.is_empty() || pin.len() > 256 || pin.chars().any(char::is_control) {
        return Err("PIN is invalid");
    }
    Ok(pin)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_only_matching_vehicle_and_pin() {
        assert_eq!(
            parse_pin("NIO_VEHICLE_ID=v\nPIN=123456\n", "v").unwrap(),
            "123456"
        );
        assert!(parse_pin("NIO_VEHICLE_ID=x\nPIN=123456\n", "v").is_err());
        assert!(parse_pin("NIO_VEHICLE_ID=v\nPIN=123456\nPIN=111111\n", "v").is_err());
        assert!(parse_pin("NIO_VEHICLE_ID=v\nPIN=\n", "v").is_err());
        assert!(parse_pin("NIO_VEHICLE_ID=v\nPIN=123456\nEXTRA=x\n", "v").is_err());
    }
}
