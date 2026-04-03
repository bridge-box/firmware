mod config;
mod state;
mod protocol;
mod telemetry;
mod ws;
mod executor;
mod agent;

// Старые модули — будут удалены после полной миграции
mod api;
mod device;
mod events;
mod models;
mod overlay;

use std::process::ExitCode;

#[tokio::main(flavor = "current_thread")]
async fn main() -> ExitCode {
    tracing_subscriber::fmt()
        .with_target(false)
        .with_env_filter(
            tracing_subscriber::EnvFilter::from_default_env()
                .add_directive(tracing::Level::INFO.into()),
        )
        .init();

    let config = match config::AgentConfig::load() {
        Ok(c) => c,
        Err(e) => {
            tracing::error!("Конфигурация: {e}");
            return ExitCode::FAILURE;
        }
    };

    tracing::info!(box_id = %config.box_id, "bb-agent v0.2.0 запущен");

    let agent = agent::Agent::new(config);
    agent.run().await;

    ExitCode::SUCCESS
}
