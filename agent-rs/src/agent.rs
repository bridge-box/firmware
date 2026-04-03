use std::net::IpAddr;
use tokio::sync::mpsc;
use tokio::time::{interval, Duration};

use crate::config::{AgentConfig, MgmtIface};
use crate::executor;
use crate::protocol::{AgentMessage, BackendMessage, EventData};
use crate::state::bridge::{BridgeEffect, BridgeEvent, BridgeNotification, BridgeState};
use crate::state::connection::{ConnEffect, ConnEvent, ConnNotification, ConnState};
use crate::state::mesh::{MeshEffect, MeshEvent, MeshNotification, MeshState};
use crate::state::overlay::{
    OverlayEffect, OverlayEvent, OverlayNotification, OverlayState,
};
use crate::state::wifi::{WiFiEffect, WiFiEvent, WiFiNotification, WiFiState};
use crate::state::StateMachine;
use crate::telemetry;
use crate::ws::{self, WsTx};

const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(30);
const WS_RETRY_INTERVAL: Duration = Duration::from_secs(10);

/// Внутренние события для event loop.
pub enum InternalEvent {
    ManagementReady { ip: IpAddr },
    ManagementTimeout,
    WiFi(WiFiEvent),
    Bridge(BridgeEvent),
    Mesh(MeshEvent),
    Overlay(OverlayEvent),
    Conn(ConnEvent),
}

pub struct Agent {
    config: AgentConfig,
    wifi: WiFiState,
    bridge: BridgeState,
    mesh: MeshState,
    overlay: OverlayState,
    conn: ConnState,
    ws_tx: Option<WsTx>,
}

impl Agent {
    pub fn new(config: AgentConfig) -> Self {
        Self {
            config,
            wifi: WiFiState::Down,
            bridge: BridgeState::Disabled,
            mesh: MeshState::Disconnected,
            overlay: OverlayState::None,
            conn: ConnState::Offline,
            ws_tx: None,
        }
    }

    /// Главный async event loop.
    pub async fn run(mut self) {
        let (event_tx, mut event_rx) = mpsc::channel::<InternalEvent>(64);
        let (ws_msg_tx, mut ws_msg_rx) = mpsc::channel::<BackendMessage>(32);

        // Запускаем boot-последовательность
        self.boot(event_tx.clone()).await;

        // Запускаем bridge сразу — он всегда нужен
        self.transition_bridge(BridgeEvent::Enable, event_tx.clone())
            .await;

        let mut heartbeat_tick = interval(HEARTBEAT_INTERVAL);
        let mut ws_retry_tick = interval(WS_RETRY_INTERVAL);

        // Пропускаем первый немедленный тик
        heartbeat_tick.tick().await;
        ws_retry_tick.tick().await;

        loop {
            tokio::select! {
                Some(backend_msg) = ws_msg_rx.recv() => {
                    self.handle_backend_message(backend_msg, event_tx.clone()).await;
                }
                Some(event) = event_rx.recv() => {
                    self.handle_internal_event(event, event_tx.clone(), ws_msg_tx.clone()).await;
                }
                _ = heartbeat_tick.tick() => {
                    self.send_heartbeat().await;
                    // Уведомляем ConnSM о heartbeat tick
                    self.transition_conn(ConnEvent::HeartbeatTick).await;
                }
                _ = ws_retry_tick.tick() => {
                    if self.ws_tx.is_none() {
                        self.try_ws_connect(ws_msg_tx.clone()).await;
                    }
                    self.transition_conn(ConnEvent::WsRetryTick).await;
                }
                _ = tokio::signal::ctrl_c() => {
                    tracing::info!("SIGINT — завершение");
                    break;
                }
            }
        }
    }

    /// Определяем management-интерфейс и запускаем начальную последовательность.
    async fn boot(&self, event_tx: mpsc::Sender<InternalEvent>) {
        match &self.config.mgmt_iface {
            MgmtIface::Wlan0 => {
                // Wi-Fi flow — ищем PHY адаптер
                tracing::info!("Management через wlan0 — ищем Wi-Fi адаптер");
                let tx = event_tx.clone();
                tokio::spawn(async move {
                    // Проверяем наличие phy0
                    match executor::run_shell("ls", &["/sys/class/ieee80211/phy0"]).await {
                        Ok(_) => {
                            let _ = tx
                                .send(InternalEvent::WiFi(WiFiEvent::AdapterDetected {
                                    phy: "phy0".to_string(),
                                }))
                                .await;
                        }
                        Err(_) => {
                            tracing::warn!("Wi-Fi адаптер не найден, ждём 10с...");
                            tokio::time::sleep(Duration::from_secs(10)).await;
                            match executor::run_shell("ls", &["/sys/class/ieee80211/phy0"]).await {
                                Ok(_) => {
                                    let _ = tx
                                        .send(InternalEvent::WiFi(WiFiEvent::AdapterDetected {
                                            phy: "phy0".to_string(),
                                        }))
                                        .await;
                                }
                                Err(_) => {
                                    let _ = tx
                                        .send(InternalEvent::WiFi(WiFiEvent::AdapterTimeout))
                                        .await;
                                }
                            }
                        }
                    }
                });
            }
            MgmtIface::Ethernet { iface } => {
                // Ethernet management — сразу готовы
                tracing::info!(iface = %iface, "Management через ethernet");
                let iface = iface.clone();
                let tx = event_tx.clone();
                tokio::spawn(async move {
                    // Ждём пока интерфейс получит IP
                    for _ in 0..30 {
                        if let Ok(output) =
                            executor::run_shell("ip", &["-4", "addr", "show", &iface]).await
                        {
                            if let Some(ip) = parse_ip_from_output(&output) {
                                let _ = tx.send(InternalEvent::ManagementReady { ip }).await;
                                return;
                            }
                        }
                        tokio::time::sleep(Duration::from_secs(2)).await;
                    }
                    let _ = tx.send(InternalEvent::ManagementTimeout).await;
                });
            }
        }
    }

    /// Обработка сообщений от backend.
    async fn handle_backend_message(
        &mut self,
        msg: BackendMessage,
        event_tx: mpsc::Sender<InternalEvent>,
    ) {
        match msg {
            BackendMessage::Command(cmd) => {
                tracing::info!(cmd = %cmd.cmd, "Backend command");
                match cmd.cmd.as_str() {
                    "switch_mode" => {
                        if let Some(mode) = &cmd.mode {
                            match mode.as_str() {
                                "bridge" => {
                                    let _ =
                                        event_tx.send(InternalEvent::Bridge(BridgeEvent::Enable)).await;
                                }
                                _ => {
                                    tracing::warn!(mode = %mode, "Неизвестный mode");
                                }
                            }
                        }
                    }
                    "apply_overlay" => {
                        if let (Some(version), Some(url), Some(sha256)) =
                            (cmd.version, cmd.url, cmd.sha256)
                        {
                            let _ = event_tx
                                .send(InternalEvent::Overlay(OverlayEvent::Apply {
                                    version,
                                    url,
                                    sha256,
                                }))
                                .await;
                        } else {
                            tracing::warn!("apply_overlay: missing version/url/sha256");
                        }
                    }
                    "remove_overlay" => {
                        let _ = event_tx
                            .send(InternalEvent::Overlay(OverlayEvent::Remove))
                            .await;
                    }
                    other => {
                        tracing::warn!(cmd = %other, "Неизвестная команда");
                    }
                }
            }
            BackendMessage::DesiredState(desired) => {
                tracing::info!("Backend desired_state");
                if let Some(overlay) = desired.overlay {
                    let _ = event_tx
                        .send(InternalEvent::Overlay(OverlayEvent::Apply {
                            version: overlay.version,
                            url: overlay.url,
                            sha256: overlay.sha256,
                        }))
                        .await;
                }
            }
        }
    }

    /// Маршрутизация внутренних событий к соответствующим state machines.
    async fn handle_internal_event(
        &mut self,
        event: InternalEvent,
        event_tx: mpsc::Sender<InternalEvent>,
        _ws_msg_tx: mpsc::Sender<BackendMessage>,
    ) {
        match event {
            InternalEvent::ManagementReady { ip } => {
                tracing::info!(%ip, "Management interface ready — registering with backend");
                let backend_url = self.config.backend_url.clone();
                let device_id = self.config.box_id.clone();
                let tx = event_tx.clone();
                tokio::spawn(async move {
                    match executor::register(&backend_url, &device_id).await {
                        Ok(result) => {
                            tracing::info!(state = %result.state, "Registered with backend");
                            if let Some(key) = result.tailscale_auth_key {
                                // Backend вернул auth key — сразу в mesh
                                tracing::info!("Auth key received from register response");
                                let _ = tx
                                    .send(InternalEvent::Mesh(MeshEvent::ManagementReady))
                                    .await;
                                let _ = tx
                                    .send(InternalEvent::Mesh(MeshEvent::AuthKeyReceived { key }))
                                    .await;
                            } else {
                                // Нет auth key — штатный flow через RequestAuthKey
                                let _ = tx
                                    .send(InternalEvent::Mesh(MeshEvent::ManagementReady))
                                    .await;
                            }
                        }
                        Err(e) => {
                            tracing::error!("Registration failed: {e} — proceeding with mesh anyway");
                            let _ = tx
                                .send(InternalEvent::Mesh(MeshEvent::ManagementReady))
                                .await;
                        }
                    }
                });
            }
            InternalEvent::ManagementTimeout => {
                tracing::error!("Management interface timeout — работаем без mesh");
            }
            InternalEvent::WiFi(wifi_event) => {
                self.transition_wifi(wifi_event, event_tx.clone()).await;
            }
            InternalEvent::Bridge(bridge_event) => {
                self.transition_bridge(bridge_event, event_tx.clone()).await;
            }
            InternalEvent::Mesh(mesh_event) => {
                self.transition_mesh(mesh_event, event_tx.clone()).await;
            }
            InternalEvent::Overlay(overlay_event) => {
                self.transition_overlay(overlay_event, event_tx.clone())
                    .await;
            }
            InternalEvent::Conn(conn_event) => {
                self.transition_conn(conn_event).await;
            }
        }
    }

    // --- SM transitions ---

    async fn transition_wifi(
        &mut self,
        event: WiFiEvent,
        event_tx: mpsc::Sender<InternalEvent>,
    ) {
        let prev = std::mem::replace(&mut self.wifi, WiFiState::Down);
        let (new_state, effects) = prev.handle(event);
        self.wifi = new_state;
        self.execute_wifi_effects(effects, event_tx).await;
    }

    async fn transition_bridge(
        &mut self,
        event: BridgeEvent,
        event_tx: mpsc::Sender<InternalEvent>,
    ) {
        let prev = std::mem::replace(&mut self.bridge, BridgeState::Disabled);
        let (new_state, effects) = prev.handle(event);
        self.bridge = new_state;
        self.execute_bridge_effects(effects, event_tx).await;
    }

    async fn transition_mesh(
        &mut self,
        event: MeshEvent,
        event_tx: mpsc::Sender<InternalEvent>,
    ) {
        let prev = std::mem::replace(&mut self.mesh, MeshState::Disconnected);
        let (new_state, effects) = prev.handle(event);
        self.mesh = new_state;
        self.execute_mesh_effects(effects, event_tx).await;
    }

    async fn transition_overlay(
        &mut self,
        event: OverlayEvent,
        event_tx: mpsc::Sender<InternalEvent>,
    ) {
        let prev = std::mem::replace(&mut self.overlay, OverlayState::None);
        let (new_state, effects) = prev.handle(event);
        self.overlay = new_state;
        self.execute_overlay_effects(effects, event_tx).await;
    }

    async fn transition_conn(&mut self, event: ConnEvent) {
        let prev = std::mem::replace(&mut self.conn, ConnState::Offline);
        let (new_state, effects) = prev.handle(event);
        self.conn = new_state;
        self.execute_conn_effects(effects).await;
    }

    // --- Effect executors ---

    async fn execute_wifi_effects(
        &self,
        effects: Vec<WiFiEffect>,
        event_tx: mpsc::Sender<InternalEvent>,
    ) {
        for effect in effects {
            match effect {
                WiFiEffect::StartAP { phy, ssid } => {
                    tracing::info!(%phy, %ssid, "Starting AP");
                    let tx = event_tx.clone();
                    tokio::spawn(async move {
                        if let Err(e) = executor::run_shell(
                            "sh",
                            &["/usr/lib/bridgebox/setup-wifi-ap.sh", &phy, &ssid],
                        )
                        .await
                        {
                            tracing::error!("AP setup failed: {e}");
                        }
                        // AP не генерирует дальнейших событий — ждём credentials
                        let _ = tx; // keep tx alive
                    });
                }
                WiFiEffect::StartSTA { ssid, password } => {
                    tracing::info!(%ssid, "Connecting to Wi-Fi STA");
                    let tx = event_tx.clone();
                    tokio::spawn(async move {
                        match executor::run_shell(
                            "sh",
                            &["/usr/lib/bridgebox/setup-wifi-sta.sh", &ssid, &password],
                        )
                        .await
                        {
                            Ok(output) => {
                                // Пытаемся извлечь IP из вывода
                                if let Some(ip) = parse_ip_from_output(&output) {
                                    let _ = tx
                                        .send(InternalEvent::WiFi(WiFiEvent::DhcpSuccess { ip }))
                                        .await;
                                } else {
                                    let _ = tx
                                        .send(InternalEvent::WiFi(WiFiEvent::DhcpFailed))
                                        .await;
                                }
                            }
                            Err(e) => {
                                tracing::error!("STA setup failed: {e}");
                                let _ = tx
                                    .send(InternalEvent::WiFi(WiFiEvent::ConnectTimeout))
                                    .await;
                            }
                        }
                    });
                }
                WiFiEffect::Cleanup => {
                    tracing::info!("Wi-Fi cleanup");
                    if let Err(e) =
                        executor::run_shell("sh", &["/usr/lib/bridgebox/cleanup-wifi.sh"]).await
                    {
                        tracing::warn!("Wi-Fi cleanup error: {e}");
                    }
                }
                WiFiEffect::SaveCredentials { ssid, password } => {
                    tracing::info!(%ssid, "Saving Wi-Fi credentials");
                    let _ = tokio::fs::create_dir_all("/etc/bridgebox").await;
                    let content = format!("{ssid}\n{password}\n");
                    if let Err(e) =
                        tokio::fs::write("/etc/bridgebox/wifi-credentials", content).await
                    {
                        tracing::error!("Save credentials failed: {e}");
                    }
                }
                WiFiEffect::Notify(notification) => match notification {
                    WiFiNotification::STAReady { ip } => {
                        tracing::info!(%ip, "Wi-Fi STA ready");
                        // STAReady означает management готов — запускаем mesh
                        let _ = event_tx
                            .send(InternalEvent::ManagementReady { ip })
                            .await;
                    }
                    WiFiNotification::APReady { ssid } => {
                        tracing::info!(%ssid, "Wi-Fi AP ready");
                    }
                    WiFiNotification::STAFailed { reason } => {
                        tracing::warn!(%reason, "Wi-Fi STA failed");
                    }
                    WiFiNotification::AdapterMissing => {
                        tracing::error!("Wi-Fi adapter not found");
                    }
                },
            }
        }
    }

    async fn execute_bridge_effects(
        &self,
        effects: Vec<BridgeEffect>,
        event_tx: mpsc::Sender<InternalEvent>,
    ) {
        for effect in effects {
            match effect {
                BridgeEffect::CreateBridge => {
                    tracing::info!("Creating bridge");
                    let tx = event_tx.clone();
                    tokio::spawn(async move {
                        match executor::create_bridge().await {
                            Ok(()) => {
                                let _ = tx
                                    .send(InternalEvent::Bridge(BridgeEvent::Created))
                                    .await;
                            }
                            Err(e) => {
                                let _ = tx
                                    .send(InternalEvent::Bridge(BridgeEvent::CreateFailed {
                                        reason: e,
                                    }))
                                    .await;
                            }
                        }
                    });
                }
                BridgeEffect::DestroyBridge => {
                    tracing::info!("Destroying bridge");
                    if let Err(e) =
                        executor::run_shell("sh", &["/usr/lib/bridgebox/destroy-bridge.sh"]).await
                    {
                        tracing::error!("Destroy bridge failed: {e}");
                    }
                }
                BridgeEffect::Notify(notification) => match notification {
                    BridgeNotification::BridgeActive => {
                        tracing::info!("Bridge active");
                        self.send_event(EventData {
                            event: "mode_changed".into(),
                            version: None,
                            mode: Some("bridge".into()),
                            reason: None,
                        })
                        .await;
                    }
                    BridgeNotification::BridgeFailed { reason } => {
                        tracing::error!(%reason, "Bridge failed");
                    }
                    BridgeNotification::BridgeDestroyed => {
                        tracing::info!("Bridge destroyed");
                    }
                },
            }
        }
    }

    async fn execute_mesh_effects(
        &self,
        effects: Vec<MeshEffect>,
        event_tx: mpsc::Sender<InternalEvent>,
    ) {
        for effect in effects {
            match effect {
                MeshEffect::RequestAuthKey => {
                    tracing::info!("Requesting auth key from backend");
                    let backend_url = self.config.backend_url.clone();
                    let device_id = self.config.box_id.clone();
                    let tx = event_tx.clone();
                    tokio::spawn(async move {
                        match executor::request_auth_key(&backend_url, &device_id).await {
                            Ok(key) => {
                                let _ = tx
                                    .send(InternalEvent::Mesh(MeshEvent::AuthKeyReceived { key }))
                                    .await;
                            }
                            Err(e) => {
                                let _ = tx
                                    .send(InternalEvent::Mesh(MeshEvent::AuthKeyDenied {
                                        reason: e,
                                    }))
                                    .await;
                            }
                        }
                    });
                }
                MeshEffect::TailscaleUp { auth_key } => {
                    tracing::info!("Tailscale up");
                    let headscale_url = self.config.headscale_url.clone();
                    let tx = event_tx.clone();
                    tokio::spawn(async move {
                        match executor::tailscale_up(&headscale_url, &auth_key).await {
                            Ok(output) => {
                                // Извлекаем Tailscale IP
                                if let Some(ip) = parse_tailscale_ip(&output) {
                                    let _ = tx
                                        .send(InternalEvent::Mesh(MeshEvent::TailscaleUp { ip }))
                                        .await;
                                } else {
                                    // Пробуем получить IP через tailscale ip
                                    match executor::run_shell("tailscale", &["ip", "-4"]).await {
                                        Ok(ip_str) => {
                                            if let Ok(ip) = ip_str.parse::<IpAddr>() {
                                                let _ = tx
                                                    .send(InternalEvent::Mesh(
                                                        MeshEvent::TailscaleUp { ip },
                                                    ))
                                                    .await;
                                            } else {
                                                let _ = tx
                                                    .send(InternalEvent::Mesh(
                                                        MeshEvent::TailscaleFailed {
                                                            reason: format!(
                                                                "bad tailscale IP: {ip_str}"
                                                            ),
                                                        },
                                                    ))
                                                    .await;
                                            }
                                        }
                                        Err(e) => {
                                            let _ = tx
                                                .send(InternalEvent::Mesh(
                                                    MeshEvent::TailscaleFailed { reason: e },
                                                ))
                                                .await;
                                        }
                                    }
                                }
                            }
                            Err(e) => {
                                let _ = tx
                                    .send(InternalEvent::Mesh(MeshEvent::TailscaleFailed {
                                        reason: e,
                                    }))
                                    .await;
                            }
                        }
                    });
                }
                MeshEffect::Notify(notification) => match notification {
                    MeshNotification::MeshReady { ip } => {
                        tracing::info!(%ip, "Mesh ready");
                        // Mesh готов — подключаемся к backend через WS
                        let ws_url = format!(
                            "{}/ws/devices/{}",
                            self.config
                                .backend_url
                                .replace("http://", "ws://")
                                .replace("https://", "wss://"),
                            self.config.box_id
                        );
                        let _ = event_tx
                            .send(InternalEvent::Conn(ConnEvent::MeshReady { ws_url }))
                            .await;
                    }
                    MeshNotification::MeshLost => {
                        tracing::warn!("Mesh lost");
                        let _ = event_tx
                            .send(InternalEvent::Conn(ConnEvent::MeshLost))
                            .await;
                    }
                    MeshNotification::MeshFailed { reason } => {
                        tracing::error!(%reason, "Mesh failed");
                    }
                },
            }
        }
    }

    async fn execute_overlay_effects(
        &self,
        effects: Vec<OverlayEffect>,
        event_tx: mpsc::Sender<InternalEvent>,
    ) {
        for effect in effects {
            match effect {
                OverlayEffect::Download { url, dest } => {
                    tracing::info!(%url, "Downloading overlay");
                    let tx = event_tx.clone();
                    tokio::spawn(async move {
                        match executor::download(&url, &dest).await {
                            Ok(()) => {
                                let _ = tx
                                    .send(InternalEvent::Overlay(OverlayEvent::DownloadOk))
                                    .await;
                            }
                            Err(e) => {
                                let _ = tx
                                    .send(InternalEvent::Overlay(OverlayEvent::DownloadFailed {
                                        reason: e,
                                    }))
                                    .await;
                            }
                        }
                    });
                }
                OverlayEffect::Extract { archive, dest } => {
                    // Создаём директорию и распаковываем
                    let _ = tokio::fs::create_dir_all(&dest).await;
                    if let Err(e) = executor::extract_tar(&archive, &dest).await {
                        tracing::error!("Extract failed: {e}");
                        let _ = event_tx
                            .send(InternalEvent::Overlay(OverlayEvent::ApplyFailed {
                                reason: format!("extract: {e}"),
                            }))
                            .await;
                    }
                }
                OverlayEffect::RunApply { bundle_dir } => {
                    let tx = event_tx.clone();
                    tokio::spawn(async move {
                        match executor::run_bundle_script(&bundle_dir, "apply.sh").await {
                            Ok(()) => {
                                let _ = tx
                                    .send(InternalEvent::Overlay(OverlayEvent::ApplyOk))
                                    .await;
                            }
                            Err(e) => {
                                let _ = tx
                                    .send(InternalEvent::Overlay(OverlayEvent::ApplyFailed {
                                        reason: e,
                                    }))
                                    .await;
                            }
                        }
                    });
                }
                OverlayEffect::RunRollback { bundle_dir } => {
                    let tx = event_tx.clone();
                    tokio::spawn(async move {
                        match executor::run_bundle_script(&bundle_dir, "rollback.sh").await {
                            Ok(()) => {
                                let _ = tx
                                    .send(InternalEvent::Overlay(OverlayEvent::RollbackComplete))
                                    .await;
                            }
                            Err(e) => {
                                tracing::error!("Rollback script failed: {e}");
                                // Всё равно считаем rollback завершённым —
                                // лучше неполный rollback, чем зависание
                                let _ = tx
                                    .send(InternalEvent::Overlay(OverlayEvent::RollbackComplete))
                                    .await;
                            }
                        }
                    });
                }
                OverlayEffect::WriteVersion { version, status } => {
                    let _ = tokio::fs::create_dir_all("/etc/bridgebox").await;
                    let ver = version.as_deref().unwrap_or("");
                    if let Err(e) =
                        tokio::fs::write("/etc/bridgebox/overlay-version", ver).await
                    {
                        tracing::error!("Write overlay-version failed: {e}");
                    }
                    if let Err(e) =
                        tokio::fs::write("/etc/bridgebox/overlay-status", &status).await
                    {
                        tracing::error!("Write overlay-status failed: {e}");
                    }
                }
                OverlayEffect::CleanupArchive { path } => {
                    let _ = tokio::fs::remove_file(&path).await;
                }
                OverlayEffect::Notify(notification) => match notification {
                    OverlayNotification::Applied { version } => {
                        tracing::info!(%version, "Overlay applied");
                        self.send_event(EventData {
                            event: "overlay_applied".into(),
                            version: Some(version),
                            mode: None,
                            reason: None,
                        })
                        .await;
                    }
                    OverlayNotification::Failed {
                        version,
                        reason,
                        attempt,
                    } => {
                        tracing::error!(%version, %reason, attempt, "Overlay failed");
                        self.send_event(EventData {
                            event: "overlay_failed".into(),
                            version: Some(version),
                            mode: None,
                            reason: Some(reason),
                        })
                        .await;
                    }
                    OverlayNotification::RolledBack => {
                        tracing::info!("Overlay rolled back");
                        self.send_event(EventData {
                            event: "overlay_rolled_back".into(),
                            version: None,
                            mode: None,
                            reason: None,
                        })
                        .await;
                    }
                },
            }
        }
    }

    async fn execute_conn_effects(&self, effects: Vec<ConnEffect>) {
        for effect in effects {
            match effect {
                ConnEffect::ConnectWs { url } => {
                    tracing::info!(%url, "ConnEffect: connect WS (handled by retry loop)");
                }
                ConnEffect::WsSend { payload } => {
                    tracing::debug!("ConnEffect: WS send");
                    let _ = payload; // Отправка идёт через ws_tx напрямую
                }
                ConnEffect::HttpHeartbeat => {
                    tracing::debug!("HTTP heartbeat fallback");
                    let heartbeat = telemetry::collect();
                    let msg = AgentMessage::Heartbeat(heartbeat);
                    let url = format!(
                        "{}/api/devices/{}/heartbeat",
                        self.config.backend_url, self.config.box_id
                    );
                    tokio::spawn(async move {
                        let json = match serde_json::to_string(&msg) {
                            Ok(j) => j,
                            Err(e) => {
                                tracing::error!("HTTP heartbeat serialize: {e}");
                                return;
                            }
                        };
                        let result = tokio::task::spawn_blocking(move || -> Result<(), String> {
                            ureq::post(&url)
                                .header("Content-Type", "application/json")
                                .send(json.as_bytes())
                                .map_err(|e| format!("HTTP heartbeat: {e}"))?;
                            Ok(())
                        })
                        .await;
                        match result {
                            Ok(Ok(_)) => tracing::debug!("HTTP heartbeat sent"),
                            Ok(Err(e)) => tracing::warn!("{e}"),
                            Err(e) => tracing::warn!("HTTP heartbeat task: {e}"),
                        }
                    });
                }
                ConnEffect::Notify(notification) => match notification {
                    ConnNotification::Connected => {
                        tracing::info!("Backend connection: WebSocket");
                    }
                    ConnNotification::Disconnected => {
                        tracing::warn!("Backend connection: offline");
                        self.ws_tx.as_ref(); // no-op, ws_tx cleared in try_ws_connect
                    }
                    ConnNotification::FallbackActive => {
                        tracing::warn!("Backend connection: HTTP fallback");
                    }
                },
            }
        }
    }

    // --- Helpers ---

    async fn send_heartbeat(&self) {
        let heartbeat = telemetry::collect();
        let msg = AgentMessage::Heartbeat(heartbeat);
        if let Some(tx) = &self.ws_tx {
            if tx.send(msg).await.is_err() {
                tracing::warn!("WS send heartbeat failed (channel closed)");
            }
        }
    }

    async fn send_event(&self, event: EventData) {
        let msg = AgentMessage::Event(event);
        if let Some(tx) = &self.ws_tx {
            if tx.send(msg).await.is_err() {
                tracing::warn!("WS send event failed (channel closed)");
            }
        }
    }

    async fn try_ws_connect(&mut self, ws_msg_tx: mpsc::Sender<BackendMessage>) {
        let ws_url = format!(
            "{}/ws/devices/{}",
            self.config
                .backend_url
                .replace("http://", "ws://")
                .replace("https://", "wss://"),
            self.config.box_id
        );

        match ws::connect(&ws_url).await {
            Ok((tx, mut rx, handle)) => {
                tracing::info!("WS connected");
                self.ws_tx = Some(tx);
                self.transition_conn(ConnEvent::WsConnected).await;

                // Пробрасываем сообщения из WS в основной event loop
                let ws_msg_tx = ws_msg_tx.clone();
                tokio::spawn(async move {
                    while let Some(msg) = rx.recv().await {
                        if ws_msg_tx.send(msg).await.is_err() {
                            break;
                        }
                    }
                    // WS канал закрыт — ждём завершения задачи
                    let _ = handle.await;
                });
            }
            Err(e) => {
                tracing::debug!("WS connect failed: {e}");
                self.ws_tx = None;
            }
        }
    }
}

/// Парсит IPv4 адрес из вывода `ip addr show`.
fn parse_ip_from_output(output: &str) -> Option<IpAddr> {
    for line in output.lines() {
        let line = line.trim();
        if line.starts_with("inet ") {
            // "inet 192.168.1.100/24 ..."
            if let Some(addr_part) = line.split_whitespace().nth(1) {
                if let Some(ip_str) = addr_part.split('/').next() {
                    if let Ok(ip) = ip_str.parse::<IpAddr>() {
                        return Some(ip);
                    }
                }
            }
        }
    }
    None
}

/// Парсит Tailscale IP из вывода tailscale up.
fn parse_tailscale_ip(output: &str) -> Option<IpAddr> {
    // tailscale up обычно не выводит IP, но на всякий случай
    for line in output.lines() {
        if let Ok(ip) = line.trim().parse::<IpAddr>() {
            return Some(ip);
        }
    }
    None
}
