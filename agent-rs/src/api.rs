use crate::models::*;

/// POST /api/devices/register
pub fn register(base_url: &str, device_id: &str, mac_eth0: &str) -> Result<RegisterResponse, String> {
    let url = format!("{base_url}/api/devices/register");
    let body = RegisterRequest {
        device_id: device_id.to_string(),
        mac_eth0: mac_eth0.to_string(),
    };

    let mut resp: ureq::Body = ureq::post(&url)
        .header("Content-Type", "application/json")
        .send_json(&body)
        .map_err(|e| format!("register: {e}"))?
        .into_body();

    serde_json::from_reader(resp.as_reader())
        .map_err(|e| format!("register: ошибка парсинга ответа: {e}"))
}

/// GET /api/devices/{id}/state
pub fn get_state(base_url: &str, device_id: &str) -> Result<DeviceStateResponse, String> {
    let url = format!("{base_url}/api/devices/{device_id}/state");

    let mut resp = ureq::get(&url)
        .call()
        .map_err(|e| format!("status: {e}"))?
        .into_body();

    serde_json::from_reader(resp.as_reader())
        .map_err(|e| format!("status: ошибка парсинга ответа: {e}"))
}

/// GET /api/devices/{id}/auth-key — fallback если при register не получили ключ
pub fn request_auth_key(base_url: &str, device_id: &str) -> Result<RegisterResponse, String> {
    let url = format!("{base_url}/api/devices/{device_id}/auth-key");

    let mut resp = ureq::get(&url)
        .call()
        .map_err(|e| format!("auth-key: {e}"))?
        .into_body();

    serde_json::from_reader(resp.as_reader())
        .map_err(|e| format!("auth-key: ошибка парсинга ответа: {e}"))
}

/// POST /api/devices/{id}/heartbeat
pub fn heartbeat(
    base_url: &str,
    device_id: &str,
    uptime: u64,
    wlan_connected: bool,
    bridge_up: bool,
    tailscale_connected: bool,
) -> Result<HeartbeatResponse, String> {
    let url = format!("{base_url}/api/devices/{device_id}/heartbeat");
    let body = HeartbeatRequest {
        device_id: device_id.to_string(),
        uptime,
        wlan_connected,
        bridge_up,
        tailscale_connected,
    };

    let mut resp = ureq::post(&url)
        .header("Content-Type", "application/json")
        .send_json(&body)
        .map_err(|e| format!("heartbeat: {e}"))?
        .into_body();

    serde_json::from_reader(resp.as_reader())
        .map_err(|e| format!("heartbeat: ошибка парсинга ответа: {e}"))
}
