use std::collections::HashMap;
use std::ffi::OsString;
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU8, AtomicU64, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::Duration;

use futures_util::StreamExt;
#[cfg(unix)]
use nix::sys::signal::{Signal, killpg};
#[cfg(unix)]
use nix::unistd::Pid;
use serde_json::{Value, json};
use thiserror::Error;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::process::{Child, ChildStderr, ChildStdin, ChildStdout, Command};
use tokio::sync::{Mutex, broadcast, mpsc, oneshot};
use tokio::task::JoinHandle;
use tokio::time::{self, Instant};
use tokio_util::codec::{FramedRead, LinesCodec, LinesCodecError};
use tokio_util::sync::CancellationToken;

const STATE_STARTING: u8 = 0;
const STATE_RUNNING: u8 = 1;
const STATE_CLOSING: u8 = 2;
const STATE_CLOSED: u8 = 3;
const STDERR_TAIL_BYTES: usize = 16 * 1024;
const FERMIN_OPT_OUT_NOTIFICATION_METHODS: [&str; 6] = [
    // Persist complete agent-message items instead of every token delta. The
    // engine's reducer durably writes and republishes each accepted event; a
    // verbose multi-session turn can otherwise overflow the bounded broadcast
    // channel, lose the completed message, and leave Desktop/Mobile showing a
    // permanently-working session even though Codex already replied.
    "item/agentMessage/delta",
    // Completed command items carry the authoritative bounded output.
    "item/commandExecution/outputDelta",
    "turn/diff/updated",
    "thread/tokenUsage/updated",
    "mcpServer/startupStatus/updated",
    "model/safetyBuffering/updated",
];

static NEXT_PROCESS_EPOCH: AtomicU64 = AtomicU64::new(1);

#[derive(Clone, Debug)]
pub struct AppServerConfig {
    pub executable: PathBuf,
    pub args: Vec<OsString>,
    pub cwd: Option<PathBuf>,
    pub env: Vec<(OsString, OsString)>,
    pub initialize_params: Value,
    pub request_timeout: Duration,
    pub initialize_timeout: Duration,
    pub shutdown_timeout: Duration,
    pub max_line_bytes: usize,
    pub writer_capacity: usize,
    pub event_capacity: usize,
}

impl AppServerConfig {
    pub fn new(executable: impl Into<PathBuf>) -> Self {
        Self {
            executable: executable.into(),
            args: Vec::new(),
            cwd: None,
            env: Vec::new(),
            initialize_params: json!({
                "clientInfo": {
                    "name": "fermin_code",
                    "title": "Fermin Code",
                    "version": env!("CARGO_PKG_VERSION")
                },
                "capabilities": {
                    "experimentalApi": true,
                    "optOutNotificationMethods": FERMIN_OPT_OUT_NOTIFICATION_METHODS
                }
            }),
            request_timeout: Duration::from_secs(30),
            initialize_timeout: Duration::from_secs(20),
            shutdown_timeout: Duration::from_secs(3),
            max_line_bytes: 64 * 1024 * 1024,
            writer_capacity: 128,
            event_capacity: 512,
        }
    }

    pub fn for_codex(executable: impl Into<PathBuf>) -> Self {
        let mut config = Self::new(executable);
        config.args = vec![
            OsString::from("app-server"),
            OsString::from("--listen"),
            OsString::from("stdio://"),
        ];
        config
    }

    pub fn arg(mut self, arg: impl Into<OsString>) -> Self {
        self.args.push(arg.into());
        self
    }

    pub fn args<I, S>(mut self, args: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<OsString>,
    {
        self.args.extend(args.into_iter().map(Into::into));
        self
    }

    pub fn cwd(mut self, cwd: impl Into<PathBuf>) -> Self {
        self.cwd = Some(cwd.into());
        self
    }

    pub fn env(mut self, key: impl Into<OsString>, value: impl Into<OsString>) -> Self {
        self.env.push((key.into(), value.into()));
        self
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum AppServerEvent {
    Notification {
        epoch: u64,
        method: String,
        params: Value,
    },
    ServerRequest {
        epoch: u64,
        id: Value,
        method: String,
        params: Value,
    },
    Unrecognized {
        epoch: u64,
        message: Value,
    },
    Lifecycle {
        epoch: u64,
        state: AppServerLifecycle,
        detail: Option<String>,
    },
}

impl AppServerEvent {
    pub fn epoch(&self) -> u64 {
        match self {
            Self::Notification { epoch, .. }
            | Self::ServerRequest { epoch, .. }
            | Self::Unrecognized { epoch, .. }
            | Self::Lifecycle { epoch, .. } => *epoch,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AppServerLifecycle {
    Spawned,
    Ready,
    Stopping,
    Stopped,
    Failed,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ModelProbe {
    pub epoch: u64,
    pub response: Value,
    pub models: Vec<Value>,
}

#[derive(Clone, Debug, Error, PartialEq)]
pub enum AppServerError {
    #[error("failed to spawn app-server: {message}")]
    Spawn { message: String },
    #[error("app-server is closed (epoch {epoch})")]
    Closed { epoch: u64 },
    #[error("app-server request `{method}` timed out after {timeout:?} (epoch {epoch})")]
    Timeout {
        epoch: u64,
        method: String,
        timeout: Duration,
    },
    #[error("app-server outbound JSONL line is {actual} bytes; maximum is {max}")]
    OutboundLineTooLong { actual: usize, max: usize },
    #[error("app-server JSONL line exceeded {max} bytes (epoch {epoch})")]
    LineTooLong { epoch: u64, max: usize },
    #[error("app-server emitted malformed JSONL (epoch {epoch}): {message}; preview={preview:?}")]
    MalformedLine {
        epoch: u64,
        message: String,
        preview: String,
    },
    #[error("app-server stdout reached EOF (epoch {epoch})")]
    Eof { epoch: u64 },
    #[error("app-server transport failed (epoch {epoch}): {message}")]
    Transport { epoch: u64, message: String },
    #[error("app-server exited (epoch {epoch}, status {status}): {stderr}")]
    ProcessExited {
        epoch: u64,
        status: String,
        stderr: String,
    },
    #[error("app-server protocol violation (epoch {epoch}): {message}")]
    Protocol { epoch: u64, message: String },
    #[error("app-server is overloaded during `{method}`: {message}")]
    Overloaded {
        method: String,
        message: String,
        data: Option<Value>,
    },
    #[error("app-server RPC `{method}` failed with code {code}: {message}")]
    Rpc {
        method: String,
        code: i64,
        message: String,
        data: Option<Value>,
    },
}

impl AppServerError {
    pub fn is_overloaded(&self) -> bool {
        matches!(self, Self::Overloaded { .. })
    }
}

#[derive(Clone)]
pub struct AppServerClient {
    shared: Arc<Shared>,
    lifecycle: Arc<Lifecycle>,
}

struct Shared {
    epoch: u64,
    state: AtomicU8,
    next_request_id: AtomicU64,
    request_timeout: Duration,
    max_line_bytes: usize,
    writer_tx: mpsc::Sender<Outbound>,
    pending: Mutex<HashMap<u64, PendingRequest>>,
    events: broadcast::Sender<AppServerEvent>,
}

struct Lifecycle {
    cancellation: CancellationToken,
    process_group: Arc<AtomicI32>,
    runtime: Mutex<Option<JoinHandle<Result<(), AppServerError>>>>,
    outcome: StdMutex<Option<Result<(), AppServerError>>>,
    shutdown_started: AtomicBool,
}

struct PendingRequest {
    method: String,
    response: oneshot::Sender<Result<Value, AppServerError>>,
}

struct Outbound {
    bytes: Vec<u8>,
    written: oneshot::Sender<Result<(), AppServerError>>,
}

impl AppServerClient {
    pub async fn spawn(config: AppServerConfig) -> Result<Self, AppServerError> {
        validate_config(&config)?;

        let mut command = Command::new(&config.executable);
        command
            .args(&config.args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        if let Some(cwd) = &config.cwd {
            command.current_dir(cwd);
        }
        for (key, value) in &config.env {
            command.env(key, value);
        }
        #[cfg(unix)]
        {
            use std::os::unix::process::CommandExt;
            command.as_std_mut().process_group(0);
        }

        let mut child = command.spawn().map_err(|error| AppServerError::Spawn {
            message: format!("{}: {error}", config.executable.display()),
        })?;
        let process_id = child.id().ok_or_else(|| AppServerError::Spawn {
            message: "spawned process has no process id".to_owned(),
        })?;
        let stdin = child.stdin.take().ok_or_else(|| AppServerError::Spawn {
            message: "spawned process has no stdin".to_owned(),
        })?;
        let stdout = child.stdout.take().ok_or_else(|| AppServerError::Spawn {
            message: "spawned process has no stdout".to_owned(),
        })?;
        let stderr = child.stderr.take().ok_or_else(|| AppServerError::Spawn {
            message: "spawned process has no stderr".to_owned(),
        })?;

        let epoch = NEXT_PROCESS_EPOCH.fetch_add(1, Ordering::Relaxed);
        let (writer_tx, writer_rx) = mpsc::channel(config.writer_capacity);
        let (events, _) = broadcast::channel(config.event_capacity);
        let shared = Arc::new(Shared {
            epoch,
            state: AtomicU8::new(STATE_STARTING),
            next_request_id: AtomicU64::new(1),
            request_timeout: config.request_timeout,
            max_line_bytes: config.max_line_bytes,
            writer_tx,
            pending: Mutex::new(HashMap::new()),
            events,
        });
        let cancellation = CancellationToken::new();
        let process_group = Arc::new(AtomicI32::new(process_id as i32));
        let runtime = tokio::spawn(run_process(
            child,
            stdin,
            stdout,
            stderr,
            writer_rx,
            Arc::clone(&shared),
            cancellation.clone(),
            Arc::clone(&process_group),
            config.shutdown_timeout,
        ));
        let client = Self {
            shared,
            lifecycle: Arc::new(Lifecycle {
                cancellation,
                process_group,
                runtime: Mutex::new(Some(runtime)),
                outcome: StdMutex::new(None),
                shutdown_started: AtomicBool::new(false),
            }),
        };

        let initialize_result = client
            .request_with_timeout(
                "initialize",
                config.initialize_params,
                config.initialize_timeout,
            )
            .await;
        if let Err(error) = initialize_result {
            let _ = client.shutdown().await;
            return Err(error);
        }
        if let Err(error) = client.notify("initialized", json!({})).await {
            let _ = client.shutdown().await;
            return Err(error);
        }
        if client
            .shared
            .state
            .compare_exchange(
                STATE_STARTING,
                STATE_RUNNING,
                Ordering::AcqRel,
                Ordering::Acquire,
            )
            .is_err()
        {
            let error = AppServerError::Closed { epoch };
            let _ = client.shutdown().await;
            return Err(error);
        }
        emit(
            &client.shared,
            AppServerEvent::Lifecycle {
                epoch,
                state: AppServerLifecycle::Ready,
                detail: None,
            },
        );
        Ok(client)
    }

    pub fn epoch(&self) -> u64 {
        self.shared.epoch
    }

    pub fn is_running(&self) -> bool {
        self.shared.state.load(Ordering::Acquire) == STATE_RUNNING
    }

    pub fn subscribe(&self) -> broadcast::Receiver<AppServerEvent> {
        self.shared.events.subscribe()
    }

    pub async fn request(
        &self,
        method: impl Into<String>,
        params: Value,
    ) -> Result<Value, AppServerError> {
        self.request_with_timeout(method, params, self.shared.request_timeout)
            .await
    }

    pub async fn request_with_timeout(
        &self,
        method: impl Into<String>,
        params: Value,
        timeout: Duration,
    ) -> Result<Value, AppServerError> {
        let method = method.into();
        if method.trim().is_empty() {
            return Err(AppServerError::Protocol {
                epoch: self.epoch(),
                message: "request method must not be empty".to_owned(),
            });
        }
        self.ensure_open()?;

        let id = self.shared.next_request_id.fetch_add(1, Ordering::Relaxed);
        let (response_tx, response_rx) = oneshot::channel();
        self.shared.pending.lock().await.insert(
            id,
            PendingRequest {
                method: method.clone(),
                response: response_tx,
            },
        );
        let payload = json!({ "id": id, "method": method, "params": params });
        let operation = async {
            self.send_value(payload).await?;
            response_rx.await.map_err(|_| AppServerError::Closed {
                epoch: self.epoch(),
            })?
        };

        match time::timeout(timeout, operation).await {
            Ok(result) => {
                if result.is_err() {
                    self.shared.pending.lock().await.remove(&id);
                }
                result
            }
            Err(_) => {
                self.shared.pending.lock().await.remove(&id);
                Err(AppServerError::Timeout {
                    epoch: self.epoch(),
                    method,
                    timeout,
                })
            }
        }
    }

    pub async fn notify(
        &self,
        method: impl Into<String>,
        params: Value,
    ) -> Result<(), AppServerError> {
        let method = method.into();
        if method.trim().is_empty() {
            return Err(AppServerError::Protocol {
                epoch: self.epoch(),
                message: "notification method must not be empty".to_owned(),
            });
        }
        self.ensure_open()?;
        self.send_value(json!({ "method": method, "params": params }))
            .await
    }

    pub async fn respond(&self, id: Value, result: Value) -> Result<(), AppServerError> {
        self.ensure_open()?;
        self.send_value(json!({ "id": id, "result": result })).await
    }

    pub async fn respond_error(
        &self,
        id: Value,
        code: i64,
        message: impl Into<String>,
        data: Option<Value>,
    ) -> Result<(), AppServerError> {
        self.ensure_open()?;
        let mut error = serde_json::Map::new();
        error.insert("code".to_owned(), Value::from(code));
        error.insert("message".to_owned(), Value::from(message.into()));
        if let Some(data) = data {
            error.insert("data".to_owned(), data);
        }
        self.send_value(json!({ "id": id, "error": error })).await
    }

    pub async fn model_list(&self) -> Result<Value, AppServerError> {
        self.request(
            "model/list",
            json!({ "includeHidden": false, "limit": 100 }),
        )
        .await
    }

    pub async fn probe_models(&self) -> Result<ModelProbe, AppServerError> {
        let response = self.model_list().await?;
        let models = response
            .get("data")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        Ok(ModelProbe {
            epoch: self.epoch(),
            response,
            models,
        })
    }

    pub async fn shutdown(&self) -> Result<(), AppServerError> {
        if !self.lifecycle.shutdown_started.swap(true, Ordering::AcqRel) {
            let transitioned = self
                .shared
                .state
                .fetch_update(Ordering::AcqRel, Ordering::Acquire, |state| {
                    (state < STATE_CLOSING).then_some(STATE_CLOSING)
                })
                .is_ok();
            if transitioned {
                emit(
                    &self.shared,
                    AppServerEvent::Lifecycle {
                        epoch: self.epoch(),
                        state: AppServerLifecycle::Stopping,
                        detail: None,
                    },
                );
            }
            self.lifecycle.cancellation.cancel();
        }

        let mut runtime = self.lifecycle.runtime.lock().await;
        if let Some(handle) = runtime.as_mut() {
            let outcome = match handle.await {
                Ok(result) => result,
                Err(error) => Err(AppServerError::Transport {
                    epoch: self.epoch(),
                    message: format!("runtime task failed: {error}"),
                }),
            };
            *runtime = None;
            *self
                .lifecycle
                .outcome
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(outcome.clone());
            outcome
        } else {
            self.lifecycle
                .outcome
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .clone()
                .unwrap_or(Ok(()))
        }
    }

    fn ensure_open(&self) -> Result<(), AppServerError> {
        if self.shared.state.load(Ordering::Acquire) >= STATE_CLOSING {
            Err(AppServerError::Closed {
                epoch: self.epoch(),
            })
        } else {
            Ok(())
        }
    }

    async fn send_value(&self, value: Value) -> Result<(), AppServerError> {
        let mut bytes = serde_json::to_vec(&value).map_err(|error| AppServerError::Protocol {
            epoch: self.epoch(),
            message: format!("serialize outbound message: {error}"),
        })?;
        if bytes.len() > self.shared.max_line_bytes {
            return Err(AppServerError::OutboundLineTooLong {
                actual: bytes.len(),
                max: self.shared.max_line_bytes,
            });
        }
        bytes.push(b'\n');
        let (written_tx, written_rx) = oneshot::channel();
        self.shared
            .writer_tx
            .send(Outbound {
                bytes,
                written: written_tx,
            })
            .await
            .map_err(|_| AppServerError::Closed {
                epoch: self.epoch(),
            })?;
        written_rx.await.map_err(|_| AppServerError::Closed {
            epoch: self.epoch(),
        })?
    }
}

impl Drop for Lifecycle {
    fn drop(&mut self) {
        self.cancellation.cancel();
        let process_group = self.process_group.load(Ordering::Acquire);
        if process_group > 0 {
            signal_process_group(process_group, true);
        }
    }
}

fn validate_config(config: &AppServerConfig) -> Result<(), AppServerError> {
    if config.max_line_bytes == 0 {
        return Err(AppServerError::Spawn {
            message: "max_line_bytes must be greater than zero".to_owned(),
        });
    }
    if config.writer_capacity == 0 {
        return Err(AppServerError::Spawn {
            message: "writer_capacity must be greater than zero".to_owned(),
        });
    }
    if config.event_capacity == 0 {
        return Err(AppServerError::Spawn {
            message: "event_capacity must be greater than zero".to_owned(),
        });
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
async fn run_process(
    mut child: Child,
    stdin: ChildStdin,
    stdout: ChildStdout,
    stderr: ChildStderr,
    writer_rx: mpsc::Receiver<Outbound>,
    shared: Arc<Shared>,
    cancellation: CancellationToken,
    process_group: Arc<AtomicI32>,
    shutdown_timeout: Duration,
) -> Result<(), AppServerError> {
    emit(
        &shared,
        AppServerEvent::Lifecycle {
            epoch: shared.epoch,
            state: AppServerLifecycle::Spawned,
            detail: None,
        },
    );

    let task_cancellation = cancellation.child_token();
    let stderr_tail = Arc::new(StdMutex::new(String::new()));
    let mut writer = tokio::spawn(writer_loop(
        stdin,
        writer_rx,
        Arc::clone(&shared),
        task_cancellation.clone(),
    ));
    let mut reader = tokio::spawn(reader_loop(
        stdout,
        Arc::clone(&shared),
        task_cancellation.clone(),
    ));
    let stderr_task = tokio::spawn(stderr_loop(
        stderr,
        Arc::clone(&stderr_tail),
        task_cancellation.clone(),
    ));

    enum StopReason {
        Shutdown,
        Exited(Result<std::process::ExitStatus, std::io::Error>),
        Reader(Result<Result<(), AppServerError>, tokio::task::JoinError>),
        Writer(Result<Result<(), AppServerError>, tokio::task::JoinError>),
    }

    let stop_reason = tokio::select! {
        biased;
        _ = cancellation.cancelled() => StopReason::Shutdown,
        status = child.wait() => StopReason::Exited(status),
        result = &mut reader => StopReason::Reader(result),
        result = &mut writer => StopReason::Writer(result),
    };
    let reader_finished = matches!(stop_reason, StopReason::Reader(_));
    let writer_finished = matches!(stop_reason, StopReason::Writer(_));
    let process_was_reaped = matches!(stop_reason, StopReason::Exited(Ok(_)));
    task_cancellation.cancel();

    let terminal = match stop_reason {
        StopReason::Shutdown => None,
        StopReason::Exited(Ok(status)) => Some(AppServerError::ProcessExited {
            epoch: shared.epoch,
            status: status.to_string(),
            stderr: read_stderr_tail(&stderr_tail),
        }),
        StopReason::Exited(Err(error)) => Some(AppServerError::Transport {
            epoch: shared.epoch,
            message: format!("wait for app-server: {error}"),
        }),
        StopReason::Reader(Ok(Ok(()))) => Some(AppServerError::Eof {
            epoch: shared.epoch,
        }),
        StopReason::Reader(Ok(Err(error))) => Some(error),
        StopReason::Reader(Err(error)) => Some(AppServerError::Transport {
            epoch: shared.epoch,
            message: format!("reader task failed: {error}"),
        }),
        StopReason::Writer(Ok(Ok(()))) => Some(AppServerError::Transport {
            epoch: shared.epoch,
            message: "writer stopped unexpectedly".to_owned(),
        }),
        StopReason::Writer(Ok(Err(error))) => Some(error),
        StopReason::Writer(Err(error)) => Some(AppServerError::Transport {
            epoch: shared.epoch,
            message: format!("writer task failed: {error}"),
        }),
    };

    terminate_process(
        &mut child,
        process_group.load(Ordering::Acquire),
        shutdown_timeout,
        process_was_reaped,
    )
    .await;
    process_group.store(0, Ordering::Release);

    if !reader_finished {
        let _ = reader.await;
    }
    if !writer_finished {
        let _ = writer.await;
    }
    let _ = stderr_task.await;

    shared.state.store(STATE_CLOSED, Ordering::Release);
    let pending_error = terminal.clone().unwrap_or(AppServerError::Closed {
        epoch: shared.epoch,
    });
    fail_pending(&shared, pending_error).await;

    match terminal {
        Some(error) => {
            emit(
                &shared,
                AppServerEvent::Lifecycle {
                    epoch: shared.epoch,
                    state: AppServerLifecycle::Failed,
                    detail: Some(error.to_string()),
                },
            );
            Err(error)
        }
        None => {
            emit(
                &shared,
                AppServerEvent::Lifecycle {
                    epoch: shared.epoch,
                    state: AppServerLifecycle::Stopped,
                    detail: None,
                },
            );
            Ok(())
        }
    }
}

async fn writer_loop(
    mut stdin: ChildStdin,
    mut writer_rx: mpsc::Receiver<Outbound>,
    shared: Arc<Shared>,
    cancellation: CancellationToken,
) -> Result<(), AppServerError> {
    loop {
        let outbound = tokio::select! {
            _ = cancellation.cancelled() => return Ok(()),
            outbound = writer_rx.recv() => match outbound {
                Some(outbound) => outbound,
                None => return Ok(()),
            },
        };
        let result = tokio::select! {
            _ = cancellation.cancelled() => Err(AppServerError::Closed { epoch: shared.epoch }),
            result = async {
                stdin.write_all(&outbound.bytes).await?;
                stdin.flush().await
            } => result.map_err(|error| AppServerError::Transport {
                epoch: shared.epoch,
                message: format!("write app-server stdin: {error}"),
            }),
        };
        let failed = result.is_err();
        let _ = outbound.written.send(result.clone());
        if failed {
            return result;
        }
    }
}

async fn reader_loop(
    stdout: ChildStdout,
    shared: Arc<Shared>,
    cancellation: CancellationToken,
) -> Result<(), AppServerError> {
    let mut lines = FramedRead::new(
        stdout,
        LinesCodec::new_with_max_length(shared.max_line_bytes),
    );
    loop {
        let next = tokio::select! {
            _ = cancellation.cancelled() => return Ok(()),
            next = lines.next() => next,
        };
        let line = match next {
            Some(Ok(line)) => line,
            Some(Err(LinesCodecError::MaxLineLengthExceeded)) => {
                return Err(AppServerError::LineTooLong {
                    epoch: shared.epoch,
                    max: shared.max_line_bytes,
                });
            }
            Some(Err(LinesCodecError::Io(error))) => {
                return Err(AppServerError::Transport {
                    epoch: shared.epoch,
                    message: format!("read app-server stdout: {error}"),
                });
            }
            None => {
                return Err(AppServerError::Eof {
                    epoch: shared.epoch,
                });
            }
        };

        let message: Value =
            serde_json::from_str(&line).map_err(|error| AppServerError::MalformedLine {
                epoch: shared.epoch,
                message: error.to_string(),
                preview: preview(&line, 240),
            })?;
        handle_message(&shared, message).await;
    }
}

async fn handle_message(shared: &Arc<Shared>, message: Value) {
    let Some(object) = message.as_object() else {
        emit(
            shared,
            AppServerEvent::Unrecognized {
                epoch: shared.epoch,
                message,
            },
        );
        return;
    };

    if let Some(method) = object.get("method").and_then(Value::as_str) {
        let params = object.get("params").cloned().unwrap_or(Value::Null);
        if let Some(id) = object.get("id") {
            emit(
                shared,
                AppServerEvent::ServerRequest {
                    epoch: shared.epoch,
                    id: id.clone(),
                    method: method.to_owned(),
                    params,
                },
            );
        } else {
            emit(
                shared,
                AppServerEvent::Notification {
                    epoch: shared.epoch,
                    method: method.to_owned(),
                    params,
                },
            );
        }
        return;
    }

    if let Some(id) = object.get("id").and_then(Value::as_u64)
        && (object.contains_key("result") || object.contains_key("error"))
    {
        if let Some(pending) = shared.pending.lock().await.remove(&id) {
            let result = parse_response(shared.epoch, &pending.method, object);
            let _ = pending.response.send(result);
        } else {
            emit(
                shared,
                AppServerEvent::Unrecognized {
                    epoch: shared.epoch,
                    message,
                },
            );
        }
        return;
    }

    emit(
        shared,
        AppServerEvent::Unrecognized {
            epoch: shared.epoch,
            message,
        },
    );
}

fn parse_response(
    epoch: u64,
    method: &str,
    object: &serde_json::Map<String, Value>,
) -> Result<Value, AppServerError> {
    if let Some(result) = object.get("result") {
        return Ok(result.clone());
    }
    let Some(error) = object.get("error").and_then(Value::as_object) else {
        return Err(AppServerError::Protocol {
            epoch,
            message: format!("RPC response for `{method}` has neither result nor a valid error"),
        });
    };
    let Some(code) = error.get("code").and_then(Value::as_i64) else {
        return Err(AppServerError::Protocol {
            epoch,
            message: format!("RPC error response for `{method}` has no integer code"),
        });
    };
    let message = error
        .get("message")
        .and_then(Value::as_str)
        .unwrap_or("unknown RPC error")
        .to_owned();
    let data = error.get("data").cloned();
    if code == -32001 {
        Err(AppServerError::Overloaded {
            method: method.to_owned(),
            message,
            data,
        })
    } else {
        Err(AppServerError::Rpc {
            method: method.to_owned(),
            code,
            message,
            data,
        })
    }
}

async fn stderr_loop(
    mut stderr: ChildStderr,
    tail: Arc<StdMutex<String>>,
    cancellation: CancellationToken,
) {
    let mut buffer = [0_u8; 4096];
    loop {
        let read = tokio::select! {
            _ = cancellation.cancelled() => return,
            read = stderr.read(&mut buffer) => read,
        };
        match read {
            Ok(0) | Err(_) => return,
            Ok(length) => append_stderr_tail(&tail, &buffer[..length]),
        }
    }
}

async fn fail_pending(shared: &Shared, error: AppServerError) {
    let pending = std::mem::take(&mut *shared.pending.lock().await);
    for (_, request) in pending {
        let _ = request.response.send(Err(error.clone()));
    }
}

async fn terminate_process(
    child: &mut Child,
    process_group: i32,
    shutdown_timeout: Duration,
    already_reaped: bool,
) {
    if process_group > 0 {
        signal_process_group(process_group, false);
    }

    let mut reaped = already_reaped;
    if !reaped {
        reaped = matches!(
            time::timeout(shutdown_timeout, child.wait()).await,
            Ok(Ok(_))
        );
    }

    if process_group > 0 {
        signal_process_group(process_group, true);
    }
    if !reaped {
        let deadline = Instant::now() + shutdown_timeout;
        let _ = time::timeout_at(deadline, child.wait()).await;
    }
}

#[cfg(unix)]
fn signal_process_group(process_group: i32, force: bool) {
    let signal = if force {
        Signal::SIGKILL
    } else {
        Signal::SIGTERM
    };
    let _ = killpg(Pid::from_raw(process_group), signal);
}

#[cfg(not(unix))]
fn signal_process_group(_process_group: i32, _force: bool) {}

fn emit(shared: &Shared, event: AppServerEvent) {
    let _ = shared.events.send(event);
}

fn append_stderr_tail(tail: &StdMutex<String>, bytes: &[u8]) {
    let mut tail = tail.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    tail.push_str(&String::from_utf8_lossy(bytes));
    if tail.len() > STDERR_TAIL_BYTES {
        let mut start = tail.len() - STDERR_TAIL_BYTES;
        while !tail.is_char_boundary(start) {
            start += 1;
        }
        tail.drain(..start);
    }
}

fn read_stderr_tail(tail: &StdMutex<String>) -> String {
    tail.lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .clone()
}

fn preview(value: &str, max_chars: usize) -> String {
    let mut chars = value.chars();
    let preview: String = chars.by_ref().take(max_chars).collect();
    if chars.next().is_some() {
        format!("{preview}…")
    } else {
        preview
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn appserver_initialization_opts_out_of_unused_high_volume_notifications() {
        let config = AppServerConfig::new("codex");
        let methods = config
            .initialize_params
            .pointer("/capabilities/optOutNotificationMethods")
            .and_then(Value::as_array)
            .expect("opt-out methods");
        let methods = methods.iter().filter_map(Value::as_str).collect::<Vec<_>>();

        for expected in FERMIN_OPT_OUT_NOTIFICATION_METHODS {
            assert!(
                methods.contains(&expected),
                "missing opt-out for {expected}"
            );
        }
        assert!(
            methods.contains(&"item/agentMessage/delta"),
            "token deltas must stay disabled so completed agent messages cannot be starved"
        );
        assert!(
            methods.contains(&"item/commandExecution/outputDelta"),
            "terminal output deltas must stay disabled to bound the durable event journal"
        );
    }
}
