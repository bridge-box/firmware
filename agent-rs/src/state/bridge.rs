use super::StateMachine;

#[derive(Debug, Clone, PartialEq)]
pub enum BridgeState {
    Disabled,
    Creating,
    Active,
    Failed { reason: String },
}

#[derive(Debug, Clone, PartialEq)]
pub enum BridgeEvent {
    Enable,
    Created,
    CreateFailed { reason: String },
    Disable,
}

#[derive(Debug, Clone, PartialEq)]
pub enum BridgeEffect {
    CreateBridge,
    DestroyBridge,
    Notify(BridgeNotification),
}

#[derive(Debug, Clone, PartialEq)]
pub enum BridgeNotification {
    BridgeActive,
    BridgeFailed { reason: String },
    BridgeDestroyed,
}

impl StateMachine for BridgeState {
    type Event = BridgeEvent;
    type Effect = BridgeEffect;

    fn handle(self, event: Self::Event) -> (Self, Vec<Self::Effect>) {
        match (self, event) {
            (BridgeState::Disabled, BridgeEvent::Enable) => {
                (BridgeState::Creating, vec![BridgeEffect::CreateBridge])
            }
            (BridgeState::Creating, BridgeEvent::Created) => {
                (BridgeState::Active, vec![BridgeEffect::Notify(BridgeNotification::BridgeActive)])
            }
            (BridgeState::Creating, BridgeEvent::CreateFailed { reason }) => {
                (
                    BridgeState::Failed { reason: reason.clone() },
                    vec![BridgeEffect::Notify(BridgeNotification::BridgeFailed { reason })],
                )
            }
            (BridgeState::Active, BridgeEvent::Disable) => {
                (
                    BridgeState::Disabled,
                    vec![
                        BridgeEffect::DestroyBridge,
                        BridgeEffect::Notify(BridgeNotification::BridgeDestroyed),
                    ],
                )
            }
            (BridgeState::Failed { .. }, BridgeEvent::Enable) => {
                (BridgeState::Creating, vec![BridgeEffect::CreateBridge])
            }
            (state, _) => (state, vec![]),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn disabled_enable_starts_creating() {
        let (state, effects) = BridgeState::Disabled.handle(BridgeEvent::Enable);
        assert_eq!(state, BridgeState::Creating);
        assert_eq!(effects, vec![BridgeEffect::CreateBridge]);
    }

    #[test]
    fn creating_created_becomes_active() {
        let (state, effects) = BridgeState::Creating.handle(BridgeEvent::Created);
        assert_eq!(state, BridgeState::Active);
        assert_eq!(effects, vec![BridgeEffect::Notify(BridgeNotification::BridgeActive)]);
    }

    #[test]
    fn creating_failed_becomes_failed() {
        let reason = "eth0 not found".to_string();
        let (state, effects) = BridgeState::Creating.handle(BridgeEvent::CreateFailed {
            reason: reason.clone(),
        });
        assert_eq!(state, BridgeState::Failed { reason: reason.clone() });
        assert_eq!(
            effects,
            vec![BridgeEffect::Notify(BridgeNotification::BridgeFailed { reason })]
        );
    }

    #[test]
    fn active_disable_becomes_disabled() {
        let (state, effects) = BridgeState::Active.handle(BridgeEvent::Disable);
        assert_eq!(state, BridgeState::Disabled);
        assert_eq!(
            effects,
            vec![
                BridgeEffect::DestroyBridge,
                BridgeEffect::Notify(BridgeNotification::BridgeDestroyed),
            ]
        );
    }

    #[test]
    fn failed_enable_retries_creating() {
        let (state, effects) = BridgeState::Failed {
            reason: "previous error".to_string(),
        }
        .handle(BridgeEvent::Enable);
        assert_eq!(state, BridgeState::Creating);
        assert_eq!(effects, vec![BridgeEffect::CreateBridge]);
    }
}
