use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use anyhow::{Context, Result};
use axum::extract::ws::{Message as WebSocketMessage, WebSocket, WebSocketUpgrade};
use axum::extract::{Path as AxumPath, Query, State};
use axum::http::header::{CACHE_CONTROL, CONTENT_LENGTH, CONTENT_TYPE};
use axum::http::{HeaderMap, HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::{Json, Router};
use bytes::Bytes;
use futures_util::{SinkExt, StreamExt};
use serde::Deserialize;
use serde_json::{Value, json};
use subtle::ConstantTimeEq;
use tokio::sync::{Mutex, broadcast, mpsc, oneshot};
use tokio::time::{Instant, interval, timeout};
use tracing::{info, warn};
use uuid::Uuid;

use crate::api::{
    AttachmentContent, AttachmentUpload, BackendEventStream, BackendFuture, BackendHealth,
    FilePreview, MobileApiConfig, MobileBackend, MobileBackendError, ProjectCatalog,
    PromptImproverPreferenceRecord, PromptImproverVariant, ReplayCursor, SessionHistoryItem,
    SessionHistoryPage, SessionHistoryQuery, SessionHistoryResumeResult, SessionHistorySort,
    SessionHistoryState, SessionRecoveryItem, SessionRecoveryPage, SessionRecoveryQuery,
    SessionRecoveryResult,
};
use crate::config::{RelayConfig, read_secret};
use crate::protocol::{
    AuthoritativeSnapshot, CommandAcceptance, CommandKind, CommandReceipt, CommandRecord,
    CommandRequest, CommandState, CommandTransition, DurableEvent, EventCursor, EventKind,
    FencingToken, ImageAttachment, LeaseRequest, MessageMutation, MessagePatch, ModelCatalog,
    NewEvent, RelayEnvelope, RelayFrame, RelayQueryError, SessionSummary,
};
use crate::store::Store;

const ENGINE_WRITER_CAPACITY: usize = 128;
const EVENT_WAKE_CAPACITY: usize = 2048;
const MAX_ENGINE_FRAME_BYTES: usize = 64 * 1024 * 1024;
const INITIAL_FRAME_TIMEOUT: Duration = Duration::from_secs(10);
const COMMAND_BATCH_LIMIT: usize = 128;
const COMMAND_SCAN_LIMIT: usize = 10_000;
const RELAY_QUERY_CAPACITY: usize = 128;
const RELAY_QUERY_TIMEOUT: Duration = Duration::from_secs(20);
const MAX_QUERY_METHOD_BYTES: usize = 128;
const MAX_QUERY_PARAMS_BYTES: usize = 2 * 1024 * 1024;
const RELAY_ATTACHMENT_PREFIX: &str = "relay://";
const ENGINE_AUTHORITY_WATERMARK_SCOPE: &str = "engine-authority-watermark-v1";
const SESSION_OWNERSHIP_CUTOVER_SCOPE: &str = "session-ownership-cutover-v2";

#[derive(Clone)]
pub struct RelayState {
    config: RelayConfig,
    store: Store,
    mobile_token: Arc<str>,
    engine_token: Arc<str>,
    active_engine: Arc<Mutex<Option<ActiveEngine>>>,
    pending_queries: Arc<Mutex<BTreeMap<String, PendingEngineQuery>>>,
    event_wake: broadcast::Sender<DurableEvent>,
    prompt_preference: Arc<Mutex<PromptImproverPreferenceRecord>>,
    prompt_preference_path: Arc<std::path::PathBuf>,
    started_at: Instant,
}

#[derive(Clone)]
struct ActiveEngine {
    engine_id: String,
    connection_id: String,
    connection_epoch: u64,
    fence: FencingToken,
    outbound: mpsc::Sender<RelayEnvelope>,
    next_sequence: Arc<AtomicU64>,
    last_engine_sequence: Arc<AtomicU64>,
    last_source_cursor: Arc<AtomicU64>,
    last_heartbeat_ms: Arc<AtomicU64>,
    pending_command_acks: Arc<Mutex<BTreeMap<u64, Vec<String>>>>,
    cancellation: tokio_util::sync::CancellationToken,
}

struct PendingEngineQuery {
    connection_id: String,
    response: oneshot::Sender<std::result::Result<Value, RelayQueryError>>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct EngineQuery {
    engine_id: Option<String>,
}

pub async fn run(config: RelayConfig) -> Result<()> {
    let state = Arc::new(RelayState::open(config.clone()).await?);
    let mobile_config = MobileApiConfig::new(state.mobile_token.as_ref())?
        .with_max_body_bytes(config.max_body_bytes)?
        .with_heartbeat_interval(Duration::from_secs(config.heartbeat_seconds.clamp(2, 20)))?;
    let mobile_backend: Arc<dyn MobileBackend> = state.clone();
    let app = crate::api::router(mobile_backend, mobile_config).merge(relay_router(state));
    let listener = tokio::net::TcpListener::bind(config.bind)
        .await
        .with_context(|| format!("bind Fermín relay {}", config.bind))?;
    info!(bind = %config.bind, "Fermín relay listening");
    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await
        .context("serve Fermín relay")
}

impl RelayState {
    pub async fn open(config: RelayConfig) -> Result<Self> {
        let mobile_token = Arc::<str>::from(read_secret(&config.auth_token_file)?);
        let engine_token = Arc::<str>::from(read_secret(&config.engine_token_file)?);
        let store = Store::open(&config.database_path)
            .await
            .context("open relay store")?;
        let prompt_preference_path = config.database_path.with_extension("prompt-improver.json");
        let prompt_preference = read_prompt_preference(&prompt_preference_path).await;
        let (event_wake, _) = broadcast::channel(EVENT_WAKE_CAPACITY);
        Ok(Self {
            config,
            store,
            mobile_token,
            engine_token,
            active_engine: Arc::new(Mutex::new(None)),
            pending_queries: Arc::new(Mutex::new(BTreeMap::new())),
            event_wake,
            prompt_preference: Arc::new(Mutex::new(prompt_preference)),
            prompt_preference_path: Arc::new(prompt_preference_path),
            started_at: Instant::now(),
        })
    }

    pub fn store(&self) -> &Store {
        &self.store
    }

    pub fn subscribe_events(&self) -> broadcast::Receiver<DurableEvent> {
        self.event_wake.subscribe()
    }

    pub async fn accept_mobile_command(
        &self,
        request: CommandRequest,
    ) -> Result<CommandAcceptance> {
        let acceptance = self.store.accept_command(request).await?;
        if acceptance.inserted {
            self.dispatch_commands(vec![acceptance.command.clone()])
                .await;
        }
        Ok(acceptance)
    }

    pub async fn snapshot(&self) -> Result<AuthoritativeSnapshot> {
        self.snapshot_from_store(true).await
    }

    async fn mobile_snapshot(&self) -> Result<AuthoritativeSnapshot> {
        self.snapshot_from_store(false).await
    }

    async fn snapshot_from_store(&self, include_messages: bool) -> Result<AuthoritativeSnapshot> {
        let durable = self
            .store
            .state_snapshot(
                include_messages,
                Some(ENGINE_AUTHORITY_WATERMARK_SCOPE.to_owned()),
            )
            .await?;
        let authority_generated_at = durable
            .authority
            .as_ref()
            .map_or(0, |stored| stored.snapshot.generated_at);
        let engine_signal_at = {
            let active = self.active_engine.lock().await;
            active
                .as_ref()
                .and_then(|engine| self.fresh_engine_signal_at(engine, now_ms().max(0) as u64))
        };
        let generated_at = engine_signal_at.map_or(authority_generated_at, |observed_at| {
            authority_generated_at.max(observed_at)
        });
        let sessions = durable
            .sessions
            .into_iter()
            .filter(|stored| {
                stored.session.managed_by_fermin && !session_is_archived(&stored.session)
            })
            .map(|stored| stored.session)
            .collect();
        Ok(AuthoritativeSnapshot {
            schema_version: crate::protocol::MOBILE_SCHEMA_VERSION,
            global_sequence: durable.global_sequence,
            generated_at,
            sessions,
            models: durable
                .models
                .map(|catalog| catalog.models)
                .unwrap_or_default(),
        })
    }

    fn engine_freshness_window_ms(&self) -> u64 {
        self.config
            .engine_lease_seconds
            .saturating_mul(2)
            .max(self.config.heartbeat_seconds.saturating_mul(3))
            .saturating_mul(1_000)
    }

    fn fresh_engine_signal_at(&self, engine: &ActiveEngine, now: u64) -> Option<i64> {
        let observed_at = engine.last_heartbeat_ms.load(Ordering::Acquire);
        let age_ms = now.saturating_sub(observed_at);
        (age_ms <= self.engine_freshness_window_ms())
            .then_some(observed_at.min(i64::MAX as u64) as i64)
    }

    async fn record_engine_authority_watermark(
        &self,
        relay_global_sequence: Option<u64>,
        generated_at: i64,
        fence: FencingToken,
    ) -> Result<()> {
        let existing = self
            .store
            .get_snapshot(ENGINE_AUTHORITY_WATERMARK_SCOPE)
            .await?;
        let (global_sequence, generated_at) = if let Some(stored) = existing {
            let next = (
                relay_global_sequence
                    .unwrap_or(stored.snapshot.global_sequence)
                    .max(stored.snapshot.global_sequence),
                generated_at.max(stored.snapshot.generated_at),
            );
            if next
                == (
                    stored.snapshot.global_sequence,
                    stored.snapshot.generated_at,
                )
            {
                return Ok(());
            }
            next
        } else {
            (relay_global_sequence.unwrap_or(0), generated_at)
        };
        self.store
            .put_snapshot(
                ENGINE_AUTHORITY_WATERMARK_SCOPE,
                AuthoritativeSnapshot {
                    schema_version: crate::protocol::MOBILE_SCHEMA_VERSION,
                    global_sequence,
                    generated_at,
                    sessions: Vec::new(),
                    models: Vec::new(),
                },
                Some(fence.clone()),
            )
            .await?;
        Ok(())
    }

    pub async fn active_engine_health(&self) -> Value {
        let active = self.active_engine.lock().await.clone();
        match active {
            Some(engine) => json!({
                "connected": true,
                "engineId": engine.engine_id,
                "connectionEpoch": engine.connection_epoch,
                "fenceGeneration": engine.fence.generation,
                "lastEngineSequence": engine.last_engine_sequence.load(Ordering::Acquire),
                "lastSourceCursor": engine.last_source_cursor.load(Ordering::Acquire),
                "lastHeartbeatAt": engine.last_heartbeat_ms.load(Ordering::Acquire),
            }),
            None => json!({"connected": false}),
        }
    }

    pub async fn query_engine(&self, method: impl Into<String>, params: Value) -> Result<Value> {
        self.query_engine_with_fence(method, params)
            .await
            .map(|(result, _)| result)
    }

    async fn query_engine_with_fence(
        &self,
        method: impl Into<String>,
        params: Value,
    ) -> Result<(Value, FencingToken)> {
        let method = method.into();
        validate_outbound_query(&method, &params)?;
        let request_id = Uuid::new_v4().to_string();
        let (response, receive) = oneshot::channel();
        let active_guard = self.active_engine.lock().await;
        let active = active_guard
            .clone()
            .context("Fermín engine is not connected")?;
        let mut pending = self.pending_queries.lock().await;
        if pending.len() >= RELAY_QUERY_CAPACITY {
            anyhow::bail!("Fermín engine query capacity is exhausted");
        }
        pending.insert(
            request_id.clone(),
            PendingEngineQuery {
                connection_id: active.connection_id.clone(),
                response,
            },
        );
        drop(pending);
        drop(active_guard);

        let envelope = active.envelope(RelayFrame::QueryRequest {
            request_id: request_id.clone(),
            method,
            params,
        });
        if active.outbound.try_send(envelope).is_err() {
            self.pending_queries.lock().await.remove(&request_id);
            anyhow::bail!("Fermín engine outbound queue is full");
        }

        match timeout(RELAY_QUERY_TIMEOUT, receive).await {
            Ok(Ok(Ok(result))) => Ok((result, active.fence)),
            Ok(Ok(Err(error))) => {
                anyhow::bail!("engine query failed ({}): {}", error.code, error.message)
            }
            Ok(Err(_)) => anyhow::bail!("Fermín engine disconnected during query"),
            Err(_) => {
                self.pending_queries.lock().await.remove(&request_id);
                anyhow::bail!("Fermín engine query timed out")
            }
        }
    }

    async fn load_relay_attachment(
        &self,
        token: &str,
    ) -> std::result::Result<AttachmentContent, MobileBackendError> {
        let mime_type = relay_attachment_mime(token).ok_or_else(|| {
            MobileBackendError::Invalid("invalid relay attachment token".to_owned())
        })?;
        let path = relay_attachment_root(&self.config).join(token);
        let metadata = tokio::fs::symlink_metadata(&path)
            .await
            .map_err(|_| MobileBackendError::NotFound("attachment not found".to_owned()))?;
        if !metadata.file_type().is_file()
            || metadata.len() == 0
            || metadata.len() > crate::api::MAX_ATTACHMENT_BYTES as u64
        {
            return Err(MobileBackendError::NotFound(
                "attachment not found".to_owned(),
            ));
        }
        let bytes = tokio::fs::read(&path)
            .await
            .map_err(|_| MobileBackendError::NotFound("attachment not found".to_owned()))?;
        if bytes.len() as u64 != metadata.len()
            || !relay_attachment_bytes_match_mime(mime_type, &bytes)
        {
            return Err(MobileBackendError::NotFound(
                "attachment not found".to_owned(),
            ));
        }
        Ok(AttachmentContent {
            mime_type: mime_type.to_owned(),
            bytes: Bytes::from(bytes),
        })
    }

    async fn resolve_window_id(&self, window_id: &str) -> Result<Option<String>> {
        if let Some(stored) = self.store.get_session(window_id.to_owned()).await?
            && stored.session.managed_by_fermin
        {
            return Ok(Some(stored.session.session_id));
        }
        Ok(self
            .store
            .list_sessions()
            .await?
            .into_iter()
            .find(|stored| {
                stored.session.managed_by_fermin && stored.session.window_id == window_id
            })
            .map(|stored| stored.session.session_id))
    }

    async fn dispatch_commands(&self, commands: Vec<crate::protocol::CommandRecord>) {
        if commands.is_empty() {
            return;
        }
        let active = self.active_engine.lock().await.clone();
        let Some(active) = active else {
            return;
        };
        self.dispatch_commands_to_active(&active, commands).await;
    }

    async fn dispatch_commands_to_active(
        &self,
        active: &ActiveEngine,
        commands: Vec<crate::protocol::CommandRecord>,
    ) {
        let mut deliverable = Vec::with_capacity(commands.len());
        for command in commands {
            let command = if command.state == CommandState::Accepted {
                match self
                    .store
                    .transition_command(
                        CommandTransition {
                            command_id: command.command_id.clone(),
                            expected_state: Some(CommandState::Accepted),
                            new_state: CommandState::Leased,
                            updated_at: now_ms(),
                            error: None,
                            event: None,
                        },
                        Some(active.fence.clone()),
                    )
                    .await
                {
                    Ok(mutation) => mutation.command,
                    Err(error) => {
                        warn!(command_id = %command.command_id, %error, "failed to lease relay command");
                        continue;
                    }
                }
            } else {
                command
            };
            deliverable.push(command);
        }
        if deliverable.is_empty() {
            return;
        }
        let envelope = active.envelope(RelayFrame::Commands {
            commands: deliverable.clone(),
        });
        let sequence = envelope.sequence;
        let command_ids = deliverable
            .iter()
            .map(|command| command.command_id.clone())
            .collect();
        let mut pending = active.pending_command_acks.lock().await;
        pending.insert(sequence, command_ids);
        if active.outbound.try_send(envelope).is_err() {
            pending.remove(&sequence);
            warn!(engine_id = %active.engine_id, "engine outbound queue is full; command remains durable");
        }
    }

    async fn dispatch_next_command_batch(&self, active: &ActiveEngine) -> Result<()> {
        let in_flight = active
            .pending_command_acks
            .lock()
            .await
            .values()
            .flatten()
            .cloned()
            .collect::<BTreeSet<_>>();
        let commands = self
            .store
            .pending_commands(COMMAND_SCAN_LIMIT)
            .await?
            .into_iter()
            .filter(|command| {
                matches!(command.state, CommandState::Accepted | CommandState::Leased)
                    && !in_flight.contains(&command.command_id)
            })
            .take(COMMAND_BATCH_LIMIT)
            .collect();
        self.dispatch_commands_to_active(active, commands).await;
        Ok(())
    }

    async fn take_acknowledged_engine_commands(
        &self,
        active: &ActiveEngine,
        acknowledgement: u64,
    ) -> Vec<String> {
        let mut pending = active.pending_command_acks.lock().await;
        let sequences = pending
            .range(..=acknowledgement)
            .map(|(sequence, _)| *sequence)
            .collect::<Vec<_>>();
        let mut command_ids = Vec::new();
        for sequence in sequences {
            if let Some(ids) = pending.remove(&sequence) {
                command_ids.extend(ids);
            }
        }
        command_ids
    }

    async fn apply_command_receipts(
        &self,
        active: &ActiveEngine,
        acknowledged: Vec<String>,
        receipts: Vec<CommandReceipt>,
    ) -> Result<()> {
        if acknowledged.is_empty() || receipts.len() > COMMAND_BATCH_LIMIT {
            anyhow::bail!("engine sent unsolicited or oversized command receipts");
        }
        let acknowledged_ids = acknowledged.into_iter().collect::<BTreeSet<_>>();
        let receipt_ids = receipts
            .iter()
            .map(|receipt| receipt.relay_command_id.clone())
            .collect::<BTreeSet<_>>();
        if receipt_ids.len() != receipts.len() || receipt_ids != acknowledged_ids {
            anyhow::bail!("engine command receipts do not match the acknowledged command batch");
        }
        for receipt in receipts {
            let mutation = self
                .store
                .record_command_receipt(receipt, now_ms(), Some(active.fence.clone()))
                .await?;
            if let Some(event) = mutation.event {
                let _ = self.event_wake.send(event);
            }
        }
        self.dispatch_next_command_batch(active).await?;
        Ok(())
    }

    async fn apply_engine_envelope(
        &self,
        active: &ActiveEngine,
        envelope: RelayEnvelope,
    ) -> Result<()> {
        if envelope.protocol_version != crate::PROTOCOL_VERSION {
            anyhow::bail!("unsupported protocol version {}", envelope.protocol_version);
        }
        if envelope.engine_id != active.engine_id
            || envelope.connection_epoch != active.connection_epoch
            || envelope.fence_generation != active.fence.generation
        {
            anyhow::bail!("stale or mismatched engine envelope");
        }

        let previous = active.last_engine_sequence.load(Ordering::Acquire);
        if envelope.sequence <= previous {
            return Ok(());
        }
        if previous != 0 && envelope.sequence != previous + 1 {
            anyhow::bail!(
                "engine sequence gap: expected {}, received {}",
                previous + 1,
                envelope.sequence
            );
        }
        active
            .last_engine_sequence
            .store(envelope.sequence, Ordering::Release);
        active
            .last_heartbeat_ms
            .store(now_ms().max(0) as u64, Ordering::Release);
        let acknowledged = self
            .take_acknowledged_engine_commands(active, envelope.acknowledgement)
            .await;

        match envelope.frame {
            RelayFrame::CommandReceipts { receipts } => {
                self.apply_command_receipts(active, acknowledged, receipts)
                    .await?;
            }
            RelayFrame::Events { events } => {
                if !acknowledged.is_empty() {
                    anyhow::bail!("engine acknowledged commands without command receipts");
                }
                let final_cursor = events
                    .last()
                    .map(|event| event.global_sequence)
                    .unwrap_or_else(|| active.last_source_cursor.load(Ordering::Acquire));
                for event in events {
                    self.apply_engine_event(event, active.fence.clone()).await?;
                }
                if final_cursor > active.last_source_cursor.load(Ordering::Acquire) {
                    self.store
                        .commit_cursor(crate::protocol::ConsumerCursor {
                            consumer_id: format!("source:{}", active.engine_id),
                            global_sequence: final_cursor,
                            updated_at: now_ms(),
                        })
                        .await?;
                    active
                        .last_source_cursor
                        .store(final_cursor, Ordering::Release);
                }
                let _ = active
                    .outbound
                    .try_send(active.envelope_with_cursor(RelayFrame::Ack, Some(final_cursor)));
            }
            RelayFrame::Snapshot { snapshot } => {
                if !acknowledged.is_empty() {
                    anyhow::bail!("engine acknowledged commands without command receipts");
                }
                self.apply_snapshot(snapshot, active.fence.clone()).await?;
            }
            RelayFrame::QueryResponse {
                request_id,
                result,
                error,
            } => {
                if !acknowledged.is_empty() {
                    anyhow::bail!("engine acknowledged commands without command receipts");
                }
                self.complete_engine_query(active, request_id, result, error)
                    .await;
            }
            RelayFrame::Ping { sent_at } => {
                if !acknowledged.is_empty() {
                    anyhow::bail!("engine acknowledged commands without command receipts");
                }
                let response = active.envelope(RelayFrame::Pong { sent_at });
                let _ = active.outbound.try_send(response);
            }
            RelayFrame::Pong { .. } | RelayFrame::Ack | RelayFrame::Hello { .. } => {
                if !acknowledged.is_empty() {
                    anyhow::bail!("engine acknowledged commands without command receipts");
                }
            }
            RelayFrame::Commands { .. } | RelayFrame::QueryRequest { .. } => {
                anyhow::bail!("engine sent a relay-only frame");
            }
            RelayFrame::Error {
                code,
                message,
                retryable,
            } => {
                if !acknowledged.is_empty() {
                    anyhow::bail!("engine acknowledged commands without command receipts");
                }
                warn!(%code, %message, retryable, "engine reported relay error");
            }
        }
        Ok(())
    }

    async fn complete_engine_query(
        &self,
        active: &ActiveEngine,
        request_id: String,
        result: Option<Value>,
        error: Option<RelayQueryError>,
    ) {
        let pending = {
            let mut pending = self.pending_queries.lock().await;
            if pending
                .get(&request_id)
                .is_some_and(|query| query.connection_id == active.connection_id)
            {
                pending.remove(&request_id)
            } else {
                None
            }
        };
        let Some(pending) = pending else {
            warn!(%request_id, engine_id = %active.engine_id, "ignored unknown engine query response");
            return;
        };
        let response = match (result, error) {
            (Some(result), None) => Ok(result),
            (None, Some(error)) => Err(error),
            _ => Err(RelayQueryError {
                code: "invalid_response".to_owned(),
                message: "engine returned an invalid query response".to_owned(),
            }),
        };
        let _ = pending.response.send(response);
    }

    async fn apply_engine_event(&self, source: DurableEvent, fence: FencingToken) -> Result<()> {
        let authority_generated_at = source.created_at;
        let imported_event = NewEvent {
            event_id: Some(format!("{}:{}", source.event_id, source.global_sequence)),
            session_id: source.session_id.clone(),
            command_id: source.command_id.clone(),
            process_epoch: source.process_epoch,
            kind: source.kind,
            payload: source.payload.clone(),
            created_at: source.created_at,
        };
        match source.kind {
            EventKind::CommandStateChanged => {
                let command_id = source.command_id.clone().or_else(|| {
                    source
                        .payload
                        .get("commandId")
                        .and_then(Value::as_str)
                        .map(str::to_owned)
                });
                let new_state = source
                    .payload
                    .get("state")
                    .cloned()
                    .and_then(|value| serde_json::from_value::<CommandState>(value).ok());
                if let (Some(command_id), Some(new_state)) = (command_id, new_state) {
                    let error = source
                        .payload
                        .get("error")
                        .and_then(Value::as_str)
                        .map(str::to_owned);
                    let aliased = self
                        .store
                        .materialize_engine_command_state(
                            command_id.clone(),
                            new_state,
                            source.created_at,
                            error.clone(),
                            imported_event.clone(),
                            Some(fence.clone()),
                        )
                        .await?;
                    if aliased.matched_aliases > 0 {
                        let relay_cursor = aliased
                            .mutations
                            .iter()
                            .filter_map(|mutation| {
                                mutation.event.as_ref().map(|event| event.global_sequence)
                            })
                            .max();
                        for mutation in aliased.mutations {
                            if let Some(event) = mutation.event {
                                let _ = self.event_wake.send(event);
                            }
                        }
                        self.record_engine_authority_watermark(
                            relay_cursor,
                            authority_generated_at,
                            fence,
                        )
                        .await?;
                        return Ok(());
                    }
                    if let Some(command) = self.store.get_command(command_id.clone()).await? {
                        let mutation = self
                            .store
                            .transition_command(
                                CommandTransition {
                                    command_id,
                                    expected_state: Some(command.state),
                                    new_state,
                                    updated_at: source.created_at,
                                    error,
                                    event: Some(imported_event),
                                },
                                Some(fence.clone()),
                            )
                            .await?;
                        let relay_cursor =
                            mutation.event.as_ref().map(|event| event.global_sequence);
                        if let Some(event) = mutation.event {
                            let _ = self.event_wake.send(event);
                        }
                        self.record_engine_authority_watermark(
                            relay_cursor,
                            authority_generated_at,
                            fence,
                        )
                        .await?;
                        return Ok(());
                    }
                }
            }
            EventKind::SessionUpserted | EventKind::RuntimeStatus => {
                if let Ok(session) =
                    serde_json::from_value::<SessionSummary>(source.payload.clone())
                {
                    if !session.managed_by_fermin {
                        self.store
                            .delete_session(session.session_id, Some(fence.clone()))
                            .await?;
                        self.record_engine_authority_watermark(None, authority_generated_at, fence)
                            .await?;
                        return Ok(());
                    }
                    let mutation = self
                        .store
                        .upsert_session_with_event(session, imported_event, Some(fence.clone()))
                        .await?;
                    let relay_cursor = mutation.event.as_ref().map(|event| event.global_sequence);
                    if let Some(event) = mutation.event {
                        let _ = self.event_wake.send(event);
                    }
                    self.record_engine_authority_watermark(
                        relay_cursor,
                        authority_generated_at,
                        fence,
                    )
                    .await?;
                    return Ok(());
                }
            }
            EventKind::SessionRemoved => {
                if let Some(session_id) = source.session_id.as_deref() {
                    let mutation = self
                        .store
                        .delete_session_with_event(
                            session_id.to_owned(),
                            imported_event,
                            Some(fence.clone()),
                        )
                        .await?;
                    let relay_cursor = mutation.event.as_ref().map(|event| event.global_sequence);
                    if let Some(event) = mutation.event {
                        let _ = self.event_wake.send(event);
                    }
                    self.record_engine_authority_watermark(
                        relay_cursor,
                        authority_generated_at,
                        fence,
                    )
                    .await?;
                    return Ok(());
                }
            }
            EventKind::MessagePatch => {
                if let Ok(patch) = serde_json::from_value::<MessagePatch>(source.payload.clone()) {
                    let managed = self
                        .store
                        .get_session(patch.window_id.clone())
                        .await?
                        .is_some_and(|stored| stored.session.managed_by_fermin);
                    if !managed {
                        self.record_engine_authority_watermark(None, authority_generated_at, fence)
                            .await?;
                        return Ok(());
                    }
                    let mutation = self
                        .store
                        .upsert_message_with_event(
                            MessageMutation {
                                session_id: patch.window_id,
                                message: patch.message,
                                revision: patch.revision,
                                updated_at: patch.updated_at,
                                final_: patch.final_,
                            },
                            imported_event,
                            Some(fence.clone()),
                        )
                        .await?;
                    let relay_cursor = mutation.event.as_ref().map(|event| event.global_sequence);
                    if let Some(event) = mutation.event {
                        let _ = self.event_wake.send(event);
                    }
                    self.record_engine_authority_watermark(
                        relay_cursor,
                        authority_generated_at,
                        fence,
                    )
                    .await?;
                    return Ok(());
                }
            }
            EventKind::ModelCatalogUpdated => {
                if let Ok(catalog) = serde_json::from_value::<ModelCatalog>(source.payload.clone())
                {
                    let mutation = self
                        .store
                        .replace_models_with_event(catalog, imported_event, Some(fence.clone()))
                        .await?;
                    let relay_cursor = mutation.event.as_ref().map(|event| event.global_sequence);
                    if let Some(event) = mutation.event {
                        let _ = self.event_wake.send(event);
                    }
                    self.record_engine_authority_watermark(
                        relay_cursor,
                        authority_generated_at,
                        fence,
                    )
                    .await?;
                    return Ok(());
                }
            }
            _ => {}
        }

        let event = self
            .store
            .append_event(imported_event, Some(fence.clone()))
            .await?;
        let relay_cursor = event.global_sequence;
        let _ = self.event_wake.send(event);
        self.record_engine_authority_watermark(Some(relay_cursor), authority_generated_at, fence)
            .await?;
        Ok(())
    }

    async fn apply_snapshot(
        &self,
        mut snapshot: AuthoritativeSnapshot,
        fence: FencingToken,
    ) -> Result<()> {
        snapshot
            .sessions
            .retain(|session| session.managed_by_fermin);
        let incoming_session_ids = snapshot
            .sessions
            .iter()
            .map(|session| session.session_id.clone())
            .collect::<BTreeSet<_>>();
        for stored in self.store.list_sessions().await? {
            if !incoming_session_ids.contains(&stored.session.session_id)
                && (!session_is_archived(&stored.session) || !stored.session.managed_by_fermin)
            {
                self.store
                    .delete_session(stored.session.session_id, Some(fence.clone()))
                    .await?;
            }
        }
        for session in &snapshot.sessions {
            let mut summary = session.clone();
            summary.messages.clear();
            self.store
                .upsert_session(summary, Some(fence.clone()))
                .await?;
            let existing_message_ids = self
                .store
                .list_messages(session.session_id.clone())
                .await?
                .into_iter()
                .map(|stored| stored.message.id)
                .collect::<BTreeSet<_>>();
            for message in &session.messages {
                if existing_message_ids.contains(&message.id) {
                    continue;
                }
                self.store
                    .upsert_message(
                        MessageMutation {
                            session_id: session.session_id.clone(),
                            message: message.clone(),
                            revision: 1,
                            updated_at: session.updated_at,
                            final_: true,
                        },
                        Some(fence.clone()),
                    )
                    .await?;
            }
        }
        self.store
            .replace_models(
                ModelCatalog {
                    observed_at: snapshot.generated_at,
                    app_server_version: None,
                    capability_hash: None,
                    models: snapshot.models.clone(),
                },
                Some(fence.clone()),
            )
            .await?;
        self.store
            .put_snapshot("engine", snapshot.clone(), Some(fence.clone()))
            .await?;
        let mobile_items = snapshot
            .sessions
            .iter()
            .cloned()
            .map(|mut session| {
                session.messages.clear();
                session
            })
            .collect::<Vec<_>>();
        let mobile_snapshot = json!({
            "ok": true,
            "now": snapshot.generated_at,
            "exportedAt": snapshot.generated_at,
            "items": mobile_items,
        });
        let event = self
            .store
            .append_event(
                NewEvent {
                    event_id: None,
                    session_id: None,
                    command_id: None,
                    process_epoch: None,
                    kind: EventKind::Snapshot,
                    payload: mobile_snapshot,
                    created_at: now_ms(),
                },
                Some(fence.clone()),
            )
            .await?;
        if self
            .store
            .get_snapshot(SESSION_OWNERSHIP_CUTOVER_SCOPE)
            .await?
            .is_none()
        {
            self.store
                .put_snapshot(
                    SESSION_OWNERSHIP_CUTOVER_SCOPE,
                    AuthoritativeSnapshot {
                        schema_version: crate::protocol::MOBILE_SCHEMA_VERSION,
                        global_sequence: event.global_sequence,
                        generated_at: snapshot.generated_at,
                        sessions: Vec::new(),
                        models: Vec::new(),
                    },
                    Some(fence.clone()),
                )
                .await?;
        }
        self.record_engine_authority_watermark(
            Some(event.global_sequence),
            snapshot.generated_at,
            fence,
        )
        .await?;
        let _ = self.event_wake.send(event);
        Ok(())
    }
}

impl MobileBackend for RelayState {
    fn health(&self) -> BackendFuture<'_, BackendHealth> {
        Box::pin(async move {
            let pending_commands = self
                .store
                .pending_commands(COMMAND_SCAN_LIMIT)
                .await
                .map_err(backend_internal)?;
            let engine = self.active_engine.lock().await.clone();
            let now = now_ms().max(0) as u64;
            let (ready, engine_details) = match engine {
                Some(engine) => {
                    let last_heartbeat_at = engine.last_heartbeat_ms.load(Ordering::Acquire);
                    let heartbeat_age_ms = now.saturating_sub(last_heartbeat_at);
                    let heartbeat_fresh = heartbeat_age_ms <= self.engine_freshness_window_ms();
                    (
                        heartbeat_fresh,
                        json!({
                            "connected": true,
                            "heartbeatFresh": heartbeat_fresh,
                            "heartbeatAgeMs": heartbeat_age_ms,
                            "engineId": engine.engine_id,
                            "connectionEpoch": engine.connection_epoch,
                            "fenceGeneration": engine.fence.generation,
                            "lastEngineSequence": engine.last_engine_sequence.load(Ordering::Acquire),
                            "lastSourceCursor": engine.last_source_cursor.load(Ordering::Acquire),
                            "lastHeartbeatAt": last_heartbeat_at,
                        }),
                    )
                }
                None => (false, json!({"connected": false})),
            };
            Ok(BackendHealth {
                ready,
                role: "relay".to_owned(),
                details: json!({
                    "protocolVersion": crate::PROTOCOL_VERSION,
                    "uptimeSeconds": self.started_at.elapsed().as_secs(),
                    "sqlite": self.store.metadata(),
                    "pendingCommands": pending_commands.len(),
                    "engine": engine_details,
                }),
            })
        })
    }

    fn snapshot(&self) -> BackendFuture<'_, AuthoritativeSnapshot> {
        Box::pin(async move {
            RelayState::mobile_snapshot(self)
                .await
                .map_err(backend_internal)
        })
    }

    fn session(&self, window_id: String) -> BackendFuture<'_, Option<SessionSummary>> {
        Box::pin(async move {
            let Some(session_id) = self
                .resolve_window_id(&window_id)
                .await
                .map_err(backend_internal)?
            else {
                return Ok(None);
            };
            let Some(stored) = self
                .store
                .get_session(session_id.clone())
                .await
                .map_err(backend_internal)?
            else {
                return Ok(None);
            };
            if !stored.session.managed_by_fermin || session_is_archived(&stored.session) {
                return Ok(None);
            }
            let mut cached_session = stored.session;
            let announced_message_count = cached_session.message_count;
            cached_session.messages = crate::engine::collapse_provider_snapshot_aliases(
                self.store
                    .list_messages(cached_session.session_id.clone())
                    .await
                    .map_err(backend_internal)?
                    .into_iter()
                    .map(|stored| stored.message)
                    .collect(),
            );
            cached_session.message_count = cached_session.messages.len() as u64;
            cached_session.last_message_preview = cached_session
                .messages
                .last()
                .map(|message| crate::protocol::bounded_session_preview(&message.content));
            if transcript_cache_covers_summary(
                cached_session.messages.len(),
                announced_message_count,
            ) {
                return Ok(Some(cached_session));
            }
            if self.active_engine.lock().await.is_some() {
                let (result, fence) = match self
                    .query_engine_with_fence("session", json!({"windowId": session_id}))
                    .await
                {
                    Ok(result) => result,
                    Err(error) => {
                        warn!(
                            session_id,
                            error = %error,
                            "engine session query failed; serving durable relay transcript"
                        );
                        return Ok(Some(cached_session));
                    }
                };
                let session: Option<SessionSummary> =
                    serde_json::from_value(result).map_err(|_| {
                        MobileBackendError::Internal(
                            "Fermín engine returned an invalid session detail".to_owned(),
                        )
                    })?;
                if let Some(session) = session {
                    if session.session_id != session_id {
                        return Err(MobileBackendError::Internal(
                            "Fermín engine returned a mismatched session detail".to_owned(),
                        ));
                    }
                    if !session.managed_by_fermin || session_is_archived(&session) {
                        return Ok(None);
                    }
                    if let Err(error) =
                        backfill_session_messages(&self.store, &session, Some(fence)).await
                    {
                        // The live engine result is still authoritative for
                        // this read. A stale fence during a reconnect must not
                        // hide recovered messages; the next detail read or
                        // bridge snapshot retries the durable repair.
                        warn!(
                            session_id,
                            error = %error,
                            "failed to persist recovered engine transcript in relay cache"
                        );
                    }
                    return Ok(Some(session));
                }
                return Ok(None);
            }
            Ok(Some(cached_session))
        })
    }

    fn command(&self, command_id: String) -> BackendFuture<'_, Option<CommandRecord>> {
        Box::pin(async move {
            self.store
                .get_command(command_id)
                .await
                .map_err(backend_internal)
        })
    }

    fn submit_command(
        &self,
        target_window_id: Option<String>,
        mut request: CommandRequest,
    ) -> BackendFuture<'_, CommandAcceptance> {
        Box::pin(async move {
            if let Some(window_id) = target_window_id {
                let target_session_id = self
                    .resolve_window_id(&window_id)
                    .await
                    .map_err(backend_internal)?
                    .ok_or_else(|| {
                        MobileBackendError::NotFound(format!("session {window_id} was not found"))
                    })?;
                request =
                    crate::engine::EngineState::route_targeted_command(request, target_session_id)
                        .map_err(|error| MobileBackendError::Invalid(error.to_string()))?;
            }
            if matches!(
                &request.command,
                CommandKind::SendMessage { .. }
                    | CommandKind::RunPromptImprover { .. }
                    | CommandKind::RetryPromptTransform { .. }
            ) {
                let variant = self.prompt_preference.lock().await.variant;
                request =
                    crate::engine::EngineState::attach_prompt_improver_variant(request, variant);
            }
            self.accept_mobile_command(request)
                .await
                .map_err(backend_internal)
        })
    }

    fn models(&self, _window_id: String) -> BackendFuture<'_, ModelCatalog> {
        Box::pin(async move {
            self.store
                .get_models()
                .await
                .map_err(backend_internal)?
                .ok_or_else(|| {
                    MobileBackendError::Unavailable("model catalog is not ready".to_owned())
                })
        })
    }

    fn projects(&self) -> BackendFuture<'_, ProjectCatalog> {
        Box::pin(async move {
            let result = self
                .query_engine("projects", json!({}))
                .await
                .map_err(|_| {
                    MobileBackendError::Unavailable(
                        "project catalog is unavailable while the Fermín engine is offline"
                            .to_owned(),
                    )
                })?;
            serde_json::from_value(result).map_err(|_| {
                MobileBackendError::Internal(
                    "Fermín engine returned an invalid project catalog".to_owned(),
                )
            })
        })
    }

    fn prompt_improver_preference(&self) -> BackendFuture<'_, PromptImproverPreferenceRecord> {
        Box::pin(async move { Ok(self.prompt_preference.lock().await.clone()) })
    }

    fn set_prompt_improver_preference(
        &self,
        variant: PromptImproverVariant,
    ) -> BackendFuture<'_, PromptImproverPreferenceRecord> {
        Box::pin(async move {
            let record = PromptImproverPreferenceRecord {
                version: 1,
                variant,
                updated_at: Some(now_ms().to_string()),
            };
            write_prompt_preference(&self.prompt_preference_path, &record)
                .await
                .map_err(backend_internal)?;
            *self.prompt_preference.lock().await = record.clone();
            Ok(record)
        })
    }

    fn file_preview(&self, path: String) -> BackendFuture<'_, FilePreview> {
        Box::pin(async move {
            let result = self
                .query_engine("filePreview", json!({"path": path}))
                .await
                .map_err(|_| {
                    MobileBackendError::Unavailable(
                        "file preview is unavailable from the Fermín engine".to_owned(),
                    )
                })?;
            serde_json::from_value(result).map_err(|_| {
                MobileBackendError::Internal(
                    "Fermín engine returned an invalid file preview".to_owned(),
                )
            })
        })
    }

    fn upload_attachment(
        &self,
        window_id: String,
        upload: AttachmentUpload,
    ) -> BackendFuture<'_, ImageAttachment> {
        Box::pin(async move {
            if self
                .resolve_window_id(&window_id)
                .await
                .map_err(backend_internal)?
                .is_none()
            {
                return Err(MobileBackendError::NotFound(
                    "attachment session was not found".to_owned(),
                ));
            }
            let extension = relay_attachment_extension(&upload.mime_type).ok_or_else(|| {
                MobileBackendError::UnsupportedMediaType(
                    "unsupported relay attachment type".to_owned(),
                )
            })?;
            let attachment_id = Uuid::new_v4().to_string();
            let safe_name = sanitize_file_name(&upload.file_name);
            let token = format!("{attachment_id}.{extension}");
            let path = relay_attachment_root(&self.config).join(&token);
            atomic_write_bytes(&path, &upload.bytes)
                .await
                .map_err(backend_internal)?;
            Ok(ImageAttachment {
                id: attachment_id,
                name: safe_name,
                path: Some(format!("{RELAY_ATTACHMENT_PREFIX}{token}")),
                size: upload.bytes.len() as u64,
                mime_type: upload.mime_type,
                preview_data: None,
            })
        })
    }

    fn attachment_content(&self, path: String) -> BackendFuture<'_, AttachmentContent> {
        Box::pin(async move {
            let token = path
                .strip_prefix(RELAY_ATTACHMENT_PREFIX)
                .ok_or_else(|| MobileBackendError::Invalid("invalid attachment path".to_owned()))?;
            self.load_relay_attachment(token).await
        })
    }

    fn session_history(&self, query: SessionHistoryQuery) -> BackendFuture<'_, SessionHistoryPage> {
        Box::pin(async move {
            let mut items = Vec::new();
            let needle = query.query.trim().to_ascii_lowercase();
            for stored in self.store.list_sessions().await.map_err(backend_internal)? {
                let session = stored.session;
                if !session.managed_by_fermin {
                    continue;
                }
                let archived = session_is_archived(&session);
                let state = if archived {
                    SessionHistoryState::Archived
                } else {
                    SessionHistoryState::Active
                };
                if (query.state == SessionHistoryState::Active && archived)
                    || (query.state == SessionHistoryState::Archived && !archived)
                {
                    continue;
                }
                if query
                    .project_path
                    .as_deref()
                    .is_some_and(|path| session.project_path.as_deref() != Some(path))
                {
                    continue;
                }
                if query.from.is_some_and(|from| session.updated_at < from)
                    || query.to.is_some_and(|to| session.updated_at > to)
                {
                    continue;
                }
                let searchable = format!(
                    "{} {} {}",
                    session.display_name,
                    session.project_name.as_deref().unwrap_or_default(),
                    session.last_message_preview.as_deref().unwrap_or_default()
                )
                .to_ascii_lowercase();
                let relevance = history_relevance(&session, &needle, &searchable);
                let Some((score, matched_in)) = relevance else {
                    continue;
                };
                items.push(SessionHistoryItem {
                    id: session.session_id.clone(),
                    session_uuid: Some(session.session_id.clone()),
                    project_key: session.project_key.clone(),
                    project_name: session
                        .project_name
                        .clone()
                        .unwrap_or_else(|| session.project_key.clone()),
                    session_id: session.session_id.clone(),
                    session_name: session.display_name.clone(),
                    session_path: session.project_path.clone().unwrap_or_default(),
                    created_at: session.created_at.unwrap_or(session.updated_at),
                    updated_at: session.updated_at,
                    state,
                    window_id: Some(session.window_id),
                    archived_id: archived.then(|| session.session_id.clone()),
                    score,
                    preview: session.last_message_preview.unwrap_or_default(),
                    matched_in,
                    can_resume: true,
                });
            }
            items.sort_by(|left, right| match query.sort {
                SessionHistorySort::Relevance if !needle.is_empty() => right
                    .score
                    .total_cmp(&left.score)
                    .then_with(|| history_recent_order(left, right)),
                SessionHistorySort::Name => history_name_order(left, right),
                SessionHistorySort::Relevance | SessionHistorySort::Recent => {
                    history_recent_order(left, right)
                }
            });
            let total = items.len();
            let page = items
                .into_iter()
                .skip(query.offset)
                .take(query.limit)
                .collect::<Vec<_>>();
            Ok(SessionHistoryPage {
                has_more: query.offset.saturating_add(page.len()) < total,
                items: page,
                offset: query.offset,
                limit: query.limit,
                total,
                updated_at: now_ms(),
                search_ms: 0.0,
                index_build_ms: 0.0,
                indexed_sessions: total,
                indexed_terms: 0,
            })
        })
    }

    fn resume_history(
        &self,
        history_id: String,
        idempotency_key: String,
    ) -> BackendFuture<'_, SessionHistoryResumeResult> {
        Box::pin(async move {
            let stored = self
                .store
                .get_session(history_id.clone())
                .await
                .map_err(backend_internal)?
                .ok_or_else(|| {
                    MobileBackendError::NotFound("history session not found".to_owned())
                })?;
            let session = stored.session;
            if !session.managed_by_fermin {
                return Err(MobileBackendError::NotFound(
                    "history session not found".to_owned(),
                ));
            }
            let mut request = CommandRequest {
                command_id: None,
                idempotency_key,
                session_id: Some(session.session_id.clone()),
                command: CommandKind::SetMinimized { minimized: false },
                requested_at: now_ms(),
                trace_id: None,
            };
            if session_is_archived(&session) {
                request = crate::engine::EngineState::attach_resume_history_trace(request);
            }
            let acceptance = self
                .accept_mobile_command(request)
                .await
                .map_err(backend_internal)?;
            Ok(SessionHistoryResumeResult {
                acceptance,
                session_id: session.session_id,
                window_id: Some(session.window_id),
                project_path: session.project_path,
            })
        })
    }

    fn recoverable_sessions(
        &self,
        query: SessionRecoveryQuery,
    ) -> BackendFuture<'_, SessionRecoveryPage> {
        Box::pin(async move {
            let result = self
                .query_engine(
                    "recoverableSessions",
                    serde_json::to_value(query).map_err(backend_internal)?,
                )
                .await
                .map_err(|_| {
                    MobileBackendError::Unavailable(
                        "session recovery is unavailable while the Fermín engine is offline"
                            .to_owned(),
                    )
                })?;
            serde_json::from_value(result).map_err(|_| {
                MobileBackendError::Internal(
                    "Fermín engine returned an invalid recovery page".to_owned(),
                )
            })
        })
    }

    fn recover_session(
        &self,
        recovery_id: String,
        idempotency_key: String,
    ) -> BackendFuture<'_, SessionRecoveryResult> {
        Box::pin(async move {
            let result = self
                .query_engine("recoverableSession", json!({ "id": recovery_id }))
                .await
                .map_err(|_| {
                    MobileBackendError::Unavailable(
                        "session recovery is unavailable while the Fermín engine is offline"
                            .to_owned(),
                    )
                })?;
            let item: Option<SessionRecoveryItem> =
                serde_json::from_value(result).map_err(|_| {
                    MobileBackendError::Internal(
                        "Fermín engine returned an invalid recovery candidate".to_owned(),
                    )
                })?;
            let item = item.ok_or_else(|| {
                MobileBackendError::NotFound(format!(
                    "recovery session {recovery_id} was not found"
                ))
            })?;
            if !item.can_recover {
                return Err(MobileBackendError::Conflict(
                    "the selected session cannot be recovered".to_owned(),
                ));
            }
            let acceptance = self
                .accept_mobile_command(CommandRequest {
                    command_id: None,
                    idempotency_key,
                    session_id: Some(recovery_id.clone()),
                    command: CommandKind::RecoverSession,
                    requested_at: now_ms(),
                    trace_id: None,
                })
                .await
                .map_err(backend_internal)?;
            Ok(SessionRecoveryResult {
                acceptance,
                session_id: recovery_id.clone(),
                window_id: Some(recovery_id),
                project_path: item.project_path,
            })
        })
    }

    fn replay_events(
        &self,
        cursor: ReplayCursor,
        limit: usize,
    ) -> BackendFuture<'_, Vec<DurableEvent>> {
        Box::pin(async move {
            let requested_after = cursor
                .after_global_sequence
                .or_else(|| parse_event_sequence(cursor.last_event_id.as_deref()))
                .unwrap_or(0);
            let cutover = self
                .store
                .get_snapshot(SESSION_OWNERSHIP_CUTOVER_SCOPE)
                .await
                .map_err(backend_internal)?
                .map_or(0, |stored| stored.snapshot.global_sequence);
            let after = requested_after.max(cutover);
            self.store
                .replay_events(
                    EventCursor {
                        after_global_sequence: after,
                    },
                    limit,
                )
                .await
                .map_err(backend_internal)
        })
    }

    fn subscribe_events(&self) -> Result<BackendEventStream, MobileBackendError> {
        let mut receiver = self.event_wake.subscribe();
        Ok(Box::pin(async_stream::stream! {
            loop {
                match receiver.recv().await {
                    Ok(event) => yield Ok(event),
                    Err(broadcast::error::RecvError::Lagged(_)) => {
                        yield Err(MobileBackendError::Unavailable(
                            "event subscriber lagged; replay from the durable cursor".to_owned(),
                        ));
                        break;
                    }
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
        }))
    }
}

fn backend_internal(error: impl std::fmt::Display) -> MobileBackendError {
    MobileBackendError::Internal(error.to_string())
}

fn transcript_cache_covers_summary(
    cached_message_count: usize,
    announced_message_count: u64,
) -> bool {
    cached_message_count > 0
        && u64::try_from(cached_message_count).unwrap_or(u64::MAX) >= announced_message_count
}

async fn backfill_session_messages(
    store: &Store,
    session: &SessionSummary,
    fence: Option<FencingToken>,
) -> Result<usize> {
    let existing_messages = store
        .list_messages(session.session_id.clone())
        .await?
        .into_iter()
        .map(|stored| (stored.message.id.clone(), stored))
        .collect::<BTreeMap<_, _>>();
    let mut applied = 0usize;
    for message in &session.messages {
        let final_ = message.status.as_deref() != Some("streaming");
        let existing = existing_messages.get(&message.id);
        if existing.is_some_and(|stored| stored.message == *message && stored.final_ == final_) {
            continue;
        }
        store
            .upsert_message(
                MessageMutation {
                    session_id: session.session_id.clone(),
                    message: message.clone(),
                    revision: existing
                        .map(|stored| stored.revision.saturating_add(1))
                        .unwrap_or(1),
                    updated_at: message.timestamp,
                    final_,
                },
                fence.clone(),
            )
            .await?;
        applied += 1;
    }
    Ok(applied)
}

fn session_is_archived(session: &SessionSummary) -> bool {
    session.runtime_status.as_deref() == Some("ARCHIVED")
}

fn history_relevance(
    session: &SessionSummary,
    needle: &str,
    legacy_searchable: &str,
) -> Option<(f64, Option<String>)> {
    if needle.is_empty() {
        return Some((0.0, None));
    }
    let candidates = [
        ("name", session.display_name.as_str(), 1_000_u16, 900, 800),
        (
            "project",
            session.project_name.as_deref().unwrap_or_default(),
            700,
            650,
            600,
        ),
        ("project", session.project_key.as_str(), 650, 600, 550),
        (
            "preview",
            session.last_message_preview.as_deref().unwrap_or_default(),
            500,
            450,
            400,
        ),
        (
            "path",
            session.project_path.as_deref().unwrap_or_default(),
            350,
            325,
            300,
        ),
    ];
    let mut best: Option<(u16, &str)> = None;
    for (field, value, exact_score, prefix_score, contains_score) in candidates {
        let normalized = value.to_ascii_lowercase();
        let score = if normalized == needle {
            Some(exact_score)
        } else if normalized.starts_with(needle) {
            Some(prefix_score)
        } else if normalized.contains(needle) {
            Some(contains_score)
        } else {
            None
        };
        if let Some(score) = score
            && best.is_none_or(|(best_score, _)| score > best_score)
        {
            best = Some((score, field));
        }
    }
    best.map(|(score, field)| (f64::from(score), Some(field.to_owned())))
        .or_else(|| {
            legacy_searchable
                .contains(needle)
                .then(|| (1.0, Some("combined".to_owned())))
        })
}

fn history_recent_order(
    left: &SessionHistoryItem,
    right: &SessionHistoryItem,
) -> std::cmp::Ordering {
    right
        .updated_at
        .cmp(&left.updated_at)
        .then_with(|| {
            left.session_name
                .to_ascii_lowercase()
                .cmp(&right.session_name.to_ascii_lowercase())
        })
        .then_with(|| left.session_name.cmp(&right.session_name))
        .then_with(|| left.session_id.cmp(&right.session_id))
}

fn history_name_order(left: &SessionHistoryItem, right: &SessionHistoryItem) -> std::cmp::Ordering {
    left.session_name
        .to_ascii_lowercase()
        .cmp(&right.session_name.to_ascii_lowercase())
        .then_with(|| left.session_name.cmp(&right.session_name))
        .then_with(|| right.updated_at.cmp(&left.updated_at))
        .then_with(|| left.session_id.cmp(&right.session_id))
}

fn relay_attachment_root(config: &RelayConfig) -> std::path::PathBuf {
    config
        .database_path
        .parent()
        .unwrap_or_else(|| std::path::Path::new("."))
        .join("attachments")
}

fn relay_attachment_extension(mime_type: &str) -> Option<&'static str> {
    match mime_type {
        "image/png" => Some("png"),
        "image/jpeg" => Some("jpg"),
        "image/gif" => Some("gif"),
        "image/webp" => Some("webp"),
        _ => None,
    }
}

fn relay_attachment_mime(token: &str) -> Option<&'static str> {
    let (identifier, extension) = token.rsplit_once('.')?;
    if Uuid::parse_str(identifier).is_err() {
        return None;
    }
    match extension {
        "png" => Some("image/png"),
        "jpg" => Some("image/jpeg"),
        "gif" => Some("image/gif"),
        "webp" => Some("image/webp"),
        _ => None,
    }
}

fn relay_attachment_bytes_match_mime(mime_type: &str, bytes: &[u8]) -> bool {
    match mime_type {
        "image/png" => bytes.starts_with(&[0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a]),
        "image/jpeg" => bytes.starts_with(&[0xff, 0xd8, 0xff]),
        "image/gif" => bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a"),
        "image/webp" => bytes.len() >= 12 && bytes.starts_with(b"RIFF") && &bytes[8..12] == b"WEBP",
        _ => false,
    }
}

fn sanitize_file_name(value: &str) -> String {
    let value = std::path::Path::new(value)
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("attachment");
    let sanitized = value
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() || matches!(character, '.' | '-' | '_') {
                character
            } else {
                '_'
            }
        })
        .take(180)
        .collect::<String>();
    if sanitized.is_empty() {
        "attachment".to_owned()
    } else {
        sanitized
    }
}

fn parse_event_sequence(event_id: Option<&str>) -> Option<u64> {
    event_id.and_then(|value| value.rsplit(':').next()?.parse().ok())
}

async fn read_prompt_preference(path: &std::path::Path) -> PromptImproverPreferenceRecord {
    match tokio::fs::read(path).await {
        Ok(bytes) => serde_json::from_slice(&bytes).unwrap_or(PromptImproverPreferenceRecord {
            version: 1,
            variant: PromptImproverVariant::Standard,
            updated_at: None,
        }),
        Err(_) => PromptImproverPreferenceRecord {
            version: 1,
            variant: PromptImproverVariant::Standard,
            updated_at: None,
        },
    }
}

async fn write_prompt_preference(
    path: &std::path::Path,
    record: &PromptImproverPreferenceRecord,
) -> Result<()> {
    if let Some(parent) = path.parent() {
        tokio::fs::create_dir_all(parent).await?;
    }
    let bytes = serde_json::to_vec(record)?;
    atomic_write_bytes(path, &bytes).await
}

async fn atomic_write_bytes(path: &std::path::Path, bytes: &[u8]) -> Result<()> {
    let parent = path
        .parent()
        .context("private file path has no parent directory")?;
    tokio::fs::create_dir_all(parent).await?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        tokio::fs::set_permissions(parent, std::fs::Permissions::from_mode(0o700)).await?;
    }
    let path = path.to_path_buf();
    let temporary = parent.join(format!(".fermin-{}.tmp", Uuid::new_v4()));
    let bytes = bytes.to_vec();
    tokio::task::spawn_blocking(move || -> Result<()> {
        use std::io::Write;
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&temporary)?;
        if let Err(error) = file.write_all(&bytes).and_then(|_| file.sync_all()) {
            let _ = std::fs::remove_file(&temporary);
            return Err(error.into());
        }
        if let Err(error) = std::fs::rename(&temporary, &path) {
            let _ = std::fs::remove_file(&temporary);
            return Err(error.into());
        }
        Ok(())
    })
    .await
    .context("join private file writer")??;
    Ok(())
}

impl ActiveEngine {
    fn envelope(&self, frame: RelayFrame) -> RelayEnvelope {
        self.envelope_with_cursor(frame, None)
    }

    fn envelope_with_cursor(&self, frame: RelayFrame, resume_cursor: Option<u64>) -> RelayEnvelope {
        RelayEnvelope {
            protocol_version: crate::PROTOCOL_VERSION,
            engine_id: self.engine_id.clone(),
            connection_epoch: self.connection_epoch,
            sequence: self.next_sequence.fetch_add(1, Ordering::AcqRel),
            acknowledgement: self.last_engine_sequence.load(Ordering::Acquire),
            resume_cursor,
            fence_generation: self.fence.generation,
            frame,
        }
    }
}

pub fn relay_router(state: Arc<RelayState>) -> Router {
    Router::new()
        .route("/relay-healthz", get(health))
        .route("/v1/engine/connect", get(engine_connect))
        .route("/v1/engine/attachments/{token}", get(engine_attachment))
        .route("/fermin-code/relay-healthz", get(health))
        .route("/fermin-code/v1/engine/connect", get(engine_connect))
        .route(
            "/fermin-code/v1/engine/attachments/{token}",
            get(engine_attachment),
        )
        .route("/fermin-code-puky/relay-healthz", get(health))
        .route("/fermin-code-puky/v1/engine/connect", get(engine_connect))
        .route(
            "/fermin-code-puky/v1/engine/attachments/{token}",
            get(engine_attachment),
        )
        .with_state(state)
}

async fn health(State(state): State<Arc<RelayState>>) -> Response {
    let backend_health = MobileBackend::health(state.as_ref()).await;
    let (status, service_ready, engine_ready, details) = match backend_health {
        Ok(health) => (StatusCode::OK, true, health.ready, health.details),
        Err(error) => (
            StatusCode::SERVICE_UNAVAILABLE,
            false,
            false,
            json!({"error": error.to_string()}),
        ),
    };
    (
        status,
        Json(json!({
            "ok": service_ready,
            "ready": service_ready,
            "engineReady": engine_ready,
            "service": "fermin-relay",
            "version": crate::BUILD_VERSION,
            "details": details,
        })),
    )
        .into_response()
}

async fn engine_connect(
    State(state): State<Arc<RelayState>>,
    Query(query): Query<EngineQuery>,
    headers: HeaderMap,
    upgrade: WebSocketUpgrade,
) -> Response {
    if !authorized(&headers, &state.engine_token) {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({"error": "unauthorized"})),
        )
            .into_response();
    }
    upgrade
        .max_message_size(MAX_ENGINE_FRAME_BYTES)
        .on_upgrade(move |socket| engine_socket(state, query.engine_id, socket))
        .into_response()
}

async fn engine_attachment(
    State(state): State<Arc<RelayState>>,
    AxumPath(token): AxumPath<String>,
    headers: HeaderMap,
) -> Response {
    if !authorized(&headers, &state.engine_token) {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({"error": "unauthorized"})),
        )
            .into_response();
    }
    let content = match state.load_relay_attachment(&token).await {
        Ok(content) => content,
        Err(MobileBackendError::Invalid(_) | MobileBackendError::NotFound(_)) => {
            return (
                StatusCode::NOT_FOUND,
                Json(json!({"error": "attachment not found"})),
            )
                .into_response();
        }
        Err(_) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({"error": "attachment unavailable"})),
            )
                .into_response();
        }
    };
    let length = content.bytes.len();
    let mut response = content.bytes.into_response();
    response.headers_mut().insert(
        CONTENT_TYPE,
        HeaderValue::from_str(&content.mime_type)
            .unwrap_or_else(|_| HeaderValue::from_static("application/octet-stream")),
    );
    response.headers_mut().insert(
        CONTENT_LENGTH,
        HeaderValue::from_str(&length.to_string())
            .unwrap_or_else(|_| HeaderValue::from_static("0")),
    );
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("private, no-store"));
    response
}

async fn engine_socket(
    state: Arc<RelayState>,
    query_engine_id: Option<String>,
    mut socket: WebSocket,
) {
    let first = match timeout(INITIAL_FRAME_TIMEOUT, socket.recv()).await {
        Ok(Some(Ok(WebSocketMessage::Text(text)))) => text,
        _ => {
            let _ = socket.close().await;
            return;
        }
    };
    let hello: RelayEnvelope = match serde_json::from_str(first.as_str()) {
        Ok(envelope) => envelope,
        Err(_) => {
            let _ = socket
                .send(WebSocketMessage::Text(
                    json!({"error":"invalid hello envelope"}).to_string().into(),
                ))
                .await;
            let _ = socket.close().await;
            return;
        }
    };
    let RelayFrame::Hello { .. } = &hello.frame else {
        let _ = socket.close().await;
        return;
    };
    if hello.protocol_version != crate::PROTOCOL_VERSION
        || query_engine_id
            .as_deref()
            .is_some_and(|engine_id| engine_id != hello.engine_id)
    {
        let _ = socket.close().await;
        return;
    }

    let connection_id = Uuid::new_v4().to_string();
    let lease = match state
        .store
        .acquire_lease(LeaseRequest {
            lease_key: format!("engine:{}", hello.engine_id),
            // The durable holder is the authenticated logical engine, while
            // connection_id remains the in-memory socket identity. A relay
            // restart necessarily destroys the old socket, so a reconnect from
            // the same engine must advance the generation immediately instead
            // of waiting out a ghost connection's full lease TTL. The new
            // generation fences every late frame from the superseded socket.
            holder_id: hello.engine_id.clone(),
            now: now_ms(),
            ttl_millis: (state.config.engine_lease_seconds as i64) * 1_000,
            previous_generation: None,
        })
        .await
    {
        Ok(lease) => lease,
        Err(error) => {
            warn!(%error, "failed to acquire engine lease");
            let _ = socket.close().await;
            return;
        }
    };
    let fence = lease.fencing_token(now_ms());
    let (outbound, mut outbound_rx) = mpsc::channel(ENGINE_WRITER_CAPACITY);
    let active = ActiveEngine {
        engine_id: hello.engine_id.clone(),
        connection_id,
        connection_epoch: hello.connection_epoch,
        fence,
        outbound,
        next_sequence: Arc::new(AtomicU64::new(1)),
        last_engine_sequence: Arc::new(AtomicU64::new(hello.sequence)),
        last_source_cursor: Arc::new(AtomicU64::new(
            state
                .store
                .get_cursor(format!("source:{}", hello.engine_id))
                .await
                .ok()
                .flatten()
                .map(|cursor| cursor.global_sequence)
                .unwrap_or(0),
        )),
        last_heartbeat_ms: Arc::new(AtomicU64::new(now_ms().max(0) as u64)),
        pending_command_acks: Arc::new(Mutex::new(BTreeMap::new())),
        cancellation: tokio_util::sync::CancellationToken::new(),
    };
    let superseded = state.active_engine.lock().await.replace(active.clone());
    if let Some(superseded) = superseded {
        superseded.cancellation.cancel();
        fail_pending_queries(&state, &superseded).await;
    }

    let ack = active.envelope_with_cursor(
        RelayFrame::Ack,
        Some(active.last_source_cursor.load(Ordering::Acquire)),
    );
    if active.outbound.send(ack).await.is_err() {
        clear_active(&state, &active).await;
        return;
    }
    if let Err(error) = state.dispatch_next_command_batch(&active).await {
        warn!(engine_id = %active.engine_id, %error, "failed to dispatch pending relay commands");
    }

    let (mut writer, mut reader) = socket.split();
    let mut lease_tick = interval(Duration::from_secs(
        (state.config.engine_lease_seconds / 3).max(2),
    ));
    loop {
        tokio::select! {
            _ = active.cancellation.cancelled() => {
                let _ = writer.send(WebSocketMessage::Close(None)).await;
                break;
            }
            outbound = outbound_rx.recv() => {
                let Some(envelope) = outbound else { break; };
                let Ok(text) = serde_json::to_string(&envelope) else { break; };
                if writer.send(WebSocketMessage::Text(text.into())).await.is_err() {
                    break;
                }
            }
            inbound = reader.next() => {
                match inbound {
                    Some(Ok(WebSocketMessage::Text(text))) => {
                        let envelope: RelayEnvelope = match serde_json::from_str(text.as_str()) {
                            Ok(value) => value,
                            Err(error) => {
                                warn!(%error, "invalid engine envelope");
                                break;
                            }
                        };
                        if let Err(error) = state.apply_engine_envelope(&active, envelope).await {
                            warn!(engine_id = %active.engine_id, %error, "rejected engine envelope");
                            break;
                        }
                    }
                    Some(Ok(WebSocketMessage::Ping(data))) => {
                        if writer.send(WebSocketMessage::Pong(data)).await.is_err() { break; }
                    }
                    Some(Ok(WebSocketMessage::Close(_))) | None | Some(Err(_)) => break,
                    Some(Ok(_)) => {}
                }
            }
            _ = lease_tick.tick() => {
                let renewed = state.store.renew_lease(
                    active.fence.clone(),
                    (state.config.engine_lease_seconds as i64) * 1_000,
                ).await;
                if renewed.is_err() {
                    break;
                }
                let ping = active.envelope(RelayFrame::Ping { sent_at: now_ms() });
                if active.outbound.try_send(ping).is_err() {
                    break;
                }
            }
        }
    }
    clear_active(&state, &active).await;
}

async fn clear_active(state: &RelayState, active: &ActiveEngine) {
    let mut guard = state.active_engine.lock().await;
    if guard
        .as_ref()
        .is_some_and(|current| current.connection_id == active.connection_id)
    {
        *guard = None;
    }
    drop(guard);
    fail_pending_queries(state, active).await;
    let _ = state.store.release_lease(active.fence.clone()).await;
}

async fn fail_pending_queries(state: &RelayState, active: &ActiveEngine) {
    let disconnected = RelayQueryError {
        code: "engine_disconnected".to_owned(),
        message: "engine disconnected during query".to_owned(),
    };
    let pending = {
        let mut pending = state.pending_queries.lock().await;
        let request_ids = pending
            .iter()
            .filter(|(_, query)| query.connection_id == active.connection_id)
            .map(|(request_id, _)| request_id.clone())
            .collect::<Vec<_>>();
        request_ids
            .into_iter()
            .filter_map(|request_id| pending.remove(&request_id))
            .collect::<Vec<_>>()
    };
    for query in pending {
        let _ = query.response.send(Err(disconnected.clone()));
    }
}

fn validate_outbound_query(method: &str, params: &Value) -> Result<()> {
    let valid_method = !method.is_empty()
        && method.len() <= MAX_QUERY_METHOD_BYTES
        && method
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'));
    if !valid_method {
        anyhow::bail!("invalid read-only engine query method");
    }
    let params_size = serde_json::to_vec(params)
        .map(|encoded| encoded.len())
        .unwrap_or(usize::MAX);
    if params_size > MAX_QUERY_PARAMS_BYTES {
        anyhow::bail!("engine query params exceed the transport limit");
    }
    Ok(())
}

fn authorized(headers: &HeaderMap, expected: &str) -> bool {
    let Some(value) = headers
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
    else {
        return false;
    };
    value.as_bytes().ct_eq(expected.as_bytes()).into()
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(i64::MAX as u128) as i64
}

async fn shutdown_signal() {
    let ctrl_c = async {
        let _ = tokio::signal::ctrl_c().await;
    };
    #[cfg(unix)]
    let terminate = async {
        if let Ok(mut signal) =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        {
            signal.recv().await;
        }
    };
    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();
    tokio::select! {
        () = ctrl_c => {},
        () = terminate => {},
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bearer_comparison_is_exact() {
        let mut headers = HeaderMap::new();
        headers.insert(
            axum::http::header::AUTHORIZATION,
            "Bearer 01234567890123456789012345678901".parse().unwrap(),
        );
        assert!(authorized(&headers, "01234567890123456789012345678901"));
        assert!(!authorized(&headers, "01234567890123456789012345678902"));
    }

    #[test]
    fn partial_nonempty_transcript_requires_engine_detail() {
        assert!(!transcript_cache_covers_summary(409, 437));
        assert!(transcript_cache_covers_summary(437, 437));
        assert!(transcript_cache_covers_summary(438, 437));
        assert!(!transcript_cache_covers_summary(0, 0));
    }

    #[tokio::test]
    async fn engine_detail_backfills_partial_durable_transcript_idempotently() {
        let directory = tempfile::TempDir::new().unwrap();
        let store = Store::open(directory.path().join("relay.sqlite3"))
            .await
            .unwrap();
        let mut session = SessionSummary::new("partial", "project", "Partial", 1);
        session.message_count = 3;
        session.messages = vec![
            crate::protocol::Message::user("user-1", "one", 1),
            crate::protocol::Message::assistant("assistant-1", "two", 2),
            crate::protocol::Message::assistant("assistant-2", "three", 3),
        ];
        store.upsert_session(session.clone(), None).await.unwrap();
        store
            .upsert_message(
                MessageMutation {
                    session_id: session.session_id.clone(),
                    message: session.messages[0].clone(),
                    revision: 1,
                    updated_at: 1,
                    final_: true,
                },
                None,
            )
            .await
            .unwrap();

        assert_eq!(
            backfill_session_messages(&store, &session, None)
                .await
                .unwrap(),
            2
        );
        assert_eq!(store.list_messages("partial").await.unwrap().len(), 3);
        assert_eq!(
            backfill_session_messages(&store, &session, None)
                .await
                .unwrap(),
            0
        );
        assert_eq!(store.list_messages("partial").await.unwrap().len(), 3);
    }
}
