use serde::{Deserialize, Serialize};

/// Agent → Backend (по WebSocket)
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", content = "data")]
#[serde(rename_all = "snake_case")]
pub enum AgentMessage {
    Heartbeat(HeartbeatData),
    Event(EventData),
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HeartbeatData {
    pub uptime: u64,
    pub wlan_connected: bool,
    pub bridge_up: bool,
    pub overlay_version: Option<String>,
    pub overlay_service_running: bool,
    pub tailscale_connected: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct EventData {
    pub event: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mode: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

/// Backend → Agent (по WebSocket)
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "type", content = "data")]
#[serde(rename_all = "snake_case")]
pub enum BackendMessage {
    Command(CommandData),
    DesiredState(DesiredStateData),
}

#[derive(Debug, Clone, Deserialize)]
pub struct CommandData {
    pub cmd: String,
    #[serde(default)]
    pub mode: Option<String>,
    #[serde(default)]
    pub version: Option<String>,
    #[serde(default)]
    pub url: Option<String>,
    #[serde(default)]
    pub sha256: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct DesiredStateData {
    pub overlay: Option<DesiredOverlayData>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct DesiredOverlayData {
    pub version: String,
    pub url: String,
    pub sha256: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn serialize_heartbeat() {
        let msg = AgentMessage::Heartbeat(HeartbeatData {
            uptime: 3600,
            wlan_connected: true,
            bridge_up: true,
            overlay_version: Some("1.0.0".into()),
            overlay_service_running: true,
            tailscale_connected: false,
        });
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains(r#""type":"heartbeat""#));
        assert!(json.contains(r#""uptime""#));
    }

    #[test]
    fn serialize_event_mode_changed() {
        let msg = AgentMessage::Event(EventData {
            event: "mode_changed".into(),
            version: None,
            mode: Some("bridge".into()),
            reason: None,
        });
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("mode_changed"));
        assert!(json.contains("bridge"));
    }

    #[test]
    fn deserialize_command_switch_mode() {
        let json = r#"{"type":"command","data":{"cmd":"switch_mode","mode":"bridge"}}"#;
        let msg: BackendMessage = serde_json::from_str(json).unwrap();
        if let BackendMessage::Command(data) = msg {
            assert_eq!(data.cmd, "switch_mode");
            assert_eq!(data.mode.as_deref(), Some("bridge"));
        } else {
            panic!("expected Command variant");
        }
    }

    #[test]
    fn deserialize_command_apply_overlay() {
        let json = r#"{"type":"command","data":{"cmd":"apply_overlay","version":"2.0.0","url":"https://example.com/overlay.tar.gz","sha256":"abc123"}}"#;
        let msg: BackendMessage = serde_json::from_str(json).unwrap();
        if let BackendMessage::Command(data) = msg {
            assert_eq!(data.cmd, "apply_overlay");
            assert_eq!(data.version.as_deref(), Some("2.0.0"));
            assert_eq!(data.url.as_deref(), Some("https://example.com/overlay.tar.gz"));
            assert_eq!(data.sha256.as_deref(), Some("abc123"));
        } else {
            panic!("expected Command variant");
        }
    }

    #[test]
    fn deserialize_desired_state_with_overlay() {
        let json = r#"{"type":"desired_state","data":{"overlay":{"version":"1.2.3","url":"https://example.com/v1.2.3.tar.gz","sha256":"deadbeef"}}}"#;
        let msg: BackendMessage = serde_json::from_str(json).unwrap();
        if let BackendMessage::DesiredState(data) = msg {
            let overlay = data.overlay.expect("overlay should be present");
            assert_eq!(overlay.version, "1.2.3");
            assert_eq!(overlay.url, "https://example.com/v1.2.3.tar.gz");
            assert_eq!(overlay.sha256, "deadbeef");
        } else {
            panic!("expected DesiredState variant");
        }
    }

    #[test]
    fn deserialize_desired_state_null_overlay() {
        let json = r#"{"type":"desired_state","data":{"overlay":null}}"#;
        let msg: BackendMessage = serde_json::from_str(json).unwrap();
        if let BackendMessage::DesiredState(data) = msg {
            assert!(data.overlay.is_none());
        } else {
            panic!("expected DesiredState variant");
        }
    }
}
