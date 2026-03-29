use crate::models::DeviceEvent;

/// Отправить событие на бэкенд (fire-and-forget).
/// Если бэкенд недоступен — событие теряется, не критично.
pub fn send_event(base_url: &str, device_id: &str, event: DeviceEvent) {
    // Всегда в syslog
    log_to_syslog(&event);

    // Fire-and-forget на бэкенд
    let url = format!("{base_url}/api/devices/{device_id}/events");
    let _ = ureq::post(&url)
        .header("Content-Type", "application/json")
        .send_json(&event);
}

/// Логирование в syslog через logger.
fn log_to_syslog(event: &DeviceEvent) {
    let msg = if let Some(ref v) = event.version {
        format!("{} version={} {}", event.event, v, event.details)
    } else {
        format!("{} {}", event.event, event.details)
    };

    let _ = std::process::Command::new("logger")
        .args(["-t", "bb-agent", &msg])
        .output();
}

/// Создать событие с текущим временем.
pub fn new_event(event: &str, version: Option<&str>, details: &str) -> DeviceEvent {
    DeviceEvent {
        event: event.to_string(),
        version: version.map(String::from),
        details: details.to_string(),
        timestamp: current_timestamp(),
    }
}

fn current_timestamp() -> String {
    std::fs::read_to_string("/proc/uptime")
        .ok()
        .and_then(|s| s.split('.').next().map(|n| format!("uptime:{n}s")))
        .unwrap_or_else(|| "unknown".to_string())
}
