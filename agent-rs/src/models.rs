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
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HeartbeatRequest {
    pub device_id: String,
    pub uptime: u64,
    pub wlan_connected: bool,
    pub bridge_up: bool,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct HeartbeatResponse {
    pub state: DeviceState,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceStateResponse {
    pub device_id: String,
    pub state: DeviceState,
    pub expires_at: String,
    pub grace_hours: i32,
}

#[derive(Debug, Deserialize)]
pub struct ErrorResponse {
    pub error: String,
}
