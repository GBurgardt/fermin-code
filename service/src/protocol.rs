use serde::{Deserialize, Serialize};
use serde_json::Value;

pub type Millis = i64;
pub type Sequence = u64;

pub const MOBILE_SCHEMA_VERSION: u16 = 1;
pub const ENGINE_NAME: &str = "codex";
pub const MAX_SESSION_PREVIEW_CHARS: usize = 512;

pub fn bounded_session_preview(value: &str) -> String {
    let mut chars = value.chars();
    let preview: String = chars.by_ref().take(MAX_SESSION_PREVIEW_CHARS).collect();
    if chars.next().is_some() {
        format!("{preview}…")
    } else {
        preview
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionFeatures {
    pub prompt_improver_enabled: bool,
    pub explainer_enabled: bool,
    pub code_context_enabled: bool,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ActivityStatus {
    Working,
    Approval,
    Error,
    Ready,
    Done,
    #[default]
    Idle,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RunMode {
    #[serde(rename = "normal")]
    #[default]
    Default,
    Goal,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum MessageRole {
    User,
    Assistant,
    System,
    Tool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ImageAttachment {
    pub id: String,
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    pub size: u64,
    pub mime_type: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub preview_data: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Message {
    pub id: String,
    pub role: MessageRole,
    #[serde(rename = "type", skip_serializing_if = "Option::is_none")]
    pub message_type: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub provider_item_id: Option<String>,
    pub content: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub original_prompt: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub transformed_prompt: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub improved_prompt: Option<String>,
    pub timestamp: Millis,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub image_attachments: Vec<ImageAttachment>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub transform_status: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub transform_error_reason: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub prompt_transform_note: Option<String>,
}

impl Message {
    pub fn user(id: impl Into<String>, content: impl Into<String>, timestamp: Millis) -> Self {
        let content = content.into();
        Self {
            id: id.into(),
            role: MessageRole::User,
            message_type: None,
            provider_item_id: None,
            original_prompt: Some(content.clone()),
            content,
            transformed_prompt: None,
            improved_prompt: None,
            timestamp,
            status: None,
            image_attachments: Vec::new(),
            transform_status: None,
            transform_error_reason: None,
            prompt_transform_note: None,
        }
    }

    pub fn assistant(id: impl Into<String>, content: impl Into<String>, timestamp: Millis) -> Self {
        Self {
            id: id.into(),
            role: MessageRole::Assistant,
            message_type: None,
            provider_item_id: None,
            content: content.into(),
            original_prompt: None,
            transformed_prompt: None,
            improved_prompt: None,
            timestamp,
            status: None,
            image_attachments: Vec::new(),
            transform_status: None,
            transform_error_reason: None,
            prompt_transform_note: None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PendingSubagentDraft {
    pub display_message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent_notification_prompt: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub child_message_sent_at: Option<Millis>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GoalState {
    pub objective: String,
    pub status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub token_budget: Option<u64>,
    pub tokens_used: u64,
    pub time_used_seconds: u64,
    pub created_at: Millis,
    pub updated_at: Millis,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionSummary {
    pub window_id: String,
    pub session_id: String,
    #[serde(default)]
    pub managed_by_fermin: bool,
    #[serde(default = "default_engine")]
    pub engine: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reasoning_effort: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub provider_session_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub provider_session_path: Option<String>,
    pub project_key: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub project_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub project_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub window_name: Option<String>,
    pub display_name: String,
    #[serde(default = "default_sidecar_mode")]
    pub sidecar_mode: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sidecar_url: Option<String>,
    #[serde(default)]
    pub activity_status: ActivityStatus,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub runtime_status: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub runtime_status_detail: Option<String>,
    #[serde(default)]
    pub features: SessionFeatures,
    #[serde(default)]
    pub run_mode: RunMode,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub goal_started_at: Option<Millis>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub goal: Option<GoalState>,
    pub message_count: u64,
    pub updated_at: Millis,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub created_at: Option<Millis>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub raw_prompt: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub original_prompt: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub improved_prompt: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_message_preview: Option<String>,
    #[serde(default)]
    pub is_minimized: bool,
    #[serde(default = "default_true")]
    pub is_pinned: bool,
    #[serde(default = "default_true")]
    pub can_send: bool,
    #[serde(default = "default_true")]
    pub can_control_features: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub unsupported_reason: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub messages: Vec<Message>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pending_subagent: Option<PendingSubagentDraft>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub collaboration_project_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub collaboration_project_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent_session_id: Option<String>,
}

impl SessionSummary {
    pub fn new(
        session_id: impl Into<String>,
        project_key: impl Into<String>,
        display_name: impl Into<String>,
        now: Millis,
    ) -> Self {
        let session_id = session_id.into();
        Self {
            window_id: session_id.clone(),
            session_id,
            managed_by_fermin: true,
            engine: default_engine(),
            model: None,
            reasoning_effort: None,
            provider_session_id: None,
            provider_session_path: None,
            project_key: project_key.into(),
            project_path: None,
            project_name: None,
            window_name: None,
            display_name: display_name.into(),
            sidecar_mode: default_sidecar_mode(),
            sidecar_url: None,
            activity_status: ActivityStatus::Idle,
            runtime_status: None,
            runtime_status_detail: None,
            features: SessionFeatures::default(),
            run_mode: RunMode::Default,
            goal_started_at: None,
            goal: None,
            message_count: 0,
            updated_at: now,
            created_at: Some(now),
            raw_prompt: None,
            original_prompt: None,
            improved_prompt: None,
            last_message_preview: None,
            is_minimized: false,
            is_pinned: true,
            can_send: true,
            can_control_features: true,
            unsupported_reason: None,
            messages: Vec::new(),
            pending_subagent: None,
            collaboration_project_id: None,
            collaboration_project_name: None,
            session_name: None,
            parent_session_id: None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionsEnvelope {
    pub ok: bool,
    pub now: Millis,
    pub exported_at: Millis,
    pub items: Vec<SessionSummary>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cursor: Option<Sequence>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionDetailEnvelope {
    pub ok: bool,
    pub now: Millis,
    pub item: SessionSummary,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cursor: Option<Sequence>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReasoningEffortOption {
    pub reasoning_effort: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelInfo {
    pub id: String,
    pub model: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model_provider: Option<String>,
    pub display_name: String,
    pub default_reasoning_effort: String,
    #[serde(default)]
    pub supported_reasoning_efforts: Vec<ReasoningEffortOption>,
    #[serde(default)]
    pub hidden: bool,
    #[serde(default)]
    pub is_default: bool,
}

impl ModelInfo {
    pub fn is_product_supported(&self) -> bool {
        let model = self.model.to_ascii_lowercase();
        let id = self.id.to_ascii_lowercase();
        let provider = self
            .model_provider
            .as_deref()
            .unwrap_or("openai")
            .to_ascii_lowercase();
        !self.hidden
            && model.starts_with("gpt-")
            && id.starts_with("gpt-")
            && !model.contains("grok")
            && !id.contains("grok")
            && !provider.contains("xai")
            && (provider == "openai" || provider == "codex")
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelCatalog {
    pub observed_at: Millis,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub app_server_version: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub capability_hash: Option<String>,
    #[serde(rename = "data")]
    pub models: Vec<ModelInfo>,
}

impl ModelCatalog {
    pub fn product_filtered(mut self) -> Self {
        self.models.retain(ModelInfo::is_product_supported);
        self
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeModelSettings {
    pub model: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model_provider: Option<String>,
    pub effort: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(
    tag = "type",
    content = "data",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum CommandKind {
    CreateSession {
        project_path: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        display_name: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        model: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        reasoning_effort: Option<String>,
    },
    RecoverSession,
    SendMessage {
        content: String,
        client_message_id: String,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        attachments: Vec<ImageAttachment>,
        #[serde(skip_serializing_if = "Option::is_none")]
        service_tier: Option<String>,
    },
    Steer {
        content: String,
    },
    Interrupt,
    Archive,
    Delete,
    Rename {
        display_name: String,
    },
    SetMinimized {
        minimized: bool,
    },
    SetPinned {
        pinned: bool,
    },
    SetRunMode {
        run_mode: RunMode,
        #[serde(skip_serializing_if = "Option::is_none")]
        objective: Option<String>,
    },
    SetFeatures {
        features: SessionFeatures,
    },
    SetModel {
        settings: RuntimeModelSettings,
    },
    CreateSubagent {
        prompt: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        display_name: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        parent_notification_prompt: Option<String>,
    },
    RespondApproval {
        request_id: String,
        decision: String,
    },
    RespondUserInput {
        request_id: String,
        answers: Value,
    },
    RetryPromptTransform {
        message_id: String,
    },
    RunPromptImprover {
        message_id: String,
        prompt: String,
    },
    RunExplainer {
        #[serde(skip_serializing_if = "Option::is_none")]
        focus: Option<String>,
    },
}

impl CommandKind {
    pub fn name(&self) -> &'static str {
        match self {
            Self::CreateSession { .. } => "createSession",
            Self::RecoverSession => "recoverSession",
            Self::SendMessage { .. } => "sendMessage",
            Self::Steer { .. } => "steer",
            Self::Interrupt => "interrupt",
            Self::Archive => "archive",
            Self::Delete => "delete",
            Self::Rename { .. } => "rename",
            Self::SetMinimized { .. } => "setMinimized",
            Self::SetPinned { .. } => "setPinned",
            Self::SetRunMode { .. } => "setRunMode",
            Self::SetFeatures { .. } => "setFeatures",
            Self::SetModel { .. } => "setModel",
            Self::CreateSubagent { .. } => "createSubagent",
            Self::RespondApproval { .. } => "respondApproval",
            Self::RespondUserInput { .. } => "respondUserInput",
            Self::RetryPromptTransform { .. } => "retryPromptTransform",
            Self::RunPromptImprover { .. } => "runPromptImprover",
            Self::RunExplainer { .. } => "runExplainer",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CommandRequest {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub command_id: Option<String>,
    pub idempotency_key: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    pub command: CommandKind,
    pub requested_at: Millis,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub trace_id: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CommandState {
    Accepted,
    Leased,
    EngineDurable,
    SentToChild,
    Completed,
    Failed,
    Cancelled,
    Unknown,
}

impl CommandState {
    pub fn is_terminal(self) -> bool {
        matches!(
            self,
            Self::Completed | Self::Failed | Self::Cancelled | Self::Unknown
        )
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Accepted => "accepted",
            Self::Leased => "leased",
            Self::EngineDurable => "engineDurable",
            Self::SentToChild => "sentToChild",
            Self::Completed => "completed",
            Self::Failed => "failed",
            Self::Cancelled => "cancelled",
            Self::Unknown => "unknown",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CommandRecord {
    pub command_id: String,
    pub idempotency_key: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    pub command: CommandKind,
    pub state: CommandState,
    pub requested_at: Millis,
    pub accepted_at: Millis,
    pub updated_at: Millis,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub trace_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub lease_generation: Option<Sequence>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CommandAcceptance {
    pub inserted: bool,
    pub command: CommandRecord,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CommandReceipt {
    pub relay_command_id: String,
    pub engine_command_id: String,
    pub idempotency_key: String,
    pub inserted: bool,
    pub state: CommandState,
    pub updated_at: Millis,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CommandTransition {
    pub command_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expected_state: Option<CommandState>,
    pub new_state: CommandState,
    pub updated_at: Millis,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub event: Option<NewEvent>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EventKind {
    Snapshot,
    MessagePatch,
    SessionUpserted,
    SessionRemoved,
    CommandStateChanged,
    TurnStarted,
    TurnCompleted,
    TurnInterrupted,
    ItemStarted,
    ItemUpdated,
    ItemCompleted,
    ApprovalRequested,
    ApprovalResolved,
    UserInputRequested,
    UserInputResolved,
    ModelCatalogUpdated,
    GoalUpdated,
    SubagentUpdated,
    RuntimeStatus,
    Error,
    Heartbeat,
}

impl EventKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Snapshot => "snapshot",
            Self::MessagePatch => "message_patch",
            Self::SessionUpserted => "session_upserted",
            Self::SessionRemoved => "session_removed",
            Self::CommandStateChanged => "command_state_changed",
            Self::TurnStarted => "turn_started",
            Self::TurnCompleted => "turn_completed",
            Self::TurnInterrupted => "turn_interrupted",
            Self::ItemStarted => "item_started",
            Self::ItemUpdated => "item_updated",
            Self::ItemCompleted => "item_completed",
            Self::ApprovalRequested => "approval_requested",
            Self::ApprovalResolved => "approval_resolved",
            Self::UserInputRequested => "user_input_requested",
            Self::UserInputResolved => "user_input_resolved",
            Self::ModelCatalogUpdated => "model_catalog_updated",
            Self::GoalUpdated => "goal_updated",
            Self::SubagentUpdated => "subagent_updated",
            Self::RuntimeStatus => "runtime_status",
            Self::Error => "error",
            Self::Heartbeat => "heartbeat",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NewEvent {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub event_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub command_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub process_epoch: Option<Sequence>,
    pub kind: EventKind,
    #[serde(default)]
    pub payload: Value,
    pub created_at: Millis,
}

impl NewEvent {
    pub fn new(kind: EventKind, payload: Value, created_at: Millis) -> Self {
        Self {
            event_id: None,
            session_id: None,
            command_id: None,
            process_epoch: None,
            kind,
            payload,
            created_at,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DurableEvent {
    pub event_id: String,
    pub global_sequence: Sequence,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_sequence: Option<Sequence>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub command_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub process_epoch: Option<Sequence>,
    pub kind: EventKind,
    pub payload: Value,
    pub created_at: Millis,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EventCursor {
    pub after_global_sequence: Sequence,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CommandMutation {
    pub command: CommandRecord,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub event: Option<DurableEvent>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MessagePatch {
    pub window_id: String,
    pub message: Message,
    pub revision: Sequence,
    pub updated_at: Millis,
    #[serde(rename = "final")]
    pub final_: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AuthoritativeSnapshot {
    #[serde(default = "default_mobile_schema_version")]
    pub schema_version: u16,
    pub global_sequence: Sequence,
    pub generated_at: Millis,
    #[serde(default)]
    pub sessions: Vec<SessionSummary>,
    #[serde(default)]
    pub models: Vec<ModelInfo>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StoredSession {
    pub session: SessionSummary,
    pub revision: Sequence,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MessageMutation {
    pub session_id: String,
    pub message: Message,
    pub revision: Sequence,
    pub updated_at: Millis,
    #[serde(rename = "final")]
    pub final_: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StoredMessage {
    pub session_id: String,
    pub message: Message,
    pub revision: Sequence,
    pub updated_at: Millis,
    #[serde(rename = "final")]
    pub final_: bool,
    pub applied: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StoredSnapshot {
    pub scope: String,
    pub version: Sequence,
    pub snapshot: AuthoritativeSnapshot,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NewEngineEpoch {
    pub engine_id: String,
    pub started_at: Millis,
    pub app_server_version: String,
    pub capability_hash: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub schema_hash: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EngineEpoch {
    pub engine_id: String,
    pub epoch: Sequence,
    pub started_at: Millis,
    pub app_server_version: String,
    pub capability_hash: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub schema_hash: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LeaseRequest {
    pub lease_key: String,
    pub holder_id: String,
    pub now: Millis,
    pub ttl_millis: Millis,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub previous_generation: Option<Sequence>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LeaseRecord {
    pub lease_key: String,
    pub holder_id: String,
    pub generation: Sequence,
    pub acquired_at: Millis,
    pub expires_at: Millis,
    pub updated_at: Millis,
}

impl LeaseRecord {
    pub fn fencing_token(&self, now: Millis) -> FencingToken {
        FencingToken {
            lease_key: self.lease_key.clone(),
            holder_id: self.holder_id.clone(),
            generation: self.generation,
            checked_at: now,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FencingToken {
    pub lease_key: String,
    pub holder_id: String,
    pub generation: Sequence,
    pub checked_at: Millis,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConsumerCursor {
    pub consumer_id: String,
    pub global_sequence: Sequence,
    pub updated_at: Millis,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NewOutboxEntry {
    pub peer_id: String,
    pub frame: RelayFrame,
    pub created_at: Millis,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RelayOutboxEntry {
    pub peer_id: String,
    pub sequence: Sequence,
    pub frame: RelayFrame,
    pub created_at: Millis,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RelayEnvelope {
    pub protocol_version: u16,
    pub engine_id: String,
    pub connection_epoch: Sequence,
    pub sequence: Sequence,
    pub acknowledgement: Sequence,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub resume_cursor: Option<Sequence>,
    pub fence_generation: Sequence,
    pub frame: RelayFrame,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RelayQueryError {
    pub code: String,
    pub message: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(
    tag = "type",
    content = "data",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum RelayFrame {
    Hello {
        app_server_version: String,
        capability_hash: String,
        process_epoch: Sequence,
    },
    Commands {
        commands: Vec<CommandRecord>,
    },
    CommandReceipts {
        receipts: Vec<CommandReceipt>,
    },
    Events {
        events: Vec<DurableEvent>,
    },
    Snapshot {
        snapshot: AuthoritativeSnapshot,
    },
    QueryRequest {
        request_id: String,
        method: String,
        params: Value,
    },
    QueryResponse {
        request_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        result: Option<Value>,
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<RelayQueryError>,
    },
    Ack,
    Ping {
        sent_at: Millis,
    },
    Pong {
        sent_at: Millis,
    },
    Error {
        code: String,
        message: String,
        retryable: bool,
    },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StoreMetadata {
    pub schema_version: u32,
    pub sqlite_version: String,
    pub journal_mode: String,
    pub synchronous: String,
}

fn default_engine() -> String {
    ENGINE_NAME.to_owned()
}

fn default_sidecar_mode() -> String {
    "fermin".to_owned()
}

fn default_true() -> bool {
    true
}

const fn default_mobile_schema_version() -> u16 {
    MOBILE_SCHEMA_VERSION
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn legacy_sessions_default_to_unmanaged_and_new_sessions_are_managed() {
        let new_session = SessionSummary::new("new", "project", "New", 1);
        assert!(new_session.managed_by_fermin);
        assert!(new_session.is_pinned);

        let mut legacy_json = serde_json::to_value(new_session).unwrap();
        let legacy_object = legacy_json.as_object_mut().unwrap();
        legacy_object.remove("managedByFermin");
        legacy_object.remove("isPinned");
        let legacy: SessionSummary = serde_json::from_value(legacy_json).unwrap();
        assert!(!legacy.managed_by_fermin);
        assert!(legacy.is_pinned);
    }

    #[test]
    fn session_previews_are_unicode_safe_and_strictly_bounded() {
        let long = "🧠".repeat(MAX_SESSION_PREVIEW_CHARS + 20);
        let bounded = bounded_session_preview(&long);
        assert_eq!(bounded.chars().count(), MAX_SESSION_PREVIEW_CHARS + 1);
        assert!(bounded.ends_with('…'));
        assert_eq!(bounded_session_preview("short"), "short");
    }
}
