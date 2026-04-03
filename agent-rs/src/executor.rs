use sha2::{Digest, Sha256};
use std::io::Read;
use tokio::process::Command;

/// Запускает shell-команду и возвращает stdout.
pub async fn run_shell(cmd: &str, args: &[&str]) -> Result<String, String> {
    let output = Command::new(cmd)
        .args(args)
        .output()
        .await
        .map_err(|e| format!("exec {cmd}: {e}"))?;

    if output.status.success() {
        Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr);
        Err(format!("{cmd} failed ({}): {}", output.status, stderr.trim()))
    }
}

/// Создаёт bridge через setup-bridge.sh.
pub async fn create_bridge() -> Result<(), String> {
    run_shell("sh", &["/usr/lib/bridgebox/setup-bridge.sh"]).await?;
    Ok(())
}

/// Поднимает Tailscale с auth key.
pub async fn tailscale_up(headscale_url: &str, auth_key: &str) -> Result<String, String> {
    run_shell(
        "tailscale",
        &[
            "up",
            "--login-server",
            headscale_url,
            "--authkey",
            auth_key,
            "--hostname",
            "bridge-box",
            "--accept-routes",
        ],
    )
    .await
}

/// Скачивает файл по URL через ureq (sync HTTP в spawn_blocking).
pub async fn download(url: &str, dest: &str) -> Result<(), String> {
    let url = url.to_string();
    let dest = dest.to_string();

    tokio::task::spawn_blocking(move || {
        let resp = ureq::get(&url)
            .call()
            .map_err(|e| format!("download {url}: {e}"))?;

        let mut reader = resp.into_body().into_reader();
        let mut file = std::fs::File::create(&dest)
            .map_err(|e| format!("create {dest}: {e}"))?;
        std::io::copy(&mut reader, &mut file)
            .map_err(|e| format!("write {dest}: {e}"))?;

        Ok(())
    })
    .await
    .map_err(|e| format!("spawn_blocking: {e}"))?
}

/// Вычисляет SHA256 файла.
pub async fn sha256_file(path: &str) -> Result<String, String> {
    let path = path.to_string();

    tokio::task::spawn_blocking(move || {
        let mut file = std::fs::File::open(&path)
            .map_err(|e| format!("open {path}: {e}"))?;
        let mut hasher = Sha256::new();
        let mut buf = [0u8; 8192];
        loop {
            let n = file.read(&mut buf).map_err(|e| format!("read {path}: {e}"))?;
            if n == 0 {
                break;
            }
            hasher.update(&buf[..n]);
        }
        let hash = hasher.finalize();
        Ok(format!("{hash:x}"))
    })
    .await
    .map_err(|e| format!("spawn_blocking: {e}"))?
}

/// Распаковывает tar.gz архив.
pub async fn extract_tar(archive: &str, dest: &str) -> Result<(), String> {
    run_shell("tar", &["-xzf", archive, "-C", dest]).await?;
    Ok(())
}

/// Запускает скрипт из bundle-директории.
pub async fn run_bundle_script(bundle_dir: &str, script: &str) -> Result<(), String> {
    let script_path = format!("{bundle_dir}/{script}");
    run_shell("sh", &[&script_path]).await?;
    Ok(())
}

/// Результат регистрации устройства на backend.
pub struct RegisterResult {
    pub state: String,
    pub tailscale_auth_key: Option<String>,
}

/// Читает MAC-адрес eth0 из sysfs.
pub fn read_mac_address() -> Result<String, String> {
    std::fs::read_to_string("/sys/class/net/eth0/address")
        .map(|s| s.trim().to_string())
        .map_err(|e| format!("read eth0 MAC: {e}"))
}

/// Регистрирует устройство на backend (POST /api/devices/register).
/// Возвращает RegisterResult с опциональным auth key.
pub async fn register(backend_url: &str, device_id: &str) -> Result<RegisterResult, String> {
    let url = format!("{backend_url}/api/devices/register");
    let device_id = device_id.to_string();

    tokio::task::spawn_blocking(move || -> Result<RegisterResult, String> {
        let mac = read_mac_address()?;

        let body = serde_json::json!({
            "deviceId": device_id,
            "macEth0": mac,
        });

        let resp = ureq::post(&url)
            .header("Content-Type", "application/json")
            .send(body.to_string().as_bytes())
            .map_err(|e| format!("register request: {e}"))?;

        let json: serde_json::Value = resp
            .into_body()
            .read_json()
            .map_err(|e| format!("register parse: {e}"))?;

        let state = json["state"]
            .as_str()
            .unwrap_or("UNKNOWN")
            .to_string();

        let tailscale_auth_key = json["tailscaleAuthKey"]
            .as_str()
            .map(String::from);

        Ok(RegisterResult {
            state,
            tailscale_auth_key,
        })
    })
    .await
    .map_err(|e| format!("spawn_blocking: {e}"))?
}

/// Запрашивает auth key для Tailscale у backend.
pub async fn request_auth_key(backend_url: &str, device_id: &str) -> Result<String, String> {
    let url = format!("{backend_url}/api/devices/{device_id}/auth-key");

    tokio::task::spawn_blocking(move || -> Result<String, String> {
        let resp = ureq::get(&url)
            .call()
            .map_err(|e| format!("auth-key request: {e}"))?;

        let body: serde_json::Value = resp
            .into_body()
            .read_json()
            .map_err(|e| format!("auth-key parse: {e}"))?;

        body["tailscaleAuthKey"]
            .as_str()
            .map(String::from)
            .ok_or_else(|| "auth-key: missing 'tailscaleAuthKey' field".to_string())
    })
    .await
    .map_err(|e| format!("spawn_blocking: {e}"))?
}
