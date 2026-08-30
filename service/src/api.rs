use std::convert::Infallible;
use std::future::Future;
use std::path::Path as FsPath;
use std::pin::Pin;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use async_stream::stream;
use axum::body::Body;
use axum::extract::{DefaultBodyLimit, Multipart, Path, Query, State};
use axum::http::header::{
    AUTHORIZATION, CACHE_CONTROL, CONTENT_LENGTH, CONTENT_TYPE, WWW_AUTHENTICATE,
};
use axum::http::{HeaderMap, HeaderValue, Request, StatusCode};
use axum::middleware::{self, Next};
use axum::response::sse::Event;
use axum::response::{IntoResponse, Response, Sse};
use axum::routing::{get, post};
use axum::{Json, Router};
use bytes::Bytes;
use futures_util::{Stream, StreamExt};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;
use thiserror::Error;
use uuid::Uuid;

use crate::features::MAX_NATIVE_GOAL_OBJECTIVE_CHARS;
use crate::protocol::{
    AuthoritativeSnapshot, CommandAcceptance, CommandKind, CommandRecord, CommandRequest,
    CommandState, DurableEvent, ImageAttachment, MOBILE_SCHEMA_VERSION, Millis, ModelCatalog,
    ModelInfo, RunMode, RuntimeModelSettings, Sequence, SessionDetailEnvelope, SessionFeatures,
    SessionSummary, SessionsEnvelope,
};

pub const MAX_JSON_BODY_BYTES: usize = 1024 * 1024;
pub const MAX_MESSAGE_BYTES: usize = 256 * 1024;
pub const MAX_IDENTIFIER_BYTES: usize = 1024;
pub const MAX_PATH_BYTES: usize = 4096;
pub const MAX_ATTACHMENT_COUNT: usize = 10;
pub const MAX_ATTACHMENT_BYTES: usize = 20 * 1024 * 1024;
pub const MAX_ATTACHMENT_TOTAL_BYTES: usize = 50 * 1024 * 1024;
pub const MAX_ATTACHMENT_UPLOAD_BODY_BYTES: usize = MAX_ATTACHMENT_BYTES + 128 * 1024;
pub const MAX_FILE_PREVIEW_BYTES: usize = 10 * 1024 * 1024;
pub const MAX_SSE_EVENT_BYTES: usize = 512 * 1024;
pub const MAX_SSE_SNAPSHOT_BYTES: usize = 4 * 1024 * 1024;
pub const MAX_REPLAY_EVENTS: usize = 256;
pub const MAX_CONFIGURED_BODY_BYTES: usize = 128 * 1024 * 1024;
pub const DEFAULT_HEARTBEAT_INTERVAL: Duration = Duration::from_secs(15);
pub const MAX_HEARTBEAT_INTERVAL: Duration = Duration::from_secs(24);

#[derive(Clone, Debug)]
pub struct MobileApiConfig {
    bearer_digest: [u8; 32],
    heartbeat_interval: Duration,
    replay_limit: usize,
    max_json_body_bytes: usize,
    max_attachment_upload_body_bytes: usize,
}

impl MobileApiConfig {
    pub fn new(bearer_token: impl AsRef<str>) -> Result<Self, MobileApiConfigError> {
        let token = bearer_token.as_ref().trim();
        if token.len() < 32 {
            return Err(MobileApiConfigError::WeakBearerToken);
        }
        Ok(Self {
            bearer_digest: Sha256::digest(token.as_bytes()).into(),
            heartbeat_interval: DEFAULT_HEARTBEAT_INTERVAL,
            replay_limit: MAX_REPLAY_EVENTS,
            max_json_body_bytes: MAX_JSON_BODY_BYTES,
            max_attachment_upload_body_bytes: MAX_ATTACHMENT_UPLOAD_BODY_BYTES,
        })
    }

    pub fn with_heartbeat_interval(
        mut self,
        heartbeat_interval: Duration,
    ) -> Result<Self, MobileApiConfigError> {
        if heartbeat_interval.is_zero() || heartbeat_interval >= MAX_HEARTBEAT_INTERVAL {
            return Err(MobileApiConfigError::InvalidHeartbeat);
        }
        self.heartbeat_interval = heartbeat_interval;
        Ok(self)
    }

    pub fn with_replay_limit(mut self, replay_limit: usize) -> Self {
        self.replay_limit = replay_limit.clamp(1, MAX_REPLAY_EVENTS);
        self
    }

    pub fn with_max_body_bytes(
        mut self,
        max_body_bytes: usize,
    ) -> Result<Self, MobileApiConfigError> {
        if !(MAX_JSON_BODY_BYTES..=MAX_CONFIGURED_BODY_BYTES).contains(&max_body_bytes) {
            return Err(MobileApiConfigError::InvalidBodyLimit);
        }
        self.max_json_body_bytes = MAX_JSON_BODY_BYTES.min(max_body_bytes);
        self.max_attachment_upload_body_bytes =
            MAX_ATTACHMENT_UPLOAD_BODY_BYTES.min(max_body_bytes);
        Ok(self)
    }
}

#[derive(Debug, Error, Eq, PartialEq)]
pub enum MobileApiConfigError {
    #[error("mobile bearer token must contain at least 32 characters")]
    WeakBearerToken,
    #[error("mobile SSE heartbeat must be greater than zero and less than 24 seconds")]
    InvalidHeartbeat,
    #[error("mobile body limit must be between 1 MiB and 128 MiB")]
    InvalidBodyLimit,
}

pub type BackendFuture<'a, T> =
    Pin<Box<dyn Future<Output = Result<T, MobileBackendError>> + Send + 'a>>;
pub type BackendEventStream =
    Pin<Box<dyn Stream<Item = Result<DurableEvent, MobileBackendError>> + Send + 'static>>;

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BackendHealth {
    pub ready: bool,
    pub role: String,
    pub details: Value,
}

impl BackendHealth {
    pub fn ready(role: impl Into<String>) -> Self {
        Self {
            ready: true,
            role: role.into(),
            details: Value::Object(Default::default()),
        }
    }
}

/// Object-safe boundary between HTTP compatibility and the durable engine/store.
///
/// `submit_command` must durably persist the `CommandRequest` before resolving.
/// `target_window_id` preserves the mobile routing identity separately from the
/// protocol session id (notably for create-session and create-subagent). Event
/// streams returned by `subscribe_events` must themselves use bounded queues.
pub trait MobileBackend: Send + Sync {
    fn health(&self) -> BackendFuture<'_, BackendHealth> {
        Box::pin(async { Ok(BackendHealth::ready("backend")) })
    }

    fn snapshot(&self) -> BackendFuture<'_, AuthoritativeSnapshot>;
    fn session(&self, window_id: String) -> BackendFuture<'_, Option<SessionSummary>>;
    fn command(&self, command_id: String) -> BackendFuture<'_, Option<CommandRecord>>;
    fn submit_command(
        &self,
        target_window_id: Option<String>,
        request: CommandRequest,
    ) -> BackendFuture<'_, CommandAcceptance>;
    fn models(&self, window_id: String) -> BackendFuture<'_, ModelCatalog>;
    fn projects(&self) -> BackendFuture<'_, ProjectCatalog>;
    fn prompt_improver_preference(&self) -> BackendFuture<'_, PromptImproverPreferenceRecord>;
    fn set_prompt_improver_preference(
        &self,
        variant: PromptImproverVariant,
    ) -> BackendFuture<'_, PromptImproverPreferenceRecord>;
    fn file_preview(&self, path: String) -> BackendFuture<'_, FilePreview>;
    fn upload_attachment(
        &self,
        window_id: String,
        upload: AttachmentUpload,
    ) -> BackendFuture<'_, ImageAttachment>;
    fn attachment_content(&self, path: String) -> BackendFuture<'_, AttachmentContent>;
    fn session_history(&self, query: SessionHistoryQuery) -> BackendFuture<'_, SessionHistoryPage>;
    fn resume_history(
        &self,
        history_id: String,
        idempotency_key: String,
    ) -> BackendFuture<'_, SessionHistoryResumeResult>;
    fn recoverable_sessions(
        &self,
        query: SessionRecoveryQuery,
    ) -> BackendFuture<'_, SessionRecoveryPage>;
    fn recover_session(
        &self,
        recovery_id: String,
        idempotency_key: String,
    ) -> BackendFuture<'_, SessionRecoveryResult>;
    fn replay_events(
        &self,
        cursor: ReplayCursor,
        limit: usize,
    ) -> BackendFuture<'_, Vec<DurableEvent>>;
    fn subscribe_events(&self) -> Result<BackendEventStream, MobileBackendError>;
}

#[derive(Debug, Error)]
pub enum MobileBackendError {
    #[error("{0}")]
    Invalid(String),
    #[error("{0}")]
    NotFound(String),
    #[error("{0}")]
    Conflict(String),
    #[error("{0}")]
    PayloadTooLarge(String),
    #[error("{0}")]
    UnsupportedMediaType(String),
    #[error("{0}")]
    Unavailable(String),
    #[error("{0}")]
    Internal(String),
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectDirectory {
    pub name: String,
    pub path: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectCatalog {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub root_path: Option<String>,
    pub items: Vec<ProjectDirectory>,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PromptImproverVariant {
    #[default]
    Standard,
    Motivational,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PromptImproverPreferenceRecord {
    pub version: u16,
    pub variant: PromptImproverVariant,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub updated_at: Option<String>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum FilePreviewKind {
    Code,
    Markdown,
    Json,
    Text,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FilePreview {
    pub path: String,
    pub name: String,
    pub content: String,
    pub kind: FilePreviewKind,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub language: Option<String>,
    pub size_bytes: usize,
}

#[derive(Clone)]
pub struct AttachmentUpload {
    pub file_name: String,
    pub mime_type: String,
    pub bytes: Bytes,
}

#[derive(Clone)]
pub struct AttachmentContent {
    pub mime_type: String,
    pub bytes: Bytes,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SessionHistoryState {
    #[default]
    All,
    Active,
    Archived,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SessionHistorySort {
    Relevance,
    #[default]
    Recent,
    Name,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SessionHistoryQuery {
    pub query: String,
    pub state: SessionHistoryState,
    pub sort: SessionHistorySort,
    pub project_path: Option<String>,
    pub from: Option<Millis>,
    pub to: Option<Millis>,
    pub offset: usize,
    pub limit: usize,
    pub refresh: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionHistoryItem {
    pub id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_uuid: Option<String>,
    pub project_key: String,
    pub project_name: String,
    pub session_id: String,
    pub session_name: String,
    pub session_path: String,
    pub created_at: Millis,
    pub updated_at: Millis,
    pub state: SessionHistoryState,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub window_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub archived_id: Option<String>,
    pub score: f64,
    pub preview: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub matched_in: Option<String>,
    pub can_resume: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionHistoryPage {
    pub items: Vec<SessionHistoryItem>,
    pub offset: usize,
    pub limit: usize,
    pub total: usize,
    pub has_more: bool,
    pub updated_at: Millis,
    #[serde(default)]
    pub search_ms: f64,
    #[serde(default)]
    pub index_build_ms: f64,
    #[serde(default)]
    pub indexed_sessions: usize,
    #[serde(default)]
    pub indexed_terms: usize,
}

pub struct SessionHistoryResumeResult {
    pub acceptance: CommandAcceptance,
    pub session_id: String,
    pub window_id: Option<String>,
    pub project_path: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionRecoveryQuery {
    pub query: String,
    pub offset: usize,
    pub limit: usize,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionRecoveryItem {
    pub id: String,
    pub project_name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub project_path: Option<String>,
    pub session_name: String,
    pub created_at: Millis,
    pub updated_at: Millis,
    pub archived: bool,
    pub score: f64,
    pub preview: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub matched_in: Option<String>,
    pub can_recover: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionRecoveryPage {
    pub items: Vec<SessionRecoveryItem>,
    pub offset: usize,
    pub limit: usize,
    pub total: usize,
    pub has_more: bool,
    pub updated_at: Millis,
}

pub struct SessionRecoveryResult {
    pub acceptance: CommandAcceptance,
    pub session_id: String,
    pub window_id: Option<String>,
    pub project_path: Option<String>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ReplayCursor {
    pub last_event_id: Option<String>,
    pub after_global_sequence: Option<Sequence>,
}

#[derive(Clone)]
struct ApiState {
    backend: Arc<dyn MobileBackend>,
    config: MobileApiConfig,
}

pub fn router(backend: Arc<dyn MobileBackend>, config: MobileApiConfig) -> Router {
    let state = ApiState { backend, config };
    let max_json_body_bytes = state.config.max_json_body_bytes;
    let max_attachment_upload_body_bytes = state.config.max_attachment_upload_body_bytes;
    let json_routes = Router::new()
        .route(
            "/api/mobile/sessions",
            get(list_sessions).post(create_session),
        )
        .route(
            "/api/mobile/sessions/{window_id}",
            get(session_detail).delete(archive_session),
        )
        .route(
            "/api/mobile/sessions/{window_id}/archive",
            post(archive_session),
        )
        .route(
            "/api/mobile/sessions/{window_id}/permanent",
            axum::routing::delete(delete_session),
        )
        .route("/api/mobile/commands/{command_id}", get(command_status))
        .route(
            "/api/mobile/sessions/{window_id}/message",
            post(send_message),
        )
        .route(
            "/api/mobile/sessions/{window_id}/steer",
            post(steer_session),
        )
        .route(
            "/api/mobile/sessions/{window_id}/interrupt",
            post(interrupt_session),
        )
        .route(
            "/api/mobile/sessions/{window_id}/run-mode",
            post(set_run_mode),
        )
        .route(
            "/api/mobile/sessions/{window_id}/features",
            post(set_features),
        )
        .route("/api/mobile/sessions/{window_id}/models", get(models))
        .route(
            "/api/mobile/sessions/{window_id}/model-settings",
            post(set_model_settings),
        )
        .route(
            "/api/mobile/sessions/{window_id}/rename",
            post(rename_session)
                .put(rename_session)
                .patch(rename_session),
        )
        .route(
            "/api/mobile/sessions/{window_id}/minimize",
            post(minimize_session),
        )
        .route(
            "/api/mobile/sessions/{window_id}/restore",
            post(restore_session),
        )
        .route(
            "/api/mobile/sessions/{window_id}/pinned",
            post(set_pinned).put(set_pinned),
        )
        .route(
            "/api/mobile/sessions/{window_id}/create-subagent",
            post(create_subagent),
        )
        .route(
            "/api/mobile/sessions/{window_id}/messages/{message_id}/retry-prompt-transform",
            post(retry_prompt_transform),
        )
        .route(
            "/api/mobile/preferences/prompt-improver",
            get(get_prompt_preference)
                .put(set_prompt_preference)
                .post(set_prompt_preference),
        )
        .route("/api/mobile/projects", get(projects))
        .route("/api/mobile/file-preview", post(file_preview))
        .route("/api/mobile/attachments/content", get(attachment_content))
        .route("/api/mobile/session-history", get(session_history))
        .route("/api/mobile/session-history/resume", post(resume_history))
        .route("/api/mobile/session-recovery", get(recoverable_sessions))
        .route(
            "/api/mobile/session-recovery/recover",
            post(recover_session),
        )
        .route("/api/mobile/stream", get(stream_events))
        .layer(DefaultBodyLimit::max(max_json_body_bytes));
    let upload_routes = Router::new()
        .route(
            "/api/mobile/sessions/{window_id}/attachments",
            post(upload_attachment),
        )
        .layer(DefaultBodyLimit::max(max_attachment_upload_body_bytes));
    let protected = Router::new()
        .merge(json_routes)
        .merge(upload_routes)
        .route_layer(middleware::from_fn(private_no_store))
        .route_layer(middleware::from_fn_with_state(
            state.clone(),
            require_bearer,
        ));
    let surface = Router::new()
        .route("/healthz", get(healthz))
        .merge(protected);
    Router::new()
        .merge(surface.clone())
        .nest("/fermin-code", surface.clone())
        .nest("/fermin-code-puky", surface.clone())
        .nest("/sync-hub", surface)
        .with_state(state)
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct HealthEnvelope {
    ok: bool,
    ready: bool,
    service: &'static str,
    version: &'static str,
    schema_version: u16,
    role: String,
    details: Value,
}

async fn healthz(State(state): State<ApiState>) -> Response {
    let backend_health = match state.backend.health().await {
        Ok(health) => health,
        Err(_) => BackendHealth {
            ready: false,
            role: "backend".to_owned(),
            details: json!({"error": "backend health unavailable"}),
        },
    };
    let status = if backend_health.ready {
        StatusCode::OK
    } else {
        StatusCode::SERVICE_UNAVAILABLE
    };
    let envelope = HealthEnvelope {
        ok: backend_health.ready,
        ready: backend_health.ready,
        service: "fermin-code",
        version: env!("CARGO_PKG_VERSION"),
        schema_version: MOBILE_SCHEMA_VERSION,
        role: backend_health.role,
        details: backend_health.details,
    };
    (status, Json(envelope)).into_response()
}

async fn private_no_store(request: Request<Body>, next: Next) -> Response {
    let mut response = next.run(request).await;
    response
        .headers_mut()
        .entry(CACHE_CONTROL)
        .or_insert(HeaderValue::from_static("private, no-store"));
    response
}

async fn require_bearer(
    State(state): State<ApiState>,
    request: Request<Body>,
    next: Next,
) -> Response {
    if bearer_is_authorized(request.headers(), &state.config.bearer_digest) {
        return next.run(request).await;
    }
    let mut response = ApiError::unauthorized().into_response();
    response.headers_mut().insert(
        WWW_AUTHENTICATE,
        HeaderValue::from_static("Bearer realm=\"fermin-code\""),
    );
    response
}

fn bearer_is_authorized(headers: &HeaderMap, expected_digest: &[u8; 32]) -> bool {
    let Some(candidate) = headers
        .get(AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .map(str::trim)
        .filter(|value| !value.is_empty())
    else {
        return false;
    };
    let candidate_digest: [u8; 32] = Sha256::digest(candidate.as_bytes()).into();
    bool::from(candidate_digest.ct_eq(expected_digest))
}

async fn list_sessions(State(state): State<ApiState>) -> Result<Json<SessionsEnvelope>, ApiError> {
    let snapshot = state.backend.snapshot().await.map_err(ApiError::backend)?;
    Ok(Json(sessions_envelope(&snapshot)))
}

async fn session_detail(
    State(state): State<ApiState>,
    Path(window_id): Path<String>,
) -> Result<Json<SessionDetailEnvelope>, ApiError> {
    let window_id = validated_identifier(window_id, "windowId")?;
    let item = state
        .backend
        .session(window_id)
        .await
        .map_err(ApiError::backend)?
        .ok_or_else(|| ApiError::not_found("SESSION_NOT_FOUND", "session not found"))?;
    Ok(Json(SessionDetailEnvelope {
        ok: true,
        now: unix_millis(),
        item,
        cursor: None,
    }))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CreateSessionBody {
    project_path: String,
    #[serde(default)]
    session_id: Option<String>,
    #[serde(default, alias = "displayName")]
    session_name: Option<String>,
    #[serde(default)]
    model: Option<String>,
    #[serde(default)]
    reasoning_effort: Option<String>,
    #[serde(default)]
    idempotency_key: Option<String>,
}

async fn create_session(
    State(state): State<ApiState>,
    Json(body): Json<CreateSessionBody>,
) -> Result<Json<DurableCommandAck>, ApiError> {
    let project_path = validated_path(body.project_path, "projectPath")?;
    if !FsPath::new(&project_path).is_absolute() {
        return Err(ApiError::bad_request(
            "INVALID_PROJECT_PATH",
            "projectPath must be absolute",
        ));
    }
    let session_id = match body.session_id {
        Some(session_id) => validated_identifier(session_id, "sessionId")?,
        None => format!("mobile-{}", Uuid::new_v4()),
    };
    let session_name = optional_bounded(body.session_name, "sessionName", 200)?;
    let model = optional_model(body.model)?;
    let reasoning_effort = optional_bounded(body.reasoning_effort, "reasoningEffort", 32)?;
    let idempotency_key = idempotency_key(body.idempotency_key, Some(&session_id))?;
    let acceptance = submit_command(
        &state,
        None,
        Some(session_id.clone()),
        CommandKind::CreateSession {
            project_path: project_path.clone(),
            display_name: session_name.clone(),
            model,
            reasoning_effort,
        },
        idempotency_key,
    )
    .await?;
    let project_name = FsPath::new(&project_path)
        .file_name()
        .and_then(|value| value.to_str())
        .filter(|value| !value.is_empty())
        .unwrap_or("project")
        .to_owned();
    let mut ack = DurableCommandAck::new(acceptance);
    ack.project_path = Some(project_path);
    ack.project_name = Some(project_name);
    ack.session_id = Some(session_id);
    ack.session_name = session_name;
    Ok(Json(ack))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct MessageBody {
    #[serde(default)]
    message: String,
    #[serde(default)]
    client_message_id: Option<String>,
    #[serde(default)]
    attachments: Vec<MessageAttachmentInput>,
    #[serde(default)]
    features: Option<SessionFeatures>,
    #[serde(default)]
    fast_mode_enabled: Option<bool>,
    #[serde(default)]
    parent_notification_prompt: Option<String>,
    #[serde(default)]
    idempotency_key: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct MessageAttachmentInput {
    #[serde(default)]
    id: Option<String>,
    path: String,
    name: String,
    size: u64,
    mime_type: String,
}

async fn send_message(
    State(state): State<ApiState>,
    Path(window_id): Path<String>,
    Json(body): Json<MessageBody>,
) -> Result<Json<DurableCommandAck>, ApiError> {
    let window_id = validated_identifier(window_id, "windowId")?;
    let content = bounded_trimmed(body.message, "message", MAX_MESSAGE_BYTES, true)?;
    let attachments = validate_message_attachments(body.attachments)?;
    if content.is_empty() && attachments.is_empty() {
        return Err(ApiError::bad_request(
            "EMPTY_MESSAGE",
            "message or attachments is required",
        ));
    }
    let parent_notification_prompt = body
        .parent_notification_prompt
        .map(|prompt| bounded_trimmed(prompt, "parentNotificationPrompt", 64 * 1024, false))
        .transpose()?;
    if let Some(features) = body.features {
        let feature_key = idempotency_key(
            body.idempotency_key
                .as_ref()
                .map(|key| format!("{key}:features")),
            None,
        )?;
        submit_command(
            &state,
            Some(window_id.clone()),
            Some(window_id.clone()),
            CommandKind::SetFeatures { features },
            feature_key,
        )
        .await?;
    }
    let client_message_id = match body.client_message_id {
        Some(id) => validated_identifier(id, "clientMessageId")?,
        None => format!("mobile-user-{}", Uuid::new_v4()),
    };
    let service_tier = if body.fast_mode_enabled == Some(true) {
        Some("fast".to_owned())
    } else {
        None
    };
    let key = idempotency_key(body.idempotency_key, Some(&client_message_id))?;
    let acceptance = submit_command(
        &state,
        Some(window_id.clone()),
        Some(window_id.clone()),
        CommandKind::SendMessage {
            content,
            client_message_id: client_message_id.clone(),
            attachments,
            service_tier,
        },
        key,
    )
    .await?;
    let parent_command_id = if let Some(parent_prompt) = parent_notification_prompt {
        let child = state
            .backend
            .session(window_id.clone())
            .await
            .map_err(ApiError::backend)?
            .ok_or_else(|| ApiError::not_found("SESSION_NOT_FOUND", "session not found"))?;
        let parent_session_id = child.parent_session_id.ok_or_else(|| ApiError {
            status: StatusCode::CONFLICT,
            code: "PARENT_SESSION_NOT_FOUND",
            message: "session has no parent for the coordination notification".to_owned(),
        })?;
        let snapshot = state.backend.snapshot().await.map_err(ApiError::backend)?;
        let parent_target = snapshot
            .sessions
            .iter()
            .find(|session| session.session_id == parent_session_id)
            .map(|session| session.window_id.clone())
            .unwrap_or_else(|| parent_session_id.clone());
        let digest = Sha256::digest(client_message_id.as_bytes());
        let parent_message_id = format!("parent-notification-{digest:x}");
        let parent_acceptance = submit_command(
            &state,
            Some(parent_target),
            Some(parent_session_id),
            CommandKind::SendMessage {
                content: parent_prompt,
                client_message_id: parent_message_id.clone(),
                attachments: Vec::new(),
                service_tier: None,
            },
            parent_message_id,
        )
        .await?;
        Some(parent_acceptance.command.command_id)
    } else {
        None
    };
    let mut ack = DurableCommandAck::new(acceptance);
    ack.window_id = Some(window_id);
    ack.client_message_id = Some(client_message_id);
    ack.parent_command_id = parent_command_id;
    Ok(Json(ack))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SteerBody {
    #[serde(alias = "content")]
    message: String,
    #[serde(default)]
    idempotency_key: Option<String>,
}

async fn steer_session(
    State(state): State<ApiState>,
    Path(window_id): Path<String>,
    Json(body): Json<SteerBody>,
) -> Result<Json<DurableCommandAck>, ApiError> {
    let window_id = validated_identifier(window_id, "windowId")?;
    let content = bounded_trimmed(body.message, "message", MAX_MESSAGE_BYTES, false)?;
    let acceptance = submit_command(
        &state,
        Some(window_id.clone()),
        Some(window_id.clone()),
        CommandKind::Steer { content },
        idempotency_key(body.idempotency_key, None)?,
    )
    .await?;
    let mut ack = DurableCommandAck::new(acceptance);
    ack.window_id = Some(window_id);
    Ok(Json(ack))
}

async fn interrupt_session(
    State(state): State<ApiState>,
    Path(window_id): Path<String>,
) -> Result<Json<DurableCommandAck>, ApiError> {
    let window_id = validated_identifier(window_id, "windowId")?;
    let acceptance = submit_command(
        &state,
        Some(window_id.clone()),
        Some(window_id.clone()),
        CommandKind::Interrupt,
        fresh_idempotency_key(),
    )
    .await?;
    let mut ack = DurableCommandAck::new(acceptance);
    ack.window_id = Some(window_id);
    Ok(Json(ack))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RunModeBody {
    goal_enabled: bool,
    #[serde(default)]
    objective: Option<String>,
    #[serde(default)]
    idempotency_key: Option<String>,
}

async fn set_run_mode(
    State(state): State<ApiState>,
    Path(window_id): Path<String>,
    Json(body): Json<RunModeBody>,
) -> Result<Json<DurableCommandAck>, ApiError> {
    let window_id = validated_identifier(window_id, "windowId")?;
    let objective = optional_bounded(body.objective, "objective", MAX_MESSAGE_BYTES)?;
    if objective
        .as_deref()
        .is_some_and(|objective| objective.chars().count() > MAX_NATIVE_GOAL_OBJECTIVE_CHARS)
    {
        return Err(ApiError::bad_request(
            "GOAL_OBJECTIVE_TOO_LONG",
            format!("objective must contain at most {MAX_NATIVE_GOAL_OBJECTIVE_CHARS} characters"),
        ));
    }
    let run_mode = if body.goal_enabled {
        RunMode::Goal
    } else {
        RunMode::Default
    };
    let acceptance = submit_command(
        &state,
        Some(window_id.clone()),
        Some(window_id.clone()),
        CommandKind::SetRunMode {
            run_mode,
            objective,
        },
        idempotency_key(body.idempotency_key, None)?,
    )
    .await?;
    let mut ack = DurableCommandAck::new(acceptance);
    ack.window_id = Some(window_id);
    ack.run_mode = Some(run_mode);
    ack.goal_started_at = body.goal_enabled.then(unix_millis);
    Ok(Json(ack))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct FeaturesBody {
    #[serde(default)]
    prompt_improver_enabled: Option<bool>,
    #[serde(default)]
    explainer_enabled: Option<bool>,
    #[serde(default)]
    code_context_enabled: Option<bool>,
    #[serde(default)]
    idempotency_key: Option<String>,
}

async fn set_features(
    State(state): State<ApiState>,
    Path(window_id): Path<String>,
    Json(body): Json<FeaturesBody>,
) -> Result<Json<DurableCommandAck>, ApiError> {
    if body.prompt_improver_enabled.is_none()
        && body.explainer_enabled.is_none()
        && body.code_context_enabled.is_none()
    {
        return Err(ApiError::bad_request(
            "EMPTY_FEATURE_PATCH",
            "at least one feature field is required",
        ));
    }
    let window_id = validated_identifier(window_id, "windowId")?;
    let session = state
        .backend
        .session(window_id.clone())
        .await
        .map_err(ApiError::backend)?
        .ok_or_else(|| ApiError::not_found("SESSION_NOT_FOUND", "session not found"))?;
    let features = SessionFeatures {
        prompt_improver_enabled: body
            .prompt_improver_enabled
            .unwrap_or(session.features.prompt_improver_enabled),
        explainer_enabled: body
            .explainer_enabled
            .unwrap_or(session.features.explainer_enabled),
        code_context_enabled: body
            .code_context_enabled
            .unwrap_or(session.features.code_context_enabled),
    };
    let acceptance = submit_command(
        &state,
        Some(window_id.clone()),
        Some(window_id.clone()),
        CommandKind::SetFeatures { features },
        idempotency_key(body.idempotency_key, None)?,
    )
    .await?;
    let mut ack = DurableCommandAck::new(acceptance);
    ack.window_id = Some(window_id);
    Ok(Json(ack))
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ModelCatalogEnvelope {
    ok: bool,
    observed_at: Millis,
    #[serde(skip_serializing_if = "Option::is_none")]
    app_server_version: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    capability_hash: Option<String>,
    data: Vec<ModelInfo>,
}

async fn models(
    State(state): State<ApiState>,
    Path(window_id): Path<String>,
) -> Result<Json<ModelCatalogEnvelope>, ApiError> {
    let window_id = validated_identifier(window_id, "windowId")?;
    let catalog = state
        .backend
        .models(window_id)
        .await
        .map_err(ApiError::backend)?
        .product_filtered();
    Ok(Json(ModelCatalogEnvelope {
        ok: true,
        observed_at: catalog.observed_at,
        app_server_version: catalog.app_server_version,
        capability_hash: catalog.capability_hash,
        data: catalog.models,
    }))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ModelSettingsBody {
    model: String,
    #[serde(default)]
    model_provider: Option<String>,
    reasoning_effort: String,
    #[serde(default)]
    idempotency_key: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ModelSettingsEnvelope {
    ok: bool,
    model_settings: RuntimeModelSettings,
    command: DurableCommandAck,
}

async fn set_model_settings(
    State(state): State<ApiState>,
    Path(window_id): Path<String>,
    Json(body): Json<ModelSettingsBody>,
) -> Result<Json<ModelSettingsEnvelope>, ApiError> {
    let window_id = validated_identifier(window_id, "windowId")?;
    let model = validated_model(body.model)?;
    let provider = body
        .model_provider
        .unwrap_or_else(|| "openai".to_owned())
        .trim()
        .to_ascii_lowercase();
    if provider != "openai" && provider != "codex" {
        return Err(ApiError::bad_request(
            "UNSUPPORTED_MODEL_PROVIDER",
            "only OpenAI/Codex GPT providers are supported",
        ));
    }
    let effort = bounded_trimmed(body.reasoning_effort, "reasoningEffort", 32, false)?;
    let settings = RuntimeModelSettings {
        model,
        model_provider: Some(provider),
        effort,
    };
    let acceptance = submit_command(
        &state,
        Some(window_id.clone()),
        Some(window_id),
        CommandKind::SetModel {
            settings: settings.clone(),
        },
        idempotency_key(body.idempotency_key, None)?,
    )
    .await?;
    Ok(Json(ModelSettingsEnvelope {
        ok: true,
        model_settings: settings,
        command: DurableCommandAck::new(acceptance),
    }))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RenameBody {
    name: String,
    #[serde(default)]
    idempotency_key: Option<String>,
}

async fn rename_session(
    State(state): State<ApiState>,
    Path(window_id): Path<String>,
    Json(body): Json<RenameBody>,
) -> Result<Json<DurableCommandAck>, ApiError> {
    let window_id = validated_identifier(window_id, "windowId")?;
    let name = bounded_trimmed(body.name, "name", 200, false)?;
    let acceptance = submit_command(
        &state,
        Some(window_id.clone()),
        Some(window_id.clone()),
        CommandKind::Rename {
            display_name: name.clone(),
        },
        idempotency_key(body.idempotency_key, None)?,
    )
    .await?;
    let mut ack = DurableCommandAck::new(acceptance);
    ack.window_id = Some(window_id);
    ack.name = Some(name);
    Ok(Json(ack))
}

async fn minimize_session(
    State(state): State<ApiState>,
    Path(window_id): Path<String>,
) -> Result<Json<DurableCommandAck>, ApiError> {
    set_minimized(state, window_id, true).await.map(Json)
}

async fn restore_session(
    State(state): State<ApiState>,
    Path(window_id): Path<String>,
) -> Result<Json<DurableCommandAck>, ApiError> {
    set_minimized(state, window_id, false).await.map(Json)
}

async fn set_minimized(
    state: ApiState,
    window_id: String,
    minimized: bool,
) -> Result<DurableCommandAck, ApiError> {
    let window_id = validated_identifier(window_id, "windowId")?;
    let acceptance = submit_command(
        &state,
        Some(window_id.clone()),
        Some(window_id.clone()),
        CommandKind::SetMinimized { minimized },
        fresh_idempotency_key(),
    )
    .await?;
    let mut ack = DurableCommandAck::new(acceptance);
    ack.window_id = Some(window_id);
    ack.minimized = Some(minimized);
    Ok(ack)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PinnedBody {
    pinned: bool,
    #[serde(default)]
    idempotency_key: Option<String>,
}

async fn set_pinned(
    State(state): State<ApiState>,
    Path(window_id): Path<String>,
    Json(body): Json<PinnedBody>,
) -> Result<Json<DurableCommandAck>, ApiError> {
    let window_id = validated_identifier(window_id, "windowId")?;
    let acceptance = submit_command(
        &state,
        Some(window_id.clone()),
        Some(window_id.clone()),
        CommandKind::SetPinned {
            pinned: body.pinned,
        },
        idempotency_key(body.idempotency_key, None)?,
    )
    .await?;
    let mut ack = DurableCommandAck::new(acceptance);
    ack.window_id = Some(window_id);
    ack.pinned = Some(body.pinned);
    Ok(Json(ack))
}

async fn delete_session(
    State(state): State<ApiState>,
    Path(window_id): Path<String>,
) -> Result<Json<DurableCommandAck>, ApiError> {
    let window_id = validated_identifier(window_id, "windowId")?;
    let acceptance = submit_command(
        &state,
        Some(window_id.clone()),
        Some(window_id.clone()),
        CommandKind::Delete,
        fresh_idempotency_key(),
    )
    .await?;
    let mut ack = DurableCommandAck::new(acceptance);
    ack.window_id = Some(window_id);
    Ok(Json(ack))
}

async fn archive_session(
    State(state): State<ApiState>,
    Path(window_id): Path<String>,
) -> Result<Json<DurableCommandAck>, ApiError> {
    let window_id = validated_identifier(window_id, "windowId")?;
    let acceptance = submit_command(
        &state,
        Some(window_id.clone()),
        Some(window_id.clone()),
        CommandKind::Archive,
        fresh_idempotency_key(),
    )
    .await?;
    let mut ack = DurableCommandAck::new(acceptance);
    ack.window_id = Some(window_id);
    Ok(Json(ack))
}

async fn command_status(
    State(state): State<ApiState>,
    Path(command_id): Path<String>,
) -> Result<Json<DurableCommandStatus>, ApiError> {
    let command_id = validated_identifier(command_id, "commandId")?;
    let command = state
        .backend
        .command(command_id)
        .await
        .map_err(ApiError::backend)?
        .ok_or_else(|| ApiError::not_found("COMMAND_NOT_FOUND", "command not found"))?;
    Ok(Json(DurableCommandStatus::new(command)))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CreateSubagentBody {
    message: String,
    #[serde(default)]
    session_id: Option<String>,
    #[serde(default)]
    display_name: Option<String>,
    #[serde(default)]
    parent_notification_prompt: Option<String>,
    #[serde(default)]
    engine: Option<String>,
    #[serde(default)]
    idempotency_key: Option<String>,
}

async fn create_subagent(
    State(state): State<ApiState>,
    Path(window_id): Path<String>,
    Json(body): Json<CreateSubagentBody>,
) -> Result<Json<DurableCommandAck>, ApiError> {
    let window_id = validated_identifier(window_id, "windowId")?;
    if let Some(engine) = body.engine.as_deref()
        && !engine.trim().is_empty()
        && !engine.eq_ignore_ascii_case("codex")
    {
        return Err(ApiError::bad_request(
            "UNSUPPORTED_SUBAGENT_ENGINE",
            "Fermín Code subagents use Codex",
        ));
    }
    let parent = state
        .backend
        .session(window_id.clone())
        .await
        .map_err(ApiError::backend)?
        .ok_or_else(|| ApiError::not_found("SESSION_NOT_FOUND", "session not found"))?;
    let prompt = bounded_trimmed(body.message, "message", MAX_MESSAGE_BYTES, false)?;
    let child_session_id = match body.session_id {
        Some(session_id) => validated_identifier(session_id, "sessionId")?,
        None => format!("subagent-{}", Uuid::new_v4()),
    };
    let display_name = optional_bounded(body.display_name, "displayName", 200)?;
    let parent_notification_prompt = optional_bounded(
        body.parent_notification_prompt,
        "parentNotificationPrompt",
        64 * 1024,
    )?;
    let acceptance = submit_command(
        &state,
        Some(window_id.clone()),
        Some(child_session_id.clone()),
        CommandKind::CreateSubagent {
            prompt,
            display_name,
            parent_notification_prompt,
        },
        idempotency_key(body.idempotency_key, Some(&child_session_id))?,
    )
    .await?;
    let mut ack = DurableCommandAck::new(acceptance);
    ack.source_window_id = Some(window_id);
    ack.source_session_id = Some(parent.session_id);
    ack.project_path = parent.project_path;
    ack.project_name = parent.project_name.or(Some(parent.project_key));
    ack.session_id = Some(child_session_id);
    ack.engine = Some("codex".to_owned());
    Ok(Json(ack))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RetryPromptBody {
    #[serde(default)]
    message_id: Option<String>,
    #[serde(default)]
    idempotency_key: Option<String>,
}

async fn retry_prompt_transform(
    State(state): State<ApiState>,
    Path((window_id, message_id)): Path<(String, String)>,
    Json(body): Json<RetryPromptBody>,
) -> Result<Json<DurableCommandAck>, ApiError> {
    let window_id = validated_identifier(window_id, "windowId")?;
    let message_id = validated_identifier(message_id, "messageId")?;
    if let Some(body_message_id) = body.message_id {
        let body_message_id = validated_identifier(body_message_id, "messageId")?;
        if body_message_id != message_id {
            return Err(ApiError::bad_request(
                "MESSAGE_ID_MISMATCH",
                "messageId does not match request path",
            ));
        }
    }
    let acceptance = submit_command(
        &state,
        Some(window_id.clone()),
        Some(window_id.clone()),
        CommandKind::RetryPromptTransform {
            message_id: message_id.clone(),
        },
        idempotency_key(body.idempotency_key, Some(&format!("retry:{message_id}")))?,
    )
    .await?;
    let mut ack = DurableCommandAck::new(acceptance);
    ack.window_id = Some(window_id);
    ack.message_id = Some(message_id);
    Ok(Json(ack))
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PromptPreferenceEnvelope {
    ok: bool,
    preference: PromptImproverPreferenceRecord,
    variants: [PromptImproverVariant; 2],
}

async fn get_prompt_preference(
    State(state): State<ApiState>,
) -> Result<Json<PromptPreferenceEnvelope>, ApiError> {
    let preference = state
        .backend
        .prompt_improver_preference()
        .await
        .map_err(ApiError::backend)?;
    Ok(Json(prompt_preference_envelope(preference)))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PromptPreferenceBody {
    variant: PromptImproverVariant,
}

async fn set_prompt_preference(
    State(state): State<ApiState>,
    Json(body): Json<PromptPreferenceBody>,
) -> Result<Json<PromptPreferenceEnvelope>, ApiError> {
    let preference = state
        .backend
        .set_prompt_improver_preference(body.variant)
        .await
        .map_err(ApiError::backend)?;
    Ok(Json(prompt_preference_envelope(preference)))
}

fn prompt_preference_envelope(
    preference: PromptImproverPreferenceRecord,
) -> PromptPreferenceEnvelope {
    PromptPreferenceEnvelope {
        ok: true,
        preference,
        variants: [
            PromptImproverVariant::Standard,
            PromptImproverVariant::Motivational,
        ],
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ProjectEnvelope {
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    root_path: Option<String>,
    items: Vec<ProjectDirectory>,
}

async fn projects(State(state): State<ApiState>) -> Result<Json<ProjectEnvelope>, ApiError> {
    let catalog = state.backend.projects().await.map_err(ApiError::backend)?;
    if catalog.items.len() > 10_000 {
        return Err(ApiError::payload_too_large(
            "PROJECT_CATALOG_TOO_LARGE",
            "project catalog exceeds 10000 entries",
        ));
    }
    Ok(Json(ProjectEnvelope {
        ok: true,
        root_path: catalog.root_path,
        items: catalog.items,
    }))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct FilePreviewBody {
    path: String,
}

async fn file_preview(
    State(state): State<ApiState>,
    Json(body): Json<FilePreviewBody>,
) -> Result<Json<FilePreview>, ApiError> {
    let path = validated_path(body.path, "path")?;
    let preview = state
        .backend
        .file_preview(path)
        .await
        .map_err(ApiError::backend)?;
    if preview.content.len() > MAX_FILE_PREVIEW_BYTES || preview.size_bytes > MAX_FILE_PREVIEW_BYTES
    {
        return Err(ApiError::payload_too_large(
            "FILE_PREVIEW_TOO_LARGE",
            "file exceeds the 10 MiB preview limit",
        ));
    }
    Ok(Json(preview))
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct AttachmentUploadEnvelope {
    ok: bool,
    path: String,
    bytes: u64,
    mime_type: String,
}

async fn upload_attachment(
    State(state): State<ApiState>,
    Path(window_id): Path<String>,
    mut multipart: Multipart,
) -> Result<Json<AttachmentUploadEnvelope>, ApiError> {
    let window_id = validated_identifier(window_id, "windowId")?;
    let mut upload = None;
    while let Some(field) = multipart
        .next_field()
        .await
        .map_err(|error| ApiError::bad_request("INVALID_MULTIPART", error.to_string()))?
    {
        if field.name() != Some("image") || upload.is_some() {
            return Err(ApiError::bad_request(
                "INVALID_MULTIPART",
                "multipart body must contain exactly one image field",
            ));
        }
        let file_name = field.file_name().map(str::to_owned).ok_or_else(|| {
            ApiError::bad_request("MISSING_FILE_NAME", "image filename is required")
        })?;
        validate_file_name(&file_name)?;
        let declared_mime = field
            .content_type()
            .map(str::to_ascii_lowercase)
            .ok_or_else(|| ApiError::unsupported_media("missing image content type"))?;
        let bytes = field
            .bytes()
            .await
            .map_err(|error| ApiError::bad_request("INVALID_MULTIPART", error.to_string()))?;
        validate_image_bytes(&bytes, &declared_mime)?;
        upload = Some(AttachmentUpload {
            file_name,
            mime_type: declared_mime,
            bytes,
        });
    }
    let upload = upload.ok_or_else(|| {
        ApiError::bad_request("MISSING_IMAGE", "multipart image field is required")
    })?;
    let actual_size = upload.bytes.len() as u64;
    let mime_type = upload.mime_type.clone();
    let attachment = state
        .backend
        .upload_attachment(window_id, upload)
        .await
        .map_err(ApiError::backend)?;
    let path = attachment
        .path
        .filter(|path| !path.trim().is_empty())
        .ok_or_else(|| {
            ApiError::backend(MobileBackendError::Internal(
                "upload path missing".to_owned(),
            ))
        })?;
    Ok(Json(AttachmentUploadEnvelope {
        ok: true,
        path,
        bytes: actual_size,
        mime_type,
    }))
}

#[derive(Deserialize)]
struct AttachmentContentQuery {
    path: String,
}

async fn attachment_content(
    State(state): State<ApiState>,
    Query(query): Query<AttachmentContentQuery>,
) -> Result<Response, ApiError> {
    let path = validated_path(query.path, "path")?;
    let content = state
        .backend
        .attachment_content(path)
        .await
        .map_err(ApiError::backend)?;
    validate_image_bytes(&content.bytes, &content.mime_type)?;
    let content_length = content.bytes.len();
    let mut response = content.bytes.into_response();
    response.headers_mut().insert(
        CONTENT_TYPE,
        HeaderValue::from_str(&content.mime_type).map_err(|_| {
            ApiError::backend(MobileBackendError::Internal("invalid MIME type".to_owned()))
        })?,
    );
    response.headers_mut().insert(
        CONTENT_LENGTH,
        HeaderValue::from_str(&content_length.to_string())
            .unwrap_or_else(|_| HeaderValue::from_static("0")),
    );
    response.headers_mut().insert(
        CACHE_CONTROL,
        HeaderValue::from_static("private, max-age=300"),
    );
    Ok(response)
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct RawHistoryQuery {
    #[serde(default)]
    query: String,
    #[serde(default)]
    state: SessionHistoryState,
    #[serde(default)]
    sort: SessionHistorySort,
    #[serde(default)]
    project_path: Option<String>,
    #[serde(default)]
    from: Option<Millis>,
    #[serde(default)]
    to: Option<Millis>,
    #[serde(default)]
    offset: Option<usize>,
    #[serde(default)]
    limit: Option<usize>,
    #[serde(default)]
    refresh: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SessionHistoryEnvelope {
    ok: bool,
    #[serde(flatten)]
    page: SessionHistoryPage,
}

async fn session_history(
    State(state): State<ApiState>,
    Query(raw): Query<RawHistoryQuery>,
) -> Result<Json<SessionHistoryEnvelope>, ApiError> {
    let query_text = bounded_trimmed(raw.query, "query", 1024, true)?;
    let project_path = match raw.project_path {
        Some(path) => Some(validated_path(path, "projectPath")?),
        None => None,
    };
    let offset = raw.offset.unwrap_or(0).min(100_000);
    let limit = raw.limit.unwrap_or(30).clamp(1, 100);
    if raw.from.zip(raw.to).is_some_and(|(from, to)| from > to) {
        return Err(ApiError::bad_request(
            "INVALID_DATE_RANGE",
            "from must be less than or equal to to",
        ));
    }
    let query = SessionHistoryQuery {
        query: query_text,
        state: raw.state,
        sort: raw.sort,
        project_path,
        from: raw.from,
        to: raw.to,
        offset,
        limit,
        refresh: matches!(raw.refresh.as_deref(), Some("1" | "true")),
    };
    let mut page = state
        .backend
        .session_history(query)
        .await
        .map_err(ApiError::backend)?;
    page.items.truncate(limit);
    page.limit = limit;
    Ok(Json(SessionHistoryEnvelope { ok: true, page }))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ResumeHistoryBody {
    #[serde(alias = "historyId")]
    id: String,
    #[serde(default)]
    idempotency_key: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ResumeHistoryEnvelope {
    ok: bool,
    queued: bool,
    command_id: String,
    queued_at: Millis,
    state: CommandState,
    #[serde(skip_serializing_if = "Option::is_none")]
    window_id: Option<String>,
    session_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    project_path: Option<String>,
}

async fn resume_history(
    State(state): State<ApiState>,
    Json(body): Json<ResumeHistoryBody>,
) -> Result<Json<ResumeHistoryEnvelope>, ApiError> {
    let history_id = validated_identifier(body.id, "id")?;
    let key = idempotency_key(body.idempotency_key, Some(&format!("resume:{history_id}")))?;
    let result = state
        .backend
        .resume_history(history_id, key)
        .await
        .map_err(ApiError::backend)?;
    Ok(Json(ResumeHistoryEnvelope {
        ok: true,
        queued: !result.acceptance.command.state.is_terminal(),
        command_id: result.acceptance.command.command_id,
        queued_at: result.acceptance.command.accepted_at,
        state: result.acceptance.command.state,
        window_id: result.window_id,
        session_id: result.session_id,
        project_path: result.project_path,
    }))
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct RawRecoveryQuery {
    #[serde(default)]
    query: String,
    #[serde(default)]
    offset: Option<usize>,
    #[serde(default)]
    limit: Option<usize>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SessionRecoveryEnvelope {
    ok: bool,
    #[serde(flatten)]
    page: SessionRecoveryPage,
}

async fn recoverable_sessions(
    State(state): State<ApiState>,
    Query(raw): Query<RawRecoveryQuery>,
) -> Result<Json<SessionRecoveryEnvelope>, ApiError> {
    let query = SessionRecoveryQuery {
        query: bounded_trimmed(raw.query, "query", 1024, true)?,
        offset: raw.offset.unwrap_or(0).min(100_000),
        limit: raw.limit.unwrap_or(30).clamp(1, 100),
    };
    let limit = query.limit;
    let mut page = state
        .backend
        .recoverable_sessions(query)
        .await
        .map_err(ApiError::backend)?;
    page.items.truncate(limit);
    page.limit = limit;
    Ok(Json(SessionRecoveryEnvelope { ok: true, page }))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RecoverSessionBody {
    id: String,
    #[serde(default)]
    idempotency_key: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct RecoverSessionEnvelope {
    ok: bool,
    queued: bool,
    command_id: String,
    queued_at: Millis,
    state: CommandState,
    #[serde(skip_serializing_if = "Option::is_none")]
    window_id: Option<String>,
    session_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    project_path: Option<String>,
}

async fn recover_session(
    State(state): State<ApiState>,
    Json(body): Json<RecoverSessionBody>,
) -> Result<Json<RecoverSessionEnvelope>, ApiError> {
    let recovery_id = validated_identifier(body.id, "id")?;
    let key = idempotency_key(
        body.idempotency_key,
        Some(&format!("recover:{recovery_id}")),
    )?;
    let result = state
        .backend
        .recover_session(recovery_id, key)
        .await
        .map_err(ApiError::backend)?;
    Ok(Json(RecoverSessionEnvelope {
        ok: true,
        queued: !result.acceptance.command.state.is_terminal(),
        command_id: result.acceptance.command.command_id,
        queued_at: result.acceptance.command.accepted_at,
        state: result.acceptance.command.state,
        window_id: result.window_id,
        session_id: result.session_id,
        project_path: result.project_path,
    }))
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct StreamQuery {
    #[serde(default, alias = "after")]
    after_global_sequence: Option<Sequence>,
    #[serde(default)]
    replay_limit: Option<usize>,
}

async fn stream_events(
    State(state): State<ApiState>,
    headers: HeaderMap,
    Query(query): Query<StreamQuery>,
) -> Result<Sse<impl Stream<Item = Result<Event, Infallible>>>, ApiError> {
    let snapshot = state.backend.snapshot().await.map_err(ApiError::backend)?;
    let snapshot_payload = sessions_envelope(&snapshot);
    let snapshot_json = serde_json::to_string(&snapshot_payload)
        .map_err(|_| ApiError::internal("failed to serialize initial snapshot"))?;
    if snapshot_json.len() > MAX_SSE_SNAPSHOT_BYTES {
        return Err(ApiError::payload_too_large(
            "SSE_SNAPSHOT_TOO_LARGE",
            "initial SSE snapshot exceeds 4 MiB",
        ));
    }
    let last_event_id = headers
        .get("last-event-id")
        .map(|value| {
            value
                .to_str()
                .map_err(|_| {
                    ApiError::bad_request("INVALID_EVENT_CURSOR", "Last-Event-ID is invalid")
                })
                .and_then(|value| {
                    let value = value.trim();
                    if value.is_empty() || value.len() > 512 {
                        Err(ApiError::bad_request(
                            "INVALID_EVENT_CURSOR",
                            "Last-Event-ID must contain 1 to 512 characters",
                        ))
                    } else {
                        Ok(value.to_owned())
                    }
                })
        })
        .transpose()?;
    let replay_cursor = ReplayCursor {
        last_event_id: last_event_id.clone(),
        after_global_sequence: query
            .after_global_sequence
            .or_else(|| last_event_id.is_none().then_some(snapshot.global_sequence)),
    };
    let replay_limit = query
        .replay_limit
        .unwrap_or(state.config.replay_limit)
        .clamp(1, state.config.replay_limit);
    let mut live = state
        .backend
        .subscribe_events()
        .map_err(ApiError::backend)?;
    let backend = state.backend.clone();
    let heartbeat_interval = state.config.heartbeat_interval;
    let output = stream! {
        yield Ok::<Event, Infallible>(Event::default().event("snapshot").data(snapshot_json));

        let mut replay_cursor = replay_cursor;
        let mut delivered_sequence = replay_cursor.after_global_sequence.unwrap_or(0);
        loop {
            match backend.replay_events(replay_cursor.clone(), replay_limit).await {
                Ok(events) => {
                    let page_len = events.len();
                    if page_len == 0 {
                        break;
                    }
                    let mut last_sequence = None;
                    for durable in events.into_iter().take(replay_limit) {
                        last_sequence = Some(durable.global_sequence);
                        match durable_sse_event(&durable) {
                            Ok(event) => {
                                delivered_sequence = durable.global_sequence;
                                yield Ok(event);
                            }
                            Err(error) => {
                                yield Ok(sse_error_event(&error));
                                return;
                            }
                        }
                    }
                    let Some(last_sequence) = last_sequence else {
                        break;
                    };
                    replay_cursor = ReplayCursor {
                        last_event_id: None,
                        after_global_sequence: Some(last_sequence),
                    };
                    if page_len < replay_limit {
                        break;
                    }
                }
                Err(error) => {
                    yield Ok(sse_error_event(&ApiError::backend(error)));
                    return;
                }
            }
        }

        let start = tokio::time::Instant::now() + heartbeat_interval;
        let mut heartbeat = tokio::time::interval_at(start, heartbeat_interval);
        heartbeat.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            tokio::select! {
                event = live.next() => {
                    match event {
                        Some(Ok(durable)) if durable.global_sequence <= delivered_sequence => continue,
                        Some(Ok(durable)) => match durable_sse_event(&durable) {
                            Ok(event) => {
                                delivered_sequence = durable.global_sequence;
                                yield Ok(event);
                            }
                            Err(error) => {
                                yield Ok(sse_error_event(&error));
                                return;
                            }
                        },
                        Some(Err(error)) => {
                            yield Ok(sse_error_event(&ApiError::backend(error)));
                            return;
                        }
                        None => return,
                    }
                }
                _ = heartbeat.tick() => {
                    yield Ok(Event::default().comment("heartbeat"));
                }
            }
        }
    };
    Ok(Sse::new(output))
}

fn durable_sse_event(event: &DurableEvent) -> Result<Event, ApiError> {
    if event.event_id.trim().is_empty() || event.event_id.len() > 512 {
        return Err(ApiError::internal("durable event id is invalid"));
    }
    let data = serde_json::to_string(&event.payload)
        .map_err(|_| ApiError::internal("durable event payload is not serializable"))?;
    if data.len() > MAX_SSE_EVENT_BYTES {
        let omitted = serde_json::to_string(&json!({
            "ok": false,
            "code": "SSE_EVENT_PAYLOAD_OMITTED",
            "reason": "payloadTooLarge",
            "originalEvent": event.kind.as_str(),
            "originalBytes": data.len(),
            "refetchRequired": true,
        }))
        .map_err(|_| ApiError::internal("failed to serialize omitted event marker"))?;
        return Ok(Event::default()
            .id(event.global_sequence.to_string())
            .event("event_omitted")
            .data(omitted));
    }
    Ok(Event::default()
        .id(event.global_sequence.to_string())
        .event(event.kind.as_str())
        .data(data))
}

fn sse_error_event(error: &ApiError) -> Event {
    Event::default().event("error").data(
        serde_json::to_string(&ErrorEnvelope {
            ok: false,
            code: error.code,
            error: error.message.clone(),
        })
        .unwrap_or_else(|_| {
            "{\"ok\":false,\"code\":\"STREAM_ERROR\",\"error\":\"stream failed\"}".to_owned()
        }),
    )
}

fn sessions_envelope(snapshot: &AuthoritativeSnapshot) -> SessionsEnvelope {
    let items = snapshot
        .sessions
        .iter()
        .cloned()
        .map(|mut session| {
            session.messages.clear();
            session
        })
        .collect();
    SessionsEnvelope {
        ok: true,
        now: snapshot.generated_at,
        exported_at: snapshot.generated_at,
        items,
        cursor: Some(snapshot.global_sequence),
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DurableCommandStatus {
    pub ok: bool,
    pub command_id: String,
    pub command_state: CommandState,
    pub updated_at: Millis,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

impl DurableCommandStatus {
    fn new(command: CommandRecord) -> Self {
        Self {
            ok: !matches!(
                command.state,
                CommandState::Failed | CommandState::Unknown | CommandState::Cancelled
            ),
            command_id: command.command_id,
            command_state: command.state,
            updated_at: command.updated_at,
            error: command.error,
        }
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DurableCommandAck {
    pub ok: bool,
    pub command_id: String,
    pub command_state: CommandState,
    pub inserted: bool,
    pub durable: bool,
    pub queued_at: Millis,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub window_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source_window_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source_session_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub project_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub project_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub client_message_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent_command_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub minimized: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pinned: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub run_mode: Option<RunMode>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub goal_started_at: Option<Millis>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub engine: Option<String>,
}

impl DurableCommandAck {
    fn new(acceptance: CommandAcceptance) -> Self {
        Self {
            ok: !matches!(
                acceptance.command.state,
                CommandState::Failed | CommandState::Cancelled
            ),
            command_id: acceptance.command.command_id,
            command_state: acceptance.command.state,
            inserted: acceptance.inserted,
            durable: true,
            queued_at: acceptance.command.accepted_at,
            window_id: None,
            session_id: acceptance.command.session_id,
            session_name: None,
            source_window_id: None,
            source_session_id: None,
            project_path: None,
            project_name: None,
            client_message_id: None,
            message_id: None,
            parent_command_id: None,
            name: None,
            minimized: None,
            pinned: None,
            run_mode: None,
            goal_started_at: None,
            engine: None,
        }
    }
}

async fn submit_command(
    state: &ApiState,
    target_window_id: Option<String>,
    session_id: Option<String>,
    command: CommandKind,
    idempotency_key: String,
) -> Result<CommandAcceptance, ApiError> {
    let requested_at = unix_millis();
    state
        .backend
        .submit_command(
            target_window_id,
            CommandRequest {
                command_id: None,
                idempotency_key,
                session_id,
                command,
                requested_at,
                trace_id: None,
            },
        )
        .await
        .map_err(ApiError::backend)
}

fn validate_message_attachments(
    inputs: Vec<MessageAttachmentInput>,
) -> Result<Vec<ImageAttachment>, ApiError> {
    if inputs.len() > MAX_ATTACHMENT_COUNT {
        return Err(ApiError::payload_too_large(
            "TOO_MANY_ATTACHMENTS",
            "at most 10 image attachments are allowed",
        ));
    }
    let mut total = 0_u64;
    inputs
        .into_iter()
        .enumerate()
        .map(|(index, input)| {
            let path = validated_path(input.path, "attachment.path")?;
            let name = bounded_trimmed(input.name, "attachment.name", 255, false)?;
            if input.size == 0 || input.size > MAX_ATTACHMENT_BYTES as u64 {
                return Err(ApiError::payload_too_large(
                    "INVALID_ATTACHMENT_SIZE",
                    "each image must contain 1 byte to 20 MiB",
                ));
            }
            total = total.saturating_add(input.size);
            if total > MAX_ATTACHMENT_TOTAL_BYTES as u64 {
                return Err(ApiError::payload_too_large(
                    "ATTACHMENTS_TOO_LARGE",
                    "combined images exceed 50 MiB",
                ));
            }
            let mime_type = input.mime_type.trim().to_ascii_lowercase();
            if !supported_image_mime(&mime_type) {
                return Err(ApiError::unsupported_media("unsupported image type"));
            }
            let id = match input.id {
                Some(id) => validated_identifier(id, "attachment.id")?,
                None => format!("attachment-{index}-{}", Uuid::new_v4()),
            };
            Ok(ImageAttachment {
                id,
                name,
                path: Some(path),
                size: input.size,
                mime_type,
                preview_data: None,
            })
        })
        .collect()
}

fn validate_image_bytes(bytes: &[u8], declared_mime: &str) -> Result<(), ApiError> {
    if bytes.is_empty() {
        return Err(ApiError::bad_request("EMPTY_IMAGE", "image is empty"));
    }
    if bytes.len() > MAX_ATTACHMENT_BYTES {
        return Err(ApiError::payload_too_large(
            "IMAGE_TOO_LARGE",
            "image exceeds 20 MiB",
        ));
    }
    let declared_mime = declared_mime.trim().to_ascii_lowercase();
    if !supported_image_mime(&declared_mime)
        || detect_image_mime(bytes) != Some(declared_mime.as_str())
    {
        return Err(ApiError::unsupported_media(
            "image bytes do not match PNG, JPEG, GIF, or WebP content type",
        ));
    }
    Ok(())
}

fn supported_image_mime(mime: &str) -> bool {
    matches!(
        mime,
        "image/png" | "image/jpeg" | "image/gif" | "image/webp"
    )
}

fn detect_image_mime(bytes: &[u8]) -> Option<&'static str> {
    if bytes.starts_with(&[0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a]) {
        return Some("image/png");
    }
    if bytes.starts_with(&[0xff, 0xd8, 0xff]) {
        return Some("image/jpeg");
    }
    if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        return Some("image/gif");
    }
    if bytes.len() >= 12 && &bytes[..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        return Some("image/webp");
    }
    None
}

fn validate_file_name(file_name: &str) -> Result<(), ApiError> {
    let file_name = file_name.trim();
    if file_name.is_empty()
        || file_name.len() > 255
        || file_name.contains('/')
        || file_name.contains('\\')
        || file_name.chars().any(char::is_control)
    {
        return Err(ApiError::bad_request(
            "INVALID_FILE_NAME",
            "image filename is invalid",
        ));
    }
    Ok(())
}

fn validated_identifier(value: String, field: &'static str) -> Result<String, ApiError> {
    bounded_trimmed(value, field, MAX_IDENTIFIER_BYTES, false).and_then(|value| {
        if value.chars().any(char::is_control) {
            Err(ApiError::bad_request(
                "INVALID_IDENTIFIER",
                format!("{field} contains control characters"),
            ))
        } else {
            Ok(value)
        }
    })
}

fn validated_path(value: String, field: &'static str) -> Result<String, ApiError> {
    bounded_trimmed(value, field, MAX_PATH_BYTES, false).and_then(|value| {
        if value.contains('\0') {
            Err(ApiError::bad_request(
                "INVALID_PATH",
                format!("{field} contains a NUL byte"),
            ))
        } else {
            Ok(value)
        }
    })
}

fn bounded_trimmed(
    value: String,
    field: &'static str,
    max_bytes: usize,
    allow_empty: bool,
) -> Result<String, ApiError> {
    let value = value.trim().to_owned();
    if !allow_empty && value.is_empty() {
        return Err(ApiError::bad_request(
            "MISSING_FIELD",
            format!("{field} is required"),
        ));
    }
    if value.len() > max_bytes {
        return Err(ApiError::payload_too_large(
            "FIELD_TOO_LARGE",
            format!("{field} exceeds {max_bytes} bytes"),
        ));
    }
    Ok(value)
}

fn optional_bounded(
    value: Option<String>,
    field: &'static str,
    max_bytes: usize,
) -> Result<Option<String>, ApiError> {
    value
        .map(|value| bounded_trimmed(value, field, max_bytes, false))
        .transpose()
}

fn validated_model(model: String) -> Result<String, ApiError> {
    let model = bounded_trimmed(model, "model", 128, false)?;
    let normalized = model.to_ascii_lowercase();
    if !normalized.starts_with("gpt-")
        || normalized.contains("grok")
        || normalized.contains("xai")
        || normalized.contains("x.ai")
    {
        return Err(ApiError::bad_request(
            "UNSUPPORTED_MODEL",
            "only GPT models reported by Codex App Server are supported",
        ));
    }
    Ok(model)
}

fn optional_model(model: Option<String>) -> Result<Option<String>, ApiError> {
    model.map(validated_model).transpose()
}

fn idempotency_key(explicit: Option<String>, fallback: Option<&str>) -> Result<String, ApiError> {
    match explicit {
        Some(key) => validated_identifier(key, "idempotencyKey"),
        None => Ok(fallback
            .map(str::to_owned)
            .unwrap_or_else(fresh_idempotency_key)),
    }
}

fn fresh_idempotency_key() -> String {
    format!("mobile-command-{}", Uuid::new_v4())
}

fn unix_millis() -> Millis {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(i64::MAX as u128) as i64
}

#[derive(Serialize)]
struct ErrorEnvelope {
    ok: bool,
    code: &'static str,
    error: String,
}

struct ApiError {
    status: StatusCode,
    code: &'static str,
    message: String,
}

impl ApiError {
    fn bad_request(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::BAD_REQUEST,
            code,
            message: message.into(),
        }
    }

    fn unauthorized() -> Self {
        Self {
            status: StatusCode::UNAUTHORIZED,
            code: "UNAUTHORIZED",
            message: "valid Bearer authorization is required".to_owned(),
        }
    }

    fn not_found(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::NOT_FOUND,
            code,
            message: message.into(),
        }
    }

    fn payload_too_large(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::PAYLOAD_TOO_LARGE,
            code,
            message: message.into(),
        }
    }

    fn unsupported_media(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::UNSUPPORTED_MEDIA_TYPE,
            code: "UNSUPPORTED_MEDIA_TYPE",
            message: message.into(),
        }
    }

    fn internal(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::INTERNAL_SERVER_ERROR,
            code: "INTERNAL_ERROR",
            message: message.into(),
        }
    }

    fn backend(error: MobileBackendError) -> Self {
        match error {
            MobileBackendError::Invalid(message) => Self::bad_request("INVALID_REQUEST", message),
            MobileBackendError::NotFound(message) => Self::not_found("NOT_FOUND", message),
            MobileBackendError::Conflict(message) => Self {
                status: StatusCode::CONFLICT,
                code: "CONFLICT",
                message,
            },
            MobileBackendError::PayloadTooLarge(message) => {
                Self::payload_too_large("PAYLOAD_TOO_LARGE", message)
            }
            MobileBackendError::UnsupportedMediaType(message) => Self::unsupported_media(message),
            MobileBackendError::Unavailable(message) => Self {
                status: StatusCode::SERVICE_UNAVAILABLE,
                code: "BACKEND_UNAVAILABLE",
                message,
            },
            MobileBackendError::Internal(_) => {
                Self::internal("Fermín Code backend failed unexpectedly")
            }
        }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (
            self.status,
            [(CACHE_CONTROL, HeaderValue::from_static("no-store"))],
            Json(ErrorEnvelope {
                ok: false,
                code: self.code,
                error: self.message,
            }),
        )
            .into_response()
    }
}

#[cfg(test)]
mod tests {
    use std::collections::{HashMap, VecDeque};
    use std::sync::Mutex;
    use std::sync::atomic::{AtomicBool, Ordering};

    use axum::body::to_bytes;
    use axum::http::header::AUTHORIZATION;
    use axum::http::{Method, Request};
    use futures_util::stream;
    use serde_json::Value;
    use tower::ServiceExt;

    use crate::protocol::{ActivityStatus, CommandRecord, EventKind, ReasoningEffortOption};

    use super::*;

    const TOKEN: &str = "test-token-0123456789-abcdefghijklmnopqrstuvwxyz";

    struct FakeBackend {
        snapshot: AuthoritativeSnapshot,
        submissions: Mutex<Vec<(Option<String>, CommandRequest)>>,
        commands: Mutex<HashMap<String, CommandRecord>>,
        replay: Mutex<VecDeque<DurableEvent>>,
        live: Mutex<Vec<DurableEvent>>,
        seen_window_id: Mutex<Option<String>>,
        preference: Mutex<PromptImproverPreferenceRecord>,
        ready: AtomicBool,
    }

    impl FakeBackend {
        fn new() -> Self {
            let mut session = SessionSummary::new("session-1", "project", "Session one", 100);
            session.window_id = "window-1".to_owned();
            session.project_path = Some("/tmp/project".to_owned());
            session.project_name = Some("project".to_owned());
            session.activity_status = ActivityStatus::Ready;
            Self {
                snapshot: AuthoritativeSnapshot {
                    schema_version: MOBILE_SCHEMA_VERSION,
                    global_sequence: 7,
                    generated_at: 100,
                    sessions: vec![session],
                    models: vec![],
                },
                submissions: Mutex::new(Vec::new()),
                commands: Mutex::new(HashMap::new()),
                replay: Mutex::new(VecDeque::new()),
                live: Mutex::new(Vec::new()),
                seen_window_id: Mutex::new(None),
                preference: Mutex::new(PromptImproverPreferenceRecord {
                    version: 1,
                    variant: PromptImproverVariant::Standard,
                    updated_at: None,
                }),
                ready: AtomicBool::new(true),
            }
        }

        fn accepted(request: CommandRequest) -> CommandAcceptance {
            let now = request.requested_at;
            CommandAcceptance {
                inserted: true,
                command: CommandRecord {
                    command_id: request
                        .command_id
                        .clone()
                        .unwrap_or_else(|| format!("command-{}", Uuid::new_v4())),
                    idempotency_key: request.idempotency_key.clone(),
                    session_id: request.session_id.clone(),
                    command: request.command.clone(),
                    state: CommandState::Accepted,
                    requested_at: now,
                    accepted_at: now,
                    updated_at: now,
                    trace_id: request.trace_id.clone(),
                    lease_generation: None,
                    error: None,
                },
            }
        }
    }

    impl MobileBackend for FakeBackend {
        fn health(&self) -> BackendFuture<'_, BackendHealth> {
            Box::pin(async move {
                Ok(BackendHealth {
                    ready: self.ready.load(Ordering::Acquire),
                    role: "fake".to_owned(),
                    details: json!({"fixture": true}),
                })
            })
        }

        fn snapshot(&self) -> BackendFuture<'_, AuthoritativeSnapshot> {
            Box::pin(async { Ok(self.snapshot.clone()) })
        }

        fn session(&self, window_id: String) -> BackendFuture<'_, Option<SessionSummary>> {
            Box::pin(async move {
                *self.seen_window_id.lock().unwrap() = Some(window_id.clone());
                let mut item = self.snapshot.sessions[0].clone();
                item.window_id = window_id;
                Ok(Some(item))
            })
        }

        fn command(&self, command_id: String) -> BackendFuture<'_, Option<CommandRecord>> {
            Box::pin(async move { Ok(self.commands.lock().unwrap().get(&command_id).cloned()) })
        }

        fn submit_command(
            &self,
            target_window_id: Option<String>,
            request: CommandRequest,
        ) -> BackendFuture<'_, CommandAcceptance> {
            Box::pin(async move {
                self.submissions
                    .lock()
                    .unwrap()
                    .push((target_window_id, request.clone()));
                let acceptance = Self::accepted(request);
                self.commands.lock().unwrap().insert(
                    acceptance.command.command_id.clone(),
                    acceptance.command.clone(),
                );
                Ok(acceptance)
            })
        }

        fn models(&self, _window_id: String) -> BackendFuture<'_, ModelCatalog> {
            Box::pin(async {
                Ok(ModelCatalog {
                    observed_at: 100,
                    app_server_version: Some("0.147.0".to_owned()),
                    capability_hash: Some("hash".to_owned()),
                    models: vec![
                        ModelInfo {
                            id: "gpt-5.6-luna".to_owned(),
                            model: "gpt-5.6-luna".to_owned(),
                            model_provider: Some("openai".to_owned()),
                            display_name: "GPT-5.6 Luna".to_owned(),
                            default_reasoning_effort: "high".to_owned(),
                            supported_reasoning_efforts: vec![ReasoningEffortOption {
                                reasoning_effort: "high".to_owned(),
                                description: None,
                            }],
                            hidden: false,
                            is_default: true,
                        },
                        ModelInfo {
                            id: "unsupported-4".to_owned(),
                            model: "unsupported-4".to_owned(),
                            model_provider: Some("unsupported".to_owned()),
                            display_name: "Unsupported".to_owned(),
                            default_reasoning_effort: "high".to_owned(),
                            supported_reasoning_efforts: vec![],
                            hidden: false,
                            is_default: false,
                        },
                    ],
                })
            })
        }

        fn projects(&self) -> BackendFuture<'_, ProjectCatalog> {
            Box::pin(async {
                Ok(ProjectCatalog {
                    root_path: Some("/tmp".to_owned()),
                    items: vec![ProjectDirectory {
                        name: "project".to_owned(),
                        path: "/tmp/project".to_owned(),
                        kind: Some("directory".to_owned()),
                    }],
                })
            })
        }

        fn prompt_improver_preference(&self) -> BackendFuture<'_, PromptImproverPreferenceRecord> {
            Box::pin(async { Ok(self.preference.lock().unwrap().clone()) })
        }

        fn set_prompt_improver_preference(
            &self,
            variant: PromptImproverVariant,
        ) -> BackendFuture<'_, PromptImproverPreferenceRecord> {
            Box::pin(async move {
                let mut preference = self.preference.lock().unwrap();
                preference.variant = variant;
                Ok(preference.clone())
            })
        }

        fn file_preview(&self, path: String) -> BackendFuture<'_, FilePreview> {
            Box::pin(async move {
                Ok(FilePreview {
                    name: "file.rs".to_owned(),
                    path,
                    content: "fn main() {}".to_owned(),
                    kind: FilePreviewKind::Code,
                    language: Some("rust".to_owned()),
                    size_bytes: 12,
                })
            })
        }

        fn upload_attachment(
            &self,
            _window_id: String,
            upload: AttachmentUpload,
        ) -> BackendFuture<'_, ImageAttachment> {
            Box::pin(async move {
                Ok(ImageAttachment {
                    id: "image-1".to_owned(),
                    name: upload.file_name,
                    path: Some("/tmp/uploads/image.png".to_owned()),
                    size: upload.bytes.len() as u64,
                    mime_type: upload.mime_type,
                    preview_data: None,
                })
            })
        }

        fn attachment_content(&self, _path: String) -> BackendFuture<'_, AttachmentContent> {
            Box::pin(async {
                Ok(AttachmentContent {
                    mime_type: "image/png".to_owned(),
                    bytes: Bytes::from_static(&[0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a, 0]),
                })
            })
        }

        fn session_history(
            &self,
            query: SessionHistoryQuery,
        ) -> BackendFuture<'_, SessionHistoryPage> {
            Box::pin(async move {
                Ok(SessionHistoryPage {
                    items: vec![],
                    offset: query.offset,
                    limit: query.limit,
                    total: 0,
                    has_more: false,
                    updated_at: 100,
                    search_ms: 0.1,
                    index_build_ms: 0.0,
                    indexed_sessions: 1,
                    indexed_terms: 1,
                })
            })
        }

        fn resume_history(
            &self,
            history_id: String,
            idempotency_key: String,
        ) -> BackendFuture<'_, SessionHistoryResumeResult> {
            Box::pin(async move {
                let request = CommandRequest {
                    command_id: None,
                    idempotency_key,
                    session_id: Some(history_id.clone()),
                    command: CommandKind::CreateSession {
                        project_path: "/tmp/project".to_owned(),
                        display_name: None,
                        model: None,
                        reasoning_effort: None,
                    },
                    requested_at: 100,
                    trace_id: None,
                };
                Ok(SessionHistoryResumeResult {
                    acceptance: Self::accepted(request),
                    session_id: history_id,
                    window_id: None,
                    project_path: Some("/tmp/project".to_owned()),
                })
            })
        }

        fn recoverable_sessions(
            &self,
            query: SessionRecoveryQuery,
        ) -> BackendFuture<'_, SessionRecoveryPage> {
            Box::pin(async move {
                Ok(SessionRecoveryPage {
                    items: Vec::new(),
                    offset: query.offset,
                    limit: query.limit,
                    total: 0,
                    has_more: false,
                    updated_at: 100,
                })
            })
        }

        fn recover_session(
            &self,
            recovery_id: String,
            idempotency_key: String,
        ) -> BackendFuture<'_, SessionRecoveryResult> {
            Box::pin(async move {
                let request = CommandRequest {
                    command_id: None,
                    idempotency_key,
                    session_id: Some(recovery_id.clone()),
                    command: CommandKind::RecoverSession,
                    requested_at: 100,
                    trace_id: None,
                };
                Ok(SessionRecoveryResult {
                    acceptance: Self::accepted(request),
                    session_id: recovery_id.clone(),
                    window_id: Some(recovery_id),
                    project_path: Some("/tmp/project".to_owned()),
                })
            })
        }

        fn replay_events(
            &self,
            cursor: ReplayCursor,
            limit: usize,
        ) -> BackendFuture<'_, Vec<DurableEvent>> {
            Box::pin(async move {
                let events = self.replay.lock().unwrap();
                let after = cursor.after_global_sequence.or_else(|| {
                    cursor.last_event_id.as_deref().and_then(|event_id| {
                        events
                            .iter()
                            .find(|event| event.event_id == event_id)
                            .map(|event| event.global_sequence)
                    })
                });
                Ok(events
                    .iter()
                    .filter(|event| after.is_none_or(|after| event.global_sequence > after))
                    .take(limit)
                    .cloned()
                    .collect())
            })
        }

        fn subscribe_events(&self) -> Result<BackendEventStream, MobileBackendError> {
            let live = self.live.lock().unwrap().clone();
            if live.is_empty() {
                Ok(Box::pin(stream::pending()))
            } else {
                Ok(Box::pin(stream::iter(live.into_iter().map(Ok))))
            }
        }
    }

    fn test_router(backend: Arc<FakeBackend>) -> Router {
        router(backend, MobileApiConfig::new(TOKEN).unwrap())
    }

    fn authorized_request(method: Method, uri: &str, body: Body) -> Request<Body> {
        Request::builder()
            .method(method)
            .uri(uri)
            .header(AUTHORIZATION, format!("Bearer {TOKEN}"))
            .header(CONTENT_TYPE, "application/json")
            .body(body)
            .unwrap()
    }

    async fn json_value(response: Response) -> Value {
        let bytes = to_bytes(response.into_body(), MAX_JSON_BODY_BYTES)
            .await
            .unwrap();
        serde_json::from_slice(&bytes).unwrap()
    }

    #[tokio::test]
    async fn health_is_public_at_root_and_mount_prefix() {
        let app = test_router(Arc::new(FakeBackend::new()));
        for path in [
            "/healthz",
            "/fermin-code/healthz",
            "/fermin-code-puky/healthz",
            "/sync-hub/healthz",
        ] {
            let response = app
                .clone()
                .oneshot(Request::builder().uri(path).body(Body::empty()).unwrap())
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::OK);
            assert_eq!(json_value(response).await["service"], "fermin-code");
        }
    }

    #[tokio::test]
    async fn health_returns_service_unavailable_when_backend_is_not_ready() {
        let backend = Arc::new(FakeBackend::new());
        backend.ready.store(false, Ordering::Release);
        let app = test_router(backend);
        let response = app
            .oneshot(
                Request::builder()
                    .uri("/healthz")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
        let body = json_value(response).await;
        assert_eq!(body["ok"], false);
        assert_eq!(body["ready"], false);
        assert_eq!(body["role"], "fake");
        assert_eq!(body["details"]["fixture"], true);
    }

    #[test]
    fn mobile_session_snapshots_are_lightweight_and_source_timestamped() {
        let mut backend = FakeBackend::new();
        backend.snapshot.generated_at = 1234;
        backend.snapshot.sessions[0]
            .messages
            .push(crate::protocol::Message::assistant(
                "message-1",
                "large transcript",
                99,
            ));

        let envelope = sessions_envelope(&backend.snapshot);

        assert_eq!(envelope.now, 1234);
        assert_eq!(envelope.exported_at, 1234);
        assert!(envelope.items[0].messages.is_empty());
        assert_eq!(backend.snapshot.sessions[0].messages.len(), 1);
    }

    #[tokio::test]
    async fn protected_routes_require_constant_time_bearer_check() {
        let config = MobileApiConfig::new(TOKEN).unwrap();
        let mut headers = HeaderMap::new();
        headers.insert(
            AUTHORIZATION,
            HeaderValue::from_str(&format!("Bearer {TOKEN}")).unwrap(),
        );
        assert!(bearer_is_authorized(&headers, &config.bearer_digest));
        headers.insert(
            AUTHORIZATION,
            HeaderValue::from_static("Bearer test-token-0123456789-xxxxxxxxxxxxxxxxxxxxxxxxxx"),
        );
        assert!(!bearer_is_authorized(&headers, &config.bearer_digest));

        let app = test_router(Arc::new(FakeBackend::new()));
        let response = app
            .oneshot(
                Request::builder()
                    .uri("/api/mobile/sessions")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
        assert_eq!(json_value(response).await["code"], "UNAUTHORIZED");
    }

    #[tokio::test]
    async fn encoded_window_id_reaches_backend_without_route_loss() {
        let backend = Arc::new(FakeBackend::new());
        let app = test_router(backend.clone());
        let response = app
            .oneshot(authorized_request(
                Method::GET,
                "/api/mobile/sessions/profile%3A%3Awindow%2Fone",
                Body::empty(),
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(
            response.headers().get(CACHE_CONTROL),
            Some(&HeaderValue::from_static("private, no-store"))
        );
        assert_eq!(
            backend.seen_window_id.lock().unwrap().as_deref(),
            Some("profile::window/one")
        );
    }

    #[tokio::test]
    async fn delete_archive_and_command_status_keep_distinct_durable_semantics() {
        let backend = Arc::new(FakeBackend::new());
        let app = test_router(backend.clone());

        let delete_response = app
            .clone()
            .oneshot(authorized_request(
                Method::DELETE,
                "/api/mobile/sessions/window-1/permanent",
                Body::empty(),
            ))
            .await
            .unwrap();
        assert_eq!(delete_response.status(), StatusCode::OK);
        let delete_body = json_value(delete_response).await;
        let command_id = delete_body["commandId"].as_str().unwrap();
        assert!(matches!(
            &backend.submissions.lock().unwrap()[0].1.command,
            CommandKind::Delete
        ));

        let status_response = app
            .clone()
            .oneshot(authorized_request(
                Method::GET,
                &format!("/api/mobile/commands/{command_id}"),
                Body::empty(),
            ))
            .await
            .unwrap();
        assert_eq!(status_response.status(), StatusCode::OK);
        let status_body = json_value(status_response).await;
        assert_eq!(status_body["commandId"], command_id);
        assert_eq!(status_body["commandState"], "accepted");

        let archive_response = app
            .oneshot(authorized_request(
                Method::POST,
                "/api/mobile/sessions/window-1/archive",
                Body::empty(),
            ))
            .await
            .unwrap();
        assert_eq!(archive_response.status(), StatusCode::OK);
        assert!(matches!(
            &backend.submissions.lock().unwrap()[1].1.command,
            CommandKind::Archive
        ));

        let legacy_archive_response = test_router(backend.clone())
            .oneshot(authorized_request(
                Method::DELETE,
                "/api/mobile/sessions/window-1",
                Body::empty(),
            ))
            .await
            .unwrap();
        assert_eq!(legacy_archive_response.status(), StatusCode::OK);
        assert!(matches!(
            &backend.submissions.lock().unwrap()[2].1.command,
            CommandKind::Archive
        ));
    }

    #[tokio::test]
    async fn pinned_route_accepts_mobile_and_desktop_changes_in_both_directions() {
        let backend = Arc::new(FakeBackend::new());
        let app = test_router(backend.clone());
        let changes = [
            (Method::POST, false, "mobile-unpin"),
            (Method::POST, true, "mobile-pin"),
            (Method::PUT, false, "desktop-unpin"),
            (Method::PUT, true, "desktop-pin"),
        ];

        for (method, pinned, key) in &changes {
            let response = app
                .clone()
                .oneshot(authorized_request(
                    method.clone(),
                    "/api/mobile/sessions/window-1/pinned",
                    Body::from(
                        json!({
                            "pinned": *pinned,
                            "idempotencyKey": key
                        })
                        .to_string(),
                    ),
                ))
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::OK);
            let payload = json_value(response).await;
            assert_eq!(payload["pinned"], *pinned);
            assert_eq!(payload["durable"], true);
        }

        let submissions = backend.submissions.lock().unwrap();
        assert_eq!(submissions.len(), 4);
        for (index, (_, pinned, key)) in changes.into_iter().enumerate() {
            assert_eq!(submissions[index].0.as_deref(), Some("window-1"));
            assert_eq!(submissions[index].1.idempotency_key, key);
            assert!(matches!(
                &submissions[index].1.command,
                CommandKind::SetPinned { pinned: actual } if *actual == pinned
            ));
        }
    }

    #[tokio::test]
    async fn message_returns_durable_ack_and_protocol_command() {
        let backend = Arc::new(FakeBackend::new());
        let app = test_router(backend.clone());
        let body = Body::from(
            json!({
                "message": "Hello",
                "clientMessageId": "mobile-user-1",
                "attachments": [],
                "fastModeEnabled": true
            })
            .to_string(),
        );
        let response = app
            .oneshot(authorized_request(
                Method::POST,
                "/api/mobile/sessions/window-1/message",
                body,
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let payload = json_value(response).await;
        assert_eq!(payload["durable"], true);
        assert_eq!(payload["commandState"], "accepted");
        let submissions = backend.submissions.lock().unwrap();
        assert_eq!(submissions[0].0.as_deref(), Some("window-1"));
        assert_eq!(submissions[0].1.idempotency_key, "mobile-user-1");
        assert!(matches!(
            &submissions[0].1.command,
            CommandKind::SendMessage { content, service_tier, .. }
                if content == "Hello" && service_tier.as_deref() == Some("fast")
        ));
    }

    #[tokio::test]
    async fn steer_and_interrupt_are_durable_targeted_commands() {
        let backend = Arc::new(FakeBackend::new());
        let app = test_router(backend.clone());
        let steer = app
            .clone()
            .oneshot(authorized_request(
                Method::POST,
                "/api/mobile/sessions/window-1/steer",
                Body::from(
                    json!({
                        "message": "Focus on the failing test",
                        "idempotencyKey": "steer-1"
                    })
                    .to_string(),
                ),
            ))
            .await
            .unwrap();
        assert_eq!(steer.status(), StatusCode::OK);
        assert_eq!(json_value(steer).await["durable"], true);

        let interrupt = app
            .oneshot(authorized_request(
                Method::POST,
                "/api/mobile/sessions/window-1/interrupt",
                Body::empty(),
            ))
            .await
            .unwrap();
        assert_eq!(interrupt.status(), StatusCode::OK);
        assert_eq!(json_value(interrupt).await["durable"], true);

        let submissions = backend.submissions.lock().unwrap();
        assert_eq!(submissions.len(), 2);
        assert_eq!(submissions[0].0.as_deref(), Some("window-1"));
        assert_eq!(submissions[0].1.idempotency_key, "steer-1");
        assert!(matches!(
            &submissions[0].1.command,
            CommandKind::Steer { content } if content == "Focus on the failing test"
        ));
        assert_eq!(submissions[1].0.as_deref(), Some("window-1"));
        assert!(matches!(&submissions[1].1.command, CommandKind::Interrupt));
    }

    #[tokio::test]
    async fn subagent_parent_note_is_a_separate_idempotent_protocol_message() {
        let mut backend = FakeBackend::new();
        backend.snapshot.sessions[0].parent_session_id = Some("parent-session".to_owned());
        let mut parent = SessionSummary::new("parent-session", "project", "Parent", 90);
        parent.window_id = "parent-window".to_owned();
        backend.snapshot.sessions.push(parent);
        let backend = Arc::new(backend);
        let app = test_router(backend.clone());
        let response = app
            .oneshot(authorized_request(
                Method::POST,
                "/api/mobile/sessions/window-1/message",
                Body::from(
                    json!({
                        "message": "Run the delegated task",
                        "clientMessageId": "mobile-child-1",
                        "attachments": [],
                        "parentNotificationPrompt": "SUB-AGENT COORDINATION NOTE: child started"
                    })
                    .to_string(),
                ),
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert!(json_value(response).await["parentCommandId"].is_string());
        let submissions = backend.submissions.lock().unwrap();
        assert_eq!(submissions.len(), 2);
        assert_eq!(submissions[1].0.as_deref(), Some("parent-window"));
        assert!(matches!(
            &submissions[1].1.command,
            CommandKind::SendMessage { content, attachments, .. }
                if content.contains("COORDINATION NOTE") && attachments.is_empty()
        ));
        assert!(
            submissions[1]
                .1
                .idempotency_key
                .starts_with("parent-notification-")
        );
    }

    #[tokio::test]
    async fn validation_errors_are_4xx_json() {
        let app = test_router(Arc::new(FakeBackend::new()));
        let response = app
            .clone()
            .oneshot(authorized_request(
                Method::POST,
                "/api/mobile/sessions/window-1/model-settings",
                Body::from(
                    json!({
                        "model": "unsupported-4",
                        "modelProvider": "unsupported",
                        "reasoningEffort": "high"
                    })
                    .to_string(),
                ),
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
        assert_eq!(json_value(response).await["code"], "UNSUPPORTED_MODEL");

        let response = app
            .oneshot(authorized_request(
                Method::POST,
                "/api/mobile/sessions/window-1/run-mode",
                Body::from(
                    json!({
                        "goalEnabled": true,
                        "objective": "x".repeat(MAX_NATIVE_GOAL_OBJECTIVE_CHARS + 1)
                    })
                    .to_string(),
                ),
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
        assert_eq!(
            json_value(response).await["code"],
            "GOAL_OBJECTIVE_TOO_LONG"
        );
    }

    #[tokio::test]
    async fn upload_rejects_mime_spoof_and_accepts_png() {
        let app = test_router(Arc::new(FakeBackend::new()));
        let boundary = "test-boundary";
        let multipart = |bytes: &[u8], mime: &str| {
            let mut body = format!(
                "--{boundary}\r\nContent-Disposition: form-data; name=\"image\"; filename=\"a.png\"\r\nContent-Type: {mime}\r\n\r\n"
            )
            .into_bytes();
            body.extend_from_slice(bytes);
            body.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());
            body
        };
        let request = |bytes: Vec<u8>| {
            Request::builder()
                .method(Method::POST)
                .uri("/api/mobile/sessions/window-1/attachments")
                .header(AUTHORIZATION, format!("Bearer {TOKEN}"))
                .header(
                    CONTENT_TYPE,
                    format!("multipart/form-data; boundary={boundary}"),
                )
                .body(Body::from(bytes))
                .unwrap()
        };
        let bad = app
            .clone()
            .oneshot(request(multipart(b"not png", "image/png")))
            .await
            .unwrap();
        assert_eq!(bad.status(), StatusCode::UNSUPPORTED_MEDIA_TYPE);

        let good_bytes = [0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a, 0];
        let good = app
            .oneshot(request(multipart(&good_bytes, "image/png")))
            .await
            .unwrap();
        assert_eq!(good.status(), StatusCode::OK);
        assert_eq!(json_value(good).await["mimeType"], "image/png");
    }

    #[tokio::test]
    async fn recovery_routes_are_separate_from_history_and_return_durable_shape() {
        let app = test_router(Arc::new(FakeBackend::new()));
        let search = app
            .clone()
            .oneshot(authorized_request(
                Method::GET,
                "/api/mobile/session-recovery?query=article-studio&limit=20",
                Body::empty(),
            ))
            .await
            .unwrap();
        assert_eq!(search.status(), StatusCode::OK);
        let search = json_value(search).await;
        assert_eq!(search["ok"], true);
        assert_eq!(search["limit"], 20);

        let recover = app
            .oneshot(authorized_request(
                Method::POST,
                "/api/mobile/session-recovery/recover",
                Body::from(
                    serde_json::to_vec(&json!({
                        "id": "legacy-session",
                        "idempotencyKey": "recover-legacy-session"
                    }))
                    .unwrap(),
                ),
            ))
            .await
            .unwrap();
        assert_eq!(recover.status(), StatusCode::OK);
        let recover = json_value(recover).await;
        assert_eq!(recover["ok"], true);
        assert_eq!(recover["sessionId"], "legacy-session");
        assert!(recover["commandId"].is_string());
    }

    #[tokio::test]
    async fn sse_starts_with_snapshot_then_replays_durable_id_and_event() {
        let backend = Arc::new(FakeBackend::new());
        backend.replay.lock().unwrap().push_back(DurableEvent {
            event_id: "event-8".to_owned(),
            global_sequence: 8,
            session_sequence: Some(1),
            session_id: Some("session-1".to_owned()),
            command_id: None,
            process_epoch: Some(1),
            kind: EventKind::MessagePatch,
            payload: json!({ "windowId": "window-1", "revision": 1 }),
            created_at: 101,
        });
        let app = test_router(backend);
        let response = app
            .oneshot(authorized_request(
                Method::GET,
                "/api/mobile/stream?afterGlobalSequence=7",
                Body::empty(),
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let mut stream = response.into_body().into_data_stream();
        let first = tokio::time::timeout(Duration::from_secs(1), stream.next())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        let second = tokio::time::timeout(Duration::from_secs(1), stream.next())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        let first = String::from_utf8(first.to_vec()).unwrap();
        let second = String::from_utf8(second.to_vec()).unwrap();
        assert!(first.contains("event: snapshot"));
        assert!(second.contains("id: 8"));
        assert!(second.contains("event: message_patch"));
    }

    #[tokio::test]
    async fn sse_replays_every_page_before_switching_to_live_events() {
        let backend = Arc::new(FakeBackend::new());
        for sequence in 8..=10 {
            backend.replay.lock().unwrap().push_back(DurableEvent {
                event_id: format!("event-{sequence}"),
                global_sequence: sequence,
                session_sequence: Some(sequence - 7),
                session_id: Some("session-1".to_owned()),
                command_id: None,
                process_epoch: Some(1),
                kind: EventKind::CommandStateChanged,
                payload: json!({
                    "commandId": format!("command-{sequence}"),
                    "state": "completed"
                }),
                created_at: 100 + sequence as i64,
            });
        }
        let config = MobileApiConfig::new(TOKEN).unwrap().with_replay_limit(2);
        let app = router(backend, config);
        let response = app
            .oneshot(authorized_request(
                Method::GET,
                "/api/mobile/stream?afterGlobalSequence=7",
                Body::empty(),
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let mut stream = response.into_body().into_data_stream();
        let mut chunks = Vec::new();
        for _ in 0..4 {
            let chunk = tokio::time::timeout(Duration::from_secs(1), stream.next())
                .await
                .unwrap()
                .unwrap()
                .unwrap();
            chunks.push(String::from_utf8(chunk.to_vec()).unwrap());
        }
        assert!(chunks[0].contains("event: snapshot"));
        assert!(chunks[1].contains("id: 8"));
        assert!(chunks[2].contains("id: 9"));
        assert!(chunks[3].contains("id: 10"));
    }

    #[tokio::test]
    async fn sse_deduplicates_events_captured_by_replay_and_live_subscription() {
        let backend = Arc::new(FakeBackend::new());
        let replayed = DurableEvent {
            event_id: "event-8".to_owned(),
            global_sequence: 8,
            session_sequence: Some(1),
            session_id: Some("session-1".to_owned()),
            command_id: None,
            process_epoch: Some(1),
            kind: EventKind::MessagePatch,
            payload: json!({"revision": 1}),
            created_at: 108,
        };
        let live = DurableEvent {
            event_id: "event-9".to_owned(),
            global_sequence: 9,
            session_sequence: Some(2),
            session_id: Some("session-1".to_owned()),
            command_id: None,
            process_epoch: Some(1),
            kind: EventKind::MessagePatch,
            payload: json!({"revision": 2}),
            created_at: 109,
        };
        backend.replay.lock().unwrap().push_back(replayed.clone());
        backend.live.lock().unwrap().extend([replayed, live]);
        let app = test_router(backend);
        let response = app
            .oneshot(authorized_request(
                Method::GET,
                "/api/mobile/stream?afterGlobalSequence=7",
                Body::empty(),
            ))
            .await
            .unwrap();
        let mut stream = response.into_body().into_data_stream();
        let mut chunks = Vec::new();
        while let Some(chunk) = tokio::time::timeout(Duration::from_secs(1), stream.next())
            .await
            .unwrap()
        {
            chunks.push(String::from_utf8(chunk.unwrap().to_vec()).unwrap());
        }
        assert_eq!(
            chunks
                .iter()
                .filter(|chunk| chunk.contains("id: 8"))
                .count(),
            1
        );
        assert_eq!(
            chunks
                .iter()
                .filter(|chunk| chunk.contains("id: 9"))
                .count(),
            1
        );
    }

    #[tokio::test]
    async fn oversized_durable_event_advances_cursor_without_exposing_payload() {
        let backend = Arc::new(FakeBackend::new());
        let private_marker = "private-transcript-marker";
        backend.replay.lock().unwrap().push_back(DurableEvent {
            event_id: "event-8".to_owned(),
            global_sequence: 8,
            session_sequence: Some(1),
            session_id: Some("session-1".to_owned()),
            command_id: None,
            process_epoch: Some(1),
            kind: EventKind::MessagePatch,
            payload: json!({
                "content": format!("{private_marker}{}", "x".repeat(MAX_SSE_EVENT_BYTES))
            }),
            created_at: 108,
        });
        backend.replay.lock().unwrap().push_back(DurableEvent {
            event_id: "event-9".to_owned(),
            global_sequence: 9,
            session_sequence: Some(2),
            session_id: Some("session-1".to_owned()),
            command_id: None,
            process_epoch: Some(1),
            kind: EventKind::CommandStateChanged,
            payload: json!({"commandId": "command-9", "state": "completed"}),
            created_at: 109,
        });
        let app = test_router(backend);
        let response = app
            .oneshot(authorized_request(
                Method::GET,
                "/api/mobile/stream?afterGlobalSequence=7",
                Body::empty(),
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let mut stream = response.into_body().into_data_stream();
        let mut chunks = Vec::new();
        for _ in 0..3 {
            let chunk = tokio::time::timeout(Duration::from_secs(1), stream.next())
                .await
                .unwrap()
                .unwrap()
                .unwrap();
            chunks.push(String::from_utf8(chunk.to_vec()).unwrap());
        }
        assert!(chunks[1].contains("id: 8"));
        assert!(chunks[1].contains("event: event_omitted"));
        assert!(chunks[1].contains("SSE_EVENT_PAYLOAD_OMITTED"));
        assert!(!chunks[1].contains(private_marker));
        assert!(chunks[2].contains("id: 9"));
        assert!(chunks[2].contains("event: command_state_changed"));
    }

    #[test]
    fn heartbeat_is_strictly_below_twenty_four_seconds() {
        assert!(
            MobileApiConfig::new(TOKEN)
                .unwrap()
                .with_heartbeat_interval(Duration::from_secs(23))
                .is_ok()
        );
        assert_eq!(
            MobileApiConfig::new(TOKEN)
                .unwrap()
                .with_heartbeat_interval(Duration::from_secs(24))
                .unwrap_err(),
            MobileApiConfigError::InvalidHeartbeat
        );
        assert!(
            MobileApiConfig::new(TOKEN)
                .unwrap()
                .with_max_body_bytes(MAX_JSON_BODY_BYTES)
                .is_ok()
        );
        assert_eq!(
            MobileApiConfig::new(TOKEN)
                .unwrap()
                .with_max_body_bytes(MAX_JSON_BODY_BYTES - 1)
                .unwrap_err(),
            MobileApiConfigError::InvalidBodyLimit
        );
    }

    #[tokio::test]
    async fn model_catalog_filters_non_gpt_providers() {
        let app = test_router(Arc::new(FakeBackend::new()));
        let response = app
            .oneshot(authorized_request(
                Method::GET,
                "/fermin-code/api/mobile/sessions/window-1/models",
                Body::empty(),
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let payload = json_value(response).await;
        assert_eq!(payload["data"].as_array().unwrap().len(), 1);
        assert_eq!(payload["data"][0]["model"], "gpt-5.6-luna");
    }
}
