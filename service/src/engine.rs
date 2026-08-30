use std::collections::{BTreeMap, HashMap, HashSet};
use std::future::Future;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex as StdMutex, Weak};
use std::time::Duration;

use anyhow::{Context, Result, bail};
use bytes::Bytes;
use futures_util::StreamExt;
use serde::Serialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use thiserror::Error;
use tokio::sync::{Mutex, RwLock, Semaphore, broadcast, mpsc};
use tokio::task::JoinHandle;
use tokio::time;
use tokio_util::sync::CancellationToken;
use tracing::{error, info, warn};
use tracing_subscriber::EnvFilter;

use crate::appserver::{
    AppServerClient, AppServerConfig, AppServerError, AppServerEvent, AppServerLifecycle,
};
use crate::config::EngineConfig;
use crate::features::{
    AppServerCapabilities, ExplainerInput, FeatureError, FidelityDisposition, GoalModePlan,
    GoalModeRequest, GoalStatus, IsolatedAppServer, MAX_NATIVE_GOAL_OBJECTIVE_CHARS,
    ObserverContext, PromptImproverInput, ResponseLanguage, SubagentRelationship,
    THREAD_SETTINGS_UPDATE_METHOD, build_subagent_child_notification_instructions,
    build_subagent_parent_context, explain_result, improve_prompt, select_goal_mode,
};
use crate::protocol::{
    ActivityStatus, AuthoritativeSnapshot, CommandAcceptance, CommandKind, CommandRecord,
    CommandRequest, CommandState, CommandTransition, ConsumerCursor, DurableEvent, EventCursor,
    EventKind, FencingToken, GoalState, LeaseRecord, LeaseRequest, Message, MessageMutation,
    Millis, ModelCatalog, ModelInfo, NewEngineEpoch, NewEvent, PendingSubagentDraft,
    ReasoningEffortOption, RunMode, RuntimeModelSettings, SessionFeatures, SessionSummary,
    StoredSession,
};
use crate::store::{Store, StoreError};

const COMMAND_LANE_CAPACITY: usize = 32;
const LIVE_EVENT_CAPACITY: usize = 1_024;
const APP_SERVER_EVENT_CAPACITY: usize = 2_048;
const APP_SERVER_WRITER_CAPACITY: usize = 256;
// The local lease fences stale writers, but a replacement process with the same
// engine holder can supersede it immediately. Keep enough slack for scheduler
// starvation on a heavily loaded Mac: a 30-second TTL made a healthy engine
// cancel itself after a transient CPU stall even though the relay still
// considered its 90-second connection lease fresh.
const ENGINE_LEASE_TTL_MILLIS: i64 = 90_000;
const ENGINE_STARTUP_LEASE_TTL_MILLIS: i64 = 15 * 60 * 1_000;
const ENGINE_LEASE_RENEW_INTERVAL: Duration = Duration::from_secs(10);
const _: () = assert!(ENGINE_STARTUP_LEASE_TTL_MILLIS >= ENGINE_LEASE_TTL_MILLIS * 10);
const OVERLOAD_RETRIES: usize = 3;
const EVENT_REPLAY_PAGE: usize = 10_000;
const COMMAND_SWEEP_INTERVAL: Duration = Duration::from_millis(500);
const APP_SERVER_REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
const APP_SERVER_THREAD_REQUEST_TIMEOUT: Duration = Duration::from_secs(120);
// Puky can be heavily loaded by interactive agents and simulators. Codex App Server
// initialization is CPU- and I/O-sensitive, so the engine must not enter a PM2
// restart loop merely because startup takes longer than the generic client default.
const APP_SERVER_STARTUP_TIMEOUT: Duration = Duration::from_secs(120);
const CODEX_SCHEMA_PROBE_TIMEOUT: Duration = Duration::from_secs(120);
const THREAD_SETTINGS_CONFIRMATION_TIMEOUT: Duration = Duration::from_secs(5);
const SESSION_CREATOR_CONCURRENCY: usize = 2;
const PROMPT_IMPROVER_CONTEXT_MAX_MESSAGES: usize = 48;
const PROMPT_IMPROVER_CONTEXT_MAX_BYTES: usize = 64 * 1024;
const PROMPT_IMPROVER_CONTEXT_MESSAGE_MAX_BYTES: usize = 8 * 1024;
const MAX_PERSISTED_ITEM_NOTIFICATION_BYTES: usize = 384 * 1024;
const MAX_PERSISTED_ITEM_METADATA_BYTES: usize = 8 * 1024;
const MAX_PERSISTED_NORMALIZED_NOTIFICATION_BYTES: usize = 64 * 1024;
const RUNTIME_ERROR_DETAIL_MAX_CHARS: usize = 600;
const RESUME_HISTORY_TRACE_PREFIX: &str = "fermin:resume-history:";
const CRASH_RECOVERY_TRACE_PREFIX: &str = "fermin:crash-recovery:";
const CRASH_RECOVERY_MESSAGE: &str = "Continuá con el trabajo que venías haciendo desde el último punto seguro. Conservá todo lo ya realizado, verificá el estado actual antes de editar y seguí hasta completar el objetivo original.";
const RELAY_ATTACHMENT_PREFIX: &str = "relay://";
const ATTACHMENT_CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const ATTACHMENT_DOWNLOAD_TIMEOUT: Duration = Duration::from_secs(45);

#[derive(Clone, Copy, Debug)]
struct SendMessageOptions<'a> {
    service_tier: Option<&'a str>,
    allow_prompt_improver: bool,
}

type TransportFuture<'a, T> = Pin<Box<dyn Future<Output = Result<T, AppServerError>> + Send + 'a>>;

trait EngineTransport: Send + Sync {
    fn epoch(&self) -> u64;
    fn is_running(&self) -> bool;
    fn subscribe(&self) -> broadcast::Receiver<AppServerEvent>;
    fn request(&self, method: String, params: Value) -> TransportFuture<'_, Value>;
    fn request_with_timeout(
        &self,
        method: String,
        params: Value,
        _timeout: Duration,
    ) -> TransportFuture<'_, Value> {
        self.request(method, params)
    }
    fn respond(&self, id: Value, result: Value) -> TransportFuture<'_, ()>;
    fn respond_error(
        &self,
        id: Value,
        code: i64,
        message: String,
        data: Option<Value>,
    ) -> TransportFuture<'_, ()>;
    fn shutdown(&self) -> TransportFuture<'_, ()>;
}

impl EngineTransport for AppServerClient {
    fn epoch(&self) -> u64 {
        AppServerClient::epoch(self)
    }

    fn is_running(&self) -> bool {
        AppServerClient::is_running(self)
    }

    fn subscribe(&self) -> broadcast::Receiver<AppServerEvent> {
        AppServerClient::subscribe(self)
    }

    fn request(&self, method: String, params: Value) -> TransportFuture<'_, Value> {
        Box::pin(async move { AppServerClient::request(self, method, params).await })
    }

    fn request_with_timeout(
        &self,
        method: String,
        params: Value,
        timeout: Duration,
    ) -> TransportFuture<'_, Value> {
        Box::pin(async move {
            AppServerClient::request_with_timeout(self, method, params, timeout).await
        })
    }

    fn respond(&self, id: Value, result: Value) -> TransportFuture<'_, ()> {
        Box::pin(async move { AppServerClient::respond(self, id, result).await })
    }

    fn respond_error(
        &self,
        id: Value,
        code: i64,
        message: String,
        data: Option<Value>,
    ) -> TransportFuture<'_, ()> {
        Box::pin(async move { AppServerClient::respond_error(self, id, code, message, data).await })
    }

    fn shutdown(&self) -> TransportFuture<'_, ()> {
        Box::pin(async move { AppServerClient::shutdown(self).await })
    }
}

#[derive(Debug, Error)]
pub enum EngineError {
    #[error("invalid engine configuration: {0}")]
    Configuration(String),
    #[error("session {0:?} was not found")]
    SessionNotFound(String),
    #[error("session {0:?} has no active turn")]
    NoActiveTurn(String),
    #[error("unsupported command: {0}")]
    UnsupportedCommand(String),
    #[error("observer workflows are unavailable until an observer runtime is installed")]
    ObserverUnavailable,
    #[error("observer workflow failed: {0}")]
    Feature(#[from] crate::features::FeatureError),
    #[error("command lane closed before accepting durable command {0}")]
    CommandLaneClosed(String),
    #[error("engine is shutting down")]
    ShuttingDown,
    #[error("invalid App Server response: {0}")]
    InvalidResponse(String),
    #[error("invalid model settings: {0}")]
    InvalidModel(String),
    #[error("path is outside configured workspace roots: {0}")]
    PathOutsideWorkspace(String),
    #[error(transparent)]
    AppServer(#[from] AppServerError),
    #[error(transparent)]
    Store(#[from] StoreError),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
    #[error("filesystem error: {0}")]
    Io(#[from] std::io::Error),
}

impl EngineError {
    fn is_ambiguous_child_execution(&self) -> bool {
        matches!(
            self,
            Self::AppServer(
                AppServerError::Closed { .. }
                    | AppServerError::Timeout { .. }
                    | AppServerError::LineTooLong { .. }
                    | AppServerError::MalformedLine { .. }
                    | AppServerError::Eof { .. }
                    | AppServerError::Transport { .. }
                    | AppServerError::ProcessExited { .. }
                    | AppServerError::Protocol { .. }
            )
        )
    }

    fn may_follow_external_side_effect(&self) -> bool {
        matches!(
            self,
            Self::AppServer(_) | Self::Store(_) | Self::Json(_) | Self::InvalidResponse(_)
        )
    }
}

pub type EngineResult<T> = Result<T, EngineError>;

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EngineHealth {
    pub ready: bool,
    pub app_server_running: bool,
    pub engine_id: String,
    pub process_epoch: u64,
    pub app_server_epoch: u64,
    pub model_count: usize,
    pub session_count: usize,
}

#[derive(Clone)]
pub struct EngineState {
    core: Arc<EngineCore>,
}

impl std::fmt::Debug for EngineState {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("EngineState")
            .field("engine_id", &self.core.config.engine_id)
            .field("process_epoch", &self.core.process_epoch)
            .field("ready", &self.core.ready.load(Ordering::Acquire))
            .finish_non_exhaustive()
    }
}

struct EngineCore {
    config: EngineConfig,
    store: Store,
    appserver: Arc<dyn EngineTransport>,
    session_creator: Option<Arc<dyn EngineTransport>>,
    session_creator_slots: Semaphore,
    attachment_http: reqwest::Client,
    process_epoch: u64,
    app_server_version: String,
    capability_hash: String,
    appserver_capabilities: AppServerCapabilities,
    models: RwLock<ModelCatalog>,
    observer: Option<Arc<dyn IsolatedAppServer>>,
    runtime: RwLock<RuntimeIndex>,
    lanes: Mutex<HashMap<String, mpsc::Sender<String>>>,
    scheduled_commands: StdMutex<HashSet<String>>,
    active_commands: StdMutex<HashSet<String>>,
    live_events: broadcast::Sender<DurableEvent>,
    last_global_sequence: AtomicU64,
    publisher: StdMutex<EventPublisher>,
    lease: RwLock<LeaseRecord>,
    admission: RwLock<()>,
    cancellation: CancellationToken,
    tasks: Mutex<Vec<JoinHandle<()>>>,
    prompt_preference: RwLock<crate::api::PromptImproverPreferenceRecord>,
    ready: AtomicBool,
    shutdown_started: AtomicBool,
}

#[derive(Clone)]
struct RuntimeSchemaProbe {
    schema_hash: String,
    capabilities: AppServerCapabilities,
    baseline_schema_match: bool,
}

#[derive(Default)]
struct RuntimeIndex {
    sessions: HashMap<String, RuntimeSession>,
    threads: HashMap<String, String>,
}

struct EventPublisher {
    last_published: u64,
    pending: BTreeMap<u64, DurableEvent>,
}

#[derive(Clone, Default)]
struct RuntimeSession {
    thread_id: String,
    active_turn_id: Option<String>,
    message_buffers: HashMap<String, MessageAccumulator>,
    appserver_loaded: bool,
    transcript_hydrated: bool,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct MessageAccumulator {
    content: String,
    revision: u64,
    timestamp: i64,
}

struct ScheduledCommandGuard {
    core: Weak<EngineCore>,
    command_id: String,
    armed: bool,
}

impl ScheduledCommandGuard {
    fn new(core: &Arc<EngineCore>, command_id: String) -> Self {
        Self {
            core: Arc::downgrade(core),
            command_id,
            armed: true,
        }
    }

    fn retain_marker(mut self) {
        self.armed = false;
    }
}

impl Drop for ScheduledCommandGuard {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        if let Some(core) = self.core.upgrade() {
            lock_std(&core.scheduled_commands).remove(&self.command_id);
        }
    }
}

impl MessageAccumulator {
    fn apply_delta(&mut self, delta: &str, timestamp: i64) -> (String, u64, i64) {
        self.content.push_str(delta);
        self.revision = self.revision.saturating_add(1).max(1);
        self.timestamp = self.timestamp.max(timestamp);
        (self.content.clone(), self.revision, self.timestamp)
    }

    fn apply_authoritative(&mut self, text: &str, timestamp: i64) -> (String, u64, i64) {
        if self.content != text {
            self.content.clear();
            self.content.push_str(text);
            self.revision = self.revision.saturating_add(1).max(1);
        } else if self.revision == 0 {
            self.revision = 1;
        }
        self.timestamp = self.timestamp.max(timestamp);
        (self.content.clone(), self.revision, self.timestamp)
    }
}

impl EngineState {
    pub fn route_targeted_command(
        mut request: CommandRequest,
        target_session_id: impl Into<String>,
    ) -> EngineResult<CommandRequest> {
        let target_session_id = target_session_id.into();
        if target_session_id.trim().is_empty() {
            return Err(EngineError::UnsupportedCommand(
                "target sessionId must not be empty".to_owned(),
            ));
        }
        if matches!(&request.command, CommandKind::CreateSubagent { .. }) {
            let child_session_id = request.session_id.clone().ok_or_else(|| {
                EngineError::UnsupportedCommand(
                    "createSubagent requires a child sessionId".to_owned(),
                )
            })?;
            request.trace_id = Some(encode_subagent_routing(
                &target_session_id,
                &child_session_id,
                request.trace_id.as_deref(),
            ));
        }
        request.session_id = Some(target_session_id);
        Ok(request)
    }

    pub fn attach_prompt_improver_variant(
        mut request: CommandRequest,
        variant: crate::api::PromptImproverVariant,
    ) -> CommandRequest {
        request.trace_id = Some(encode_prompt_variant(variant, request.trace_id.as_deref()));
        request
    }

    pub fn attach_resume_history_trace(mut request: CommandRequest) -> CommandRequest {
        if !request
            .trace_id
            .as_deref()
            .is_some_and(|trace| trace.starts_with(RESUME_HISTORY_TRACE_PREFIX))
        {
            let trace = request
                .trace_id
                .take()
                .unwrap_or_else(|| request.idempotency_key.clone());
            request.trace_id = Some(format!("{RESUME_HISTORY_TRACE_PREFIX}{trace}"));
        }
        request
    }

    pub async fn bootstrap(config: EngineConfig) -> EngineResult<Self> {
        config
            .validate()
            .map_err(|error| EngineError::Configuration(error.to_string()))?;
        let store = Store::open(&config.database_path).await?;
        info!("validating Codex runtime");
        let app_server_version = probe_codex_version(&config.codex_path).await?;
        let schema_probe = probe_codex_schema(&config.codex_path).await?;
        info!(
            app_server_version = %app_server_version,
            schema_hash = %schema_probe.schema_hash,
            baseline_schema_match = schema_probe.baseline_schema_match,
            "Codex runtime contract is compatible"
        );
        let mut appserver_config = AppServerConfig::for_codex(&config.codex_path);
        appserver_config.initialize_timeout = APP_SERVER_STARTUP_TIMEOUT;
        appserver_config.max_line_bytes = config.max_jsonl_bytes;
        appserver_config.writer_capacity = APP_SERVER_WRITER_CAPACITY;
        appserver_config.event_capacity = APP_SERVER_EVENT_CAPACITY;
        let observer_appserver_config = appserver_config.clone();
        info!(
            timeout_seconds = APP_SERVER_STARTUP_TIMEOUT.as_secs(),
            "starting Codex App Server transports"
        );
        let appserver = AppServerClient::spawn(appserver_config).await?;
        // Observer turns must not share a process or event bus with interactive
        // sessions. A busy Goal/streaming turn can otherwise starve or fail the
        // prompt improver even though its ephemeral thread is logically separate.
        let observer_appserver = match AppServerClient::spawn(observer_appserver_config).await {
            Ok(observer_appserver) => observer_appserver,
            Err(error) => {
                let _ = appserver.shutdown().await;
                return Err(error.into());
            }
        };
        let observer = Arc::new(crate::observer::AppServerObserver::new(
            observer_appserver.clone(),
        ));
        let appserver: Arc<dyn EngineTransport> = Arc::new(appserver);
        // Codex 0.149 can leave a second persistent App Server blocked in its
        // first thread/start while still reporting the process as alive. Use
        // the supervised primary transport for session creation so its timeout
        // and lifecycle are authoritative; keep only the observer isolated.
        let result = Self::bootstrap_with_transport(
            config,
            store,
            appserver.clone(),
            None,
            Some(observer),
            app_server_version,
            schema_probe,
        )
        .await;
        match result {
            Ok(state) => {
                state
                    .spawn_auxiliary_appserver_shutdown(observer_appserver)
                    .await;
                Ok(state)
            }
            Err(error) => {
                let _ = observer_appserver.shutdown().await;
                let _ = appserver.shutdown().await;
                Err(error)
            }
        }
    }

    async fn bootstrap_with_transport(
        config: EngineConfig,
        store: Store,
        appserver: Arc<dyn EngineTransport>,
        session_creator: Option<Arc<dyn EngineTransport>>,
        observer: Option<Arc<dyn IsolatedAppServer>>,
        app_server_version: String,
        schema_probe: RuntimeSchemaProbe,
    ) -> EngineResult<Self> {
        let receiver = appserver.subscribe();
        let model_response = probe_live_models(appserver.as_ref()).await?;
        let capability_hash = hash_json(&json!({
            "modelList": &model_response,
            "schemaSha256": &schema_probe.schema_hash,
        }))?;
        let model_catalog = parse_model_catalog(
            &model_response,
            unix_millis()?,
            &app_server_version,
            &capability_hash,
        )?;
        validate_default_model(&config, &model_catalog)?;

        let epoch = store
            .begin_engine_epoch(NewEngineEpoch {
                engine_id: config.engine_id.clone(),
                started_at: unix_millis()?,
                app_server_version: app_server_version.clone(),
                capability_hash: capability_hash.clone(),
                schema_hash: Some(schema_probe.schema_hash.clone()),
            })
            .await?;
        let lease = store
            .acquire_lease(LeaseRequest {
                lease_key: format!("engine:{}", config.engine_id),
                holder_id: config.engine_id.clone(),
                now: unix_millis()?,
                // Hydrating a long-running thread can exceed the steady-state
                // lease TTL. The same engine holder can still supersede this
                // generation immediately after a crash, while the first
                // successful renewal contracts the lease back to 90 seconds.
                ttl_millis: ENGINE_STARTUP_LEASE_TTL_MILLIS,
                previous_generation: None,
            })
            .await?;
        let stored_catalog = store
            .replace_models(model_catalog, Some(lease.fencing_token(unix_millis()?)))
            .await?;
        let recovered_working_sessions =
            normalize_recovered_session_statuses(&store, &lease).await?;
        let runtime = hydrate_runtime_index(&store).await?;
        let last_global_sequence = load_last_global_sequence(&store).await?;
        let prompt_preference = load_prompt_preference(&config).await?;
        let attachment_http = reqwest::Client::builder()
            .connect_timeout(ATTACHMENT_CONNECT_TIMEOUT)
            .timeout(ATTACHMENT_DOWNLOAD_TIMEOUT)
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(|_| {
                EngineError::Configuration("failed to build relay attachment client".to_owned())
            })?;
        let (live_events, _) = broadcast::channel(LIVE_EVENT_CAPACITY);
        let state = Self {
            core: Arc::new(EngineCore {
                config,
                store,
                appserver,
                session_creator,
                session_creator_slots: Semaphore::new(SESSION_CREATOR_CONCURRENCY),
                attachment_http,
                process_epoch: epoch.epoch,
                app_server_version,
                capability_hash,
                appserver_capabilities: schema_probe.capabilities,
                models: RwLock::new(stored_catalog),
                observer,
                runtime: RwLock::new(runtime),
                lanes: Mutex::new(HashMap::new()),
                scheduled_commands: StdMutex::new(HashSet::new()),
                active_commands: StdMutex::new(HashSet::new()),
                live_events,
                last_global_sequence: AtomicU64::new(last_global_sequence),
                publisher: StdMutex::new(EventPublisher {
                    last_published: last_global_sequence,
                    pending: BTreeMap::new(),
                }),
                lease: RwLock::new(lease),
                admission: RwLock::new(()),
                cancellation: CancellationToken::new(),
                tasks: Mutex::new(Vec::new()),
                prompt_preference: RwLock::new(prompt_preference),
                ready: AtomicBool::new(false),
                shutdown_started: AtomicBool::new(false),
            }),
        };
        state.spawn_event_loop(receiver).await;
        state.spawn_lease_renewal().await;
        state.recover_pending_commands().await?;
        state
            .enqueue_recovered_session_continuations(recovered_working_sessions)
            .await?;
        state.spawn_command_sweeper().await;
        state.spawn_outbound_bridge().await;
        state.core.ready.store(true, Ordering::Release);
        Ok(state)
    }

    async fn enqueue_recovered_session_continuations(
        &self,
        recovered: Vec<RecoveredWorkingSession>,
    ) -> EngineResult<()> {
        for session in recovered {
            let recovery_ref = format!("{}:{}", session.session_id, session.updated_at);
            let request = CommandRequest {
                command_id: None,
                idempotency_key: format!("crash-recovery:{recovery_ref}"),
                session_id: Some(session.session_id),
                command: CommandKind::SendMessage {
                    content: CRASH_RECOVERY_MESSAGE.to_owned(),
                    client_message_id: format!("crash-recovery:{recovery_ref}"),
                    attachments: Vec::new(),
                    service_tier: None,
                },
                requested_at: unix_millis()?,
                trace_id: Some(format!("{CRASH_RECOVERY_TRACE_PREFIX}{recovery_ref}")),
            };
            self.submit_command(request).await?;
        }
        Ok(())
    }

    pub fn store(&self) -> Store {
        self.core.store.clone()
    }

    pub fn capability_hash(&self) -> &str {
        &self.core.capability_hash
    }

    pub fn subscribe_events(&self) -> broadcast::Receiver<DurableEvent> {
        self.core.live_events.subscribe()
    }

    pub async fn health(&self) -> EngineHealth {
        let model_count = self.core.models.read().await.models.len();
        let session_count = self.core.runtime.read().await.sessions.len();
        EngineHealth {
            ready: self.core.ready.load(Ordering::Acquire),
            app_server_running: self.core.appserver.is_running(),
            engine_id: self.core.config.engine_id.clone(),
            process_epoch: self.core.process_epoch,
            app_server_epoch: self.core.appserver.epoch(),
            model_count,
            session_count,
        }
    }

    pub fn is_ready(&self) -> bool {
        self.core.ready.load(Ordering::Acquire) && self.core.appserver.is_running()
    }

    pub async fn cancelled(&self) {
        self.core.cancellation.cancelled().await;
    }

    pub async fn list_sessions(&self) -> EngineResult<Vec<SessionSummary>> {
        Ok(self
            .core
            .store
            .list_sessions()
            .await?
            .into_iter()
            .filter(|stored| {
                stored.session.managed_by_fermin
                    && stored.session.runtime_status.as_deref() != Some("ARCHIVED")
            })
            .map(|stored| stored.session)
            .collect())
    }

    pub async fn session(&self, session_id: &str) -> EngineResult<Option<SessionSummary>> {
        let Some(stored) = self.core.store.get_session(session_id).await? else {
            return Ok(None);
        };
        if !stored.session.managed_by_fermin
            || stored.session.runtime_status.as_deref() == Some("ARCHIVED")
        {
            return Ok(None);
        }
        let has_cached_transcript = !self.core.store.list_messages(session_id).await?.is_empty();
        if has_cached_transcript && self.claim_transcript_hydration(session_id).await {
            self.spawn_cached_transcript_reconciliation(session_id.to_owned())
                .await;
        } else if !has_cached_transcript
            && self
                .core
                .runtime
                .read()
                .await
                .sessions
                .get(session_id)
                .is_some_and(|runtime| !runtime.transcript_hydrated)
        {
            self.hydrate_session_transcript(session_id).await?;
        }
        let Some(mut stored) = self.core.store.get_session(session_id).await? else {
            return Ok(None);
        };
        let stored_message_count = stored.session.message_count;
        let stored_last_message_preview = stored.session.last_message_preview.clone();
        stored.session.messages = collapse_provider_snapshot_aliases(
            self.core
                .store
                .list_messages(session_id)
                .await?
                .into_iter()
                .map(|stored| stored.message)
                .collect(),
        );
        stored.session.message_count = stored.session.messages.len() as u64;
        stored.session.last_message_preview = stored
            .session
            .messages
            .last()
            .map(|message| crate::protocol::bounded_session_preview(&message.content));
        if stored.session.message_count != stored_message_count
            || stored.session.last_message_preview != stored_last_message_preview
        {
            let mut lightweight = stored.session.clone();
            lightweight.messages.clear();
            self.core
                .store
                .upsert_session(lightweight, Some(self.fence().await?))
                .await?;
        }
        Ok(Some(stored.session))
    }

    pub async fn models(&self) -> ModelCatalog {
        self.core.models.read().await.clone()
    }

    pub async fn replay_events(
        &self,
        after_global_sequence: u64,
        limit: usize,
    ) -> EngineResult<Vec<DurableEvent>> {
        Ok(self
            .core
            .store
            .replay_events(
                EventCursor {
                    after_global_sequence,
                },
                limit,
            )
            .await?)
    }

    pub async fn snapshot(&self) -> EngineResult<AuthoritativeSnapshot> {
        self.snapshot_from_store(true).await
    }

    async fn mobile_snapshot(&self) -> EngineResult<AuthoritativeSnapshot> {
        self.snapshot_from_store(false).await
    }

    async fn snapshot_from_store(
        &self,
        include_messages: bool,
    ) -> EngineResult<AuthoritativeSnapshot> {
        let durable = self
            .core
            .store
            .state_snapshot(include_messages, None)
            .await?;
        let sessions = durable
            .sessions
            .into_iter()
            .filter(|stored| {
                stored.session.managed_by_fermin
                    && stored.session.runtime_status.as_deref() != Some("ARCHIVED")
            })
            .map(|stored| stored.session)
            .collect();
        Ok(AuthoritativeSnapshot {
            schema_version: crate::protocol::MOBILE_SCHEMA_VERSION,
            global_sequence: durable.global_sequence,
            generated_at: unix_millis()?,
            sessions,
            models: durable
                .models
                .map(|catalog| catalog.models)
                .unwrap_or_default(),
        })
    }

    pub async fn submit_command(
        &self,
        mut request: CommandRequest,
    ) -> EngineResult<CommandAcceptance> {
        if self.core.cancellation.is_cancelled() {
            return Err(EngineError::ShuttingDown);
        }
        let _admission = self.core.admission.read().await;
        if self.core.cancellation.is_cancelled() {
            return Err(EngineError::ShuttingDown);
        }
        validate_command_request(&request)?;
        if matches!(&request.command, CommandKind::SendMessage { .. })
            && prompt_variant_from_trace(request.trace_id.as_deref()).is_none()
        {
            let variant = self.core.prompt_preference.read().await.variant;
            request = Self::attach_prompt_improver_variant(request, variant);
        }
        let acceptance = self
            .core
            .store
            .accept_command_fenced(request, Some(self.fence().await?))
            .await?;
        if !acceptance.command.state.is_terminal() {
            self.enqueue_command(&acceptance.command).await?;
        }
        Ok(acceptance)
    }

    pub async fn wait_for_command(
        &self,
        command_id: &str,
        timeout: Duration,
    ) -> EngineResult<CommandRecord> {
        let deadline = time::Instant::now() + timeout;
        loop {
            let command = self
                .core
                .store
                .get_command(command_id)
                .await?
                .ok_or_else(|| {
                    EngineError::InvalidResponse(format!("unknown command {command_id}"))
                })?;
            if command.state.is_terminal() {
                return Ok(command);
            }
            if time::Instant::now() >= deadline {
                return Err(EngineError::AppServer(AppServerError::Timeout {
                    epoch: self.core.appserver.epoch(),
                    method: format!("command/{command_id}"),
                    timeout,
                }));
            }
            time::sleep(Duration::from_millis(20)).await;
        }
    }

    pub async fn run_prompt_improver(
        &self,
        session_id: &str,
        message_id: &str,
    ) -> EngineResult<()> {
        self.transform_message(session_id, message_id, None, None)
            .await?;
        Ok(())
    }

    pub async fn run_explainer(&self, session_id: &str, focus: Option<&str>) -> EngineResult<()> {
        let observer = self
            .core
            .observer
            .as_deref()
            .ok_or(EngineError::ObserverUnavailable)?;
        let summary = self.required_summary(session_id).await?;
        let messages = self.core.store.list_messages(session_id).await?;
        let evidence = serde_json::to_string(
            &messages
                .iter()
                .map(|stored| &stored.message)
                .collect::<Vec<_>>(),
        )?;
        let mut input = ExplainerInput::new(evidence.clone());
        input.current_request = focus.unwrap_or_default().to_owned();
        input.language = ResponseLanguage::Spanish;
        input.context = ObserverContext {
            dossier: evidence,
            working_directory: summary.project_path.as_deref().map(PathBuf::from),
            session_file: summary.provider_session_path.as_deref().map(PathBuf::from),
            inspect_workspace: summary.features.code_context_enabled,
        };
        let explanation = explain_result(observer, &input).await?;
        let now = unix_millis()?;
        let mut message = Message::assistant(
            format!("explainer-{}", uuid::Uuid::now_v7()),
            explanation.markdown,
            now,
        );
        message.message_type = Some("explainer".to_owned());
        message.status = Some("done".to_owned());
        self.persist_message_patch(session_id, message, 1, now, true)
            .await?;
        self.refresh_session_message_metadata(session_id, summary.activity_status)
            .await?;
        Ok(())
    }

    pub async fn shutdown(&self) -> EngineResult<()> {
        if self.core.shutdown_started.swap(true, Ordering::AcqRel) {
            return Ok(());
        }
        self.core.ready.store(false, Ordering::Release);
        self.core.cancellation.cancel();
        let _admission = self.core.admission.write().await;
        self.core.lanes.lock().await.clear();
        let handles = std::mem::take(&mut *self.core.tasks.lock().await);
        for handle in handles {
            if let Err(join_error) = handle.await {
                warn!(error = %join_error, "owned engine task failed during shutdown");
            }
        }
        let release_token = self.core.lease.read().await.fencing_token(unix_millis()?);
        if let Err(error) = self.core.store.release_lease(release_token).await {
            warn!(error = %error, "engine lease was already stale during shutdown");
        }
        let creator_result = if let Some(creator) = &self.core.session_creator {
            creator.shutdown().await
        } else {
            Ok(())
        };
        let appserver_result = self.core.appserver.shutdown().await;
        self.core.store.checkpoint().await?;
        creator_result?;
        appserver_result?;
        Ok(())
    }

    async fn spawn_event_loop(&self, receiver: broadcast::Receiver<AppServerEvent>) {
        let weak = Arc::downgrade(&self.core);
        let cancellation = self.core.cancellation.clone();
        let handle = tokio::spawn(async move {
            event_loop(weak, receiver, cancellation).await;
        });
        self.core.tasks.lock().await.push(handle);
    }

    async fn spawn_auxiliary_appserver_shutdown(&self, appserver: AppServerClient) {
        let cancellation = self.core.cancellation.clone();
        let handle = tokio::spawn(async move {
            cancellation.cancelled().await;
            if let Err(error) = appserver.shutdown().await {
                warn!(error = %error, "dedicated observer App Server shutdown failed");
            }
        });
        self.core.tasks.lock().await.push(handle);
    }

    async fn spawn_lease_renewal(&self) {
        let weak = Arc::downgrade(&self.core);
        let cancellation = self.core.cancellation.clone();
        let handle = tokio::spawn(async move {
            let mut interval = time::interval(ENGINE_LEASE_RENEW_INTERVAL);
            interval.set_missed_tick_behavior(time::MissedTickBehavior::Delay);
            interval.tick().await;
            loop {
                tokio::select! {
                    () = cancellation.cancelled() => break,
                    _ = interval.tick() => {
                        let Some(core) = weak.upgrade() else { break };
                        let state = EngineState { core };
                        if let Err(error) = state.renew_lease().await {
                            error!(error = %error, "engine lease renewal failed");
                            state.core.ready.store(false, Ordering::Release);
                            state.core.cancellation.cancel();
                            break;
                        }
                    }
                }
            }
        });
        self.core.tasks.lock().await.push(handle);
    }

    async fn spawn_outbound_bridge(&self) {
        let Some(config) = self.core.config.relay.clone() else {
            return;
        };
        let source = Arc::new(self.clone());
        let cancellation = self.core.cancellation.clone();
        let handle = tokio::spawn(async move {
            if let Err(error) =
                crate::bridge::run_outbound_bridge(source, config, cancellation).await
            {
                error!(error = %error, "outbound relay bridge stopped");
            }
        });
        self.core.tasks.lock().await.push(handle);
    }

    async fn spawn_command_sweeper(&self) {
        let weak = Arc::downgrade(&self.core);
        let cancellation = self.core.cancellation.clone();
        let handle = tokio::spawn(async move {
            let mut interval = time::interval(COMMAND_SWEEP_INTERVAL);
            interval.set_missed_tick_behavior(time::MissedTickBehavior::Delay);
            interval.tick().await;
            loop {
                tokio::select! {
                    () = cancellation.cancelled() => break,
                    _ = interval.tick() => {
                        let Some(core) = weak.upgrade() else { break };
                        let state = EngineState { core };
                        if let Err(error) = state.sweep_pending_commands().await {
                            error!(error = %error, "durable command sweep failed");
                        }
                    }
                }
            }
        });
        self.core.tasks.lock().await.push(handle);
    }

    async fn renew_lease(&self) -> EngineResult<()> {
        let current = self.core.lease.read().await.clone();
        let renewed = self
            .core
            .store
            .renew_lease(
                current.fencing_token(unix_millis()?),
                ENGINE_LEASE_TTL_MILLIS,
            )
            .await?;
        *self.core.lease.write().await = renewed;
        Ok(())
    }

    async fn fence(&self) -> EngineResult<FencingToken> {
        Ok(self.core.lease.read().await.fencing_token(unix_millis()?))
    }

    async fn recover_pending_commands(&self) -> EngineResult<()> {
        self.sweep_pending_commands().await
    }

    async fn sweep_pending_commands(&self) -> EngineResult<()> {
        for command in self.core.store.pending_commands(10_000).await? {
            if lock_std(&self.core.active_commands).contains(&command.command_id) {
                continue;
            }
            if command.state == CommandState::SentToChild {
                let _ = self
                    .transition_command(
                        &command,
                        Some(CommandState::SentToChild),
                        CommandState::Unknown,
                        Some("engine restarted after child delivery became ambiguous".to_owned()),
                    )
                    .await?;
            } else {
                self.enqueue_command(&command).await?;
            }
        }
        Ok(())
    }

    async fn enqueue_command(&self, command: &CommandRecord) -> EngineResult<()> {
        {
            let mut scheduled = lock_std(&self.core.scheduled_commands);
            if !scheduled.insert(command.command_id.clone()) {
                return Ok(());
            }
        }
        let marker = ScheduledCommandGuard::new(&self.core, command.command_id.clone());
        let lane_key = command_lane_key(command);
        let sender = self.command_lane(&lane_key).await;
        if sender.send(command.command_id.clone()).await.is_err() {
            return Err(EngineError::CommandLaneClosed(command.command_id.clone()));
        }
        marker.retain_marker();
        Ok(())
    }

    async fn command_lane(&self, lane_key: &str) -> mpsc::Sender<String> {
        let mut lanes = self.core.lanes.lock().await;
        if let Some(sender) = lanes.get(lane_key) {
            return sender.clone();
        }
        let (sender, receiver) = mpsc::channel(COMMAND_LANE_CAPACITY);
        lanes.insert(lane_key.to_owned(), sender.clone());
        let weak = Arc::downgrade(&self.core);
        let cancellation = self.core.cancellation.clone();
        let lane_name = lane_key.to_owned();
        let handle = tokio::spawn(async move {
            command_lane_loop(weak, lane_name, receiver, cancellation).await;
        });
        self.core.tasks.lock().await.push(handle);
        sender
    }

    async fn process_command_id(&self, command_id: &str) -> EngineResult<()> {
        let Some(mut command) = self.core.store.get_command(command_id).await? else {
            return Ok(());
        };
        if command.state.is_terminal() {
            return Ok(());
        }
        if command.state == CommandState::Accepted {
            command = self
                .transition_command(
                    &command,
                    Some(CommandState::Accepted),
                    CommandState::Leased,
                    None,
                )
                .await?;
        }
        if command.state == CommandState::Leased {
            command = self
                .transition_command(
                    &command,
                    Some(CommandState::Leased),
                    CommandState::EngineDurable,
                    None,
                )
                .await?;
        }
        let external_delivery = command_has_external_side_effects(&command);
        if command.state == CommandState::EngineDurable && external_delivery {
            command = self
                .transition_command(
                    &command,
                    Some(CommandState::EngineDurable),
                    CommandState::SentToChild,
                    None,
                )
                .await?;
        }
        let executing_state = if external_delivery {
            CommandState::SentToChild
        } else {
            CommandState::EngineDurable
        };
        if command.state != executing_state {
            return Ok(());
        }

        match self.handle_command(&command).await {
            Ok(()) => {
                let _ = self
                    .transition_command(
                        &command,
                        Some(executing_state),
                        CommandState::Completed,
                        None,
                    )
                    .await?;
            }
            Err(error) => {
                let new_state = if error.is_ambiguous_child_execution()
                    || (external_delivery && error.may_follow_external_side_effect())
                {
                    CommandState::Unknown
                } else {
                    CommandState::Failed
                };
                let _ = self
                    .transition_command(
                        &command,
                        Some(executing_state),
                        new_state,
                        Some(redacted_error(&error)),
                    )
                    .await?;
            }
        }
        Ok(())
    }

    async fn transition_command(
        &self,
        command: &CommandRecord,
        expected_state: Option<CommandState>,
        new_state: CommandState,
        error: Option<String>,
    ) -> EngineResult<CommandRecord> {
        let now = unix_millis()?;
        let mutation = self
            .core
            .store
            .transition_command(
                CommandTransition {
                    command_id: command.command_id.clone(),
                    expected_state,
                    new_state,
                    updated_at: now,
                    error: error.clone(),
                    event: Some(NewEvent {
                        event_id: Some(format!(
                            "command:{}:{}",
                            command.command_id,
                            new_state.as_str()
                        )),
                        session_id: command.session_id.clone(),
                        command_id: Some(command.command_id.clone()),
                        process_epoch: Some(self.core.process_epoch),
                        kind: EventKind::CommandStateChanged,
                        payload: json!({
                            "commandId": command.command_id,
                            "state": new_state,
                            "error": error,
                        }),
                        created_at: now,
                    }),
                },
                Some(self.fence().await?),
            )
            .await?;
        if let Some(event) = mutation.event {
            self.publish_event(event);
        }
        Ok(mutation.command)
    }

    async fn handle_command(&self, command: &CommandRecord) -> EngineResult<()> {
        match &command.command {
            CommandKind::CreateSession {
                project_path,
                display_name,
                model,
                reasoning_effort,
            } => {
                self.handle_create_session(
                    command,
                    project_path,
                    display_name.as_deref(),
                    model.as_deref(),
                    reasoning_effort.as_deref(),
                )
                .await
            }
            CommandKind::RecoverSession => {
                self.handle_recover_session(required_session_id(command)?).await
            }
            CommandKind::SendMessage {
                content,
                client_message_id,
                attachments,
                service_tier,
            } => {
                self.handle_send_message(
                    command,
                    required_session_id(command)?,
                    content,
                    client_message_id,
                    attachments,
                    SendMessageOptions {
                        service_tier: service_tier.as_deref(),
                        allow_prompt_improver: !trace_contains_prefix(
                            command.trace_id.as_deref(),
                            CRASH_RECOVERY_TRACE_PREFIX,
                        ),
                    },
                )
                .await
            }
            CommandKind::Steer { content } => {
                self.handle_steer(command, required_session_id(command)?, content)
                    .await
            }
            CommandKind::Interrupt => self.handle_interrupt(required_session_id(command)?).await,
            CommandKind::Archive => self.handle_archive(required_session_id(command)?).await,
            CommandKind::Delete => self.handle_delete(required_session_id(command)?).await,
            CommandKind::Rename { display_name } => {
                self.handle_rename(required_session_id(command)?, display_name)
                    .await
            }
            CommandKind::SetMinimized { minimized } => {
                self.handle_minimize(command, required_session_id(command)?, *minimized)
                    .await
            }
            CommandKind::SetPinned { pinned } => {
                self.handle_pinned(required_session_id(command)?, *pinned)
                    .await
            }
            CommandKind::SetFeatures { features } => {
                self.handle_features(required_session_id(command)?, features.clone())
                    .await
            }
            CommandKind::SetModel { settings } => {
                self.handle_model_settings(required_session_id(command)?, settings)
                    .await
            }
            CommandKind::SetRunMode {
                run_mode,
                objective,
            } => {
                self.handle_run_mode(
                    required_session_id(command)?,
                    *run_mode,
                    objective.as_deref(),
                )
                .await
            }
            CommandKind::CreateSubagent {
                prompt,
                display_name,
                parent_notification_prompt,
            } => {
                self.handle_create_subagent(
                    command,
                    required_session_id(command)?,
                    prompt,
                    display_name.as_deref(),
                    parent_notification_prompt.as_deref(),
                )
                .await
            }
            CommandKind::RunPromptImprover { message_id, prompt } => {
                self.transform_message(
                    required_session_id(command)?,
                    message_id,
                    Some(prompt.as_str()),
                    prompt_variant_from_trace(command.trace_id.as_deref()),
                )
                .await?;
                Ok(())
            }
            CommandKind::RetryPromptTransform { message_id } => {
                self.transform_message(
                    required_session_id(command)?,
                    message_id,
                    None,
                    prompt_variant_from_trace(command.trace_id.as_deref()),
                )
                .await?;
                Ok(())
            }
            CommandKind::RunExplainer { focus } => {
                self.run_explainer(required_session_id(command)?, focus.as_deref())
                    .await
            }
            CommandKind::RespondApproval { .. } | CommandKind::RespondUserInput { .. } => Err(
                EngineError::UnsupportedCommand(
                    "interactive approval and user-input responses are disabled while approvalPolicy=never"
                        .to_owned(),
                ),
            ),
        }
    }

    async fn handle_create_session(
        &self,
        command: &CommandRecord,
        project_path: &str,
        display_name: Option<&str>,
        model: Option<&str>,
        reasoning_effort: Option<&str>,
    ) -> EngineResult<()> {
        let project_path = self.validated_project_path(project_path)?;
        let model = model.unwrap_or(&self.core.config.default_model);
        let effort = reasoning_effort.unwrap_or(&self.core.config.default_effort);
        self.validate_model_settings(&RuntimeModelSettings {
            model: model.to_owned(),
            model_provider: Some("openai".to_owned()),
            effort: effort.to_owned(),
        })
        .await?;
        let requested_name = display_name
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_owned);
        let (response, appserver_loaded, dedicated_creator) = self
            .request_session_thread_start(
                json!({
                "cwd": project_path,
                "model": model,
                "modelProvider": "openai",
                "approvalPolicy": "never",
                "ephemeral": false,
                "config": { "model_reasoning_effort": effort },
                }),
                requested_name.as_deref(),
                model,
                effort,
            )
            .await?;
        let thread = response.get("thread").ok_or_else(|| {
            EngineError::InvalidResponse("thread/start omitted thread".to_owned())
        })?;
        let thread_id = required_string(thread, "id")?;
        let session_id = command
            .session_id
            .clone()
            .unwrap_or_else(|| thread_id.clone());
        let mut summary = summary_from_thread(thread, &session_id, unix_millis()?)?;
        summary.managed_by_fermin = true;
        summary.model = Some(
            response
                .get("model")
                .and_then(Value::as_str)
                .unwrap_or(model)
                .to_owned(),
        );
        summary.reasoning_effort = Some(
            response
                .get("reasoningEffort")
                .and_then(Value::as_str)
                .unwrap_or(effort)
                .to_owned(),
        );
        if let Some(display_name) = requested_name.as_deref() {
            summary.display_name = display_name.to_owned();
            summary.window_name = Some(summary.display_name.clone());
        }
        let persistence_name = requested_name.clone().unwrap_or_else(|| {
            thread
                .get("name")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(str::to_owned)
                .unwrap_or_else(|| "Fermín Code session".to_owned())
        });
        if dedicated_creator {
            summary.can_send = false;
            summary.runtime_status = Some("STARTING".to_owned());
            summary.runtime_status_detail = Some("Finalizando la sesión".to_owned());
        }
        self.upsert_runtime_session(summary.clone(), None).await?;
        self.set_appserver_loaded(&session_id, appserver_loaded)
            .await;
        self.set_transcript_hydrated(&session_id, true).await;
        if dedicated_creator {
            if let Err(error) = self
                .persist_created_thread(&thread_id, &persistence_name)
                .await
            {
                self.remove_provisional_session(&session_id, &thread_id)
                    .await?;
                return Err(error);
            }
            summary.can_send = true;
            summary.runtime_status = Some("WAITING".to_owned());
            summary.runtime_status_detail = None;
            summary.updated_at = unix_millis()?;
            self.upsert_runtime_session(summary, None).await?;
        } else if let Some(display_name) = requested_name {
            self.spawn_thread_name_update(thread_id, display_name).await;
        }
        Ok(())
    }

    async fn handle_recover_session(&self, session_id: &str) -> EngineResult<()> {
        let stored = self
            .core
            .store
            .get_session(session_id)
            .await?
            .ok_or_else(|| EngineError::SessionNotFound(session_id.to_owned()))?;
        if stored.session.managed_by_fermin {
            if stored.session.runtime_status.as_deref() == Some("ARCHIVED") {
                return Err(EngineError::UnsupportedCommand(
                    "la sesión ya pertenece a Fermín Code; reanudala desde Historial".to_owned(),
                ));
            }
            self.ensure_session_loaded(session_id).await?;
            let mut summary = self.required_summary(session_id).await?;
            summary.is_minimized = false;
            summary.updated_at = unix_millis()?;
            self.upsert_runtime_session(summary, None).await?;
            return Ok(());
        }

        let thread_id = stored
            .session
            .provider_session_id
            .clone()
            .unwrap_or_else(|| session_id.to_owned());
        let was_archived = stored.session.runtime_status.as_deref() == Some("ARCHIVED");
        if was_archived {
            match self
                .request_with_overload_retry(
                    "thread/unarchive",
                    json!({ "threadId": thread_id.clone() }),
                )
                .await
            {
                Ok(_) => {}
                Err(error) if is_missing_provider_rollout(&error, "thread/unarchive") => {}
                Err(error) => return Err(error),
            }
        }
        let response = match self
            .request_with_overload_retry(
                "thread/resume",
                json!({
                    "threadId": thread_id.clone(),
                    "approvalPolicy": "never",
                }),
            )
            .await
        {
            Ok(response) => response,
            Err(error) if !was_archived && is_missing_provider_rollout(&error, "thread/resume") => {
                self.request_with_overload_retry(
                    "thread/unarchive",
                    json!({ "threadId": thread_id.clone() }),
                )
                .await?;
                self.request_with_overload_retry(
                    "thread/resume",
                    json!({
                        "threadId": thread_id.clone(),
                        "approvalPolicy": "never",
                    }),
                )
                .await?
            }
            Err(error) => return Err(error),
        };
        let thread = response.get("thread").ok_or_else(|| {
            EngineError::InvalidResponse("thread/resume omitted recovered thread".to_owned())
        })?;
        if thread.get("id").and_then(Value::as_str) != Some(thread_id.as_str()) {
            return Err(EngineError::InvalidResponse(
                "thread/resume returned the wrong recovered thread".to_owned(),
            ));
        }
        self.reconcile_thread_with_ownership(thread, Some(session_id), true)
            .await?;
        let mut recovered = self.required_summary(session_id).await?;
        recovered.model = response
            .get("model")
            .and_then(Value::as_str)
            .map(str::to_owned)
            .or(recovered.model);
        recovered.reasoning_effort = response
            .get("reasoningEffort")
            .and_then(Value::as_str)
            .map(str::to_owned)
            .or(recovered.reasoning_effort);
        recovered.is_minimized = false;
        recovered.can_send = true;
        recovered.runtime_status_detail = None;
        recovered.updated_at = unix_millis()?;
        self.upsert_runtime_session(recovered, None).await?;
        self.set_appserver_loaded(session_id, true).await;
        self.set_transcript_hydrated(session_id, true).await;
        Ok(())
    }

    async fn request_session_thread_start(
        &self,
        params: Value,
        _requested_name: Option<&str>,
        expected_model: &str,
        expected_effort: &str,
    ) -> EngineResult<(Value, bool, bool)> {
        let Some(creator) = self
            .core
            .session_creator
            .as_ref()
            .filter(|creator| creator.is_running())
        else {
            let response = self
                .request_with_overload_retry("thread/start", params)
                .await?;
            validate_effective_model_response(&response, expected_model, expected_effort)?;
            return Ok((response, true, false));
        };
        let _permit = self
            .core
            .session_creator_slots
            .acquire()
            .await
            .map_err(|_| EngineError::ShuttingDown)?;
        let response =
            request_transport_with_overload_retry(creator.as_ref(), "thread/start", params).await?;
        validate_effective_model_response(&response, expected_model, expected_effort)?;
        Ok((response, false, true))
    }

    async fn persist_created_thread(
        &self,
        thread_id: &str,
        display_name: &str,
    ) -> EngineResult<()> {
        let creator = self
            .core
            .session_creator
            .as_ref()
            .filter(|creator| creator.is_running())
            .ok_or_else(|| {
                EngineError::InvalidResponse(
                    "dedicated session creator stopped before persistence".to_owned(),
                )
            })?;
        if let Err(error) = request_transport_with_overload_retry(
            creator.as_ref(),
            "thread/name/set",
            json!({ "threadId": thread_id, "name": display_name }),
        )
        .await
        {
            let _ = request_transport_with_overload_retry(
                creator.as_ref(),
                "thread/delete",
                json!({ "threadId": thread_id }),
            )
            .await;
            return Err(error);
        }
        if let Err(error) = request_transport_with_overload_retry(
            creator.as_ref(),
            "thread/archive",
            json!({ "threadId": thread_id }),
        )
        .await
        {
            let _ = request_transport_with_overload_retry(
                creator.as_ref(),
                "thread/delete",
                json!({ "threadId": thread_id }),
            )
            .await;
            return Err(error);
        }
        let unarchived = match request_transport_with_overload_retry(
            creator.as_ref(),
            "thread/unarchive",
            json!({ "threadId": thread_id }),
        )
        .await
        {
            Ok(unarchived) => unarchived,
            Err(error) => {
                let _ = request_transport_with_overload_retry(
                    creator.as_ref(),
                    "thread/delete",
                    json!({ "threadId": thread_id }),
                )
                .await;
                return Err(error);
            }
        };
        if unarchived.pointer("/thread/id").and_then(Value::as_str) != Some(thread_id) {
            let _ = request_transport_with_overload_retry(
                creator.as_ref(),
                "thread/delete",
                json!({ "threadId": thread_id }),
            )
            .await;
            return Err(EngineError::InvalidResponse(
                "thread/unarchive returned the wrong created thread".to_owned(),
            ));
        }
        if let Err(error) = request_transport_with_overload_retry(
            creator.as_ref(),
            "thread/unsubscribe",
            json!({ "threadId": thread_id }),
        )
        .await
        {
            warn!(error = %error, "dedicated session creator unsubscribe failed");
        }
        Ok(())
    }

    async fn remove_provisional_session(
        &self,
        session_id: &str,
        thread_id: &str,
    ) -> EngineResult<()> {
        let event = NewEvent {
            event_id: None,
            session_id: Some(session_id.to_owned()),
            command_id: None,
            process_epoch: Some(self.core.process_epoch),
            kind: EventKind::SessionRemoved,
            payload: json!({ "windowId": session_id, "sessionId": session_id }),
            created_at: unix_millis()?,
        };
        let mutation = self
            .core
            .store
            .delete_session_with_event(session_id.to_owned(), event, Some(self.fence().await?))
            .await?;
        if let Some(event) = mutation.event {
            self.publish_event(event);
        }
        self.remove_runtime_session(session_id, thread_id).await;
        Ok(())
    }

    async fn spawn_thread_name_update(&self, thread_id: String, display_name: String) {
        let state = self.clone();
        let cancellation = self.core.cancellation.clone();
        let handle = tokio::spawn(async move {
            tokio::select! {
                () = cancellation.cancelled() => {}
                result = state.request_with_overload_retry(
                    "thread/name/set",
                    json!({ "threadId": thread_id, "name": display_name }),
                ) => {
                    if let Err(error) = result {
                        warn!(error = %error, "deferred thread name update failed");
                    }
                }
            }
        });
        self.core.tasks.lock().await.push(handle);
    }

    async fn handle_send_message(
        &self,
        command: &CommandRecord,
        session_id: &str,
        content: &str,
        client_message_id: &str,
        attachments: &[crate::protocol::ImageAttachment],
        options: SendMessageOptions<'_>,
    ) -> EngineResult<()> {
        if content.trim().is_empty() && attachments.is_empty() {
            return Err(EngineError::UnsupportedCommand(
                "message content and attachments are both empty".to_owned(),
            ));
        }
        self.ensure_session_loaded(session_id).await?;
        let outbound_attachments = self
            .validated_turn_attachments(session_id, attachments)
            .await?;
        let summary = self
            .core
            .store
            .get_session(session_id)
            .await?
            .ok_or_else(|| EngineError::SessionNotFound(session_id.to_owned()))?
            .session;
        let runtime = self.runtime_session(session_id).await?;
        let now = unix_millis()?;
        let mut user_message = Message::user(client_message_id, content, now);
        user_message.message_type = Some("localUserMessage".to_owned());
        user_message.image_attachments = attachments.to_vec();
        if options.allow_prompt_improver
            && summary.features.prompt_improver_enabled
            && !content.trim().is_empty()
        {
            user_message.transform_status = Some("pending".to_owned());
        }
        self.persist_message_patch(session_id, user_message, 1, now, true)
            .await?;
        self.refresh_session_message_metadata(session_id, ActivityStatus::Working)
            .await?;

        let prompt_improver_enabled = options.allow_prompt_improver
            && summary.features.prompt_improver_enabled
            && !content.trim().is_empty();
        let outbound_content = if prompt_improver_enabled {
            let transformed = self
                .transform_message(
                    session_id,
                    client_message_id,
                    Some(content),
                    prompt_variant_from_trace(command.trace_id.as_deref()),
                )
                .await
                .inspect_err(|error| {
                    warn!(
                        session_id,
                        message_id = client_message_id,
                        error = %redacted_error(error),
                        "prompt improver failed; Codex turn was not started"
                    );
                })?;
            prompt_improver_turn_content(content, &transformed)
        } else {
            content.to_owned()
        };
        let mut input = build_turn_input(&outbound_content, &outbound_attachments);
        if summary.run_mode == RunMode::Goal
            && !self.core.appserver_capabilities.supports_native_goals()
        {
            input.insert(
                0,
                json!({
                    "type": "text",
                    "text": goal_fallback_bootstrap(&self.goal_objective_path(session_id)),
                }),
            );
        }
        if options.service_tier.is_some_and(|tier| tier != "fast") {
            return Err(EngineError::UnsupportedCommand(
                "unsupported App Server service tier".to_owned(),
            ));
        }
        let turn_params = json!({
            "threadId": runtime.thread_id,
            "input": input,
            "model": summary.model,
            "effort": summary.reasoning_effort,
            "approvalPolicy": "never",
            "serviceTier": options.service_tier,
        });
        let response = self
            .request_with_overload_retry("turn/start", turn_params)
            .await?;
        let turn_id = response
            .pointer("/turn/id")
            .and_then(Value::as_str)
            .ok_or_else(|| EngineError::InvalidResponse("turn/start omitted turn.id".to_owned()))?
            .to_owned();
        self.set_active_turn(session_id, Some(turn_id)).await;
        Ok(())
    }

    async fn transform_message(
        &self,
        session_id: &str,
        message_id: &str,
        prompt_override: Option<&str>,
        variant_override: Option<crate::api::PromptImproverVariant>,
    ) -> EngineResult<String> {
        let observer = self
            .core
            .observer
            .as_deref()
            .ok_or(EngineError::ObserverUnavailable)?;
        let summary = self.required_summary(session_id).await?;
        let stored = self
            .core
            .store
            .list_messages(session_id)
            .await?
            .into_iter()
            .find(|stored| stored.message.id == message_id)
            .ok_or_else(|| {
                EngineError::InvalidResponse(format!("message {message_id} was not found"))
            })?;
        let prompt = prompt_override
            .map(str::to_owned)
            .or_else(|| stored.message.original_prompt.clone())
            .unwrap_or_else(|| stored.message.content.clone());
        if prompt.trim().is_empty() {
            return Err(EngineError::UnsupportedCommand(
                "Prompt Improver requires non-empty message text".to_owned(),
            ));
        }

        let pending_revision = stored.revision.saturating_add(1);
        let now = unix_millis()?;
        let mut pending = stored.message.clone();
        pending.original_prompt = Some(prompt.clone());
        pending.transform_status = Some("pending".to_owned());
        pending.transform_error_reason = None;
        pending.prompt_transform_note = None;
        self.persist_message_patch(session_id, pending.clone(), pending_revision, now, true)
            .await?;

        let messages = self
            .core
            .store
            .list_messages(session_id)
            .await?
            .into_iter()
            .map(|stored| stored.message)
            .collect();
        let dossier = prompt_improver_dossier(messages, message_id)?;
        let preference = match variant_override {
            Some(variant) => variant,
            None => self.core.prompt_preference.read().await.variant,
        };
        let mut input = PromptImproverInput::new(prompt.clone());
        input.language = ResponseLanguage::Spanish;
        input.variant = match preference {
            crate::api::PromptImproverVariant::Standard => {
                crate::features::PromptImproverVariant::Standard
            }
            crate::api::PromptImproverVariant::Motivational => {
                crate::features::PromptImproverVariant::Motivational
            }
        };
        input.context = ObserverContext {
            dossier,
            working_directory: summary.project_path.as_deref().map(PathBuf::from),
            session_file: summary.provider_session_path.as_deref().map(PathBuf::from),
            inspect_workspace: summary.features.code_context_enabled,
        };
        match improve_prompt(observer, input).await {
            Ok(improvement) => {
                let updated_at = unix_millis()?;
                pending.transformed_prompt = Some(improvement.transformed_prompt.clone());
                pending.improved_prompt = Some(improvement.transformed_prompt.clone());
                pending.transform_status = Some("done".to_owned());
                pending.prompt_transform_note = (improvement.disposition
                    == FidelityDisposition::Fallback)
                    .then(|| "raw-error".to_owned());
                self.persist_message_patch(
                    session_id,
                    pending,
                    pending_revision.saturating_add(1),
                    updated_at,
                    true,
                )
                .await?;
                Ok(improvement.transformed_prompt)
            }
            Err(error) => {
                let updated_at = unix_millis()?;
                pending.transform_status = Some("error".to_owned());
                pending.transform_error_reason = Some(feature_error_reason(&error).to_owned());
                pending.prompt_transform_note = Some("raw-error".to_owned());
                self.persist_message_patch(
                    session_id,
                    pending,
                    pending_revision.saturating_add(1),
                    updated_at,
                    true,
                )
                .await?;
                Err(error.into())
            }
        }
    }

    async fn handle_steer(
        &self,
        command: &CommandRecord,
        session_id: &str,
        content: &str,
    ) -> EngineResult<()> {
        self.ensure_session_loaded(session_id).await?;
        // A long-running goal can rotate or finish its active turn before the
        // relay receives the next Mobile/Desktop snapshot. Re-read the thread
        // immediately before steering so expectedTurnId always comes from the
        // App Server authority instead of a stale local WORKING marker.
        self.hydrate_session_transcript(session_id).await?;
        let runtime = self.runtime_session(session_id).await?;
        let Some(turn_id) = runtime.active_turn_id else {
            return self
                .start_steer_as_new_turn(command, session_id, content)
                .await;
        };
        let result = self
            .request_with_overload_retry(
                "turn/steer",
                json!({
                    "threadId": runtime.thread_id,
                    "expectedTurnId": &turn_id,
                    "input": [{ "type": "text", "text": content }],
                }),
            )
            .await;
        match result {
            Ok(_) => Ok(()),
            Err(error) if is_recoverable_steer_race(&error) => {
                // Completion can still win the narrow window between
                // thread/read and turn/steer. Reconcile once more: steer the
                // replacement turn when one exists, otherwise preserve the
                // user's prompt by starting the next turn.
                self.hydrate_session_transcript(session_id).await?;
                let refreshed = self.runtime_session(session_id).await?;
                match refreshed.active_turn_id {
                    Some(refreshed_turn_id) if refreshed_turn_id != turn_id => {
                        self.request_with_overload_retry(
                            "turn/steer",
                            json!({
                                "threadId": refreshed.thread_id,
                                "expectedTurnId": refreshed_turn_id,
                                "input": [{ "type": "text", "text": content }],
                            }),
                        )
                        .await?;
                        Ok(())
                    }
                    None => {
                        self.start_steer_as_new_turn(command, session_id, content)
                            .await
                    }
                    Some(_) => Err(error),
                }
            }
            Err(error) => Err(error),
        }
    }

    async fn start_steer_as_new_turn(
        &self,
        command: &CommandRecord,
        session_id: &str,
        content: &str,
    ) -> EngineResult<()> {
        let client_message_id = format!("steer-fallback-{}", command.command_id);
        self.handle_send_message(
            command,
            session_id,
            content,
            &client_message_id,
            &[],
            SendMessageOptions {
                service_tier: None,
                allow_prompt_improver: true,
            },
        )
        .await
    }

    async fn handle_interrupt(&self, session_id: &str) -> EngineResult<()> {
        let runtime = self.runtime_session(session_id).await?;
        let Some(turn_id) = runtime.active_turn_id else {
            return Ok(());
        };
        self.request_with_overload_retry(
            "turn/interrupt",
            json!({ "threadId": runtime.thread_id, "turnId": turn_id }),
        )
        .await?;
        self.set_active_turn(session_id, None).await;
        self.update_session_status(session_id, ActivityStatus::Ready, "WAITING", None)
            .await?;
        Ok(())
    }

    async fn handle_archive(&self, session_id: &str) -> EngineResult<()> {
        let summary = self.required_summary(session_id).await?;
        let thread_id = summary
            .provider_session_id
            .as_deref()
            .ok_or_else(|| EngineError::SessionNotFound(session_id.to_owned()))?
            .to_owned();
        if let Err(error) = self
            .request_with_overload_retry("thread/archive", json!({ "threadId": thread_id }))
            .await
        {
            if !is_missing_provider_rollout(&error, "thread/archive") {
                return Err(error);
            }
            warn!(
                session_id,
                "provider rollout was already absent; completing archive in the durable Fermín store"
            );
        }
        self.mark_session_archived(session_id, &thread_id).await?;
        Ok(())
    }

    async fn handle_delete(&self, session_id: &str) -> EngineResult<()> {
        let summary = self.required_summary(session_id).await?;
        let thread_id = summary
            .provider_session_id
            .as_deref()
            .ok_or_else(|| EngineError::SessionNotFound(session_id.to_owned()))?
            .to_owned();
        if let Some(creator) = self.core.session_creator.as_ref()
            && let Err(error) = request_transport_with_overload_retry(
                creator.as_ref(),
                "thread/unsubscribe",
                json!({ "threadId": thread_id.clone() }),
            )
            .await
        {
            warn!(
                session_id,
                error = %redacted_error(&error),
                "session creator unsubscribe failed before permanent deletion"
            );
        }
        if let Err(error) = self
            .request_with_overload_retry(
                "thread/unsubscribe",
                json!({ "threadId": thread_id.clone() }),
            )
            .await
        {
            warn!(
                session_id,
                error = %redacted_error(&error),
                "provider thread unsubscribe failed before permanent deletion; attempting delete"
            );
        }
        if let Err(error) = self
            .request_with_overload_retry("thread/delete", json!({ "threadId": thread_id }))
            .await
        {
            if !is_missing_provider_rollout(&error, "thread/delete") {
                return Err(error);
            }
            warn!(
                session_id,
                "provider rollout was already absent; completing permanent deletion in the durable Fermín store"
            );
        }
        self.remove_provisional_session(session_id, &thread_id)
            .await?;
        Ok(())
    }

    async fn handle_rename(&self, session_id: &str, display_name: &str) -> EngineResult<()> {
        let name = display_name.trim();
        if name.is_empty() {
            return Err(EngineError::UnsupportedCommand(
                "display name must not be empty".to_owned(),
            ));
        }
        self.ensure_session_loaded(session_id).await?;
        let runtime = self.runtime_session(session_id).await?;
        self.request_with_overload_retry(
            "thread/name/set",
            json!({ "threadId": runtime.thread_id, "name": name }),
        )
        .await?;
        let mut summary = self.required_summary(session_id).await?;
        summary.display_name = name.to_owned();
        summary.window_name = Some(name.to_owned());
        summary.session_name = Some(name.to_owned());
        summary.updated_at = unix_millis()?;
        self.upsert_runtime_session(summary, None).await?;
        Ok(())
    }

    async fn handle_minimize(
        &self,
        command: &CommandRecord,
        session_id: &str,
        minimized: bool,
    ) -> EngineResult<()> {
        if command
            .trace_id
            .as_deref()
            .is_some_and(|trace| trace.starts_with(RESUME_HISTORY_TRACE_PREFIX))
        {
            let archived = self.required_summary(session_id).await?;
            let thread_id = archived
                .provider_session_id
                .clone()
                .ok_or_else(|| EngineError::SessionNotFound(session_id.to_owned()))?;
            match self
                .request_with_overload_retry("thread/unarchive", json!({ "threadId": thread_id }))
                .await
            {
                Ok(unarchive_response) => {
                    let unarchived_thread = unarchive_response.get("thread").ok_or_else(|| {
                        EngineError::InvalidResponse("thread/unarchive omitted thread".to_owned())
                    })?;
                    if unarchived_thread.get("id").and_then(Value::as_str)
                        != Some(thread_id.as_str())
                    {
                        return Err(EngineError::InvalidResponse(
                            "thread/unarchive returned the wrong restored thread".to_owned(),
                        ));
                    }
                }
                Err(error) if is_missing_provider_rollout(&error, "thread/unarchive") => {
                    // Unarchive moves the rollout before replying. If the App Server
                    // transport drops between those two steps, Fermín still records
                    // ARCHIVED while a retry correctly finds the rollout active.
                    // Continue with thread/resume so this recovery is idempotent.
                    warn!(
                        session_id,
                        "provider rollout was already unarchived; resuming it and reconciling durable history state"
                    );
                }
                Err(error) => return Err(error),
            }
            // Unarchiving only changes durable history state. Codex reports the
            // returned thread as `notLoaded`; turn/start then fails with -32600
            // unless this App Server explicitly resumes the rollout first.
            let resume_response = self
                .request_with_overload_retry("thread/resume", json!({ "threadId": thread_id }))
                .await?;
            let thread = resume_response.get("thread").ok_or_else(|| {
                EngineError::InvalidResponse("thread/resume omitted restored thread".to_owned())
            })?;
            let mut resumed = summary_from_thread(thread, session_id, unix_millis()?)?;
            merge_preserved_session_fields(&mut resumed, archived);
            resumed.can_send = true;
            resumed.activity_status = ActivityStatus::Ready;
            resumed.runtime_status = Some("WAITING".to_owned());
            resumed.runtime_status_detail = None;
            self.upsert_runtime_session(resumed, None).await?;
            self.set_appserver_loaded(session_id, true).await;
            self.set_transcript_hydrated(session_id, true).await;
        }
        let mut summary = self.required_summary(session_id).await?;
        summary.is_minimized = minimized;
        summary.updated_at = unix_millis()?;
        self.upsert_runtime_session(summary, None).await?;
        Ok(())
    }

    async fn handle_pinned(&self, session_id: &str, pinned: bool) -> EngineResult<()> {
        let mut summary = self.required_summary(session_id).await?;
        summary.is_pinned = pinned;
        summary.updated_at = unix_millis()?;
        self.upsert_runtime_session(summary, None).await?;
        Ok(())
    }

    async fn handle_features(
        &self,
        session_id: &str,
        features: SessionFeatures,
    ) -> EngineResult<()> {
        let mut summary = self.required_summary(session_id).await?;
        summary.features = features;
        summary.updated_at = unix_millis()?;
        self.upsert_runtime_session(summary, None).await?;
        Ok(())
    }

    async fn handle_model_settings(
        &self,
        session_id: &str,
        settings: &RuntimeModelSettings,
    ) -> EngineResult<()> {
        self.validate_model_settings(settings).await?;
        if !self
            .core
            .appserver_capabilities
            .supports_thread_settings_update()
        {
            return Err(EngineError::UnsupportedCommand(
                "installed App Server does not support thread/settings/update".to_owned(),
            ));
        }
        self.ensure_session_loaded(session_id).await?;
        let runtime = self.runtime_session(session_id).await?;
        let appserver_epoch = self.core.appserver.epoch();
        let mut notifications = self.core.appserver.subscribe();
        self.request_with_overload_retry(
            THREAD_SETTINGS_UPDATE_METHOD,
            json!({
                "threadId": runtime.thread_id,
                "model": settings.model,
                "effort": settings.effort,
            }),
        )
        .await?;
        let confirmed = self
            .await_thread_settings_confirmation(
                &mut notifications,
                appserver_epoch,
                &runtime.thread_id,
                settings,
            )
            .await?;
        self.apply_confirmed_model_settings(session_id, &confirmed)
            .await
    }

    async fn await_thread_settings_confirmation(
        &self,
        notifications: &mut broadcast::Receiver<AppServerEvent>,
        appserver_epoch: u64,
        thread_id: &str,
        expected: &RuntimeModelSettings,
    ) -> EngineResult<RuntimeModelSettings> {
        time::timeout(THREAD_SETTINGS_CONFIRMATION_TIMEOUT, async {
            loop {
                match notifications.recv().await {
                    Ok(AppServerEvent::Notification {
                        epoch,
                        method,
                        params,
                    }) if epoch == appserver_epoch && method == "thread/settings/updated" => {
                        let (confirmed_thread_id, confirmed) =
                            parse_thread_settings_notification(&params)?;
                        if confirmed_thread_id != thread_id {
                            continue;
                        }
                        validate_effective_model_settings(
                            &confirmed,
                            &expected.model,
                            &expected.effort,
                        )?;
                        return Ok(confirmed);
                    }
                    Ok(AppServerEvent::Lifecycle { epoch, state, .. })
                        if epoch == appserver_epoch
                            && matches!(
                                state,
                                AppServerLifecycle::Failed | AppServerLifecycle::Stopped
                            ) =>
                    {
                        return Err(EngineError::AppServer(AppServerError::Closed { epoch }));
                    }
                    Ok(_) => {}
                    Err(broadcast::error::RecvError::Lagged(skipped)) => {
                        return Err(EngineError::InvalidResponse(format!(
                            "missed {skipped} App Server events while confirming thread settings"
                        )));
                    }
                    Err(broadcast::error::RecvError::Closed) => {
                        return Err(EngineError::AppServer(AppServerError::Closed {
                            epoch: appserver_epoch,
                        }));
                    }
                }
            }
        })
        .await
        .map_err(|_| {
            EngineError::InvalidResponse(format!(
                "App Server did not confirm thread settings within {:?}",
                THREAD_SETTINGS_CONFIRMATION_TIMEOUT
            ))
        })?
    }

    async fn apply_confirmed_model_settings(
        &self,
        session_id: &str,
        settings: &RuntimeModelSettings,
    ) -> EngineResult<()> {
        self.validate_model_settings(settings).await?;
        let mut summary = self.required_summary(session_id).await?;
        if summary.model.as_deref() == Some(settings.model.as_str())
            && summary.reasoning_effort.as_deref() == Some(settings.effort.as_str())
        {
            return Ok(());
        }
        summary.model = Some(settings.model.clone());
        summary.reasoning_effort = Some(settings.effort.clone());
        summary.updated_at = unix_millis()?;
        self.upsert_runtime_session(summary, None).await?;
        Ok(())
    }

    async fn handle_run_mode(
        &self,
        session_id: &str,
        run_mode: RunMode,
        objective: Option<&str>,
    ) -> EngineResult<()> {
        self.ensure_session_loaded(session_id).await?;
        let runtime = self.runtime_session(session_id).await?;
        let goal = match run_mode {
            RunMode::Default => {
                if self.core.appserver_capabilities.supports_native_goals() {
                    let response = self
                        .request_with_overload_retry(
                            crate::features::NATIVE_GOAL_CLEAR_METHOD,
                            json!({ "threadId": runtime.thread_id }),
                        )
                        .await?;
                    if response.get("cleared").and_then(Value::as_bool).is_none() {
                        return Err(EngineError::InvalidResponse(
                            "thread/goal/clear omitted cleared".to_owned(),
                        ));
                    }
                    if self.read_native_goal(&runtime.thread_id).await?.is_some() {
                        return Err(EngineError::InvalidResponse(
                            "thread/goal/clear left a native goal behind".to_owned(),
                        ));
                    }
                }
                self.remove_goal_objective(session_id).await?;
                None
            }
            RunMode::Goal => {
                let objective = self.resolve_goal_objective(session_id, objective).await?;
                let objective_file = self.goal_objective_path(session_id);
                let plan = select_goal_mode(
                    &self.core.appserver_capabilities,
                    GoalModeRequest {
                        thread_id: runtime.thread_id.clone(),
                        objective: objective.clone(),
                        status: Some(GoalStatus::Active),
                        token_budget: None,
                        fallback_objective_file: objective_file.clone(),
                    },
                )?;
                match plan {
                    GoalModePlan::Native { method, params } => {
                        let response = self.request_with_overload_retry(method, params).await?;
                        let returned = response.get("goal").ok_or_else(|| {
                            EngineError::InvalidResponse("thread/goal/set omitted goal".to_owned())
                        })?;
                        let returned = parse_native_goal(returned, &runtime.thread_id)?;
                        if returned.objective != objective || returned.status != "active" {
                            return Err(EngineError::InvalidResponse(
                                "thread/goal/set returned mismatched goal state".to_owned(),
                            ));
                        }
                        let canonical = self
                            .read_native_goal(&runtime.thread_id)
                            .await?
                            .ok_or_else(|| {
                                EngineError::InvalidResponse(
                                    "thread/goal/get omitted the goal after set".to_owned(),
                                )
                            })?;
                        if canonical.objective != objective || canonical.status != "active" {
                            return Err(EngineError::InvalidResponse(
                                "thread/goal/get returned mismatched goal state".to_owned(),
                            ));
                        }
                        write_private_file(&objective_file, objective.as_bytes()).await?;
                        Some(canonical)
                    }
                    GoalModePlan::PromptFileFallback {
                        objective_file,
                        objective_file_contents,
                        ..
                    } => {
                        write_private_file(&objective_file, objective_file_contents.as_bytes())
                            .await?;
                        let now = unix_millis()?;
                        Some(GoalState {
                            objective,
                            status: "active".to_owned(),
                            token_budget: None,
                            tokens_used: 0,
                            time_used_seconds: 0,
                            created_at: now,
                            updated_at: now,
                        })
                    }
                }
            }
        };
        let mut summary = self.required_summary(session_id).await?;
        summary.run_mode = run_mode;
        summary.goal_started_at = goal.as_ref().map(|goal| goal.created_at);
        summary.goal = goal;
        summary.updated_at = unix_millis()?;
        self.upsert_runtime_session(summary, Some(EventKind::GoalUpdated))
            .await?;
        Ok(())
    }

    async fn read_native_goal(&self, thread_id: &str) -> EngineResult<Option<GoalState>> {
        let response = self
            .request_with_overload_retry(
                crate::features::NATIVE_GOAL_GET_METHOD,
                json!({ "threadId": thread_id }),
            )
            .await?;
        match response.get("goal") {
            Some(Value::Null) => Ok(None),
            Some(goal) => parse_native_goal(goal, thread_id).map(Some),
            None => Err(EngineError::InvalidResponse(
                "thread/goal/get omitted goal".to_owned(),
            )),
        }
    }

    async fn reconcile_native_goal(&self, session_id: &str, thread_id: &str) -> EngineResult<()> {
        if !self.core.appserver_capabilities.supports_native_goals() {
            return Ok(());
        }
        let goal = self.read_native_goal(thread_id).await?;
        if let Some(goal) = &goal {
            write_private_file(
                &self.goal_objective_path(session_id),
                goal.objective.as_bytes(),
            )
            .await?;
        } else {
            self.remove_goal_objective(session_id).await?;
        }
        let mut summary = self.required_summary(session_id).await?;
        summary.run_mode = if goal.is_some() {
            RunMode::Goal
        } else {
            RunMode::Default
        };
        summary.goal_started_at = goal.as_ref().map(|goal| goal.created_at);
        summary.goal = goal;
        summary.updated_at = unix_millis()?;
        self.upsert_runtime_session(summary, Some(EventKind::GoalUpdated))
            .await?;
        Ok(())
    }

    async fn remove_goal_objective(&self, session_id: &str) -> EngineResult<()> {
        match tokio::fs::remove_file(self.goal_objective_path(session_id)).await {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(error.into()),
        }
    }

    async fn resolve_goal_objective(
        &self,
        session_id: &str,
        explicit: Option<&str>,
    ) -> EngineResult<String> {
        if let Some(explicit) = explicit.map(str::trim).filter(|value| !value.is_empty()) {
            return Ok(explicit.to_owned());
        }
        let summary = self.required_summary(session_id).await?;
        for candidate in [
            summary.raw_prompt.as_deref(),
            summary.original_prompt.as_deref(),
        ] {
            if let Some(candidate) = candidate.map(str::trim).filter(|value| !value.is_empty()) {
                return Ok(candidate.to_owned());
            }
        }
        if let Some(message) = self
            .core
            .store
            .list_messages(session_id)
            .await?
            .into_iter()
            .rev()
            .find(|stored| stored.message.role == crate::protocol::MessageRole::User)
        {
            let candidate = message
                .message
                .original_prompt
                .as_deref()
                .unwrap_or(&message.message.content)
                .trim();
            if !candidate.is_empty() {
                return Ok(candidate.to_owned());
            }
        }
        if let Some(preview) = summary
            .last_message_preview
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
        {
            return Ok(preview.to_owned());
        }
        Ok(format!(
            "Complete the current session work for {} and verify the result.",
            summary.display_name.trim()
        ))
    }

    async fn handle_create_subagent(
        &self,
        command: &CommandRecord,
        parent_session_id: &str,
        prompt: &str,
        display_name: Option<&str>,
        parent_notification_prompt: Option<&str>,
    ) -> EngineResult<()> {
        if prompt.trim().is_empty() {
            return Err(EngineError::UnsupportedCommand(
                "subagent prompt must not be empty".to_owned(),
            ));
        }
        let parent = self.required_summary(parent_session_id).await?;
        let parent_runtime = self.runtime_session(parent_session_id).await?;
        let requested_child_session_id = subagent_child_session_id(command)
            .unwrap_or_else(|| format!("subagent-{}", uuid::Uuid::now_v7()));
        let child_instructions = build_subagent_child_notification_instructions(
            parent_session_id,
            &requested_child_session_id,
        )
        .map_err(|error| EngineError::UnsupportedCommand(error.to_string()))?;
        let model = parent
            .model
            .as_deref()
            .unwrap_or(&self.core.config.default_model);
        let effort = parent
            .reasoning_effort
            .as_deref()
            .unwrap_or(&self.core.config.default_effort);
        self.validate_model_settings(&RuntimeModelSettings {
            model: model.to_owned(),
            model_provider: Some("openai".to_owned()),
            effort: effort.to_owned(),
        })
        .await?;
        let response = self
            .request_with_overload_retry(
                "thread/start",
                json!({
                    "cwd": parent.project_path,
                    "model": model,
                    "modelProvider": "openai",
                    "approvalPolicy": "never",
                    "ephemeral": false,
                    "developerInstructions": child_instructions,
                    "config": { "model_reasoning_effort": effort },
                }),
            )
            .await?;
        validate_effective_model_response(&response, model, effort)?;
        let thread = response.get("thread").ok_or_else(|| {
            EngineError::InvalidResponse("thread/start omitted thread".to_owned())
        })?;
        let child_session_id = requested_child_session_id;
        let mut child = summary_from_thread(thread, &child_session_id, unix_millis()?)?;
        let child_thread_id = child.provider_session_id.clone().ok_or_else(|| {
            EngineError::InvalidResponse("thread/start omitted thread.id".to_owned())
        })?;
        child.managed_by_fermin = true;
        child.parent_session_id = Some(parent_session_id.to_owned());
        child.model = parent.model.clone();
        child.reasoning_effort = parent.reasoning_effort.clone();
        child.features = parent.features.clone();
        child.display_name = display_name
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .unwrap_or("Subagent")
            .to_owned();
        child.window_name = Some(child.display_name.clone());
        child.pending_subagent = Some(PendingSubagentDraft {
            display_message: prompt.to_owned(),
            parent_notification_prompt: Some(
                parent_notification_prompt
                    .map(str::to_owned)
                    .unwrap_or_else(|| {
                        format!(
                            "Notify parent session {parent_session_id} when this delegated task changes state."
                        )
                    }),
            ),
            child_message_sent_at: None,
        });
        self.upsert_runtime_session(child.clone(), Some(EventKind::SubagentUpdated))
            .await?;
        self.set_appserver_loaded(&child_session_id, true).await;
        self.set_transcript_hydrated(&child_session_id, true).await;

        let parent_context = build_subagent_parent_context(&SubagentRelationship {
            parent_session_id: parent_session_id.to_owned(),
            child_session_id: child_session_id.clone(),
            child_name: Some(child.display_name.clone()),
            delegated_task: prompt.to_owned(),
        })
        .map_err(|error| EngineError::UnsupportedCommand(error.to_string()))?;
        self.append_event(NewEvent {
            event_id: Some(format!("subagent:{child_session_id}:staged")),
            session_id: Some(parent_session_id.to_owned()),
            command_id: None,
            process_epoch: Some(self.core.process_epoch),
            kind: EventKind::SubagentUpdated,
            payload: json!({
                "parentSessionId": parent_session_id,
                "parentThreadId": parent_runtime.thread_id,
                "childSession": child,
                "parentContext": parent_context.clone(),
                "state": "staged",
            }),
            created_at: unix_millis()?,
        })
        .await?;

        let child_message_id = format!("subagent-task:{}", command.command_id);
        if let Err(error) = self
            .handle_send_message(
                command,
                &child_session_id,
                prompt,
                &child_message_id,
                &[],
                SendMessageOptions {
                    service_tier: None,
                    allow_prompt_improver: false,
                },
            )
            .await
        {
            if let Err(cleanup_error) = self
                .request_with_overload_retry(
                    "thread/delete",
                    json!({ "threadId": child_thread_id }),
                )
                .await
            {
                warn!(
                    session_id = child_session_id,
                    error = %redacted_error(&cleanup_error),
                    "failed to delete subagent thread after first-turn failure"
                );
            }
            if let Err(cleanup_error) = self
                .remove_provisional_session(&child_session_id, &child_thread_id)
                .await
            {
                warn!(
                    session_id = child_session_id,
                    error = %redacted_error(&cleanup_error),
                    "failed to remove staged subagent after first-turn failure"
                );
            }
            return Err(error);
        }

        let started_at = unix_millis()?;
        let mut started_child = self.required_summary(&child_session_id).await?;
        if let Some(pending) = started_child.pending_subagent.as_mut() {
            pending.child_message_sent_at = Some(started_at);
        }
        started_child.updated_at = started_at;
        self.upsert_runtime_session(started_child.clone(), Some(EventKind::SubagentUpdated))
            .await?;
        self.append_event(NewEvent {
            event_id: Some(format!("subagent:{child_session_id}:started")),
            session_id: Some(parent_session_id.to_owned()),
            command_id: Some(command.command_id.clone()),
            process_epoch: Some(self.core.process_epoch),
            kind: EventKind::SubagentUpdated,
            payload: json!({
                "parentSessionId": parent_session_id,
                "parentThreadId": parent_runtime.thread_id,
                "childSession": started_child,
                "parentContext": parent_context,
                "state": "started",
            }),
            created_at: started_at,
        })
        .await?;
        Ok(())
    }

    async fn request_with_overload_retry(
        &self,
        method: &str,
        params: Value,
    ) -> EngineResult<Value> {
        request_transport_with_overload_retry(self.core.appserver.as_ref(), method, params).await
    }

    async fn required_summary(&self, session_id: &str) -> EngineResult<SessionSummary> {
        self.core
            .store
            .get_session(session_id)
            .await?
            .filter(|stored| stored.session.managed_by_fermin)
            .map(|stored| stored.session)
            .ok_or_else(|| EngineError::SessionNotFound(session_id.to_owned()))
    }

    async fn runtime_session(&self, session_id: &str) -> EngineResult<RuntimeSession> {
        self.core
            .runtime
            .read()
            .await
            .sessions
            .get(session_id)
            .cloned()
            .ok_or_else(|| EngineError::SessionNotFound(session_id.to_owned()))
    }

    async fn ensure_session_loaded(&self, session_id: &str) -> EngineResult<()> {
        if self.runtime_session(session_id).await?.appserver_loaded {
            return Ok(());
        }
        let summary = self.required_summary(session_id).await?;
        let thread_id = summary
            .provider_session_id
            .as_deref()
            .ok_or_else(|| EngineError::SessionNotFound(session_id.to_owned()))?;
        let model = summary
            .model
            .as_deref()
            .unwrap_or(&self.core.config.default_model);
        let effort = summary
            .reasoning_effort
            .as_deref()
            .unwrap_or(&self.core.config.default_effort);
        self.validate_model_settings(&RuntimeModelSettings {
            model: model.to_owned(),
            model_provider: Some("openai".to_owned()),
            effort: effort.to_owned(),
        })
        .await?;
        let response = self
            .request_with_overload_retry(
                "thread/resume",
                json!({
                    "threadId": thread_id,
                    "model": model,
                    "modelProvider": "openai",
                    "config": { "model_reasoning_effort": effort },
                    "approvalPolicy": "never",
                }),
            )
            .await?;
        validate_effective_model_response(&response, model, effort)?;
        let thread = response.get("thread").ok_or_else(|| {
            EngineError::InvalidResponse("thread/resume omitted thread".to_owned())
        })?;
        self.reconcile_thread(thread, Some(session_id)).await?;
        let mut resumed = self.required_summary(session_id).await?;
        resumed.model = Some(
            response
                .get("model")
                .and_then(Value::as_str)
                .unwrap_or(model)
                .to_owned(),
        );
        resumed.reasoning_effort = Some(
            response
                .get("reasoningEffort")
                .and_then(Value::as_str)
                .unwrap_or(effort)
                .to_owned(),
        );
        resumed.runtime_status_detail = None;
        self.upsert_runtime_session(resumed, None).await?;
        self.set_appserver_loaded(session_id, true).await;
        Ok(())
    }

    async fn hydrate_session_transcript(&self, session_id: &str) -> EngineResult<()> {
        let runtime = self.runtime_session(session_id).await?;
        let response = self
            .request_with_overload_retry(
                "thread/read",
                json!({ "threadId": runtime.thread_id, "includeTurns": true }),
            )
            .await?;
        let thread = response
            .get("thread")
            .ok_or_else(|| EngineError::InvalidResponse("thread/read omitted thread".to_owned()))?;
        self.reconcile_thread(thread, Some(session_id)).await
    }

    async fn session_id_for_thread(&self, thread_id: &str) -> Option<String> {
        self.core
            .runtime
            .read()
            .await
            .threads
            .get(thread_id)
            .cloned()
    }

    async fn set_active_turn(&self, session_id: &str, turn_id: Option<String>) {
        if let Some(runtime) = self.core.runtime.write().await.sessions.get_mut(session_id) {
            runtime.active_turn_id = turn_id;
        }
    }

    async fn set_appserver_loaded(&self, session_id: &str, loaded: bool) {
        if let Some(runtime) = self.core.runtime.write().await.sessions.get_mut(session_id) {
            runtime.appserver_loaded = loaded;
        }
    }

    async fn set_transcript_hydrated(&self, session_id: &str, hydrated: bool) {
        if let Some(runtime) = self.core.runtime.write().await.sessions.get_mut(session_id) {
            runtime.transcript_hydrated = hydrated;
        }
    }

    async fn claim_transcript_hydration(&self, session_id: &str) -> bool {
        let mut runtime = self.core.runtime.write().await;
        let Some(session) = runtime.sessions.get_mut(session_id) else {
            return false;
        };
        if session.transcript_hydrated {
            return false;
        }
        session.transcript_hydrated = true;
        true
    }

    async fn spawn_cached_transcript_reconciliation(&self, session_id: String) {
        let state = self.clone();
        let cancellation = self.core.cancellation.clone();
        let handle = tokio::spawn(async move {
            tokio::select! {
                () = cancellation.cancelled() => {}
                result = state.hydrate_session_transcript(&session_id) => {
                    if let Err(error) = result {
                        state.set_transcript_hydrated(&session_id, false).await;
                        warn!(
                            session_id,
                            error = %error,
                            "deferred transcript reconciliation failed; durable transcript remains available"
                        );
                    }
                }
            }
        });
        self.core.tasks.lock().await.push(handle);
    }

    async fn upsert_runtime_session(
        &self,
        mut summary: SessionSummary,
        event_kind: Option<EventKind>,
    ) -> EngineResult<StoredSession> {
        if !summary.managed_by_fermin {
            return Err(EngineError::SessionNotFound(summary.session_id));
        }
        summary.engine = crate::protocol::ENGINE_NAME.to_owned();
        summary.can_control_features = true;
        summary.messages.clear();
        summary.last_message_preview = summary
            .last_message_preview
            .as_deref()
            .map(crate::protocol::bounded_session_preview);
        let thread_id = summary
            .provider_session_id
            .clone()
            .unwrap_or_else(|| summary.session_id.clone());
        let mutation = self
            .core
            .store
            .upsert_session_with_event(
                summary.clone(),
                NewEvent {
                    event_id: None,
                    session_id: Some(summary.session_id.clone()),
                    command_id: None,
                    process_epoch: Some(self.core.process_epoch),
                    kind: event_kind.unwrap_or(EventKind::SessionUpserted),
                    payload: serde_json::to_value(&summary)?,
                    created_at: summary.updated_at,
                },
                Some(self.fence().await?),
            )
            .await?;
        if let Some(event) = mutation.event {
            self.publish_event(event);
        }
        {
            let mut index = self.core.runtime.write().await;
            index
                .threads
                .insert(thread_id.clone(), summary.session_id.clone());
            index
                .sessions
                .entry(summary.session_id.clone())
                .and_modify(|runtime| runtime.thread_id.clone_from(&thread_id))
                .or_insert_with(|| RuntimeSession {
                    thread_id,
                    ..RuntimeSession::default()
                });
        }
        Ok(mutation.stored)
    }

    async fn remove_runtime_session(&self, session_id: &str, thread_id: &str) {
        let mut index = self.core.runtime.write().await;
        index.sessions.remove(session_id);
        index.threads.remove(thread_id);
        self.core.lanes.lock().await.remove(session_id);
    }

    async fn mark_session_archived(&self, session_id: &str, thread_id: &str) -> EngineResult<()> {
        let mut summary = self.required_summary(session_id).await?;
        if summary.runtime_status.as_deref() == Some("ARCHIVED") {
            self.remove_runtime_session(session_id, thread_id).await;
            return Ok(());
        }
        let now = unix_millis()?;
        summary.activity_status = ActivityStatus::Done;
        summary.runtime_status = Some("ARCHIVED".to_owned());
        summary.runtime_status_detail = None;
        summary.can_send = false;
        summary.updated_at = now;
        summary.messages.clear();
        let event_payload = serde_json::to_value(&summary)?;
        let mutation = self
            .core
            .store
            .upsert_session_with_event(
                summary,
                NewEvent {
                    event_id: None,
                    session_id: Some(session_id.to_owned()),
                    command_id: None,
                    process_epoch: Some(self.core.process_epoch),
                    kind: EventKind::SessionUpserted,
                    payload: event_payload,
                    created_at: now,
                },
                Some(self.fence().await?),
            )
            .await?;
        if let Some(event) = mutation.event {
            self.publish_event(event);
        }
        self.remove_runtime_session(session_id, thread_id).await;
        Ok(())
    }

    async fn update_session_status(
        &self,
        session_id: &str,
        activity: ActivityStatus,
        runtime_status: &str,
        detail: Option<String>,
    ) -> EngineResult<()> {
        let mut summary = self.required_summary(session_id).await?;
        summary.activity_status = activity;
        summary.runtime_status = Some(runtime_status.to_owned());
        summary.runtime_status_detail = detail;
        summary.updated_at = unix_millis()?;
        self.upsert_runtime_session(summary, Some(EventKind::RuntimeStatus))
            .await?;
        Ok(())
    }

    async fn refresh_session_message_metadata(
        &self,
        session_id: &str,
        activity: ActivityStatus,
    ) -> EngineResult<()> {
        let messages = collapse_provider_snapshot_aliases(
            self.core
                .store
                .list_messages(session_id)
                .await?
                .into_iter()
                .map(|stored| stored.message)
                .collect(),
        );
        let mut summary = self.required_summary(session_id).await?;
        summary.message_count = messages.len() as u64;
        summary.last_message_preview = messages
            .last()
            .map(|message| crate::protocol::bounded_session_preview(&message.content));
        summary.activity_status = activity;
        summary.runtime_status = Some(
            if activity == ActivityStatus::Working {
                "WORKING"
            } else {
                "WAITING"
            }
            .to_owned(),
        );
        summary.updated_at = unix_millis()?;
        self.upsert_runtime_session(summary, None).await?;
        Ok(())
    }

    async fn validate_model_settings(&self, settings: &RuntimeModelSettings) -> EngineResult<()> {
        let provider = settings
            .model_provider
            .as_deref()
            .unwrap_or("openai")
            .to_ascii_lowercase();
        if provider != "openai" && provider != "codex" {
            return Err(EngineError::InvalidModel(
                "only OpenAI/Codex model providers are supported".to_owned(),
            ));
        }
        let catalog = self.core.models.read().await;
        let model = catalog
            .models
            .iter()
            .find(|candidate| candidate.model == settings.model)
            .ok_or_else(|| EngineError::InvalidModel(settings.model.clone()))?;
        if !model
            .supported_reasoning_efforts
            .iter()
            .any(|option| option.reasoning_effort == settings.effort)
        {
            return Err(EngineError::InvalidModel(format!(
                "{} does not support effort {}",
                settings.model, settings.effort
            )));
        }
        Ok(())
    }

    fn validated_project_path(&self, raw: &str) -> EngineResult<PathBuf> {
        let candidate = std::fs::canonicalize(raw)
            .map_err(|_| EngineError::PathOutsideWorkspace(raw.to_owned()))?;
        let allowed = self.core.config.workspace_roots.iter().any(|root| {
            std::fs::canonicalize(root)
                .map(|root| candidate.starts_with(root))
                .unwrap_or(false)
        });
        if !allowed {
            return Err(EngineError::PathOutsideWorkspace(
                candidate.display().to_string(),
            ));
        }
        Ok(candidate)
    }

    async fn append_event(&self, event: NewEvent) -> EngineResult<DurableEvent> {
        let durable = self
            .core
            .store
            .append_event(event, Some(self.fence().await?))
            .await?;
        self.publish_event(durable.clone());
        Ok(durable)
    }

    fn publish_event(&self, event: DurableEvent) {
        let mut publisher = lock_std(&self.core.publisher);
        if event.global_sequence <= publisher.last_published {
            return;
        }
        publisher.pending.insert(event.global_sequence, event);
        loop {
            let next = publisher.last_published.saturating_add(1);
            let Some(event) = publisher.pending.remove(&next) else {
                break;
            };
            publisher.last_published = next;
            self.core
                .last_global_sequence
                .store(next, Ordering::Release);
            let _ = self.core.live_events.send(event);
        }
    }

    async fn reduce_appserver_event(&self, event: AppServerEvent) -> EngineResult<()> {
        match event {
            AppServerEvent::Notification {
                epoch,
                method,
                params,
            } => self.reduce_notification(epoch, &method, params).await,
            AppServerEvent::ServerRequest {
                epoch,
                id,
                method,
                params,
            } => self.handle_server_request(epoch, id, &method, params).await,
            AppServerEvent::Unrecognized { epoch, message } => {
                self.append_event(NewEvent {
                    event_id: None,
                    session_id: None,
                    command_id: None,
                    process_epoch: Some(self.core.process_epoch),
                    kind: EventKind::Error,
                    payload: json!({
                        "source": "appServer",
                        "appServerEpoch": epoch,
                        "code": "unrecognizedMessage",
                        "messageType": message.get("method"),
                    }),
                    created_at: unix_millis()?,
                })
                .await?;
                Ok(())
            }
            AppServerEvent::Lifecycle {
                epoch,
                state,
                detail,
            } => {
                if matches!(
                    state,
                    AppServerLifecycle::Failed | AppServerLifecycle::Stopped
                ) {
                    self.core.ready.store(false, Ordering::Release);
                    self.core.cancellation.cancel();
                }
                self.append_event(NewEvent {
                    event_id: None,
                    session_id: None,
                    command_id: None,
                    process_epoch: Some(self.core.process_epoch),
                    kind: if state == AppServerLifecycle::Failed {
                        EventKind::Error
                    } else {
                        EventKind::RuntimeStatus
                    },
                    payload: json!({
                        "source": "appServer",
                        "appServerEpoch": epoch,
                        "state": format!("{state:?}"),
                        "detail": detail,
                    }),
                    created_at: unix_millis()?,
                })
                .await?;
                Ok(())
            }
        }
    }

    async fn reduce_notification(
        &self,
        appserver_epoch: u64,
        method: &str,
        params: Value,
    ) -> EngineResult<()> {
        // These are renderer snapshots or telemetry. Fermín does not expose
        // them, and durable session/message state already carries everything
        // its clients need. Persisting cumulative turn diffs duplicated
        // hundreds of megabytes into both engine and relay databases.
        if should_drop_derived_appserver_notification(method) {
            return Ok(());
        }
        match method {
            "thread/settings/updated" => {
                let (thread_id, settings) = parse_thread_settings_notification(&params)?;
                if let Some(session_id) = self.session_id_for_thread(&thread_id).await {
                    self.apply_confirmed_model_settings(&session_id, &settings)
                        .await?;
                }
            }
            "thread/started" => {
                if let Some(thread) = params.get("thread") {
                    let thread_id = required_string(thread, "id")?;
                    let known = self.session_id_for_thread(&thread_id).await.is_some();
                    let known_parent = match thread.get("parentThreadId").and_then(Value::as_str) {
                        Some(parent_thread_id) => {
                            self.session_id_for_thread(parent_thread_id).await.is_some()
                        }
                        None => false,
                    };
                    if known || known_parent {
                        self.reconcile_thread(thread, None).await?;
                        if let Some(session_id) = self.session_id_for_thread(&thread_id).await {
                            self.set_appserver_loaded(&session_id, true).await;
                        }
                    }
                }
            }
            "turn/started" => {
                if let Some((session_id, thread_id)) = self.notification_session(&params).await {
                    let turn_id = params
                        .pointer("/turn/id")
                        .and_then(Value::as_str)
                        .map(str::to_owned);
                    self.set_active_turn(&session_id, turn_id).await;
                    self.update_session_status(
                        &session_id,
                        ActivityStatus::Working,
                        "WORKING",
                        None,
                    )
                    .await?;
                    self.persist_normalized_notification(
                        appserver_epoch,
                        method,
                        EventKind::TurnStarted,
                        Some(session_id.clone()),
                        Some(thread_id),
                        params,
                    )
                    .await?;
                }
            }
            "turn/completed" => {
                if let Some((session_id, thread_id)) = self.notification_session(&params).await {
                    let turn_id = params
                        .pointer("/turn/id")
                        .and_then(Value::as_str)
                        .unwrap_or("unknown-turn")
                        .to_owned();
                    self.set_active_turn(&session_id, None).await;
                    let status = params
                        .pointer("/turn/status")
                        .and_then(Value::as_str)
                        .unwrap_or("completed");
                    let (activity, event_kind) = match status {
                        "failed" => (ActivityStatus::Error, EventKind::Error),
                        "interrupted" => (ActivityStatus::Ready, EventKind::TurnInterrupted),
                        _ => (ActivityStatus::Ready, EventKind::TurnCompleted),
                    };
                    let detail = if activity == ActivityStatus::Error {
                        let existing = self.required_summary(&session_id).await?;
                        runtime_failure_detail(&params).or(existing.runtime_status_detail)
                    } else {
                        None
                    };
                    self.update_session_status(&session_id, activity, "WAITING", detail)
                        .await?;
                    self.persist_normalized_notification(
                        appserver_epoch,
                        method,
                        event_kind,
                        Some(session_id.clone()),
                        Some(thread_id),
                        params,
                    )
                    .await?;
                    if let Err(error) = self
                        .enqueue_automatic_explainer(&session_id, &turn_id)
                        .await
                    {
                        warn!(
                            session_id,
                            turn_id,
                            error = %redacted_error(&error),
                            "failed to enqueue automatic Explainer"
                        );
                    }
                }
            }
            "item/agentMessage/delta" => {
                self.reduce_agent_delta(appserver_epoch, params).await?;
            }
            "item/started" => {
                self.reduce_item(appserver_epoch, &params, false).await?;
                self.persist_item_notification(
                    appserver_epoch,
                    method,
                    EventKind::ItemStarted,
                    params,
                )
                .await?;
            }
            "item/completed" => {
                self.reduce_item(appserver_epoch, &params, true).await?;
                let kind = if params.pointer("/item/type").and_then(Value::as_str)
                    == Some("collabAgentToolCall")
                    || params.pointer("/item/type").and_then(Value::as_str)
                        == Some("subAgentActivity")
                {
                    EventKind::SubagentUpdated
                } else {
                    EventKind::ItemCompleted
                };
                self.persist_item_notification(appserver_epoch, method, kind, params)
                    .await?;
            }
            "thread/status/changed" => {
                if let Some((session_id, thread_id)) = self.notification_session(&params).await {
                    let status = params.pointer("/status/type").and_then(Value::as_str);
                    let activity = match status {
                        Some("active") => ActivityStatus::Working,
                        Some("systemError") => ActivityStatus::Error,
                        _ => ActivityStatus::Ready,
                    };
                    let detail = if activity == ActivityStatus::Error {
                        let existing = self.required_summary(&session_id).await?;
                        runtime_failure_detail(&params).or(existing.runtime_status_detail)
                    } else {
                        None
                    };
                    self.update_session_status(
                        &session_id,
                        activity,
                        if activity == ActivityStatus::Working {
                            "WORKING"
                        } else {
                            "WAITING"
                        },
                        detail,
                    )
                    .await?;
                    self.persist_normalized_notification(
                        appserver_epoch,
                        method,
                        EventKind::RuntimeStatus,
                        Some(session_id),
                        Some(thread_id),
                        params,
                    )
                    .await?;
                }
            }
            "error" => {
                if let Some((session_id, thread_id)) = self.notification_session(&params).await {
                    let will_retry = params
                        .get("willRetry")
                        .and_then(Value::as_bool)
                        .unwrap_or(false);
                    let existing = self.required_summary(&session_id).await?;
                    let detail = runtime_failure_detail(&params).or(existing.runtime_status_detail);
                    self.update_session_status(
                        &session_id,
                        if will_retry {
                            ActivityStatus::Working
                        } else {
                            ActivityStatus::Error
                        },
                        if will_retry { "WORKING" } else { "WAITING" },
                        detail,
                    )
                    .await?;
                    self.persist_normalized_notification(
                        appserver_epoch,
                        method,
                        EventKind::Error,
                        Some(session_id),
                        Some(thread_id),
                        params,
                    )
                    .await?;
                }
            }
            "thread/name/updated" => {
                if let Some((session_id, thread_id)) = self.notification_session(&params).await {
                    if let Some(name) = params.get("threadName").and_then(Value::as_str) {
                        let mut summary = self.required_summary(&session_id).await?;
                        summary.display_name = name.to_owned();
                        summary.window_name = Some(name.to_owned());
                        summary.session_name = Some(name.to_owned());
                        summary.updated_at = unix_millis()?;
                        self.upsert_runtime_session(summary, None).await?;
                    }
                    self.persist_normalized_notification(
                        appserver_epoch,
                        method,
                        EventKind::SessionUpserted,
                        Some(session_id),
                        Some(thread_id),
                        params,
                    )
                    .await?;
                }
            }
            "thread/goal/updated" | "thread/goal/cleared" => {
                if let Some((session_id, thread_id)) = self.notification_session(&params).await {
                    self.reconcile_native_goal(&session_id, &thread_id).await?;
                }
            }
            "thread/archived" => {
                if let Some((session_id, thread_id)) = self.notification_session(&params).await {
                    self.mark_session_archived(&session_id, &thread_id).await?;
                }
            }
            "thread/deleted" => {
                if let Some((session_id, thread_id)) = self.notification_session(&params).await {
                    self.remove_provisional_session(&session_id, &thread_id)
                        .await?;
                }
            }
            "thread/closed" => {
                if let Some((session_id, thread_id)) = self.notification_session(&params).await {
                    self.set_appserver_loaded(&session_id, false).await;
                    self.set_active_turn(&session_id, None).await;
                    self.persist_normalized_notification(
                        appserver_epoch,
                        method,
                        EventKind::RuntimeStatus,
                        Some(session_id),
                        Some(thread_id),
                        params,
                    )
                    .await?;
                }
            }
            _ => {
                let Some((session_id, thread_id)) = self.notification_session(&params).await else {
                    return Ok(());
                };
                let kind = if method.starts_with("item/") {
                    EventKind::ItemUpdated
                } else if method.starts_with("turn/") {
                    EventKind::RuntimeStatus
                } else if method.contains("error") || method.contains("warning") {
                    EventKind::Error
                } else {
                    EventKind::RuntimeStatus
                };
                self.persist_normalized_notification(
                    appserver_epoch,
                    method,
                    kind,
                    Some(session_id),
                    Some(thread_id),
                    params,
                )
                .await?;
            }
        }
        Ok(())
    }

    async fn reduce_agent_delta(&self, appserver_epoch: u64, params: Value) -> EngineResult<()> {
        let thread_id = required_string(&params, "threadId")?;
        let session_id = self.session_id_for_thread(&thread_id).await;
        let Some(session_id) = session_id else {
            return Ok(());
        };
        let item_id = required_string(&params, "itemId")?;
        let delta = params
            .get("delta")
            .and_then(Value::as_str)
            .ok_or_else(|| EngineError::InvalidResponse("agent delta omitted delta".to_owned()))?;
        let now = unix_millis()?;
        let stored_messages = self.core.store.list_messages(&session_id).await?;
        let existing = stored_messages
            .iter()
            .find(|stored| stored.message.id == item_id)
            .cloned();
        if existing.as_ref().is_some_and(|stored| stored.final_) {
            return Ok(());
        }
        let (content, revision, timestamp) = {
            let mut index = self.core.runtime.write().await;
            let runtime = index
                .sessions
                .get_mut(&session_id)
                .ok_or_else(|| EngineError::SessionNotFound(session_id.clone()))?;
            let buffer = runtime
                .message_buffers
                .entry(item_id.clone())
                .or_insert_with(|| MessageAccumulator {
                    content: existing
                        .as_ref()
                        .map(|stored| stored.message.content.clone())
                        .unwrap_or_default(),
                    revision: existing.as_ref().map(|stored| stored.revision).unwrap_or(0),
                    timestamp: existing
                        .as_ref()
                        .map(|stored| stored.updated_at)
                        .unwrap_or(now),
                });
            buffer.apply_delta(delta, now)
        };
        self.persist_absolute_message_patch(
            appserver_epoch,
            &session_id,
            &item_id,
            content,
            revision,
            timestamp,
            false,
        )
        .await?;
        Ok(())
    }

    async fn reduce_item(
        &self,
        appserver_epoch: u64,
        params: &Value,
        final_: bool,
    ) -> EngineResult<()> {
        let Some(item) = params.get("item") else {
            return Ok(());
        };
        let thread_id = required_string(params, "threadId")?;
        let Some(session_id) = self.session_id_for_thread(&thread_id).await else {
            return Ok(());
        };
        let item_type = item.get("type").and_then(Value::as_str).unwrap_or_default();
        let item_id = item
            .get("id")
            .and_then(Value::as_str)
            .unwrap_or("unknown-item")
            .to_owned();
        let timestamp = params
            .get(if final_ {
                "completedAtMs"
            } else {
                "startedAtMs"
            })
            .and_then(Value::as_i64)
            .unwrap_or(unix_millis()?);
        match item_type {
            "agentMessage" => {
                let text = item.get("text").and_then(Value::as_str).unwrap_or_default();
                let stored_messages = self.core.store.list_messages(&session_id).await?;
                let existing = stored_messages
                    .iter()
                    .find(|stored| stored.message.id == item_id)
                    .cloned();
                if existing.as_ref().is_some_and(|stored| stored.final_) && !final_ {
                    return Ok(());
                }
                let (content, revision, timestamp) = {
                    let mut index = self.core.runtime.write().await;
                    let runtime = index
                        .sessions
                        .get_mut(&session_id)
                        .ok_or_else(|| EngineError::SessionNotFound(session_id.clone()))?;
                    let buffer = runtime
                        .message_buffers
                        .entry(item_id.clone())
                        .or_insert_with(|| MessageAccumulator {
                            content: existing
                                .as_ref()
                                .map(|stored| stored.message.content.clone())
                                .unwrap_or_default(),
                            revision: existing.as_ref().map(|stored| stored.revision).unwrap_or(0),
                            timestamp: existing
                                .as_ref()
                                .map(|stored| stored.updated_at)
                                .unwrap_or(timestamp),
                        });
                    buffer.apply_authoritative(text, timestamp)
                };
                self.persist_absolute_message_patch(
                    appserver_epoch,
                    &session_id,
                    &item_id,
                    content,
                    revision,
                    timestamp,
                    final_,
                )
                .await?;
            }
            "userMessage" => {
                self.persist_appserver_user_message(&session_id, item, timestamp)
                    .await?;
            }
            _ => {}
        }
        Ok(())
    }

    async fn persist_appserver_user_message(
        &self,
        session_id: &str,
        item: &Value,
        timestamp: i64,
    ) -> EngineResult<()> {
        let content = extract_user_message_text(item);
        let provider_item_id = item
            .get("id")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .map(str::to_owned);
        let message_id = item
            .get("clientId")
            .and_then(Value::as_str)
            .or(provider_item_id.as_deref())
            .unwrap_or("unknown-user-message")
            .to_owned();
        let stored_messages = self.core.store.list_messages(session_id).await?;
        let provider_match = provider_item_id.as_deref().and_then(|provider_item_id| {
            stored_messages
                .iter()
                .find(|stored| stored.message.provider_item_id.as_deref() == Some(provider_item_id))
        });
        let canonical_snapshot_match = is_provider_snapshot_item_id(&message_id).then(|| {
            stored_messages.iter().find(|stored| {
                stored.message.role == crate::protocol::MessageRole::User
                    && stored.message.content == content
                    && !is_provider_snapshot_item_id(&stored.message.id)
                    && stored
                        .message
                        .provider_item_id
                        .as_deref()
                        .is_none_or(|provider_id| !is_provider_snapshot_item_id(provider_id))
            })
        });
        let id_match = stored_messages
            .iter()
            .find(|stored| stored.message.id == message_id);
        let exact = provider_match
            .or(canonical_snapshot_match.flatten())
            .or(id_match);
        if exact.is_some_and(|stored| {
            stored.final_
                && stored.message.message_type.as_deref() == Some("userMessage")
                && stored.message.content == content
                && stored.message.provider_item_id == provider_item_id
        }) {
            return Ok(());
        }
        let pending_local = exact
            .filter(|stored| stored.message.message_type.as_deref() == Some("localUserMessage"))
            .or_else(|| {
                stored_messages.iter().rev().find(|stored| {
                    stored.message.role == crate::protocol::MessageRole::User
                        && stored.message.message_type.as_deref() == Some("localUserMessage")
                        && (stored.message.content == content
                            || stored.message.transformed_prompt.as_deref()
                                == Some(content.as_str())
                            || stored.message.improved_prompt.as_deref() == Some(content.as_str()))
                })
            });
        let (mut message, revision, updated_at) = if let Some(stored) = pending_local {
            let mut message = stored.message.clone();
            message.message_type = Some("userMessage".to_owned());
            (
                message,
                stored.revision.saturating_add(1),
                stored.updated_at,
            )
        } else if let Some(stored) = exact {
            let mut message = stored.message.clone();
            message.content = content.clone();
            message.original_prompt = Some(content.clone());
            message.message_type = Some("userMessage".to_owned());
            (
                message,
                stored.revision.saturating_add(1),
                stored.updated_at,
            )
        } else {
            let mut message = Message::user(message_id, content, timestamp);
            message.message_type = Some("userMessage".to_owned());
            (message, 1, timestamp)
        };
        message.provider_item_id = provider_item_id;
        message.timestamp = message.timestamp.min(timestamp);
        self.persist_message_patch(session_id, message, revision, updated_at, true)
            .await?;
        self.refresh_session_message_metadata(session_id, ActivityStatus::Working)
            .await?;
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    async fn persist_absolute_message_patch(
        &self,
        _appserver_epoch: u64,
        session_id: &str,
        item_id: &str,
        content: String,
        revision: u64,
        timestamp: i64,
        final_: bool,
    ) -> EngineResult<()> {
        let mut message = Message::assistant(item_id, content, timestamp);
        message.message_type = Some("agentMessage".to_owned());
        message.status = (!final_).then(|| "streaming".to_owned());
        let applied = self
            .persist_message_patch(session_id, message, revision, timestamp, final_)
            .await?;
        if !applied {
            return Ok(());
        }
        let activity = if self
            .runtime_session(session_id)
            .await?
            .active_turn_id
            .is_some()
        {
            ActivityStatus::Working
        } else if final_ {
            ActivityStatus::Ready
        } else {
            ActivityStatus::Working
        };
        self.refresh_session_message_metadata(session_id, activity)
            .await?;
        Ok(())
    }

    async fn persist_message_patch(
        &self,
        session_id: &str,
        message: Message,
        revision: u64,
        updated_at: i64,
        final_: bool,
    ) -> EngineResult<bool> {
        let patch = crate::protocol::MessagePatch {
            window_id: session_id.to_owned(),
            message: message.clone(),
            revision,
            updated_at,
            final_,
        };
        let mutation = self
            .core
            .store
            .upsert_message_with_event(
                MessageMutation {
                    session_id: session_id.to_owned(),
                    message,
                    revision,
                    updated_at,
                    final_,
                },
                NewEvent {
                    event_id: Some(format!(
                        "message:{session_id}:{}:{revision}:{final_}",
                        patch.message.id
                    )),
                    session_id: Some(session_id.to_owned()),
                    command_id: None,
                    process_epoch: Some(self.core.process_epoch),
                    kind: EventKind::MessagePatch,
                    payload: serde_json::to_value(patch)?,
                    created_at: updated_at,
                },
                Some(self.fence().await?),
            )
            .await?;
        let Some(event) = mutation.event else {
            return Ok(false);
        };
        self.publish_event(event);
        Ok(true)
    }

    async fn persist_item_notification(
        &self,
        appserver_epoch: u64,
        method: &str,
        kind: EventKind,
        params: Value,
    ) -> EngineResult<()> {
        let Some((session_id, thread_id)) = self.notification_session(&params).await else {
            return Ok(());
        };
        let params = bounded_item_notification_params(params)?;
        self.persist_normalized_notification(
            appserver_epoch,
            method,
            kind,
            Some(session_id),
            Some(thread_id),
            params,
        )
        .await
    }

    async fn persist_normalized_notification(
        &self,
        appserver_epoch: u64,
        method: &str,
        kind: EventKind,
        session_id: Option<String>,
        thread_id: Option<String>,
        params: Value,
    ) -> EngineResult<()> {
        let params = bounded_normalized_notification_params(params)?;
        let created_at = unix_millis()?;
        self.append_event(NewEvent {
            event_id: Some(format!(
                "app:{appserver_epoch}:{}:{}",
                method.replace('/', ":"),
                uuid::Uuid::now_v7()
            )),
            session_id,
            command_id: None,
            process_epoch: Some(self.core.process_epoch),
            kind,
            payload: json!({
                "method": method,
                "threadId": thread_id,
                "params": params,
            }),
            created_at,
        })
        .await?;
        Ok(())
    }

    async fn notification_session(&self, params: &Value) -> Option<(String, String)> {
        let thread_id = params
            .get("threadId")
            .and_then(Value::as_str)
            .or_else(|| params.pointer("/thread/id").and_then(Value::as_str))?
            .to_owned();
        let session_id = self.session_id_for_thread(&thread_id).await?;
        Some((session_id, thread_id))
    }

    async fn enqueue_automatic_explainer(
        &self,
        session_id: &str,
        turn_id: &str,
    ) -> EngineResult<()> {
        let summary = self.required_summary(session_id).await?;
        if !summary.features.explainer_enabled {
            return Ok(());
        }
        let _ = self
            .submit_command(CommandRequest {
                command_id: None,
                idempotency_key: format!("auto-explainer:{session_id}:{turn_id}"),
                session_id: Some(session_id.to_owned()),
                command: CommandKind::RunExplainer { focus: None },
                requested_at: unix_millis()?,
                trace_id: Some(format!("turn:{turn_id}")),
            })
            .await?;
        Ok(())
    }

    async fn handle_server_request(
        &self,
        appserver_epoch: u64,
        id: Value,
        method: &str,
        params: Value,
    ) -> EngineResult<()> {
        let mapped_session = self.notification_session(&params).await;
        let kind = if method.contains("requestUserInput") {
            EventKind::UserInputRequested
        } else if method.contains("Approval") || method.contains("approval") {
            EventKind::ApprovalRequested
        } else {
            EventKind::Error
        };
        if let Some((session_id, thread_id)) = mapped_session.as_ref() {
            self.persist_normalized_notification(
                appserver_epoch,
                method,
                kind,
                Some(session_id.clone()),
                Some(thread_id.clone()),
                params.clone(),
            )
            .await?;
        }

        let response = match method {
            "item/commandExecution/requestApproval" | "item/fileChange/requestApproval" => {
                Some(json!({ "decision": "decline" }))
            }
            "execCommandApproval" | "applyPatchApproval" => Some(json!({
                "decision": {
                    "denied": {
                        "rejection": "Fermín Code runs with approvalPolicy=never"
                    }
                }
            })),
            "item/tool/requestUserInput" => Some(json!({ "answers": {} })),
            _ => None,
        };
        let recognized = response.is_some();
        if let Some(response) = response {
            self.core.appserver.respond(id, response).await?;
        } else {
            self.core
                .appserver
                .respond_error(
                    id,
                    -32601,
                    format!("Fermín Code does not provide host method {method}"),
                    None,
                )
                .await?;
        }
        if let Some((session_id, _)) = mapped_session {
            self.append_event(NewEvent {
                event_id: None,
                session_id: Some(session_id),
                command_id: None,
                process_epoch: Some(self.core.process_epoch),
                kind: if !recognized {
                    EventKind::Error
                } else if kind == EventKind::UserInputRequested {
                    EventKind::UserInputResolved
                } else {
                    EventKind::ApprovalResolved
                },
                payload: json!({
                    "method": method,
                    "resolution": if recognized { "automaticDecline" } else { "unsupportedHostMethod" },
                }),
                created_at: unix_millis()?,
            })
            .await?;
        }
        Ok(())
    }

    async fn reconcile_thread(
        &self,
        thread: &Value,
        preferred_session_id: Option<&str>,
    ) -> EngineResult<()> {
        self.reconcile_thread_with_ownership(thread, preferred_session_id, false)
            .await
    }

    async fn reconcile_thread_with_ownership(
        &self,
        thread: &Value,
        preferred_session_id: Option<&str>,
        adopt_for_fermin: bool,
    ) -> EngineResult<()> {
        let thread_id = required_string(thread, "id")?;
        let session_id = if let Some(preferred) = preferred_session_id {
            preferred.to_owned()
        } else if let Some(existing) = self.session_id_for_thread(&thread_id).await {
            existing
        } else {
            thread_id.clone()
        };
        let existing = self.core.store.get_session(&session_id).await?;
        let mut summary = summary_from_thread(thread, &session_id, unix_millis()?)?;
        if let Some(parent_thread_id) = summary.parent_session_id.clone()
            && let Some(parent_session_id) = self.session_id_for_thread(&parent_thread_id).await
        {
            summary.parent_session_id = Some(parent_session_id);
        }
        if let Some(existing) = existing {
            merge_preserved_session_fields(&mut summary, existing.session);
        }
        if adopt_for_fermin {
            summary.managed_by_fermin = true;
            summary.can_send = true;
            summary.can_control_features = true;
            summary.unsupported_reason = None;
            summary.is_minimized = false;
        }
        self.upsert_runtime_session(summary, None).await?;

        let mut active_turn = None;
        if let Some(turns) = thread.get("turns").and_then(Value::as_array) {
            for turn in turns {
                let turn_status = turn
                    .get("status")
                    .and_then(Value::as_str)
                    .unwrap_or("completed");
                if turn_status == "inProgress" {
                    active_turn = turn.get("id").and_then(Value::as_str).map(str::to_owned);
                }
                if let Some(items) = turn.get("items").and_then(Value::as_array) {
                    for item in items {
                        self.reconcile_item(&session_id, item, turn_status != "inProgress")
                            .await?;
                    }
                }
            }
        }
        self.set_active_turn(&session_id, active_turn).await;
        let reconciled_activity = if self
            .runtime_session(&session_id)
            .await?
            .active_turn_id
            .is_some()
        {
            ActivityStatus::Working
        } else if self.required_summary(&session_id).await?.activity_status == ActivityStatus::Error
        {
            ActivityStatus::Error
        } else {
            ActivityStatus::Ready
        };
        self.refresh_session_message_metadata(&session_id, reconciled_activity)
            .await?;
        self.reconcile_native_goal(&session_id, &thread_id).await?;
        self.set_transcript_hydrated(&session_id, true).await;
        Ok(())
    }

    async fn reconcile_item(
        &self,
        session_id: &str,
        item: &Value,
        final_: bool,
    ) -> EngineResult<()> {
        let item_id = item
            .get("id")
            .and_then(Value::as_str)
            .unwrap_or("unknown-item");
        let now = unix_millis()?;
        match item.get("type").and_then(Value::as_str) {
            Some("agentMessage") => {
                let content = item.get("text").and_then(Value::as_str).unwrap_or_default();
                let stored_messages = self.core.store.list_messages(session_id).await?;
                let provider_match = stored_messages
                    .iter()
                    .find(|stored| stored.message.provider_item_id.as_deref() == Some(item_id));
                let canonical_snapshot_match = is_provider_snapshot_item_id(item_id).then(|| {
                    stored_messages.iter().find(|stored| {
                        stored.message.role == crate::protocol::MessageRole::Assistant
                            && stored.message.content == content
                            && !is_provider_snapshot_item_id(&stored.message.id)
                            && stored.message.provider_item_id.as_deref().is_none_or(
                                |provider_id| !is_provider_snapshot_item_id(provider_id),
                            )
                    })
                });
                let id_match = stored_messages
                    .iter()
                    .find(|stored| stored.message.id == item_id);
                let existing = provider_match
                    .or(canonical_snapshot_match.flatten())
                    .or(id_match)
                    .cloned();
                if existing.as_ref().is_some_and(|stored| stored.final_) && !final_ {
                    return Ok(());
                }
                let revision = existing
                    .as_ref()
                    .map(|stored| {
                        if stored.message.content == content
                            && stored.final_ == final_
                            && stored.message.provider_item_id.as_deref() == Some(item_id)
                        {
                            stored.revision
                        } else {
                            stored.revision.saturating_add(1)
                        }
                    })
                    .unwrap_or(1);
                let mut message = existing
                    .as_ref()
                    .map(|stored| stored.message.clone())
                    .unwrap_or_else(|| Message::assistant(item_id, content, now));
                message.content = content.to_owned();
                message.message_type = Some("agentMessage".to_owned());
                message.provider_item_id = Some(item_id.to_owned());
                message.status = (!final_).then(|| "streaming".to_owned());
                let updated_at = existing
                    .as_ref()
                    .map(|stored| stored.updated_at)
                    .unwrap_or(now);
                // A thread/read reconciliation is not merely a local cache
                // repair. The relay is the durable transcript served to
                // Mobile, so every newly recovered or changed assistant item
                // must enter the same message-patch journal as a live App
                // Server notification. Persisting it without an event leaves
                // the engine's messageCount ahead of the relay transcript and
                // makes Mobile stop on the last user bubble.
                self.persist_message_patch(session_id, message, revision, updated_at, final_)
                    .await?;
                let mut index = self.core.runtime.write().await;
                if let Some(runtime) = index.sessions.get_mut(session_id) {
                    runtime.message_buffers.insert(
                        item_id.to_owned(),
                        MessageAccumulator {
                            content: content.to_owned(),
                            revision,
                            timestamp: updated_at,
                        },
                    );
                }
            }
            Some("userMessage") => {
                self.persist_appserver_user_message(session_id, item, now)
                    .await?;
            }
            _ => {}
        }
        Ok(())
    }

    async fn reconcile_all_threads(&self) {
        let known: Vec<String> = self
            .core
            .runtime
            .read()
            .await
            .sessions
            .values()
            .map(|runtime| runtime.thread_id.clone())
            .collect();
        for thread_id in known {
            match self
                .request_with_overload_retry(
                    "thread/read",
                    json!({ "threadId": thread_id, "includeTurns": true }),
                )
                .await
            {
                Ok(response) => {
                    if let Some(thread) = response.get("thread")
                        && let Err(error) = self.reconcile_thread(thread, None).await
                    {
                        warn!(error = %error, "thread reconciliation failed after event lag");
                    }
                }
                Err(error) => warn!(error = %error, "thread/read failed after event lag"),
            }
        }
        if let Ok(mut snapshot) = self.snapshot().await {
            for session in &mut snapshot.sessions {
                session.messages.clear();
            }
            let _ = self
                .append_event(NewEvent {
                    event_id: None,
                    session_id: None,
                    command_id: None,
                    process_epoch: Some(self.core.process_epoch),
                    kind: EventKind::Snapshot,
                    payload: serde_json::to_value(snapshot).unwrap_or_else(|_| json!({})),
                    created_at: unix_millis().unwrap_or_default(),
                })
                .await;
        }
    }
}

async fn request_transport_with_overload_retry(
    transport: &dyn EngineTransport,
    method: &str,
    params: Value,
) -> EngineResult<Value> {
    let mut delay = Duration::from_millis(50);
    let timeout = appserver_request_timeout(method);
    for attempt in 0..=OVERLOAD_RETRIES {
        match transport
            .request_with_timeout(method.to_owned(), params.clone(), timeout)
            .await
        {
            Ok(value) => return Ok(value),
            Err(error) if error.is_overloaded() && attempt < OVERLOAD_RETRIES => {
                time::sleep(delay).await;
                delay = delay.saturating_mul(2);
            }
            Err(error) => return Err(error.into()),
        }
    }
    unreachable!("bounded overload retry loop always returns")
}

fn appserver_request_timeout(method: &str) -> Duration {
    match method {
        "thread/start" | "thread/resume" | "thread/read" => APP_SERVER_THREAD_REQUEST_TIMEOUT,
        _ => APP_SERVER_REQUEST_TIMEOUT,
    }
}

async fn event_loop(
    weak: std::sync::Weak<EngineCore>,
    mut receiver: broadcast::Receiver<AppServerEvent>,
    cancellation: CancellationToken,
) {
    loop {
        tokio::select! {
            () = cancellation.cancelled() => break,
            result = receiver.recv() => {
                let Some(core) = weak.upgrade() else { break };
                let state = EngineState { core };
                match result {
                    Ok(event) => {
                        if let Err(error) = state.reduce_appserver_event(event).await {
                            error!(error = %error, "failed to reduce App Server event");
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(skipped)) => {
                        warn!(skipped, "App Server event consumer lagged; reconciling snapshots");
                        if !state.core.appserver.is_running() {
                            state.core.ready.store(false, Ordering::Release);
                            state.core.cancellation.cancel();
                            break;
                        }
                        state.reconcile_all_threads().await;
                    }
                    Err(broadcast::error::RecvError::Closed) => {
                        state.core.ready.store(false, Ordering::Release);
                        state.core.cancellation.cancel();
                        break;
                    }
                }
            }
        }
    }
}

async fn command_lane_loop(
    weak: std::sync::Weak<EngineCore>,
    lane_name: String,
    mut receiver: mpsc::Receiver<String>,
    cancellation: CancellationToken,
) {
    loop {
        tokio::select! {
            () = cancellation.cancelled() => break,
            command = receiver.recv() => {
                let Some(command_id) = command else { break };
                let Some(core) = weak.upgrade() else { break };
                let state = EngineState { core };
                lock_std(&state.core.active_commands).insert(command_id.clone());
                if let Err(error) = state.process_command_id(&command_id).await {
                    error!(lane = lane_name, command_id, error = %error, "command processing failed");
                }
                lock_std(&state.core.active_commands).remove(&command_id);
                lock_std(&state.core.scheduled_commands).remove(&command_id);
            }
        }
    }
}

impl crate::bridge::BridgeSource for EngineState {
    fn engine_id(&self) -> &str {
        &self.core.config.engine_id
    }

    fn app_server_version(&self) -> &str {
        &self.core.app_server_version
    }

    fn capability_hash(&self) -> &str {
        &self.core.capability_hash
    }

    fn process_epoch(&self) -> u64 {
        self.core.process_epoch
    }

    fn snapshot(&self) -> crate::bridge::BridgeFuture<'_, AuthoritativeSnapshot> {
        Box::pin(async move { self.snapshot_from_store(false).await.map_err(Into::into) })
    }

    fn replay_events(
        &self,
        after_global_sequence: u64,
        limit: usize,
    ) -> crate::bridge::BridgeFuture<'_, Vec<DurableEvent>> {
        Box::pin(async move {
            EngineState::replay_events(self, after_global_sequence, limit)
                .await
                .map_err(Into::into)
        })
    }

    fn submit_remote(
        &self,
        command: CommandRecord,
    ) -> crate::bridge::BridgeFuture<'_, CommandAcceptance> {
        Box::pin(async move {
            if matches!(&command.command, CommandKind::CreateSubagent { .. })
                && subagent_child_session_id(&command).is_none()
            {
                bail!(
                    "relay createSubagent command is missing durable parent/child routing metadata"
                );
            }
            let acceptance = EngineState::submit_command(
                self,
                CommandRequest {
                    command_id: Some(command.command_id),
                    idempotency_key: command.idempotency_key,
                    session_id: command.session_id,
                    command: command.command,
                    requested_at: command.requested_at,
                    trace_id: command.trace_id,
                },
            )
            .await?;
            Ok(acceptance)
        })
    }

    fn subscribe_events(&self) -> broadcast::Receiver<DurableEvent> {
        EngineState::subscribe_events(self)
    }

    fn load_relay_cursor(&self) -> crate::bridge::BridgeFuture<'_, u64> {
        Box::pin(async move {
            Ok(self
                .core
                .store
                .get_cursor(format!("relay:{}", self.core.config.engine_id))
                .await?
                .map(|cursor| cursor.global_sequence)
                .unwrap_or(0))
        })
    }

    fn commit_relay_cursor(&self, global_sequence: u64) -> crate::bridge::BridgeFuture<'_, ()> {
        Box::pin(async move {
            self.core
                .store
                .commit_cursor(ConsumerCursor {
                    consumer_id: format!("relay:{}", self.core.config.engine_id),
                    global_sequence,
                    updated_at: unix_millis()?,
                })
                .await?;
            Ok(())
        })
    }

    fn handle_query(&self, method: &str, params: Value) -> crate::bridge::BridgeFuture<'_, Value> {
        let method = method.to_owned();
        Box::pin(async move {
            match method.as_str() {
                "projects" => {
                    if !params.as_object().is_some_and(serde_json::Map::is_empty) {
                        bail!("invalid projects query parameters");
                    }
                    let projects = self
                        .project_catalog()
                        .map_err(|_| anyhow::anyhow!("projects query failed"))?;
                    serde_json::to_value(projects)
                        .map_err(|_| anyhow::anyhow!("projects query encoding failed"))
                }
                "filePreview" => {
                    let Some(object) = params.as_object() else {
                        bail!("invalid filePreview query parameters");
                    };
                    if object.len() != 1 {
                        bail!("invalid filePreview query parameters");
                    }
                    let path = object
                        .get("path")
                        .and_then(Value::as_str)
                        .filter(|path| !path.trim().is_empty())
                        .ok_or_else(|| anyhow::anyhow!("invalid filePreview query parameters"))?;
                    let preview = self
                        .read_file_preview(path)
                        .await
                        .map_err(|_| anyhow::anyhow!("filePreview query failed"))?;
                    serde_json::to_value(preview)
                        .map_err(|_| anyhow::anyhow!("filePreview query encoding failed"))
                }
                "session" => {
                    let Some(object) = params.as_object() else {
                        bail!("invalid session query parameters");
                    };
                    if object.len() != 1 {
                        bail!("invalid session query parameters");
                    }
                    let window_id = object
                        .get("windowId")
                        .and_then(Value::as_str)
                        .map(str::trim)
                        .filter(|window_id| !window_id.is_empty() && window_id.len() <= 512)
                        .ok_or_else(|| anyhow::anyhow!("invalid session query parameters"))?;
                    let session = match self
                        .resolve_window_id(window_id)
                        .await
                        .map_err(|_| anyhow::anyhow!("session query failed"))?
                    {
                        Some(session_id) => EngineState::session(self, &session_id)
                            .await
                            .map_err(|_| anyhow::anyhow!("session query failed"))?,
                        None => None,
                    };
                    serde_json::to_value(session)
                        .map_err(|_| anyhow::anyhow!("session query encoding failed"))
                }
                "recoverableSessions" => {
                    let query: crate::api::SessionRecoveryQuery = serde_json::from_value(params)
                        .map_err(|_| anyhow::anyhow!("invalid recovery query parameters"))?;
                    if query.query.chars().count() > 1024
                        || query.offset > 100_000
                        || !(1..=100).contains(&query.limit)
                    {
                        bail!("invalid recovery query parameters");
                    }
                    let page = self
                        .recoverable_sessions(query)
                        .await
                        .map_err(|_| anyhow::anyhow!("recovery query failed"))?;
                    serde_json::to_value(page)
                        .map_err(|_| anyhow::anyhow!("recovery query encoding failed"))
                }
                "recoverableSession" => {
                    let Some(object) = params.as_object() else {
                        bail!("invalid recoverableSession query parameters");
                    };
                    if object.len() != 1 {
                        bail!("invalid recoverableSession query parameters");
                    }
                    let recovery_id = object
                        .get("id")
                        .and_then(Value::as_str)
                        .map(str::trim)
                        .filter(|value| !value.is_empty() && value.len() <= 512)
                        .ok_or_else(|| {
                            anyhow::anyhow!("invalid recoverableSession query parameters")
                        })?;
                    let item = self
                        .recovery_item(recovery_id)
                        .await
                        .map_err(|_| anyhow::anyhow!("recoverableSession query failed"))?;
                    serde_json::to_value(item)
                        .map_err(|_| anyhow::anyhow!("recoverableSession query encoding failed"))
                }
                _ => bail!("unsupported read-only relay query method"),
            }
        })
    }
}

impl crate::api::MobileBackend for EngineState {
    fn health(&self) -> crate::api::BackendFuture<'_, crate::api::BackendHealth> {
        Box::pin(async move {
            let health = EngineState::health(self).await;
            Ok(crate::api::BackendHealth {
                ready: self.is_ready() && health.ready,
                role: "engine".to_owned(),
                details: serde_json::to_value(health).map_err(|_| {
                    crate::api::MobileBackendError::Internal(
                        "failed to encode engine health".to_owned(),
                    )
                })?,
            })
        })
    }

    fn snapshot(&self) -> crate::api::BackendFuture<'_, AuthoritativeSnapshot> {
        Box::pin(async move {
            EngineState::mobile_snapshot(self)
                .await
                .map_err(mobile_backend_error)
        })
    }

    fn session(&self, window_id: String) -> crate::api::BackendFuture<'_, Option<SessionSummary>> {
        Box::pin(async move {
            let session_id = self
                .resolve_window_id(&window_id)
                .await
                .map_err(mobile_backend_error)?;
            match session_id {
                Some(session_id) => EngineState::session(self, &session_id)
                    .await
                    .map_err(mobile_backend_error),
                None => Ok(None),
            }
        })
    }

    fn command(&self, command_id: String) -> crate::api::BackendFuture<'_, Option<CommandRecord>> {
        Box::pin(async move {
            self.core.store.get_command(command_id).await.map_err(|_| {
                crate::api::MobileBackendError::Internal(
                    "failed to read durable command state".to_owned(),
                )
            })
        })
    }

    fn submit_command(
        &self,
        target_window_id: Option<String>,
        mut request: CommandRequest,
    ) -> crate::api::BackendFuture<'_, CommandAcceptance> {
        Box::pin(async move {
            if let Some(window_id) = target_window_id {
                let resolved = self
                    .resolve_window_id(&window_id)
                    .await
                    .map_err(mobile_backend_error)?;
                let target_session_id = resolved.ok_or_else(|| {
                    crate::api::MobileBackendError::NotFound(format!(
                        "session {window_id} was not found"
                    ))
                })?;
                request = EngineState::route_targeted_command(request, target_session_id)
                    .map_err(mobile_backend_error)?;
            }
            EngineState::submit_command(self, request)
                .await
                .map_err(mobile_backend_error)
        })
    }

    fn models(&self, _window_id: String) -> crate::api::BackendFuture<'_, ModelCatalog> {
        Box::pin(async move { Ok(EngineState::models(self).await) })
    }

    fn projects(&self) -> crate::api::BackendFuture<'_, crate::api::ProjectCatalog> {
        Box::pin(async move { self.project_catalog().map_err(mobile_backend_error) })
    }

    fn prompt_improver_preference(
        &self,
    ) -> crate::api::BackendFuture<'_, crate::api::PromptImproverPreferenceRecord> {
        Box::pin(async move { Ok(self.core.prompt_preference.read().await.clone()) })
    }

    fn set_prompt_improver_preference(
        &self,
        variant: crate::api::PromptImproverVariant,
    ) -> crate::api::BackendFuture<'_, crate::api::PromptImproverPreferenceRecord> {
        Box::pin(async move {
            let mut preference = self.core.prompt_preference.write().await;
            let mut next = preference.clone();
            next.version = next.version.saturating_add(1);
            next.variant = variant;
            next.updated_at = Some(unix_millis().map_err(mobile_backend_error)?.to_string());
            let encoded = serde_json::to_vec(&next).map_err(|_| {
                crate::api::MobileBackendError::Internal(
                    "failed to encode prompt preference".to_owned(),
                )
            })?;
            write_private_file(&self.prompt_preference_path(), &encoded)
                .await
                .map_err(mobile_backend_error)?;
            *preference = next.clone();
            Ok(next)
        })
    }

    fn file_preview(&self, path: String) -> crate::api::BackendFuture<'_, crate::api::FilePreview> {
        Box::pin(async move {
            self.read_file_preview(&path)
                .await
                .map_err(mobile_backend_error)
        })
    }

    fn upload_attachment(
        &self,
        window_id: String,
        upload: crate::api::AttachmentUpload,
    ) -> crate::api::BackendFuture<'_, crate::protocol::ImageAttachment> {
        Box::pin(async move {
            let session_id = self
                .resolve_window_id(&window_id)
                .await
                .map_err(mobile_backend_error)?
                .ok_or_else(|| {
                    crate::api::MobileBackendError::NotFound(format!(
                        "session {window_id} was not found"
                    ))
                })?;
            self.persist_attachment(&session_id, upload)
                .await
                .map_err(mobile_backend_error)
        })
    }

    fn attachment_content(
        &self,
        path: String,
    ) -> crate::api::BackendFuture<'_, crate::api::AttachmentContent> {
        Box::pin(async move {
            self.read_attachment(&path)
                .await
                .map_err(mobile_backend_error)
        })
    }

    fn session_history(
        &self,
        query: crate::api::SessionHistoryQuery,
    ) -> crate::api::BackendFuture<'_, crate::api::SessionHistoryPage> {
        Box::pin(async move {
            self.active_session_history(query)
                .await
                .map_err(mobile_backend_error)
        })
    }

    fn resume_history(
        &self,
        history_id: String,
        idempotency_key: String,
    ) -> crate::api::BackendFuture<'_, crate::api::SessionHistoryResumeResult> {
        Box::pin(async move {
            let session = self
                .core
                .store
                .get_session(history_id.clone())
                .await
                .map_err(|error| mobile_backend_error(error.into()))?
                .filter(|stored| stored.session.managed_by_fermin)
                .map(|stored| stored.session)
                .ok_or_else(|| {
                    crate::api::MobileBackendError::NotFound(format!(
                        "history session {history_id} was not found in Fermín Code"
                    ))
                })?;
            let mut request = CommandRequest {
                command_id: None,
                idempotency_key,
                session_id: Some(session.session_id.clone()),
                command: CommandKind::SetMinimized { minimized: false },
                requested_at: unix_millis().map_err(mobile_backend_error)?,
                trace_id: None,
            };
            if session.runtime_status.as_deref() == Some("ARCHIVED") {
                request = Self::attach_resume_history_trace(request);
            }
            let acceptance = EngineState::submit_command(self, request)
                .await
                .map_err(mobile_backend_error)?;
            Ok(crate::api::SessionHistoryResumeResult {
                acceptance,
                session_id: session.session_id,
                window_id: Some(session.window_id),
                project_path: session.project_path,
            })
        })
    }

    fn recoverable_sessions(
        &self,
        query: crate::api::SessionRecoveryQuery,
    ) -> crate::api::BackendFuture<'_, crate::api::SessionRecoveryPage> {
        Box::pin(async move {
            self.recoverable_sessions(query)
                .await
                .map_err(mobile_backend_error)
        })
    }

    fn recover_session(
        &self,
        recovery_id: String,
        idempotency_key: String,
    ) -> crate::api::BackendFuture<'_, crate::api::SessionRecoveryResult> {
        Box::pin(async move {
            let item = self
                .recovery_item(&recovery_id)
                .await
                .map_err(mobile_backend_error)?
                .ok_or_else(|| {
                    crate::api::MobileBackendError::NotFound(format!(
                        "recovery session {recovery_id} was not found"
                    ))
                })?;
            if !item.can_recover {
                return Err(crate::api::MobileBackendError::Conflict(
                    "the selected session cannot be recovered".to_owned(),
                ));
            }
            let request = CommandRequest {
                command_id: None,
                idempotency_key,
                session_id: Some(recovery_id.clone()),
                command: CommandKind::RecoverSession,
                requested_at: unix_millis().map_err(mobile_backend_error)?,
                trace_id: None,
            };
            let acceptance = EngineState::submit_command(self, request)
                .await
                .map_err(mobile_backend_error)?;
            Ok(crate::api::SessionRecoveryResult {
                acceptance,
                session_id: recovery_id.clone(),
                window_id: Some(recovery_id),
                project_path: item.project_path,
            })
        })
    }

    fn replay_events(
        &self,
        cursor: crate::api::ReplayCursor,
        limit: usize,
    ) -> crate::api::BackendFuture<'_, Vec<DurableEvent>> {
        Box::pin(async move {
            let after = if let Some(sequence) = cursor.after_global_sequence {
                sequence
            } else if let Some(event_id) = cursor.last_event_id {
                match event_id.parse::<u64>() {
                    Ok(sequence) => sequence,
                    Err(_) => self
                        .global_sequence_for_event(&event_id)
                        .await
                        .map_err(mobile_backend_error)?
                        .ok_or_else(|| {
                            crate::api::MobileBackendError::Invalid(format!(
                                "unknown Last-Event-ID {event_id}"
                            ))
                        })?,
                }
            } else {
                0
            };
            EngineState::replay_events(self, after, limit)
                .await
                .map_err(mobile_backend_error)
        })
    }

    fn subscribe_events(
        &self,
    ) -> Result<crate::api::BackendEventStream, crate::api::MobileBackendError> {
        let mut receiver = EngineState::subscribe_events(self);
        Ok(Box::pin(async_stream::stream! {
            loop {
                match receiver.recv().await {
                    Ok(event) => yield Ok(event),
                    Err(broadcast::error::RecvError::Lagged(skipped)) => {
                        yield Err(crate::api::MobileBackendError::Unavailable(format!(
                            "live event consumer lagged by {skipped}; reconnect with cursor replay"
                        )));
                        break;
                    }
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
        }))
    }
}

impl EngineState {
    async fn resolve_window_id(&self, window_id: &str) -> EngineResult<Option<String>> {
        if self
            .core
            .store
            .get_session(window_id)
            .await?
            .is_some_and(|stored| stored.session.managed_by_fermin)
        {
            return Ok(Some(window_id.to_owned()));
        }
        Ok(self
            .core
            .store
            .list_sessions()
            .await?
            .into_iter()
            .find(|stored| {
                stored.session.managed_by_fermin && stored.session.window_id == window_id
            })
            .map(|stored| stored.session.session_id))
    }

    fn project_catalog(&self) -> EngineResult<crate::api::ProjectCatalog> {
        let mut items = Vec::new();
        for root in &self.core.config.workspace_roots {
            let canonical = std::fs::canonicalize(root)?;
            let root_name = canonical
                .file_name()
                .and_then(|value| value.to_str())
                .unwrap_or("projects")
                .to_owned();
            items.push(crate::api::ProjectDirectory {
                name: root_name,
                path: canonical.display().to_string(),
                kind: Some("root".to_owned()),
            });
            for entry in std::fs::read_dir(&canonical)? {
                let entry = entry?;
                if !entry.file_type()?.is_dir() {
                    continue;
                }
                let name = entry.file_name().to_string_lossy().into_owned();
                if name.starts_with('.') {
                    continue;
                }
                items.push(crate::api::ProjectDirectory {
                    name,
                    path: entry.path().display().to_string(),
                    kind: Some("directory".to_owned()),
                });
            }
        }
        items.sort_by(|left, right| left.name.cmp(&right.name).then(left.path.cmp(&right.path)));
        items.dedup_by(|left, right| left.path == right.path);
        Ok(crate::api::ProjectCatalog {
            root_path: self
                .core
                .config
                .workspace_roots
                .first()
                .map(|path| path.display().to_string()),
            items,
        })
    }

    async fn read_file_preview(&self, path: &str) -> EngineResult<crate::api::FilePreview> {
        let canonical = self.validated_project_path(path)?;
        let metadata = tokio::fs::metadata(&canonical).await?;
        if !metadata.is_file() {
            return Err(EngineError::UnsupportedCommand(
                "file preview path is not a regular file".to_owned(),
            ));
        }
        let size_bytes = usize::try_from(metadata.len()).map_err(|_| {
            EngineError::UnsupportedCommand("file size does not fit this platform".to_owned())
        })?;
        if size_bytes > crate::api::MAX_FILE_PREVIEW_BYTES {
            return Err(EngineError::UnsupportedCommand(format!(
                "file exceeds {} byte preview limit",
                crate::api::MAX_FILE_PREVIEW_BYTES
            )));
        }
        let bytes = tokio::fs::read(&canonical).await?;
        let content = String::from_utf8(bytes).map_err(|_| {
            EngineError::UnsupportedCommand("file preview requires UTF-8 text".to_owned())
        })?;
        let extension = canonical
            .extension()
            .and_then(|value| value.to_str())
            .unwrap_or_default()
            .to_ascii_lowercase();
        let kind = match extension.as_str() {
            "md" | "markdown" => crate::api::FilePreviewKind::Markdown,
            "json" => crate::api::FilePreviewKind::Json,
            "rs" | "swift" | "js" | "ts" | "tsx" | "jsx" | "py" | "go" | "toml" | "yaml"
            | "yml" | "sh" => crate::api::FilePreviewKind::Code,
            _ => crate::api::FilePreviewKind::Text,
        };
        Ok(crate::api::FilePreview {
            path: canonical.display().to_string(),
            name: canonical
                .file_name()
                .and_then(|value| value.to_str())
                .unwrap_or("file")
                .to_owned(),
            content,
            kind,
            language: (!extension.is_empty()).then_some(extension),
            size_bytes,
        })
    }

    fn attachment_root(&self) -> PathBuf {
        self.engine_data_root().join("fermin-attachments")
    }

    fn engine_data_root(&self) -> PathBuf {
        engine_data_root_for_config(&self.core.config)
    }

    fn goal_objective_path(&self, session_id: &str) -> PathBuf {
        self.engine_data_root()
            .join("fermin-goals")
            .join(safe_path_component(session_id))
            .join("goal_prompt.md")
    }

    fn prompt_preference_path(&self) -> PathBuf {
        self.engine_data_root()
            .join("prompt-improver-preference.json")
    }

    async fn persist_attachment(
        &self,
        session_id: &str,
        upload: crate::api::AttachmentUpload,
    ) -> EngineResult<crate::protocol::ImageAttachment> {
        validate_image_bytes(&upload.mime_type, &upload.bytes)?;
        let extension = image_extension(&upload.mime_type).ok_or_else(|| {
            EngineError::UnsupportedCommand(format!(
                "unsupported image MIME type {}",
                upload.mime_type
            ))
        })?;
        let attachment_id = uuid::Uuid::now_v7().to_string();
        let directory = self.attachment_root().join(safe_path_component(session_id));
        let path = directory.join(format!("{attachment_id}.{extension}"));
        write_private_file(&path, &upload.bytes).await?;
        Ok(crate::protocol::ImageAttachment {
            id: attachment_id,
            name: sanitized_file_name(&upload.file_name, extension),
            path: Some(path.display().to_string()),
            size: upload.bytes.len() as u64,
            mime_type: upload.mime_type,
            preview_data: None,
        })
    }

    async fn validated_turn_attachments(
        &self,
        session_id: &str,
        attachments: &[crate::protocol::ImageAttachment],
    ) -> EngineResult<Vec<crate::protocol::ImageAttachment>> {
        if attachments.is_empty() {
            return Ok(Vec::new());
        }
        ensure_private_directory(&self.attachment_root()).await?;
        let canonical_root = tokio::fs::canonicalize(self.attachment_root())
            .await
            .map_err(|_| {
                EngineError::UnsupportedCommand(
                    "engine attachment storage is unavailable".to_owned(),
                )
            })?;
        let mut validated = Vec::with_capacity(attachments.len());
        for attachment in attachments {
            if attachment
                .path
                .as_deref()
                .is_some_and(|path| path.starts_with(RELAY_ATTACHMENT_PREFIX))
            {
                validated.push(
                    self.materialize_relay_attachment(session_id, attachment)
                        .await?,
                );
                continue;
            }
            let path = attachment.path.as_deref().ok_or_else(|| {
                EngineError::UnsupportedCommand(
                    "image attachment is missing an engine-owned path".to_owned(),
                )
            })?;
            let canonical = tokio::fs::canonicalize(path).await.map_err(|_| {
                EngineError::UnsupportedCommand("image attachment is unavailable".to_owned())
            })?;
            if !canonical.starts_with(&canonical_root) {
                return Err(EngineError::PathOutsideWorkspace(
                    "attachment path is not engine-owned".to_owned(),
                ));
            }
            let metadata = tokio::fs::metadata(&canonical).await?;
            if !metadata.is_file()
                || metadata.len() == 0
                || metadata.len() > crate::api::MAX_ATTACHMENT_BYTES as u64
                || metadata.len() != attachment.size
            {
                return Err(EngineError::UnsupportedCommand(
                    "image attachment metadata does not match engine storage".to_owned(),
                ));
            }
            let bytes = tokio::fs::read(&canonical).await?;
            validate_image_bytes(&attachment.mime_type, &bytes)?;
            let mut materialized = attachment.clone();
            materialized.path = Some(canonical.display().to_string());
            validated.push(materialized);
        }
        Ok(validated)
    }

    async fn materialize_relay_attachment(
        &self,
        session_id: &str,
        attachment: &crate::protocol::ImageAttachment,
    ) -> EngineResult<crate::protocol::ImageAttachment> {
        if attachment.size == 0 || attachment.size > crate::api::MAX_ATTACHMENT_BYTES as u64 {
            return Err(EngineError::UnsupportedCommand(
                "relay attachment size is invalid".to_owned(),
            ));
        }
        let token = attachment
            .path
            .as_deref()
            .and_then(|path| path.strip_prefix(RELAY_ATTACHMENT_PREFIX))
            .filter(|token| relay_attachment_mime(token).is_some())
            .ok_or_else(|| {
                EngineError::UnsupportedCommand("relay attachment token is invalid".to_owned())
            })?;
        if relay_attachment_mime(token) != Some(attachment.mime_type.as_str()) {
            return Err(EngineError::UnsupportedCommand(
                "relay attachment metadata is inconsistent".to_owned(),
            ));
        }
        let directory = self
            .attachment_root()
            .join("relay-cache")
            .join(safe_path_component(session_id));
        ensure_private_directory(&directory).await?;
        let path = directory.join(token);
        if let Ok(metadata) = tokio::fs::symlink_metadata(&path).await {
            if metadata.file_type().is_file() && metadata.len() == attachment.size {
                let bytes = tokio::fs::read(&path).await?;
                if validate_image_bytes(&attachment.mime_type, &bytes).is_ok() {
                    let mut materialized = attachment.clone();
                    materialized.path = Some(path.display().to_string());
                    return Ok(materialized);
                }
            }
            let _ = tokio::fs::remove_file(&path).await;
        }

        let relay = self.core.config.relay.as_ref().ok_or_else(|| {
            EngineError::UnsupportedCommand(
                "relay attachment cannot be fetched without relay configuration".to_owned(),
            )
        })?;
        let url = relay_attachment_url(&relay.url, token)?;
        let bearer = crate::config::read_secret(&relay.token_file).map_err(|_| {
            EngineError::Configuration("relay attachment credential is unavailable".to_owned())
        })?;
        let response = self
            .core
            .attachment_http
            .get(url)
            .bearer_auth(bearer)
            .header(reqwest::header::ACCEPT, attachment.mime_type.as_str())
            .header(reqwest::header::ACCEPT_ENCODING, "identity")
            .send()
            .await
            .map_err(|_| {
                EngineError::UnsupportedCommand("relay attachment is unavailable".to_owned())
            })?;
        if response.status() != reqwest::StatusCode::OK {
            return Err(EngineError::UnsupportedCommand(
                "relay attachment is unavailable".to_owned(),
            ));
        }
        let returned_mime = response
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.split(';').next())
            .map(str::trim);
        if returned_mime != Some(attachment.mime_type.as_str())
            || response
                .content_length()
                .is_some_and(|length| length != attachment.size)
        {
            return Err(EngineError::UnsupportedCommand(
                "relay attachment response metadata is invalid".to_owned(),
            ));
        }
        let mut bytes = Vec::with_capacity(attachment.size as usize);
        let mut stream = response.bytes_stream();
        while let Some(chunk) = stream.next().await {
            let chunk = chunk.map_err(|_| {
                EngineError::UnsupportedCommand("relay attachment download failed".to_owned())
            })?;
            if bytes.len().saturating_add(chunk.len()) > crate::api::MAX_ATTACHMENT_BYTES
                || bytes.len().saturating_add(chunk.len()) > attachment.size as usize
            {
                return Err(EngineError::UnsupportedCommand(
                    "relay attachment exceeded its declared size".to_owned(),
                ));
            }
            bytes.extend_from_slice(&chunk);
        }
        if bytes.len() as u64 != attachment.size {
            return Err(EngineError::UnsupportedCommand(
                "relay attachment download was incomplete".to_owned(),
            ));
        }
        validate_image_bytes(&attachment.mime_type, &bytes)?;
        write_private_file(&path, &bytes).await?;
        let mut materialized = attachment.clone();
        materialized.path = Some(path.display().to_string());
        Ok(materialized)
    }

    async fn read_attachment(&self, path: &str) -> EngineResult<crate::api::AttachmentContent> {
        let canonical_root = std::fs::canonicalize(self.attachment_root())?;
        let canonical = std::fs::canonicalize(path)?;
        if !canonical.starts_with(&canonical_root) {
            return Err(EngineError::PathOutsideWorkspace(
                canonical.display().to_string(),
            ));
        }
        let bytes = tokio::fs::read(&canonical).await?;
        let mime_type = mime_guess::from_path(&canonical)
            .first_raw()
            .unwrap_or("application/octet-stream")
            .to_owned();
        Ok(crate::api::AttachmentContent {
            mime_type,
            bytes: Bytes::from(bytes),
        })
    }

    async fn active_session_history(
        &self,
        query: crate::api::SessionHistoryQuery,
    ) -> EngineResult<crate::api::SessionHistoryPage> {
        let started = std::time::Instant::now();
        let needle = query.query.trim().to_ascii_lowercase();
        let mut items = Vec::new();
        for stored in self.core.store.list_sessions().await? {
            let session = stored.session;
            if !session.managed_by_fermin {
                continue;
            }
            let archived = session.runtime_status.as_deref() == Some("ARCHIVED");
            if (query.state == crate::api::SessionHistoryState::Active && archived)
                || (query.state == crate::api::SessionHistoryState::Archived && !archived)
            {
                continue;
            }
            if let Some(project_path) = query.project_path.as_deref()
                && session.project_path.as_deref() != Some(project_path)
            {
                continue;
            }
            if query.from.is_some_and(|from| session.updated_at < from)
                || query.to.is_some_and(|to| session.updated_at > to)
            {
                continue;
            }
            let haystack = format!(
                "{} {} {}",
                session.display_name,
                session.project_name.as_deref().unwrap_or_default(),
                session.last_message_preview.as_deref().unwrap_or_default()
            )
            .to_ascii_lowercase();
            if !needle.is_empty() && !haystack.contains(&needle) {
                continue;
            }
            let score = if needle.is_empty() {
                0.0
            } else if session.display_name.to_ascii_lowercase().contains(&needle) {
                2.0
            } else {
                1.0
            };
            items.push(crate::api::SessionHistoryItem {
                id: session.session_id.clone(),
                session_uuid: Some(session.session_id.clone()),
                project_key: session.project_key.clone(),
                project_name: session
                    .project_name
                    .clone()
                    .unwrap_or_else(|| session.project_key.clone()),
                session_id: session.session_id.clone(),
                session_name: session.display_name.clone(),
                session_path: session
                    .provider_session_path
                    .clone()
                    .or(session.project_path.clone())
                    .unwrap_or_default(),
                created_at: session.created_at.unwrap_or(session.updated_at),
                updated_at: session.updated_at,
                state: if archived {
                    crate::api::SessionHistoryState::Archived
                } else {
                    crate::api::SessionHistoryState::Active
                },
                window_id: Some(session.window_id.clone()),
                archived_id: archived.then(|| session.session_id.clone()),
                score,
                preview: session.last_message_preview.unwrap_or_default(),
                matched_in: (!needle.is_empty()).then_some("session".to_owned()),
                can_resume: true,
            });
        }
        match query.sort {
            crate::api::SessionHistorySort::Relevance => items.sort_by(|left, right| {
                right
                    .score
                    .total_cmp(&left.score)
                    .then(right.updated_at.cmp(&left.updated_at))
            }),
            crate::api::SessionHistorySort::Recent => {
                items.sort_by(|left, right| right.updated_at.cmp(&left.updated_at))
            }
            crate::api::SessionHistorySort::Name => items.sort_by(|left, right| {
                left.session_name
                    .to_ascii_lowercase()
                    .cmp(&right.session_name.to_ascii_lowercase())
            }),
        }
        let total = items.len();
        let offset = query.offset.min(total);
        let end = offset.saturating_add(query.limit).min(total);
        let page = items[offset..end].to_vec();
        Ok(crate::api::SessionHistoryPage {
            items: page,
            offset: query.offset,
            limit: query.limit,
            total,
            has_more: end < total,
            updated_at: unix_millis()?,
            search_ms: started.elapsed().as_secs_f64() * 1_000.0,
            index_build_ms: 0.0,
            indexed_sessions: total,
            indexed_terms: 0,
        })
    }

    async fn recoverable_sessions(
        &self,
        query: crate::api::SessionRecoveryQuery,
    ) -> EngineResult<crate::api::SessionRecoveryPage> {
        let needle = query.query.trim().to_ascii_lowercase();
        let mut items = Vec::new();
        for stored in self.core.store.list_sessions().await? {
            let session = stored.session;
            if session.managed_by_fermin {
                continue;
            }
            let matched = recovery_metadata_match(&session, &needle);
            let content_match = if matched.is_none() && !needle.is_empty() {
                recovery_message_match(
                    self.core
                        .store
                        .list_messages(session.session_id.clone())
                        .await?,
                    &needle,
                )
            } else {
                None
            };
            if !needle.is_empty() && matched.is_none() && content_match.is_none() {
                continue;
            }
            let (score, matched_in, preview) = match (matched, content_match) {
                (Some((score, matched_in)), _) => (
                    score,
                    Some(matched_in.to_owned()),
                    session.last_message_preview.clone().unwrap_or_default(),
                ),
                (None, Some(preview)) => (1.0, Some("contenido".to_owned()), preview),
                (None, None) => (
                    0.0,
                    None,
                    session.last_message_preview.clone().unwrap_or_default(),
                ),
            };
            items.push(session_recovery_item(&session, score, matched_in, preview));
        }
        if needle.is_empty() {
            items.sort_by(|left, right| right.updated_at.cmp(&left.updated_at));
        } else {
            items.sort_by(|left, right| {
                right
                    .score
                    .total_cmp(&left.score)
                    .then(right.updated_at.cmp(&left.updated_at))
            });
        }
        let total = items.len();
        let offset = query.offset.min(total);
        let end = offset.saturating_add(query.limit).min(total);
        Ok(crate::api::SessionRecoveryPage {
            items: items[offset..end].to_vec(),
            offset: query.offset,
            limit: query.limit,
            total,
            has_more: end < total,
            updated_at: unix_millis()?,
        })
    }

    async fn recovery_item(
        &self,
        recovery_id: &str,
    ) -> EngineResult<Option<crate::api::SessionRecoveryItem>> {
        Ok(self
            .core
            .store
            .get_session(recovery_id)
            .await?
            .map(|stored| {
                let preview = stored
                    .session
                    .last_message_preview
                    .clone()
                    .unwrap_or_default();
                session_recovery_item(&stored.session, 0.0, None, preview)
            }))
    }

    async fn global_sequence_for_event(&self, event_id: &str) -> EngineResult<Option<u64>> {
        let mut after = 0;
        loop {
            let page = EngineState::replay_events(self, after, EVENT_REPLAY_PAGE).await?;
            if let Some(event) = page.iter().find(|event| event.event_id == event_id) {
                return Ok(Some(event.global_sequence));
            }
            let Some(last) = page.last() else {
                return Ok(None);
            };
            after = last.global_sequence;
            if page.len() < EVENT_REPLAY_PAGE {
                return Ok(None);
            }
        }
    }
}

fn recovery_metadata_match(session: &SessionSummary, needle: &str) -> Option<(f64, &'static str)> {
    if needle.is_empty() {
        return None;
    }
    let fields = [
        (session.display_name.as_str(), 6.0, "nombre"),
        (
            session.session_name.as_deref().unwrap_or_default(),
            6.0,
            "nombre",
        ),
        (
            session.project_name.as_deref().unwrap_or_default(),
            5.0,
            "proyecto",
        ),
        (session.project_key.as_str(), 5.0, "proyecto"),
        (
            session.project_path.as_deref().unwrap_or_default(),
            4.0,
            "ruta",
        ),
        (
            session.last_message_preview.as_deref().unwrap_or_default(),
            3.0,
            "contenido",
        ),
    ];
    fields.into_iter().find_map(|(value, score, field)| {
        value
            .to_ascii_lowercase()
            .contains(needle)
            .then_some((score, field))
    })
}

fn recovery_message_match(
    messages: Vec<crate::protocol::StoredMessage>,
    needle: &str,
) -> Option<String> {
    for stored in messages.into_iter().rev() {
        let message = stored.message;
        for value in [
            Some(message.content.as_str()),
            message.original_prompt.as_deref(),
            message.transformed_prompt.as_deref(),
            message.improved_prompt.as_deref(),
        ]
        .into_iter()
        .flatten()
        {
            if value.to_ascii_lowercase().contains(needle) {
                return Some(recovery_match_preview(value, needle));
            }
        }
    }
    None
}

fn recovery_match_preview(value: &str, needle: &str) -> String {
    let lowered = value.to_ascii_lowercase();
    let Some(start) = lowered.find(needle) else {
        return crate::protocol::bounded_session_preview(value.trim());
    };
    let end = start.saturating_add(needle.len()).min(value.len());
    let prefix_start = value[..start]
        .char_indices()
        .rev()
        .nth(80)
        .map_or(0, |(index, _)| index);
    let suffix_end = value[end..]
        .char_indices()
        .nth(240)
        .map_or(value.len(), |(index, _)| end + index);
    let compact = value[prefix_start..suffix_end]
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    let prefix = if prefix_start > 0 { "…" } else { "" };
    let suffix = if suffix_end < value.len() { "…" } else { "" };
    crate::protocol::bounded_session_preview(&format!("{prefix}{compact}{suffix}"))
}

fn session_recovery_item(
    session: &SessionSummary,
    score: f64,
    matched_in: Option<String>,
    preview: String,
) -> crate::api::SessionRecoveryItem {
    crate::api::SessionRecoveryItem {
        id: session.session_id.clone(),
        project_name: session
            .project_name
            .clone()
            .unwrap_or_else(|| session.project_key.clone()),
        project_path: session.project_path.clone(),
        session_name: recovery_session_name(session),
        created_at: session.created_at.unwrap_or(session.updated_at),
        updated_at: session.updated_at,
        archived: session.runtime_status.as_deref() == Some("ARCHIVED"),
        score,
        preview: crate::protocol::bounded_session_preview(&preview),
        matched_in,
        can_recover: session
            .provider_session_id
            .as_deref()
            .is_some_and(|value| !value.trim().is_empty()),
    }
}

fn recovery_session_name(session: &SessionSummary) -> String {
    const MAX_RECOVERY_SESSION_NAME_CHARS: usize = 160;

    let raw = session
        .session_name
        .as_deref()
        .or(session.window_name.as_deref())
        .unwrap_or(&session.display_name);
    let compact = raw.split_whitespace().collect::<Vec<_>>().join(" ");
    let mut characters = compact.chars();
    let bounded: String = characters
        .by_ref()
        .take(MAX_RECOVERY_SESSION_NAME_CHARS)
        .collect();
    if characters.next().is_some() {
        format!("{bounded}…")
    } else {
        bounded
    }
}

fn mobile_backend_error(error: EngineError) -> crate::api::MobileBackendError {
    match error {
        EngineError::SessionNotFound(message) => crate::api::MobileBackendError::NotFound(message),
        EngineError::NoActiveTurn(message) | EngineError::InvalidModel(message) => {
            crate::api::MobileBackendError::Conflict(message)
        }
        EngineError::ObserverUnavailable => {
            crate::api::MobileBackendError::Unavailable("observer runtime unavailable".to_owned())
        }
        EngineError::Feature(_) => {
            crate::api::MobileBackendError::Unavailable("observer workflow failed".to_owned())
        }
        EngineError::UnsupportedCommand(message)
        | EngineError::Configuration(message)
        | EngineError::PathOutsideWorkspace(message) => {
            crate::api::MobileBackendError::Invalid(message)
        }
        EngineError::CommandLaneClosed(message) | EngineError::InvalidResponse(message) => {
            crate::api::MobileBackendError::Unavailable(message)
        }
        EngineError::ShuttingDown => {
            crate::api::MobileBackendError::Unavailable("engine is shutting down".to_owned())
        }
        EngineError::AppServer(error) => crate::api::MobileBackendError::Unavailable(
            redacted_error(&EngineError::AppServer(error)),
        ),
        EngineError::Store(_) | EngineError::Json(_) | EngineError::Io(_) => {
            crate::api::MobileBackendError::Internal("durable engine failure".to_owned())
        }
    }
}

fn safe_path_component(value: &str) -> String {
    value
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() || matches!(character, '-' | '_') {
                character
            } else {
                '_'
            }
        })
        .collect()
}

fn lock_std<T>(mutex: &StdMutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn sanitized_file_name(value: &str, fallback_extension: &str) -> String {
    let name = Path::new(value)
        .file_name()
        .and_then(|value| value.to_str())
        .filter(|value| !value.trim().is_empty())
        .unwrap_or("image");
    if Path::new(name).extension().is_some() {
        name.to_owned()
    } else {
        format!("{name}.{fallback_extension}")
    }
}

fn image_extension(mime_type: &str) -> Option<&'static str> {
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
    if uuid::Uuid::parse_str(identifier).is_err() {
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

fn relay_attachment_url(base_url: &str, token: &str) -> EngineResult<url::Url> {
    if relay_attachment_mime(token).is_none() {
        return Err(EngineError::UnsupportedCommand(
            "relay attachment token is invalid".to_owned(),
        ));
    }
    let mut url = url::Url::parse(base_url)
        .map_err(|_| EngineError::Configuration("relay attachment URL is invalid".to_owned()))?;
    let scheme = match url.scheme() {
        "wss" => "https",
        "ws" => "http",
        _ => {
            return Err(EngineError::Configuration(
                "relay attachment URL has an unsupported scheme".to_owned(),
            ));
        }
    };
    url.set_scheme(scheme).map_err(|_| {
        EngineError::Configuration("relay attachment URL scheme is invalid".to_owned())
    })?;
    let segments = url
        .path_segments()
        .ok_or_else(|| {
            EngineError::Configuration("relay attachment URL cannot contain a base path".to_owned())
        })?
        .collect::<Vec<_>>();
    if !segments.ends_with(&["v1", "engine", "connect"]) {
        return Err(EngineError::Configuration(
            "relay URL must end with /v1/engine/connect".to_owned(),
        ));
    }
    {
        let mut path = url.path_segments_mut().map_err(|_| {
            EngineError::Configuration("relay attachment URL path is invalid".to_owned())
        })?;
        path.pop().push("attachments").push(token);
    }
    url.set_query(None);
    Ok(url)
}

fn validate_image_bytes(mime_type: &str, bytes: &[u8]) -> EngineResult<()> {
    let valid = match mime_type {
        "image/png" => bytes.starts_with(&[0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a]),
        "image/jpeg" => bytes.starts_with(&[0xff, 0xd8, 0xff]),
        "image/gif" => bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a"),
        "image/webp" => bytes.len() >= 12 && bytes.starts_with(b"RIFF") && &bytes[8..12] == b"WEBP",
        _ => false,
    };
    if valid {
        Ok(())
    } else {
        Err(EngineError::UnsupportedCommand(
            "attachment bytes do not match the declared image MIME type".to_owned(),
        ))
    }
}

async fn ensure_private_directory(path: &Path) -> EngineResult<()> {
    tokio::fs::create_dir_all(path).await?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        tokio::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700)).await?;
    }
    Ok(())
}

async fn write_private_file(path: &Path, contents: &[u8]) -> EngineResult<()> {
    let parent = path.parent().ok_or_else(|| {
        EngineError::Configuration(format!("path has no parent: {}", path.display()))
    })?;
    ensure_private_directory(parent).await?;
    let temporary = parent.join(format!(".goal-{}.tmp", uuid::Uuid::now_v7()));
    let destination = path.to_path_buf();
    let contents = contents.to_vec();
    tokio::task::spawn_blocking(move || -> EngineResult<()> {
        use std::io::Write;
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&temporary)?;
        if let Err(error) = file.write_all(&contents).and_then(|_| file.sync_all()) {
            let _ = std::fs::remove_file(&temporary);
            return Err(error.into());
        }
        if let Err(error) = std::fs::rename(&temporary, &destination) {
            let _ = std::fs::remove_file(&temporary);
            return Err(error.into());
        }
        Ok(())
    })
    .await
    .map_err(|_| EngineError::Io(std::io::Error::other("private file writer task failed")))??;
    Ok(())
}

fn goal_fallback_bootstrap(objective_file: &Path) -> String {
    format!(
        "GOAL MODE OBJECTIVE FILE:\n{}\nRead that file as the authoritative objective. Continue until every requirement is complete and verified.",
        objective_file.display()
    )
}

const SUBAGENT_ROUTING_PREFIX: &str = "fermin-subagent-routing:";
const PROMPT_VARIANT_PREFIX: &str = "fermin-prompt-variant:";

fn encode_subagent_routing(
    parent_session_id: &str,
    child_session_id: &str,
    upstream_trace_id: Option<&str>,
) -> String {
    format!(
        "{SUBAGENT_ROUTING_PREFIX}{}",
        json!({
            "parentSessionId": parent_session_id,
            "childSessionId": child_session_id,
            "upstreamTraceId": upstream_trace_id,
        })
    )
}

fn subagent_child_session_id(command: &CommandRecord) -> Option<String> {
    let routing = command
        .trace_id
        .as_deref()?
        .strip_prefix(SUBAGENT_ROUTING_PREFIX)?;
    serde_json::from_str::<Value>(routing)
        .ok()?
        .get("childSessionId")?
        .as_str()
        .filter(|value| !value.trim().is_empty())
        .map(str::to_owned)
}

fn encode_prompt_variant(
    variant: crate::api::PromptImproverVariant,
    upstream_trace_id: Option<&str>,
) -> String {
    format!(
        "{PROMPT_VARIANT_PREFIX}{}",
        json!({
            "variant": variant,
            "upstreamTraceId": upstream_trace_id,
        })
    )
}

fn prompt_variant_from_trace(trace_id: Option<&str>) -> Option<crate::api::PromptImproverVariant> {
    let metadata = trace_id?.strip_prefix(PROMPT_VARIANT_PREFIX)?;
    let value: Value = serde_json::from_str(metadata).ok()?;
    serde_json::from_value(value.get("variant")?.clone()).ok()
}

fn trace_contains_prefix(trace_id: Option<&str>, prefix: &str) -> bool {
    let Some(trace_id) = trace_id else {
        return false;
    };
    if trace_id.starts_with(prefix) {
        return true;
    }
    let Some(metadata) = trace_id.strip_prefix(PROMPT_VARIANT_PREFIX) else {
        return false;
    };
    let Ok(value) = serde_json::from_str::<Value>(metadata) else {
        return false;
    };
    value
        .get("upstreamTraceId")
        .and_then(Value::as_str)
        .is_some_and(|upstream| upstream.starts_with(prefix))
}

fn engine_data_root_for_config(config: &EngineConfig) -> PathBuf {
    let database_path = if config.database_path.is_absolute() {
        config.database_path.clone()
    } else {
        std::env::current_dir()
            .unwrap_or_else(|_| PathBuf::from("."))
            .join(&config.database_path)
    };
    database_path
        .parent()
        .unwrap_or_else(|| Path::new("."))
        .to_path_buf()
}

async fn load_prompt_preference(
    config: &EngineConfig,
) -> EngineResult<crate::api::PromptImproverPreferenceRecord> {
    let path = engine_data_root_for_config(config).join("prompt-improver-preference.json");
    match tokio::fs::read(&path).await {
        Ok(bytes) => {
            let mut preference: crate::api::PromptImproverPreferenceRecord =
                serde_json::from_slice(&bytes).map_err(|error| {
                    EngineError::Configuration(format!(
                        "invalid prompt preference {}: {error}",
                        path.display()
                    ))
                })?;
            preference.version = preference.version.max(1);
            Ok(preference)
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            Ok(crate::api::PromptImproverPreferenceRecord {
                version: 1,
                variant: crate::api::PromptImproverVariant::Standard,
                updated_at: None,
            })
        }
        Err(error) => Err(error.into()),
    }
}

fn validate_effective_model_response(
    response: &Value,
    expected_model: &str,
    expected_effort: &str,
) -> EngineResult<()> {
    let settings = RuntimeModelSettings {
        model: required_string(response, "model")?,
        model_provider: Some(required_string(response, "modelProvider")?),
        effort: required_string(response, "reasoningEffort")?,
    };
    validate_effective_model_settings(&settings, expected_model, expected_effort)
}

fn validate_effective_model_settings(
    settings: &RuntimeModelSettings,
    expected_model: &str,
    expected_effort: &str,
) -> EngineResult<()> {
    if settings.model != expected_model {
        return Err(EngineError::InvalidModel(format!(
            "App Server selected {} instead of {expected_model}",
            settings.model
        )));
    }
    let provider = settings
        .model_provider
        .as_deref()
        .unwrap_or("openai")
        .to_ascii_lowercase();
    if provider != "openai" && provider != "codex" {
        return Err(EngineError::InvalidModel(format!(
            "App Server selected unsupported provider {provider}"
        )));
    }
    if settings.effort != expected_effort {
        return Err(EngineError::InvalidModel(format!(
            "App Server selected effort {} instead of {expected_effort}",
            settings.effort
        )));
    }
    Ok(())
}

fn parse_thread_settings_notification(
    params: &Value,
) -> EngineResult<(String, RuntimeModelSettings)> {
    let thread_id = required_string(params, "threadId")?;
    let thread_settings = params.get("threadSettings").ok_or_else(|| {
        EngineError::InvalidResponse("thread/settings/updated omitted threadSettings".to_owned())
    })?;
    Ok((
        thread_id,
        RuntimeModelSettings {
            model: required_string(thread_settings, "model")?,
            model_provider: Some(required_string(thread_settings, "modelProvider")?),
            effort: required_string(thread_settings, "effort")?,
        },
    ))
}

pub fn init_tracing() {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
    let _ = tracing_subscriber::fmt()
        .with_env_filter(filter)
        .json()
        .with_current_span(true)
        .try_init();
}

pub async fn run(config: EngineConfig) -> Result<()> {
    let bearer_token = crate::config::read_secret(&config.auth_token_file)
        .context("read Fermín mobile bearer token")?;
    let api_config = crate::api::MobileApiConfig::new(bearer_token)
        .context("configure Fermín mobile API")?
        .with_max_body_bytes(config.max_body_bytes)
        .context("configure Fermín mobile body limit")?
        .with_heartbeat_interval(config.heartbeat_interval())
        .context("configure Fermín mobile heartbeat")?;
    let listener = tokio::net::TcpListener::bind(config.bind)
        .await
        .with_context(|| format!("bind Fermín engine {}", config.bind))?;
    let state = Arc::new(
        EngineState::bootstrap(config.clone())
            .await
            .context("bootstrap Fermín engine")?,
    );
    info!(bind = %config.bind, "Fermín engine listening");
    let backend: Arc<dyn crate::api::MobileBackend> = state.clone();
    let shutdown_state = state.clone();
    let serve_result = axum::serve(listener, crate::api::router(backend, api_config))
        .with_graceful_shutdown(async move {
            tokio::select! {
                () = shutdown_signal() => {}
                () = shutdown_state.cancelled() => {}
            }
        })
        .await
        .context("serve Fermín engine");
    let shutdown_result = state.shutdown().await.context("shutdown Fermín engine");
    serve_result.and(shutdown_result)
}

pub async fn doctor(codex: PathBuf) -> Result<()> {
    if !codex.is_absolute() || !codex.exists() {
        bail!("Codex executable not found at {}", codex.display());
    }
    let version = probe_codex_version(&codex)
        .await
        .context("probe Codex version")?;
    let schema = probe_codex_schema(&codex)
        .await
        .context("probe Codex App Server schema")?;
    println!("codex={version}");
    println!("app_server_schema_sha256={}", schema.schema_hash);
    println!("schema_contract=compatible");
    println!("baseline_schema_match={}", schema.baseline_schema_match);
    println!(
        "native_goal_methods={}",
        schema.capabilities.supports_native_goals()
    );
    println!(
        "thread_settings_update={}",
        schema.capabilities.supports_thread_settings_update()
    );
    println!(
        "default_session_model={}",
        crate::config::DEFAULT_SESSION_MODEL
    );
    println!(
        "default_session_effort={}",
        crate::config::DEFAULT_SESSION_EFFORT
    );
    println!("required_test_model={}", crate::config::REQUIRED_TEST_MODEL);
    println!(
        "required_test_effort={}",
        crate::config::REQUIRED_TEST_EFFORT
    );
    Ok(())
}

async fn probe_codex_version(codex: &Path) -> EngineResult<String> {
    let output = tokio::process::Command::new(codex)
        .arg("--version")
        .output()
        .await?;
    if !output.status.success() {
        return Err(EngineError::Configuration(format!(
            "Codex version probe failed with {}",
            output.status
        )));
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

async fn probe_codex_schema(codex: &Path) -> EngineResult<RuntimeSchemaProbe> {
    const MAX_SCHEMA_BYTES: u64 = 32 * 1024 * 1024;

    let directory =
        std::env::temp_dir().join(format!("fermin-code-schema-{}", uuid::Uuid::now_v7()));
    tokio::fs::create_dir(&directory).await?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        tokio::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700)).await?;
    }

    let result = async {
        let mut child = tokio::process::Command::new(codex)
            .args([
                "app-server",
                "generate-json-schema",
                "--experimental",
                "--out",
            ])
            .arg(&directory)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .spawn()?;
        let status = match time::timeout(CODEX_SCHEMA_PROBE_TIMEOUT, child.wait()).await {
            Ok(status) => status?,
            Err(_) => {
                let _ = child.kill().await;
                let _ = child.wait().await;
                return Err(EngineError::Configuration(
                    "Codex App Server schema generation timed out".to_owned(),
                ));
            }
        };
        if !status.success() {
            return Err(EngineError::Configuration(format!(
                "Codex App Server schema generation failed with {status}"
            )));
        }

        let v2_path = directory.join("codex_app_server_protocol.v2.schemas.json");
        let client_request_path = directory.join("ClientRequest.json");
        for path in [&v2_path, &client_request_path] {
            let metadata = tokio::fs::metadata(path).await?;
            if !metadata.is_file() || metadata.len() > MAX_SCHEMA_BYTES {
                return Err(EngineError::Configuration(format!(
                    "generated App Server schema is missing or exceeds {MAX_SCHEMA_BYTES} bytes"
                )));
            }
        }

        let v2_bytes = tokio::fs::read(v2_path).await?;
        let client_request: Value =
            serde_json::from_slice(&tokio::fs::read(client_request_path).await?)?;
        validate_runtime_schema_contract(&v2_bytes, &client_request)
    }
    .await;

    let _ = tokio::fs::remove_dir_all(&directory).await;
    result
}

fn validate_runtime_schema_contract(
    v2_schema_bytes: &[u8],
    client_request: &Value,
) -> EngineResult<RuntimeSchemaProbe> {
    let v2_schema: Value = serde_json::from_slice(v2_schema_bytes)?;
    if !v2_schema.is_object() {
        return Err(EngineError::Configuration(
            "generated App Server v2 schema must be a JSON object".to_owned(),
        ));
    }

    let schema_hash = format!("{:x}", Sha256::digest(v2_schema_bytes));
    let baseline = runtime_manifest_schema_probe()?;
    let baseline_schema_match = schema_hash == baseline.schema_hash;
    if !baseline_schema_match {
        warn!(
            installed_schema_hash = %schema_hash,
            baseline_schema_hash = %baseline.schema_hash,
            "Codex App Server schema changed; validating the supported method contract"
        );
    }

    let mut methods = HashSet::new();
    collect_schema_methods(client_request, &mut methods);
    for required in runtime_manifest_methods("requiredMethods")? {
        if !methods.contains(&required) {
            return Err(EngineError::Configuration(format!(
                "installed App Server schema omits required method {required}"
            )));
        }
    }

    Ok(RuntimeSchemaProbe {
        schema_hash,
        capabilities: AppServerCapabilities::from_methods(methods),
        baseline_schema_match,
    })
}

fn collect_schema_methods(value: &Value, methods: &mut HashSet<String>) {
    match value {
        Value::Object(object) => {
            if let Some(method_schema) = object.get("method") {
                collect_method_values(method_schema, methods);
            }
            for child in object.values() {
                collect_schema_methods(child, methods);
            }
        }
        Value::Array(items) => {
            for item in items {
                collect_schema_methods(item, methods);
            }
        }
        _ => {}
    }
}

fn collect_method_values(value: &Value, methods: &mut HashSet<String>) {
    match value {
        Value::String(method) if method == "initialize" || method.contains('/') => {
            methods.insert(method.clone());
        }
        Value::Object(object) => {
            for child in object.values() {
                collect_method_values(child, methods);
            }
        }
        Value::Array(items) => {
            for item in items {
                collect_method_values(item, methods);
            }
        }
        _ => {}
    }
}

fn runtime_manifest_schema_probe() -> EngineResult<RuntimeSchemaProbe> {
    let manifest: Value = serde_json::from_str(include_str!("../schema/runtime-manifest.json"))?;
    let schema_hash = manifest
        .get("v2SchemaSha256")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| {
            EngineError::Configuration("runtime manifest omits v2SchemaSha256".to_owned())
        })?
        .to_owned();
    let mut methods = runtime_manifest_methods_from(&manifest, "requiredMethods")?;
    methods.extend(runtime_manifest_methods_from(&manifest, "optionalMethods")?);
    Ok(RuntimeSchemaProbe {
        schema_hash,
        capabilities: AppServerCapabilities::from_methods(methods),
        baseline_schema_match: true,
    })
}

fn runtime_manifest_methods(field: &str) -> EngineResult<Vec<String>> {
    let manifest: Value = serde_json::from_str(include_str!("../schema/runtime-manifest.json"))?;
    runtime_manifest_methods_from(&manifest, field)
}

fn runtime_manifest_methods_from(manifest: &Value, field: &str) -> EngineResult<Vec<String>> {
    manifest
        .get(field)
        .and_then(Value::as_array)
        .ok_or_else(|| EngineError::Configuration(format!("runtime manifest omits {field}")))?
        .iter()
        .map(|value| {
            value
                .as_str()
                .filter(|method| !method.is_empty())
                .map(str::to_owned)
                .ok_or_else(|| {
                    EngineError::Configuration(format!(
                        "runtime manifest {field} contains an invalid method"
                    ))
                })
        })
        .collect()
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

async fn hydrate_runtime_index(store: &Store) -> EngineResult<RuntimeIndex> {
    let mut index = RuntimeIndex::default();
    for stored in store.list_sessions().await? {
        if !stored.session.managed_by_fermin
            || stored.session.runtime_status.as_deref() == Some("ARCHIVED")
        {
            continue;
        }
        let session_id = stored.session.session_id;
        let thread_id = stored
            .session
            .provider_session_id
            .unwrap_or_else(|| session_id.clone());
        index.threads.insert(thread_id.clone(), session_id.clone());
        index.sessions.insert(
            session_id,
            RuntimeSession {
                thread_id,
                ..RuntimeSession::default()
            },
        );
    }
    Ok(index)
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct RecoveredWorkingSession {
    session_id: String,
    updated_at: Millis,
}

async fn normalize_recovered_session_statuses(
    store: &Store,
    lease: &LeaseRecord,
) -> EngineResult<Vec<RecoveredWorkingSession>> {
    let now = unix_millis()?;
    let mut recovered_working_sessions = Vec::new();
    for stored in store.list_sessions().await? {
        let mut summary = stored.session;
        if !summary.managed_by_fermin || summary.runtime_status.as_deref() == Some("ARCHIVED") {
            continue;
        }

        let changed = if summary.activity_status == ActivityStatus::Working
            || summary.runtime_status.as_deref() == Some("WORKING")
        {
            // The App Server subprocess does not preserve an in-flight turn,
            // but the user's durable intent does survive. Keep the session
            // visibly working and enqueue one idempotent continuation after
            // pending commands are recovered. Clearing it to WAITING here made
            // Desktop/Mobile report Ready while rollout recovery had not run.
            recovered_working_sessions.push(RecoveredWorkingSession {
                session_id: summary.session_id.clone(),
                updated_at: summary.updated_at,
            });
            false
        } else if summary.activity_status == ActivityStatus::Error
            && summary.runtime_status_detail.is_none()
        {
            summary.runtime_status_detail =
                latest_persisted_runtime_failure_detail(store, &summary.session_id).await?;
            summary.runtime_status_detail.is_some()
        } else {
            false
        };

        if changed {
            summary.updated_at = summary.updated_at.max(now);
            store
                .upsert_session(summary, Some(lease.fencing_token(now)))
                .await?;
        }
    }
    Ok(recovered_working_sessions)
}

async fn latest_persisted_runtime_failure_detail(
    store: &Store,
    session_id: &str,
) -> EngineResult<Option<String>> {
    let mut after = 0;
    let mut latest = None;
    loop {
        let page = store
            .replay_session_events(session_id.to_owned(), after, EVENT_REPLAY_PAGE)
            .await?;
        let Some(last) = page.last() else {
            return Ok(latest);
        };
        for event in &page {
            if event.kind == EventKind::Error {
                let detail = runtime_failure_detail(&event.payload)
                    .or_else(|| event.payload.get("params").and_then(runtime_failure_detail));
                if detail.is_some() {
                    latest = detail;
                }
            }
        }
        after = last.session_sequence.unwrap_or(after);
        if page.len() < EVENT_REPLAY_PAGE {
            return Ok(latest);
        }
    }
}

async fn load_last_global_sequence(store: &Store) -> EngineResult<u64> {
    let mut after = 0;
    loop {
        let page = store
            .replay_events(
                EventCursor {
                    after_global_sequence: after,
                },
                EVENT_REPLAY_PAGE,
            )
            .await?;
        let Some(last) = page.last() else {
            return Ok(after);
        };
        after = last.global_sequence;
        if page.len() < EVENT_REPLAY_PAGE {
            return Ok(after);
        }
    }
}

async fn probe_live_models(appserver: &dyn EngineTransport) -> EngineResult<Value> {
    let mut models = Vec::new();
    let mut cursor: Option<String> = None;
    let mut seen_cursors = HashSet::new();
    loop {
        let mut params = json!({ "includeHidden": false, "limit": 100 });
        if let Some(cursor) = cursor.as_deref() {
            params["cursor"] = Value::String(cursor.to_owned());
        }
        let response = appserver.request("model/list".to_owned(), params).await?;
        let page = response
            .get("data")
            .and_then(Value::as_array)
            .ok_or_else(|| EngineError::InvalidResponse("model/list omitted data".to_owned()))?;
        models.extend(page.iter().cloned());
        let next = response
            .get("nextCursor")
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty())
            .map(str::to_owned);
        let Some(next) = next else {
            break;
        };
        if !seen_cursors.insert(next.clone()) {
            return Err(EngineError::InvalidResponse(
                "model/list repeated a pagination cursor".to_owned(),
            ));
        }
        cursor = Some(next);
        if seen_cursors.len() >= 1_000 {
            return Err(EngineError::InvalidResponse(
                "model/list exceeded 1000 pages".to_owned(),
            ));
        }
    }
    Ok(json!({ "data": models }))
}

fn parse_model_catalog(
    response: &Value,
    observed_at: i64,
    app_server_version: &str,
    capability_hash: &str,
) -> EngineResult<ModelCatalog> {
    let raw_models = response
        .get("data")
        .and_then(Value::as_array)
        .ok_or_else(|| EngineError::InvalidResponse("model/list omitted data".to_owned()))?;
    let mut models = Vec::new();
    for raw in raw_models {
        let id = raw.get("id").and_then(Value::as_str).unwrap_or_default();
        let model = raw.get("model").and_then(Value::as_str).unwrap_or(id);
        let efforts = raw
            .get("supportedReasoningEfforts")
            .and_then(Value::as_array)
            .map(|values| {
                values
                    .iter()
                    .filter_map(|value| {
                        let reasoning_effort = value
                            .get("reasoningEffort")
                            .and_then(Value::as_str)?
                            .to_owned();
                        Some(ReasoningEffortOption {
                            reasoning_effort,
                            description: value
                                .get("description")
                                .and_then(Value::as_str)
                                .map(str::to_owned),
                        })
                    })
                    .collect()
            })
            .unwrap_or_default();
        let candidate = ModelInfo {
            id: id.to_owned(),
            model: model.to_owned(),
            model_provider: Some(
                raw.get("modelProvider")
                    .and_then(Value::as_str)
                    .unwrap_or("openai")
                    .to_owned(),
            ),
            display_name: raw
                .get("displayName")
                .and_then(Value::as_str)
                .unwrap_or(model)
                .to_owned(),
            default_reasoning_effort: raw
                .get("defaultReasoningEffort")
                .and_then(Value::as_str)
                .unwrap_or("medium")
                .to_owned(),
            supported_reasoning_efforts: efforts,
            hidden: raw.get("hidden").and_then(Value::as_bool).unwrap_or(false),
            is_default: raw
                .get("isDefault")
                .and_then(Value::as_bool)
                .unwrap_or(false),
        };
        if candidate.is_product_supported() {
            models.push(candidate);
        }
    }
    if models.is_empty() {
        return Err(EngineError::InvalidResponse(
            "model/list contained no visible OpenAI GPT models".to_owned(),
        ));
    }
    Ok(ModelCatalog {
        observed_at,
        app_server_version: Some(app_server_version.to_owned()),
        capability_hash: Some(capability_hash.to_owned()),
        models,
    })
}

fn validate_default_model(config: &EngineConfig, catalog: &ModelCatalog) -> EngineResult<()> {
    let Some(model) = catalog
        .models
        .iter()
        .find(|model| model.model == config.default_model)
    else {
        return Err(EngineError::InvalidModel(format!(
            "configured default model {} is not in model/list",
            config.default_model
        )));
    };
    if !model
        .supported_reasoning_efforts
        .iter()
        .any(|effort| effort.reasoning_effort == config.default_effort)
    {
        return Err(EngineError::InvalidModel(format!(
            "configured default effort {} is unavailable for {}",
            config.default_effort, config.default_model
        )));
    }
    Ok(())
}

fn summary_from_thread(
    thread: &Value,
    session_id: &str,
    fallback_now: i64,
) -> EngineResult<SessionSummary> {
    let thread_id = required_string(thread, "id")?;
    let cwd = thread
        .get("cwd")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let project_path = (!cwd.is_empty()).then(|| cwd.to_owned());
    let project_name = Path::new(cwd)
        .file_name()
        .and_then(|value| value.to_str())
        .filter(|value| !value.is_empty())
        .unwrap_or("Codex")
        .to_owned();
    let display_name = thread
        .get("name")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .or_else(|| {
            thread
                .get("preview")
                .and_then(Value::as_str)
                .filter(|value| !value.trim().is_empty())
        })
        .unwrap_or(&project_name)
        .to_owned();
    let created_at =
        seconds_to_millis(thread.get("createdAt").and_then(Value::as_i64)).unwrap_or(fallback_now);
    let updated_at =
        seconds_to_millis(thread.get("updatedAt").and_then(Value::as_i64)).unwrap_or(fallback_now);
    let status = thread
        .pointer("/status/type")
        .and_then(Value::as_str)
        .unwrap_or("idle");
    let activity_status = match status {
        "active" => ActivityStatus::Working,
        "systemError" => ActivityStatus::Error,
        _ => ActivityStatus::Ready,
    };
    let mut summary = SessionSummary::new(
        session_id,
        project_path.clone().unwrap_or_else(|| project_name.clone()),
        display_name,
        created_at,
    );
    summary.provider_session_id = Some(thread_id);
    summary.provider_session_path = thread
        .get("path")
        .and_then(Value::as_str)
        .map(str::to_owned);
    summary.project_path = project_path;
    summary.project_name = Some(project_name);
    summary.window_name = thread
        .get("name")
        .and_then(Value::as_str)
        .map(str::to_owned);
    summary.activity_status = activity_status;
    summary.runtime_status = Some(
        if activity_status == ActivityStatus::Working {
            "WORKING"
        } else {
            "WAITING"
        }
        .to_owned(),
    );
    summary.runtime_status_detail = if activity_status == ActivityStatus::Error {
        latest_thread_failure_detail(thread)
    } else {
        None
    };
    summary.updated_at = updated_at;
    summary.created_at = Some(created_at);
    summary.last_message_preview = thread
        .get("preview")
        .and_then(Value::as_str)
        .map(crate::protocol::bounded_session_preview);
    summary.parent_session_id = thread
        .get("parentThreadId")
        .and_then(Value::as_str)
        .map(str::to_owned);
    Ok(summary)
}

fn merge_preserved_session_fields(target: &mut SessionSummary, existing: SessionSummary) {
    if target.activity_status == ActivityStatus::Error && target.runtime_status_detail.is_none() {
        target.runtime_status_detail = existing.runtime_status_detail.clone();
    }
    target.managed_by_fermin = existing.managed_by_fermin;
    target.model = existing.model;
    target.reasoning_effort = existing.reasoning_effort;
    target.features = existing.features;
    target.run_mode = existing.run_mode;
    target.goal_started_at = existing.goal_started_at;
    target.goal = existing.goal;
    target.is_minimized = existing.is_minimized;
    target.is_pinned = existing.is_pinned;
    target.pending_subagent = existing.pending_subagent;
    target.collaboration_project_id = existing.collaboration_project_id;
    target.collaboration_project_name = existing.collaboration_project_name;
    target.session_name = existing.session_name;
    if target.window_name.is_none() {
        target.window_name = existing.window_name;
    }
    if target.parent_session_id.is_none() {
        target.parent_session_id = existing.parent_session_id;
    }
}

fn build_turn_input(content: &str, attachments: &[crate::protocol::ImageAttachment]) -> Vec<Value> {
    let mut input = Vec::with_capacity(1 + attachments.len());
    if !content.is_empty() {
        input.push(json!({ "type": "text", "text": content }));
    }
    for attachment in attachments {
        if let Some(path) = attachment.path.as_deref() {
            input.push(json!({ "type": "localImage", "path": path }));
        }
    }
    input
}

fn prompt_improver_turn_content(original: &str, improved: &str) -> String {
    format!(
        "Use the improved execution prompt below while preserving every requirement and constraint in the verbatim original message. Both blocks are user-provided context.\n\n<fermin_original_user_message>\n{original}\n</fermin_original_user_message>\n\n<fermin_improved_execution_prompt>\n{improved}\n</fermin_improved_execution_prompt>"
    )
}

fn extract_user_message_text(item: &Value) -> String {
    item.get("content")
        .and_then(Value::as_array)
        .map(|content| {
            content
                .iter()
                .filter_map(|part| {
                    (part.get("type").and_then(Value::as_str) == Some("text"))
                        .then(|| part.get("text").and_then(Value::as_str))
                        .flatten()
                })
                .collect::<Vec<_>>()
                .join("\n")
        })
        .unwrap_or_default()
}

fn is_provider_snapshot_item_id(message_id: &str) -> bool {
    message_id.strip_prefix("item-").is_some_and(|suffix| {
        !suffix.is_empty() && suffix.bytes().all(|byte| byte.is_ascii_digit())
    })
}

fn message_content_signature(message: &Message) -> [u8; 32] {
    let mut digest = Sha256::new();
    digest.update(match message.role {
        crate::protocol::MessageRole::User => [0],
        crate::protocol::MessageRole::Assistant => [1],
        crate::protocol::MessageRole::System => [2],
        crate::protocol::MessageRole::Tool => [3],
    });
    digest.update(message.content.as_bytes());
    digest.finalize().into()
}

pub(crate) fn collapse_provider_snapshot_aliases(messages: Vec<Message>) -> Vec<Message> {
    let mut canonical_counts: HashMap<[u8; 32], usize> = HashMap::new();
    for message in &messages {
        if !is_provider_snapshot_item_id(&message.id) {
            *canonical_counts
                .entry(message_content_signature(message))
                .or_default() += 1;
        }
    }

    messages
        .into_iter()
        .filter(|message| {
            if !is_provider_snapshot_item_id(&message.id) {
                return true;
            }
            let Some(remaining) = canonical_counts.get_mut(&message_content_signature(message))
            else {
                return true;
            };
            if *remaining == 0 {
                return true;
            }
            *remaining -= 1;
            false
        })
        .collect()
}

fn latest_thread_failure_detail(thread: &Value) -> Option<String> {
    thread
        .get("turns")
        .and_then(Value::as_array)?
        .iter()
        .rev()
        .find(|turn| turn.get("status").and_then(Value::as_str) == Some("failed"))
        .and_then(runtime_failure_detail)
}

fn runtime_failure_detail(value: &Value) -> Option<String> {
    let error = value
        .pointer("/turn/error")
        .or_else(|| value.get("error"))?;
    let code = error
        .get("codexErrorInfo")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if code == "cyberPolicy" {
        return Some(
            "Codex bloqueó este hilo por una política de seguridad. El mensaje llegó correctamente a Fermín, pero no fue procesado. Para continuar, creá una sesión nueva y reformulá el objetivo con un alcance claramente autorizado."
                .to_owned(),
        );
    }

    let message = error.get("message").and_then(Value::as_str)?.trim();
    if message.is_empty() {
        return None;
    }
    let mut bounded = message
        .chars()
        .take(RUNTIME_ERROR_DETAIL_MAX_CHARS)
        .collect::<String>();
    if message.chars().count() > RUNTIME_ERROR_DETAIL_MAX_CHARS {
        bounded.push('…');
    }
    Some(format!("Codex no pudo completar el turno: {bounded}"))
}

fn prompt_improver_dossier(
    messages: Vec<Message>,
    current_message_id: &str,
) -> Result<String, serde_json::Error> {
    let mut newest_first = Vec::new();
    let mut encoded_bytes = 2usize; // JSON array brackets.
    for message in collapse_provider_snapshot_aliases(messages)
        .into_iter()
        .rev()
    {
        if message.id == current_message_id
            || !matches!(
                message.role,
                crate::protocol::MessageRole::User | crate::protocol::MessageRole::Assistant
            )
        {
            continue;
        }
        let content = bounded_prompt_context_content(
            &message.content,
            PROMPT_IMPROVER_CONTEXT_MESSAGE_MAX_BYTES,
        );
        if content.trim().is_empty() {
            continue;
        }
        let entry = json!({
            "id": message.id,
            "role": message.role,
            "type": message.message_type,
            "content": content,
            "timestamp": message.timestamp,
        });
        let entry_bytes = serde_json::to_vec(&entry)?.len();
        let delimiter_bytes = usize::from(!newest_first.is_empty());
        if encoded_bytes
            .saturating_add(delimiter_bytes)
            .saturating_add(entry_bytes)
            > PROMPT_IMPROVER_CONTEXT_MAX_BYTES
        {
            break;
        }
        encoded_bytes += delimiter_bytes + entry_bytes;
        newest_first.push(entry);
        if newest_first.len() == PROMPT_IMPROVER_CONTEXT_MAX_MESSAGES {
            break;
        }
    }
    newest_first.reverse();
    serde_json::to_string(&newest_first)
}

fn bounded_prompt_context_content(value: &str, max_bytes: usize) -> String {
    if value.len() <= max_bytes {
        return value.to_owned();
    }
    const MARKER: &str = "\n\n[... contenido intermedio omitido por límite de contexto ...]\n\n";
    let available = max_bytes.saturating_sub(MARKER.len());
    let head_budget = available * 2 / 5;
    let tail_budget = available - head_budget;
    let mut head_end = head_budget.min(value.len());
    while !value.is_char_boundary(head_end) {
        head_end -= 1;
    }
    let mut tail_start = value.len().saturating_sub(tail_budget);
    while tail_start < value.len() && !value.is_char_boundary(tail_start) {
        tail_start += 1;
    }
    format!("{}{}{}", &value[..head_end], MARKER, &value[tail_start..])
}

fn bounded_item_notification_params(params: Value) -> EngineResult<Value> {
    let original_bytes = serde_json::to_vec(&params)?.len();
    if original_bytes <= MAX_PERSISTED_ITEM_NOTIFICATION_BYTES {
        return Ok(params);
    }

    let mut compact = serde_json::Map::new();
    for key in ["threadId", "turnId", "startedAtMs", "completedAtMs"] {
        if let Some(value) = params.get(key).and_then(bounded_item_metadata_value) {
            compact.insert(key.to_owned(), value);
        }
    }

    let mut compact_item = serde_json::Map::new();
    if let Some(item) = params.get("item").and_then(Value::as_object) {
        for key in [
            "id",
            "type",
            "status",
            "name",
            "title",
            "displayName",
            "command",
            "cwd",
            "exitCode",
            "durationMs",
            "server",
            "tool",
            "agentId",
            "senderThreadId",
            "receiverThreadIds",
            "parentThreadId",
            "phase",
        ] {
            if let Some(value) = item.get(key).and_then(bounded_item_metadata_value) {
                compact_item.insert(key.to_owned(), value);
            }
        }
    }
    compact_item.insert("ferminPayloadOmitted".to_owned(), Value::Bool(true));
    compact_item.insert(
        "ferminOriginalBytes".to_owned(),
        Value::from(u64::try_from(original_bytes).unwrap_or(u64::MAX)),
    );
    compact.insert("item".to_owned(), Value::Object(compact_item));
    Ok(Value::Object(compact))
}

fn should_drop_derived_appserver_notification(method: &str) -> bool {
    matches!(
        method,
        "turn/diff/updated"
            | "thread/tokenUsage/updated"
            | "mcpServer/startupStatus/updated"
            | "model/safetyBuffering/updated"
    )
}

fn bounded_normalized_notification_params(params: Value) -> EngineResult<Value> {
    let original_bytes = serde_json::to_vec(&params)?.len();
    if original_bytes <= MAX_PERSISTED_NORMALIZED_NOTIFICATION_BYTES {
        return Ok(params);
    }

    let mut compact = serde_json::Map::new();
    for key in [
        "threadId", "turnId", "status", "error", "warning", "message",
    ] {
        if let Some(value) = params.get(key).and_then(bounded_item_metadata_value) {
            compact.insert(key.to_owned(), value);
        }
    }
    compact.insert("ferminPayloadOmitted".to_owned(), Value::Bool(true));
    compact.insert(
        "ferminOriginalBytes".to_owned(),
        Value::from(u64::try_from(original_bytes).unwrap_or(u64::MAX)),
    );
    Ok(Value::Object(compact))
}

fn bounded_item_metadata_value(value: &Value) -> Option<Value> {
    match value {
        Value::String(text) => Some(Value::String(bounded_prompt_context_content(
            text,
            MAX_PERSISTED_ITEM_METADATA_BYTES,
        ))),
        Value::Null | Value::Bool(_) | Value::Number(_) => Some(value.clone()),
        Value::Array(_) | Value::Object(_) => (serde_json::to_vec(value).ok()?.len()
            <= MAX_PERSISTED_ITEM_METADATA_BYTES)
            .then(|| value.clone()),
    }
}

fn validate_command_request(request: &CommandRequest) -> EngineResult<()> {
    if request.idempotency_key.trim().is_empty() {
        return Err(EngineError::UnsupportedCommand(
            "idempotencyKey must not be empty".to_owned(),
        ));
    }
    if let CommandKind::SendMessage {
        service_tier: Some(service_tier),
        ..
    } = &request.command
        && service_tier != "fast"
    {
        return Err(EngineError::UnsupportedCommand(
            "unsupported App Server service tier".to_owned(),
        ));
    }
    if let CommandKind::SetRunMode {
        run_mode: RunMode::Goal,
        objective: Some(objective),
    } = &request.command
        && objective.chars().count() > MAX_NATIVE_GOAL_OBJECTIVE_CHARS
    {
        return Err(EngineError::UnsupportedCommand(format!(
            "native goal objective exceeds {MAX_NATIVE_GOAL_OBJECTIVE_CHARS} characters"
        )));
    }
    match &request.command {
        CommandKind::CreateSession { .. } => Ok(()),
        _ if request
            .session_id
            .as_deref()
            .unwrap_or_default()
            .trim()
            .is_empty() =>
        {
            Err(EngineError::UnsupportedCommand(
                "sessionId is required for this command".to_owned(),
            ))
        }
        _ => Ok(()),
    }
}

fn required_session_id(command: &CommandRecord) -> EngineResult<&str> {
    command
        .session_id
        .as_deref()
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| EngineError::UnsupportedCommand("sessionId is required".to_owned()))
}

fn command_lane_key(command: &CommandRecord) -> String {
    command
        .session_id
        .clone()
        .unwrap_or_else(|| format!("create:{}", command.command_id))
}

fn command_has_external_side_effects(command: &CommandRecord) -> bool {
    match &command.command {
        CommandKind::SetMinimized { .. } => command
            .trace_id
            .as_deref()
            .is_some_and(|trace| trace.starts_with(RESUME_HISTORY_TRACE_PREFIX)),
        CommandKind::SetPinned { .. }
        | CommandKind::SetFeatures { .. }
        | CommandKind::SetRunMode { .. }
        | CommandKind::RespondApproval { .. }
        | CommandKind::RespondUserInput { .. } => false,
        _ => true,
    }
}

fn required_string(value: &Value, field: &str) -> EngineResult<String> {
    value
        .get(field)
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
        .ok_or_else(|| EngineError::InvalidResponse(format!("missing {field}")))
}

fn parse_native_goal(value: &Value, expected_thread_id: &str) -> EngineResult<GoalState> {
    let thread_id = required_string(value, "threadId")?;
    if thread_id != expected_thread_id {
        return Err(EngineError::InvalidResponse(
            "native goal belongs to a different thread".to_owned(),
        ));
    }
    let objective = required_string(value, "objective")?;
    let status = required_string(value, "status")?;
    if !matches!(
        status.as_str(),
        "active" | "paused" | "blocked" | "usageLimited" | "budgetLimited" | "complete"
    ) {
        return Err(EngineError::InvalidResponse(
            "native goal returned an unknown status".to_owned(),
        ));
    }
    let token_budget = match value.get("tokenBudget") {
        Some(Value::Null) | None => None,
        Some(value) => Some(value.as_u64().ok_or_else(|| {
            EngineError::InvalidResponse("native goal tokenBudget is invalid".to_owned())
        })?),
    };
    let tokens_used = value
        .get("tokensUsed")
        .and_then(Value::as_u64)
        .ok_or_else(|| {
            EngineError::InvalidResponse("native goal tokensUsed is invalid".to_owned())
        })?;
    let time_used_seconds = value
        .get("timeUsedSeconds")
        .and_then(Value::as_u64)
        .ok_or_else(|| {
            EngineError::InvalidResponse("native goal timeUsedSeconds is invalid".to_owned())
        })?;
    let created_at =
        seconds_to_millis(value.get("createdAt").and_then(Value::as_i64)).ok_or_else(|| {
            EngineError::InvalidResponse("native goal createdAt is invalid".to_owned())
        })?;
    let updated_at =
        seconds_to_millis(value.get("updatedAt").and_then(Value::as_i64)).ok_or_else(|| {
            EngineError::InvalidResponse("native goal updatedAt is invalid".to_owned())
        })?;
    Ok(GoalState {
        objective,
        status,
        token_budget,
        tokens_used,
        time_used_seconds,
        created_at,
        updated_at,
    })
}

fn seconds_to_millis(seconds: Option<i64>) -> Option<i64> {
    seconds.and_then(|value| value.checked_mul(1_000))
}

fn hash_json(value: &Value) -> EngineResult<String> {
    let bytes = serde_json::to_vec(value)?;
    Ok(format!("{:x}", Sha256::digest(bytes)))
}

fn unix_millis() -> EngineResult<i64> {
    let duration = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|error| EngineError::Configuration(format!("system clock error: {error}")))?;
    i64::try_from(duration.as_millis())
        .map_err(|_| EngineError::Configuration("system clock overflow".to_owned()))
}

fn is_recoverable_steer_race(error: &EngineError) -> bool {
    let EngineError::AppServer(AppServerError::Rpc {
        method,
        code,
        message,
        ..
    }) = error
    else {
        return false;
    };
    if method != "turn/steer" || *code != -32600 {
        return false;
    }
    let message = message.to_ascii_lowercase();
    message.contains("no active turn")
        || message.contains("expectedturnid")
        || message.contains("expected turn id")
        || message.contains("expected active turn")
}

fn is_missing_provider_rollout(error: &EngineError, expected_method: &str) -> bool {
    let EngineError::AppServer(AppServerError::Rpc {
        method,
        code,
        message,
        ..
    }) = error
    else {
        return false;
    };
    if method != expected_method || *code != -32600 {
        return false;
    }
    let message = message.trim().to_ascii_lowercase();
    message.starts_with("no rollout found for thread id ")
        || (expected_method == "thread/unarchive"
            && message.starts_with("no archived rollout found for thread id "))
}

fn redacted_error(error: &EngineError) -> String {
    match error {
        EngineError::AppServer(AppServerError::Rpc { method, code, .. }) => {
            format!("App Server RPC {method} failed with code {code}")
        }
        EngineError::AppServer(AppServerError::Overloaded { method, .. }) => {
            format!("App Server remained overloaded during {method}")
        }
        EngineError::SessionNotFound(session) => format!("session {session} was not found"),
        EngineError::NoActiveTurn(session) => format!("session {session} has no active turn"),
        EngineError::InvalidModel(message)
        | EngineError::UnsupportedCommand(message)
        | EngineError::Configuration(message)
        | EngineError::InvalidResponse(message)
        | EngineError::PathOutsideWorkspace(message) => message.clone(),
        EngineError::ObserverUnavailable => "observer workflow unavailable".to_owned(),
        EngineError::Feature(error) => {
            format!("observer workflow failed ({})", feature_error_reason(error))
        }
        EngineError::CommandLaneClosed(_) | EngineError::ShuttingDown => error.to_string(),
        EngineError::Store(_) | EngineError::Json(_) | EngineError::Io(_) => {
            "internal durable engine error".to_owned()
        }
        EngineError::AppServer(_) => "App Server transport failed".to_owned(),
    }
}

fn feature_error_reason(error: &FeatureError) -> &'static str {
    match error {
        FeatureError::Timeout { workflow, .. } => match workflow {
            crate::features::WorkflowKind::PromptImprover => "prompt_improver_timeout",
            crate::features::WorkflowKind::PromptFidelityAudit => "prompt_fidelity_timeout",
            crate::features::WorkflowKind::Explainer => "explainer_timeout",
        },
        FeatureError::AppServer(_) => "transport",
        FeatureError::InvalidOutput { .. } => "invalid_output",
        FeatureError::MissingInput { .. }
        | FeatureError::InputTooLarge { .. }
        | FeatureError::InvalidContext(_) => "invalid_input",
        FeatureError::PolicyViolation(_) => "policy",
        FeatureError::Serialization(_) => "serialization",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::MessagePatch;
    use std::collections::BTreeSet;
    use std::sync::atomic::AtomicUsize;

    use tempfile::TempDir;

    #[test]
    fn improved_turn_contains_exact_original_then_improved_prompt() {
        let original = "Keep this exact requirement: do not deploy yet.";
        let improved = "Implement the fix, verify it, and do not deploy.";

        let content = prompt_improver_turn_content(original, improved);

        assert!(content.contains(&format!(
            "<fermin_original_user_message>\n{original}\n</fermin_original_user_message>"
        )));
        assert!(content.contains(&format!(
            "<fermin_improved_execution_prompt>\n{improved}\n</fermin_improved_execution_prompt>"
        )));
        assert!(content.find(original).unwrap() < content.find(improved).unwrap());
    }

    #[test]
    fn observer_timeout_reason_preserves_the_failed_phase() {
        assert_eq!(
            feature_error_reason(&FeatureError::Timeout {
                workflow: crate::features::WorkflowKind::PromptImprover,
                timeout_ms: 360_000,
            }),
            "prompt_improver_timeout"
        );
        assert_eq!(
            feature_error_reason(&FeatureError::Timeout {
                workflow: crate::features::WorkflowKind::PromptFidelityAudit,
                timeout_ms: 360_000,
            }),
            "prompt_fidelity_timeout"
        );
    }

    #[test]
    fn thread_lifecycle_requests_allow_slow_app_server_startup() {
        for method in ["thread/start", "thread/resume", "thread/read"] {
            assert_eq!(
                appserver_request_timeout(method),
                APP_SERVER_THREAD_REQUEST_TIMEOUT
            );
        }
        assert_eq!(
            appserver_request_timeout("turn/start"),
            APP_SERVER_REQUEST_TIMEOUT
        );
    }

    #[test]
    fn failed_thread_snapshot_recovers_a_clear_provider_policy_diagnostic() {
        let summary = summary_from_thread(
            &json!({
                "id": "thread-policy",
                "cwd": "/tmp/project",
                "name": "homepod",
                "status": { "type": "systemError" },
                "turns": [{
                    "id": "turn-policy",
                    "status": "failed",
                    "error": {
                        "codexErrorInfo": "cyberPolicy",
                        "message": "raw provider policy text"
                    },
                    "items": []
                }]
            }),
            "session-policy",
            123,
        )
        .unwrap();

        assert_eq!(summary.activity_status, ActivityStatus::Error);
        assert_eq!(
            summary.runtime_status_detail.as_deref(),
            Some(
                "Codex bloqueó este hilo por una política de seguridad. El mensaje llegó correctamente a Fermín, pero no fue procesado. Para continuar, creá una sesión nueva y reformulá el objetivo con un alcance claramente autorizado."
            )
        );
    }

    #[tokio::test]
    async fn non_retryable_provider_error_stays_visible_until_a_new_turn_starts() {
        let (directory, state, transport) = test_engine().await;
        create_session(&state, &directory, "provider-error", "homepod").await;
        let thread_id = state
            .session("provider-error")
            .await
            .unwrap()
            .unwrap()
            .provider_session_id
            .unwrap();

        state
            .reduce_notification(
                transport.epoch(),
                "turn/started",
                json!({
                    "threadId": thread_id,
                    "turn": { "id": "turn-policy" }
                }),
            )
            .await
            .unwrap();
        state
            .reduce_notification(
                transport.epoch(),
                "thread/status/changed",
                json!({
                    "threadId": thread_id,
                    "status": { "type": "systemError" }
                }),
            )
            .await
            .unwrap();
        state
            .reduce_notification(
                transport.epoch(),
                "error",
                json!({
                    "threadId": thread_id,
                    "turnId": "turn-policy",
                    "willRetry": false,
                    "error": {
                        "codexErrorInfo": "cyberPolicy",
                        "message": "raw provider policy text"
                    }
                }),
            )
            .await
            .unwrap();
        state
            .reduce_notification(
                transport.epoch(),
                "turn/completed",
                json!({
                    "threadId": thread_id,
                    "turn": {
                        "id": "turn-policy",
                        "status": "failed",
                        "error": {
                            "codexErrorInfo": "cyberPolicy",
                            "message": "raw provider policy text"
                        }
                    }
                }),
            )
            .await
            .unwrap();

        let failed = state.session("provider-error").await.unwrap().unwrap();
        assert_eq!(failed.activity_status, ActivityStatus::Error);
        assert_eq!(failed.runtime_status.as_deref(), Some("WAITING"));
        assert!(
            failed
                .runtime_status_detail
                .as_deref()
                .is_some_and(|detail| detail.contains("El mensaje llegó correctamente a Fermín"))
        );

        state
            .reduce_notification(
                transport.epoch(),
                "turn/started",
                json!({
                    "threadId": thread_id,
                    "turn": { "id": "turn-recovered" }
                }),
            )
            .await
            .unwrap();
        let recovered = state.session("provider-error").await.unwrap().unwrap();
        assert_eq!(recovered.activity_status, ActivityStatus::Working);
        assert_eq!(recovered.runtime_status_detail, None);
        state.shutdown().await.unwrap();
    }

    #[test]
    fn oversized_item_notifications_keep_metadata_without_persisting_tool_output() {
        let private_marker = "oversized-private-tool-output";
        let params = json!({
            "threadId": "thread-1",
            "turnId": "turn-1",
            "completedAtMs": 1234,
            "item": {
                "id": "exec-1",
                "type": "commandExecution",
                "status": "completed",
                "command": "x".repeat(MAX_PERSISTED_ITEM_METADATA_BYTES * 2),
                "cwd": "/tmp/project",
                "exitCode": 0,
                "aggregatedOutput": format!(
                    "{private_marker}{}",
                    "z".repeat(MAX_PERSISTED_ITEM_NOTIFICATION_BYTES)
                ),
            }
        });
        let original_bytes = serde_json::to_vec(&params).unwrap().len();
        assert!(original_bytes > MAX_PERSISTED_ITEM_NOTIFICATION_BYTES);

        let bounded = bounded_item_notification_params(params).unwrap();
        let encoded = serde_json::to_vec(&bounded).unwrap();
        assert!(encoded.len() < MAX_PERSISTED_ITEM_NOTIFICATION_BYTES);
        assert_eq!(bounded.pointer("/item/id"), Some(&json!("exec-1")));
        assert_eq!(
            bounded.pointer("/item/type"),
            Some(&json!("commandExecution"))
        );
        assert_eq!(
            bounded.pointer("/item/ferminPayloadOmitted"),
            Some(&Value::Bool(true))
        );
        assert_eq!(
            bounded
                .pointer("/item/ferminOriginalBytes")
                .and_then(Value::as_u64),
            Some(original_bytes as u64)
        );
        assert!(
            bounded
                .pointer("/item/command")
                .and_then(Value::as_str)
                .is_some_and(|command| command.len() <= MAX_PERSISTED_ITEM_METADATA_BYTES)
        );
        assert!(bounded.pointer("/item/aggregatedOutput").is_none());
        assert!(!String::from_utf8(encoded).unwrap().contains(private_marker));
    }

    #[test]
    fn derived_high_volume_notifications_are_not_durable_fermin_events() {
        for method in [
            "turn/diff/updated",
            "thread/tokenUsage/updated",
            "mcpServer/startupStatus/updated",
            "model/safetyBuffering/updated",
        ] {
            assert!(should_drop_derived_appserver_notification(method));
        }
        assert!(!should_drop_derived_appserver_notification(
            "turn/completed"
        ));
        assert!(!should_drop_derived_appserver_notification(
            "item/completed"
        ));
    }

    #[test]
    fn oversized_normalized_notifications_keep_only_bounded_routing_metadata() {
        let private_marker = "oversized-derived-payload";
        let params = json!({
            "threadId": "thread-1",
            "turnId": "turn-1",
            "diff": format!(
                "{private_marker}{}",
                "x".repeat(MAX_PERSISTED_NORMALIZED_NOTIFICATION_BYTES)
            ),
        });
        let original_bytes = serde_json::to_vec(&params).unwrap().len();

        let bounded = bounded_normalized_notification_params(params).unwrap();
        let encoded = serde_json::to_vec(&bounded).unwrap();
        assert!(encoded.len() < MAX_PERSISTED_NORMALIZED_NOTIFICATION_BYTES);
        assert_eq!(bounded.get("threadId"), Some(&json!("thread-1")));
        assert_eq!(bounded.get("turnId"), Some(&json!("turn-1")));
        assert_eq!(
            bounded.get("ferminPayloadOmitted"),
            Some(&Value::Bool(true))
        );
        assert_eq!(
            bounded.get("ferminOriginalBytes").and_then(Value::as_u64),
            Some(original_bytes as u64)
        );
        assert!(bounded.get("diff").is_none());
        assert!(!String::from_utf8(encoded).unwrap().contains(private_marker));
    }

    #[test]
    fn provider_snapshot_aliases_are_collapsed_without_losing_real_repetitions() {
        let messages = vec![
            Message::user("mobile-a", "repeat", 1),
            Message::user("mobile-b", "repeat", 2),
            Message::user("item-1", "repeat", 3),
            Message::user("item-2", "repeat", 4),
            Message::assistant("msg-a", "reply", 5),
            Message::assistant("item-3", "reply", 6),
            Message::assistant("item-4", "provider only", 7),
            Message::assistant("item-not-numeric", "keep this", 8),
        ];

        let collapsed = collapse_provider_snapshot_aliases(messages);
        assert_eq!(
            collapsed
                .iter()
                .map(|message| message.id.as_str())
                .collect::<Vec<_>>(),
            vec![
                "mobile-a",
                "mobile-b",
                "msg-a",
                "item-4",
                "item-not-numeric"
            ]
        );
    }

    #[test]
    fn prompt_improver_context_is_recent_deduplicated_and_bounded() {
        let mut messages = (0..80)
            .map(|index| {
                Message::assistant(
                    format!("msg-{index}"),
                    format!("context-{index}-{}", "x".repeat(2_000)),
                    index,
                )
            })
            .collect::<Vec<_>>();
        messages.push(Message::user(
            "mobile-alias",
            format!("important recent context {}", "á".repeat(12_000)),
            81,
        ));
        messages.push(Message::user(
            "item-1",
            format!("important recent context {}", "á".repeat(12_000)),
            82,
        ));
        messages.push(Message::user("current-message", "current prompt", 83));

        let dossier = prompt_improver_dossier(messages, "current-message").unwrap();
        assert!(dossier.len() <= PROMPT_IMPROVER_CONTEXT_MAX_BYTES);
        let decoded: Vec<Value> = serde_json::from_str(&dossier).unwrap();
        assert!(decoded.len() <= PROMPT_IMPROVER_CONTEXT_MAX_MESSAGES);
        assert!(!decoded.is_empty());
        assert!(
            decoded
                .iter()
                .all(|entry| entry["id"] != "current-message" && entry["id"] != "item-1")
        );
        assert_eq!(decoded.last().unwrap()["id"], "mobile-alias");
        assert!(
            decoded
                .iter()
                .all(|entry| entry["content"].as_str().unwrap().len()
                    <= PROMPT_IMPROVER_CONTEXT_MESSAGE_MAX_BYTES)
        );
    }

    #[tokio::test]
    async fn collapsed_alias_metadata_is_persisted_for_lightweight_session_lists() {
        let directory = TempDir::new().unwrap();
        let config = test_config(&directory);
        let store = Store::open(&config.database_path).await.unwrap();
        let now = unix_millis().unwrap();
        let mut summary = SessionSummary::new(
            "legacy-aliases",
            directory.path().display().to_string(),
            "Legacy aliases",
            now,
        );
        summary.provider_session_id = Some("legacy-aliases".to_owned());
        summary.runtime_status = Some("WAITING".to_owned());
        summary.message_count = 4;
        store.upsert_session(summary, None).await.unwrap();
        for (message, updated_at) in [
            (Message::user("mobile-user", "hello", now), now),
            (Message::user("item-1", "hello", now + 1), now + 1),
            (Message::assistant("msg-agent", "world", now + 2), now + 2),
            (Message::assistant("item-2", "world", now + 3), now + 3),
        ] {
            store
                .upsert_message(
                    MessageMutation {
                        session_id: "legacy-aliases".to_owned(),
                        message,
                        revision: 1,
                        updated_at,
                        final_: true,
                    },
                    None,
                )
                .await
                .unwrap();
        }
        let state = EngineState::bootstrap_with_transport(
            config,
            store,
            Arc::new(FakeTransport::new()),
            None,
            None,
            "codex-cli test".to_owned(),
            runtime_manifest_schema_probe().unwrap(),
        )
        .await
        .unwrap();
        state.set_transcript_hydrated("legacy-aliases", true).await;

        let detail = state.session("legacy-aliases").await.unwrap().unwrap();
        assert_eq!(detail.message_count, 2);
        assert_eq!(detail.messages.len(), 2);
        assert_eq!(detail.last_message_preview.as_deref(), Some("world"));
        let listed = state
            .list_sessions()
            .await
            .unwrap()
            .into_iter()
            .find(|session| session.session_id == "legacy-aliases")
            .unwrap();
        assert_eq!(listed.message_count, 2);
        assert_eq!(listed.last_message_preview.as_deref(), Some("world"));

        state
            .refresh_session_message_metadata("legacy-aliases", ActivityStatus::Ready)
            .await
            .unwrap();
        let refreshed = state
            .list_sessions()
            .await
            .unwrap()
            .into_iter()
            .find(|session| session.session_id == "legacy-aliases")
            .unwrap();
        assert_eq!(refreshed.message_count, 2);
        state.shutdown().await.unwrap();
    }

    struct FakeTransport {
        epoch: u64,
        running: AtomicBool,
        events: broadcast::Sender<AppServerEvent>,
        requests: StdMutex<Vec<(String, Value)>>,
        goals: StdMutex<HashMap<String, Value>>,
        responses: StdMutex<Vec<Value>>,
        response_errors: StdMutex<Vec<(Value, i64, String)>>,
        thread_list_pages: StdMutex<HashMap<Option<String>, Value>>,
        thread_reads: StdMutex<HashMap<String, Value>>,
        request_failures: StdMutex<HashMap<String, AppServerError>>,
        active_writer_threads: StdMutex<HashSet<String>>,
        next_thread: AtomicUsize,
        in_flight_turns: AtomicUsize,
        max_in_flight_turns: AtomicUsize,
        thread_name_delay_ms: AtomicU64,
        thread_read_delay_ms: AtomicU64,
    }

    impl FakeTransport {
        fn new() -> Self {
            let (events, _) = broadcast::channel(64);
            Self {
                epoch: 7,
                running: AtomicBool::new(true),
                events,
                requests: StdMutex::new(Vec::new()),
                goals: StdMutex::new(HashMap::new()),
                responses: StdMutex::new(Vec::new()),
                response_errors: StdMutex::new(Vec::new()),
                thread_list_pages: StdMutex::new(HashMap::new()),
                thread_reads: StdMutex::new(HashMap::new()),
                request_failures: StdMutex::new(HashMap::new()),
                active_writer_threads: StdMutex::new(HashSet::new()),
                next_thread: AtomicUsize::new(1),
                in_flight_turns: AtomicUsize::new(0),
                max_in_flight_turns: AtomicUsize::new(0),
                thread_name_delay_ms: AtomicU64::new(0),
                thread_read_delay_ms: AtomicU64::new(0),
            }
        }

        fn emit(&self, event: AppServerEvent) {
            let _ = self.events.send(event);
        }

        fn request_count(&self, method: &str) -> usize {
            lock_std(&self.requests)
                .iter()
                .filter(|(candidate, _)| candidate == method)
                .count()
        }

        fn set_thread_name_delay(&self, delay: Duration) {
            self.thread_name_delay_ms.store(
                u64::try_from(delay.as_millis()).unwrap_or(u64::MAX),
                Ordering::Release,
            );
        }

        fn set_thread_read_delay(&self, delay: Duration) {
            self.thread_read_delay_ms.store(
                u64::try_from(delay.as_millis()).unwrap_or(u64::MAX),
                Ordering::Release,
            );
        }

        fn seed_goal(&self, thread_id: &str, objective: &str, status: &str) {
            lock_std(&self.goals).insert(
                thread_id.to_owned(),
                json!({
                    "threadId": thread_id,
                    "objective": objective,
                    "status": status,
                    "tokenBudget": 10_000,
                    "tokensUsed": 200,
                    "timeUsedSeconds": 15,
                    "createdAt": 10,
                    "updatedAt": 20
                }),
            );
        }

        fn clear_goal(&self, thread_id: &str) {
            lock_std(&self.goals).remove(thread_id);
        }

        fn seed_thread_list_page(&self, cursor: Option<&str>, response: Value) {
            lock_std(&self.thread_list_pages).insert(cursor.map(str::to_owned), response);
        }

        fn seed_thread_read(&self, thread_id: &str, response: Value) {
            lock_std(&self.thread_reads).insert(thread_id.to_owned(), response);
        }

        fn fail_request(&self, method: &str, error: AppServerError) {
            lock_std(&self.request_failures).insert(method.to_owned(), error);
        }

        fn mark_active_writer(&self, thread_id: &str) {
            lock_std(&self.active_writer_threads).insert(thread_id.to_owned());
        }

        fn thread_response(&self, method: &str, params: &Value) -> Value {
            let thread_id = params
                .get("threadId")
                .and_then(Value::as_str)
                .map(str::to_owned)
                .unwrap_or_else(|| {
                    format!("thread-{}", self.next_thread.fetch_add(1, Ordering::AcqRel))
                });
            let model = params
                .get("model")
                .and_then(Value::as_str)
                .unwrap_or(crate::config::REQUIRED_TEST_MODEL);
            let effort = params
                .pointer("/config/model_reasoning_effort")
                .or_else(|| params.get("effort"))
                .and_then(Value::as_str)
                .unwrap_or(crate::config::REQUIRED_TEST_EFFORT);
            json!({
                "model": model,
                "modelProvider": "openai",
                "reasoningEffort": effort,
                "thread": {
                    "id": thread_id,
                    "cwd": params.get("cwd").and_then(Value::as_str).unwrap_or("/tmp"),
                    "name": if method == "thread/unarchive" { "Resumed" } else { "Test" },
                    "preview": "",
                    "createdAt": 1,
                    "updatedAt": 1,
                    "status": { "type": "idle" },
                    "turns": []
                }
            })
        }
    }

    impl EngineTransport for FakeTransport {
        fn epoch(&self) -> u64 {
            self.epoch
        }

        fn is_running(&self) -> bool {
            self.running.load(Ordering::Acquire)
        }

        fn subscribe(&self) -> broadcast::Receiver<AppServerEvent> {
            self.events.subscribe()
        }

        fn request(&self, method: String, params: Value) -> TransportFuture<'_, Value> {
            Box::pin(async move {
                lock_std(&self.requests).push((method.clone(), params.clone()));
                if let Some(error) = lock_std(&self.request_failures).get(&method).cloned() {
                    return Err(error);
                }
                match method.as_str() {
                    "model/list" => Ok(catalog_response()),
                    "thread/list" => {
                        let cursor = params
                            .get("cursor")
                            .and_then(Value::as_str)
                            .map(str::to_owned);
                        Ok(lock_std(&self.thread_list_pages)
                            .get(&cursor)
                            .cloned()
                            .unwrap_or_else(|| json!({ "data": [], "nextCursor": null })))
                    }
                    "thread/start" | "thread/resume" | "thread/unarchive" => {
                        Ok(self.thread_response(&method, &params))
                    }
                    "thread/name/set" => {
                        let delay = self.thread_name_delay_ms.load(Ordering::Acquire);
                        if delay > 0 {
                            time::sleep(Duration::from_millis(delay)).await;
                        }
                        Ok(json!({}))
                    }
                    THREAD_SETTINGS_UPDATE_METHOD => {
                        let thread_id = params
                            .get("threadId")
                            .and_then(Value::as_str)
                            .unwrap_or("thread")
                            .to_owned();
                        let model = params
                            .get("model")
                            .and_then(Value::as_str)
                            .unwrap_or(crate::config::DEFAULT_SESSION_MODEL)
                            .to_owned();
                        let effort = params
                            .get("effort")
                            .and_then(Value::as_str)
                            .unwrap_or(crate::config::DEFAULT_SESSION_EFFORT)
                            .to_owned();
                        self.emit(AppServerEvent::Notification {
                            epoch: self.epoch,
                            method: "thread/settings/updated".to_owned(),
                            params: json!({
                                "threadId": thread_id,
                                "threadSettings": {
                                    "model": model,
                                    "modelProvider": "openai",
                                    "effort": effort,
                                }
                            }),
                        });
                        Ok(json!({}))
                    }
                    "turn/start" => {
                        let current = self.in_flight_turns.fetch_add(1, Ordering::AcqRel) + 1;
                        self.max_in_flight_turns
                            .fetch_max(current, Ordering::AcqRel);
                        time::sleep(Duration::from_millis(75)).await;
                        self.in_flight_turns.fetch_sub(1, Ordering::AcqRel);
                        Ok(json!({
                            "turn": {
                                "id": format!("turn-{}", uuid::Uuid::now_v7()),
                                "status": "inProgress"
                            }
                        }))
                    }
                    "thread/read" => {
                        let delay = self.thread_read_delay_ms.load(Ordering::Acquire);
                        if delay > 0 {
                            time::sleep(Duration::from_millis(delay)).await;
                        }
                        let thread_id = params
                            .get("threadId")
                            .and_then(Value::as_str)
                            .unwrap_or("thread");
                        Ok(lock_std(&self.thread_reads)
                            .get(thread_id)
                            .cloned()
                            .unwrap_or_else(|| {
                                json!({
                                    "thread": {
                                        "id": thread_id,
                                        "cwd": "/tmp",
                                        "createdAt": 1,
                                        "updatedAt": 1,
                                        "status": { "type": "idle" },
                                        "turns": []
                                    }
                                })
                            }))
                    }
                    "thread/unsubscribe" => {
                        if let Some(thread_id) = params.get("threadId").and_then(Value::as_str) {
                            lock_std(&self.active_writer_threads).remove(thread_id);
                        }
                        Ok(json!({}))
                    }
                    "thread/delete" => {
                        let thread_id = params
                            .get("threadId")
                            .and_then(Value::as_str)
                            .unwrap_or("thread");
                        if lock_std(&self.active_writer_threads).contains(thread_id) {
                            return Err(AppServerError::Rpc {
                                method,
                                code: -32600,
                                message: format!("thread {thread_id} already has an active writer"),
                                data: None,
                            });
                        }
                        Ok(json!({}))
                    }
                    "thread/goal/set" => {
                        let thread_id = params
                            .get("threadId")
                            .and_then(Value::as_str)
                            .unwrap_or("thread")
                            .to_owned();
                        let goal = json!({
                            "threadId": thread_id,
                            "objective": params.get("objective").and_then(Value::as_str).unwrap_or(""),
                            "status": params.get("status").and_then(Value::as_str).unwrap_or("active"),
                            "tokenBudget": params.get("tokenBudget").cloned().unwrap_or(Value::Null),
                            "tokensUsed": 0,
                            "timeUsedSeconds": 0,
                            "createdAt": 1,
                            "updatedAt": 1
                        });
                        lock_std(&self.goals).insert(thread_id, goal.clone());
                        Ok(json!({ "goal": goal }))
                    }
                    "thread/goal/get" => {
                        let thread_id = params
                            .get("threadId")
                            .and_then(Value::as_str)
                            .unwrap_or("thread");
                        let goal = lock_std(&self.goals)
                            .get(thread_id)
                            .cloned()
                            .unwrap_or(Value::Null);
                        Ok(json!({ "goal": goal }))
                    }
                    "thread/goal/clear" => {
                        let thread_id = params
                            .get("threadId")
                            .and_then(Value::as_str)
                            .unwrap_or("thread");
                        let cleared = lock_std(&self.goals).remove(thread_id).is_some();
                        Ok(json!({ "cleared": cleared }))
                    }
                    _ => Ok(json!({})),
                }
            })
        }

        fn respond(&self, id: Value, result: Value) -> TransportFuture<'_, ()> {
            Box::pin(async move {
                lock_std(&self.responses).push(json!({ "id": id, "result": result }));
                Ok(())
            })
        }

        fn respond_error(
            &self,
            id: Value,
            code: i64,
            message: String,
            _data: Option<Value>,
        ) -> TransportFuture<'_, ()> {
            Box::pin(async move {
                lock_std(&self.response_errors).push((id, code, message));
                Ok(())
            })
        }

        fn shutdown(&self) -> TransportFuture<'_, ()> {
            Box::pin(async move {
                self.running.store(false, Ordering::Release);
                Ok(())
            })
        }
    }

    fn test_config(directory: &TempDir) -> EngineConfig {
        EngineConfig {
            bind: "127.0.0.1:0".parse().unwrap(),
            engine_id: format!("test-engine-{}", uuid::Uuid::now_v7()),
            codex_path: PathBuf::from("/bin/false"),
            database_path: directory.path().join("engine.sqlite3"),
            auth_token_file: directory.path().join("token"),
            workspace_roots: vec![directory.path().to_path_buf()],
            discovery_roots: Vec::new(),
            default_model: crate::config::DEFAULT_SESSION_MODEL.to_owned(),
            default_effort: crate::config::DEFAULT_SESSION_EFFORT.to_owned(),
            max_body_bytes: 52 * 1024 * 1024,
            max_jsonl_bytes: 16 * 1024 * 1024,
            heartbeat_seconds: 2,
            relay: None,
        }
    }

    async fn test_engine() -> (TempDir, EngineState, Arc<FakeTransport>) {
        let directory = TempDir::new().unwrap();
        let transport = Arc::new(FakeTransport::new());
        let state = bootstrap_test_engine(&directory, transport.clone()).await;
        (directory, state, transport)
    }

    async fn bootstrap_test_engine(
        directory: &TempDir,
        transport: Arc<FakeTransport>,
    ) -> EngineState {
        let config = test_config(directory);
        let store = Store::open(&config.database_path).await.unwrap();
        EngineState::bootstrap_with_transport(
            config,
            store,
            transport,
            None,
            None,
            "codex-cli test".to_owned(),
            runtime_manifest_schema_probe().unwrap(),
        )
        .await
        .unwrap()
    }

    async fn create_session(
        state: &EngineState,
        directory: &TempDir,
        session_id: &str,
        display_name: &str,
    ) {
        let acceptance = state
            .submit_command(CommandRequest {
                command_id: None,
                idempotency_key: format!("create:{session_id}"),
                session_id: Some(session_id.to_owned()),
                command: CommandKind::CreateSession {
                    project_path: directory.path().display().to_string(),
                    display_name: Some(display_name.to_owned()),
                    model: None,
                    reasoning_effort: None,
                },
                requested_at: unix_millis().unwrap(),
                trace_id: None,
            })
            .await
            .unwrap();
        let completed = state
            .wait_for_command(&acceptance.command.command_id, Duration::from_secs(3))
            .await
            .unwrap();
        assert_eq!(completed.state, CommandState::Completed);
    }

    fn catalog_response() -> Value {
        json!({
            "data": [
                {
                    "id": "gpt-5.6-sol",
                    "model": "gpt-5.6-sol",
                    "displayName": "GPT-5.6 Sol",
                    "defaultReasoningEffort": "low",
                    "supportedReasoningEfforts": [
                        { "reasoningEffort": "low", "description": "Fast" },
                        { "reasoningEffort": "high", "description": "Deep" },
                        { "reasoningEffort": "max", "description": "Maximum" }
                    ],
                    "hidden": false,
                    "isDefault": true
                },
                {
                    "id": "gpt-5.6-luna",
                    "model": "gpt-5.6-luna",
                    "displayName": "GPT-5.6 Luna",
                    "defaultReasoningEffort": "high",
                    "supportedReasoningEfforts": [
                        { "reasoningEffort": "medium", "description": "Fast" },
                        { "reasoningEffort": "high", "description": "Deep" }
                    ],
                    "hidden": false,
                    "isDefault": false
                },
                {
                    "id": "unsupported-4",
                    "model": "unsupported-4",
                    "displayName": "Unsupported",
                    "defaultReasoningEffort": "high",
                    "supportedReasoningEfforts": [
                        { "reasoningEffort": "high" }
                    ],
                    "hidden": false,
                    "isDefault": false
                },
                {
                    "id": "gpt-xai",
                    "model": "gpt-xai",
                    "modelProvider": "xai",
                    "displayName": "Provider impostor",
                    "defaultReasoningEffort": "high",
                    "supportedReasoningEfforts": [
                        { "reasoningEffort": "high" }
                    ],
                    "hidden": false,
                    "isDefault": false
                },
                {
                    "id": "gpt-hidden",
                    "model": "gpt-hidden",
                    "displayName": "Hidden",
                    "defaultReasoningEffort": "medium",
                    "supportedReasoningEfforts": [
                        { "reasoningEffort": "medium" }
                    ],
                    "hidden": true,
                    "isDefault": false
                }
            ]
        })
    }

    fn missing_rollout_rpc(method: &str, thread_id: &str) -> AppServerError {
        AppServerError::Rpc {
            method: method.to_owned(),
            code: -32600,
            message: format!("no rollout found for thread id {thread_id}"),
            data: None,
        }
    }

    fn missing_archived_rollout_rpc(thread_id: &str) -> AppServerError {
        AppServerError::Rpc {
            method: "thread/unarchive".to_owned(),
            code: -32600,
            message: format!("no archived rollout found for thread id {thread_id}"),
            data: None,
        }
    }

    #[test]
    fn model_probe_keeps_only_visible_gpt_models() {
        let catalog =
            parse_model_catalog(&catalog_response(), 10, "codex-cli 0.147.0", "hash").unwrap();
        assert_eq!(catalog.models.len(), 2);
        assert_eq!(catalog.models[0].model, "gpt-5.6-sol");
        assert_eq!(catalog.models[0].model_provider.as_deref(), Some("openai"));
        assert_eq!(catalog.models[1].model, "gpt-5.6-luna");
    }

    #[tokio::test]
    async fn new_sessions_default_to_sol_max_and_model_changes_use_settings_update() {
        let (directory, state, transport) = test_engine().await;
        create_session(&state, &directory, "sticky-model", "Sticky model").await;

        let created = state.session("sticky-model").await.unwrap().unwrap();
        assert_eq!(
            created.model.as_deref(),
            Some(crate::config::DEFAULT_SESSION_MODEL)
        );
        assert_eq!(
            created.reasoning_effort.as_deref(),
            Some(crate::config::DEFAULT_SESSION_EFFORT)
        );
        let thread_id = created.provider_session_id.clone().unwrap();

        let acceptance = state
            .submit_command(CommandRequest {
                command_id: None,
                idempotency_key: "sticky-model:change".to_owned(),
                session_id: Some("sticky-model".to_owned()),
                command: CommandKind::SetModel {
                    settings: RuntimeModelSettings {
                        model: crate::config::REQUIRED_TEST_MODEL.to_owned(),
                        model_provider: Some("openai".to_owned()),
                        effort: crate::config::REQUIRED_TEST_EFFORT.to_owned(),
                    },
                },
                requested_at: unix_millis().unwrap(),
                trace_id: None,
            })
            .await
            .unwrap();
        let completed = state
            .wait_for_command(&acceptance.command.command_id, Duration::from_secs(3))
            .await
            .unwrap();
        assert_eq!(completed.state, CommandState::Completed);

        {
            let requests = lock_std(&transport.requests);
            let (_, update) = requests
                .iter()
                .find(|(method, _)| method == THREAD_SETTINGS_UPDATE_METHOD)
                .unwrap();
            assert_eq!(
                update,
                &json!({
                    "threadId": thread_id,
                    "model": crate::config::REQUIRED_TEST_MODEL,
                    "effort": crate::config::REQUIRED_TEST_EFFORT,
                })
            );
            assert_eq!(
                requests
                    .iter()
                    .filter(|(method, _)| method == "thread/resume")
                    .count(),
                0
            );
        }

        let changed = state.session("sticky-model").await.unwrap().unwrap();
        assert_eq!(
            changed.model.as_deref(),
            Some(crate::config::REQUIRED_TEST_MODEL)
        );
        assert_eq!(
            changed.reasoning_effort.as_deref(),
            Some(crate::config::REQUIRED_TEST_EFFORT)
        );

        let reconciled_thread = transport.thread_response(
            "thread/read",
            &json!({
                "threadId": thread_id,
                "cwd": directory.path(),
            }),
        );
        state
            .reconcile_thread(
                reconciled_thread.get("thread").unwrap(),
                Some("sticky-model"),
            )
            .await
            .unwrap();
        let reconciled = state.session("sticky-model").await.unwrap().unwrap();
        assert_eq!(
            reconciled.model.as_deref(),
            Some(crate::config::REQUIRED_TEST_MODEL)
        );
        assert_eq!(
            reconciled.reasoning_effort.as_deref(),
            Some(crate::config::REQUIRED_TEST_EFFORT)
        );
        state.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn slow_thread_name_update_does_not_delay_session_creation() {
        let (directory, state, transport) = test_engine().await;
        transport.set_thread_name_delay(Duration::from_secs(2));

        let started = time::Instant::now();
        create_session(&state, &directory, "fast-create", "Visible immediately").await;

        assert!(started.elapsed() < Duration::from_millis(500));
        let created = state.session("fast-create").await.unwrap().unwrap();
        assert_eq!(created.display_name, "Visible immediately");
        assert_eq!(created.window_name.as_deref(), Some("Visible immediately"));
        for _ in 0..50 {
            if transport.request_count("thread/name/set") == 1 {
                break;
            }
            time::sleep(Duration::from_millis(10)).await;
        }
        assert_eq!(transport.request_count("thread/name/set"), 1);
        state.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn warm_session_creator_exposes_provisional_session_before_persistence() {
        let directory = TempDir::new().unwrap();
        let config = test_config(&directory);
        let store = Store::open(&config.database_path).await.unwrap();
        let main_transport = Arc::new(FakeTransport::new());
        let session_creator = Arc::new(FakeTransport::new());
        session_creator.set_thread_name_delay(Duration::from_secs(2));
        let state = EngineState::bootstrap_with_transport(
            config,
            store,
            main_transport.clone(),
            Some(session_creator.clone()),
            None,
            "codex-cli test".to_owned(),
            runtime_manifest_schema_probe().unwrap(),
        )
        .await
        .unwrap();

        let started = time::Instant::now();
        let acceptance = state
            .submit_command(CommandRequest {
                command_id: None,
                idempotency_key: "create:warm-creator".to_owned(),
                session_id: Some("warm-creator".to_owned()),
                command: CommandKind::CreateSession {
                    project_path: directory.path().display().to_string(),
                    display_name: Some("Warm creator".to_owned()),
                    model: None,
                    reasoning_effort: None,
                },
                requested_at: unix_millis().unwrap(),
                trace_id: None,
            })
            .await
            .unwrap();

        let provisional = time::timeout(Duration::from_millis(500), async {
            loop {
                if let Some(session) = state
                    .list_sessions()
                    .await
                    .unwrap()
                    .into_iter()
                    .find(|session| session.session_id == "warm-creator")
                {
                    break session;
                }
                time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("the warm creator must expose the provisional session promptly");

        assert!(started.elapsed() < Duration::from_millis(500));
        assert!(!provisional.can_send);
        assert_eq!(provisional.runtime_status.as_deref(), Some("STARTING"));
        assert_eq!(
            provisional.runtime_status_detail.as_deref(),
            Some("Finalizando la sesión")
        );
        assert_eq!(main_transport.request_count("thread/start"), 0);
        assert_eq!(session_creator.request_count("thread/start"), 1);

        let completed = state
            .wait_for_command(&acceptance.command.command_id, Duration::from_secs(4))
            .await
            .unwrap();
        assert_eq!(completed.state, CommandState::Completed);
        let ready = state.session("warm-creator").await.unwrap().unwrap();
        assert!(ready.can_send);
        assert_eq!(ready.runtime_status.as_deref(), Some("WAITING"));
        assert_eq!(ready.runtime_status_detail, None);
        assert_eq!(session_creator.request_count("thread/name/set"), 1);
        assert_eq!(session_creator.request_count("thread/archive"), 1);
        assert_eq!(session_creator.request_count("thread/unarchive"), 1);
        assert_eq!(session_creator.request_count("thread/unsubscribe"), 1);
        assert_eq!(main_transport.request_count("thread/name/set"), 0);
        state.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn warm_creator_sessions_resume_on_main_before_followup_thread_commands() {
        let directory = TempDir::new().unwrap();
        let config = test_config(&directory);
        let store = Store::open(&config.database_path).await.unwrap();
        let main_transport = Arc::new(FakeTransport::new());
        let session_creator = Arc::new(FakeTransport::new());
        let state = EngineState::bootstrap_with_transport(
            config,
            store,
            main_transport.clone(),
            Some(session_creator.clone()),
            None,
            "codex-cli test".to_owned(),
            runtime_manifest_schema_probe().unwrap(),
        )
        .await
        .unwrap();

        create_session(&state, &directory, "warm-followup", "Warm followup").await;
        assert_eq!(main_transport.request_count("thread/start"), 0);

        let rename = state
            .submit_command(CommandRequest {
                command_id: None,
                idempotency_key: "warm-followup:rename".to_owned(),
                session_id: Some("warm-followup".to_owned()),
                command: CommandKind::Rename {
                    display_name: "Renamed after warm create".to_owned(),
                },
                requested_at: unix_millis().unwrap(),
                trace_id: None,
            })
            .await
            .unwrap();
        assert_eq!(
            state
                .wait_for_command(&rename.command.command_id, Duration::from_secs(3))
                .await
                .unwrap()
                .state,
            CommandState::Completed
        );

        let archive = state
            .submit_command(CommandRequest {
                command_id: None,
                idempotency_key: "warm-followup:archive".to_owned(),
                session_id: Some("warm-followup".to_owned()),
                command: CommandKind::Archive,
                requested_at: unix_millis().unwrap(),
                trace_id: None,
            })
            .await
            .unwrap();
        assert_eq!(
            state
                .wait_for_command(&archive.command.command_id, Duration::from_secs(3))
                .await
                .unwrap()
                .state,
            CommandState::Completed
        );

        {
            let requests = lock_std(&main_transport.requests);
            let resume_index = requests
                .iter()
                .position(|(method, _)| method == "thread/resume")
                .unwrap();
            let rename_index = requests
                .iter()
                .position(|(method, _)| method == "thread/name/set")
                .unwrap();
            let archive_index = requests
                .iter()
                .position(|(method, _)| method == "thread/archive")
                .unwrap();
            assert!(resume_index < rename_index);
            assert!(rename_index < archive_index);
        }
        assert_eq!(main_transport.request_count("thread/resume"), 1);
        assert_eq!(session_creator.request_count("thread/start"), 1);
        assert_eq!(session_creator.request_count("thread/name/set"), 1);
        state.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn thread_settings_notifications_reconcile_the_durable_model_authority() {
        let (directory, state, transport) = test_engine().await;
        create_session(&state, &directory, "notified-model", "Notified model").await;
        let thread_id = state
            .session("notified-model")
            .await
            .unwrap()
            .unwrap()
            .provider_session_id
            .unwrap();

        state
            .reduce_notification(
                transport.epoch(),
                "thread/settings/updated",
                json!({
                    "threadId": thread_id,
                    "threadSettings": {
                        "model": crate::config::REQUIRED_TEST_MODEL,
                        "modelProvider": "openai",
                        "effort": crate::config::REQUIRED_TEST_EFFORT,
                    }
                }),
            )
            .await
            .unwrap();

        let reconciled = state.session("notified-model").await.unwrap().unwrap();
        assert_eq!(
            reconciled.model.as_deref(),
            Some(crate::config::REQUIRED_TEST_MODEL)
        );
        assert_eq!(
            reconciled.reasoning_effort.as_deref(),
            Some(crate::config::REQUIRED_TEST_EFFORT)
        );
        state.shutdown().await.unwrap();
    }

    #[test]
    fn message_accumulator_produces_absolute_monotonic_patches() {
        let mut accumulator = MessageAccumulator::default();
        assert_eq!(
            accumulator.apply_delta("hello", 10),
            ("hello".to_owned(), 1, 10)
        );
        assert_eq!(
            accumulator.apply_delta(" world", 11),
            ("hello world".to_owned(), 2, 11)
        );
        assert_eq!(
            accumulator.apply_authoritative("hello world!", 9),
            ("hello world!".to_owned(), 3, 11)
        );
        assert_eq!(
            accumulator.apply_authoritative("hello world!", 13),
            ("hello world!".to_owned(), 3, 13)
        );
    }

    #[test]
    fn turn_input_is_text_plus_local_images() {
        let attachments = vec![crate::protocol::ImageAttachment {
            id: "image-1".to_owned(),
            name: "one.png".to_owned(),
            path: Some("/tmp/one.png".to_owned()),
            size: 3,
            mime_type: "image/png".to_owned(),
            preview_data: None,
        }];
        assert_eq!(
            build_turn_input("inspect", &attachments),
            vec![
                json!({ "type": "text", "text": "inspect" }),
                json!({ "type": "localImage", "path": "/tmp/one.png" }),
            ]
        );
    }

    #[test]
    fn relay_attachment_url_preserves_public_prefix_and_removes_query() {
        let token = format!("{}.png", uuid::Uuid::new_v4());
        let url = relay_attachment_url(
            "wss://relay.example.com/fermin-code/v1/engine/connect?engineId=old",
            &token,
        )
        .unwrap();
        assert_eq!(
            url.as_str(),
            format!("https://relay.example.com/fermin-code/v1/engine/attachments/{token}")
        );
    }

    #[test]
    fn thread_snapshot_maps_to_mobile_session() {
        let summary = summary_from_thread(
            &json!({
                "id": "thread-1",
                "cwd": "/tmp/project",
                "name": "Session name",
                "preview": "first prompt",
                "createdAt": 10,
                "updatedAt": 11,
                "path": "/tmp/rollout.jsonl",
                "parentThreadId": "parent-1",
                "status": { "type": "active", "activeFlags": [] },
                "turns": []
            }),
            "mobile-1",
            0,
        )
        .unwrap();
        assert_eq!(summary.session_id, "mobile-1");
        assert_eq!(summary.provider_session_id.as_deref(), Some("thread-1"));
        assert_eq!(summary.display_name, "Session name");
        assert_eq!(summary.updated_at, 11_000);
        assert_eq!(summary.activity_status, ActivityStatus::Working);
        assert_eq!(summary.parent_session_id.as_deref(), Some("parent-1"));
    }

    #[tokio::test]
    async fn startup_idempotently_continues_sessions_that_were_working() {
        let directory = TempDir::new().unwrap();
        let config = test_config(&directory);
        let store = Store::open(&config.database_path).await.unwrap();
        let now = unix_millis().unwrap();
        let mut stored = SessionSummary::new(
            "stored-session",
            directory.path().display().to_string(),
            "Stored session",
            now,
        );
        stored.provider_session_id = Some("stored-thread".to_owned());
        stored.activity_status = ActivityStatus::Working;
        stored.runtime_status = Some("WORKING".to_owned());
        stored.runtime_status_detail = Some("Stale pre-restart activity".to_owned());
        stored.model = Some(crate::config::REQUIRED_TEST_MODEL.to_owned());
        stored.reasoning_effort = Some(crate::config::REQUIRED_TEST_EFFORT.to_owned());
        store.upsert_session(stored, None).await.unwrap();

        let transport = Arc::new(FakeTransport::new());
        let state = time::timeout(
            Duration::from_secs(1),
            EngineState::bootstrap_with_transport(
                config,
                store,
                transport.clone(),
                None,
                None,
                "codex-cli test".to_owned(),
                runtime_manifest_schema_probe().unwrap(),
            ),
        )
        .await
        .expect("stored sessions must not block engine readiness")
        .unwrap();

        time::timeout(Duration::from_secs(3), async {
            while transport.request_count("turn/start") == 0 {
                time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("the recovered continuation must start without an external rollout helper");
        assert_eq!(transport.request_count("thread/resume"), 1);
        let recovered = state
            .list_sessions()
            .await
            .unwrap()
            .into_iter()
            .find(|session| session.session_id == "stored-session")
            .unwrap();
        assert_eq!(recovered.activity_status, ActivityStatus::Working);
        assert_eq!(recovered.runtime_status.as_deref(), Some("WORKING"));
        assert_eq!(recovered.runtime_status_detail, None);
        {
            let requests = lock_std(&transport.requests);
            let turn_start = requests
                .iter()
                .find(|(method, _)| method == "turn/start")
                .expect("recovery turn/start request");
            assert!(turn_start.1.to_string().contains(CRASH_RECOVERY_MESSAGE));
        }
        state.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn startup_recovers_a_persisted_provider_failure_detail() {
        let directory = TempDir::new().unwrap();
        let config = test_config(&directory);
        let store = Store::open(&config.database_path).await.unwrap();
        let now = unix_millis().unwrap();
        let mut stored = SessionSummary::new(
            "stored-provider-error",
            directory.path().display().to_string(),
            "homepod",
            now,
        );
        stored.provider_session_id = Some("stored-provider-thread".to_owned());
        stored.activity_status = ActivityStatus::Error;
        stored.runtime_status = Some("WAITING".to_owned());
        stored.model = Some(crate::config::REQUIRED_TEST_MODEL.to_owned());
        stored.reasoning_effort = Some(crate::config::REQUIRED_TEST_EFFORT.to_owned());
        store.upsert_session(stored, None).await.unwrap();
        store
            .append_event(
                NewEvent {
                    event_id: Some("persisted-provider-error".to_owned()),
                    session_id: Some("stored-provider-error".to_owned()),
                    command_id: None,
                    process_epoch: None,
                    kind: EventKind::Error,
                    payload: json!({
                        "method": "error",
                        "params": {
                            "threadId": "stored-provider-thread",
                            "willRetry": false,
                            "error": {
                                "codexErrorInfo": "cyberPolicy",
                                "message": "raw provider policy text"
                            }
                        }
                    }),
                    created_at: now,
                },
                None,
            )
            .await
            .unwrap();

        let transport = Arc::new(FakeTransport::new());
        let state = EngineState::bootstrap_with_transport(
            config,
            store,
            transport,
            None,
            None,
            "codex-cli test".to_owned(),
            runtime_manifest_schema_probe().unwrap(),
        )
        .await
        .unwrap();

        let recovered = state
            .list_sessions()
            .await
            .unwrap()
            .into_iter()
            .find(|session| session.session_id == "stored-provider-error")
            .unwrap();
        assert_eq!(recovered.activity_status, ActivityStatus::Error);
        assert_eq!(recovered.runtime_status.as_deref(), Some("WAITING"));
        assert!(
            recovered
                .runtime_status_detail
                .as_deref()
                .is_some_and(|detail| detail.contains("El mensaje llegó correctamente a Fermín"))
        );
        state.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn stored_lazy_thread_resumes_before_settings_update_and_confirms() {
        let directory = TempDir::new().unwrap();
        let config = test_config(&directory);
        let store = Store::open(&config.database_path).await.unwrap();
        let now = unix_millis().unwrap();
        let mut stored = SessionSummary::new(
            "stored-model-session",
            directory.path().display().to_string(),
            "Stored model session",
            now,
        );
        stored.provider_session_id = Some("stored-model-thread".to_owned());
        stored.runtime_status = Some("WAITING".to_owned());
        stored.model = Some(crate::config::REQUIRED_TEST_MODEL.to_owned());
        stored.reasoning_effort = Some(crate::config::REQUIRED_TEST_EFFORT.to_owned());
        store.upsert_session(stored, None).await.unwrap();

        let transport = Arc::new(FakeTransport::new());
        let state = EngineState::bootstrap_with_transport(
            config,
            store,
            transport.clone(),
            None,
            None,
            "codex-cli test".to_owned(),
            runtime_manifest_schema_probe().unwrap(),
        )
        .await
        .unwrap();
        assert_eq!(transport.request_count("thread/resume"), 0);

        let acceptance = state
            .submit_command(CommandRequest {
                command_id: None,
                idempotency_key: "stored-model-session:change".to_owned(),
                session_id: Some("stored-model-session".to_owned()),
                command: CommandKind::SetModel {
                    settings: RuntimeModelSettings {
                        model: crate::config::DEFAULT_SESSION_MODEL.to_owned(),
                        model_provider: Some("openai".to_owned()),
                        effort: crate::config::DEFAULT_SESSION_EFFORT.to_owned(),
                    },
                },
                requested_at: unix_millis().unwrap(),
                trace_id: None,
            })
            .await
            .unwrap();
        let completed = state
            .wait_for_command(&acceptance.command.command_id, Duration::from_secs(3))
            .await
            .unwrap();
        assert_eq!(completed.state, CommandState::Completed);

        {
            let requests = lock_std(&transport.requests);
            let resume_index = requests
                .iter()
                .position(|(method, _)| method == "thread/resume")
                .unwrap();
            let update_index = requests
                .iter()
                .position(|(method, _)| method == THREAD_SETTINGS_UPDATE_METHOD)
                .unwrap();
            assert!(resume_index < update_index);
            assert_eq!(
                requests[resume_index].1,
                json!({
                    "threadId": "stored-model-thread",
                    "model": crate::config::REQUIRED_TEST_MODEL,
                    "modelProvider": "openai",
                    "config": {
                        "model_reasoning_effort": crate::config::REQUIRED_TEST_EFFORT,
                    },
                    "approvalPolicy": "never",
                })
            );
            assert_eq!(
                requests[update_index].1,
                json!({
                    "threadId": "stored-model-thread",
                    "model": crate::config::DEFAULT_SESSION_MODEL,
                    "effort": crate::config::DEFAULT_SESSION_EFFORT,
                })
            );
        }

        let changed = state
            .session("stored-model-session")
            .await
            .unwrap()
            .unwrap();
        assert_eq!(
            changed.model.as_deref(),
            Some(crate::config::DEFAULT_SESSION_MODEL)
        );
        assert_eq!(
            changed.reasoning_effort.as_deref(),
            Some(crate::config::DEFAULT_SESSION_EFFORT)
        );
        state.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn bridge_snapshot_stays_lightweight_with_large_transcripts() {
        let (directory, state, _) = test_engine().await;
        create_session(&state, &directory, "large-history", "Large history").await;
        let now = unix_millis().unwrap();
        let content = "x".repeat(64 * 1024);
        for index in 0..40 {
            state
                .store()
                .upsert_message(
                    MessageMutation {
                        session_id: "large-history".to_owned(),
                        message: Message::assistant(
                            format!("large-message-{index}"),
                            content.clone(),
                            now + index,
                        ),
                        revision: 1,
                        updated_at: now + index,
                        final_: true,
                    },
                    None,
                )
                .await
                .unwrap();
        }

        let snapshot = <EngineState as crate::bridge::BridgeSource>::snapshot(&state)
            .await
            .unwrap();
        assert!(
            snapshot
                .sessions
                .iter()
                .all(|session| session.messages.is_empty())
        );
        assert!(serde_json::to_vec(&snapshot).unwrap().len() < 2 * 1024 * 1024);
        state.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn startup_never_lists_or_imports_global_codex_threads() {
        let directory = TempDir::new().unwrap();
        let transport = Arc::new(FakeTransport::new());
        transport.seed_thread_list_page(
            None,
            json!({
                "data": [{
                    "id": "global-codex-thread",
                    "cwd": directory.path(),
                    "preview": "Must never enter Fermín Code",
                    "createdAt": 10,
                    "updatedAt": 20,
                    "status": { "type": "notLoaded" },
                    "turns": []
                }],
                "nextCursor": null
            }),
        );

        let state = bootstrap_test_engine(&directory, transport.clone()).await;
        let sessions = state.list_sessions().await.unwrap();
        assert!(sessions.is_empty());
        assert_eq!(state.health().await.session_count, 0);
        assert_eq!(transport.request_count("thread/list"), 0);
        assert!(state.snapshot().await.unwrap().sessions.is_empty());
        state.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn legacy_unmanaged_rows_stay_hidden_while_new_create_and_chat_work() {
        let directory = TempDir::new().unwrap();
        let config = test_config(&directory);
        let store = Store::open(&config.database_path).await.unwrap();
        let mut legacy = SessionSummary::new(
            "legacy-global",
            directory.path().display().to_string(),
            "Legacy global thread",
            unix_millis().unwrap(),
        );
        legacy.managed_by_fermin = false;
        legacy.provider_session_id = Some("legacy-global-thread".to_owned());
        legacy.runtime_status = Some("WAITING".to_owned());
        store.upsert_session(legacy, None).await.unwrap();
        let transport = Arc::new(FakeTransport::new());
        let state = EngineState::bootstrap_with_transport(
            config,
            store,
            transport.clone(),
            None,
            None,
            "codex-cli test".to_owned(),
            runtime_manifest_schema_probe().unwrap(),
        )
        .await
        .unwrap();
        assert!(state.list_sessions().await.unwrap().is_empty());
        assert!(state.session("legacy-global").await.unwrap().is_none());

        create_session(&state, &directory, "fermin-owned", "Fermín owned").await;
        let acceptance = state
            .submit_command(CommandRequest {
                command_id: None,
                idempotency_key: "fermin-owned-message".to_owned(),
                session_id: Some("fermin-owned".to_owned()),
                command: CommandKind::SendMessage {
                    content: "hello from Fermín".to_owned(),
                    client_message_id: "fermin-owned-client-message".to_owned(),
                    attachments: Vec::new(),
                    service_tier: None,
                },
                requested_at: unix_millis().unwrap(),
                trace_id: None,
            })
            .await
            .unwrap();
        let completed = state
            .wait_for_command(&acceptance.command.command_id, Duration::from_secs(3))
            .await
            .unwrap();
        assert_eq!(completed.state, CommandState::Completed);
        let sessions = state.list_sessions().await.unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].session_id, "fermin-owned");
        assert!(sessions[0].managed_by_fermin);
        state.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn recovery_searches_legacy_content_and_adopts_only_the_selected_session() {
        let directory = TempDir::new().unwrap();
        let config = test_config(&directory);
        let store = Store::open(&config.database_path).await.unwrap();
        let now = unix_millis().unwrap();
        let mut legacy = SessionSummary::new(
            "legacy-article-studio",
            directory.path().display().to_string(),
            "GitHub deploy notes",
            now,
        );
        legacy.managed_by_fermin = false;
        legacy.provider_session_id = Some("legacy-article-studio-thread".to_owned());
        legacy.project_name = Some("cloudx-toolbox".to_owned());
        legacy.project_path = Some(directory.path().display().to_string());
        legacy.session_name = Some(format!(
            "A legacy title with newlines\nand excess detail {}",
            "article work ".repeat(40)
        ));
        legacy.runtime_status = Some("WAITING".to_owned());
        store.upsert_session(legacy, None).await.unwrap();
        store
            .upsert_message(
                MessageMutation {
                    session_id: "legacy-article-studio".to_owned(),
                    message: Message::assistant(
                        "legacy-message",
                        "Created webapp/app/routes/tools.article-studio.tsx and deployed it.",
                        now,
                    ),
                    revision: 1,
                    updated_at: now,
                    final_: true,
                },
                None,
            )
            .await
            .unwrap();
        let transport = Arc::new(FakeTransport::new());
        let state = EngineState::bootstrap_with_transport(
            config,
            store,
            transport.clone(),
            None,
            None,
            "codex-cli test".to_owned(),
            runtime_manifest_schema_probe().unwrap(),
        )
        .await
        .unwrap();

        let history_before = state
            .active_session_history(crate::api::SessionHistoryQuery {
                query: "article-studio".to_owned(),
                state: crate::api::SessionHistoryState::All,
                sort: crate::api::SessionHistorySort::Relevance,
                project_path: None,
                from: None,
                to: None,
                offset: 0,
                limit: 100,
                refresh: false,
            })
            .await
            .unwrap();
        assert!(history_before.items.is_empty());

        let recoverable = state
            .recoverable_sessions(crate::api::SessionRecoveryQuery {
                query: "article-studio".to_owned(),
                offset: 0,
                limit: 100,
            })
            .await
            .unwrap();
        assert_eq!(recoverable.total, 1);
        assert_eq!(recoverable.items[0].id, "legacy-article-studio");
        assert_eq!(
            recoverable.items[0].matched_in.as_deref(),
            Some("contenido")
        );
        assert!(recoverable.items[0].preview.contains("article-studio"));
        assert!(recoverable.items[0].session_name.chars().count() <= 161);
        assert!(!recoverable.items[0].session_name.contains('\n'));

        let recovery = <EngineState as crate::api::MobileBackend>::recover_session(
            &state,
            "legacy-article-studio".to_owned(),
            "recover-legacy-article-studio".to_owned(),
        )
        .await
        .unwrap();
        let completed = state
            .wait_for_command(
                &recovery.acceptance.command.command_id,
                Duration::from_secs(3),
            )
            .await
            .unwrap();
        assert_eq!(completed.state, CommandState::Completed);
        let recovered = state
            .session("legacy-article-studio")
            .await
            .unwrap()
            .unwrap();
        assert!(recovered.managed_by_fermin);
        assert_eq!(transport.request_count("thread/resume"), 1);
        assert!(
            state
                .recoverable_sessions(crate::api::SessionRecoveryQuery {
                    query: "article-studio".to_owned(),
                    offset: 0,
                    limit: 100,
                })
                .await
                .unwrap()
                .items
                .is_empty()
        );
        state.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn managed_thread_hydrates_detail_lazily_and_only_once() {
        let directory = TempDir::new().unwrap();
        let config = test_config(&directory);
        let store = Store::open(&config.database_path).await.unwrap();
        let mut summary = SessionSummary::new(
            "lazy-detail",
            directory.path().display().to_string(),
            "Lazy detail",
            unix_millis().unwrap(),
        );
        summary.provider_session_id = Some("lazy-detail".to_owned());
        summary.runtime_status = Some("WAITING".to_owned());
        summary.model = Some(crate::config::REQUIRED_TEST_MODEL.to_owned());
        summary.reasoning_effort = Some(crate::config::REQUIRED_TEST_EFFORT.to_owned());
        store.upsert_session(summary, None).await.unwrap();
        let transport = Arc::new(FakeTransport::new());
        transport.seed_thread_read(
            "lazy-detail",
            json!({
                "thread": {
                    "id": "lazy-detail",
                    "cwd": directory.path(),
                    "preview": "Lazy detail",
                    "createdAt": 10,
                    "updatedAt": 21,
                    "status": { "type": "idle" },
                    "turns": [{
                        "id": "turn-lazy",
                        "status": "completed",
                        "items": [
                            {
                                "id": "user-lazy",
                                "type": "userMessage",
                                "content": [{ "type": "text", "text": "hello" }]
                            },
                            {
                                "id": "agent-lazy",
                                "type": "agentMessage",
                                "text": "world"
                            }
                        ]
                    }]
                }
            }),
        );

        let state = EngineState::bootstrap_with_transport(
            config,
            store,
            transport.clone(),
            None,
            None,
            "codex-cli test".to_owned(),
            runtime_manifest_schema_probe().unwrap(),
        )
        .await
        .unwrap();
        assert_eq!(transport.request_count("thread/read"), 0);
        let first = state.session("lazy-detail").await.unwrap().unwrap();
        assert_eq!(first.messages.len(), 2);
        assert_eq!(first.runtime_status.as_deref(), Some("WAITING"));
        assert_eq!(first.runtime_status_detail, None);
        let recovered_message_ids = state
            .replay_events(0, 1_000)
            .await
            .unwrap()
            .into_iter()
            .filter(|event| event.kind == EventKind::MessagePatch)
            .filter_map(|event| serde_json::from_value::<MessagePatch>(event.payload).ok())
            .map(|patch| patch.message.id)
            .collect::<BTreeSet<_>>();
        assert_eq!(
            recovered_message_ids,
            BTreeSet::from(["agent-lazy".to_owned(), "user-lazy".to_owned()])
        );
        let second = state.session("lazy-detail").await.unwrap().unwrap();
        assert_eq!(second.messages.len(), 2);
        assert_eq!(transport.request_count("thread/read"), 1);
        state.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn managed_thread_hydration_claims_existing_messages_instead_of_duplicating_them() {
        let directory = TempDir::new().unwrap();
        let config = test_config(&directory);
        let store = Store::open(&config.database_path).await.unwrap();
        let mut summary = SessionSummary::new(
            "alias-detail",
            directory.path().display().to_string(),
            "Alias detail",
            unix_millis().unwrap(),
        );
        summary.provider_session_id = Some("alias-detail".to_owned());
        summary.runtime_status = Some("WAITING".to_owned());
        summary.model = Some(crate::config::REQUIRED_TEST_MODEL.to_owned());
        summary.reasoning_effort = Some(crate::config::REQUIRED_TEST_EFFORT.to_owned());
        store.upsert_session(summary, None).await.unwrap();
        let now = unix_millis().unwrap();
        for (message, updated_at) in [
            (Message::user("mobile-user", "hello", now), now),
            (Message::assistant("msg-agent", "world", now + 1), now + 1),
        ] {
            store
                .upsert_message(
                    MessageMutation {
                        session_id: "alias-detail".to_owned(),
                        message,
                        revision: 1,
                        updated_at,
                        final_: true,
                    },
                    None,
                )
                .await
                .unwrap();
        }
        let transport = Arc::new(FakeTransport::new());
        transport.set_thread_read_delay(Duration::from_secs(1));
        transport.seed_thread_read(
            "alias-detail",
            json!({
                "thread": {
                    "id": "alias-detail",
                    "cwd": directory.path(),
                    "preview": "Alias detail",
                    "createdAt": 10,
                    "updatedAt": 21,
                    "status": { "type": "idle" },
                    "turns": [{
                        "id": "turn-alias",
                        "status": "completed",
                        "items": [
                            {
                                "id": "item-1",
                                "type": "userMessage",
                                "content": [{ "type": "text", "text": "hello" }]
                            },
                            {
                                "id": "item-2",
                                "type": "agentMessage",
                                "text": "world"
                            }
                        ]
                    }]
                }
            }),
        );

        let state = EngineState::bootstrap_with_transport(
            config,
            store,
            transport.clone(),
            None,
            None,
            "codex-cli test".to_owned(),
            runtime_manifest_schema_probe().unwrap(),
        )
        .await
        .unwrap();
        let cached = time::timeout(Duration::from_millis(250), state.session("alias-detail"))
            .await
            .expect("cached detail must not wait for the provider")
            .unwrap()
            .unwrap();
        assert_eq!(cached.messages.len(), 2);
        assert_eq!(cached.messages[0].id, "mobile-user");
        assert_eq!(cached.messages[0].provider_item_id, None);
        assert_eq!(cached.messages[1].id, "msg-agent");
        assert_eq!(cached.messages[1].provider_item_id, None);

        let detail = time::timeout(Duration::from_secs(3), async {
            loop {
                let detail = state.session("alias-detail").await.unwrap().unwrap();
                if detail.messages[0].provider_item_id.as_deref() == Some("item-1")
                    && detail.messages[1].provider_item_id.as_deref() == Some("item-2")
                {
                    break detail;
                }
                time::sleep(Duration::from_millis(20)).await;
            }
        })
        .await
        .expect("deferred provider reconciliation must complete");
        assert_eq!(transport.request_count("thread/read"), 1);
        assert_eq!(
            detail.messages[0].provider_item_id.as_deref(),
            Some("item-1")
        );
        assert_eq!(
            detail.messages[1].provider_item_id.as_deref(),
            Some("item-2")
        );
        assert_eq!(
            state
                .store()
                .list_messages("alias-detail")
                .await
                .unwrap()
                .len(),
            2
        );
        state.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn first_send_to_managed_stored_thread_resumes_before_turn_start() {
        let directory = TempDir::new().unwrap();
        let config = test_config(&directory);
        let store = Store::open(&config.database_path).await.unwrap();
        let mut summary = SessionSummary::new(
            "lazy-send",
            directory.path().display().to_string(),
            "Lazy send",
            unix_millis().unwrap(),
        );
        summary.provider_session_id = Some("lazy-send".to_owned());
        summary.runtime_status = Some("WAITING".to_owned());
        summary.model = Some(crate::config::REQUIRED_TEST_MODEL.to_owned());
        summary.reasoning_effort = Some(crate::config::REQUIRED_TEST_EFFORT.to_owned());
        store.upsert_session(summary, None).await.unwrap();
        let transport = Arc::new(FakeTransport::new());
        let state = EngineState::bootstrap_with_transport(
            config,
            store,
            transport.clone(),
            None,
            None,
            "codex-cli test".to_owned(),
            runtime_manifest_schema_probe().unwrap(),
        )
        .await
        .unwrap();
        let acceptance = state
            .submit_command(CommandRequest {
                command_id: None,
                idempotency_key: "lazy-send-command".to_owned(),
                session_id: Some("lazy-send".to_owned()),
                command: CommandKind::SendMessage {
                    content: "continue".to_owned(),
                    client_message_id: "lazy-send-message".to_owned(),
                    attachments: Vec::new(),
                    service_tier: None,
                },
                requested_at: unix_millis().unwrap(),
                trace_id: None,
            })
            .await
            .unwrap();
        let completed = state
            .wait_for_command(&acceptance.command.command_id, Duration::from_secs(3))
            .await
            .unwrap();
        assert_eq!(completed.state, CommandState::Completed);

        {
            let requests = lock_std(&transport.requests);
            let resume_index = requests
                .iter()
                .position(|(method, _)| method == "thread/resume")
                .unwrap();
            let turn_index = requests
                .iter()
                .position(|(method, _)| method == "turn/start")
                .unwrap();
            assert!(resume_index < turn_index);
        }
        state.shutdown().await.unwrap();
    }

    #[test]
    fn commands_without_sessions_are_rejected_except_create() {
        let request = CommandRequest {
            command_id: None,
            idempotency_key: "key".to_owned(),
            session_id: None,
            command: CommandKind::Interrupt,
            requested_at: 1,
            trace_id: None,
        };
        assert!(validate_command_request(&request).is_err());
        let create = CommandRequest {
            command: CommandKind::CreateSession {
                project_path: "/tmp".to_owned(),
                display_name: None,
                model: None,
                reasoning_effort: None,
            },
            ..request
        };
        assert!(validate_command_request(&create).is_ok());
    }

    #[test]
    fn routing_metadata_helpers_are_idempotent_and_preserve_child_identity() {
        let request = CommandRequest {
            command_id: None,
            idempotency_key: "route-key".to_owned(),
            session_id: Some("child-session".to_owned()),
            command: CommandKind::CreateSubagent {
                prompt: "delegate this".to_owned(),
                display_name: None,
                parent_notification_prompt: None,
            },
            requested_at: 1,
            trace_id: None,
        };
        let routed = EngineState::route_targeted_command(request, "parent-session").unwrap();
        assert_eq!(routed.session_id.as_deref(), Some("parent-session"));
        let record = CommandRecord {
            command_id: "command".to_owned(),
            idempotency_key: routed.idempotency_key.clone(),
            session_id: routed.session_id.clone(),
            command: routed.command.clone(),
            state: CommandState::Accepted,
            requested_at: routed.requested_at,
            accepted_at: 1,
            updated_at: 1,
            trace_id: routed.trace_id.clone(),
            lease_generation: None,
            error: None,
        };
        assert_eq!(
            subagent_child_session_id(&record).as_deref(),
            Some("child-session")
        );

        let resumed = EngineState::attach_resume_history_trace(CommandRequest {
            command_id: None,
            idempotency_key: "resume-key".to_owned(),
            session_id: Some("session".to_owned()),
            command: CommandKind::SetMinimized { minimized: false },
            requested_at: 1,
            trace_id: Some("upstream".to_owned()),
        });
        let repeated = EngineState::attach_resume_history_trace(resumed.clone());
        assert_eq!(resumed.trace_id, repeated.trace_id);
        assert!(
            resumed
                .trace_id
                .as_deref()
                .unwrap()
                .starts_with(RESUME_HISTORY_TRACE_PREFIX)
        );
    }

    #[tokio::test]
    async fn create_subagent_starts_first_turn_and_delete_survives_restart() {
        let (directory, state, transport) = test_engine().await;
        create_session(&state, &directory, "subagent-parent", "Parent").await;

        let routed = EngineState::route_targeted_command(
            CommandRequest {
                command_id: None,
                idempotency_key: "create:subagent-child".to_owned(),
                session_id: Some("subagent-child".to_owned()),
                command: CommandKind::CreateSubagent {
                    prompt: "Inspect the delegated flow and report the result.".to_owned(),
                    display_name: Some("Flow inspector".to_owned()),
                    parent_notification_prompt: None,
                },
                requested_at: unix_millis().unwrap(),
                trace_id: None,
            },
            "subagent-parent",
        )
        .unwrap();
        let acceptance = state.submit_command(routed).await.unwrap();
        let completed = state
            .wait_for_command(&acceptance.command.command_id, Duration::from_secs(3))
            .await
            .unwrap();
        assert_eq!(completed.state, CommandState::Completed);

        let child = state.session("subagent-child").await.unwrap().unwrap();
        assert_eq!(child.parent_session_id.as_deref(), Some("subagent-parent"));
        assert_eq!(child.activity_status, ActivityStatus::Working);
        assert_eq!(child.runtime_status.as_deref(), Some("WORKING"));
        assert_eq!(child.message_count, 1);
        assert_eq!(child.messages.len(), 1);
        assert_eq!(
            child.messages[0].content,
            "Inspect the delegated flow and report the result."
        );
        assert!(
            child
                .pending_subagent
                .as_ref()
                .and_then(|pending| pending.child_message_sent_at)
                .is_some()
        );
        assert_eq!(transport.request_count("thread/start"), 2);
        assert_eq!(transport.request_count("turn/start"), 1);
        let (child_thread_start, child_turn_start) = {
            let requests = lock_std(&transport.requests);
            let child_thread_start = requests
                .iter()
                .rposition(|(method, _)| method == "thread/start")
                .unwrap();
            let child_turn_start = requests
                .iter()
                .position(|(method, _)| method == "turn/start")
                .unwrap();
            (child_thread_start, child_turn_start)
        };
        assert!(child_thread_start < child_turn_start);

        let deletion = state
            .submit_command(CommandRequest {
                command_id: None,
                idempotency_key: "delete:subagent-child".to_owned(),
                session_id: Some("subagent-child".to_owned()),
                command: CommandKind::Delete,
                requested_at: unix_millis().unwrap(),
                trace_id: None,
            })
            .await
            .unwrap();
        let deleted = state
            .wait_for_command(&deletion.command.command_id, Duration::from_secs(3))
            .await
            .unwrap();
        assert_eq!(deleted.state, CommandState::Completed);
        assert!(state.session("subagent-child").await.unwrap().is_none());
        assert_eq!(transport.request_count("thread/delete"), 1);

        state.shutdown().await.unwrap();
        let restarted = bootstrap_test_engine(&directory, Arc::new(FakeTransport::new())).await;
        assert!(restarted.session("subagent-child").await.unwrap().is_none());
        restarted.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn permanent_delete_releases_the_provider_writer_without_removing_other_sessions() {
        let directory = TempDir::new().unwrap();
        let config = test_config(&directory);
        let store = Store::open(&config.database_path).await.unwrap();
        let transport = Arc::new(FakeTransport::new());
        let session_creator = Arc::new(FakeTransport::new());
        let state = EngineState::bootstrap_with_transport(
            config,
            store,
            transport.clone(),
            Some(session_creator.clone()),
            None,
            "codex-cli test".to_owned(),
            runtime_manifest_schema_probe().unwrap(),
        )
        .await
        .unwrap();
        create_session(&state, &directory, "writer-delete", "Writer delete").await;
        create_session(&state, &directory, "unrelated-session", "Unrelated").await;
        let thread_id = state
            .session("writer-delete")
            .await
            .unwrap()
            .unwrap()
            .provider_session_id
            .unwrap();
        let creator_unsubscribes_before_delete =
            session_creator.request_count("thread/unsubscribe");
        transport.mark_active_writer(&thread_id);
        session_creator.mark_active_writer(&thread_id);

        let deletion = state
            .submit_command(CommandRequest {
                command_id: None,
                idempotency_key: "delete:active-writer".to_owned(),
                session_id: Some("writer-delete".to_owned()),
                command: CommandKind::Delete,
                requested_at: unix_millis().unwrap(),
                trace_id: None,
            })
            .await
            .unwrap();
        let deleted = state
            .wait_for_command(&deletion.command.command_id, Duration::from_secs(3))
            .await
            .unwrap();

        assert_eq!(deleted.state, CommandState::Completed);
        assert!(state.session("writer-delete").await.unwrap().is_none());
        assert!(state.session("unrelated-session").await.unwrap().is_some());
        assert_eq!(transport.request_count("thread/unsubscribe"), 1);
        assert_eq!(
            session_creator.request_count("thread/unsubscribe"),
            creator_unsubscribes_before_delete + 1
        );
        assert_eq!(transport.request_count("thread/delete"), 1);
        {
            let requests = lock_std(&transport.requests);
            let unsubscribe = requests
                .iter()
                .position(|(method, params)| {
                    method == "thread/unsubscribe"
                        && params.get("threadId").and_then(Value::as_str)
                            == Some(thread_id.as_str())
                })
                .unwrap();
            let delete = requests
                .iter()
                .position(|(method, params)| {
                    method == "thread/delete"
                        && params.get("threadId").and_then(Value::as_str)
                            == Some(thread_id.as_str())
                })
                .unwrap();
            assert!(unsubscribe < delete);
        }
        state.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn permanent_delete_removes_an_orphaned_session_and_survives_restart() {
        let (directory, state, transport) = test_engine().await;
        create_session(&state, &directory, "orphan-delete", "Orphan delete").await;
        let thread_id = state
            .session("orphan-delete")
            .await
            .unwrap()
            .unwrap()
            .provider_session_id
            .unwrap();
        transport.fail_request(
            "thread/delete",
            missing_rollout_rpc("thread/delete", &thread_id),
        );

        let deletion = state
            .submit_command(CommandRequest {
                command_id: None,
                idempotency_key: "delete:orphan-delete".to_owned(),
                session_id: Some("orphan-delete".to_owned()),
                command: CommandKind::Delete,
                requested_at: unix_millis().unwrap(),
                trace_id: None,
            })
            .await
            .unwrap();
        let deleted = state
            .wait_for_command(&deletion.command.command_id, Duration::from_secs(3))
            .await
            .unwrap();
        assert_eq!(deleted.state, CommandState::Completed);
        assert!(state.session("orphan-delete").await.unwrap().is_none());
        assert_eq!(transport.request_count("thread/delete"), 1);

        state.shutdown().await.unwrap();
        let restarted = bootstrap_test_engine(&directory, Arc::new(FakeTransport::new())).await;
        assert!(restarted.session("orphan-delete").await.unwrap().is_none());
        restarted.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn permanent_delete_does_not_hide_unrelated_invalid_requests() {
        let (directory, state, transport) = test_engine().await;
        create_session(&state, &directory, "invalid-delete", "Invalid delete").await;
        transport.fail_request(
            "thread/delete",
            AppServerError::Rpc {
                method: "thread/delete".to_owned(),
                code: -32600,
                message: "invalid params: threadId has the wrong shape".to_owned(),
                data: None,
            },
        );

        let deletion = state
            .submit_command(CommandRequest {
                command_id: None,
                idempotency_key: "delete:invalid-delete".to_owned(),
                session_id: Some("invalid-delete".to_owned()),
                command: CommandKind::Delete,
                requested_at: unix_millis().unwrap(),
                trace_id: None,
            })
            .await
            .unwrap();
        let rejected = state
            .wait_for_command(&deletion.command.command_id, Duration::from_secs(3))
            .await
            .unwrap();
        assert_eq!(rejected.state, CommandState::Unknown);
        assert!(state.session("invalid-delete").await.unwrap().is_some());
        state.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn archive_does_not_resume_and_completes_when_the_rollout_is_already_absent() {
        let (directory, state, transport) = test_engine().await;
        create_session(&state, &directory, "orphan-archive", "Orphan archive").await;
        let thread_id = state
            .session("orphan-archive")
            .await
            .unwrap()
            .unwrap()
            .provider_session_id
            .unwrap();
        state
            .reduce_notification(
                transport.epoch(),
                "thread/closed",
                json!({ "threadId": thread_id }),
            )
            .await
            .unwrap();
        transport.fail_request(
            "thread/archive",
            missing_rollout_rpc("thread/archive", &thread_id),
        );

        let archive = state
            .submit_command(CommandRequest {
                command_id: None,
                idempotency_key: "archive:orphan-archive".to_owned(),
                session_id: Some("orphan-archive".to_owned()),
                command: CommandKind::Archive,
                requested_at: unix_millis().unwrap(),
                trace_id: None,
            })
            .await
            .unwrap();
        let archived = state
            .wait_for_command(&archive.command.command_id, Duration::from_secs(3))
            .await
            .unwrap();
        assert_eq!(archived.state, CommandState::Completed);
        assert_eq!(transport.request_count("thread/resume"), 0);
        assert_eq!(transport.request_count("thread/archive"), 1);
        let summary = state
            .core
            .store
            .get_session("orphan-archive")
            .await
            .unwrap()
            .unwrap()
            .session;
        assert_eq!(summary.runtime_status.as_deref(), Some("ARCHIVED"));
        assert!(!summary.can_send);
        state.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn thread_closed_unloads_without_archiving_or_deleting_the_session() {
        let (directory, state, transport) = test_engine().await;
        create_session(&state, &directory, "closed-thread", "Keep after close").await;
        let thread_id = state
            .session("closed-thread")
            .await
            .unwrap()
            .unwrap()
            .provider_session_id
            .unwrap();
        assert!(
            state
                .runtime_session("closed-thread")
                .await
                .unwrap()
                .appserver_loaded
        );

        state
            .reduce_notification(
                transport.epoch(),
                "thread/closed",
                json!({ "threadId": thread_id }),
            )
            .await
            .unwrap();

        let preserved = state.session("closed-thread").await.unwrap().unwrap();
        assert_ne!(preserved.runtime_status.as_deref(), Some("ARCHIVED"));
        assert!(
            !state
                .runtime_session("closed-thread")
                .await
                .unwrap()
                .appserver_loaded
        );
        state.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn steer_reconciles_the_authoritative_active_turn_before_rpc() {
        let (directory, state, transport) = test_engine().await;
        create_session(&state, &directory, "steer-current", "Steer current").await;
        let summary = state.session("steer-current").await.unwrap().unwrap();
        let thread_id = summary.provider_session_id.unwrap();
        transport.seed_thread_read(
            &thread_id,
            json!({
                "thread": {
                    "id": thread_id,
                    "cwd": directory.path(),
                    "createdAt": 1,
                    "updatedAt": 2,
                    "status": { "type": "active" },
                    "turns": [{
                        "id": "turn-authoritative",
                        "status": "inProgress",
                        "items": []
                    }]
                }
            }),
        );
        state
            .set_active_turn("steer-current", Some("turn-stale".to_owned()))
            .await;
        let baseline_turn_starts = transport.request_count("turn/start");

        let acceptance = state
            .submit_command(CommandRequest {
                command_id: None,
                idempotency_key: "steer-current-command".to_owned(),
                session_id: Some("steer-current".to_owned()),
                command: CommandKind::Steer {
                    content: "Keep the current turn focused".to_owned(),
                },
                requested_at: unix_millis().unwrap(),
                trace_id: None,
            })
            .await
            .unwrap();
        let completed = state
            .wait_for_command(&acceptance.command.command_id, Duration::from_secs(3))
            .await
            .unwrap();

        assert_eq!(completed.state, CommandState::Completed);
        assert_eq!(transport.request_count("thread/read"), 1);
        assert_eq!(transport.request_count("turn/steer"), 1);
        assert_eq!(transport.request_count("turn/start"), baseline_turn_starts);
        let steer_params = lock_std(&transport.requests)
            .iter()
            .find(|(method, _)| method == "turn/steer")
            .map(|(_, params)| params.clone())
            .unwrap();
        assert_eq!(
            steer_params.get("expectedTurnId").and_then(Value::as_str),
            Some("turn-authoritative")
        );
        state.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn stale_steer_starts_a_new_turn_without_dropping_the_prompt() {
        let (directory, state, transport) = test_engine().await;
        create_session(&state, &directory, "steer-idle", "Steer idle").await;
        let summary = state.session("steer-idle").await.unwrap().unwrap();
        let thread_id = summary.provider_session_id.unwrap();
        transport.seed_thread_read(
            &thread_id,
            json!({
                "thread": {
                    "id": thread_id,
                    "cwd": directory.path(),
                    "createdAt": 1,
                    "updatedAt": 2,
                    "status": { "type": "idle" },
                    "turns": []
                }
            }),
        );
        state
            .set_active_turn("steer-idle", Some("turn-stale".to_owned()))
            .await;
        let baseline_turn_starts = transport.request_count("turn/start");

        let acceptance = state
            .submit_command(CommandRequest {
                command_id: None,
                idempotency_key: "steer-idle-command".to_owned(),
                session_id: Some("steer-idle".to_owned()),
                command: CommandKind::Steer {
                    content: "Do not lose this prompt".to_owned(),
                },
                requested_at: unix_millis().unwrap(),
                trace_id: None,
            })
            .await
            .unwrap();
        let completed = state
            .wait_for_command(&acceptance.command.command_id, Duration::from_secs(3))
            .await
            .unwrap();

        assert_eq!(completed.state, CommandState::Completed);
        assert_eq!(transport.request_count("thread/read"), 1);
        assert_eq!(transport.request_count("turn/steer"), 0);
        assert_eq!(
            transport.request_count("turn/start"),
            baseline_turn_starts + 1
        );
        let fallback_id = format!("steer-fallback-{}", acceptance.command.command_id);
        let stored = state.store().list_messages("steer-idle").await.unwrap();
        assert!(stored.iter().any(|message| {
            message.message.id == fallback_id
                && message.message.content == "Do not lose this prompt"
        }));
        state.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn durable_submit_is_idempotent_parallel_and_gap_free() {
        let (directory, state, transport) = test_engine().await;
        create_session(&state, &directory, "session-a", "Alpha").await;
        create_session(&state, &directory, "session-b", "Beta").await;

        let send_a = CommandRequest {
            command_id: None,
            idempotency_key: "send-a".to_owned(),
            session_id: Some("session-a".to_owned()),
            command: CommandKind::SendMessage {
                content: "alpha request".to_owned(),
                client_message_id: "message-a".to_owned(),
                attachments: Vec::new(),
                service_tier: None,
            },
            requested_at: unix_millis().unwrap(),
            trace_id: None,
        };
        let first = state.submit_command(send_a.clone()).await.unwrap();
        let duplicate = state.submit_command(send_a).await.unwrap();
        assert!(first.inserted);
        assert!(!duplicate.inserted);
        assert_eq!(first.command.command_id, duplicate.command.command_id);

        let send_b = state
            .submit_command(CommandRequest {
                command_id: None,
                idempotency_key: "send-b".to_owned(),
                session_id: Some("session-b".to_owned()),
                command: CommandKind::SendMessage {
                    content: "beta request".to_owned(),
                    client_message_id: "message-b".to_owned(),
                    attachments: Vec::new(),
                    service_tier: None,
                },
                requested_at: unix_millis().unwrap(),
                trace_id: None,
            })
            .await
            .unwrap();
        let (completed_a, completed_b) = tokio::join!(
            state.wait_for_command(&first.command.command_id, Duration::from_secs(3)),
            state.wait_for_command(&send_b.command.command_id, Duration::from_secs(3)),
        );
        assert_eq!(completed_a.unwrap().state, CommandState::Completed);
        assert_eq!(completed_b.unwrap().state, CommandState::Completed);
        assert_eq!(transport.request_count("turn/start"), 2);
        assert!(transport.max_in_flight_turns.load(Ordering::Acquire) >= 2);

        let replay = state.replay_events(0, 10_000).await.unwrap();
        assert!(!replay.is_empty());
        for (offset, event) in replay.iter().enumerate() {
            assert_eq!(event.global_sequence, offset as u64 + 1);
        }
        state.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn goal_toggle_without_objective_sets_native_goal_and_durable_objective() {
        let (directory, state, transport) = test_engine().await;
        create_session(&state, &directory, "goal-session", "Ship verified feature").await;
        let acceptance = state
            .submit_command(CommandRequest {
                command_id: None,
                idempotency_key: "goal-on".to_owned(),
                session_id: Some("goal-session".to_owned()),
                command: CommandKind::SetRunMode {
                    run_mode: RunMode::Goal,
                    objective: None,
                },
                requested_at: unix_millis().unwrap(),
                trace_id: None,
            })
            .await
            .unwrap();
        let completed = state
            .wait_for_command(&acceptance.command.command_id, Duration::from_secs(3))
            .await
            .unwrap();
        assert_eq!(completed.state, CommandState::Completed);
        let objective = tokio::fs::read_to_string(state.goal_objective_path("goal-session"))
            .await
            .unwrap();
        assert!(objective.contains("Ship verified feature"));
        assert_eq!(transport.request_count("thread/goal/set"), 1);
        assert_eq!(transport.request_count("thread/goal/get"), 1);
        let enabled = state.session("goal-session").await.unwrap().unwrap();
        assert_eq!(enabled.run_mode, RunMode::Goal);
        assert_eq!(enabled.goal_started_at, Some(1_000));
        assert_eq!(
            enabled.goal.as_ref().map(|goal| goal.status.as_str()),
            Some("active")
        );
        let disable = state
            .submit_command(CommandRequest {
                command_id: None,
                idempotency_key: "goal-off".to_owned(),
                session_id: Some("goal-session".to_owned()),
                command: CommandKind::SetRunMode {
                    run_mode: RunMode::Default,
                    objective: None,
                },
                requested_at: unix_millis().unwrap(),
                trace_id: None,
            })
            .await
            .unwrap();
        assert_eq!(
            state
                .wait_for_command(&disable.command.command_id, Duration::from_secs(3))
                .await
                .unwrap()
                .state,
            CommandState::Completed
        );
        assert_eq!(transport.request_count("thread/goal/clear"), 1);
        assert_eq!(transport.request_count("thread/goal/get"), 2);
        assert!(!state.goal_objective_path("goal-session").exists());
        state.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn pinned_state_is_durable_and_last_accepted_change_wins() {
        let (directory, state, transport) = test_engine().await;
        create_session(&state, &directory, "pinned-session", "Pinned session").await;
        assert!(
            state
                .session("pinned-session")
                .await
                .unwrap()
                .unwrap()
                .is_pinned
        );

        for (index, pinned) in [false, true, false].into_iter().enumerate() {
            let acceptance = state
                .submit_command(CommandRequest {
                    command_id: None,
                    idempotency_key: format!("pin-change-{index}"),
                    session_id: Some("pinned-session".to_owned()),
                    command: CommandKind::SetPinned { pinned },
                    requested_at: unix_millis().unwrap(),
                    trace_id: None,
                })
                .await
                .unwrap();
            assert_eq!(
                state
                    .wait_for_command(&acceptance.command.command_id, Duration::from_secs(3))
                    .await
                    .unwrap()
                    .state,
                CommandState::Completed
            );
            assert_eq!(
                state
                    .session("pinned-session")
                    .await
                    .unwrap()
                    .unwrap()
                    .is_pinned,
                pinned
            );
        }

        state.shutdown().await.unwrap();
        let restarted = bootstrap_test_engine(&directory, transport).await;
        assert!(
            !restarted
                .session("pinned-session")
                .await
                .unwrap()
                .unwrap()
                .is_pinned
        );
        restarted.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn native_goal_get_and_notifications_reconcile_canonical_status() {
        let (directory, state, transport) = test_engine().await;
        create_session(&state, &directory, "goal-reconcile", "Canonical goal").await;
        let summary = state.session("goal-reconcile").await.unwrap().unwrap();
        let thread_id = summary.provider_session_id.unwrap();
        transport.seed_goal(&thread_id, "Recover the native objective", "paused");
        let response = transport.thread_response(
            "thread/resume",
            &json!({
                "threadId": thread_id,
                "model": crate::config::REQUIRED_TEST_MODEL,
                "effort": crate::config::REQUIRED_TEST_EFFORT,
            }),
        );
        state
            .reconcile_thread(response.get("thread").unwrap(), Some("goal-reconcile"))
            .await
            .unwrap();
        let resumed = state.session("goal-reconcile").await.unwrap().unwrap();
        assert_eq!(resumed.run_mode, RunMode::Goal);
        assert_eq!(resumed.goal_started_at, Some(10_000));
        assert_eq!(resumed.goal.as_ref().unwrap().status, "paused");
        assert_eq!(
            tokio::fs::read_to_string(state.goal_objective_path("goal-reconcile"))
                .await
                .unwrap(),
            "Recover the native objective"
        );

        transport.seed_goal(&thread_id, "Recover the native objective", "budgetLimited");
        state
            .reduce_notification(
                transport.epoch(),
                "thread/goal/updated",
                json!({
                    "threadId": thread_id,
                    "turnId": null,
                    "goal": {
                        "threadId": thread_id,
                        "objective": "Recover the native objective",
                        "status": "active",
                        "tokenBudget": 10_000,
                        "tokensUsed": 10_000,
                        "timeUsedSeconds": 30,
                        "createdAt": 10,
                        "updatedAt": 30
                    }
                }),
            )
            .await
            .unwrap();
        let limited = state.session("goal-reconcile").await.unwrap().unwrap();
        assert_eq!(limited.goal_started_at, Some(10_000));
        assert_eq!(limited.goal.as_ref().unwrap().status, "budgetLimited");

        transport.seed_goal(&thread_id, "Recover the native objective", "complete");
        state
            .reduce_notification(
                transport.epoch(),
                "thread/goal/cleared",
                json!({ "threadId": thread_id }),
            )
            .await
            .unwrap();
        let stale_clear = state.session("goal-reconcile").await.unwrap().unwrap();
        assert_eq!(stale_clear.run_mode, RunMode::Goal);
        assert_eq!(stale_clear.goal.as_ref().unwrap().status, "complete");

        transport.clear_goal(&thread_id);
        state
            .reduce_notification(
                transport.epoch(),
                "thread/goal/cleared",
                json!({ "threadId": thread_id }),
            )
            .await
            .unwrap();
        let cleared = state.session("goal-reconcile").await.unwrap().unwrap();
        assert_eq!(cleared.run_mode, RunMode::Default);
        assert!(cleared.goal.is_none());
        assert_eq!(cleared.goal_started_at, None);
        assert!(!state.goal_objective_path("goal-reconcile").exists());
        state.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn fast_message_sets_and_normal_message_clears_app_server_service_tier() {
        let (directory, state, transport) = test_engine().await;
        create_session(&state, &directory, "fast-session", "Fast session").await;
        let acceptance = state
            .submit_command(CommandRequest {
                command_id: None,
                idempotency_key: "fast-message".to_owned(),
                session_id: Some("fast-session".to_owned()),
                command: CommandKind::SendMessage {
                    content: "Use the verified fast tier".to_owned(),
                    client_message_id: "fast-message-id".to_owned(),
                    attachments: Vec::new(),
                    service_tier: Some("fast".to_owned()),
                },
                requested_at: unix_millis().unwrap(),
                trace_id: None,
            })
            .await
            .unwrap();
        assert_eq!(
            state
                .wait_for_command(&acceptance.command.command_id, Duration::from_secs(3))
                .await
                .unwrap()
                .state,
            CommandState::Completed
        );
        {
            let requests = lock_std(&transport.requests);
            let (_, params) = requests
                .iter()
                .rev()
                .find(|(method, _)| method == "turn/start")
                .unwrap();
            assert_eq!(params["serviceTier"], "fast");
        }

        let normal = state
            .submit_command(CommandRequest {
                command_id: None,
                idempotency_key: "normal-message".to_owned(),
                session_id: Some("fast-session".to_owned()),
                command: CommandKind::SendMessage {
                    content: "Return to the standard service tier".to_owned(),
                    client_message_id: "normal-message-id".to_owned(),
                    attachments: Vec::new(),
                    service_tier: None,
                },
                requested_at: unix_millis().unwrap(),
                trace_id: None,
            })
            .await
            .unwrap();
        assert_eq!(
            state
                .wait_for_command(&normal.command.command_id, Duration::from_secs(3))
                .await
                .unwrap()
                .state,
            CommandState::Completed
        );
        {
            let requests = lock_std(&transport.requests);
            let tiers = requests
                .iter()
                .filter(|(method, _)| method == "turn/start")
                .map(|(_, params)| params["serviceTier"].clone())
                .collect::<Vec<_>>();
            assert_eq!(tiers, vec![Value::String("fast".to_owned()), Value::Null]);
        }
        state.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn invalid_service_tier_is_rejected_before_durable_or_message_side_effects() {
        let (directory, state, transport) = test_engine().await;
        create_session(&state, &directory, "invalid-tier", "Invalid tier").await;
        let command_id = "invalid-tier-command";
        let error = state
            .submit_command(CommandRequest {
                command_id: Some(command_id.to_owned()),
                idempotency_key: "invalid-service-tier".to_owned(),
                session_id: Some("invalid-tier".to_owned()),
                command: CommandKind::SendMessage {
                    content: "This must never be persisted".to_owned(),
                    client_message_id: "invalid-tier-message".to_owned(),
                    attachments: Vec::new(),
                    service_tier: Some("unsupported".to_owned()),
                },
                requested_at: unix_millis().unwrap(),
                trace_id: None,
            })
            .await
            .unwrap_err();
        assert!(matches!(error, EngineError::UnsupportedCommand(_)));
        assert!(
            state
                .store()
                .get_command(command_id)
                .await
                .unwrap()
                .is_none()
        );
        assert!(
            state
                .store()
                .list_messages("invalid-tier")
                .await
                .unwrap()
                .is_empty()
        );
        assert_eq!(transport.request_count("turn/start"), 0);
        state.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn oversized_native_goal_is_rejected_before_durable_or_file_side_effects() {
        let (directory, state, transport) = test_engine().await;
        create_session(&state, &directory, "oversized-goal", "Oversized goal").await;
        let command_id = "oversized-goal-command";
        let error = state
            .submit_command(CommandRequest {
                command_id: Some(command_id.to_owned()),
                idempotency_key: "oversized-goal".to_owned(),
                session_id: Some("oversized-goal".to_owned()),
                command: CommandKind::SetRunMode {
                    run_mode: RunMode::Goal,
                    objective: Some("x".repeat(MAX_NATIVE_GOAL_OBJECTIVE_CHARS + 1)),
                },
                requested_at: unix_millis().unwrap(),
                trace_id: None,
            })
            .await
            .unwrap_err();

        assert!(matches!(error, EngineError::UnsupportedCommand(_)));
        assert!(
            state
                .store()
                .get_command(command_id)
                .await
                .unwrap()
                .is_none()
        );
        assert!(!state.goal_objective_path("oversized-goal").exists());
        assert_eq!(transport.request_count("thread/goal/set"), 0);
        state.shutdown().await.unwrap();
    }

    #[test]
    fn schema_method_collector_reads_generated_request_shapes() {
        let schema = json!({
            "oneOf": [{
                "properties": {
                    "method": { "enum": ["thread/goal/set"] },
                    "params": { "type": "object" }
                }
            }, {
                "properties": {
                    "method": { "const": "turn/start" }
                }
            }]
        });
        let mut methods = HashSet::new();
        collect_schema_methods(&schema, &mut methods);
        assert!(methods.contains("thread/goal/set"));
        assert!(methods.contains("turn/start"));
    }

    #[test]
    fn changed_schema_hash_is_accepted_when_required_contract_remains_present() {
        let required = runtime_manifest_methods("requiredMethods").unwrap();
        let optional = runtime_manifest_methods("optionalMethods").unwrap();
        let request_schema = json!({
            "oneOf": required
                .iter()
                .chain(optional.iter())
                .map(|method| json!({
                    "properties": { "method": { "const": method } }
                }))
                .collect::<Vec<_>>()
        });

        let probe =
            validate_runtime_schema_contract(br#"{"version":"newer"}"#, &request_schema).unwrap();

        assert!(!probe.baseline_schema_match);
        assert!(probe.capabilities.supports_native_goals());
        assert!(probe.capabilities.supports_thread_settings_update());
    }

    #[test]
    fn changed_schema_still_fails_closed_when_a_required_method_disappears() {
        let mut required = runtime_manifest_methods("requiredMethods").unwrap();
        required.retain(|method| method != "thread/delete");
        let request_schema = json!({
            "oneOf": required
                .iter()
                .map(|method| json!({
                    "properties": { "method": { "const": method } }
                }))
                .collect::<Vec<_>>()
        });

        let error = match validate_runtime_schema_contract(
            br#"{"version":"incompatible"}"#,
            &request_schema,
        ) {
            Ok(_) => panic!("schema without thread/delete must be rejected"),
            Err(error) => error,
        };

        assert!(error.to_string().contains("thread/delete"));
    }

    #[test]
    fn runtime_manifest_requires_thread_settings_update() {
        let probe = runtime_manifest_schema_probe().unwrap();
        assert!(probe.capabilities.supports_thread_settings_update());
        assert!(
            runtime_manifest_methods("requiredMethods")
                .unwrap()
                .iter()
                .any(|method| method == THREAD_SETTINGS_UPDATE_METHOD)
        );
    }

    #[tokio::test]
    async fn unmaterialized_relay_attachment_never_reaches_app_server() {
        let (directory, state, transport) = test_engine().await;
        create_session(
            &state,
            &directory,
            "attachment-session",
            "Attachment safety",
        )
        .await;
        let acceptance = state
            .submit_command(CommandRequest {
                command_id: None,
                idempotency_key: "relay-attachment".to_owned(),
                session_id: Some("attachment-session".to_owned()),
                command: CommandKind::SendMessage {
                    content: "inspect image".to_owned(),
                    client_message_id: "relay-image-message".to_owned(),
                    attachments: vec![crate::protocol::ImageAttachment {
                        id: "relay-image".to_owned(),
                        name: "image.png".to_owned(),
                        path: Some("relay://opaque-image.png".to_owned()),
                        size: 8,
                        mime_type: "image/png".to_owned(),
                        preview_data: None,
                    }],
                    service_tier: None,
                },
                requested_at: unix_millis().unwrap(),
                trace_id: None,
            })
            .await
            .unwrap();
        let completed = state
            .wait_for_command(&acceptance.command.command_id, Duration::from_secs(3))
            .await
            .unwrap();
        assert_eq!(completed.state, CommandState::Failed);
        assert_eq!(transport.request_count("turn/start"), 0);
        assert!(
            state
                .store()
                .list_messages("attachment-session")
                .await
                .unwrap()
                .is_empty()
        );
        state.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn authenticated_relay_attachment_is_materialized_only_for_app_server() {
        let directory = TempDir::new().unwrap();
        let token = format!("{}.png", uuid::Uuid::new_v4());
        let image = vec![0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a];
        let served_token = token.clone();
        let served_image = image.clone();
        let router = axum::Router::new().route(
            "/v1/engine/attachments/{token}",
            axum::routing::get(
                move |axum::extract::Path(requested): axum::extract::Path<String>,
                      headers: axum::http::HeaderMap| {
                    let token = served_token.clone();
                    let image = served_image.clone();
                    async move {
                        use axum::response::IntoResponse;
                        let authorized = headers
                            .get(axum::http::header::AUTHORIZATION)
                            .and_then(|value| value.to_str().ok())
                            == Some("Bearer engine-token-0123456789abcdef-0123456789abcdef");
                        if requested != token || !authorized {
                            return axum::http::StatusCode::UNAUTHORIZED.into_response();
                        }
                        ([(axum::http::header::CONTENT_TYPE, "image/png")], image).into_response()
                    }
                },
            ),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });

        let engine_token_file = directory.path().join("engine-token");
        write_private_file(
            &engine_token_file,
            b"engine-token-0123456789abcdef-0123456789abcdef",
        )
        .await
        .unwrap();
        let mut config = test_config(&directory);
        config.relay = Some(crate::config::RelayClientConfig {
            url: format!("ws://{address}/v1/engine/connect"),
            token_file: engine_token_file,
            reconnect_min_ms: 50,
            reconnect_max_ms: 100,
        });
        let store = Store::open(&config.database_path).await.unwrap();
        let transport = Arc::new(FakeTransport::new());
        let state = EngineState::bootstrap_with_transport(
            config,
            store,
            transport.clone(),
            None,
            None,
            "codex-cli test".to_owned(),
            runtime_manifest_schema_probe().unwrap(),
        )
        .await
        .unwrap();
        create_session(&state, &directory, "relay-image-session", "Relay image").await;
        let acceptance = state
            .submit_command(CommandRequest {
                command_id: None,
                idempotency_key: "valid-relay-attachment".to_owned(),
                session_id: Some("relay-image-session".to_owned()),
                command: CommandKind::SendMessage {
                    content: "inspect image".to_owned(),
                    client_message_id: "relay-image-message".to_owned(),
                    attachments: vec![crate::protocol::ImageAttachment {
                        id: "relay-image".to_owned(),
                        name: "image.png".to_owned(),
                        path: Some(format!("relay://{token}")),
                        size: image.len() as u64,
                        mime_type: "image/png".to_owned(),
                        preview_data: None,
                    }],
                    service_tier: None,
                },
                requested_at: unix_millis().unwrap(),
                trace_id: None,
            })
            .await
            .unwrap();
        let completed = state
            .wait_for_command(&acceptance.command.command_id, Duration::from_secs(3))
            .await
            .unwrap();
        assert_eq!(completed.state, CommandState::Completed);
        let turn = lock_std(&transport.requests)
            .iter()
            .find(|(method, _)| method == "turn/start")
            .map(|(_, params)| params.clone())
            .expect("turn/start request");
        let local_path = turn
            .pointer("/input/1/path")
            .and_then(Value::as_str)
            .expect("materialized localImage path");
        assert!(!local_path.starts_with(RELAY_ATTACHMENT_PREFIX));
        assert_eq!(tokio::fs::read(local_path).await.unwrap(), image);
        let durable = state
            .store()
            .list_messages("relay-image-session")
            .await
            .unwrap()
            .into_iter()
            .find(|stored| stored.message.id == "relay-image-message")
            .expect("durable user message");
        assert_eq!(
            durable.message.image_attachments[0].path.as_deref(),
            Some(format!("relay://{token}").as_str())
        );
        state.shutdown().await.unwrap();
        server.abort();
        let _ = server.await;
    }

    #[tokio::test]
    async fn repeated_user_items_emit_distinct_durable_message_patches() {
        let (directory, state, _) = test_engine().await;
        create_session(&state, &directory, "message-session", "Repeated messages").await;
        let now = unix_millis().unwrap();
        let mut local = Message::user("local-message", "same text", now);
        local.message_type = Some("localUserMessage".to_owned());
        state
            .persist_message_patch("message-session", local, 1, now, true)
            .await
            .unwrap();

        let echoed_local = json!({
            "id": "server-echo",
            "type": "userMessage",
            "content": [{"type": "text", "text": "same text"}]
        });
        state
            .persist_appserver_user_message("message-session", &echoed_local, now + 1)
            .await
            .unwrap();
        state
            .persist_appserver_user_message("message-session", &echoed_local, now + 1)
            .await
            .unwrap();
        for (id, timestamp) in [("steer-one", now + 2), ("steer-two", now + 3)] {
            let item = json!({
                "id": id,
                "type": "userMessage",
                "content": [{"type": "text", "text": "same text"}]
            });
            state
                .persist_appserver_user_message("message-session", &item, timestamp)
                .await
                .unwrap();
        }
        let replayed = json!({
            "id": "steer-two",
            "type": "userMessage",
            "content": [{"type": "text", "text": "same text"}]
        });
        state
            .persist_appserver_user_message("message-session", &replayed, now + 4)
            .await
            .unwrap();

        let messages = state
            .store()
            .list_messages("message-session")
            .await
            .unwrap();
        assert_eq!(messages.len(), 3);
        assert_eq!(
            messages
                .iter()
                .filter(|stored| stored.message.content == "same text")
                .count(),
            3
        );
        assert!(messages.iter().any(|stored| {
            stored.message.id == "local-message"
                && stored.message.message_type.as_deref() == Some("userMessage")
                && stored.message.provider_item_id.as_deref() == Some("server-echo")
                && stored.revision == 2
        }));
        assert!(
            messages
                .iter()
                .any(|stored| { stored.message.id == "steer-one" && stored.revision == 1 })
        );
        assert!(
            messages
                .iter()
                .any(|stored| { stored.message.id == "steer-two" && stored.revision == 1 })
        );
        let patches = state
            .replay_events(0, 10_000)
            .await
            .unwrap()
            .into_iter()
            .filter(|event| event.kind == EventKind::MessagePatch)
            .count();
        assert_eq!(patches, 4);
        state.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn archive_preserves_history_and_resume_unarchives_same_session() {
        let (directory, state, transport) = test_engine().await;
        create_session(&state, &directory, "archive-session", "Keep history").await;
        let send = state
            .submit_command(CommandRequest {
                command_id: None,
                idempotency_key: "archive-message".to_owned(),
                session_id: Some("archive-session".to_owned()),
                command: CommandKind::SendMessage {
                    content: "durable history".to_owned(),
                    client_message_id: "archive-message-id".to_owned(),
                    attachments: Vec::new(),
                    service_tier: None,
                },
                requested_at: unix_millis().unwrap(),
                trace_id: None,
            })
            .await
            .unwrap();
        assert_eq!(
            state
                .wait_for_command(&send.command.command_id, Duration::from_secs(3))
                .await
                .unwrap()
                .state,
            CommandState::Completed
        );
        let archive = state
            .submit_command(CommandRequest {
                command_id: None,
                idempotency_key: "archive".to_owned(),
                session_id: Some("archive-session".to_owned()),
                command: CommandKind::Archive,
                requested_at: unix_millis().unwrap(),
                trace_id: None,
            })
            .await
            .unwrap();
        assert_eq!(
            state
                .wait_for_command(&archive.command.command_id, Duration::from_secs(3))
                .await
                .unwrap()
                .state,
            CommandState::Completed
        );
        assert!(state.session("archive-session").await.unwrap().is_none());
        assert_eq!(
            state
                .store()
                .list_messages("archive-session")
                .await
                .unwrap()
                .len(),
            1
        );
        let history = state
            .active_session_history(crate::api::SessionHistoryQuery {
                query: String::new(),
                state: crate::api::SessionHistoryState::Archived,
                sort: crate::api::SessionHistorySort::Recent,
                project_path: None,
                from: None,
                to: None,
                offset: 0,
                limit: 10,
                refresh: false,
            })
            .await
            .unwrap();
        assert_eq!(history.items.len(), 1);
        assert_eq!(
            history.items[0].state,
            crate::api::SessionHistoryState::Archived
        );

        let resumed = <EngineState as crate::api::MobileBackend>::resume_history(
            &state,
            "archive-session".to_owned(),
            "resume-archive".to_owned(),
        )
        .await
        .unwrap();
        assert_eq!(
            state
                .wait_for_command(
                    &resumed.acceptance.command.command_id,
                    Duration::from_secs(3)
                )
                .await
                .unwrap()
                .state,
            CommandState::Completed
        );
        assert_eq!(transport.request_count("thread/unarchive"), 1);
        assert_eq!(transport.request_count("thread/resume"), 1);
        let calls = lock_std(&transport.requests).clone();
        let unarchive_index = calls
            .iter()
            .position(|(method, _)| method == "thread/unarchive")
            .expect("thread/unarchive request");
        let resume_index = calls
            .iter()
            .position(|(method, _)| method == "thread/resume")
            .expect("thread/resume request");
        assert!(unarchive_index < resume_index);
        assert!(state.session("archive-session").await.unwrap().is_some());
        assert_eq!(
            state
                .store()
                .list_messages("archive-session")
                .await
                .unwrap()
                .len(),
            1
        );
        state.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn resume_history_recovers_when_unarchive_already_moved_the_rollout() {
        let (directory, state, transport) = test_engine().await;
        create_session(
            &state,
            &directory,
            "already-unarchived",
            "Already unarchived",
        )
        .await;
        let archive = state
            .submit_command(CommandRequest {
                command_id: None,
                idempotency_key: "archive-before-lost-response".to_owned(),
                session_id: Some("already-unarchived".to_owned()),
                command: CommandKind::Archive,
                requested_at: unix_millis().unwrap(),
                trace_id: None,
            })
            .await
            .unwrap();
        assert_eq!(
            state
                .wait_for_command(&archive.command.command_id, Duration::from_secs(3))
                .await
                .unwrap()
                .state,
            CommandState::Completed
        );
        let thread_id = state
            .store()
            .get_session("already-unarchived")
            .await
            .unwrap()
            .unwrap()
            .session
            .provider_session_id
            .unwrap();
        transport.fail_request("thread/unarchive", missing_archived_rollout_rpc(&thread_id));

        let resumed = <EngineState as crate::api::MobileBackend>::resume_history(
            &state,
            "already-unarchived".to_owned(),
            "resume-after-lost-unarchive-response".to_owned(),
        )
        .await
        .unwrap();
        assert_eq!(
            state
                .wait_for_command(
                    &resumed.acceptance.command.command_id,
                    Duration::from_secs(3)
                )
                .await
                .unwrap()
                .state,
            CommandState::Completed
        );
        assert_eq!(transport.request_count("thread/unarchive"), 1);
        assert_eq!(transport.request_count("thread/resume"), 1);
        let summary = state
            .store()
            .get_session("already-unarchived")
            .await
            .unwrap()
            .unwrap()
            .session;
        assert_eq!(summary.runtime_status.as_deref(), Some("WAITING"));
        assert_eq!(summary.activity_status, ActivityStatus::Ready);
        assert!(summary.can_send);
        assert!(state.session("already-unarchived").await.unwrap().is_some());
        state.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn stale_engine_cannot_accept_and_fatal_lifecycle_cancels() {
        let (_directory, state, transport) = test_engine().await;
        let _takeover = state
            .store()
            .acquire_lease(LeaseRequest {
                lease_key: format!("engine:{}", state.core.config.engine_id),
                holder_id: state.core.config.engine_id.clone(),
                now: unix_millis().unwrap(),
                ttl_millis: ENGINE_LEASE_TTL_MILLIS,
                previous_generation: None,
            })
            .await
            .unwrap();
        let error = state
            .submit_command(CommandRequest {
                command_id: Some("must-not-land".to_owned()),
                idempotency_key: "stale-accept".to_owned(),
                session_id: Some("missing".to_owned()),
                command: CommandKind::SetFeatures {
                    features: SessionFeatures::default(),
                },
                requested_at: unix_millis().unwrap(),
                trace_id: None,
            })
            .await
            .unwrap_err();
        assert!(matches!(
            error,
            EngineError::Store(StoreError::StaleFence { .. })
        ));
        assert!(
            state
                .store()
                .get_command("must-not-land")
                .await
                .unwrap()
                .is_none()
        );

        transport.emit(AppServerEvent::Lifecycle {
            epoch: transport.epoch,
            state: AppServerLifecycle::Failed,
            detail: Some("synthetic failure".to_owned()),
        });
        time::timeout(Duration::from_secs(1), state.cancelled())
            .await
            .unwrap();
        assert!(!state.is_ready());
        state.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn bridge_queries_are_strict_and_unknown_requests_are_answered() {
        let (directory, state, transport) = test_engine().await;
        let projects = <EngineState as crate::bridge::BridgeSource>::handle_query(
            &state,
            "projects",
            json!({}),
        )
        .await
        .unwrap();
        assert!(projects.get("items").and_then(Value::as_array).is_some());

        let preview_path = directory.path().join("preview.md");
        tokio::fs::write(&preview_path, "# Safe preview")
            .await
            .unwrap();
        let preview = <EngineState as crate::bridge::BridgeSource>::handle_query(
            &state,
            "filePreview",
            json!({ "path": preview_path }),
        )
        .await
        .unwrap();
        assert_eq!(
            preview.get("content").and_then(Value::as_str),
            Some("# Safe preview")
        );
        assert!(
            <EngineState as crate::bridge::BridgeSource>::handle_query(
                &state,
                "filePreview",
                json!({ "path": preview_path, "extra": true }),
            )
            .await
            .is_err()
        );

        let now = unix_millis().unwrap();
        let mut session = SessionSummary::new("query-session", "project", "Query session", now);
        session.messages = vec![Message::assistant("answer", "ready", now)];
        session.message_count = 1;
        state.store().upsert_session(session, None).await.unwrap();
        state
            .store()
            .upsert_message(
                MessageMutation {
                    session_id: "query-session".to_owned(),
                    message: Message::assistant("answer", "ready", now),
                    revision: 1,
                    updated_at: now,
                    final_: true,
                },
                None,
            )
            .await
            .unwrap();
        let session = <EngineState as crate::bridge::BridgeSource>::handle_query(
            &state,
            "session",
            json!({ "windowId": "query-session" }),
        )
        .await
        .unwrap();
        assert_eq!(session["sessionId"], "query-session");
        assert_eq!(session["messages"][0]["content"], "ready");

        state
            .handle_server_request(
                transport.epoch,
                json!(99),
                "unknown/host/method",
                json!({ "threadId": "unknown-thread" }),
            )
            .await
            .unwrap();
        {
            let errors = lock_std(&transport.response_errors);
            assert_eq!(errors.len(), 1);
            assert_eq!(errors[0].1, -32601);
        }
        state.shutdown().await.unwrap();
    }
}
