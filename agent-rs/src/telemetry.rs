use crate::protocol::HeartbeatData;
use std::fs;

pub fn collect() -> HeartbeatData {
    HeartbeatData {
        uptime: read_uptime(),
        wlan_connected: is_interface_up("wlan0"),
        bridge_up: is_interface_up("br0"),
        overlay_version: read_trimmed("/etc/bridgebox/overlay-version"),
        overlay_service_running: is_overlay_running(),
        tailscale_connected: is_tailscale_up(),
    }
}

fn read_uptime() -> u64 {
    fs::read_to_string("/proc/uptime")
        .ok()
        .and_then(|s| s.split('.').next().map(String::from))
        .and_then(|s| s.parse().ok())
        .unwrap_or(0)
}

fn is_interface_up(name: &str) -> bool {
    fs::read_to_string(format!("/sys/class/net/{name}/operstate"))
        .map(|s| s.trim() == "up")
        .unwrap_or(false)
}

fn read_trimmed(path: &str) -> Option<String> {
    fs::read_to_string(path)
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

fn is_tailscale_up() -> bool {
    std::process::Command::new("tailscale")
        .args(["status", "--json"])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).contains("\"BackendState\":\"Running\""))
        .unwrap_or(false)
}

fn is_overlay_running() -> bool {
    let service_name = match fs::read_to_string("/etc/bridgebox/overlay-service") {
        Ok(s) if !s.trim().is_empty() => s.trim().to_string(),
        _ => return false,
    };
    let init_script = format!("/etc/init.d/{service_name}");
    std::process::Command::new("sh")
        .args(["-c", &format!("[ -f {init_script} ] && {init_script} status >/dev/null 2>&1")])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}
