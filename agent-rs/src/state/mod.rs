pub mod wifi;
pub mod bridge;
pub mod mesh;
pub mod overlay;
pub mod connection;

/// Каждая state machine — чистая функция: (state, event) → (state, effects).
/// Никаких side effects внутри handle(). Всё через Effects.
pub trait StateMachine: Sized {
    type Event;
    type Effect;

    fn handle(self, event: Self::Event) -> (Self, Vec<Self::Effect>);
}
