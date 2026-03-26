use sha2::{Sha256, Digest};
use std::fs;
use std::path::Path;

use crate::models::DeviceState;

const BOX_ID_FILE: &str = "/etc/bridgebox/box-id";
const STATE_FILE: &str = "/etc/bridgebox/state";
const BACKEND_URL_FILE: &str = "/etc/bridgebox/backend-url";
const MAC_PATH: &str = "/sys/class/net/eth0/address";
const DEFAULT_BACKEND_URL: &str = "http://backend.bridge-box.online";

/// Читает BOX_ID из файла. Ошибка если файл не существует или пуст.
pub fn read_box_id() -> Result<String, String> {
    let content = fs::read_to_string(BOX_ID_FILE)
        .map_err(|e| format!("не удалось прочитать {BOX_ID_FILE}: {e}"))?;
    let id = content.trim().to_string();
    if id.is_empty() || id == "TEMPLATE" {
        return Err(format!("BOX_ID не задан в {BOX_ID_FILE}"));
    }
    Ok(id)
}

/// Читает или генерирует BOX_ID.
/// Если файл уже содержит валидный ID — возвращает его.
/// Иначе генерирует из MAC eth0 и сохраняет.
pub fn ensure_box_id() -> Result<String, String> {
    if let Ok(id) = read_box_id() {
        return Ok(id);
    }

    let mac = read_mac_eth0()?;
    let box_id = generate_id_from_mac(&mac);

    // Создаём директорию если не существует
    let dir = Path::new(BOX_ID_FILE).parent().unwrap();
    fs::create_dir_all(dir)
        .map_err(|e| format!("не удалось создать {}: {e}", dir.display()))?;

    fs::write(BOX_ID_FILE, &box_id)
        .map_err(|e| format!("не удалось записать {BOX_ID_FILE}: {e}"))?;

    eprintln!("[bb-agent] Сгенерирован BOX_ID: {box_id}");
    Ok(box_id)
}

/// Генерирует BB-XXXXXX из SHA256(mac).
fn generate_id_from_mac(mac: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(mac.as_bytes());
    let hash = hasher.finalize();
    let hex_str = hex::encode_upper(&hash[..3]); // 3 байта = 6 hex символов
    format!("BB-{hex_str}")
}

/// Читает MAC-адрес eth0.
pub fn read_mac_eth0() -> Result<String, String> {
    // Сначала из sysfs
    if let Ok(content) = fs::read_to_string(MAC_PATH) {
        let mac = content.trim().to_string();
        if !mac.is_empty() {
            return Ok(mac);
        }
    }

    // Fallback: env
    if let Ok(mac) = std::env::var("MAC_ETH0") {
        return Ok(mac);
    }

    Err(format!("не удалось прочитать MAC из {MAC_PATH}"))
}

/// Читает URL backend.
pub fn read_backend_url() -> String {
    fs::read_to_string(BACKEND_URL_FILE)
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .or_else(|| std::env::var("BACKEND_URL").ok())
        .unwrap_or_else(|| DEFAULT_BACKEND_URL.to_string())
}

/// Записывает текущее состояние в файл.
pub fn write_state(state: &DeviceState) -> Result<(), String> {
    let dir = Path::new(STATE_FILE).parent().unwrap();
    fs::create_dir_all(dir)
        .map_err(|e| format!("не удалось создать {}: {e}", dir.display()))?;

    fs::write(STATE_FILE, format!("{}\n", state))
        .map_err(|e| format!("не удалось записать {STATE_FILE}: {e}"))
}

const HEADSCALE_URL: &str = "https://hs.bridge-box.online";

/// Проверяет, подключён ли Tailscale (BackendState == Running).
pub fn is_tailscale_up() -> bool {
    let output = match std::process::Command::new("tailscale")
        .args(["status", "--json"])
        .output()
    {
        Ok(o) => o,
        Err(_) => return false,
    };

    let stdout = String::from_utf8_lossy(&output.stdout);
    stdout.contains("\"BackendState\":\"Running\"")
}

/// Подключает Tailscale с auth key.
pub fn tailscale_up(auth_key: &str) -> Result<(), String> {
    let headscale_url = fs::read_to_string("/etc/bridgebox/headscale-url")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| HEADSCALE_URL.to_string());

    eprintln!("[bb-agent] Tailscale up: server={headscale_url}");

    let output = std::process::Command::new("tailscale")
        .args([
            "up",
            &format!("--login-server={headscale_url}"),
            &format!("--authkey={auth_key}"),
            "--accept-routes=false",
        ])
        .output()
        .map_err(|e| format!("tailscale up: {e}"))?;

    if output.status.success() {
        eprintln!("[bb-agent] Tailscale подключён");
        Ok(())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr);
        Err(format!("tailscale up failed: {stderr}"))
    }
}

/// Проверяет, поднят ли сетевой интерфейс.
pub fn is_interface_up(name: &str) -> bool {
    let path = format!("/sys/class/net/{name}/operstate");
    fs::read_to_string(path)
        .map(|s| s.trim() == "up")
        .unwrap_or(false)
}

/// Читает uptime в секундах из /proc/uptime.
pub fn read_uptime() -> u64 {
    fs::read_to_string("/proc/uptime")
        .ok()
        .and_then(|s| s.split('.').next().map(String::from))
        .and_then(|s| s.parse().ok())
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_generate_id_deterministic() {
        let id1 = generate_id_from_mac("aa:bb:cc:dd:ee:ff");
        let id2 = generate_id_from_mac("aa:bb:cc:dd:ee:ff");
        assert_eq!(id1, id2);
        assert!(id1.starts_with("BB-"));
        assert_eq!(id1.len(), 9); // BB- + 6 hex
    }

    #[test]
    fn test_generate_id_different_macs() {
        let id1 = generate_id_from_mac("aa:bb:cc:dd:ee:ff");
        let id2 = generate_id_from_mac("11:22:33:44:55:66");
        assert_ne!(id1, id2);
    }
}
