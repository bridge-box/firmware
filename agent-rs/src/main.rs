mod api;
mod device;
mod models;
mod events;
mod overlay;

use std::process::ExitCode;

fn main() -> ExitCode {
    let command = std::env::args().nth(1).unwrap_or_default();

    let result = match command.as_str() {
        "register" => cmd_register(),
        "heartbeat" => cmd_heartbeat(),
        "status" => cmd_status(),
        "generate-id" => cmd_generate_id(),
        "ensure-mesh" => cmd_ensure_mesh(),
        "sync-overlay" => cmd_sync_overlay(),
        _ => {
            eprintln!("bb-agent <register|heartbeat|status|generate-id|ensure-mesh|sync-overlay>");
            return ExitCode::FAILURE;
        }
    };

    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("[bb-agent] ОШИБКА: {e}");
            ExitCode::FAILURE
        }
    }
}

fn cmd_register() -> Result<(), String> {
    let box_id = device::read_box_id()?;
    let mac = device::read_mac_eth0()?;
    let backend_url = device::read_backend_url();

    println!("=== BridgeBox Agent: регистрация ===");
    println!("  BOX_ID:  {box_id}");
    println!("  MAC:     {mac}");

    // Регистрация — backend сразу ставит UNCLAIMED для новых устройств
    let register_resp = api::register(&backend_url, &box_id, &mac)?;
    device::write_state(&register_resp.state)?;
    println!("  State:   {:?}", register_resp.state);

    // Если backend вернул auth key — поднимаем Tailscale
    if let Some(auth_key) = &register_resp.tailscale_auth_key {
        println!("  Tailscale: получен auth key");
        match device::tailscale_up(auth_key) {
            Ok(()) => println!("  Tailscale: подключён"),
            Err(e) => eprintln!("  Tailscale: ошибка — {e}"),
        }
    } else {
        println!("  Tailscale: auth key не получен, попробую позже");
    }

    println!("=== Регистрация завершена ===");
    Ok(())
}

fn cmd_heartbeat() -> Result<(), String> {
    let box_id = device::read_box_id()?;
    let backend_url = device::read_backend_url();

    // Проверяем mesh — если не подключён, пытаемся получить ключ
    if !device::is_tailscale_up() {
        eprintln!("[bb-agent] Tailscale не подключён, запрашиваю auth key...");
        match api::request_auth_key(&backend_url, &box_id) {
            Ok(resp) => {
                if let Some(auth_key) = &resp.tailscale_auth_key {
                    let _ = device::tailscale_up(auth_key);
                }
            }
            Err(e) => eprintln!("[bb-agent] Не удалось получить auth key: {e}"),
        }
    }

    let wlan_connected = device::is_interface_up("wlan0");
    let bridge_up = device::is_interface_up("br0");
    let tailscale_connected = device::is_tailscale_up();
    let uptime = device::read_uptime();
    let overlay_version = device::read_overlay_version();
    let overlay_status = device::read_overlay_status();
    let overlay_service_running = device::is_overlay_service_running();

    let resp = api::heartbeat(
        &backend_url, &box_id, uptime,
        wlan_connected, bridge_up, tailscale_connected,
        overlay_version, overlay_status, overlay_service_running,
    )?;

    device::write_state(&resp.state)?;

    // Sync overlay если есть расхождение
    if let Err(e) = overlay::sync(&backend_url, &box_id, resp.desired_overlay.clone()) {
        eprintln!("[bb-agent] overlay sync: {e}");
    }

    println!("{}", serde_json::to_string(&resp).unwrap_or_default());
    Ok(())
}

fn cmd_status() -> Result<(), String> {
    let box_id = device::read_box_id()?;
    let backend_url = device::read_backend_url();

    let resp = api::get_state(&backend_url, &box_id)?;
    println!("{}", serde_json::to_string_pretty(&resp).unwrap_or_default());
    Ok(())
}

fn cmd_generate_id() -> Result<(), String> {
    let box_id = device::read_box_id()?;
    println!("{box_id}");
    Ok(())
}

/// Ensure mesh — проверяет Tailscale, если не подключён — запрашивает ключ и подключает
fn cmd_ensure_mesh() -> Result<(), String> {
    if device::is_tailscale_up() {
        println!("Tailscale: уже подключён");
        return Ok(());
    }

    let box_id = device::read_box_id()?;
    let backend_url = device::read_backend_url();

    let resp = api::request_auth_key(&backend_url, &box_id)?;
    let auth_key = resp.tailscale_auth_key
        .ok_or("backend не вернул auth key")?;

    device::tailscale_up(&auth_key)
}

/// Sync overlay вручную — для отладки.
/// Читает desired-overlay.json и применяет/откатывает.
fn cmd_sync_overlay() -> Result<(), String> {
    let box_id = device::read_box_id()?;
    let backend_url = device::read_backend_url();

    let desired = match std::fs::read_to_string("/etc/bridgebox/desired-overlay.json") {
        Ok(json) => serde_json::from_str(&json)
            .map_err(|e| format!("ошибка парсинга desired-overlay.json: {e}"))?,
        Err(_) => {
            println!("desired-overlay.json не найден — ничего не делаем");
            return Ok(());
        }
    };

    overlay::sync(&backend_url, &box_id, desired)
}
