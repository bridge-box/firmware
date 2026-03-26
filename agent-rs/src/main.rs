mod api;
mod device;
mod models;

use std::process::ExitCode;

fn main() -> ExitCode {
    let command = std::env::args().nth(1).unwrap_or_default();

    let result = match command.as_str() {
        "register" => cmd_register(),
        "heartbeat" => cmd_heartbeat(),
        "status" => cmd_status(),
        "generate-id" => cmd_generate_id(),
        _ => {
            eprintln!("bb-agent <register|heartbeat|status|generate-id>");
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
    let box_id = device::ensure_box_id()?;
    let mac = device::read_mac_eth0()?;
    let backend_url = device::read_backend_url();

    println!("=== BridgeBox Agent: регистрация ===");
    println!("  BOX_ID:  {box_id}");
    println!("  MAC:     {mac}");

    // Регистрация — backend сразу ставит UNCLAIMED для новых устройств
    let register_resp = api::register(&backend_url, &box_id, &mac)?;
    device::write_state(&register_resp.state)?;
    println!("  State:   {:?}", register_resp.state);

    println!("=== Регистрация завершена ===");
    Ok(())
}

fn cmd_heartbeat() -> Result<(), String> {
    let box_id = device::read_box_id()?;
    let backend_url = device::read_backend_url();

    let wlan_connected = device::is_interface_up("wlan0");
    let bridge_up = device::is_interface_up("br0");
    let uptime = device::read_uptime();

    let resp = api::heartbeat(&backend_url, &box_id, uptime, wlan_connected, bridge_up)?;
    device::write_state(&resp.state)?;

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
    let box_id = device::ensure_box_id()?;
    println!("{box_id}");
    Ok(())
}
