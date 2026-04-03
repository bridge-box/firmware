use futures_util::{SinkExt, StreamExt};
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message;

use crate::protocol::{AgentMessage, BackendMessage};

pub type WsTx = mpsc::Sender<AgentMessage>;
pub type WsRx = mpsc::Receiver<BackendMessage>;

/// Подключается к WebSocket-серверу и возвращает каналы для обмена сообщениями.
/// При разрыве соединения задача завершается — вызывающий код обнаружит это
/// по закрытому каналу.
pub async fn connect(url: &str) -> Result<(WsTx, WsRx, tokio::task::JoinHandle<()>), String> {
    let (ws_stream, _response) = tokio_tungstenite::connect_async(url)
        .await
        .map_err(|e| format!("WS connect failed: {e}"))?;

    let (mut ws_sink, mut ws_source) = ws_stream.split();

    // agent → WS
    let (outgoing_tx, mut outgoing_rx) = mpsc::channel::<AgentMessage>(32);
    // WS → agent
    let (incoming_tx, incoming_rx) = mpsc::channel::<BackendMessage>(32);

    let handle = tokio::spawn(async move {
        loop {
            tokio::select! {
                // Отправка сообщений от агента в WS
                msg = outgoing_rx.recv() => {
                    let Some(msg) = msg else {
                        // Канал закрыт — агент завершился
                        let _ = ws_sink.close().await;
                        break;
                    };
                    let json = match serde_json::to_string(&msg) {
                        Ok(j) => j,
                        Err(e) => {
                            tracing::error!("WS serialize error: {e}");
                            continue;
                        }
                    };
                    if let Err(e) = ws_sink.send(Message::text(json)).await {
                        tracing::error!("WS send error: {e}");
                        break;
                    }
                }
                // Приём сообщений из WS
                frame = ws_source.next() => {
                    let Some(frame) = frame else {
                        // Стрим закрыт
                        break;
                    };
                    match frame {
                        Ok(Message::Text(text)) => {
                            let text_str: &str = &text;
                            match serde_json::from_str::<BackendMessage>(text_str) {
                                Ok(msg) => {
                                    if incoming_tx.send(msg).await.is_err() {
                                        // Получатель закрыт
                                        break;
                                    }
                                }
                                Err(e) => {
                                    tracing::warn!("WS parse error: {e}, payload: {text}");
                                }
                            }
                        }
                        Ok(Message::Ping(data)) => {
                            if let Err(e) = ws_sink.send(Message::Pong(data)).await {
                                tracing::error!("WS pong error: {e}");
                                break;
                            }
                        }
                        Ok(Message::Close(_)) => {
                            tracing::info!("WS close frame received");
                            break;
                        }
                        Ok(_) => {
                            // Binary, Pong, Frame — игнорируем
                        }
                        Err(e) => {
                            tracing::error!("WS read error: {e}");
                            break;
                        }
                    }
                }
            }
        }
        tracing::info!("WS bridge task завершена");
    });

    Ok((outgoing_tx, incoming_rx, handle))
}
