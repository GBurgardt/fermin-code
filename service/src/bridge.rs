use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result, bail};
use futures_util::{SinkExt, StreamExt};
use rand::Rng;
use serde_json::Value;
use tokio::sync::{Semaphore, broadcast, mpsc};
use tokio::task::JoinSet;
use tokio::time::{Instant, sleep};
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tracing::{info, warn};

use crate::PROTOCOL_VERSION;
use crate::config::{RelayClientConfig, read_secret};
use crate::protocol::{
    AuthoritativeSnapshot, CommandAcceptance, CommandReceipt, CommandRecord, DurableEvent,
    RelayEnvelope, RelayFrame, RelayQueryError, Sequence,
};

const EVENT_BATCH_LIMIT: usize = 64;
const INITIAL_ACK_TIMEOUT: Duration = Duration::from_secs(15);
const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(10);
const MAX_BRIDGE_MESSAGE_BYTES: usize = 64 * 1024 * 1024;
const BRIDGE_QUERY_CAPACITY: usize = 32;
const BRIDGE_QUERY_TIMEOUT: Duration = Duration::from_secs(15);
const STABLE_CONNECTION_BACKOFF_RESET_AFTER: Duration = Duration::from_secs(60);
const MAX_QUERY_ID_BYTES: usize = 128;
const MAX_QUERY_METHOD_BYTES: usize = 128;
const MAX_QUERY_PARAMS_BYTES: usize = 2 * 1024 * 1024;
const MAX_QUERY_RESULT_BYTES: usize = 63 * 1024 * 1024;

pub type BridgeFuture<'a, T> = Pin<Box<dyn Future<Output = Result<T>> + Send + 'a>>;

pub trait BridgeSource: Send + Sync + 'static {
    fn engine_id(&self) -> &str;
    fn app_server_version(&self) -> &str;
    fn capability_hash(&self) -> &str;
    fn process_epoch(&self) -> Sequence;
    fn snapshot(&self) -> BridgeFuture<'_, AuthoritativeSnapshot>;
    fn replay_events(
        &self,
        after_global_sequence: Sequence,
        limit: usize,
    ) -> BridgeFuture<'_, Vec<DurableEvent>>;
    fn submit_remote(&self, command: CommandRecord) -> BridgeFuture<'_, CommandAcceptance>;
    fn subscribe_events(&self) -> broadcast::Receiver<DurableEvent>;
    fn load_relay_cursor(&self) -> BridgeFuture<'_, Sequence>;
    fn commit_relay_cursor(&self, global_sequence: Sequence) -> BridgeFuture<'_, ()>;
    fn handle_query(&self, method: &str, _params: Value) -> BridgeFuture<'_, Value> {
        let method = method.to_owned();
        Box::pin(async move { bail!("unsupported read-only relay query method: {method}") })
    }
}

struct BridgeConnectionExit {
    connected_for: Duration,
    result: Result<()>,
}

pub async fn run_outbound_bridge<S: BridgeSource>(
    source: Arc<S>,
    config: RelayClientConfig,
    cancellation: tokio_util::sync::CancellationToken,
) -> Result<()> {
    let token = read_secret(&config.token_file)?;
    let initial_backoff = Duration::from_millis(config.reconnect_min_ms.max(50));
    let mut backoff = initial_backoff;
    let maximum_backoff = Duration::from_millis(
        config
            .reconnect_max_ms
            .max(config.reconnect_min_ms)
            .max(250),
    );

    loop {
        if cancellation.is_cancelled() {
            return Ok(());
        }
        let mut reset_backoff = false;
        match connect_once(source.clone(), &config.url, &token, cancellation.clone()).await {
            Ok(_) if cancellation.is_cancelled() => return Ok(()),
            Ok(exit) => {
                reset_backoff = exit.connected_for >= STABLE_CONNECTION_BACKOFF_RESET_AFTER;
                match exit.result {
                    Ok(()) => warn!(
                        connected_seconds = exit.connected_for.as_secs(),
                        "Fermín relay bridge disconnected cleanly; reconnecting"
                    ),
                    Err(error) => warn!(
                        %error,
                        connected_seconds = exit.connected_for.as_secs(),
                        "Fermín relay bridge failed; reconnecting"
                    ),
                }
            }
            Err(error) => {
                warn!(%error, "Fermín relay bridge failed before readiness; reconnecting")
            }
        }

        let (delay_cap, next_backoff) =
            reconnect_backoff_step(backoff, initial_backoff, maximum_backoff, reset_backoff);
        if reset_backoff {
            info!(
                delay_cap_ms = delay_cap.as_millis(),
                "stable relay connection reset reconnect backoff"
            );
        }

        let jitter_upper = delay_cap.as_millis().min(u64::MAX as u128) as u64;
        let delay = Duration::from_millis(rand::rng().random_range(0..=jitter_upper));
        tokio::select! {
            _ = cancellation.cancelled() => return Ok(()),
            _ = sleep(delay) => {}
        }
        backoff = next_backoff;
    }
}

fn reconnect_backoff_step(
    current: Duration,
    initial: Duration,
    maximum: Duration,
    reset_after_stable_connection: bool,
) -> (Duration, Duration) {
    let delay_cap = if reset_after_stable_connection {
        initial
    } else {
        current
    };
    (delay_cap, (delay_cap * 2).min(maximum))
}

async fn connect_once<S: BridgeSource>(
    source: Arc<S>,
    base_url: &str,
    token: &str,
    cancellation: tokio_util::sync::CancellationToken,
) -> Result<BridgeConnectionExit> {
    let mut url = url::Url::parse(base_url).context("parse relay WebSocket URL")?;
    url.query_pairs_mut()
        .append_pair("engineId", source.engine_id());
    let mut request = url.as_str().into_client_request()?;
    request.headers_mut().insert(
        axum::http::header::AUTHORIZATION,
        format!("Bearer {token}").parse()?,
    );
    let (socket, _) = connect_async(request)
        .await
        .context("connect relay WebSocket")?;
    let (mut writer, mut reader) = socket.split();
    let connection_epoch = uuid_epoch();
    let mut next_sequence = 1_u64;
    let mut last_relay_sequence: u64;

    let hello = RelayEnvelope {
        protocol_version: PROTOCOL_VERSION,
        engine_id: source.engine_id().to_owned(),
        connection_epoch,
        sequence: next_sequence,
        acknowledgement: 0,
        resume_cursor: Some(source.load_relay_cursor().await?),
        fence_generation: 0,
        frame: RelayFrame::Hello {
            app_server_version: source.app_server_version().to_owned(),
            capability_hash: source.capability_hash().to_owned(),
            process_epoch: source.process_epoch(),
        },
    };
    next_sequence += 1;
    send_envelope(&mut writer, &hello).await?;

    let first = tokio::time::timeout(INITIAL_ACK_TIMEOUT, reader.next())
        .await
        .context("relay initial ACK timeout")?
        .context("relay closed before initial ACK")??;
    let first = decode_text(first)?;
    let initial: RelayEnvelope =
        serde_json::from_str(&first).context("decode relay initial ACK")?;
    if initial.protocol_version != PROTOCOL_VERSION
        || initial.engine_id != source.engine_id()
        || initial.connection_epoch != connection_epoch
        || !matches!(initial.frame, RelayFrame::Ack)
        || initial.fence_generation == 0
    {
        bail!("invalid relay initial ACK");
    }
    let fence_generation = initial.fence_generation;
    last_relay_sequence = initial.sequence;
    let mut source_cursor = initial
        .resume_cursor
        .unwrap_or(source.load_relay_cursor().await?);
    source.commit_relay_cursor(source_cursor).await?;
    let mut wake = source.subscribe_events();

    let snapshot = source.snapshot().await?;
    let snapshot_envelope = RelayEnvelope {
        protocol_version: PROTOCOL_VERSION,
        engine_id: source.engine_id().to_owned(),
        connection_epoch,
        sequence: next_sequence,
        acknowledgement: last_relay_sequence,
        resume_cursor: Some(source_cursor),
        fence_generation,
        frame: RelayFrame::Snapshot { snapshot },
    };
    next_sequence += 1;
    send_envelope(&mut writer, &snapshot_envelope).await?;
    flush_replay(
        source.as_ref(),
        &mut writer,
        connection_epoch,
        fence_generation,
        &mut next_sequence,
        last_relay_sequence,
        &mut source_cursor,
    )
    .await?;

    info!(
        engine_id = source.engine_id(),
        connection_epoch, fence_generation, source_cursor, "Fermín relay bridge connected"
    );
    let connected_at = Instant::now();

    let mut heartbeat = tokio::time::interval(HEARTBEAT_INTERVAL);
    let mut last_send = Instant::now();
    let query_cancellation = tokio_util::sync::CancellationToken::new();
    let query_permits = Arc::new(Semaphore::new(BRIDGE_QUERY_CAPACITY));
    let (query_response_tx, mut query_response_rx) = mpsc::channel(BRIDGE_QUERY_CAPACITY);
    let mut query_tasks = JoinSet::new();
    let connection_result: Result<()> = async {
        loop {
            tokio::select! {
            _ = cancellation.cancelled() => {
                let _ = writer.send(Message::Close(None)).await;
                return Ok(());
            }
            wake_result = wake.recv() => {
                match wake_result {
                    Ok(_) | Err(broadcast::error::RecvError::Lagged(_)) => {
                        flush_replay(
                            source.as_ref(),
                            &mut writer,
                            connection_epoch,
                            fence_generation,
                            &mut next_sequence,
                            last_relay_sequence,
                            &mut source_cursor,
                        ).await?;
                        last_send = Instant::now();
                    }
                    Err(broadcast::error::RecvError::Closed) => return Ok(()),
                }
            }
            incoming = reader.next() => {
                let Some(incoming) = incoming else { return Ok(()); };
                let incoming = incoming?;
                match incoming {
                    Message::Text(text) => {
                        let envelope: RelayEnvelope = serde_json::from_str(text.as_str())?;
                        validate_relay_envelope(
                            &envelope,
                            source.engine_id(),
                            connection_epoch,
                            fence_generation,
                            last_relay_sequence,
                        )?;
                        if envelope.sequence > last_relay_sequence {
                            last_relay_sequence = envelope.sequence;
                        }
                        if let Some(cursor) = envelope.resume_cursor
                            && cursor >= source_cursor
                        {
                            source_cursor = cursor;
                            source.commit_relay_cursor(cursor).await?;
                        }
                        match envelope.frame {
                            RelayFrame::Commands { commands } => {
                                let mut receipts = Vec::with_capacity(commands.len());
                                for command in commands {
                                    let relay_command_id = command.command_id.clone();
                                    let idempotency_key = command.idempotency_key.clone();
                                    let acceptance = source.submit_remote(command).await?;
                                    if acceptance.command.idempotency_key != idempotency_key {
                                        bail!(
                                            "engine command acceptance changed the idempotency key"
                                        );
                                    }
                                    receipts.push(CommandReceipt {
                                        relay_command_id,
                                        engine_command_id: acceptance.command.command_id,
                                        idempotency_key,
                                        inserted: acceptance.inserted,
                                        state: acceptance.command.state,
                                        updated_at: acceptance.command.updated_at,
                                        error: acceptance.command.error,
                                    });
                                }
                                let receipt_envelope = RelayEnvelope {
                                    protocol_version: PROTOCOL_VERSION,
                                    engine_id: source.engine_id().to_owned(),
                                    connection_epoch,
                                    sequence: next_sequence,
                                    acknowledgement: last_relay_sequence,
                                    resume_cursor: Some(source_cursor),
                                    fence_generation,
                                    frame: RelayFrame::CommandReceipts { receipts },
                                };
                                next_sequence += 1;
                                send_envelope(&mut writer, &receipt_envelope).await?;
                                last_send = Instant::now();
                            }
                            RelayFrame::Ping { sent_at } => {
                                let pong = RelayEnvelope {
                                    protocol_version: PROTOCOL_VERSION,
                                    engine_id: source.engine_id().to_owned(),
                                    connection_epoch,
                                    sequence: next_sequence,
                                    acknowledgement: last_relay_sequence,
                                    resume_cursor: Some(source_cursor),
                                    fence_generation,
                                    frame: RelayFrame::Pong { sent_at },
                                };
                                next_sequence += 1;
                                send_envelope(&mut writer, &pong).await?;
                                last_send = Instant::now();
                            }
                            RelayFrame::QueryRequest { request_id, method, params } => {
                                let immediate_error = validate_query_request(&request_id, &method, &params).err();
                                let permit = query_permits.clone().try_acquire_owned().ok();
                                if let Some(error) = immediate_error.or_else(|| {
                                    permit.is_none().then(|| RelayQueryError {
                                        code: "busy".to_owned(),
                                        message: "engine query capacity is exhausted".to_owned(),
                                    })
                                }) {
                                    query_response_tx
                                        .try_send((request_id, Err(error)))
                                        .context("queue rejected query response")?;
                                    continue;
                                }
                                let permit = permit.expect("query permit checked above");
                                let source = source.clone();
                                let query_response_tx = query_response_tx.clone();
                                let query_cancellation = query_cancellation.clone();
                                query_tasks.spawn(async move {
                                    let _permit = permit;
                                    let response = tokio::select! {
                                        _ = query_cancellation.cancelled() => return,
                                        outcome = tokio::time::timeout(
                                            BRIDGE_QUERY_TIMEOUT,
                                            source.handle_query(&method, params),
                                        ) => match outcome {
                                            Ok(Ok(result)) => validate_query_result(result),
                                            Ok(Err(error)) => {
                                                warn!(%method, %error, "read-only relay query failed");
                                                Err(RelayQueryError {
                                                    code: "query_failed".to_owned(),
                                                    message: "engine query failed".to_owned(),
                                                })
                                            }
                                            Err(_) => Err(RelayQueryError {
                                                code: "timeout".to_owned(),
                                                message: "engine query timed out".to_owned(),
                                            }),
                                        }
                                    };
                                    let _ = query_response_tx.send((request_id, response)).await;
                                });
                            }
                            RelayFrame::Ack | RelayFrame::Pong { .. } => {}
                            RelayFrame::Error { code, message, retryable } => {
                                if !retryable { bail!("relay rejected bridge: {code}: {message}"); }
                                warn!(%code, %message, "retryable relay error");
                            }
                            RelayFrame::Hello { .. }
                            | RelayFrame::Events { .. }
                            | RelayFrame::Snapshot { .. }
                            | RelayFrame::CommandReceipts { .. }
                            | RelayFrame::QueryResponse { .. } => {
                                bail!("relay sent an engine-only frame");
                            }
                        }
                    }
                    Message::Ping(payload) => writer.send(Message::Pong(payload)).await?,
                    Message::Close(_) => return Ok(()),
                    Message::Binary(_) | Message::Pong(_) | Message::Frame(_) => {}
                }
            }
            response = query_response_rx.recv() => {
                let Some((request_id, response)) = response else { return Ok(()); };
                let (result, error) = match response {
                    Ok(result) => (Some(result), None),
                    Err(error) => (None, Some(error)),
                };
                let envelope = RelayEnvelope {
                    protocol_version: PROTOCOL_VERSION,
                    engine_id: source.engine_id().to_owned(),
                    connection_epoch,
                    sequence: next_sequence,
                    acknowledgement: last_relay_sequence,
                    resume_cursor: Some(source_cursor),
                    fence_generation,
                    frame: RelayFrame::QueryResponse {
                        request_id,
                        result,
                        error,
                    },
                };
                next_sequence += 1;
                send_envelope(&mut writer, &envelope).await?;
                last_send = Instant::now();
            }
            completed = query_tasks.join_next(), if !query_tasks.is_empty() => {
                if let Some(Err(error)) = completed {
                    warn!(%error, "read-only relay query task failed");
                }
            }
            _ = heartbeat.tick() => {
                let previous_source_cursor = source_cursor;
                flush_replay(
                    source.as_ref(),
                    &mut writer,
                    connection_epoch,
                    fence_generation,
                    &mut next_sequence,
                    last_relay_sequence,
                    &mut source_cursor,
                ).await?;
                if source_cursor > previous_source_cursor {
                    last_send = Instant::now();
                }
                if last_send.elapsed() >= HEARTBEAT_INTERVAL {
                    let ping = RelayEnvelope {
                        protocol_version: PROTOCOL_VERSION,
                        engine_id: source.engine_id().to_owned(),
                        connection_epoch,
                        sequence: next_sequence,
                        acknowledgement: last_relay_sequence,
                        resume_cursor: Some(source_cursor),
                        fence_generation,
                        frame: RelayFrame::Ping { sent_at: now_ms() },
                    };
                    next_sequence += 1;
                    send_envelope(&mut writer, &ping).await?;
                    last_send = Instant::now();
                }
            }
            }
        }
    }
    .await;
    query_cancellation.cancel();
    query_tasks.abort_all();
    while query_tasks.join_next().await.is_some() {}
    Ok(BridgeConnectionExit {
        connected_for: connected_at.elapsed(),
        result: connection_result,
    })
}

fn validate_query_request(
    request_id: &str,
    method: &str,
    params: &Value,
) -> std::result::Result<(), RelayQueryError> {
    let valid_method = !method.is_empty()
        && method.len() <= MAX_QUERY_METHOD_BYTES
        && method
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'));
    let valid_request_id = !request_id.is_empty() && request_id.len() <= MAX_QUERY_ID_BYTES;
    let params_size = serde_json::to_vec(params)
        .map(|encoded| encoded.len())
        .unwrap_or(usize::MAX);
    if !valid_request_id || !valid_method || params_size > MAX_QUERY_PARAMS_BYTES {
        return Err(RelayQueryError {
            code: "invalid_request".to_owned(),
            message: "invalid read-only engine query".to_owned(),
        });
    }
    Ok(())
}

fn validate_query_result(result: Value) -> std::result::Result<Value, RelayQueryError> {
    let result_size = serde_json::to_vec(&result)
        .map(|encoded| encoded.len())
        .unwrap_or(usize::MAX);
    if result_size > MAX_QUERY_RESULT_BYTES {
        return Err(RelayQueryError {
            code: "response_too_large".to_owned(),
            message: "engine query response exceeds the transport limit".to_owned(),
        });
    }
    Ok(result)
}

async fn flush_replay<S, W>(
    source: &S,
    writer: &mut W,
    connection_epoch: Sequence,
    fence_generation: Sequence,
    next_sequence: &mut Sequence,
    acknowledgement: Sequence,
    source_cursor: &mut Sequence,
) -> Result<()>
where
    S: BridgeSource,
    W: futures_util::Sink<Message, Error = tokio_tungstenite::tungstenite::Error> + Unpin,
{
    loop {
        let events = source
            .replay_events(*source_cursor, EVENT_BATCH_LIMIT)
            .await?;
        if events.is_empty() {
            return Ok(());
        }
        let final_cursor = events
            .last()
            .map(|event| event.global_sequence)
            .unwrap_or(*source_cursor);
        let envelope = RelayEnvelope {
            protocol_version: PROTOCOL_VERSION,
            engine_id: source.engine_id().to_owned(),
            connection_epoch,
            sequence: *next_sequence,
            acknowledgement,
            resume_cursor: Some(*source_cursor),
            fence_generation,
            frame: RelayFrame::Events { events },
        };
        *next_sequence += 1;
        send_envelope(writer, &envelope).await?;
        *source_cursor = final_cursor;
    }
}

async fn send_envelope<W>(writer: &mut W, envelope: &RelayEnvelope) -> Result<()>
where
    W: futures_util::Sink<Message, Error = tokio_tungstenite::tungstenite::Error> + Unpin,
{
    let encoded = serde_json::to_string(envelope)?;
    if encoded.len() > MAX_BRIDGE_MESSAGE_BYTES {
        bail!("relay frame exceeds {MAX_BRIDGE_MESSAGE_BYTES} bytes");
    }
    writer.send(Message::Text(encoded.into())).await?;
    Ok(())
}

fn validate_relay_envelope(
    envelope: &RelayEnvelope,
    engine_id: &str,
    connection_epoch: Sequence,
    fence_generation: Sequence,
    previous_sequence: Sequence,
) -> Result<()> {
    if envelope.protocol_version != PROTOCOL_VERSION
        || envelope.engine_id != engine_id
        || envelope.connection_epoch != connection_epoch
        || envelope.fence_generation != fence_generation
    {
        bail!("relay envelope identity/fence mismatch");
    }
    if envelope.sequence <= previous_sequence {
        return Ok(());
    }
    if previous_sequence != 0 && envelope.sequence != previous_sequence + 1 {
        bail!("relay sequence gap");
    }
    Ok(())
}

fn decode_text(message: Message) -> Result<String> {
    match message {
        Message::Text(text) => Ok(text.to_string()),
        _ => bail!("relay initial response was not text"),
    }
}

fn uuid_epoch() -> u64 {
    let bytes = *uuid::Uuid::new_v4().as_bytes();
    u64::from_be_bytes(bytes[..8].try_into().expect("UUID prefix"))
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(i64::MAX as u128) as i64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_fence_and_sequence() {
        let envelope = RelayEnvelope {
            protocol_version: PROTOCOL_VERSION,
            engine_id: "mac".to_owned(),
            connection_epoch: 7,
            sequence: 4,
            acknowledgement: 3,
            resume_cursor: Some(10),
            fence_generation: 2,
            frame: RelayFrame::Ack,
        };
        assert!(validate_relay_envelope(&envelope, "mac", 7, 2, 3).is_ok());
        assert!(validate_relay_envelope(&envelope, "mac", 7, 1, 3).is_err());
        assert!(validate_relay_envelope(&envelope, "mac", 7, 2, 2).is_err());
    }

    #[test]
    fn stable_connection_resets_reconnect_delay_to_the_fast_lane() {
        let (delay_cap, next) = reconnect_backoff_step(
            Duration::from_secs(30),
            Duration::from_millis(250),
            Duration::from_secs(30),
            true,
        );
        assert_eq!(delay_cap, Duration::from_millis(250));
        assert_eq!(next, Duration::from_millis(500));
    }

    #[test]
    fn flapping_connection_keeps_exponential_backoff_capped() {
        let (delay_cap, next) = reconnect_backoff_step(
            Duration::from_secs(20),
            Duration::from_millis(250),
            Duration::from_secs(30),
            false,
        );
        assert_eq!(delay_cap, Duration::from_secs(20));
        assert_eq!(next, Duration::from_secs(30));
    }
}
