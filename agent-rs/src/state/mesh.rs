use std::net::IpAddr;

use super::StateMachine;

#[derive(Debug, Clone, PartialEq)]
pub enum MeshState {
    Disconnected,
    RequestingKey,
    Connecting { auth_key: String },
    Connected { ip: IpAddr },
    Failed { reason: String },
}

#[derive(Debug, Clone, PartialEq)]
pub enum MeshEvent {
    ManagementReady,
    AuthKeyReceived { key: String },
    AuthKeyDenied { reason: String },
    TailscaleUp { ip: IpAddr },
    TailscaleFailed { reason: String },
    TailscaleDown,
}

#[derive(Debug, Clone, PartialEq)]
pub enum MeshEffect {
    RequestAuthKey,
    TailscaleUp { auth_key: String },
    Notify(MeshNotification),
}

#[derive(Debug, Clone, PartialEq)]
pub enum MeshNotification {
    MeshReady { ip: IpAddr },
    MeshLost,
    MeshFailed { reason: String },
}

impl StateMachine for MeshState {
    type Event = MeshEvent;
    type Effect = MeshEffect;

    fn handle(self, event: Self::Event) -> (Self, Vec<Self::Effect>) {
        match (self, event) {
            (MeshState::Disconnected, MeshEvent::ManagementReady) => (
                MeshState::RequestingKey,
                vec![MeshEffect::RequestAuthKey],
            ),

            (MeshState::RequestingKey, MeshEvent::AuthKeyReceived { key }) => (
                MeshState::Connecting {
                    auth_key: key.clone(),
                },
                vec![MeshEffect::TailscaleUp { auth_key: key }],
            ),

            (MeshState::RequestingKey, MeshEvent::AuthKeyDenied { reason }) => (
                MeshState::Failed {
                    reason: reason.clone(),
                },
                vec![MeshEffect::Notify(MeshNotification::MeshFailed { reason })],
            ),

            (MeshState::Connecting { .. }, MeshEvent::TailscaleUp { ip }) => (
                MeshState::Connected { ip },
                vec![MeshEffect::Notify(MeshNotification::MeshReady { ip })],
            ),

            (MeshState::Connecting { .. }, MeshEvent::TailscaleFailed { reason }) => (
                MeshState::Failed {
                    reason: reason.clone(),
                },
                vec![MeshEffect::Notify(MeshNotification::MeshFailed { reason })],
            ),

            (MeshState::Connected { .. }, MeshEvent::TailscaleDown) => (
                MeshState::Disconnected,
                vec![MeshEffect::Notify(MeshNotification::MeshLost)],
            ),

            (MeshState::Failed { .. }, MeshEvent::ManagementReady) => (
                MeshState::RequestingKey,
                vec![MeshEffect::RequestAuthKey],
            ),

            (state, _) => (state, vec![]),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::Ipv4Addr;

    #[test]
    fn disconnected_management_ready_requests_key() {
        let (state, effects) = MeshState::Disconnected.handle(MeshEvent::ManagementReady);
        assert_eq!(state, MeshState::RequestingKey);
        assert_eq!(effects, vec![MeshEffect::RequestAuthKey]);
    }

    #[test]
    fn requesting_key_received_starts_tailscale() {
        let key = "tskey-auth-abc123".to_string();
        let (state, effects) =
            MeshState::RequestingKey.handle(MeshEvent::AuthKeyReceived { key: key.clone() });
        assert_eq!(
            state,
            MeshState::Connecting {
                auth_key: key.clone()
            }
        );
        assert_eq!(effects, vec![MeshEffect::TailscaleUp { auth_key: key }]);
    }

    #[test]
    fn connecting_tailscale_up_becomes_connected() {
        let ip = IpAddr::V4(Ipv4Addr::new(100, 64, 0, 1));
        let (state, effects) = MeshState::Connecting {
            auth_key: "tskey-auth-abc123".to_string(),
        }
        .handle(MeshEvent::TailscaleUp { ip });
        assert_eq!(state, MeshState::Connected { ip });
        assert_eq!(
            effects,
            vec![MeshEffect::Notify(MeshNotification::MeshReady { ip })]
        );
    }

    #[test]
    fn connected_tailscale_down_disconnects() {
        let ip = IpAddr::V4(Ipv4Addr::new(100, 64, 0, 1));
        let (state, effects) = MeshState::Connected { ip }.handle(MeshEvent::TailscaleDown);
        assert_eq!(state, MeshState::Disconnected);
        assert_eq!(
            effects,
            vec![MeshEffect::Notify(MeshNotification::MeshLost)]
        );
    }

    #[test]
    fn failed_management_ready_retries() {
        let (state, effects) = MeshState::Failed {
            reason: "denied".to_string(),
        }
        .handle(MeshEvent::ManagementReady);
        assert_eq!(state, MeshState::RequestingKey);
        assert_eq!(effects, vec![MeshEffect::RequestAuthKey]);
    }
}
