use std::fs;
use std::path::Path;
use sha2::{Sha256, Digest};

use crate::models::{DesiredOverlay, OverlayStatus};
use crate::device;
use crate::events;

const BUNDLE_DIR: &str = "/opt/bridgebox/bundle";
const BUNDLE_ARCHIVE: &str = "/opt/bridgebox/bundle.tar.gz";

/// Основная логика sync-overlay.
/// Сравнивает desired vs current, скачивает и применяет при расхождении.
pub fn sync(base_url: &str, device_id: &str, desired: Option<DesiredOverlay>) -> Result<(), String> {
    let current = device::read_overlay_version();

    match desired {
        // desired == null, но overlay стоит → rollback
        None if current.is_some() => {
            events::send_event(base_url, device_id,
                events::new_event("overlay_rollback_started", current.as_deref(), "desired=null"));
            do_rollback(base_url, device_id)
        }

        // desired == null, overlay не стоит → ничего
        None => Ok(()),

        // desired есть
        Some(desired) => {
            // Уже стоит нужная версия
            if current.as_deref() == Some(&desired.version) {
                return Ok(());
            }

            events::send_event(base_url, device_id,
                events::new_event("overlay_sync_started", Some(&desired.version),
                    &format!("current={}", current.as_deref().unwrap_or("none"))));

            do_apply(base_url, device_id, &desired)
        }
    }
}

/// Скачать bundle, проверить SHA256, распаковать, запустить apply.sh.
fn do_apply(base_url: &str, device_id: &str, desired: &DesiredOverlay) -> Result<(), String> {
    device::write_overlay_status(&OverlayStatus::Applying)?;

    // 1. Скачать
    download_bundle(&desired.url, BUNDLE_ARCHIVE)
        .map_err(|e| {
            let _ = device::write_overlay_status(&OverlayStatus::Failed);
            events::send_event(base_url, device_id,
                events::new_event("overlay_download_failed", Some(&desired.version), &e));
            e
        })?;

    // 2. Проверить SHA256
    let actual_sha = sha256_file(BUNDLE_ARCHIVE)?;
    if actual_sha != desired.sha256 {
        let _ = fs::remove_file(BUNDLE_ARCHIVE);
        let _ = device::write_overlay_status(&OverlayStatus::Failed);
        let msg = format!("expected={}, actual={actual_sha}", desired.sha256);
        events::send_event(base_url, device_id,
            events::new_event("overlay_sha256_mismatch", Some(&desired.version), &msg));
        return Err(format!("SHA256 mismatch: {msg}"));
    }

    events::send_event(base_url, device_id,
        events::new_event("overlay_download_ok", Some(&desired.version), &actual_sha));

    // 3. Распаковать bundle
    let _ = fs::remove_dir_all(BUNDLE_DIR);
    fs::create_dir_all(BUNDLE_DIR)
        .map_err(|e| format!("mkdir {BUNDLE_DIR}: {e}"))?;

    let output = std::process::Command::new("tar")
        .args(["-xzf", BUNDLE_ARCHIVE, "-C", BUNDLE_DIR])
        .output()
        .map_err(|e| format!("tar: {e}"))?;

    if !output.status.success() {
        let _ = device::write_overlay_status(&OverlayStatus::Failed);
        return Err(format!("tar extract failed: {}", String::from_utf8_lossy(&output.stderr)));
    }

    let _ = fs::remove_file(BUNDLE_ARCHIVE);

    // 4. Запустить apply.sh
    events::send_event(base_url, device_id,
        events::new_event("overlay_apply_started", Some(&desired.version), ""));

    let apply_path = format!("{BUNDLE_DIR}/apply.sh");
    let apply_output = std::process::Command::new("sh")
        .arg(&apply_path)
        .output()
        .map_err(|e| format!("sh apply.sh: {e}"))?;

    if apply_output.status.success() {
        events::send_event(base_url, device_id,
            events::new_event("overlay_apply_ok", Some(&desired.version), ""));
        Ok(())
    } else {
        let stderr = String::from_utf8_lossy(&apply_output.stderr);
        let _ = device::write_overlay_status(&OverlayStatus::Failed);
        events::send_event(base_url, device_id,
            events::new_event("overlay_apply_failed", Some(&desired.version), &stderr));
        Err(format!("apply.sh failed: {stderr}"))
    }
}

/// Запустить rollback.sh.
fn do_rollback(base_url: &str, device_id: &str) -> Result<(), String> {
    let rollback_path = format!("{BUNDLE_DIR}/rollback.sh");

    if Path::new(&rollback_path).exists() {
        let output = std::process::Command::new("sh")
            .arg(&rollback_path)
            .output()
            .map_err(|e| format!("sh rollback.sh: {e}"))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(format!("rollback.sh failed: {stderr}"));
        }
    } else {
        eprintln!("[bb-agent] rollback.sh не найден, пропускаем");
    }

    events::send_event(base_url, device_id,
        events::new_event("overlay_rollback_ok", None, ""));
    Ok(())
}

/// Скачать файл по URL.
fn download_bundle(url: &str, dest: &str) -> Result<(), String> {
    let dir = Path::new(dest).parent().unwrap();
    fs::create_dir_all(dir)
        .map_err(|e| format!("mkdir: {e}"))?;

    let resp = ureq::get(url)
        .call()
        .map_err(|e| format!("download {url}: {e}"))?;

    let mut reader = resp.into_body().into_reader();
    let mut file = fs::File::create(dest)
        .map_err(|e| format!("create {dest}: {e}"))?;

    std::io::copy(&mut reader, &mut file)
        .map_err(|e| format!("write {dest}: {e}"))?;

    Ok(())
}

/// Вычислить SHA256 файла.
fn sha256_file(path: &str) -> Result<String, String> {
    let data = fs::read(path)
        .map_err(|e| format!("read {path}: {e}"))?;
    let hash = Sha256::digest(&data);
    Ok(format!("{hash:x}"))
}
