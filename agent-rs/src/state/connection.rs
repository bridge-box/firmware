use std::time::Duration;

use super::StateMachine;

pub const INITIAL_BACKOFF: Duration = Duration::from_secs(1);
pub const MAX_BACKOFF: Duration = Duration::from_secs(60);

#[derive(Debug, Clone, PartialEq)]
pub enum ConnState {
    Offline,
    WebSocket,
    HttpFallback { backoff: Duration },
}

#[derive(Debug, Clone, PartialEq)]
pub enum ConnEvent {
    MeshReady { ws_url: String },
    WsConnected,
    WsDisconnected,
    WsPingTimeout,
    HeartbeatTick,
    WsRetryTick,
    MeshLost,
}

#[derive(Debug, Clone, PartialEq)]
pub enum ConnEffect {
    ConnectWs { url: String },
    WsSend { payload: String },
    HttpHeartbeat,
    Notify(ConnNotification),
}

#[derive(Debug, Clone, PartialEq)]
pub enum ConnNotification {
    Connected,
    Disconnected,
    FallbackActive,
}

impl ConnState {
    pub fn next_backoff(current: Duration) -> Duration {
        let doubled = current.saturating_mul(2);
        if doubled > MAX_BACKOFF {
            MAX_BACKOFF
        } else {
            doubled
        }
    }
}

impl StateMachine for ConnState {
    type Event = ConnEvent;
    type Effect = ConnEffect;

    fn handle(self, event: Self::Event) -> (Self, Vec<Self::Effect>) {
        match (&self, &event) {
            // Any + MeshLost → Offline + Notify(Disconnected)
            (_, ConnEvent::MeshLost) => (
                ConnState::Offline,
                vec![ConnEffect::Notify(ConnNotification::Disconnected)],
            ),

            // Any + WsConnected → WebSocket + Notify(Connected)
            (_, ConnEvent::WsConnected) => (
                ConnState::WebSocket,
                vec![ConnEffect::Notify(ConnNotification::Connected)],
            ),

            // Offline + MeshReady → Offline + ConnectWs
            (ConnState::Offline, ConnEvent::MeshReady { ws_url }) => (
                ConnState::Offline,
                vec![ConnEffect::ConnectWs {
                    url: ws_url.clone(),
                }],
            ),

            // WebSocket + HeartbeatTick → WebSocket (no effects)
            (ConnState::WebSocket, ConnEvent::HeartbeatTick) => (ConnState::WebSocket, vec![]),

            // WebSocket + WsDisconnected/WsPingTimeout → HttpFallback{1s} + HttpHeartbeat, Notify(FallbackActive)
            (ConnState::WebSocket, ConnEvent::WsDisconnected)
            | (ConnState::WebSocket, ConnEvent::WsPingTimeout) => (
                ConnState::HttpFallback {
                    backoff: INITIAL_BACKOFF,
                },
                vec![
                    ConnEffect::HttpHeartbeat,
                    ConnEffect::Notify(ConnNotification::FallbackActive),
                ],
            ),

            // HttpFallback + HeartbeatTick → HttpFallback + HttpHeartbeat
            (ConnState::HttpFallback { .. }, ConnEvent::HeartbeatTick) => {
                (self, vec![ConnEffect::HttpHeartbeat])
            }

            // HttpFallback + WsRetryTick → HttpFallback{doubled backoff} (no effects)
            (ConnState::HttpFallback { backoff }, ConnEvent::WsRetryTick) => {
                let new_backoff = ConnState::next_backoff(*backoff);
                (ConnState::HttpFallback { backoff: new_backoff }, vec![])
            }

            // All other → (state, vec![])
            _ => (self, vec![]),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn offline_mesh_ready_connects_ws() {
        let (state, effects) = ConnState::Offline.handle(ConnEvent::MeshReady {
            ws_url: "ws://example.com".to_string(),
        });
        assert_eq!(state, ConnState::Offline);
        assert_eq!(
            effects,
            vec![ConnEffect::ConnectWs {
                url: "ws://example.com".to_string()
            }]
        );
    }

    #[test]
    fn ws_connected_transitions() {
        let (state, effects) = ConnState::Offline.handle(ConnEvent::WsConnected);
        assert_eq!(state, ConnState::WebSocket);
        assert_eq!(
            effects,
            vec![ConnEffect::Notify(ConnNotification::Connected)]
        );
    }

    #[test]
    fn ws_disconnect_falls_back_to_http() {
        let (state, effects) = ConnState::WebSocket.handle(ConnEvent::WsDisconnected);
        assert_eq!(
            state,
            ConnState::HttpFallback {
                backoff: INITIAL_BACKOFF
            }
        );
        assert_eq!(
            effects,
            vec![
                ConnEffect::HttpHeartbeat,
                ConnEffect::Notify(ConnNotification::FallbackActive),
            ]
        );
    }

    #[test]
    fn http_fallback_heartbeat_sends_http() {
        let state = ConnState::HttpFallback {
            backoff: INITIAL_BACKOFF,
        };
        let (new_state, effects) = state.handle(ConnEvent::HeartbeatTick);
        assert_eq!(
            new_state,
            ConnState::HttpFallback {
                backoff: INITIAL_BACKOFF
            }
        );
        assert_eq!(effects, vec![ConnEffect::HttpHeartbeat]);
    }

    #[test]
    fn http_fallback_retry_increases_backoff() {
        let state = ConnState::HttpFallback {
            backoff: INITIAL_BACKOFF,
        };
        let (new_state, effects) = state.handle(ConnEvent::WsRetryTick);
        assert_eq!(
            new_state,
            ConnState::HttpFallback {
                backoff: Duration::from_secs(2)
            }
        );
        assert!(effects.is_empty());
    }

    #[test]
    fn backoff_caps_at_max() {
        let state = ConnState::HttpFallback {
            backoff: Duration::from_secs(32),
        };
        let (s2, _) = state.handle(ConnEvent::WsRetryTick); // 64 → capped to 60
        assert_eq!(
            s2,
            ConnState::HttpFallback {
                backoff: MAX_BACKOFF
            }
        );

        // One more tick should stay at MAX
        let (s3, _) = s2.handle(ConnEvent::WsRetryTick);
        assert_eq!(
            s3,
            ConnState::HttpFallback {
                backoff: MAX_BACKOFF
            }
        );
    }

    #[test]
    fn any_state_mesh_lost_goes_offline() {
        for state in [
            ConnState::Offline,
            ConnState::WebSocket,
            ConnState::HttpFallback {
                backoff: Duration::from_secs(5),
            },
        ] {
            let (new_state, effects) = state.handle(ConnEvent::MeshLost);
            assert_eq!(new_state, ConnState::Offline);
            assert_eq!(
                effects,
                vec![ConnEffect::Notify(ConnNotification::Disconnected)]
            );
        }
    }
}
