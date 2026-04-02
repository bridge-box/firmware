use std::fs;
use std::path::Path;

use crate::models::DeviceState;
use crate::models::EventConfig;
use crate::models::OverlayStatus;

const BOX_ID_FILE: &str = "/etc/bridgebox/box-id";
const STATE_FILE: &str = "/etc/bridgebox/state";
const BACKEND_URL_FILE: &str = "/etc/bridgebox/backend-url";
const MAC_PATH: &str = "/sys/class/net/eth0/address";
const HEADSCALE_URL_FILE: &str = "/etc/bridgebox/headscale-url";
const OVERLAY_VERSION_FILE: &str = "/etc/bridgebox/overlay-version";
const OVERLAY_STATUS_FILE: &str = "/etc/bridgebox/overlay-status";
const DESIRED_OVERLAY_FILE: &str = "/etc/bridgebox/desired-overlay.json";

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

/// Читает URL backend. Ошибка если не настроен.
pub fn read_backend_url() -> Result<String, String> {
    fs::read_to_string(BACKEND_URL_FILE)
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .or_else(|| std::env::var("BACKEND_URL").ok())
        .ok_or_else(|| format!("backend URL не настроен: задайте в {BACKEND_URL_FILE} или BACKEND_URL"))
}

/// Записывает текущее состояние в файл (атомарно: write .tmp + rename).
pub fn write_state(state: &DeviceState) -> Result<(), String> {
    let dir = Path::new(STATE_FILE).parent().unwrap();
    fs::create_dir_all(dir)
        .map_err(|e| format!("не удалось создать {}: {e}", dir.display()))?;

    let tmp = format!("{}.tmp", STATE_FILE);
    fs::write(&tmp, format!("{}\n", state))
        .map_err(|e| format!("не удалось записать {tmp}: {e}"))?;
    fs::rename(&tmp, STATE_FILE)
        .map_err(|e| format!("не удалось переименовать {tmp} -> {STATE_FILE}: {e}"))
}

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

/// Подключает Tailscale с auth key. Ошибка если headscale-url не настроен.
pub fn tailscale_up(auth_key: &str) -> Result<(), String> {
    let headscale_url = fs::read_to_string(HEADSCALE_URL_FILE)
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .ok_or_else(|| format!("Headscale URL не настроен: задайте в {HEADSCALE_URL_FILE}"))?;

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

/// Читает текущую версию overlay (или None если не установлен).
pub fn read_overlay_version() -> Option<String> {
    fs::read_to_string(OVERLAY_VERSION_FILE)
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// Читает текущий статус overlay.
pub fn read_overlay_status() -> OverlayStatus {
    fs::read_to_string(OVERLAY_STATUS_FILE)
        .ok()
        .map(|s| OverlayStatus::from_str(&s))
        .unwrap_or(OverlayStatus::None)
}

/// Записывает desired-overlay.json (ответ бэкенда).
pub fn write_desired_overlay(json: &str) -> Result<(), String> {
    let dir = Path::new(DESIRED_OVERLAY_FILE).parent().unwrap();
    fs::create_dir_all(dir)
        .map_err(|e| format!("не удалось создать {}: {e}", dir.display()))?;
    fs::write(DESIRED_OVERLAY_FILE, json)
        .map_err(|e| format!("не удалось записать {DESIRED_OVERLAY_FILE}: {e}"))
}

/// Записывает overlay-status атомарно.
pub fn write_overlay_status(status: &OverlayStatus) -> Result<(), String> {
    let dir = Path::new(OVERLAY_STATUS_FILE).parent().unwrap();
    fs::create_dir_all(dir)
        .map_err(|e| format!("не удалось создать {}: {e}", dir.display()))?;
    let tmp = format!("{OVERLAY_STATUS_FILE}.tmp");
    fs::write(&tmp, format!("{status}\n"))
        .map_err(|e| format!("не удалось записать {tmp}: {e}"))?;
    fs::rename(&tmp, OVERLAY_STATUS_FILE)
        .map_err(|e| format!("не удалось переименовать {tmp}: {e}"))
}

/// Атомарная запись файла: write .tmp + rename.
fn safe_write(path: &str, content: &str) -> Result<(), String> {
    let tmp = format!("{path}.tmp");
    std::fs::write(&tmp, content).map_err(|e| format!("write {tmp}: {e}"))?;
    std::fs::rename(&tmp, path).map_err(|e| format!("rename {tmp} → {path}: {e}"))
}

const EVENT_CONFIG_FILE: &str = "/etc/bridgebox/event-config";

/// Сохранить конфигурацию событий на диск для overlay-монитора
pub fn write_event_config(config: &EventConfig) -> Result<(), String> {
    let dir = std::path::Path::new(EVENT_CONFIG_FILE).parent().unwrap();
    fs::create_dir_all(dir)
        .map_err(|e| format!("не удалось создать {}: {e}", dir.display()))?;
    let content = format!("{} {}", config.window_seconds, config.rst_threshold);
    safe_write(EVENT_CONFIG_FILE, &content)
}

/// Проверяет, работает ли overlay-сервис.
/// Overlay при установке создаёт /etc/bridgebox/overlay-service с именем init.d сервиса.
/// Если файла нет — overlay не установлен.
pub fn is_overlay_service_running() -> bool {
    let service_name = match std::fs::read_to_string("/etc/bridgebox/overlay-service") {
        Ok(s) => s.trim().to_string(),
        Err(_) => return false, // overlay не установлен
    };

    if service_name.is_empty() {
        return false;
    }

    let init_script = format!("/etc/init.d/{service_name}");
    std::process::Command::new("sh")
        .args(["-c", &format!("[ -f {init_script} ] && {init_script} status >/dev/null 2>&1")])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}
