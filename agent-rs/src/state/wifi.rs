use std::net::IpAddr;

use super::StateMachine;

#[derive(Debug, Clone, PartialEq)]
pub enum WiFiState {
    Down,
    AP { ssid: String },
    Connecting { ssid: String, password: String, attempt: u32 },
    STA { ssid: String, ip: IpAddr },
}

#[derive(Debug, Clone, PartialEq)]
pub enum WiFiEvent {
    AdapterDetected { phy: String },
    AdapterTimeout,
    CredentialsReceived { ssid: String, password: String },
    Associated,
    DhcpSuccess { ip: IpAddr },
    ConnectTimeout,
    DhcpFailed,
    ConnectionLost,
    SwitchToAP,
}

#[derive(Debug, Clone, PartialEq)]
pub enum WiFiEffect {
    StartAP { phy: String, ssid: String },
    StartSTA { ssid: String, password: String },
    Cleanup,
    SaveCredentials { ssid: String, password: String },
    Notify(WiFiNotification),
}

#[derive(Debug, Clone, PartialEq)]
pub enum WiFiNotification {
    APReady { ssid: String },
    STAReady { ip: IpAddr },
    STAFailed { reason: String },
    AdapterMissing,
}

impl WiFiState {
    pub fn ap_ssid(box_id: &str) -> String {
        format!("BridgeBox-{}", box_id)
    }
}

impl StateMachine for WiFiState {
    type Event = WiFiEvent;
    type Effect = WiFiEffect;

    fn handle(self, event: Self::Event) -> (Self, Vec<Self::Effect>) {
        match (self, event) {
            (WiFiState::Down, WiFiEvent::AdapterDetected { phy }) => {
                let ssid = WiFiState::ap_ssid("default");
                (
                    WiFiState::AP { ssid: ssid.clone() },
                    vec![
                        WiFiEffect::StartAP { phy, ssid: ssid.clone() },
                        WiFiEffect::Notify(WiFiNotification::APReady { ssid }),
                    ],
                )
            }

            (WiFiState::Down, WiFiEvent::AdapterTimeout) => (
                WiFiState::Down,
                vec![WiFiEffect::Notify(WiFiNotification::AdapterMissing)],
            ),

            (WiFiState::AP { .. }, WiFiEvent::CredentialsReceived { ssid, password }) => (
                WiFiState::Connecting {
                    ssid: ssid.clone(),
                    password: password.clone(),
                    attempt: 1,
                },
                vec![
                    WiFiEffect::Cleanup,
                    WiFiEffect::SaveCredentials {
                        ssid: ssid.clone(),
                        password: password.clone(),
                    },
                    WiFiEffect::StartSTA { ssid, password },
                ],
            ),

            (WiFiState::Connecting { ssid, password, attempt }, WiFiEvent::Associated) => (
                WiFiState::Connecting { ssid, password, attempt },
                vec![],
            ),

            (WiFiState::Connecting { ssid, .. }, WiFiEvent::DhcpSuccess { ip }) => (
                WiFiState::STA { ssid, ip },
                vec![WiFiEffect::Notify(WiFiNotification::STAReady { ip })],
            ),

            (WiFiState::Connecting { .. }, WiFiEvent::ConnectTimeout) => {
                let ssid = WiFiState::ap_ssid("default");
                (
                    WiFiState::AP { ssid: ssid.clone() },
                    vec![
                        WiFiEffect::Cleanup,
                        WiFiEffect::Notify(WiFiNotification::STAFailed {
                            reason: "connect timeout".to_string(),
                        }),
                    ],
                )
            }

            (WiFiState::Connecting { .. }, WiFiEvent::DhcpFailed) => {
                let ssid = WiFiState::ap_ssid("default");
                (
                    WiFiState::AP { ssid: ssid.clone() },
                    vec![
                        WiFiEffect::Cleanup,
                        WiFiEffect::Notify(WiFiNotification::STAFailed {
                            reason: "DHCP failed".to_string(),
                        }),
                    ],
                )
            }

            (WiFiState::STA { ssid, .. }, WiFiEvent::ConnectionLost) => {
                let password = String::new();
                (
                    WiFiState::Connecting {
                        ssid: ssid.clone(),
                        password: password.clone(),
                        attempt: 1,
                    },
                    vec![WiFiEffect::StartSTA { ssid, password }],
                )
            }

            (WiFiState::STA { .. }, WiFiEvent::SwitchToAP) => {
                let ssid = WiFiState::ap_ssid("default");
                (
                    WiFiState::AP { ssid: ssid.clone() },
                    vec![
                        WiFiEffect::Cleanup,
                        WiFiEffect::Notify(WiFiNotification::APReady { ssid }),
                    ],
                )
            }

            (state, _) => (state, vec![]),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::IpAddr;

    #[test]
    fn down_adapter_detected_starts_ap() {
        let (state, effects) = WiFiState::Down.handle(WiFiEvent::AdapterDetected {
            phy: "phy0".to_string(),
        });
        let ssid = WiFiState::ap_ssid("default");
        assert_eq!(state, WiFiState::AP { ssid: ssid.clone() });
        assert!(effects.contains(&WiFiEffect::StartAP {
            phy: "phy0".to_string(),
            ssid: ssid.clone(),
        }));
        assert!(effects.contains(&WiFiEffect::Notify(WiFiNotification::APReady { ssid })));
    }

    #[test]
    fn ap_credentials_starts_connecting() {
        let ssid = WiFiState::ap_ssid("default");
        let (state, effects) = WiFiState::AP { ssid }.handle(WiFiEvent::CredentialsReceived {
            ssid: "HomeWifi".to_string(),
            password: "secret123".to_string(),
        });
        assert_eq!(
            state,
            WiFiState::Connecting {
                ssid: "HomeWifi".to_string(),
                password: "secret123".to_string(),
                attempt: 1,
            }
        );
        assert!(effects.contains(&WiFiEffect::Cleanup));
        assert!(effects.contains(&WiFiEffect::SaveCredentials {
            ssid: "HomeWifi".to_string(),
            password: "secret123".to_string(),
        }));
        assert!(effects.contains(&WiFiEffect::StartSTA {
            ssid: "HomeWifi".to_string(),
            password: "secret123".to_string(),
        }));
    }

    #[test]
    fn connecting_dhcp_success_becomes_sta() {
        let ip: IpAddr = "192.168.1.100".parse().unwrap();
        let (state, effects) = WiFiState::Connecting {
            ssid: "HomeWifi".to_string(),
            password: "secret123".to_string(),
            attempt: 1,
        }
        .handle(WiFiEvent::DhcpSuccess { ip });
        assert_eq!(
            state,
            WiFiState::STA {
                ssid: "HomeWifi".to_string(),
                ip,
            }
        );
        assert!(effects.contains(&WiFiEffect::Notify(WiFiNotification::STAReady { ip })));
    }

    #[test]
    fn connecting_timeout_falls_back_to_ap() {
        let (state, effects) = WiFiState::Connecting {
            ssid: "HomeWifi".to_string(),
            password: "secret123".to_string(),
            attempt: 1,
        }
        .handle(WiFiEvent::ConnectTimeout);
        let ssid = WiFiState::ap_ssid("default");
        assert_eq!(state, WiFiState::AP { ssid });
        assert!(effects.contains(&WiFiEffect::Cleanup));
        assert!(effects.contains(&WiFiEffect::Notify(WiFiNotification::STAFailed {
            reason: "connect timeout".to_string(),
        })));
    }

    #[test]
    fn sta_connection_lost_reconnects() {
        let ip: IpAddr = "192.168.1.100".parse().unwrap();
        let (state, effects) = WiFiState::STA {
            ssid: "HomeWifi".to_string(),
            ip,
        }
        .handle(WiFiEvent::ConnectionLost);
        assert!(matches!(state, WiFiState::Connecting { ref ssid, .. } if ssid == "HomeWifi"));
        assert!(effects.iter().any(|e| matches!(e, WiFiEffect::StartSTA { .. })));
    }

    #[test]
    fn sta_switch_to_ap() {
        let ip: IpAddr = "192.168.1.100".parse().unwrap();
        let (state, effects) = WiFiState::STA {
            ssid: "HomeWifi".to_string(),
            ip,
        }
        .handle(WiFiEvent::SwitchToAP);
        let ssid = WiFiState::ap_ssid("default");
        assert_eq!(state, WiFiState::AP { ssid: ssid.clone() });
        assert!(effects.contains(&WiFiEffect::Cleanup));
        assert!(effects.contains(&WiFiEffect::Notify(WiFiNotification::APReady { ssid })));
    }

    #[test]
    fn down_adapter_timeout_stays_down() {
        let (state, effects) = WiFiState::Down.handle(WiFiEvent::AdapterTimeout);
        assert_eq!(state, WiFiState::Down);
        assert!(effects.contains(&WiFiEffect::Notify(WiFiNotification::AdapterMissing)));
    }
}
