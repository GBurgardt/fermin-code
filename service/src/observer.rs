use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::time::Duration;

use serde_json::{Map, Value, json};
use tokio::sync::broadcast;
use tokio::task::JoinHandle;
use tokio::time::{self, Instant};

use crate::appserver::{AppServerClient, AppServerError, AppServerEvent, AppServerLifecycle};
use crate::features::{
    FeatureError, IsolatedAppServer, IsolatedTurnFuture, IsolatedTurnRequest, IsolatedTurnResponse,
    MAX_OBSERVER_INPUT_BYTES, MAX_OBSERVER_OUTPUT_BYTES, OBSERVER_MODEL, OBSERVER_REASONING_EFFORT,
    OBSERVER_SERVICE_TIER, ObserverExecutionPolicy, SandboxPolicy, WorkflowKind,
};

const CLEANUP_TIMEOUT: Duration = Duration::from_secs(2);
const OBSERVER_HTTP_PROVIDER_ID: &str = "fermin_observer_http";
const CHATGPT_CODEX_BASE_URL: &str = "https://chatgpt.com/backend-api/codex";

type TransportFuture<'a, T> = Pin<Box<dyn Future<Output = Result<T, AppServerError>> + Send + 'a>>;

struct TurnWatch<'a> {
    thread_id: &'a str,
    turn_id: &'a str,
    workflow: WorkflowKind,
    max_output_bytes: usize,
    total_timeout: Duration,
    deadline: Instant,
}

trait ObserverTransport: Send + Sync {
    fn epoch(&self) -> u64;
    fn subscribe(&self) -> broadcast::Receiver<AppServerEvent>;
    fn request<'a>(
        &'a self,
        method: &'a str,
        params: Value,
        timeout: Duration,
    ) -> TransportFuture<'a, Value>;
    fn respond<'a>(&'a self, id: Value, result: Value) -> TransportFuture<'a, ()>;
}

impl ObserverTransport for AppServerClient {
    fn epoch(&self) -> u64 {
        AppServerClient::epoch(self)
    }

    fn subscribe(&self) -> broadcast::Receiver<AppServerEvent> {
        AppServerClient::subscribe(self)
    }

    fn request<'a>(
        &'a self,
        method: &'a str,
        params: Value,
        timeout: Duration,
    ) -> TransportFuture<'a, Value> {
        Box::pin(async move {
            self.request_with_timeout(method.to_owned(), params, timeout)
                .await
        })
    }

    fn respond<'a>(&'a self, id: Value, result: Value) -> TransportFuture<'a, ()> {
        Box::pin(async move { AppServerClient::respond(self, id, result).await })
    }
}

#[derive(Clone)]
pub struct AppServerObserver {
    transport: Arc<dyn ObserverTransport>,
}

impl AppServerObserver {
    pub fn new(client: AppServerClient) -> Self {
        Self {
            transport: Arc::new(client),
        }
    }

    pub fn epoch(&self) -> u64 {
        self.transport.epoch()
    }

    #[cfg(test)]
    fn from_transport(transport: Arc<dyn ObserverTransport>) -> Self {
        Self { transport }
    }

    async fn execute(
        &self,
        request: IsolatedTurnRequest,
    ) -> Result<IsolatedTurnResponse, FeatureError> {
        validate_request(&request)?;
        let workflow = request.workflow;
        let deadline = Instant::now() + request.timeout;

        // Subscribe before any RPC. App Server can emit lifecycle events before
        // thread/start and turn/start responses reach the request correlator.
        let mut events = self.transport.subscribe();
        let mut owned = OwnedThreadGuard::new(Arc::clone(&self.transport));
        let outcome = run_owned_turn(
            Arc::clone(&self.transport),
            &mut events,
            &mut owned,
            &request,
            deadline,
        )
        .await;

        let interrupt = outcome.is_err() && owned.turn_id.is_some();
        let cleanup = owned.cleanup(interrupt).await;
        match outcome {
            Ok(output) => {
                cleanup.map_err(|error| {
                    FeatureError::AppServer(format!("observer thread cleanup failed: {error}"))
                })?;
                Ok(IsolatedTurnResponse {
                    output,
                    applied_policy: ObserverExecutionPolicy::luna_high(),
                })
            }
            Err(error) => {
                let _ = cleanup;
                if matches!(error, FeatureError::Timeout { .. }) {
                    Err(FeatureError::Timeout {
                        workflow,
                        timeout_ms: request.timeout.as_millis(),
                    })
                } else {
                    Err(error)
                }
            }
        }
    }
}

impl IsolatedAppServer for AppServerObserver {
    fn run_isolated(&self, request: IsolatedTurnRequest) -> IsolatedTurnFuture<'_> {
        Box::pin(self.execute(request))
    }
}

struct OwnedThreadGuard {
    transport: Arc<dyn ObserverTransport>,
    thread_id: Option<String>,
    turn_id: Option<String>,
    armed: bool,
}

struct PendingThreadStart {
    transport: Arc<dyn ObserverTransport>,
    task: Option<JoinHandle<Result<Value, FeatureError>>>,
    thread_id: Option<String>,
    armed: bool,
}

struct PendingTurnStart {
    transport: Arc<dyn ObserverTransport>,
    task: Option<JoinHandle<Result<Value, FeatureError>>>,
    thread_id: Option<String>,
    turn_id: Option<String>,
    armed: bool,
}

impl PendingThreadStart {
    fn spawn(
        transport: Arc<dyn ObserverTransport>,
        params: Value,
        workflow: WorkflowKind,
        total_timeout: Duration,
        deadline: Instant,
    ) -> Self {
        let request_transport = Arc::clone(&transport);
        let task = tokio::spawn(async move {
            request_rpc(
                &request_transport,
                "thread/start",
                params,
                workflow,
                total_timeout,
                deadline,
            )
            .await
        });
        Self {
            transport,
            task: Some(task),
            thread_id: None,
            armed: true,
        }
    }

    async fn wait(&mut self) -> Result<String, FeatureError> {
        let response = self
            .task
            .as_mut()
            .expect("pending thread/start task must exist")
            .await;
        self.task.take();
        let response = response.map_err(|error| {
            FeatureError::AppServer(format!("observer thread/start task failed: {error}"))
        })??;
        let thread_id = thread_start_id(&response)?;
        self.thread_id = Some(thread_id.clone());
        validate_thread_start_policy(&response)?;
        Ok(thread_id)
    }

    fn transfer_to(&mut self, owned: &mut OwnedThreadGuard) {
        owned.thread_id = self.thread_id.take();
        self.armed = false;
    }
}

impl Drop for PendingThreadStart {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        let transport = Arc::clone(&self.transport);
        let known_thread_id = self.thread_id.take();
        let task = self.task.take();
        if let Ok(runtime) = tokio::runtime::Handle::try_current() {
            runtime.spawn(async move {
                let thread_id = match (known_thread_id, task) {
                    (Some(thread_id), _) => Some(thread_id),
                    (None, Some(task)) => match task.await {
                        Ok(Ok(response)) => thread_start_id(&response).ok(),
                        Ok(Err(_)) | Err(_) => None,
                    },
                    (None, None) => None,
                };
                if let Some(thread_id) = thread_id {
                    let _ = time::timeout(
                        CLEANUP_TIMEOUT,
                        cleanup_owned_thread(transport, thread_id, None, false),
                    )
                    .await;
                }
            });
        } else if let Some(task) = task {
            task.abort();
        }
    }
}

impl PendingTurnStart {
    fn spawn(
        transport: Arc<dyn ObserverTransport>,
        owned: &mut OwnedThreadGuard,
        params: Value,
        workflow: WorkflowKind,
        total_timeout: Duration,
        deadline: Instant,
    ) -> Self {
        let thread_id = owned
            .thread_id
            .take()
            .expect("pending turn/start must take ownership of a thread");
        let request_transport = Arc::clone(&transport);
        let task = tokio::spawn(async move {
            request_rpc(
                &request_transport,
                "turn/start",
                params,
                workflow,
                total_timeout,
                deadline,
            )
            .await
        });
        Self {
            transport,
            task: Some(task),
            thread_id: Some(thread_id),
            turn_id: None,
            armed: true,
        }
    }

    async fn wait(&mut self) -> Result<String, FeatureError> {
        let response = self
            .task
            .as_mut()
            .expect("pending turn/start task must exist")
            .await;
        self.task.take();
        let response = response.map_err(|error| {
            FeatureError::AppServer(format!("observer turn/start task failed: {error}"))
        })??;
        let turn_id = turn_start_id(&response)?;
        self.turn_id = Some(turn_id.clone());
        Ok(turn_id)
    }

    fn transfer_to(&mut self, owned: &mut OwnedThreadGuard) {
        owned.thread_id = self.thread_id.take();
        owned.turn_id = self.turn_id.take();
        self.armed = false;
    }
}

impl Drop for PendingTurnStart {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        let transport = Arc::clone(&self.transport);
        let thread_id = self.thread_id.take();
        let known_turn_id = self.turn_id.take();
        let task = self.task.take();
        if let Ok(runtime) = tokio::runtime::Handle::try_current() {
            runtime.spawn(async move {
                let turn_id = match (known_turn_id, task) {
                    (Some(turn_id), _) => Some(turn_id),
                    (None, Some(task)) => match task.await {
                        Ok(Ok(response)) => turn_start_id(&response).ok(),
                        Ok(Err(_)) | Err(_) => None,
                    },
                    (None, None) => None,
                };
                if let Some(thread_id) = thread_id {
                    let interrupt = turn_id.is_some();
                    let _ = time::timeout(
                        CLEANUP_TIMEOUT,
                        cleanup_owned_thread(transport, thread_id, turn_id, interrupt),
                    )
                    .await;
                }
            });
        } else if let Some(task) = task {
            task.abort();
        }
    }
}

impl OwnedThreadGuard {
    fn new(transport: Arc<dyn ObserverTransport>) -> Self {
        Self {
            transport,
            thread_id: None,
            turn_id: None,
            armed: true,
        }
    }

    async fn cleanup(&mut self, interrupt: bool) -> Result<(), AppServerError> {
        let Some(thread_id) = self.thread_id.clone() else {
            self.armed = false;
            return Ok(());
        };
        let result = cleanup_owned_thread(
            Arc::clone(&self.transport),
            thread_id,
            self.turn_id.clone(),
            interrupt,
        )
        .await;
        self.armed = false;
        result
    }
}

impl Drop for OwnedThreadGuard {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        let Some(thread_id) = self.thread_id.clone() else {
            return;
        };
        let transport = Arc::clone(&self.transport);
        let turn_id = self.turn_id.clone();
        if let Ok(runtime) = tokio::runtime::Handle::try_current() {
            runtime.spawn(async move {
                let _ = time::timeout(
                    CLEANUP_TIMEOUT,
                    cleanup_owned_thread(transport, thread_id, turn_id, true),
                )
                .await;
            });
        }
    }
}

async fn run_owned_turn(
    transport: Arc<dyn ObserverTransport>,
    events: &mut broadcast::Receiver<AppServerEvent>,
    owned: &mut OwnedThreadGuard,
    request: &IsolatedTurnRequest,
    deadline: Instant,
) -> Result<Value, FeatureError> {
    let catalog = request_rpc(
        &transport,
        "model/list",
        json!({ "includeHidden": true, "limit": 100 }),
        request.workflow,
        request.timeout,
        deadline,
    )
    .await?;
    validate_model_catalog(&catalog)?;

    let mut config_read_params = json!({ "includeLayers": false });
    if let Some(cwd) = &request.working_directory {
        config_read_params["cwd"] = Value::String(cwd.to_string_lossy().into_owned());
    }
    let config_read = request_rpc(
        &transport,
        "config/read",
        config_read_params,
        request.workflow,
        request.timeout,
        deadline,
    )
    .await?;
    let observer_config = observer_config_overlay(&config_read);

    let mut thread_params = json!({
        "model": OBSERVER_MODEL,
        "approvalPolicy": "never",
        "sandbox": "read-only",
        "ephemeral": true,
        "developerInstructions": request.developer_instructions,
        "config": observer_config,
        "environments": [],
        "dynamicTools": [],
        "selectedCapabilityRoots": [],
        "experimentalRawEvents": false
    });
    if let Some(cwd) = &request.working_directory {
        thread_params["cwd"] = Value::String(cwd.to_string_lossy().into_owned());
    }
    let mut pending_thread = PendingThreadStart::spawn(
        Arc::clone(&transport),
        thread_params,
        request.workflow,
        request.timeout,
        deadline,
    );
    let thread_id = pending_thread.wait().await?;
    pending_thread.transfer_to(owned);

    let mut turn_params = json!({
        "threadId": thread_id,
        "input": [{ "type": "text", "text": request.user_message }],
        "approvalPolicy": "never",
        "sandboxPolicy": { "type": "readOnly", "networkAccess": false },
        "model": OBSERVER_MODEL,
        "effort": OBSERVER_REASONING_EFFORT,
        // Prompt improvement is a blocking prerequisite for the user's send.
        // Keep Luna/high and the independent fidelity turn, but request the
        // supported priority tier so the normal path does not sit in the
        // standard backend queue.
        "serviceTier": OBSERVER_SERVICE_TIER,
        "outputSchema": request.output_schema,
        "environments": []
    });
    if let Some(cwd) = &request.working_directory {
        turn_params["cwd"] = Value::String(cwd.to_string_lossy().into_owned());
    }
    let mut pending_turn = PendingTurnStart::spawn(
        Arc::clone(&transport),
        owned,
        turn_params,
        request.workflow,
        request.timeout,
        deadline,
    );
    let turn_id = pending_turn.wait().await?;
    pending_turn.transfer_to(owned);

    let watch = TurnWatch {
        thread_id: &thread_id,
        turn_id: &turn_id,
        workflow: request.workflow,
        max_output_bytes: request.max_output_bytes,
        total_timeout: request.timeout,
        deadline,
    };
    wait_for_authoritative_output(&transport, events, &watch).await
}

async fn wait_for_authoritative_output(
    transport: &Arc<dyn ObserverTransport>,
    events: &mut broadcast::Receiver<AppServerEvent>,
    watch: &TurnWatch<'_>,
) -> Result<Value, FeatureError> {
    let mut completed_agent_text: Option<String> = None;
    loop {
        let event = time::timeout_at(watch.deadline, events.recv())
            .await
            .map_err(|_| FeatureError::Timeout {
                workflow: watch.workflow,
                timeout_ms: watch.total_timeout.as_millis(),
            })?
            .map_err(|error| match error {
                broadcast::error::RecvError::Lagged(count) => FeatureError::AppServer(format!(
                    "observer event stream lagged by {count} messages"
                )),
                broadcast::error::RecvError::Closed => {
                    FeatureError::AppServer("observer event stream closed".to_owned())
                }
            })?;

        match event {
            AppServerEvent::Lifecycle {
                epoch,
                state: AppServerLifecycle::Failed,
                detail,
            } if epoch == transport.epoch() => {
                return Err(FeatureError::AppServer(
                    detail.unwrap_or_else(|| "App Server process failed".to_owned()),
                ));
            }
            AppServerEvent::ServerRequest {
                id, method, params, ..
            } if event_matches_owned(&params, watch.thread_id, Some(watch.turn_id)) => {
                let response = cancellation_response(&method);
                respond_before_deadline(
                    transport,
                    id,
                    response,
                    watch.workflow,
                    watch.total_timeout,
                    watch.deadline,
                )
                .await?;
            }
            AppServerEvent::Notification { method, params, .. }
                if event_matches_owned(&params, watch.thread_id, Some(watch.turn_id)) =>
            {
                match method.as_str() {
                    "item/completed" => {
                        if let Some(text) = agent_message_text(params.get("item")) {
                            enforce_text_bound(text, watch.max_output_bytes, watch.workflow)?;
                            let is_final = params.pointer("/item/phase").and_then(Value::as_str)
                                == Some("final_answer");
                            if is_final || completed_agent_text.is_none() {
                                completed_agent_text = Some(text.to_owned());
                            }
                        }
                    }
                    "thread/status/changed"
                        if params.pointer("/status/type").and_then(Value::as_str)
                            == Some("systemError") =>
                    {
                        let message = params
                            .pointer("/status/error/message")
                            .or_else(|| params.pointer("/status/message"))
                            .and_then(Value::as_str)
                            .unwrap_or("observer thread entered system error state");
                        return Err(FeatureError::AppServer(message.to_owned()));
                    }
                    "error" if params.get("willRetry").and_then(Value::as_bool) != Some(true) => {
                        let message = params
                            .pointer("/error/message")
                            .or_else(|| params.get("message"))
                            .and_then(Value::as_str)
                            .unwrap_or("observer App Server error");
                        return Err(FeatureError::AppServer(message.to_owned()));
                    }
                    "turn/completed" => {
                        let turn = params.get("turn").ok_or_else(|| {
                            FeatureError::AppServer(
                                "turn/completed omitted the authoritative turn".to_owned(),
                            )
                        })?;
                        let status = turn
                            .get("status")
                            .and_then(Value::as_str)
                            .unwrap_or("failed");
                        if status != "completed" {
                            let message = turn
                                .pointer("/error/message")
                                .and_then(Value::as_str)
                                .map(str::to_owned)
                                .unwrap_or_else(|| format!("observer turn ended as {status}"));
                            return Err(FeatureError::AppServer(message));
                        }
                        let final_text = authoritative_turn_text(turn)
                            .or(completed_agent_text.as_deref())
                            .ok_or_else(|| FeatureError::InvalidOutput {
                                workflow: watch.workflow,
                                message: "completed turn contained no final agentMessage"
                                    .to_owned(),
                            })?;
                        return parse_structured_output(
                            final_text,
                            watch.max_output_bytes,
                            watch.workflow,
                        );
                    }
                    _ => {}
                }
            }
            _ => {}
        }
    }
}

async fn request_rpc(
    transport: &Arc<dyn ObserverTransport>,
    method: &str,
    params: Value,
    workflow: WorkflowKind,
    total_timeout: Duration,
    deadline: Instant,
) -> Result<Value, FeatureError> {
    let remaining = deadline.saturating_duration_since(Instant::now());
    if remaining.is_zero() {
        return Err(FeatureError::Timeout {
            workflow,
            timeout_ms: total_timeout.as_millis(),
        });
    }
    time::timeout_at(deadline, transport.request(method, params, remaining))
        .await
        .map_err(|_| FeatureError::Timeout {
            workflow,
            timeout_ms: total_timeout.as_millis(),
        })?
        .map_err(|error| FeatureError::AppServer(error.to_string()))
}

async fn respond_before_deadline(
    transport: &Arc<dyn ObserverTransport>,
    id: Value,
    result: Value,
    workflow: WorkflowKind,
    total_timeout: Duration,
    deadline: Instant,
) -> Result<(), FeatureError> {
    time::timeout_at(deadline, transport.respond(id, result))
        .await
        .map_err(|_| FeatureError::Timeout {
            workflow,
            timeout_ms: total_timeout.as_millis(),
        })?
        .map_err(|error| FeatureError::AppServer(error.to_string()))
}

async fn cleanup_owned_thread(
    transport: Arc<dyn ObserverTransport>,
    thread_id: String,
    turn_id: Option<String>,
    interrupt: bool,
) -> Result<(), AppServerError> {
    let deadline = Instant::now() + CLEANUP_TIMEOUT;
    let mut interrupt_error = None;
    if interrupt && let Some(turn_id) = turn_id {
        let remaining = deadline.saturating_duration_since(Instant::now());
        let interrupt_budget = remaining.min(CLEANUP_TIMEOUT / 2);
        if !interrupt_budget.is_zero()
            && let Err(error) = transport
                .request(
                    "turn/interrupt",
                    json!({ "threadId": thread_id, "turnId": turn_id }),
                    interrupt_budget,
                )
                .await
        {
            interrupt_error = Some(error);
        }
    }

    let remaining = deadline.saturating_duration_since(Instant::now());
    if remaining.is_zero() {
        return Err(interrupt_error.unwrap_or(AppServerError::Timeout {
            epoch: transport.epoch(),
            method: "thread/unsubscribe".to_owned(),
            timeout: CLEANUP_TIMEOUT,
        }));
    }
    let unsubscribe = transport
        .request(
            "thread/unsubscribe",
            json!({ "threadId": thread_id }),
            remaining,
        )
        .await;
    match unsubscribe {
        Ok(_) => Ok(()),
        Err(error) => Err(error),
    }
}

fn validate_request(request: &IsolatedTurnRequest) -> Result<(), FeatureError> {
    request.policy.validate()?;
    if request.policy != ObserverExecutionPolicy::luna_high() {
        return Err(FeatureError::PolicyViolation(
            "observer adapter accepts only the exact Luna/high policy".to_owned(),
        ));
    }
    if request.developer_instructions.trim().is_empty() {
        return Err(FeatureError::MissingInput {
            field: "developerInstructions",
        });
    }
    if request.user_message.trim().is_empty() {
        return Err(FeatureError::MissingInput {
            field: "observerInput",
        });
    }
    let input_bytes = request
        .developer_instructions
        .len()
        .saturating_add(request.user_message.len());
    if input_bytes > MAX_OBSERVER_INPUT_BYTES {
        return Err(FeatureError::InputTooLarge {
            field: "observerInput",
            max_bytes: MAX_OBSERVER_INPUT_BYTES,
        });
    }
    if request.timeout.is_zero() {
        return Err(FeatureError::PolicyViolation(
            "observer timeout must be greater than zero".to_owned(),
        ));
    }
    if request.max_output_bytes == 0 || request.max_output_bytes > MAX_OBSERVER_OUTPUT_BYTES {
        return Err(FeatureError::PolicyViolation(format!(
            "observer output bound must be between 1 and {MAX_OBSERVER_OUTPUT_BYTES} bytes"
        )));
    }
    if !request.output_schema.is_object() {
        return Err(FeatureError::InvalidContext(
            "observer outputSchema must be a JSON object".to_owned(),
        ));
    }
    if request.policy.sandbox_policy
        != (SandboxPolicy::ReadOnly {
            network_access: false,
        })
    {
        return Err(FeatureError::PolicyViolation(
            "observer requires read-only sandboxing with network disabled".to_owned(),
        ));
    }
    Ok(())
}

fn validate_model_catalog(catalog: &Value) -> Result<(), FeatureError> {
    let model = catalog
        .get("data")
        .and_then(Value::as_array)
        .and_then(|models| {
            models.iter().find(|model| {
                model.get("id").and_then(Value::as_str) == Some(OBSERVER_MODEL)
                    || model.get("model").and_then(Value::as_str) == Some(OBSERVER_MODEL)
            })
        })
        .ok_or_else(|| {
            FeatureError::PolicyViolation(format!(
                "required observer model {OBSERVER_MODEL} is unavailable"
            ))
        })?;
    let supports_high = model
        .get("supportedReasoningEfforts")
        .and_then(Value::as_array)
        .is_some_and(|efforts| {
            efforts.iter().any(|entry| {
                entry.as_str() == Some(OBSERVER_REASONING_EFFORT)
                    || entry.get("reasoningEffort").and_then(Value::as_str)
                        == Some(OBSERVER_REASONING_EFFORT)
            })
        });
    if !supports_high {
        return Err(FeatureError::PolicyViolation(format!(
            "required observer effort {OBSERVER_REASONING_EFFORT} is unavailable for {OBSERVER_MODEL}"
        )));
    }
    Ok(())
}

fn observer_config_overlay(config_read: &Value) -> Value {
    let configured_servers = config_read
        .pointer("/config/mcp_servers")
        .or_else(|| config_read.pointer("/config/mcpServers"))
        .and_then(Value::as_object);
    let mut disabled_servers = Map::new();
    if let Some(configured_servers) = configured_servers {
        let mut names: Vec<&String> = configured_servers
            .keys()
            .filter(|name| !name.is_empty())
            .collect();
        names.sort_unstable();
        for name in names {
            disabled_servers.insert(name.clone(), json!({ "enabled": false }));
        }
    }
    json!({
        // Observer turns are short, blocking prerequisites for user sends. The
        // regular Codex runtime may prefer WebSockets, but retrying a broken WS
        // handshake five times can consume the observer's entire deadline.
        // Give only these ephemeral turns a dedicated HTTPS/SSE provider while
        // retaining the same current runtime, OpenAI login, model, and effort.
        "model_provider": OBSERVER_HTTP_PROVIDER_ID,
        "model_providers": {
            (OBSERVER_HTTP_PROVIDER_ID): {
                "name": "Fermin Observer HTTPS",
                "base_url": CHATGPT_CODEX_BASE_URL,
                "wire_api": "responses",
                "requires_openai_auth": true,
                "supports_websockets": false
            }
        },
        "model_reasoning_effort": OBSERVER_REASONING_EFFORT,
        "sandbox_mode": "read-only",
        "web_search": "disabled",
        "mcp_servers": disabled_servers,
        "features": { "plugins": false }
    })
}

fn thread_start_id(result: &Value) -> Result<String, FeatureError> {
    result
        .pointer("/thread/id")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .map(str::to_owned)
        .ok_or_else(|| {
            FeatureError::AppServer("thread/start returned no owned thread id".to_owned())
        })
}

fn validate_thread_start_policy(result: &Value) -> Result<(), FeatureError> {
    let exact = result.get("model").and_then(Value::as_str) == Some(OBSERVER_MODEL)
        && result.get("reasoningEffort").and_then(Value::as_str) == Some(OBSERVER_REASONING_EFFORT)
        && result.get("approvalPolicy").and_then(Value::as_str) == Some("never")
        && result.pointer("/thread/ephemeral").and_then(Value::as_bool) == Some(true)
        && result.pointer("/sandbox/type").and_then(Value::as_str) == Some("readOnly")
        && !result
            .pointer("/sandbox/networkAccess")
            .and_then(Value::as_bool)
            .unwrap_or(false);
    if !exact {
        return Err(FeatureError::PolicyViolation(
            "thread/start did not confirm Luna/high, never approval, ephemeral read-only/no-network execution"
                .to_owned(),
        ));
    }
    Ok(())
}

fn turn_start_id(result: &Value) -> Result<String, FeatureError> {
    result
        .pointer("/turn/id")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .map(str::to_owned)
        .ok_or_else(|| FeatureError::AppServer("turn/start returned no owned turn id".to_owned()))
}

fn event_matches_owned(params: &Value, thread_id: &str, turn_id: Option<&str>) -> bool {
    let event_thread_id = params
        .get("threadId")
        .or_else(|| params.pointer("/thread/id"))
        .or_else(|| params.pointer("/thread/threadId"))
        .and_then(Value::as_str);
    if event_thread_id != Some(thread_id) {
        return false;
    }
    let Some(turn_id) = turn_id else {
        return true;
    };
    let event_turn_id = params
        .get("turnId")
        .or_else(|| params.pointer("/turn/id"))
        .and_then(Value::as_str);
    event_turn_id.is_none_or(|event_turn_id| event_turn_id == turn_id)
}

fn cancellation_response(method: &str) -> Value {
    match method {
        "item/tool/requestUserInput" => json!({ "answers": {} }),
        "mcpServer/elicitation/request" => json!({ "action": "cancel", "content": null }),
        _ => json!({ "decision": "cancel" }),
    }
}

fn agent_message_text(item: Option<&Value>) -> Option<&str> {
    let item = item?;
    (item.get("type").and_then(Value::as_str) == Some("agentMessage"))
        .then(|| item.get("text").and_then(Value::as_str))
        .flatten()
}

fn authoritative_turn_text(turn: &Value) -> Option<&str> {
    let items = turn.get("items")?.as_array()?;
    items
        .iter()
        .rev()
        .find(|item| {
            item.get("type").and_then(Value::as_str) == Some("agentMessage")
                && item.get("phase").and_then(Value::as_str) == Some("final_answer")
        })
        .and_then(|item| item.get("text").and_then(Value::as_str))
        .or_else(|| {
            items
                .iter()
                .rev()
                .find_map(|item| agent_message_text(Some(item)))
        })
}

fn enforce_text_bound(
    text: &str,
    max_output_bytes: usize,
    workflow: WorkflowKind,
) -> Result<(), FeatureError> {
    if text.len() > max_output_bytes {
        Err(FeatureError::InvalidOutput {
            workflow,
            message: format!("agentMessage exceeds {max_output_bytes} bytes"),
        })
    } else {
        Ok(())
    }
}

fn parse_structured_output(
    text: &str,
    max_output_bytes: usize,
    workflow: WorkflowKind,
) -> Result<Value, FeatureError> {
    let text = text.trim();
    enforce_text_bound(text, max_output_bytes, workflow)?;
    if text.is_empty() {
        return Err(FeatureError::InvalidOutput {
            workflow,
            message: "final agentMessage is empty".to_owned(),
        });
    }
    let output: Value =
        serde_json::from_str(text).map_err(|error| FeatureError::InvalidOutput {
            workflow,
            message: format!("final agentMessage is not structured JSON: {error}"),
        })?;
    if !output.is_object() {
        return Err(FeatureError::InvalidOutput {
            workflow,
            message: "structured observer output must be an object".to_owned(),
        });
    }
    let serialized = serde_json::to_vec(&output)
        .map_err(|error| FeatureError::Serialization(error.to_string()))?;
    if serialized.len() > max_output_bytes {
        return Err(FeatureError::InvalidOutput {
            workflow,
            message: format!("serialized observer output exceeds {max_output_bytes} bytes"),
        });
    }
    Ok(output)
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};

    use super::*;
    use crate::features::{ApprovalPolicy, ObserverExecutionPolicy};
    use tokio::sync::Notify;

    #[derive(Clone, Copy)]
    enum FakeMode {
        Complete,
        Pending,
        DelayedThreadStart,
        DelayedTurnStart,
        InvalidThreadPolicy,
        Failed,
        InvalidJson,
    }

    #[derive(Clone, Debug)]
    struct Call {
        method: String,
        params: Value,
    }

    struct FakeTransport {
        events: broadcast::Sender<AppServerEvent>,
        calls: Mutex<Vec<Call>>,
        mode: FakeMode,
        thread_start_release: Arc<Notify>,
        turn_start_release: Arc<Notify>,
    }

    impl FakeTransport {
        fn new(mode: FakeMode) -> Arc<Self> {
            let (events, _) = broadcast::channel(32);
            Arc::new(Self {
                events,
                calls: Mutex::new(Vec::new()),
                mode,
                thread_start_release: Arc::new(Notify::new()),
                turn_start_release: Arc::new(Notify::new()),
            })
        }

        fn calls(&self) -> Vec<Call> {
            self.calls.lock().unwrap().clone()
        }

        fn record(&self, method: &str, params: Value) {
            self.calls.lock().unwrap().push(Call {
                method: method.to_owned(),
                params,
            });
        }

        fn emit_completed(&self) {
            let _ = self.events.send(AppServerEvent::Notification {
                epoch: self.epoch(),
                method: "turn/completed".to_owned(),
                params: json!({
                    "threadId": "interactive-thread",
                    "turn": {
                        "id": "interactive-turn",
                        "status": "completed",
                        "items": [{
                            "id": "interactive-message",
                            "type": "agentMessage",
                            "phase": "final_answer",
                            "text": "{\"source\":\"interactive\"}"
                        }]
                    }
                }),
            });
            let _ = self.events.send(AppServerEvent::ServerRequest {
                epoch: self.epoch(),
                id: json!("approval-1"),
                method: "item/commandExecution/requestApproval".to_owned(),
                params: json!({ "threadId": "observer-thread", "turnId": "observer-turn" }),
            });
            let text = match self.mode {
                FakeMode::InvalidJson => "not json",
                _ => "{\"source\":\"item-completed\"}",
            };
            let _ = self.events.send(AppServerEvent::Notification {
                epoch: self.epoch(),
                method: "item/completed".to_owned(),
                params: json!({
                    "threadId": "observer-thread",
                    "turnId": "observer-turn",
                    "item": {
                        "id": "observer-message",
                        "type": "agentMessage",
                        "phase": "final_answer",
                        "text": text
                    }
                }),
            });
            let turn = match self.mode {
                FakeMode::Failed => json!({
                    "id": "observer-turn",
                    "status": "failed",
                    "error": { "message": "synthetic turn failure" },
                    "items": []
                }),
                FakeMode::InvalidJson => json!({
                    "id": "observer-turn",
                    "status": "completed",
                    "items": [{
                        "id": "observer-message",
                        "type": "agentMessage",
                        "phase": "final_answer",
                        "text": "not json"
                    }]
                }),
                _ => json!({
                    "id": "observer-turn",
                    "status": "completed",
                    "items": [{
                        "id": "observer-message",
                        "type": "agentMessage",
                        "phase": "final_answer",
                        "text": "{\"source\":\"turn-completed\"}"
                    }]
                }),
            };
            let _ = self.events.send(AppServerEvent::Notification {
                epoch: self.epoch(),
                method: "turn/completed".to_owned(),
                params: json!({ "threadId": "observer-thread", "turn": turn }),
            });
        }
    }

    impl ObserverTransport for FakeTransport {
        fn epoch(&self) -> u64 {
            41
        }

        fn subscribe(&self) -> broadcast::Receiver<AppServerEvent> {
            self.record("subscribe", Value::Null);
            self.events.subscribe()
        }

        fn request<'a>(
            &'a self,
            method: &'a str,
            params: Value,
            _timeout: Duration,
        ) -> TransportFuture<'a, Value> {
            self.record(method, params);
            Box::pin(async move {
                match method {
                    "model/list" => Ok(json!({
                        "data": [{
                            "id": OBSERVER_MODEL,
                            "model": OBSERVER_MODEL,
                            "supportedReasoningEfforts": [
                                { "reasoningEffort": "low" },
                                { "reasoningEffort": OBSERVER_REASONING_EFFORT }
                            ]
                        }]
                    })),
                    "config/read" => Ok(json!({
                        "config": {
                            "mcp_servers": {
                                "alpha": { "command": "secret-alpha-command" },
                                "beta": { "http_headers": { "Authorization": "secret" } }
                            }
                        }
                    })),
                    "thread/start" => {
                        if matches!(self.mode, FakeMode::DelayedThreadStart) {
                            self.thread_start_release.notified().await;
                        }
                        Ok(json!({
                            "thread": { "id": "observer-thread", "ephemeral": true },
                            "model": if matches!(self.mode, FakeMode::InvalidThreadPolicy) {
                                "wrong-model"
                            } else {
                                OBSERVER_MODEL
                            },
                            "reasoningEffort": OBSERVER_REASONING_EFFORT,
                            "approvalPolicy": "never",
                            "sandbox": { "type": "readOnly", "networkAccess": false }
                        }))
                    }
                    "turn/start" => {
                        if matches!(self.mode, FakeMode::DelayedTurnStart) {
                            self.turn_start_release.notified().await;
                        }
                        if !matches!(self.mode, FakeMode::Pending) {
                            self.emit_completed();
                        }
                        Ok(json!({
                            "turn": { "id": "observer-turn", "status": "inProgress", "items": [] }
                        }))
                    }
                    "turn/interrupt" => Ok(json!({})),
                    "thread/unsubscribe" => Ok(json!({ "status": "unsubscribed" })),
                    _ => Err(AppServerError::Rpc {
                        method: method.to_owned(),
                        code: -32601,
                        message: "unknown fake method".to_owned(),
                        data: None,
                    }),
                }
            })
        }

        fn respond<'a>(&'a self, id: Value, result: Value) -> TransportFuture<'a, ()> {
            self.record("server/respond", json!({ "id": id, "result": result }));
            Box::pin(async { Ok(()) })
        }
    }

    fn request() -> IsolatedTurnRequest {
        IsolatedTurnRequest {
            workflow: WorkflowKind::Explainer,
            policy: ObserverExecutionPolicy {
                model: OBSERVER_MODEL.to_owned(),
                reasoning_effort: OBSERVER_REASONING_EFFORT.to_owned(),
                approval_policy: ApprovalPolicy::Never,
                sandbox_policy: SandboxPolicy::ReadOnly {
                    network_access: false,
                },
                ephemeral: true,
            },
            developer_instructions: "Return the required structured object.".to_owned(),
            user_message: "Explain the synthetic result.".to_owned(),
            working_directory: Some("/tmp/observer-workspace".into()),
            output_schema: json!({
                "type": "object",
                "properties": { "source": { "type": "string" } },
                "required": ["source"],
                "additionalProperties": false
            }),
            timeout: Duration::from_secs(2),
            max_output_bytes: 4096,
        }
    }

    fn observer(transport: Arc<FakeTransport>) -> AppServerObserver {
        AppServerObserver::from_transport(transport)
    }

    #[tokio::test]
    async fn applies_exact_policy_and_prefers_authoritative_turn_payload() {
        let transport = FakeTransport::new(FakeMode::Complete);
        let response = observer(Arc::clone(&transport))
            .run_isolated(request())
            .await
            .unwrap();
        assert_eq!(response.output, json!({ "source": "turn-completed" }));
        assert_eq!(
            response.applied_policy,
            ObserverExecutionPolicy::luna_high()
        );

        let calls = transport.calls();
        assert_eq!(calls[0].method, "subscribe");
        assert_eq!(calls[1].method, "model/list");
        assert_eq!(calls[2].method, "config/read");
        assert_eq!(calls[3].method, "thread/start");
        assert_eq!(calls[4].method, "turn/start");
        let thread = &calls[3].params;
        assert_eq!(thread["model"], OBSERVER_MODEL);
        assert_eq!(thread["approvalPolicy"], "never");
        assert_eq!(thread["sandbox"], "read-only");
        assert_eq!(thread["ephemeral"], true);
        assert_eq!(
            thread["config"]["model_reasoning_effort"],
            OBSERVER_REASONING_EFFORT
        );
        assert_eq!(thread["config"]["sandbox_mode"], "read-only");
        assert_eq!(thread["config"]["web_search"], "disabled");
        assert_eq!(thread["config"]["features"]["plugins"], false);
        assert_eq!(
            thread["config"]["model_provider"],
            OBSERVER_HTTP_PROVIDER_ID
        );
        assert_eq!(
            thread["config"]["model_providers"][OBSERVER_HTTP_PROVIDER_ID]["base_url"],
            CHATGPT_CODEX_BASE_URL
        );
        assert_eq!(
            thread["config"]["model_providers"][OBSERVER_HTTP_PROVIDER_ID]["requires_openai_auth"],
            true
        );
        assert_eq!(
            thread["config"]["model_providers"][OBSERVER_HTTP_PROVIDER_ID]["supports_websockets"],
            false
        );
        assert_eq!(
            thread["config"]["mcp_servers"]["alpha"],
            json!({ "enabled": false })
        );
        assert_eq!(
            thread["config"]["mcp_servers"]["beta"],
            json!({ "enabled": false })
        );
        assert!(!thread["config"].to_string().contains("secret"));

        let turn = &calls[4].params;
        assert_eq!(turn["threadId"], "observer-thread");
        assert_eq!(turn["model"], OBSERVER_MODEL);
        assert_eq!(turn["effort"], OBSERVER_REASONING_EFFORT);
        assert_eq!(turn["serviceTier"], OBSERVER_SERVICE_TIER);
        assert_eq!(turn["approvalPolicy"], "never");
        assert_eq!(
            turn["sandboxPolicy"],
            json!({ "type": "readOnly", "networkAccess": false })
        );
        assert_eq!(turn["outputSchema"], request().output_schema);
        assert!(calls.iter().any(|call| {
            call.method == "server/respond"
                && call.params["result"] == json!({ "decision": "cancel" })
        }));
        assert_eq!(calls.last().unwrap().method, "thread/unsubscribe");
        assert!(!calls.iter().any(|call| call.method == "turn/interrupt"));
    }

    #[tokio::test]
    async fn failed_turn_interrupts_then_releases_only_the_owned_thread() {
        let transport = FakeTransport::new(FakeMode::Failed);
        let error = match observer(Arc::clone(&transport))
            .run_isolated(request())
            .await
        {
            Ok(_) => panic!("failed turn unexpectedly succeeded"),
            Err(error) => error,
        };
        assert!(error.to_string().contains("synthetic turn failure"));
        let calls = transport.calls();
        let interrupt = calls
            .iter()
            .position(|call| call.method == "turn/interrupt")
            .unwrap();
        let unsubscribe = calls
            .iter()
            .position(|call| call.method == "thread/unsubscribe")
            .unwrap();
        assert!(interrupt < unsubscribe);
        assert_eq!(calls[interrupt].params["threadId"], "observer-thread");
        assert_eq!(calls[interrupt].params["turnId"], "observer-turn");
        assert_eq!(calls[unsubscribe].params["threadId"], "observer-thread");
        assert!(
            !calls
                .iter()
                .any(|call| call.params.to_string().contains("interactive-thread"))
        );
    }

    #[tokio::test]
    async fn cancellation_best_effort_interrupts_and_unsubscribes() {
        let transport = FakeTransport::new(FakeMode::Pending);
        let observer = observer(Arc::clone(&transport));
        let task = tokio::spawn(async move { observer.run_isolated(request()).await });

        time::timeout(Duration::from_secs(1), async {
            loop {
                if transport
                    .calls()
                    .iter()
                    .any(|call| call.method == "turn/start")
                {
                    break;
                }
                time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .unwrap();
        task.abort();
        assert!(matches!(task.await, Err(error) if error.is_cancelled()));

        time::timeout(Duration::from_secs(1), async {
            loop {
                let calls = transport.calls();
                if calls.iter().any(|call| call.method == "turn/interrupt")
                    && calls.iter().any(|call| call.method == "thread/unsubscribe")
                {
                    break;
                }
                time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .unwrap();
    }

    #[tokio::test]
    async fn rejects_non_json_final_output_and_still_cleans_up() {
        let transport = FakeTransport::new(FakeMode::InvalidJson);
        let error = match observer(Arc::clone(&transport))
            .run_isolated(request())
            .await
        {
            Ok(_) => panic!("invalid output unexpectedly succeeded"),
            Err(error) => error,
        };
        assert!(error.to_string().contains("not structured JSON"));
        let calls = transport.calls();
        assert!(calls.iter().any(|call| call.method == "turn/interrupt"));
        assert_eq!(calls.last().unwrap().method, "thread/unsubscribe");
    }

    #[tokio::test]
    async fn cancellation_during_thread_start_reaps_the_late_created_thread() {
        let transport = FakeTransport::new(FakeMode::DelayedThreadStart);
        let observer = observer(Arc::clone(&transport));
        let task = tokio::spawn(async move { observer.run_isolated(request()).await });

        time::timeout(Duration::from_secs(1), async {
            loop {
                if transport
                    .calls()
                    .iter()
                    .any(|call| call.method == "thread/start")
                {
                    break;
                }
                time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .unwrap();

        task.abort();
        assert!(matches!(task.await, Err(error) if error.is_cancelled()));
        transport.thread_start_release.notify_waiters();

        time::timeout(Duration::from_secs(1), async {
            loop {
                if transport
                    .calls()
                    .iter()
                    .any(|call| call.method == "thread/unsubscribe")
                {
                    break;
                }
                time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .unwrap();

        let calls = transport.calls();
        assert!(!calls.iter().any(|call| call.method == "turn/start"));
        assert!(!calls.iter().any(|call| call.method == "turn/interrupt"));
        assert_eq!(calls.last().unwrap().method, "thread/unsubscribe");
    }

    #[tokio::test]
    async fn cancellation_during_turn_start_interrupts_late_turn_before_unsubscribe() {
        let transport = FakeTransport::new(FakeMode::DelayedTurnStart);
        let observer = observer(Arc::clone(&transport));
        let task = tokio::spawn(async move { observer.run_isolated(request()).await });

        time::timeout(Duration::from_secs(1), async {
            loop {
                if transport
                    .calls()
                    .iter()
                    .any(|call| call.method == "turn/start")
                {
                    break;
                }
                time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .unwrap();

        task.abort();
        assert!(matches!(task.await, Err(error) if error.is_cancelled()));
        transport.turn_start_release.notify_one();

        time::timeout(Duration::from_secs(1), async {
            loop {
                let calls = transport.calls();
                if calls.iter().any(|call| call.method == "turn/interrupt")
                    && calls.iter().any(|call| call.method == "thread/unsubscribe")
                {
                    break;
                }
                time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .unwrap();

        let calls = transport.calls();
        let interrupt = calls
            .iter()
            .position(|call| call.method == "turn/interrupt")
            .unwrap();
        let unsubscribe = calls
            .iter()
            .position(|call| call.method == "thread/unsubscribe")
            .unwrap();
        assert!(interrupt < unsubscribe);
        assert_eq!(calls[interrupt].params["threadId"], "observer-thread");
        assert_eq!(calls[interrupt].params["turnId"], "observer-turn");
        assert_eq!(calls[unsubscribe].params["threadId"], "observer-thread");
    }

    #[tokio::test]
    async fn invalid_thread_policy_with_id_still_unsubscribes_owned_thread() {
        let transport = FakeTransport::new(FakeMode::InvalidThreadPolicy);
        let error = match observer(Arc::clone(&transport))
            .run_isolated(request())
            .await
        {
            Ok(_) => panic!("invalid thread policy unexpectedly succeeded"),
            Err(error) => error,
        };
        assert!(matches!(error, FeatureError::PolicyViolation(_)));

        time::timeout(Duration::from_secs(1), async {
            loop {
                if transport
                    .calls()
                    .iter()
                    .any(|call| call.method == "thread/unsubscribe")
                {
                    break;
                }
                time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .unwrap();

        let calls = transport.calls();
        assert!(!calls.iter().any(|call| call.method == "turn/start"));
        assert!(!calls.iter().any(|call| call.method == "turn/interrupt"));
        let unsubscribe = calls
            .iter()
            .find(|call| call.method == "thread/unsubscribe")
            .unwrap();
        assert_eq!(unsubscribe.params["threadId"], "observer-thread");
    }

    #[test]
    fn rejects_any_policy_other_than_exact_luna_high_read_only_offline() {
        let mut request = request();
        request.policy.model = "gpt-5.6-sol".to_owned();
        assert!(matches!(
            validate_request(&request),
            Err(FeatureError::PolicyViolation(_))
        ));
        request.policy = ObserverExecutionPolicy::luna_high();
        request.max_output_bytes = MAX_OBSERVER_OUTPUT_BYTES + 1;
        assert!(matches!(
            validate_request(&request),
            Err(FeatureError::PolicyViolation(_))
        ));
    }
}
