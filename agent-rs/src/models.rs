use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "UPPERCASE")]
pub enum DeviceState {
    Setup,
    Unclaimed,
    Claimed,
    Active,
    Bypass,
}

impl std::fmt::Display for DeviceState {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let s = match self {
            Self::Setup => "setup",
            Self::Unclaimed => "unclaimed",
            Self::Claimed => "claimed",
            Self::Active => "active",
            Self::Bypass => "bypass",
        };
        f.write_str(s)
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RegisterRequest {
    pub device_id: String,
    pub mac_eth0: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RegisterResponse {
    pub device_id: String,
    pub state: DeviceState,
    pub tailscale_auth_key: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum OverlayStatus {
    None,
    Applying,
    Applied,
    Failed,
}

impl std::fmt::Display for OverlayStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let s = match self {
            Self::None => "none",
            Self::Applying => "applying",
            Self::Applied => "applied",
            Self::Failed => "failed",
        };
        f.write_str(s)
    }
}

impl OverlayStatus {
    pub fn from_str(s: &str) -> Self {
        match s.trim() {
            "applied" => Self::Applied,
            "applying" => Self::Applying,
            "failed" => Self::Failed,
            _ => Self::None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DesiredOverlay {
    pub version: String,
    pub url: String,
    pub sha256: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HeartbeatRequest {
    pub device_id: String,
    pub uptime: u64,
    pub wlan_connected: bool,
    pub bridge_up: bool,
    pub tailscale_connected: bool,
    pub overlay_version: Option<String>,
    pub overlay_status: OverlayStatus,
    pub overlay_service_running: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HeartbeatResponse {
    pub state: DeviceState,
    pub desired_overlay: Option<DesiredOverlay>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceStateResponse {
    pub device_id: String,
    pub state: DeviceState,
    pub expires_at: String,
    pub grace_hours: i32,
}

#[derive(Debug, Serialize)]
pub struct DeviceEvent {
    pub event: String,
    pub version: Option<String>,
    pub details: String,
    pub timestamp: String,
}

#[derive(Debug, Deserialize)]
pub struct ErrorResponse {
    pub error: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn overlay_status_from_str() {
        assert_eq!(OverlayStatus::from_str("applied"), OverlayStatus::Applied);
        assert_eq!(OverlayStatus::from_str("failed"), OverlayStatus::Failed);
        assert_eq!(OverlayStatus::from_str("applying"), OverlayStatus::Applying);
        assert_eq!(OverlayStatus::from_str("none"), OverlayStatus::None);
        assert_eq!(OverlayStatus::from_str(""), OverlayStatus::None);
        assert_eq!(OverlayStatus::from_str("garbage"), OverlayStatus::None);
        assert_eq!(OverlayStatus::from_str("applied\n"), OverlayStatus::Applied);
    }

    #[test]
    fn overlay_status_display() {
        assert_eq!(format!("{}", OverlayStatus::Applied), "applied");
        assert_eq!(format!("{}", OverlayStatus::Failed), "failed");
        assert_eq!(format!("{}", OverlayStatus::None), "none");
    }

    #[test]
    fn desired_overlay_deserialization() {
        let json = r#"{
            "state": "CLAIMED",
            "desiredOverlay": {
                "version": "zap-0.9.4-msk-2",
                "url": "https://example.com/bundle.tar.gz",
                "sha256": "abc123"
            }
        }"#;

        let resp: HeartbeatResponse = serde_json::from_str(json).unwrap();
        assert_eq!(resp.state, DeviceState::Claimed);
        assert!(resp.desired_overlay.is_some());
        let overlay = resp.desired_overlay.unwrap();
        assert_eq!(overlay.version, "zap-0.9.4-msk-2");
        assert_eq!(overlay.sha256, "abc123");
    }

    #[test]
    fn heartbeat_response_null_overlay() {
        let json = r#"{"state": "UNCLAIMED", "desiredOverlay": null}"#;
        let resp: HeartbeatResponse = serde_json::from_str(json).unwrap();
        assert_eq!(resp.state, DeviceState::Unclaimed);
        assert!(resp.desired_overlay.is_none());
    }

    #[test]
    fn heartbeat_request_serialization() {
        let req = HeartbeatRequest {
            device_id: "BB-TEST01".to_string(),
            uptime: 3600,
            wlan_connected: true,
            bridge_up: true,
            tailscale_connected: true,
            overlay_version: Some("zap-0.9.4-msk-2".to_string()),
            overlay_status: OverlayStatus::Applied,
            overlay_service_running: true,
        };

        let json = serde_json::to_string(&req).unwrap();
        assert!(json.contains("\"overlayVersion\":\"zap-0.9.4-msk-2\""));
        assert!(json.contains("\"overlayStatus\":\"applied\""));
        assert!(json.contains("\"overlayServiceRunning\":true"));
    }
}
