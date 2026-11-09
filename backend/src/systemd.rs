//! Fixed Linux systemd lifecycle for this single backend service.
//! The installer never embeds secrets in the unit and keeps the existing
//! /root/nio working directory so dotenvy can read its protected .env file.

use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    net::{TcpStream, ToSocketAddrs},
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    process::Command,
    thread,
    time::Duration,
};

use uuid::Uuid;

const SERVICE: &str = "nio-swap-history-backend.service";
const UNIT: &str = "/etc/systemd/system/nio-swap-history-backend.service";
const PROGRAM: &str = "/root/nio/nio-swap-history-backend";
const WORK_DIR: &str = "/root/nio";

pub fn handle(command: &str) -> Result<(), Box<dyn std::error::Error>> {
    if !cfg!(target_os = "linux") {
        return Err("systemd commands are only available on Linux".into());
    }
    match command {
        "install" => install(),
        "uninstall" => uninstall(),
        "status" => status(),
        _ => Err("unknown systemd command".into()),
    }
}

fn unit_contents() -> &'static str {
    "[Unit]\n\
Description=NIO Swap History Backend\n\
Wants=network-online.target\n\
After=network-online.target postgresql.service\n\n\
[Service]\n\
Type=exec\n\
User=root\n\
Group=root\n\
WorkingDirectory=/root/nio\n\
ExecStart=/root/nio/nio-swap-history-backend serve\n\
Restart=always\n\
RestartSec=5\n\
TimeoutStopSec=30\n\
UMask=0077\n\
NoNewPrivileges=true\n\
PrivateTmp=true\n\
ProtectSystem=full\n\
StandardOutput=journal\n\
StandardError=journal\n\n\
[Install]\n\
WantedBy=multi-user.target\n"
}

fn require_root_and_systemd() -> Result<(), Box<dyn std::error::Error>> {
    let output = Command::new("/usr/bin/id").arg("-u").output()?;
    if !output.status.success() || output.stdout != b"0\n" {
        return Err("run this command as root".into());
    }
    if !Path::new("/run/systemd/system").exists() {
        return Err("systemd is not the active service manager".into());
    }
    Ok(())
}

fn run(program: &str, args: &[&str]) -> Result<(), Box<dyn std::error::Error>> {
    let output = Command::new(program).args(args).output()?;
    if !output.status.success() {
        return Err(format!(
            "{} {} failed: {}",
            program,
            args.join(" "),
            String::from_utf8_lossy(&output.stderr).trim()
        )
        .into());
    }
    Ok(())
}

fn systemctl(args: &[&str]) -> Result<(), Box<dyn std::error::Error>> {
    run("/usr/bin/systemctl", args)
}

fn systemctl_success(args: &[&str]) -> bool {
    Command::new("/usr/bin/systemctl")
        .args(args)
        .status()
        .is_ok_and(|status| status.success())
}

fn refuse_symlink(path: &Path) -> Result<(), Box<dyn std::error::Error>> {
    if path
        .symlink_metadata()
        .is_ok_and(|metadata| metadata.file_type().is_symlink())
    {
        return Err(format!("refusing to replace symlink {}", path.display()).into());
    }
    Ok(())
}

fn stage_file(
    source: &Path,
    destination: &Path,
    mode: u32,
) -> Result<PathBuf, Box<dyn std::error::Error>> {
    refuse_symlink(destination)?;
    let parent = destination.parent().ok_or("destination has no parent")?;
    let temporary = parent.join(format!(
        ".{}.{}.tmp",
        destination.file_name().unwrap().to_string_lossy(),
        Uuid::new_v4()
    ));
    let mut input = File::open(source)?;
    let mut output = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temporary)?;
    if let Err(error) = (|| -> std::io::Result<()> {
        std::io::copy(&mut input, &mut output)?;
        output.set_permissions(fs::Permissions::from_mode(mode))?;
        output.sync_all()?;
        Ok(())
    })() {
        let _ = fs::remove_file(&temporary);
        return Err(error.into());
    }
    Ok(temporary)
}

fn stage_text(contents: &str, destination: &Path) -> Result<PathBuf, Box<dyn std::error::Error>> {
    refuse_symlink(destination)?;
    let parent = destination.parent().ok_or("destination has no parent")?;
    let temporary = parent.join(format!(".{}.{}.service", SERVICE, Uuid::new_v4()));
    let mut output = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temporary)?;
    if let Err(error) = (|| -> std::io::Result<()> {
        output.write_all(contents.as_bytes())?;
        output.set_permissions(fs::Permissions::from_mode(0o644))?;
        output.sync_all()?;
        Ok(())
    })() {
        let _ = fs::remove_file(&temporary);
        return Err(error.into());
    }
    Ok(temporary)
}

fn sync_parent(path: &Path) -> Result<(), Box<dyn std::error::Error>> {
    File::open(path.parent().ok_or("path has no parent")?)?.sync_all()?;
    Ok(())
}

fn install() -> Result<(), Box<dyn std::error::Error>> {
    require_root_and_systemd()?;
    let program = Path::new(PROGRAM);
    let unit = Path::new(UNIT);
    let work_dir = Path::new(WORK_DIR);
    if !work_dir.join(".env").is_file() {
        return Err(format!("{} must contain a configured .env file", WORK_DIR).into());
    }
    let current_exe = fs::canonicalize(std::env::current_exe()?)?;
    let staged_program = stage_file(&current_exe, program, 0o755)?;
    let staged_unit = match stage_text(unit_contents(), unit) {
        Ok(path) => path,
        Err(error) => {
            let _ = fs::remove_file(staged_program);
            return Err(error);
        }
    };
    let old_active = systemctl_success(&["is-active", "--quiet", SERVICE]);
    let old_enabled = systemctl_success(&["is-enabled", "--quiet", SERVICE]);
    let suffix = Uuid::new_v4();
    let program_backup = program.with_extension(format!("rollback-{suffix}"));
    let unit_backup = unit.with_extension(format!("rollback-{suffix}"));
    let had_program = program.exists();
    let had_unit = unit.exists();
    let backup_result = (|| -> Result<(), Box<dyn std::error::Error>> {
        if had_program {
            fs::copy(program, &program_backup)?;
            File::open(&program_backup)?.sync_all()?;
        }
        if had_unit {
            fs::copy(unit, &unit_backup)?;
            File::open(&unit_backup)?.sync_all()?;
        }
        Ok(())
    })();
    if let Err(error) = backup_result {
        let _ = fs::remove_file(&staged_program);
        let _ = fs::remove_file(&staged_unit);
        let _ = fs::remove_file(&program_backup);
        let _ = fs::remove_file(&unit_backup);
        return Err(error);
    }

    let result = (|| -> Result<(), Box<dyn std::error::Error>> {
        fs::rename(&staged_program, program)?;
        sync_parent(program)?;
        fs::rename(&staged_unit, unit)?;
        sync_parent(unit)?;
        run("/usr/bin/systemd-analyze", &["verify", UNIT])?;
        systemctl(&["daemon-reload"])?;
        systemctl(&["enable", SERVICE])?;
        if old_active {
            systemctl(&["restart", SERVICE])?;
        } else {
            systemctl(&["start", SERVICE])?;
        }
        wait_until_healthy()?;
        Ok(())
    })();
    let _ = fs::remove_file(&staged_program);
    let _ = fs::remove_file(&staged_unit);
    if let Err(error) = result {
        eprintln!("install failed: {error}; restoring previous files");
        let mut rollback_errors = Vec::new();
        if systemctl_success(&["is-active", "--quiet", SERVICE]) {
            if let Err(rollback_error) = systemctl(&["stop", SERVICE]) {
                rollback_errors.push(rollback_error.to_string());
            }
        }
        if had_program {
            if let Err(rollback_error) = fs::rename(&program_backup, program) {
                rollback_errors.push(rollback_error.to_string());
            }
        } else if program.exists() {
            if let Err(rollback_error) = fs::remove_file(program) {
                rollback_errors.push(rollback_error.to_string());
            }
        }
        if had_unit {
            if let Err(rollback_error) = fs::rename(&unit_backup, unit) {
                rollback_errors.push(rollback_error.to_string());
            }
        } else if unit.exists() {
            if let Err(rollback_error) = fs::remove_file(unit) {
                rollback_errors.push(rollback_error.to_string());
            }
        }
        if let Err(rollback_error) = systemctl(&["daemon-reload"]) {
            rollback_errors.push(rollback_error.to_string());
        }
        if had_unit {
            if old_enabled {
                if let Err(rollback_error) = systemctl(&["enable", SERVICE]) {
                    rollback_errors.push(rollback_error.to_string());
                }
            } else {
                if let Err(rollback_error) = systemctl(&["disable", SERVICE]) {
                    rollback_errors.push(rollback_error.to_string());
                }
            }
            if old_active {
                if let Err(rollback_error) =
                    systemctl(&["start", SERVICE]).and_then(|_| wait_until_healthy())
                {
                    rollback_errors.push(rollback_error.to_string());
                }
            }
        } else {
            if systemctl_success(&["is-enabled", "--quiet", SERVICE]) {
                if let Err(rollback_error) = systemctl(&["disable", SERVICE]) {
                    rollback_errors.push(rollback_error.to_string());
                }
            }
        }
        return Err(format!(
            "install failed: {error}; rollback {}",
            if rollback_errors.is_empty() {
                "completed".to_owned()
            } else {
                format!("incomplete: {}", rollback_errors.join("; "))
            }
        )
        .into());
    }
    println!("{} installed, enabled, and healthy", SERVICE);
    Ok(())
}

fn wait_until_healthy() -> Result<(), Box<dyn std::error::Error>> {
    for _ in 0..30 {
        if systemctl_success(&["is-active", "--quiet", SERVICE]) && http_healthy() {
            return Ok(());
        }
        thread::sleep(Duration::from_secs(1));
    }
    Err("service did not become healthy within 30 seconds".into())
}

fn http_healthy() -> bool {
    let Ok(mut addresses) = "127.0.0.1:8080".to_socket_addrs() else {
        return false;
    };
    let Some(address) = addresses.next() else {
        return false;
    };
    let Ok(mut stream) = TcpStream::connect_timeout(&address, Duration::from_secs(1)) else {
        return false;
    };
    let _ = stream.set_read_timeout(Some(Duration::from_secs(1)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(1)));
    if stream
        .write_all(b"GET /healthz HTTP/1.0\r\nHost: localhost\r\n\r\n")
        .is_err()
    {
        return false;
    }
    let mut response = [0u8; 1024];
    let Ok(size) = stream.read(&mut response) else {
        return false;
    };
    response[..size].starts_with(b"HTTP/1.0 200") || response[..size].starts_with(b"HTTP/1.1 200")
}

fn uninstall() -> Result<(), Box<dyn std::error::Error>> {
    require_root_and_systemd()?;
    let unit = Path::new(UNIT);
    if !unit.exists() {
        return Err(format!("{} is not installed", SERVICE).into());
    }
    systemctl(&["disable", "--now", SERVICE])?;
    fs::remove_file(unit)?;
    sync_parent(unit)?;
    systemctl(&["daemon-reload"])?;
    println!("{} uninstalled; binary and data retained", SERVICE);
    Ok(())
}

fn status() -> Result<(), Box<dyn std::error::Error>> {
    if !Path::new(UNIT).exists() {
        println!("{}: not installed", SERVICE);
        return Ok(());
    }
    let active = systemctl_success(&["is-active", "--quiet", SERVICE]);
    let enabled = systemctl_success(&["is-enabled", "--quiet", SERVICE]);
    println!(
        "{}: active={}, enabled={}, health={}",
        SERVICE,
        active,
        enabled,
        http_healthy()
    );
    Ok(())
}
