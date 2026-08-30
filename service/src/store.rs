use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use rusqlite::{Connection, OptionalExtension, Transaction, TransactionBehavior, params};
use serde::Serialize;
use tokio::sync::{Semaphore, mpsc, oneshot};
use uuid::Uuid;

use crate::protocol::{
    AuthoritativeSnapshot, CommandAcceptance, CommandMutation, CommandReceipt, CommandRecord,
    CommandRequest, CommandState, CommandTransition, ConsumerCursor, DurableEvent, EngineEpoch,
    EventCursor, EventKind, FencingToken, LeaseRecord, LeaseRequest, MessageMutation, ModelCatalog,
    NewEngineEpoch, NewEvent, NewOutboxEntry, RelayFrame, RelayOutboxEntry, SessionSummary,
    StoreMetadata, StoredMessage, StoredSession, StoredSnapshot,
};

const STORE_SCHEMA_VERSION: u32 = 2;
const MINIMUM_SQLITE_VERSION_NUMBER: i32 = 3_051_003;
const MINIMUM_SQLITE_VERSION: &str = "3.51.3";
const DEFAULT_QUEUE_CAPACITY: usize = 256;
const DEFAULT_QUEUE_BYTE_CAPACITY: usize = 8 * 1024 * 1024;
const DEFAULT_MAX_REQUEST_BYTES: usize = 2 * 1024 * 1024;
const DEFAULT_BUSY_TIMEOUT: Duration = Duration::from_secs(5);
const MAX_READ_LIMIT: usize = 10_000;

const COMMAND_COLUMNS: &str = "command_id, idempotency_key, session_id, command_json, state, requested_at, accepted_at, updated_at, trace_id, lease_generation, error";
const EVENT_COLUMNS: &str = "event_id, global_sequence, session_sequence, session_id, command_id, process_epoch, kind, payload_json, created_at";

#[derive(Clone, Debug)]
pub struct StoreConfig {
    pub path: PathBuf,
    pub queue_capacity: usize,
    pub queue_byte_capacity: usize,
    pub max_request_bytes: usize,
    pub busy_timeout: Duration,
}

impl StoreConfig {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self {
            path: path.into(),
            queue_capacity: DEFAULT_QUEUE_CAPACITY,
            queue_byte_capacity: DEFAULT_QUEUE_BYTE_CAPACITY,
            max_request_bytes: DEFAULT_MAX_REQUEST_BYTES,
            busy_timeout: DEFAULT_BUSY_TIMEOUT,
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum StoreError {
    #[error("SQLite {found} is too old; Fermín Code requires at least {required}")]
    SqliteTooOld {
        found: String,
        required: &'static str,
    },
    #[error("unsupported store schema version {found}; this binary supports {supported}")]
    SchemaTooNew { found: u32, supported: u32 },
    #[error("invalid store configuration: {0}")]
    InvalidConfig(String),
    #[error("invalid store input: {0}")]
    InvalidInput(String),
    #[error("store request is {actual} bytes; maximum is {maximum}")]
    RequestTooLarge { actual: usize, maximum: usize },
    #[error("store actor is closed")]
    ActorClosed,
    #[error("idempotency key {key:?} was reused with a different command")]
    IdempotencyConflict { key: String },
    #[error("event id {event_id:?} was reused with different event data")]
    EventConflict { event_id: String },
    #[error("command {command_id:?} was not found")]
    CommandNotFound { command_id: String },
    #[error("relay command {relay_command_id:?} has a conflicting engine command alias")]
    CommandAliasConflict { relay_command_id: String },
    #[error("invalid command transition for {command_id:?}: {from:?} -> {to:?}")]
    InvalidCommandTransition {
        command_id: String,
        from: CommandState,
        to: CommandState,
    },
    #[error("command {command_id:?} is {actual:?}, expected {expected:?}")]
    CommandStateConflict {
        command_id: String,
        expected: CommandState,
        actual: CommandState,
    },
    #[error("lease {lease_key:?} is held by {holder_id:?} through {expires_at}")]
    LeaseHeld {
        lease_key: String,
        holder_id: String,
        expires_at: i64,
    },
    #[error("stale fencing token for lease {lease_key:?}: generation {generation}")]
    StaleFence { lease_key: String, generation: u64 },
    #[error("database invariant failed: {0}")]
    Invariant(String),
    #[error("SQLite error: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("JSON error: {0}")]
    Json(#[from] serde_json::Error),
    #[error("filesystem error: {0}")]
    Io(#[from] std::io::Error),
}

pub type StoreResult<T> = Result<T, StoreError>;

#[derive(Clone, Debug, PartialEq)]
pub struct SessionEventMutation {
    pub stored: StoredSession,
    pub event: Option<DurableEvent>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct MessageEventMutation {
    pub stored: StoredMessage,
    pub event: Option<DurableEvent>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct DeleteSessionEventMutation {
    pub deleted: bool,
    pub event: Option<DurableEvent>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ModelCatalogEventMutation {
    pub catalog: ModelCatalog,
    pub event: Option<DurableEvent>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct StoreStateSnapshot {
    pub sessions: Vec<StoredSession>,
    pub models: Option<ModelCatalog>,
    pub global_sequence: u64,
    pub authority: Option<StoredSnapshot>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct CommandAlias {
    pub relay_command_id: String,
    pub engine_command_id: String,
    pub idempotency_key: String,
    pub engine_state: CommandState,
    pub engine_updated_at: i64,
    pub error: Option<String>,
    pub created_at: i64,
    pub updated_at: i64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct CommandAliasMaterialization {
    pub matched_aliases: usize,
    pub mutations: Vec<CommandMutation>,
}

#[derive(Clone)]
pub struct Store {
    inner: Arc<StoreInner>,
}

struct StoreInner {
    sender: mpsc::Sender<QueuedRequest>,
    byte_budget: Arc<Semaphore>,
    max_request_bytes: usize,
    metadata: StoreMetadata,
}

impl std::fmt::Debug for Store {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("Store")
            .field("metadata", &self.inner.metadata)
            .finish_non_exhaustive()
    }
}

impl Store {
    pub async fn open(path: impl AsRef<Path>) -> StoreResult<Self> {
        Self::open_with_config(StoreConfig::new(path.as_ref())).await
    }

    pub async fn open_with_config(config: StoreConfig) -> StoreResult<Self> {
        validate_config(&config)?;
        let (sender, receiver) = mpsc::channel(config.queue_capacity);
        let (ready_sender, ready_receiver) = oneshot::channel();
        let actor_config = config.clone();
        std::thread::Builder::new()
            .name("fermin-sqlite-writer".to_owned())
            .spawn(move || match open_connection(&actor_config) {
                Ok((connection, metadata)) => {
                    if ready_sender.send(Ok(metadata)).is_ok() {
                        actor_loop(connection, receiver);
                    }
                }
                Err(error) => {
                    let _ = ready_sender.send(Err(error));
                }
            })?;

        let metadata = ready_receiver
            .await
            .map_err(|_| StoreError::ActorClosed)??;
        Ok(Self {
            inner: Arc::new(StoreInner {
                sender,
                byte_budget: Arc::new(Semaphore::new(config.queue_byte_capacity)),
                max_request_bytes: config.max_request_bytes,
                metadata,
            }),
        })
    }

    pub fn metadata(&self) -> &StoreMetadata {
        &self.inner.metadata
    }

    pub async fn begin_engine_epoch(&self, epoch: NewEngineEpoch) -> StoreResult<EngineEpoch> {
        let bytes = encoded_len(&epoch)?;
        let (reply, receive) = oneshot::channel();
        self.enqueue(Request::BeginEngineEpoch { epoch, reply }, bytes)
            .await?;
        receive.await.map_err(|_| StoreError::ActorClosed)?
    }

    pub async fn current_engine_epoch(
        &self,
        engine_id: impl Into<String>,
    ) -> StoreResult<Option<EngineEpoch>> {
        let engine_id = engine_id.into();
        let bytes = engine_id.len();
        let (reply, receive) = oneshot::channel();
        self.enqueue(Request::CurrentEngineEpoch { engine_id, reply }, bytes)
            .await?;
        receive.await.map_err(|_| StoreError::ActorClosed)?
    }

    pub async fn accept_command(&self, command: CommandRequest) -> StoreResult<CommandAcceptance> {
        self.accept_command_fenced(command, None).await
    }

    pub async fn accept_command_fenced(
        &self,
        command: CommandRequest,
        fence: Option<FencingToken>,
    ) -> StoreResult<CommandAcceptance> {
        let bytes = encoded_len(&command)? + encoded_len(&fence)?;
        let (reply, receive) = oneshot::channel();
        self.enqueue(
            Request::AcceptCommand {
                command,
                fence,
                reply,
            },
            bytes,
        )
        .await?;
        receive.await.map_err(|_| StoreError::ActorClosed)?
    }

    pub async fn get_command(
        &self,
        command_id: impl Into<String>,
    ) -> StoreResult<Option<CommandRecord>> {
        let command_id = command_id.into();
        let bytes = command_id.len();
        let (reply, receive) = oneshot::channel();
        self.enqueue(Request::GetCommand { command_id, reply }, bytes)
            .await?;
        receive.await.map_err(|_| StoreError::ActorClosed)?
    }

    pub async fn get_command_alias(
        &self,
        relay_command_id: impl Into<String>,
    ) -> StoreResult<Option<CommandAlias>> {
        let relay_command_id = relay_command_id.into();
        let bytes = relay_command_id.len();
        let (reply, receive) = oneshot::channel();
        self.enqueue(
            Request::GetCommandAlias {
                relay_command_id,
                reply,
            },
            bytes,
        )
        .await?;
        receive.await.map_err(|_| StoreError::ActorClosed)?
    }

    pub async fn record_command_receipt(
        &self,
        receipt: CommandReceipt,
        observed_at: i64,
        fence: Option<FencingToken>,
    ) -> StoreResult<CommandMutation> {
        let bytes = encoded_len(&receipt)? + encoded_len(&fence)?;
        let (reply, receive) = oneshot::channel();
        self.enqueue(
            Request::RecordCommandReceipt {
                receipt,
                observed_at,
                fence,
                reply,
            },
            bytes,
        )
        .await?;
        receive.await.map_err(|_| StoreError::ActorClosed)?
    }

    pub async fn materialize_engine_command_state(
        &self,
        engine_command_id: impl Into<String>,
        state: CommandState,
        engine_updated_at: i64,
        error: Option<String>,
        event: NewEvent,
        fence: Option<FencingToken>,
    ) -> StoreResult<CommandAliasMaterialization> {
        let engine_command_id = engine_command_id.into();
        let bytes = engine_command_id.len()
            + encoded_len(&state)?
            + encoded_len(&error)?
            + encoded_len(&event)?
            + encoded_len(&fence)?;
        let (reply, receive) = oneshot::channel();
        self.enqueue(
            Request::MaterializeEngineCommandState {
                engine_command_id,
                state,
                engine_updated_at,
                error,
                event,
                fence,
                reply,
            },
            bytes,
        )
        .await?;
        receive.await.map_err(|_| StoreError::ActorClosed)?
    }

    pub async fn pending_commands(&self, limit: usize) -> StoreResult<Vec<CommandRecord>> {
        let (reply, receive) = oneshot::channel();
        self.enqueue(
            Request::PendingCommands {
                limit: bounded_limit(limit),
                reply,
            },
            1,
        )
        .await?;
        receive.await.map_err(|_| StoreError::ActorClosed)?
    }

    pub async fn transition_command(
        &self,
        transition: CommandTransition,
        fence: Option<FencingToken>,
    ) -> StoreResult<CommandMutation> {
        let bytes = encoded_len(&transition)? + encoded_len(&fence)?;
        let (reply, receive) = oneshot::channel();
        self.enqueue(
            Request::TransitionCommand {
                transition,
                fence,
                reply,
            },
            bytes,
        )
        .await?;
        receive.await.map_err(|_| StoreError::ActorClosed)?
    }

    pub async fn append_event(
        &self,
        event: NewEvent,
        fence: Option<FencingToken>,
    ) -> StoreResult<DurableEvent> {
        let bytes = encoded_len(&event)? + encoded_len(&fence)?;
        let (reply, receive) = oneshot::channel();
        self.enqueue(
            Request::AppendEvent {
                event,
                fence,
                reply,
            },
            bytes,
        )
        .await?;
        receive.await.map_err(|_| StoreError::ActorClosed)?
    }

    pub async fn replay_events(
        &self,
        cursor: EventCursor,
        limit: usize,
    ) -> StoreResult<Vec<DurableEvent>> {
        let (reply, receive) = oneshot::channel();
        self.enqueue(
            Request::ReplayEvents {
                after: cursor.after_global_sequence,
                limit: bounded_limit(limit),
                reply,
            },
            1,
        )
        .await?;
        receive.await.map_err(|_| StoreError::ActorClosed)?
    }

    pub async fn replay_session_events(
        &self,
        session_id: impl Into<String>,
        after_session_sequence: u64,
        limit: usize,
    ) -> StoreResult<Vec<DurableEvent>> {
        let session_id = session_id.into();
        let bytes = session_id.len();
        let (reply, receive) = oneshot::channel();
        self.enqueue(
            Request::ReplaySessionEvents {
                session_id,
                after: after_session_sequence,
                limit: bounded_limit(limit),
                reply,
            },
            bytes,
        )
        .await?;
        receive.await.map_err(|_| StoreError::ActorClosed)?
    }

    pub async fn upsert_session(
        &self,
        session: SessionSummary,
        fence: Option<FencingToken>,
    ) -> StoreResult<StoredSession> {
        let bytes = encoded_len(&session)? + encoded_len(&fence)?;
        let (reply, receive) = oneshot::channel();
        self.enqueue(
            Request::UpsertSession {
                session,
                fence,
                reply,
            },
            bytes,
        )
        .await?;
        receive.await.map_err(|_| StoreError::ActorClosed)?
    }

    pub async fn upsert_session_with_event(
        &self,
        session: SessionSummary,
        event: NewEvent,
        fence: Option<FencingToken>,
    ) -> StoreResult<SessionEventMutation> {
        let bytes = encoded_len(&session)? + encoded_len(&event)? + encoded_len(&fence)?;
        let (reply, receive) = oneshot::channel();
        self.enqueue(
            Request::UpsertSessionWithEvent {
                session,
                event,
                fence,
                reply,
            },
            bytes,
        )
        .await?;
        receive.await.map_err(|_| StoreError::ActorClosed)?
    }

    pub async fn get_session(
        &self,
        session_id: impl Into<String>,
    ) -> StoreResult<Option<StoredSession>> {
        let session_id = session_id.into();
        let bytes = session_id.len();
        let (reply, receive) = oneshot::channel();
        self.enqueue(Request::GetSession { session_id, reply }, bytes)
            .await?;
        receive.await.map_err(|_| StoreError::ActorClosed)?
    }

    pub async fn list_sessions(&self) -> StoreResult<Vec<StoredSession>> {
        let (reply, receive) = oneshot::channel();
        self.enqueue(Request::ListSessions { reply }, 1).await?;
        receive.await.map_err(|_| StoreError::ActorClosed)?
    }

    pub async fn state_snapshot(
        &self,
        include_messages: bool,
        authority_scope: Option<String>,
    ) -> StoreResult<StoreStateSnapshot> {
        let bytes = authority_scope.as_ref().map_or(1, String::len);
        let (reply, receive) = oneshot::channel();
        self.enqueue(
            Request::StateSnapshot {
                include_messages,
                authority_scope,
                reply,
            },
            bytes,
        )
        .await?;
        receive.await.map_err(|_| StoreError::ActorClosed)?
    }

    pub async fn delete_session(
        &self,
        session_id: impl Into<String>,
        fence: Option<FencingToken>,
    ) -> StoreResult<bool> {
        let session_id = session_id.into();
        let bytes = session_id.len() + encoded_len(&fence)?;
        let (reply, receive) = oneshot::channel();
        self.enqueue(
            Request::DeleteSession {
                session_id,
                fence,
                reply,
            },
            bytes,
        )
        .await?;
        receive.await.map_err(|_| StoreError::ActorClosed)?
    }

    pub async fn delete_session_with_event(
        &self,
        session_id: impl Into<String>,
        event: NewEvent,
        fence: Option<FencingToken>,
    ) -> StoreResult<DeleteSessionEventMutation> {
        let session_id = session_id.into();
        let bytes = session_id.len() + encoded_len(&event)? + encoded_len(&fence)?;
        let (reply, receive) = oneshot::channel();
        self.enqueue(
            Request::DeleteSessionWithEvent {
                session_id,
                event,
                fence,
                reply,
            },
            bytes,
        )
        .await?;
        receive.await.map_err(|_| StoreError::ActorClosed)?
    }

    pub async fn upsert_message(
        &self,
        mutation: MessageMutation,
        fence: Option<FencingToken>,
    ) -> StoreResult<StoredMessage> {
        let bytes = encoded_len(&mutation)? + encoded_len(&fence)?;
        let (reply, receive) = oneshot::channel();
        self.enqueue(
            Request::UpsertMessage {
                mutation,
                fence,
                reply,
            },
            bytes,
        )
        .await?;
        receive.await.map_err(|_| StoreError::ActorClosed)?
    }

    pub async fn upsert_message_with_event(
        &self,
        mutation: MessageMutation,
        event: NewEvent,
        fence: Option<FencingToken>,
    ) -> StoreResult<MessageEventMutation> {
        let bytes = encoded_len(&mutation)? + encoded_len(&event)? + encoded_len(&fence)?;
        let (reply, receive) = oneshot::channel();
        self.enqueue(
            Request::UpsertMessageWithEvent {
                mutation,
                event,
                fence,
                reply,
            },
            bytes,
        )
        .await?;
        receive.await.map_err(|_| StoreError::ActorClosed)?
    }

    pub async fn list_messages(
        &self,
        session_id: impl Into<String>,
    ) -> StoreResult<Vec<StoredMessage>> {
        let session_id = session_id.into();
        let bytes = session_id.len();
        let (reply, receive) = oneshot::channel();
        self.enqueue(Request::ListMessages { session_id, reply }, bytes)
            .await?;
        receive.await.map_err(|_| StoreError::ActorClosed)?
    }

    pub async fn replace_models(
        &self,
        catalog: ModelCatalog,
        fence: Option<FencingToken>,
    ) -> StoreResult<ModelCatalog> {
        let bytes = encoded_len(&catalog)? + encoded_len(&fence)?;
        let (reply, receive) = oneshot::channel();
        self.enqueue(
            Request::ReplaceModels {
                catalog,
                fence,
                reply,
            },
            bytes,
        )
        .await?;
        receive.await.map_err(|_| StoreError::ActorClosed)?
    }

    pub async fn replace_models_with_event(
        &self,
        catalog: ModelCatalog,
        event: NewEvent,
        fence: Option<FencingToken>,
    ) -> StoreResult<ModelCatalogEventMutation> {
        let bytes = encoded_len(&catalog)? + encoded_len(&event)? + encoded_len(&fence)?;
        let (reply, receive) = oneshot::channel();
        self.enqueue(
            Request::ReplaceModelsWithEvent {
                catalog,
                event,
                fence,
                reply,
            },
            bytes,
        )
        .await?;
        receive.await.map_err(|_| StoreError::ActorClosed)?
    }

    pub async fn get_models(&self) -> StoreResult<Option<ModelCatalog>> {
        let (reply, receive) = oneshot::channel();
        self.enqueue(Request::GetModels { reply }, 1).await?;
        receive.await.map_err(|_| StoreError::ActorClosed)?
    }

    pub async fn put_snapshot(
        &self,
        scope: impl Into<String>,
        snapshot: AuthoritativeSnapshot,
        fence: Option<FencingToken>,
    ) -> StoreResult<StoredSnapshot> {
        let scope = scope.into();
        let bytes = scope.len() + encoded_len(&snapshot)? + encoded_len(&fence)?;
        let (reply, receive) = oneshot::channel();
        self.enqueue(
            Request::PutSnapshot {
                scope,
                snapshot,
                fence,
                reply,
            },
            bytes,
        )
        .await?;
        receive.await.map_err(|_| StoreError::ActorClosed)?
    }

    pub async fn get_snapshot(
        &self,
        scope: impl Into<String>,
    ) -> StoreResult<Option<StoredSnapshot>> {
        let scope = scope.into();
        let bytes = scope.len();
        let (reply, receive) = oneshot::channel();
        self.enqueue(Request::GetSnapshot { scope, reply }, bytes)
            .await?;
        receive.await.map_err(|_| StoreError::ActorClosed)?
    }

    pub async fn acquire_lease(&self, request: LeaseRequest) -> StoreResult<LeaseRecord> {
        let bytes = encoded_len(&request)?;
        let (reply, receive) = oneshot::channel();
        self.enqueue(Request::AcquireLease { request, reply }, bytes)
            .await?;
        receive.await.map_err(|_| StoreError::ActorClosed)?
    }

    pub async fn renew_lease(
        &self,
        token: FencingToken,
        ttl_millis: i64,
    ) -> StoreResult<LeaseRecord> {
        let bytes = encoded_len(&token)?;
        let (reply, receive) = oneshot::channel();
        self.enqueue(
            Request::RenewLease {
                token,
                ttl_millis,
                reply,
            },
            bytes,
        )
        .await?;
        receive.await.map_err(|_| StoreError::ActorClosed)?
    }

    pub async fn release_lease(&self, token: FencingToken) -> StoreResult<bool> {
        let bytes = encoded_len(&token)?;
        let (reply, receive) = oneshot::channel();
        self.enqueue(Request::ReleaseLease { token, reply }, bytes)
            .await?;
        receive.await.map_err(|_| StoreError::ActorClosed)?
    }

    pub async fn get_lease(
        &self,
        lease_key: impl Into<String>,
    ) -> StoreResult<Option<LeaseRecord>> {
        let lease_key = lease_key.into();
        let bytes = lease_key.len();
        let (reply, receive) = oneshot::channel();
        self.enqueue(Request::GetLease { lease_key, reply }, bytes)
            .await?;
        receive.await.map_err(|_| StoreError::ActorClosed)?
    }

    pub async fn commit_cursor(&self, cursor: ConsumerCursor) -> StoreResult<ConsumerCursor> {
        let bytes = encoded_len(&cursor)?;
        let (reply, receive) = oneshot::channel();
        self.enqueue(Request::CommitCursor { cursor, reply }, bytes)
            .await?;
        receive.await.map_err(|_| StoreError::ActorClosed)?
    }

    pub async fn get_cursor(
        &self,
        consumer_id: impl Into<String>,
    ) -> StoreResult<Option<ConsumerCursor>> {
        let consumer_id = consumer_id.into();
        let bytes = consumer_id.len();
        let (reply, receive) = oneshot::channel();
        self.enqueue(Request::GetCursor { consumer_id, reply }, bytes)
            .await?;
        receive.await.map_err(|_| StoreError::ActorClosed)?
    }

    pub async fn enqueue_outbox(
        &self,
        entry: NewOutboxEntry,
        fence: Option<FencingToken>,
    ) -> StoreResult<RelayOutboxEntry> {
        let bytes = encoded_len(&entry)? + encoded_len(&fence)?;
        let (reply, receive) = oneshot::channel();
        self.enqueue(
            Request::EnqueueOutbox {
                entry,
                fence,
                reply,
            },
            bytes,
        )
        .await?;
        receive.await.map_err(|_| StoreError::ActorClosed)?
    }

    pub async fn replay_outbox(
        &self,
        peer_id: impl Into<String>,
        after_sequence: u64,
        limit: usize,
    ) -> StoreResult<Vec<RelayOutboxEntry>> {
        let peer_id = peer_id.into();
        let bytes = peer_id.len();
        let (reply, receive) = oneshot::channel();
        self.enqueue(
            Request::ReplayOutbox {
                peer_id,
                after: after_sequence,
                limit: bounded_limit(limit),
                reply,
            },
            bytes,
        )
        .await?;
        receive.await.map_err(|_| StoreError::ActorClosed)?
    }

    pub async fn ack_outbox(
        &self,
        peer_id: impl Into<String>,
        through_sequence: u64,
        fence: Option<FencingToken>,
    ) -> StoreResult<u64> {
        let peer_id = peer_id.into();
        let bytes = peer_id.len() + encoded_len(&fence)?;
        let (reply, receive) = oneshot::channel();
        self.enqueue(
            Request::AckOutbox {
                peer_id,
                through: through_sequence,
                fence,
                reply,
            },
            bytes,
        )
        .await?;
        receive.await.map_err(|_| StoreError::ActorClosed)?
    }

    pub async fn checkpoint(&self) -> StoreResult<()> {
        let (reply, receive) = oneshot::channel();
        self.enqueue(Request::Checkpoint { reply }, 1).await?;
        receive.await.map_err(|_| StoreError::ActorClosed)?
    }

    async fn enqueue(&self, request: Request, encoded_bytes: usize) -> StoreResult<()> {
        let encoded_bytes = encoded_bytes.max(1);
        if encoded_bytes > self.inner.max_request_bytes {
            return Err(StoreError::RequestTooLarge {
                actual: encoded_bytes,
                maximum: self.inner.max_request_bytes,
            });
        }
        let permits = u32::try_from(encoded_bytes).map_err(|_| StoreError::RequestTooLarge {
            actual: encoded_bytes,
            maximum: self.inner.max_request_bytes,
        })?;
        let permit = self
            .inner
            .byte_budget
            .clone()
            .acquire_many_owned(permits)
            .await
            .map_err(|_| StoreError::ActorClosed)?;
        self.inner
            .sender
            .send(QueuedRequest {
                request,
                _byte_permit: permit,
            })
            .await
            .map_err(|_| StoreError::ActorClosed)
    }
}

struct QueuedRequest {
    request: Request,
    _byte_permit: tokio::sync::OwnedSemaphorePermit,
}

enum Request {
    BeginEngineEpoch {
        epoch: NewEngineEpoch,
        reply: oneshot::Sender<StoreResult<EngineEpoch>>,
    },
    CurrentEngineEpoch {
        engine_id: String,
        reply: oneshot::Sender<StoreResult<Option<EngineEpoch>>>,
    },
    AcceptCommand {
        command: CommandRequest,
        fence: Option<FencingToken>,
        reply: oneshot::Sender<StoreResult<CommandAcceptance>>,
    },
    GetCommand {
        command_id: String,
        reply: oneshot::Sender<StoreResult<Option<CommandRecord>>>,
    },
    GetCommandAlias {
        relay_command_id: String,
        reply: oneshot::Sender<StoreResult<Option<CommandAlias>>>,
    },
    RecordCommandReceipt {
        receipt: CommandReceipt,
        observed_at: i64,
        fence: Option<FencingToken>,
        reply: oneshot::Sender<StoreResult<CommandMutation>>,
    },
    MaterializeEngineCommandState {
        engine_command_id: String,
        state: CommandState,
        engine_updated_at: i64,
        error: Option<String>,
        event: NewEvent,
        fence: Option<FencingToken>,
        reply: oneshot::Sender<StoreResult<CommandAliasMaterialization>>,
    },
    PendingCommands {
        limit: usize,
        reply: oneshot::Sender<StoreResult<Vec<CommandRecord>>>,
    },
    TransitionCommand {
        transition: CommandTransition,
        fence: Option<FencingToken>,
        reply: oneshot::Sender<StoreResult<CommandMutation>>,
    },
    AppendEvent {
        event: NewEvent,
        fence: Option<FencingToken>,
        reply: oneshot::Sender<StoreResult<DurableEvent>>,
    },
    ReplayEvents {
        after: u64,
        limit: usize,
        reply: oneshot::Sender<StoreResult<Vec<DurableEvent>>>,
    },
    ReplaySessionEvents {
        session_id: String,
        after: u64,
        limit: usize,
        reply: oneshot::Sender<StoreResult<Vec<DurableEvent>>>,
    },
    UpsertSession {
        session: SessionSummary,
        fence: Option<FencingToken>,
        reply: oneshot::Sender<StoreResult<StoredSession>>,
    },
    UpsertSessionWithEvent {
        session: SessionSummary,
        event: NewEvent,
        fence: Option<FencingToken>,
        reply: oneshot::Sender<StoreResult<SessionEventMutation>>,
    },
    GetSession {
        session_id: String,
        reply: oneshot::Sender<StoreResult<Option<StoredSession>>>,
    },
    ListSessions {
        reply: oneshot::Sender<StoreResult<Vec<StoredSession>>>,
    },
    StateSnapshot {
        include_messages: bool,
        authority_scope: Option<String>,
        reply: oneshot::Sender<StoreResult<StoreStateSnapshot>>,
    },
    DeleteSession {
        session_id: String,
        fence: Option<FencingToken>,
        reply: oneshot::Sender<StoreResult<bool>>,
    },
    DeleteSessionWithEvent {
        session_id: String,
        event: NewEvent,
        fence: Option<FencingToken>,
        reply: oneshot::Sender<StoreResult<DeleteSessionEventMutation>>,
    },
    UpsertMessage {
        mutation: MessageMutation,
        fence: Option<FencingToken>,
        reply: oneshot::Sender<StoreResult<StoredMessage>>,
    },
    UpsertMessageWithEvent {
        mutation: MessageMutation,
        event: NewEvent,
        fence: Option<FencingToken>,
        reply: oneshot::Sender<StoreResult<MessageEventMutation>>,
    },
    ListMessages {
        session_id: String,
        reply: oneshot::Sender<StoreResult<Vec<StoredMessage>>>,
    },
    ReplaceModels {
        catalog: ModelCatalog,
        fence: Option<FencingToken>,
        reply: oneshot::Sender<StoreResult<ModelCatalog>>,
    },
    ReplaceModelsWithEvent {
        catalog: ModelCatalog,
        event: NewEvent,
        fence: Option<FencingToken>,
        reply: oneshot::Sender<StoreResult<ModelCatalogEventMutation>>,
    },
    GetModels {
        reply: oneshot::Sender<StoreResult<Option<ModelCatalog>>>,
    },
    PutSnapshot {
        scope: String,
        snapshot: AuthoritativeSnapshot,
        fence: Option<FencingToken>,
        reply: oneshot::Sender<StoreResult<StoredSnapshot>>,
    },
    GetSnapshot {
        scope: String,
        reply: oneshot::Sender<StoreResult<Option<StoredSnapshot>>>,
    },
    AcquireLease {
        request: LeaseRequest,
        reply: oneshot::Sender<StoreResult<LeaseRecord>>,
    },
    RenewLease {
        token: FencingToken,
        ttl_millis: i64,
        reply: oneshot::Sender<StoreResult<LeaseRecord>>,
    },
    ReleaseLease {
        token: FencingToken,
        reply: oneshot::Sender<StoreResult<bool>>,
    },
    GetLease {
        lease_key: String,
        reply: oneshot::Sender<StoreResult<Option<LeaseRecord>>>,
    },
    CommitCursor {
        cursor: ConsumerCursor,
        reply: oneshot::Sender<StoreResult<ConsumerCursor>>,
    },
    GetCursor {
        consumer_id: String,
        reply: oneshot::Sender<StoreResult<Option<ConsumerCursor>>>,
    },
    EnqueueOutbox {
        entry: NewOutboxEntry,
        fence: Option<FencingToken>,
        reply: oneshot::Sender<StoreResult<RelayOutboxEntry>>,
    },
    ReplayOutbox {
        peer_id: String,
        after: u64,
        limit: usize,
        reply: oneshot::Sender<StoreResult<Vec<RelayOutboxEntry>>>,
    },
    AckOutbox {
        peer_id: String,
        through: u64,
        fence: Option<FencingToken>,
        reply: oneshot::Sender<StoreResult<u64>>,
    },
    Checkpoint {
        reply: oneshot::Sender<StoreResult<()>>,
    },
}

fn actor_loop(mut connection: Connection, mut receiver: mpsc::Receiver<QueuedRequest>) {
    while let Some(queued) = receiver.blocking_recv() {
        match queued.request {
            Request::BeginEngineEpoch { epoch, reply } => {
                let _ = reply.send(begin_engine_epoch(&mut connection, epoch));
            }
            Request::CurrentEngineEpoch { engine_id, reply } => {
                let _ = reply.send(current_engine_epoch(&connection, &engine_id));
            }
            Request::AcceptCommand {
                command,
                fence,
                reply,
            } => {
                let _ = reply.send(accept_command(&mut connection, command, fence.as_ref()));
            }
            Request::GetCommand { command_id, reply } => {
                let _ = reply.send(get_command(&connection, &command_id));
            }
            Request::GetCommandAlias {
                relay_command_id,
                reply,
            } => {
                let _ = reply.send(get_command_alias(&connection, &relay_command_id));
            }
            Request::RecordCommandReceipt {
                receipt,
                observed_at,
                fence,
                reply,
            } => {
                let _ = reply.send(record_command_receipt(
                    &mut connection,
                    receipt,
                    observed_at,
                    fence.as_ref(),
                ));
            }
            Request::MaterializeEngineCommandState {
                engine_command_id,
                state,
                engine_updated_at,
                error,
                event,
                fence,
                reply,
            } => {
                let _ = reply.send(materialize_engine_command_state(
                    &mut connection,
                    &engine_command_id,
                    state,
                    engine_updated_at,
                    error,
                    event,
                    fence.as_ref(),
                ));
            }
            Request::PendingCommands { limit, reply } => {
                let _ = reply.send(pending_commands(&connection, limit));
            }
            Request::TransitionCommand {
                transition,
                fence,
                reply,
            } => {
                let _ = reply.send(transition_command(
                    &mut connection,
                    transition,
                    fence.as_ref(),
                ));
            }
            Request::AppendEvent {
                event,
                fence,
                reply,
            } => {
                let _ = reply.send(append_event(&mut connection, event, fence.as_ref()));
            }
            Request::ReplayEvents {
                after,
                limit,
                reply,
            } => {
                let _ = reply.send(replay_events(&connection, after, limit));
            }
            Request::ReplaySessionEvents {
                session_id,
                after,
                limit,
                reply,
            } => {
                let _ = reply.send(replay_session_events(
                    &connection,
                    &session_id,
                    after,
                    limit,
                ));
            }
            Request::UpsertSession {
                session,
                fence,
                reply,
            } => {
                let _ = reply.send(upsert_session(&mut connection, session, fence.as_ref()));
            }
            Request::UpsertSessionWithEvent {
                session,
                event,
                fence,
                reply,
            } => {
                let _ = reply.send(upsert_session_with_event(
                    &mut connection,
                    session,
                    event,
                    fence.as_ref(),
                ));
            }
            Request::GetSession { session_id, reply } => {
                let _ = reply.send(get_session(&connection, &session_id));
            }
            Request::ListSessions { reply } => {
                let _ = reply.send(list_sessions(&connection));
            }
            Request::StateSnapshot {
                include_messages,
                authority_scope,
                reply,
            } => {
                let _ = reply.send(state_snapshot(
                    &mut connection,
                    include_messages,
                    authority_scope.as_deref(),
                ));
            }
            Request::DeleteSession {
                session_id,
                fence,
                reply,
            } => {
                let _ = reply.send(delete_session(&mut connection, &session_id, fence.as_ref()));
            }
            Request::DeleteSessionWithEvent {
                session_id,
                event,
                fence,
                reply,
            } => {
                let _ = reply.send(delete_session_with_event(
                    &mut connection,
                    &session_id,
                    event,
                    fence.as_ref(),
                ));
            }
            Request::UpsertMessage {
                mutation,
                fence,
                reply,
            } => {
                let _ = reply.send(upsert_message(&mut connection, mutation, fence.as_ref()));
            }
            Request::UpsertMessageWithEvent {
                mutation,
                event,
                fence,
                reply,
            } => {
                let _ = reply.send(upsert_message_with_event(
                    &mut connection,
                    mutation,
                    event,
                    fence.as_ref(),
                ));
            }
            Request::ListMessages { session_id, reply } => {
                let _ = reply.send(list_messages(&connection, &session_id));
            }
            Request::ReplaceModels {
                catalog,
                fence,
                reply,
            } => {
                let _ = reply.send(replace_models(&mut connection, catalog, fence.as_ref()));
            }
            Request::ReplaceModelsWithEvent {
                catalog,
                event,
                fence,
                reply,
            } => {
                let _ = reply.send(replace_models_with_event(
                    &mut connection,
                    catalog,
                    event,
                    fence.as_ref(),
                ));
            }
            Request::GetModels { reply } => {
                let _ = reply.send(get_models(&connection));
            }
            Request::PutSnapshot {
                scope,
                snapshot,
                fence,
                reply,
            } => {
                let _ = reply.send(put_snapshot(
                    &mut connection,
                    &scope,
                    snapshot,
                    fence.as_ref(),
                ));
            }
            Request::GetSnapshot { scope, reply } => {
                let _ = reply.send(get_snapshot(&connection, &scope));
            }
            Request::AcquireLease { request, reply } => {
                let _ = reply.send(acquire_lease(&mut connection, request));
            }
            Request::RenewLease {
                token,
                ttl_millis,
                reply,
            } => {
                let _ = reply.send(renew_lease(&mut connection, &token, ttl_millis));
            }
            Request::ReleaseLease { token, reply } => {
                let _ = reply.send(release_lease(&mut connection, &token));
            }
            Request::GetLease { lease_key, reply } => {
                let _ = reply.send(get_lease(&connection, &lease_key));
            }
            Request::CommitCursor { cursor, reply } => {
                let _ = reply.send(commit_cursor(&mut connection, cursor));
            }
            Request::GetCursor { consumer_id, reply } => {
                let _ = reply.send(get_cursor(&connection, &consumer_id));
            }
            Request::EnqueueOutbox {
                entry,
                fence,
                reply,
            } => {
                let _ = reply.send(enqueue_outbox(&mut connection, entry, fence.as_ref()));
            }
            Request::ReplayOutbox {
                peer_id,
                after,
                limit,
                reply,
            } => {
                let _ = reply.send(replay_outbox(&connection, &peer_id, after, limit));
            }
            Request::AckOutbox {
                peer_id,
                through,
                fence,
                reply,
            } => {
                let _ = reply.send(ack_outbox(
                    &mut connection,
                    &peer_id,
                    through,
                    fence.as_ref(),
                ));
            }
            Request::Checkpoint { reply } => {
                let _ = reply.send(checkpoint(&connection));
            }
        }
    }
}

fn validate_config(config: &StoreConfig) -> StoreResult<()> {
    if config.queue_capacity == 0 {
        return Err(StoreError::InvalidConfig(
            "queue_capacity must be greater than zero".to_owned(),
        ));
    }
    if config.queue_byte_capacity == 0 || config.queue_byte_capacity > u32::MAX as usize {
        return Err(StoreError::InvalidConfig(format!(
            "queue_byte_capacity must be between 1 and {}",
            u32::MAX
        )));
    }
    if config.max_request_bytes == 0
        || config.max_request_bytes > config.queue_byte_capacity
        || config.max_request_bytes > u32::MAX as usize
    {
        return Err(StoreError::InvalidConfig(
            "max_request_bytes must fit inside queue_byte_capacity".to_owned(),
        ));
    }
    Ok(())
}

fn open_connection(config: &StoreConfig) -> StoreResult<(Connection, StoreMetadata)> {
    let sqlite_number = rusqlite::version_number();
    if sqlite_number < MINIMUM_SQLITE_VERSION_NUMBER {
        return Err(StoreError::SqliteTooOld {
            found: rusqlite::version().to_owned(),
            required: MINIMUM_SQLITE_VERSION,
        });
    }

    if config.path != Path::new(":memory:")
        && let Some(parent) = config.path.parent()
        && !parent.as_os_str().is_empty()
    {
        std::fs::create_dir_all(parent)?;
    }

    let mut connection = Connection::open(&config.path)?;
    connection.busy_timeout(config.busy_timeout)?;
    connection.pragma_update(None, "foreign_keys", "ON")?;
    connection.pragma_update(None, "synchronous", "FULL")?;
    connection.pragma_update(None, "wal_autocheckpoint", 1000_i64)?;
    connection.pragma_update(None, "journal_size_limit", 64_i64 * 1024 * 1024)?;
    let journal_mode: String =
        connection.query_row("PRAGMA journal_mode=WAL", [], |row| row.get(0))?;
    if config.path != Path::new(":memory:") && !journal_mode.eq_ignore_ascii_case("wal") {
        return Err(StoreError::Invariant(format!(
            "expected WAL journal mode, received {journal_mode}"
        )));
    }
    migrate(&mut connection)?;
    normalize_session_summaries(&connection)?;
    connection.execute(
        "INSERT INTO metadata(key, value) VALUES ('sqliteVersion', ?1)\
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        [rusqlite::version()],
    )?;

    let synchronous_level: i64 =
        connection.query_row("PRAGMA synchronous", [], |row| row.get(0))?;
    if synchronous_level != 2 {
        return Err(StoreError::Invariant(format!(
            "expected synchronous=FULL (2), received {synchronous_level}"
        )));
    }
    Ok((
        connection,
        StoreMetadata {
            schema_version: STORE_SCHEMA_VERSION,
            sqlite_version: rusqlite::version().to_owned(),
            journal_mode,
            synchronous: "FULL".to_owned(),
        },
    ))
}

fn migrate(connection: &mut Connection) -> StoreResult<()> {
    let current: u32 = connection.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    if current > STORE_SCHEMA_VERSION {
        return Err(StoreError::SchemaTooNew {
            found: current,
            supported: STORE_SCHEMA_VERSION,
        });
    }
    if current == STORE_SCHEMA_VERSION {
        return Ok(());
    }

    if current == 1 {
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        transaction.execute_batch(
            "CREATE TABLE command_aliases (
                relay_command_id TEXT PRIMARY KEY
                    REFERENCES commands(command_id) ON DELETE CASCADE,
                engine_command_id TEXT NOT NULL,
                idempotency_key TEXT NOT NULL,
                engine_state TEXT NOT NULL,
                engine_updated_at INTEGER NOT NULL,
                error TEXT,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            ) STRICT;

            CREATE INDEX command_aliases_engine_command_idx
                ON command_aliases(engine_command_id, relay_command_id);",
        )?;
        transaction.pragma_update(None, "user_version", STORE_SCHEMA_VERSION)?;
        transaction.commit()?;
        return Ok(());
    }

    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    transaction.execute_batch(
        "CREATE TABLE metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        ) STRICT;

        CREATE TABLE counters (
            scope TEXT PRIMARY KEY,
            value INTEGER NOT NULL CHECK (value >= 0)
        ) STRICT;

        CREATE TABLE engine_epochs (
            engine_id TEXT NOT NULL,
            epoch INTEGER NOT NULL CHECK (epoch > 0),
            started_at INTEGER NOT NULL,
            app_server_version TEXT NOT NULL,
            capability_hash TEXT NOT NULL,
            schema_hash TEXT,
            PRIMARY KEY (engine_id, epoch)
        ) STRICT;

        CREATE TABLE sessions (
            session_id TEXT PRIMARY KEY,
            revision INTEGER NOT NULL CHECK (revision > 0),
            updated_at INTEGER NOT NULL,
            session_json TEXT NOT NULL
        ) STRICT;

        CREATE INDEX sessions_updated_at_idx
            ON sessions(updated_at DESC, session_id);

        CREATE TABLE messages (
            session_id TEXT NOT NULL,
            message_id TEXT NOT NULL,
            revision INTEGER NOT NULL CHECK (revision >= 0),
            updated_at INTEGER NOT NULL,
            is_final INTEGER NOT NULL CHECK (is_final IN (0, 1)),
            message_json TEXT NOT NULL,
            PRIMARY KEY (session_id, message_id)
        ) STRICT;

        CREATE INDEX messages_session_time_idx
            ON messages(session_id, updated_at, message_id);

        CREATE TABLE commands (
            command_id TEXT PRIMARY KEY,
            idempotency_key TEXT NOT NULL UNIQUE,
            session_id TEXT,
            kind TEXT NOT NULL,
            command_json TEXT NOT NULL,
            state TEXT NOT NULL,
            requested_at INTEGER NOT NULL,
            accepted_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            trace_id TEXT,
            lease_generation INTEGER,
            error TEXT
        ) STRICT;

        CREATE INDEX commands_pending_idx
            ON commands(state, accepted_at, command_id);

        CREATE TABLE command_aliases (
            relay_command_id TEXT PRIMARY KEY
                REFERENCES commands(command_id) ON DELETE CASCADE,
            engine_command_id TEXT NOT NULL,
            idempotency_key TEXT NOT NULL,
            engine_state TEXT NOT NULL,
            engine_updated_at INTEGER NOT NULL,
            error TEXT,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        ) STRICT;

        CREATE INDEX command_aliases_engine_command_idx
            ON command_aliases(engine_command_id, relay_command_id);

        CREATE TABLE events (
            event_id TEXT PRIMARY KEY,
            global_sequence INTEGER NOT NULL UNIQUE CHECK (global_sequence > 0),
            session_sequence INTEGER CHECK (session_sequence > 0),
            session_id TEXT,
            command_id TEXT,
            process_epoch INTEGER,
            kind TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            CHECK ((session_id IS NULL) = (session_sequence IS NULL)),
            UNIQUE (session_id, session_sequence)
        ) STRICT;

        CREATE INDEX events_session_replay_idx
            ON events(session_id, session_sequence);

        CREATE INDEX events_command_idx
            ON events(command_id, global_sequence);

        CREATE TABLE model_catalogs (
            scope TEXT PRIMARY KEY,
            observed_at INTEGER NOT NULL,
            catalog_json TEXT NOT NULL
        ) STRICT;

        CREATE TABLE snapshots (
            scope TEXT PRIMARY KEY,
            version INTEGER NOT NULL CHECK (version > 0),
            global_sequence INTEGER NOT NULL CHECK (global_sequence >= 0),
            created_at INTEGER NOT NULL,
            snapshot_json TEXT NOT NULL
        ) STRICT;

        CREATE TABLE leases (
            lease_key TEXT PRIMARY KEY,
            holder_id TEXT NOT NULL,
            generation INTEGER NOT NULL CHECK (generation > 0),
            acquired_at INTEGER NOT NULL,
            expires_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        ) STRICT;

        CREATE TABLE consumer_cursors (
            consumer_id TEXT PRIMARY KEY,
            global_sequence INTEGER NOT NULL CHECK (global_sequence >= 0),
            updated_at INTEGER NOT NULL
        ) STRICT;

        CREATE TABLE relay_outbox (
            peer_id TEXT NOT NULL,
            sequence INTEGER NOT NULL CHECK (sequence > 0),
            frame_json TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            PRIMARY KEY (peer_id, sequence)
        ) STRICT;

        CREATE INDEX relay_outbox_replay_idx
            ON relay_outbox(peer_id, sequence);
        ",
    )?;
    transaction.pragma_update(None, "user_version", STORE_SCHEMA_VERSION)?;
    transaction.commit()?;
    Ok(())
}

fn normalize_session_summaries(connection: &Connection) -> StoreResult<()> {
    connection.execute(
        "UPDATE sessions
         SET session_json = json_set(session_json, '$.managedByFermin', json('false'))
         WHERE json_type(session_json, '$.managedByFermin') IS NULL",
        [],
    )?;
    connection.execute(
        "UPDATE sessions
         SET session_json = json_set(session_json, '$.messages', json('[]'))
         WHERE json_array_length(json_extract(session_json, '$.messages')) > 0",
        [],
    )?;
    Ok(())
}

fn begin_engine_epoch(
    connection: &mut Connection,
    input: NewEngineEpoch,
) -> StoreResult<EngineEpoch> {
    require_nonempty("engine_id", &input.engine_id)?;
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let epoch = next_counter(&transaction, &format!("engine:{}", input.engine_id))?;
    transaction.execute(
        "INSERT INTO engine_epochs(engine_id, epoch, started_at, app_server_version, capability_hash, schema_hash)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        params![
            input.engine_id,
            to_i64(epoch)?,
            input.started_at,
            input.app_server_version,
            input.capability_hash,
            input.schema_hash,
        ],
    )?;
    transaction.commit()?;
    Ok(EngineEpoch {
        engine_id: input.engine_id,
        epoch,
        started_at: input.started_at,
        app_server_version: input.app_server_version,
        capability_hash: input.capability_hash,
        schema_hash: input.schema_hash,
    })
}

fn current_engine_epoch(
    connection: &Connection,
    engine_id: &str,
) -> StoreResult<Option<EngineEpoch>> {
    let value = connection
        .query_row(
            "SELECT engine_id, epoch, started_at, app_server_version, capability_hash, schema_hash
             FROM engine_epochs WHERE engine_id = ?1 ORDER BY epoch DESC LIMIT 1",
            [engine_id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, String>(4)?,
                    row.get::<_, Option<String>>(5)?,
                ))
            },
        )
        .optional()?;
    value
        .map(
            |(engine_id, epoch, started_at, app_server_version, capability_hash, schema_hash)| {
                Ok(EngineEpoch {
                    engine_id,
                    epoch: to_u64(epoch)?,
                    started_at,
                    app_server_version,
                    capability_hash,
                    schema_hash,
                })
            },
        )
        .transpose()
}

fn accept_command(
    connection: &mut Connection,
    request: CommandRequest,
    fence: Option<&FencingToken>,
) -> StoreResult<CommandAcceptance> {
    require_nonempty("idempotency_key", &request.idempotency_key)?;
    let command_json = serde_json::to_string(&request.command)?;
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    validate_fence(&transaction, fence)?;
    if let Some(existing) = query_command_by_idempotency(&transaction, &request.idempotency_key)? {
        let existing_json = serde_json::to_string(&existing.command)?;
        if existing.session_id != request.session_id
            || existing_json != command_json
            || idempotency_trace_identity(existing.trace_id.as_deref())
                != idempotency_trace_identity(request.trace_id.as_deref())
        {
            return Err(StoreError::IdempotencyConflict {
                key: request.idempotency_key,
            });
        }
        transaction.commit()?;
        return Ok(CommandAcceptance {
            inserted: false,
            command: existing,
        });
    }

    let command_id = request
        .command_id
        .unwrap_or_else(|| Uuid::now_v7().to_string());
    require_nonempty("command_id", &command_id)?;
    let state = CommandState::Accepted;
    transaction.execute(
        "INSERT INTO commands(
            command_id, idempotency_key, session_id, kind, command_json, state,
            requested_at, accepted_at, updated_at, trace_id, lease_generation, error
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7, ?7, ?8, ?9, NULL)",
        params![
            command_id,
            request.idempotency_key,
            request.session_id,
            request.command.name(),
            command_json,
            state.as_str(),
            request.requested_at,
            request.trace_id,
            fence.map(|value| to_i64(value.generation)).transpose()?,
        ],
    )?;
    let record = CommandRecord {
        command_id,
        idempotency_key: request.idempotency_key,
        session_id: request.session_id,
        command: request.command,
        state,
        requested_at: request.requested_at,
        accepted_at: request.requested_at,
        updated_at: request.requested_at,
        trace_id: request.trace_id,
        lease_generation: fence.map(|value| value.generation),
        error: None,
    };
    transaction.commit()?;
    Ok(CommandAcceptance {
        inserted: true,
        command: record,
    })
}

fn get_command(connection: &Connection, command_id: &str) -> StoreResult<Option<CommandRecord>> {
    query_command(connection, "command_id = ?1", command_id)
}

fn get_command_alias(
    connection: &Connection,
    relay_command_id: &str,
) -> StoreResult<Option<CommandAlias>> {
    connection
        .query_row(
            "SELECT relay_command_id, engine_command_id, idempotency_key, engine_state,
                    engine_updated_at, error, created_at, updated_at
             FROM command_aliases WHERE relay_command_id = ?1",
            [relay_command_id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, i64>(4)?,
                    row.get::<_, Option<String>>(5)?,
                    row.get::<_, i64>(6)?,
                    row.get::<_, i64>(7)?,
                ))
            },
        )
        .optional()?
        .map(command_alias_from_tuple)
        .transpose()
}

type CommandAliasTuple = (
    String,
    String,
    String,
    String,
    i64,
    Option<String>,
    i64,
    i64,
);

fn command_alias_from_tuple(tuple: CommandAliasTuple) -> StoreResult<CommandAlias> {
    Ok(CommandAlias {
        relay_command_id: tuple.0,
        engine_command_id: tuple.1,
        idempotency_key: tuple.2,
        engine_state: command_state_from_str(&tuple.3)?,
        engine_updated_at: tuple.4,
        error: tuple.5,
        created_at: tuple.6,
        updated_at: tuple.7,
    })
}

fn query_command_aliases_by_engine(
    connection: &Connection,
    engine_command_id: &str,
) -> StoreResult<Vec<CommandAlias>> {
    let mut statement = connection.prepare(
        "SELECT relay_command_id, engine_command_id, idempotency_key, engine_state,
                engine_updated_at, error, created_at, updated_at
         FROM command_aliases
         WHERE engine_command_id = ?1
         ORDER BY relay_command_id",
    )?;
    let rows = statement.query_map([engine_command_id], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, String>(2)?,
            row.get::<_, String>(3)?,
            row.get::<_, i64>(4)?,
            row.get::<_, Option<String>>(5)?,
            row.get::<_, i64>(6)?,
            row.get::<_, i64>(7)?,
        ))
    })?;
    rows.map(|row| command_alias_from_tuple(row?)).collect()
}

fn record_command_receipt(
    connection: &mut Connection,
    receipt: CommandReceipt,
    observed_at: i64,
    fence: Option<&FencingToken>,
) -> StoreResult<CommandMutation> {
    require_nonempty("relay_command_id", &receipt.relay_command_id)?;
    require_nonempty("engine_command_id", &receipt.engine_command_id)?;
    require_nonempty("idempotency_key", &receipt.idempotency_key)?;
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    validate_fence(&transaction, fence)?;
    let mut command = query_command(&transaction, "command_id = ?1", &receipt.relay_command_id)?
        .ok_or_else(|| StoreError::CommandNotFound {
            command_id: receipt.relay_command_id.clone(),
        })?;
    if command.idempotency_key != receipt.idempotency_key {
        return Err(StoreError::CommandAliasConflict {
            relay_command_id: receipt.relay_command_id,
        });
    }

    let existing = get_command_alias(&transaction, &command.command_id)?;
    if existing.as_ref().is_some_and(|alias| {
        alias.engine_command_id != receipt.engine_command_id
            || alias.idempotency_key != receipt.idempotency_key
    }) {
        return Err(StoreError::CommandAliasConflict {
            relay_command_id: command.command_id,
        });
    }
    let should_update = existing
        .as_ref()
        .is_none_or(|alias| engine_observation_is_fresh(alias, receipt.state, receipt.updated_at));
    let alias = if should_update {
        let created_at = existing
            .as_ref()
            .map_or(observed_at, |alias| alias.created_at);
        transaction.execute(
            "INSERT INTO command_aliases(
                relay_command_id, engine_command_id, idempotency_key, engine_state,
                engine_updated_at, error, created_at, updated_at
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
             ON CONFLICT(relay_command_id) DO UPDATE SET
                engine_state = excluded.engine_state,
                engine_updated_at = excluded.engine_updated_at,
                error = excluded.error,
                updated_at = excluded.updated_at",
            params![
                command.command_id,
                receipt.engine_command_id,
                receipt.idempotency_key,
                receipt.state.as_str(),
                receipt.updated_at,
                receipt.error,
                created_at,
                observed_at,
            ],
        )?;
        CommandAlias {
            relay_command_id: command.command_id.clone(),
            engine_command_id: receipt.engine_command_id,
            idempotency_key: command.idempotency_key.clone(),
            engine_state: receipt.state,
            engine_updated_at: receipt.updated_at,
            error: receipt.error,
            created_at,
            updated_at: observed_at,
        }
    } else {
        existing.expect("existing alias checked above")
    };

    let changed = materialize_relay_command(
        &transaction,
        &mut command,
        alias.engine_state,
        alias.error.clone(),
        observed_at,
    )?;
    let event = if changed {
        Some(append_event_in_transaction(
            &transaction,
            NewEvent {
                event_id: Some(format!(
                    "engine-receipt:{}:{}:{}:{}",
                    command.command_id,
                    alias.engine_command_id,
                    alias.engine_state.as_str(),
                    alias.engine_updated_at,
                )),
                session_id: command.session_id.clone(),
                command_id: Some(command.command_id.clone()),
                process_epoch: None,
                kind: EventKind::CommandStateChanged,
                payload: serde_json::json!({
                    "commandId": command.command_id,
                    "canonicalCommandId": alias.engine_command_id,
                    "state": command.state,
                    "error": command.error,
                    "receipt": true,
                }),
                created_at: observed_at,
            },
        )?)
    } else {
        None
    };
    transaction.commit()?;
    Ok(CommandMutation { command, event })
}

fn materialize_engine_command_state(
    connection: &mut Connection,
    engine_command_id: &str,
    state: CommandState,
    engine_updated_at: i64,
    error: Option<String>,
    event: NewEvent,
    fence: Option<&FencingToken>,
) -> StoreResult<CommandAliasMaterialization> {
    require_nonempty("engine_command_id", engine_command_id)?;
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    validate_fence(&transaction, fence)?;
    let aliases = query_command_aliases_by_engine(&transaction, engine_command_id)?;
    let matched_aliases = aliases.len();
    let mut mutations = Vec::with_capacity(matched_aliases);
    for mut alias in aliases {
        if engine_observation_is_fresh(&alias, state, engine_updated_at) {
            transaction.execute(
                "UPDATE command_aliases
                 SET engine_state = ?2, engine_updated_at = ?3, error = ?4, updated_at = ?5
                 WHERE relay_command_id = ?1",
                params![
                    alias.relay_command_id,
                    state.as_str(),
                    engine_updated_at,
                    error,
                    event.created_at,
                ],
            )?;
            alias.engine_state = state;
            alias.engine_updated_at = engine_updated_at;
            alias.error.clone_from(&error);
            alias.updated_at = event.created_at;
        }

        let mut command = query_command(&transaction, "command_id = ?1", &alias.relay_command_id)?
            .ok_or_else(|| StoreError::CommandNotFound {
                command_id: alias.relay_command_id.clone(),
            })?;
        let changed = materialize_relay_command(
            &transaction,
            &mut command,
            alias.engine_state,
            alias.error.clone(),
            event.created_at,
        )?;
        let durable_event = if changed {
            let mut relay_event = event.clone();
            relay_event.event_id = relay_event
                .event_id
                .map(|event_id| format!("{event_id}:relay:{}", command.command_id));
            relay_event.command_id = Some(command.command_id.clone());
            if relay_event.session_id.is_none() {
                relay_event.session_id.clone_from(&command.session_id);
            }
            if !relay_event.payload.is_object() {
                relay_event.payload = serde_json::json!({ "sourcePayload": relay_event.payload });
            }
            let payload = relay_event
                .payload
                .as_object_mut()
                .expect("payload converted to an object above");
            payload.insert(
                "commandId".to_owned(),
                serde_json::Value::String(command.command_id.clone()),
            );
            payload.insert(
                "canonicalCommandId".to_owned(),
                serde_json::Value::String(alias.engine_command_id.clone()),
            );
            payload.insert("state".to_owned(), serde_json::to_value(command.state)?);
            payload.insert(
                "error".to_owned(),
                command
                    .error
                    .clone()
                    .map_or(serde_json::Value::Null, serde_json::Value::String),
            );
            Some(append_event_in_transaction(&transaction, relay_event)?)
        } else {
            None
        };
        mutations.push(CommandMutation {
            command,
            event: durable_event,
        });
    }
    transaction.commit()?;
    Ok(CommandAliasMaterialization {
        matched_aliases,
        mutations,
    })
}

fn engine_observation_is_fresh(
    alias: &CommandAlias,
    incoming_state: CommandState,
    incoming_updated_at: i64,
) -> bool {
    if alias.engine_state.is_terminal() {
        return incoming_state == alias.engine_state
            && incoming_updated_at >= alias.engine_updated_at;
    }
    match command_state_rank(incoming_state).cmp(&command_state_rank(alias.engine_state)) {
        std::cmp::Ordering::Greater => true,
        std::cmp::Ordering::Less => false,
        std::cmp::Ordering::Equal => incoming_updated_at >= alias.engine_updated_at,
    }
}

fn materialize_relay_command(
    transaction: &Transaction<'_>,
    command: &mut CommandRecord,
    engine_state: CommandState,
    engine_error: Option<String>,
    observed_at: i64,
) -> StoreResult<bool> {
    let incoming_state = match engine_state {
        CommandState::Accepted | CommandState::Leased | CommandState::EngineDurable => {
            CommandState::EngineDurable
        }
        state => state,
    };
    let next_state = if command.state.is_terminal()
        || command_state_rank(incoming_state) < command_state_rank(command.state)
    {
        command.state
    } else {
        incoming_state
    };
    let next_error = if next_state == incoming_state
        && (incoming_state.is_terminal() || incoming_state == command.state)
    {
        engine_error
    } else {
        command.error.clone()
    };
    if next_state == command.state && next_error == command.error {
        return Ok(false);
    }
    let updated_at = command.updated_at.max(observed_at);
    transaction.execute(
        "UPDATE commands SET state = ?2, updated_at = ?3, error = ?4 WHERE command_id = ?1",
        params![
            command.command_id,
            next_state.as_str(),
            updated_at,
            next_error,
        ],
    )?;
    command.state = next_state;
    command.updated_at = updated_at;
    command.error = next_error;
    Ok(true)
}

fn command_state_rank(state: CommandState) -> u8 {
    match state {
        CommandState::Accepted => 0,
        CommandState::Leased => 1,
        CommandState::EngineDurable => 2,
        CommandState::SentToChild => 3,
        CommandState::Completed
        | CommandState::Failed
        | CommandState::Cancelled
        | CommandState::Unknown => 4,
    }
}

fn query_command_by_idempotency(
    connection: &Connection,
    idempotency_key: &str,
) -> StoreResult<Option<CommandRecord>> {
    query_command(connection, "idempotency_key = ?1", idempotency_key)
}

fn query_command(
    connection: &Connection,
    predicate: &str,
    value: &str,
) -> StoreResult<Option<CommandRecord>> {
    let sql = format!("SELECT {COMMAND_COLUMNS} FROM commands WHERE {predicate}");
    let raw = connection
        .query_row(&sql, [value], decode_command_tuple)
        .optional()?;
    raw.map(command_from_tuple).transpose()
}

type CommandTuple = (
    String,
    String,
    Option<String>,
    String,
    String,
    i64,
    i64,
    i64,
    Option<String>,
    Option<i64>,
    Option<String>,
);

fn decode_command_tuple(row: &rusqlite::Row<'_>) -> rusqlite::Result<CommandTuple> {
    Ok((
        row.get(0)?,
        row.get(1)?,
        row.get(2)?,
        row.get(3)?,
        row.get(4)?,
        row.get(5)?,
        row.get(6)?,
        row.get(7)?,
        row.get(8)?,
        row.get(9)?,
        row.get(10)?,
    ))
}

fn command_from_tuple(tuple: CommandTuple) -> StoreResult<CommandRecord> {
    Ok(CommandRecord {
        command_id: tuple.0,
        idempotency_key: tuple.1,
        session_id: tuple.2,
        command: serde_json::from_str(&tuple.3)?,
        state: command_state_from_str(&tuple.4)?,
        requested_at: tuple.5,
        accepted_at: tuple.6,
        updated_at: tuple.7,
        trace_id: tuple.8,
        lease_generation: tuple.9.map(to_u64).transpose()?,
        error: tuple.10,
    })
}

fn pending_commands(connection: &Connection, limit: usize) -> StoreResult<Vec<CommandRecord>> {
    let sql = format!(
        "SELECT {COMMAND_COLUMNS} FROM commands
         WHERE state IN ('accepted', 'leased', 'engineDurable', 'sentToChild')
         ORDER BY accepted_at, command_id LIMIT ?1"
    );
    let mut statement = connection.prepare(&sql)?;
    let rows = statement.query_map([to_i64(limit as u64)?], decode_command_tuple)?;
    rows.map(|row| command_from_tuple(row?)).collect()
}

fn transition_command(
    connection: &mut Connection,
    transition: CommandTransition,
    fence: Option<&FencingToken>,
) -> StoreResult<CommandMutation> {
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    validate_fence(&transaction, fence)?;
    let mut command = query_command(&transaction, "command_id = ?1", &transition.command_id)?
        .ok_or_else(|| StoreError::CommandNotFound {
            command_id: transition.command_id.clone(),
        })?;

    if let Some(expected) = transition.expected_state
        && command.state != expected
    {
        return Err(StoreError::CommandStateConflict {
            command_id: transition.command_id,
            expected,
            actual: command.state,
        });
    }
    if command.state != transition.new_state
        && !valid_command_transition(command.state, transition.new_state)
    {
        return Err(StoreError::InvalidCommandTransition {
            command_id: transition.command_id,
            from: command.state,
            to: transition.new_state,
        });
    }

    let lease_generation = fence
        .map(|value| value.generation)
        .or(command.lease_generation);
    transaction.execute(
        "UPDATE commands SET state = ?2, updated_at = ?3, lease_generation = ?4, error = ?5
         WHERE command_id = ?1",
        params![
            command.command_id,
            transition.new_state.as_str(),
            transition.updated_at,
            lease_generation.map(to_i64).transpose()?,
            transition.error,
        ],
    )?;
    command.state = transition.new_state;
    command.updated_at = transition.updated_at;
    command.lease_generation = lease_generation;
    command.error = transition.error;

    let event = if let Some(mut event) = transition.event {
        if event.command_id.is_none() {
            event.command_id = Some(command.command_id.clone());
        }
        if event.session_id.is_none() {
            event.session_id.clone_from(&command.session_id);
        }
        Some(append_event_in_transaction(&transaction, event)?)
    } else {
        None
    };
    transaction.commit()?;
    Ok(CommandMutation { command, event })
}

fn valid_command_transition(from: CommandState, to: CommandState) -> bool {
    use CommandState::{
        Accepted, Cancelled, Completed, EngineDurable, Failed, Leased, SentToChild, Unknown,
    };
    match from {
        Accepted => matches!(to, Leased | Failed | Cancelled),
        Leased => matches!(to, EngineDurable | Failed | Cancelled | Unknown),
        EngineDurable => matches!(to, SentToChild | Completed | Failed | Cancelled | Unknown),
        SentToChild => matches!(to, Completed | Failed | Cancelled | Unknown),
        Completed | Failed | Cancelled | Unknown => false,
    }
}

fn append_event(
    connection: &mut Connection,
    event: NewEvent,
    fence: Option<&FencingToken>,
) -> StoreResult<DurableEvent> {
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    validate_fence(&transaction, fence)?;
    let event = append_event_in_transaction(&transaction, event)?;
    transaction.commit()?;
    Ok(event)
}

fn append_event_in_transaction(
    transaction: &Transaction<'_>,
    mut input: NewEvent,
) -> StoreResult<DurableEvent> {
    let event_id = input
        .event_id
        .take()
        .unwrap_or_else(|| Uuid::now_v7().to_string());
    require_nonempty("event_id", &event_id)?;
    if let Some(existing) = query_event_by_id(transaction, &event_id)? {
        if event_matches_input(&existing, &input) {
            return Ok(existing);
        }
        return Err(StoreError::EventConflict { event_id });
    }

    let global_sequence = next_counter(transaction, "events:global")?;
    let session_sequence = input
        .session_id
        .as_ref()
        .map(|session_id| next_counter(transaction, &format!("events:session:{session_id}")))
        .transpose()?;
    let payload_json = serde_json::to_string(&input.payload)?;
    transaction.execute(
        "INSERT INTO events(
            event_id, global_sequence, session_sequence, session_id, command_id,
            process_epoch, kind, payload_json, created_at
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
        params![
            event_id,
            to_i64(global_sequence)?,
            session_sequence.map(to_i64).transpose()?,
            input.session_id,
            input.command_id,
            input.process_epoch.map(to_i64).transpose()?,
            input.kind.as_str(),
            payload_json,
            input.created_at,
        ],
    )?;
    Ok(DurableEvent {
        event_id,
        global_sequence,
        session_sequence,
        session_id: input.session_id,
        command_id: input.command_id,
        process_epoch: input.process_epoch,
        kind: input.kind,
        payload: input.payload,
        created_at: input.created_at,
    })
}

fn query_event_by_id(connection: &Connection, event_id: &str) -> StoreResult<Option<DurableEvent>> {
    let sql = format!("SELECT {EVENT_COLUMNS} FROM events WHERE event_id = ?1");
    let raw = connection
        .query_row(&sql, [event_id], decode_event_tuple)
        .optional()?;
    raw.map(event_from_tuple).transpose()
}

type EventTuple = (
    String,
    i64,
    Option<i64>,
    Option<String>,
    Option<String>,
    Option<i64>,
    String,
    String,
    i64,
);

fn decode_event_tuple(row: &rusqlite::Row<'_>) -> rusqlite::Result<EventTuple> {
    Ok((
        row.get(0)?,
        row.get(1)?,
        row.get(2)?,
        row.get(3)?,
        row.get(4)?,
        row.get(5)?,
        row.get(6)?,
        row.get(7)?,
        row.get(8)?,
    ))
}

fn event_from_tuple(tuple: EventTuple) -> StoreResult<DurableEvent> {
    Ok(DurableEvent {
        event_id: tuple.0,
        global_sequence: to_u64(tuple.1)?,
        session_sequence: tuple.2.map(to_u64).transpose()?,
        session_id: tuple.3,
        command_id: tuple.4,
        process_epoch: tuple.5.map(to_u64).transpose()?,
        kind: event_kind_from_str(&tuple.6)?,
        payload: serde_json::from_str(&tuple.7)?,
        created_at: tuple.8,
    })
}

fn event_matches_input(event: &DurableEvent, input: &NewEvent) -> bool {
    event.session_id == input.session_id
        && event.command_id == input.command_id
        && event.process_epoch == input.process_epoch
        && event.kind == input.kind
        && event.payload == input.payload
        && event.created_at == input.created_at
}

fn replay_events(
    connection: &Connection,
    after: u64,
    limit: usize,
) -> StoreResult<Vec<DurableEvent>> {
    let sql = format!(
        "SELECT {EVENT_COLUMNS} FROM events
         WHERE global_sequence > ?1 ORDER BY global_sequence LIMIT ?2"
    );
    let mut statement = connection.prepare(&sql)?;
    let rows = statement.query_map(
        params![to_i64(after)?, to_i64(limit as u64)?],
        decode_event_tuple,
    )?;
    rows.map(|row| event_from_tuple(row?)).collect()
}

fn replay_session_events(
    connection: &Connection,
    session_id: &str,
    after: u64,
    limit: usize,
) -> StoreResult<Vec<DurableEvent>> {
    let sql = format!(
        "SELECT {EVENT_COLUMNS} FROM events
         WHERE session_id = ?1 AND session_sequence > ?2
         ORDER BY session_sequence LIMIT ?3"
    );
    let mut statement = connection.prepare(&sql)?;
    let rows = statement.query_map(
        params![session_id, to_i64(after)?, to_i64(limit as u64)?],
        decode_event_tuple,
    )?;
    rows.map(|row| event_from_tuple(row?)).collect()
}

fn upsert_session(
    connection: &mut Connection,
    session: SessionSummary,
    fence: Option<&FencingToken>,
) -> StoreResult<StoredSession> {
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    validate_fence(&transaction, fence)?;
    let (stored, _) = upsert_session_in_transaction(&transaction, session)?;
    transaction.commit()?;
    Ok(stored)
}

fn upsert_session_with_event(
    connection: &mut Connection,
    session: SessionSummary,
    mut event: NewEvent,
    fence: Option<&FencingToken>,
) -> StoreResult<SessionEventMutation> {
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    validate_fence(&transaction, fence)?;
    let session_id = session.session_id.clone();
    let (stored, applied) = upsert_session_in_transaction(&transaction, session)?;
    let event = if applied {
        if event.session_id.is_none() {
            event.session_id = Some(session_id);
        }
        Some(append_event_in_transaction(&transaction, event)?)
    } else {
        None
    };
    transaction.commit()?;
    Ok(SessionEventMutation { stored, event })
}

fn upsert_session_in_transaction(
    transaction: &Transaction<'_>,
    mut session: SessionSummary,
) -> StoreResult<(StoredSession, bool)> {
    require_nonempty("session_id", &session.session_id)?;
    session.messages.clear();
    let session_json = serde_json::to_string(&session)?;
    if let Some((revision, existing_json)) = transaction
        .query_row(
            "SELECT revision, session_json FROM sessions WHERE session_id = ?1",
            [&session.session_id],
            |row| Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?)),
        )
        .optional()?
    {
        let revision = to_u64(revision)?;
        let existing_session = serde_json::from_str::<SessionSummary>(&existing_json)?;
        let mut comparable_existing = existing_session.clone();
        let mut comparable_incoming = session.clone();
        comparable_existing.messages.clear();
        comparable_incoming.messages.clear();
        if comparable_existing == comparable_incoming {
            return Ok((
                StoredSession {
                    session: existing_session,
                    revision,
                },
                false,
            ));
        }
        let next_revision = revision
            .checked_add(1)
            .ok_or_else(|| StoreError::Invariant("session revision overflow".to_owned()))?;
        transaction.execute(
            "UPDATE sessions SET revision = ?2, updated_at = ?3, session_json = ?4
             WHERE session_id = ?1",
            params![
                session.session_id,
                to_i64(next_revision)?,
                session.updated_at,
                session_json,
            ],
        )?;
        return Ok((
            StoredSession {
                session,
                revision: next_revision,
            },
            true,
        ));
    }

    transaction.execute(
        "INSERT INTO sessions(session_id, revision, updated_at, session_json)
         VALUES (?1, 1, ?2, ?3)",
        params![session.session_id, session.updated_at, session_json],
    )?;
    Ok((
        StoredSession {
            session,
            revision: 1,
        },
        true,
    ))
}

fn get_session(connection: &Connection, session_id: &str) -> StoreResult<Option<StoredSession>> {
    let raw = connection
        .query_row(
            "SELECT session_json, revision FROM sessions WHERE session_id = ?1",
            [session_id],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)),
        )
        .optional()?;
    raw.map(|(json, revision)| {
        Ok(StoredSession {
            session: serde_json::from_str(&json)?,
            revision: to_u64(revision)?,
        })
    })
    .transpose()
}

fn list_sessions(connection: &Connection) -> StoreResult<Vec<StoredSession>> {
    let mut statement = connection.prepare(
        "SELECT session_json, revision FROM sessions ORDER BY updated_at DESC, session_id",
    )?;
    let rows = statement.query_map([], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
    })?;
    rows.map(|row| {
        let (json, revision) = row?;
        Ok(StoredSession {
            session: serde_json::from_str(&json)?,
            revision: to_u64(revision)?,
        })
    })
    .collect()
}

fn state_snapshot(
    connection: &mut Connection,
    include_messages: bool,
    authority_scope: Option<&str>,
) -> StoreResult<StoreStateSnapshot> {
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Deferred)?;
    let mut sessions = list_sessions(&transaction)?;
    if include_messages {
        for stored in &mut sessions {
            stored.session.messages = list_messages(&transaction, &stored.session.session_id)?
                .into_iter()
                .map(|stored| stored.message)
                .collect();
            stored.session.message_count = stored.session.messages.len() as u64;
        }
    }
    let models = get_models(&transaction)?;
    let global_sequence = transaction.query_row(
        "SELECT COALESCE(MAX(global_sequence), 0) FROM events",
        [],
        |row| row.get::<_, i64>(0),
    )?;
    let authority = authority_scope
        .map(|scope| get_snapshot(&transaction, scope))
        .transpose()?
        .flatten();
    transaction.commit()?;
    Ok(StoreStateSnapshot {
        sessions,
        models,
        global_sequence: to_u64(global_sequence)?,
        authority,
    })
}

fn delete_session(
    connection: &mut Connection,
    session_id: &str,
    fence: Option<&FencingToken>,
) -> StoreResult<bool> {
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    validate_fence(&transaction, fence)?;
    let deleted = delete_session_in_transaction(&transaction, session_id)?;
    transaction.commit()?;
    Ok(deleted)
}

fn delete_session_with_event(
    connection: &mut Connection,
    session_id: &str,
    mut event: NewEvent,
    fence: Option<&FencingToken>,
) -> StoreResult<DeleteSessionEventMutation> {
    require_nonempty("session_id", session_id)?;
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    validate_fence(&transaction, fence)?;
    let deleted = delete_session_in_transaction(&transaction, session_id)?;
    let event = if deleted {
        if event.session_id.is_none() {
            event.session_id = Some(session_id.to_owned());
        }
        Some(append_event_in_transaction(&transaction, event)?)
    } else {
        None
    };
    transaction.commit()?;
    Ok(DeleteSessionEventMutation { deleted, event })
}

fn delete_session_in_transaction(
    transaction: &Transaction<'_>,
    session_id: &str,
) -> StoreResult<bool> {
    require_nonempty("session_id", session_id)?;
    transaction.execute("DELETE FROM messages WHERE session_id = ?1", [session_id])?;
    let changed =
        transaction.execute("DELETE FROM sessions WHERE session_id = ?1", [session_id])?;
    Ok(changed > 0)
}

fn upsert_message(
    connection: &mut Connection,
    mutation: MessageMutation,
    fence: Option<&FencingToken>,
) -> StoreResult<StoredMessage> {
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    validate_fence(&transaction, fence)?;
    let stored = upsert_message_in_transaction(&transaction, mutation)?;
    transaction.commit()?;
    Ok(stored)
}

fn upsert_message_with_event(
    connection: &mut Connection,
    mutation: MessageMutation,
    mut event: NewEvent,
    fence: Option<&FencingToken>,
) -> StoreResult<MessageEventMutation> {
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    validate_fence(&transaction, fence)?;
    let session_id = mutation.session_id.clone();
    let stored = upsert_message_in_transaction(&transaction, mutation)?;
    let event = if stored.applied {
        if event.session_id.is_none() {
            event.session_id = Some(session_id);
        }
        Some(append_event_in_transaction(&transaction, event)?)
    } else {
        None
    };
    transaction.commit()?;
    Ok(MessageEventMutation { stored, event })
}

fn upsert_message_in_transaction(
    transaction: &Transaction<'_>,
    mutation: MessageMutation,
) -> StoreResult<StoredMessage> {
    require_nonempty("session_id", &mutation.session_id)?;
    require_nonempty("message.id", &mutation.message.id)?;
    let message_json = serde_json::to_string(&mutation.message)?;
    if let Some((existing_json, revision, updated_at, is_final)) = transaction
        .query_row(
            "SELECT message_json, revision, updated_at, is_final
             FROM messages WHERE session_id = ?1 AND message_id = ?2",
            params![mutation.session_id, mutation.message.id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, bool>(3)?,
                ))
            },
        )
        .optional()?
    {
        let existing_revision = to_u64(revision)?;
        let should_apply = mutation.revision > existing_revision
            || (mutation.revision == existing_revision && mutation.updated_at > updated_at)
            || (mutation.revision == existing_revision && mutation.final_ && !is_final);
        if !should_apply {
            return Ok(StoredMessage {
                session_id: mutation.session_id,
                message: serde_json::from_str(&existing_json)?,
                revision: existing_revision,
                updated_at,
                final_: is_final,
                applied: false,
            });
        }
        transaction.execute(
            "UPDATE messages SET revision = ?3, updated_at = ?4, is_final = ?5, message_json = ?6
             WHERE session_id = ?1 AND message_id = ?2",
            params![
                mutation.session_id,
                mutation.message.id,
                to_i64(mutation.revision)?,
                mutation.updated_at,
                mutation.final_,
                message_json,
            ],
        )?;
    } else {
        transaction.execute(
            "INSERT INTO messages(session_id, message_id, revision, updated_at, is_final, message_json)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                mutation.session_id,
                mutation.message.id,
                to_i64(mutation.revision)?,
                mutation.updated_at,
                mutation.final_,
                message_json,
            ],
        )?;
    }
    Ok(StoredMessage {
        session_id: mutation.session_id,
        message: mutation.message,
        revision: mutation.revision,
        updated_at: mutation.updated_at,
        final_: mutation.final_,
        applied: true,
    })
}

fn list_messages(connection: &Connection, session_id: &str) -> StoreResult<Vec<StoredMessage>> {
    let mut statement = connection.prepare(
        "SELECT message_json, revision, updated_at, is_final
         FROM messages WHERE session_id = ?1",
    )?;
    let rows = statement.query_map([session_id], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, i64>(1)?,
            row.get::<_, i64>(2)?,
            row.get::<_, bool>(3)?,
        ))
    })?;
    let mut messages = rows
        .map(|row| {
            let (json, revision, updated_at, is_final) = row?;
            Ok(StoredMessage {
                session_id: session_id.to_owned(),
                message: serde_json::from_str(&json)?,
                revision: to_u64(revision)?,
                updated_at,
                final_: is_final,
                applied: true,
            })
        })
        .collect::<StoreResult<Vec<_>>>()?;
    messages.sort_by(|left, right| {
        left.message
            .timestamp
            .cmp(&right.message.timestamp)
            .then_with(|| left.message.id.cmp(&right.message.id))
    });
    Ok(messages)
}

fn replace_models(
    connection: &mut Connection,
    catalog: ModelCatalog,
    fence: Option<&FencingToken>,
) -> StoreResult<ModelCatalog> {
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    validate_fence(&transaction, fence)?;
    let (catalog, _) = replace_models_in_transaction(&transaction, catalog)?;
    transaction.commit()?;
    Ok(catalog)
}

fn replace_models_with_event(
    connection: &mut Connection,
    catalog: ModelCatalog,
    event: NewEvent,
    fence: Option<&FencingToken>,
) -> StoreResult<ModelCatalogEventMutation> {
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    validate_fence(&transaction, fence)?;
    let (catalog, applied) = replace_models_in_transaction(&transaction, catalog)?;
    let event = if applied {
        Some(append_event_in_transaction(&transaction, event)?)
    } else {
        None
    };
    transaction.commit()?;
    Ok(ModelCatalogEventMutation { catalog, event })
}

fn replace_models_in_transaction(
    transaction: &Transaction<'_>,
    catalog: ModelCatalog,
) -> StoreResult<(ModelCatalog, bool)> {
    let catalog = catalog.product_filtered();
    if transaction
        .query_row(
            "SELECT catalog_json FROM model_catalogs WHERE scope = 'product'",
            [],
            |row| row.get::<_, String>(0),
        )
        .optional()?
        .map(|json| serde_json::from_str::<ModelCatalog>(&json))
        .transpose()?
        .as_ref()
        == Some(&catalog)
    {
        return Ok((catalog, false));
    }
    let catalog_json = serde_json::to_string(&catalog)?;
    transaction.execute(
        "INSERT INTO model_catalogs(scope, observed_at, catalog_json)
         VALUES ('product', ?1, ?2)
         ON CONFLICT(scope) DO UPDATE SET
            observed_at = excluded.observed_at,
            catalog_json = excluded.catalog_json",
        params![catalog.observed_at, catalog_json],
    )?;
    Ok((catalog, true))
}

fn get_models(connection: &Connection) -> StoreResult<Option<ModelCatalog>> {
    let json = connection
        .query_row(
            "SELECT catalog_json FROM model_catalogs WHERE scope = 'product'",
            [],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    json.map(|value| serde_json::from_str(&value).map_err(StoreError::from))
        .transpose()
}

fn put_snapshot(
    connection: &mut Connection,
    scope: &str,
    snapshot: AuthoritativeSnapshot,
    fence: Option<&FencingToken>,
) -> StoreResult<StoredSnapshot> {
    require_nonempty("snapshot scope", scope)?;
    let snapshot_json = serde_json::to_string(&snapshot)?;
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    validate_fence(&transaction, fence)?;
    let version = next_counter(&transaction, &format!("snapshot:{scope}"))?;
    transaction.execute(
        "INSERT INTO snapshots(scope, version, global_sequence, created_at, snapshot_json)
         VALUES (?1, ?2, ?3, ?4, ?5)
         ON CONFLICT(scope) DO UPDATE SET
            version = excluded.version,
            global_sequence = excluded.global_sequence,
            created_at = excluded.created_at,
            snapshot_json = excluded.snapshot_json",
        params![
            scope,
            to_i64(version)?,
            to_i64(snapshot.global_sequence)?,
            snapshot.generated_at,
            snapshot_json,
        ],
    )?;
    transaction.commit()?;
    Ok(StoredSnapshot {
        scope: scope.to_owned(),
        version,
        snapshot,
    })
}

fn get_snapshot(connection: &Connection, scope: &str) -> StoreResult<Option<StoredSnapshot>> {
    let raw = connection
        .query_row(
            "SELECT version, snapshot_json FROM snapshots WHERE scope = ?1",
            [scope],
            |row| Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?)),
        )
        .optional()?;
    raw.map(|(version, json)| {
        Ok(StoredSnapshot {
            scope: scope.to_owned(),
            version: to_u64(version)?,
            snapshot: serde_json::from_str(&json)?,
        })
    })
    .transpose()
}

fn acquire_lease(connection: &mut Connection, request: LeaseRequest) -> StoreResult<LeaseRecord> {
    require_nonempty("lease_key", &request.lease_key)?;
    require_nonempty("holder_id", &request.holder_id)?;
    if request.ttl_millis <= 0 {
        return Err(StoreError::InvalidInput(
            "lease ttl_millis must be positive".to_owned(),
        ));
    }
    let now = wall_clock_millis()?;
    let expires_at = now
        .checked_add(request.ttl_millis)
        .ok_or_else(|| StoreError::InvalidInput("lease expiry overflow".to_owned()))?;
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let current = query_lease(&transaction, &request.lease_key)?;
    let (generation, acquired_at) = match current {
        None => (1, now),
        Some(current) if current.expires_at <= now => (
            current
                .generation
                .checked_add(1)
                .ok_or_else(|| StoreError::Invariant("lease generation overflow".to_owned()))?,
            now,
        ),
        Some(current) if current.holder_id != request.holder_id => {
            return Err(StoreError::LeaseHeld {
                lease_key: current.lease_key,
                holder_id: current.holder_id,
                expires_at: current.expires_at,
            });
        }
        Some(current) => match request.previous_generation {
            Some(generation) if generation == current.generation => {
                (current.generation, current.acquired_at)
            }
            Some(generation) => {
                return Err(StoreError::StaleFence {
                    lease_key: request.lease_key,
                    generation,
                });
            }
            None => (
                current
                    .generation
                    .checked_add(1)
                    .ok_or_else(|| StoreError::Invariant("lease generation overflow".to_owned()))?,
                now,
            ),
        },
    };
    transaction.execute(
        "INSERT INTO leases(lease_key, holder_id, generation, acquired_at, expires_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?4)
         ON CONFLICT(lease_key) DO UPDATE SET
            holder_id = excluded.holder_id,
            generation = excluded.generation,
            acquired_at = excluded.acquired_at,
            expires_at = excluded.expires_at,
            updated_at = excluded.updated_at",
        params![
            request.lease_key,
            request.holder_id,
            to_i64(generation)?,
            acquired_at,
            expires_at,
        ],
    )?;
    transaction.commit()?;
    Ok(LeaseRecord {
        lease_key: request.lease_key,
        holder_id: request.holder_id,
        generation,
        acquired_at,
        expires_at,
        updated_at: now,
    })
}

fn renew_lease(
    connection: &mut Connection,
    token: &FencingToken,
    ttl_millis: i64,
) -> StoreResult<LeaseRecord> {
    if ttl_millis <= 0 {
        return Err(StoreError::InvalidInput(
            "lease ttl_millis must be positive".to_owned(),
        ));
    }
    let now = wall_clock_millis()?;
    let expires_at = now
        .checked_add(ttl_millis)
        .ok_or_else(|| StoreError::InvalidInput("lease expiry overflow".to_owned()))?;
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    validate_fence(&transaction, Some(token))?;
    transaction.execute(
        "UPDATE leases SET expires_at = ?2, updated_at = ?3 WHERE lease_key = ?1",
        params![token.lease_key, expires_at, now],
    )?;
    let mut lease =
        query_lease(&transaction, &token.lease_key)?.ok_or_else(|| StoreError::StaleFence {
            lease_key: token.lease_key.clone(),
            generation: token.generation,
        })?;
    lease.expires_at = expires_at;
    lease.updated_at = now;
    transaction.commit()?;
    Ok(lease)
}

fn release_lease(connection: &mut Connection, token: &FencingToken) -> StoreResult<bool> {
    let now = wall_clock_millis()?;
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    validate_fence(&transaction, Some(token))?;
    let changed = transaction.execute(
        "UPDATE leases
         SET holder_id = '', expires_at = 0, updated_at = ?4
         WHERE lease_key = ?1 AND holder_id = ?2 AND generation = ?3",
        params![
            token.lease_key,
            token.holder_id,
            to_i64(token.generation)?,
            now,
        ],
    )?;
    transaction.commit()?;
    Ok(changed > 0)
}

fn get_lease(connection: &Connection, lease_key: &str) -> StoreResult<Option<LeaseRecord>> {
    query_lease(connection, lease_key)
}

fn query_lease(connection: &Connection, lease_key: &str) -> StoreResult<Option<LeaseRecord>> {
    let raw = connection
        .query_row(
            "SELECT lease_key, holder_id, generation, acquired_at, expires_at, updated_at
             FROM leases WHERE lease_key = ?1",
            [lease_key],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, i64>(3)?,
                    row.get::<_, i64>(4)?,
                    row.get::<_, i64>(5)?,
                ))
            },
        )
        .optional()?;
    raw.map(
        |(lease_key, holder_id, generation, acquired_at, expires_at, updated_at)| {
            Ok(LeaseRecord {
                lease_key,
                holder_id,
                generation: to_u64(generation)?,
                acquired_at,
                expires_at,
                updated_at,
            })
        },
    )
    .transpose()
}

fn validate_fence(connection: &Connection, token: Option<&FencingToken>) -> StoreResult<()> {
    let Some(token) = token else {
        return Ok(());
    };
    let now = wall_clock_millis()?;
    let current = query_lease(connection, &token.lease_key)?;
    match current {
        Some(current)
            if current.holder_id == token.holder_id
                && current.generation == token.generation
                && current.expires_at > now =>
        {
            Ok(())
        }
        _ => Err(StoreError::StaleFence {
            lease_key: token.lease_key.clone(),
            generation: token.generation,
        }),
    }
}

fn commit_cursor(
    connection: &mut Connection,
    cursor: ConsumerCursor,
) -> StoreResult<ConsumerCursor> {
    require_nonempty("consumer_id", &cursor.consumer_id)?;
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    if let Some(existing) = query_cursor(&transaction, &cursor.consumer_id)?
        && cursor.global_sequence <= existing.global_sequence
    {
        transaction.commit()?;
        return Ok(existing);
    }
    transaction.execute(
        "INSERT INTO consumer_cursors(consumer_id, global_sequence, updated_at)
         VALUES (?1, ?2, ?3)
         ON CONFLICT(consumer_id) DO UPDATE SET
            global_sequence = excluded.global_sequence,
            updated_at = excluded.updated_at",
        params![
            cursor.consumer_id,
            to_i64(cursor.global_sequence)?,
            cursor.updated_at,
        ],
    )?;
    transaction.commit()?;
    Ok(cursor)
}

fn get_cursor(connection: &Connection, consumer_id: &str) -> StoreResult<Option<ConsumerCursor>> {
    query_cursor(connection, consumer_id)
}

fn query_cursor(connection: &Connection, consumer_id: &str) -> StoreResult<Option<ConsumerCursor>> {
    let raw = connection
        .query_row(
            "SELECT consumer_id, global_sequence, updated_at
             FROM consumer_cursors WHERE consumer_id = ?1",
            [consumer_id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, i64>(2)?,
                ))
            },
        )
        .optional()?;
    raw.map(|(consumer_id, sequence, updated_at)| {
        Ok(ConsumerCursor {
            consumer_id,
            global_sequence: to_u64(sequence)?,
            updated_at,
        })
    })
    .transpose()
}

fn enqueue_outbox(
    connection: &mut Connection,
    entry: NewOutboxEntry,
    fence: Option<&FencingToken>,
) -> StoreResult<RelayOutboxEntry> {
    require_nonempty("peer_id", &entry.peer_id)?;
    let frame_json = serde_json::to_string(&entry.frame)?;
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    validate_fence(&transaction, fence)?;
    let sequence = next_counter(&transaction, &format!("outbox:{}", entry.peer_id))?;
    transaction.execute(
        "INSERT INTO relay_outbox(peer_id, sequence, frame_json, created_at)
         VALUES (?1, ?2, ?3, ?4)",
        params![
            entry.peer_id,
            to_i64(sequence)?,
            frame_json,
            entry.created_at,
        ],
    )?;
    transaction.commit()?;
    Ok(RelayOutboxEntry {
        peer_id: entry.peer_id,
        sequence,
        frame: entry.frame,
        created_at: entry.created_at,
    })
}

fn replay_outbox(
    connection: &Connection,
    peer_id: &str,
    after: u64,
    limit: usize,
) -> StoreResult<Vec<RelayOutboxEntry>> {
    let mut statement = connection.prepare(
        "SELECT sequence, frame_json, created_at FROM relay_outbox
         WHERE peer_id = ?1 AND sequence > ?2 ORDER BY sequence LIMIT ?3",
    )?;
    let rows = statement.query_map(
        params![peer_id, to_i64(after)?, to_i64(limit as u64)?],
        |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, i64>(2)?,
            ))
        },
    )?;
    rows.map(|row| {
        let (sequence, json, created_at) = row?;
        Ok(RelayOutboxEntry {
            peer_id: peer_id.to_owned(),
            sequence: to_u64(sequence)?,
            frame: serde_json::from_str::<RelayFrame>(&json)?,
            created_at,
        })
    })
    .collect()
}

fn ack_outbox(
    connection: &mut Connection,
    peer_id: &str,
    through: u64,
    fence: Option<&FencingToken>,
) -> StoreResult<u64> {
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    validate_fence(&transaction, fence)?;
    let changed = transaction.execute(
        "DELETE FROM relay_outbox WHERE peer_id = ?1 AND sequence <= ?2",
        params![peer_id, to_i64(through)?],
    )?;
    transaction.commit()?;
    Ok(changed as u64)
}

fn checkpoint(connection: &Connection) -> StoreResult<()> {
    connection.execute_batch("PRAGMA wal_checkpoint(PASSIVE)")?;
    Ok(())
}

fn next_counter(transaction: &Transaction<'_>, scope: &str) -> StoreResult<u64> {
    transaction.execute(
        "INSERT INTO counters(scope, value) VALUES (?1, 0)
         ON CONFLICT(scope) DO NOTHING",
        [scope],
    )?;
    let current: i64 = transaction.query_row(
        "SELECT value FROM counters WHERE scope = ?1",
        [scope],
        |row| row.get(0),
    )?;
    let next = current
        .checked_add(1)
        .ok_or_else(|| StoreError::Invariant(format!("counter overflow for {scope}")))?;
    transaction.execute(
        "UPDATE counters SET value = ?2 WHERE scope = ?1",
        params![scope, next],
    )?;
    to_u64(next)
}

fn command_state_from_str(value: &str) -> StoreResult<CommandState> {
    match value {
        "accepted" => Ok(CommandState::Accepted),
        "leased" => Ok(CommandState::Leased),
        "engineDurable" => Ok(CommandState::EngineDurable),
        "sentToChild" => Ok(CommandState::SentToChild),
        "completed" => Ok(CommandState::Completed),
        "failed" => Ok(CommandState::Failed),
        "cancelled" => Ok(CommandState::Cancelled),
        "unknown" => Ok(CommandState::Unknown),
        other => Err(StoreError::Invariant(format!(
            "unknown command state {other:?}"
        ))),
    }
}

fn event_kind_from_str(value: &str) -> StoreResult<EventKind> {
    match value {
        "snapshot" => Ok(EventKind::Snapshot),
        "message_patch" => Ok(EventKind::MessagePatch),
        "session_upserted" => Ok(EventKind::SessionUpserted),
        "session_removed" => Ok(EventKind::SessionRemoved),
        "command_state_changed" => Ok(EventKind::CommandStateChanged),
        "turn_started" => Ok(EventKind::TurnStarted),
        "turn_completed" => Ok(EventKind::TurnCompleted),
        "turn_interrupted" => Ok(EventKind::TurnInterrupted),
        "item_started" => Ok(EventKind::ItemStarted),
        "item_updated" => Ok(EventKind::ItemUpdated),
        "item_completed" => Ok(EventKind::ItemCompleted),
        "approval_requested" => Ok(EventKind::ApprovalRequested),
        "approval_resolved" => Ok(EventKind::ApprovalResolved),
        "user_input_requested" => Ok(EventKind::UserInputRequested),
        "user_input_resolved" => Ok(EventKind::UserInputResolved),
        "model_catalog_updated" => Ok(EventKind::ModelCatalogUpdated),
        "goal_updated" => Ok(EventKind::GoalUpdated),
        "subagent_updated" => Ok(EventKind::SubagentUpdated),
        "runtime_status" => Ok(EventKind::RuntimeStatus),
        "error" => Ok(EventKind::Error),
        "heartbeat" => Ok(EventKind::Heartbeat),
        other => Err(StoreError::Invariant(format!(
            "unknown event kind {other:?}"
        ))),
    }
}

fn require_nonempty(field: &str, value: &str) -> StoreResult<()> {
    if value.trim().is_empty() {
        Err(StoreError::InvalidInput(format!(
            "{field} must not be empty"
        )))
    } else {
        Ok(())
    }
}

fn to_i64(value: u64) -> StoreResult<i64> {
    i64::try_from(value)
        .map_err(|_| StoreError::Invariant(format!("value {value} does not fit in SQLite INTEGER")))
}

fn to_u64(value: i64) -> StoreResult<u64> {
    u64::try_from(value)
        .map_err(|_| StoreError::Invariant(format!("negative SQLite sequence {value}")))
}

fn encoded_len<T: Serialize>(value: &T) -> StoreResult<usize> {
    Ok(serde_json::to_vec(value)?.len())
}

fn bounded_limit(limit: usize) -> usize {
    limit.clamp(1, MAX_READ_LIMIT)
}

fn idempotency_trace_identity(trace_id: Option<&str>) -> Option<String> {
    const PROMPT_VARIANT_PREFIX: &str = "fermin-prompt-variant:";
    let trace_id = trace_id?;
    let Some(metadata) = trace_id.strip_prefix(PROMPT_VARIANT_PREFIX) else {
        return Some(trace_id.to_owned());
    };
    let Ok(metadata) = serde_json::from_str::<serde_json::Value>(metadata) else {
        return Some(trace_id.to_owned());
    };
    match metadata.get("upstreamTraceId") {
        None | Some(serde_json::Value::Null) => None,
        Some(serde_json::Value::String(value)) => Some(value.clone()),
        Some(_) => Some(trace_id.to_owned()),
    }
}

fn wall_clock_millis() -> StoreResult<i64> {
    let duration = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|error| {
            StoreError::Invariant(format!("system clock precedes Unix epoch: {error}"))
        })?;
    i64::try_from(duration.as_millis())
        .map_err(|_| StoreError::Invariant("system clock milliseconds overflow i64".to_owned()))
}
