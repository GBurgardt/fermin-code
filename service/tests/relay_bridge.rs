use std::collections::BTreeMap;
use std::future::IntoFuture;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use axum::http::header::AUTHORIZATION;
use bytes::Bytes;
use fermin_code::PROTOCOL_VERSION;
use fermin_code::api::{
    AttachmentUpload, MobileBackend, PromptImproverVariant, ReplayCursor, SessionHistoryPage,
    SessionHistoryQuery, SessionHistorySort, SessionHistoryState,
};
use fermin_code::bridge::{BridgeFuture, BridgeSource, run_outbound_bridge};
use fermin_code::config::{RelayClientConfig, RelayConfig};
use fermin_code::protocol::{
    ActivityStatus, AuthoritativeSnapshot, CommandAcceptance, CommandKind, CommandRecord,
    CommandRequest, CommandState, DurableEvent, EventCursor, EventKind, MOBILE_SCHEMA_VERSION,
    Message as MobileMessage, MessageMutation, MessagePatch, NewEvent, RelayEnvelope, RelayFrame,
    SessionSummary,
};
use fermin_code::relay::{RelayState, relay_router};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tempfile::TempDir;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::broadcast;
use tokio::task::JoinHandle;
use tokio::time::{Instant, sleep, timeout};
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::{Error as WebSocketError, Message};
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream, connect_async};
use tokio_util::sync::CancellationToken;

const ENGINE_TOKEN: &str = "engine-token-0123456789abcdef-0123456789abcdef";
const MOBILE_TOKEN: &str = "mobile-token-0123456789abcdef-0123456789abcdef";
const TEST_TIMEOUT: Duration = Duration::from_secs(5);

type ClientSocket = WebSocketStream<MaybeTlsStream<TcpStream>>;

struct RelayHarness {
    _temporary_directory: TempDir,
    state: Arc<RelayState>,
    engine_token_file: std::path::PathBuf,
    address: std::net::SocketAddr,
    shutdown: CancellationToken,
    server: JoinHandle<()>,
}

impl RelayHarness {
    async fn start() -> Self {
        let temporary_directory = tempfile::tempdir().expect("create relay temp directory");
        let mobile_token_file = temporary_directory.path().join("mobile-token");
        let engine_token_file = temporary_directory.path().join("engine-token");
        tokio::fs::write(&mobile_token_file, MOBILE_TOKEN)
            .await
            .expect("write mobile token");
        tokio::fs::write(&engine_token_file, ENGINE_TOKEN)
            .await
            .expect("write engine token");
        #[cfg(unix)]
        for token_file in [&mobile_token_file, &engine_token_file] {
            let mut permissions = tokio::fs::metadata(token_file)
                .await
                .expect("read token permissions")
                .permissions();
            permissions.set_mode(0o600);
            tokio::fs::set_permissions(token_file, permissions)
                .await
                .expect("restrict token permissions");
        }

        let state = Arc::new(
            RelayState::open(RelayConfig {
                bind: "127.0.0.1:0".parse().expect("parse loopback bind"),
                database_path: temporary_directory.path().join("relay.sqlite3"),
                auth_token_file: mobile_token_file,
                engine_token_file: engine_token_file.clone(),
                heartbeat_seconds: 1,
                engine_lease_seconds: 30,
                max_body_bytes: 1024 * 1024,
            })
            .await
            .expect("open relay state"),
        );
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind relay listener");
        let address = listener.local_addr().expect("read relay address");
        let shutdown = CancellationToken::new();
        let server_shutdown = shutdown.clone();
        let router = relay_router(state.clone());
        let server = tokio::spawn(async move {
            axum::serve(listener, router)
                .with_graceful_shutdown(server_shutdown.cancelled_owned())
                .into_future()
                .await
                .expect("serve test relay");
        });

        Self {
            _temporary_directory: temporary_directory,
            state,
            engine_token_file,
            address,
            shutdown,
            server,
        }
    }

    fn websocket_url(&self) -> String {
        format!("ws://{}/v1/engine/connect", self.address)
    }

    fn bridge_config(&self) -> RelayClientConfig {
        RelayClientConfig {
            url: self.websocket_url(),
            token_file: self.engine_token_file.clone(),
            reconnect_min_ms: 50,
            reconnect_max_ms: 100,
        }
    }

    fn relay_config(&self) -> RelayConfig {
        RelayConfig {
            bind: "127.0.0.1:0".parse().expect("parse loopback bind"),
            database_path: self._temporary_directory.path().join("relay.sqlite3"),
            auth_token_file: self._temporary_directory.path().join("mobile-token"),
            engine_token_file: self.engine_token_file.clone(),
            heartbeat_seconds: 1,
            engine_lease_seconds: 30,
            max_body_bytes: 1024 * 1024,
        }
    }

    async fn stop(self) {
        self.shutdown.cancel();
        timeout(TEST_TIMEOUT, self.server)
            .await
            .expect("relay server shutdown timeout")
            .expect("relay server task panicked");
    }
}

struct FakeBridgeSource {
    engine_id: String,
    snapshot: Mutex<AuthoritativeSnapshot>,
    events: Mutex<Vec<DurableEvent>>,
    commands: Mutex<Vec<CommandRecord>>,
    existing_commands: Mutex<BTreeMap<String, CommandRecord>>,
    queries: Mutex<Vec<(String, Value)>>,
    active_queries: AtomicU64,
    relay_cursor: AtomicU64,
    cursor_commits: Mutex<Vec<u64>>,
    event_wake: broadcast::Sender<DurableEvent>,
    inject_after_empty_replay: Mutex<Option<DurableEvent>>,
}

impl FakeBridgeSource {
    fn new(engine_id: &str) -> Self {
        let (event_wake, _) = broadcast::channel(16);
        Self {
            engine_id: engine_id.to_owned(),
            snapshot: Mutex::new(AuthoritativeSnapshot {
                schema_version: MOBILE_SCHEMA_VERSION,
                global_sequence: 0,
                generated_at: now_ms(),
                sessions: Vec::new(),
                models: Vec::new(),
            }),
            events: Mutex::new(Vec::new()),
            commands: Mutex::new(Vec::new()),
            existing_commands: Mutex::new(BTreeMap::new()),
            queries: Mutex::new(Vec::new()),
            active_queries: AtomicU64::new(0),
            relay_cursor: AtomicU64::new(0),
            cursor_commits: Mutex::new(Vec::new()),
            event_wake,
            inject_after_empty_replay: Mutex::new(None),
        }
    }

    fn append_event(&self, event: DurableEvent) {
        self.events
            .lock()
            .expect("event lock poisoned")
            .push(event.clone());
        let _ = self.event_wake.send(event);
    }

    fn persist_event_without_wake(&self, event: DurableEvent) {
        self.events.lock().expect("event lock poisoned").push(event);
    }

    fn replace_snapshot(&self, snapshot: AuthoritativeSnapshot) {
        *self.snapshot.lock().expect("snapshot lock poisoned") = snapshot;
    }

    fn delivered_command_ids(&self) -> Vec<String> {
        self.commands
            .lock()
            .expect("command lock poisoned")
            .iter()
            .map(|command| command.command_id.clone())
            .collect()
    }

    fn seed_existing_command(&self, command: CommandRecord) {
        self.existing_commands
            .lock()
            .expect("existing command lock poisoned")
            .insert(command.idempotency_key.clone(), command);
    }
}

impl BridgeSource for FakeBridgeSource {
    fn engine_id(&self) -> &str {
        &self.engine_id
    }

    fn app_server_version(&self) -> &str {
        "fake-app-server/1"
    }

    fn capability_hash(&self) -> &str {
        "fake-capabilities"
    }

    fn process_epoch(&self) -> u64 {
        7
    }

    fn snapshot(&self) -> BridgeFuture<'_, AuthoritativeSnapshot> {
        Box::pin(async {
            Ok(self
                .snapshot
                .lock()
                .expect("snapshot lock poisoned")
                .clone())
        })
    }

    fn replay_events(
        &self,
        after_global_sequence: u64,
        limit: usize,
    ) -> BridgeFuture<'_, Vec<DurableEvent>> {
        Box::pin(async move {
            let replay = self
                .events
                .lock()
                .expect("event lock poisoned")
                .iter()
                .filter(|event| event.global_sequence > after_global_sequence)
                .take(limit)
                .cloned()
                .collect::<Vec<_>>();
            if replay.is_empty() {
                let injected = self
                    .inject_after_empty_replay
                    .lock()
                    .expect("replay injection lock poisoned")
                    .take();
                if let Some(event) = injected {
                    self.append_event(event);
                }
            }
            Ok(replay)
        })
    }

    fn submit_remote(&self, command: CommandRecord) -> BridgeFuture<'_, CommandAcceptance> {
        Box::pin(async move {
            self.commands
                .lock()
                .expect("command lock poisoned")
                .push(command.clone());
            if let Some(existing) = self
                .existing_commands
                .lock()
                .expect("existing command lock poisoned")
                .get(&command.idempotency_key)
                .cloned()
            {
                return Ok(CommandAcceptance {
                    inserted: false,
                    command: existing,
                });
            }
            Ok(CommandAcceptance {
                inserted: true,
                command,
            })
        })
    }

    fn subscribe_events(&self) -> broadcast::Receiver<DurableEvent> {
        self.event_wake.subscribe()
    }

    fn load_relay_cursor(&self) -> BridgeFuture<'_, u64> {
        Box::pin(async { Ok(self.relay_cursor.load(Ordering::Acquire)) })
    }

    fn commit_relay_cursor(&self, global_sequence: u64) -> BridgeFuture<'_, ()> {
        Box::pin(async move {
            self.relay_cursor
                .fetch_max(global_sequence, Ordering::AcqRel);
            self.cursor_commits
                .lock()
                .expect("cursor commit lock poisoned")
                .push(global_sequence);
            Ok(())
        })
    }

    fn handle_query(&self, method: &str, params: Value) -> BridgeFuture<'_, Value> {
        let method = method.to_owned();
        Box::pin(async move {
            self.active_queries.fetch_add(1, Ordering::AcqRel);
            let _active_query = ActiveQueryGuard(&self.active_queries);
            self.queries
                .lock()
                .expect("query lock poisoned")
                .push((method.clone(), params.clone()));
            match method.as_str() {
                "test.echo" => Ok(params),
                "test.failure" => anyhow::bail!("synthetic engine query failure"),
                "test.pending" => std::future::pending::<anyhow::Result<Value>>().await,
                "session" => {
                    let window_id = params
                        .get("windowId")
                        .and_then(Value::as_str)
                        .ok_or_else(|| anyhow::anyhow!("invalid fake session query"))?;
                    let session = self
                        .snapshot
                        .lock()
                        .expect("snapshot lock poisoned")
                        .sessions
                        .iter()
                        .find(|session| {
                            session.window_id == window_id || session.session_id == window_id
                        })
                        .cloned();
                    Ok(serde_json::to_value(session)?)
                }
                _ => anyhow::bail!("unsupported fake engine query method: {method}"),
            }
        })
    }
}

#[tokio::test]
async fn relay_session_detail_is_hydrated_through_the_connected_engine() {
    let relay = RelayHarness::start().await;
    let source = Arc::new(FakeBridgeSource::new("engine-session-detail"));
    let now = now_ms();
    let mut summary = SessionSummary::new("remote-session", "project", "Remote session", now);
    summary.runtime_status = Some("WAITING".to_owned());
    source.replace_snapshot(AuthoritativeSnapshot {
        schema_version: MOBILE_SCHEMA_VERSION,
        global_sequence: 0,
        generated_at: now,
        sessions: vec![summary.clone()],
        models: Vec::new(),
    });
    let (cancellation, bridge) = start_bridge(source.clone(), &relay);
    wait_for_engine_state(&relay.state, true).await;
    wait_until_snapshot_event(&relay).await;

    summary.messages = vec![
        MobileMessage::user("user", "hello", now),
        MobileMessage::assistant("assistant", "world", now + 1),
    ];
    summary.message_count = 2;
    source.replace_snapshot(AuthoritativeSnapshot {
        schema_version: MOBILE_SCHEMA_VERSION,
        global_sequence: 0,
        generated_at: now,
        sessions: vec![summary],
        models: Vec::new(),
    });

    let detail = MobileBackend::session(relay.state.as_ref(), "remote-session".to_owned())
        .await
        .expect("query session detail")
        .expect("session exists");
    assert_eq!(detail.message_count, 2);
    assert_eq!(
        detail.messages[0].role,
        fermin_code::protocol::MessageRole::User
    );
    assert_eq!(
        detail.messages[1].role,
        fermin_code::protocol::MessageRole::Assistant
    );
    assert_eq!(
        source
            .queries
            .lock()
            .expect("query lock poisoned")
            .iter()
            .filter(|(method, _)| method == "session")
            .count(),
        1
    );
    cancellation.cancel();
    timeout(TEST_TIMEOUT, bridge)
        .await
        .expect("bridge shutdown timeout")
        .expect("bridge task panicked")
        .expect("bridge stopped cleanly");
    relay.stop().await;
}

#[tokio::test]
async fn relay_session_detail_hydrates_when_durable_cache_is_partial() {
    let relay = RelayHarness::start().await;
    let source = Arc::new(FakeBridgeSource::new("engine-session-cache"));
    let now = now_ms();
    let mut summary = SessionSummary::new("cached-session", "project", "Cached session", now);
    summary.runtime_status = Some("WAITING".to_owned());
    summary.message_count = 2;
    source.replace_snapshot(AuthoritativeSnapshot {
        schema_version: MOBILE_SCHEMA_VERSION,
        global_sequence: 0,
        generated_at: now,
        sessions: vec![summary.clone()],
        models: Vec::new(),
    });
    let (cancellation, bridge) = start_bridge(source.clone(), &relay);
    wait_for_engine_state(&relay.state, true).await;
    wait_until_snapshot_event(&relay).await;

    for (message, updated_at) in [
        (MobileMessage::assistant("assistant", "world", now), now),
        (
            MobileMessage::assistant("item-1", "world", now + 1),
            now + 1,
        ),
    ] {
        relay
            .state
            .store()
            .upsert_message(
                MessageMutation {
                    session_id: summary.session_id.clone(),
                    message,
                    revision: 1,
                    updated_at,
                    final_: true,
                },
                None,
            )
            .await
            .expect("seed durable relay message");
    }

    summary.messages = vec![
        MobileMessage::user("user", "hello", now),
        MobileMessage::assistant("assistant", "world", now + 1),
    ];
    source.replace_snapshot(AuthoritativeSnapshot {
        schema_version: MOBILE_SCHEMA_VERSION,
        global_sequence: 0,
        generated_at: now,
        sessions: vec![summary.clone()],
        models: Vec::new(),
    });

    let detail = timeout(
        Duration::from_millis(250),
        MobileBackend::session(relay.state.as_ref(), summary.session_id.clone()),
    )
    .await
    .expect("durable detail must be immediate")
    .expect("read durable detail")
    .expect("cached session exists");
    assert_eq!(detail.message_count, 2);
    assert_eq!(detail.messages.len(), 2);
    assert_eq!(detail.messages[0].id, "user");
    assert_eq!(
        source
            .queries
            .lock()
            .expect("query lock poisoned")
            .iter()
            .filter(|(method, _)| method == "session")
            .count(),
        1
    );
    let persisted = MobileBackend::session(relay.state.as_ref(), summary.session_id.clone())
        .await
        .expect("read repaired durable detail")
        .expect("repaired session exists");
    assert_eq!(persisted.message_count, 2);
    assert_eq!(persisted.messages.len(), 2);
    assert_eq!(persisted.messages[0].id, "user");
    assert_eq!(
        source
            .queries
            .lock()
            .expect("query lock poisoned")
            .iter()
            .filter(|(method, _)| method == "session")
            .count(),
        1,
        "the repaired relay cache must serve the second detail read without another engine query"
    );

    cancellation.cancel();
    timeout(TEST_TIMEOUT, bridge)
        .await
        .expect("bridge shutdown timeout")
        .expect("bridge task panicked")
        .expect("bridge stopped cleanly");
    relay.stop().await;
}

struct ActiveQueryGuard<'a>(&'a AtomicU64);

impl Drop for ActiveQueryGuard<'_> {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::AcqRel);
    }
}

#[tokio::test]
async fn authenticated_websocket_acks_lease_and_rejects_stale_generation() {
    let relay = RelayHarness::start().await;
    let connection_epoch = 41;
    let (mut socket, ack) = connect_engine(&relay, "engine-handshake", connection_epoch).await;

    assert_eq!(ack.protocol_version, PROTOCOL_VERSION);
    assert_eq!(ack.engine_id, "engine-handshake");
    assert_eq!(ack.connection_epoch, connection_epoch);
    assert_eq!(ack.acknowledgement, 1);
    assert_eq!(ack.resume_cursor, Some(0));
    assert!(ack.fence_generation > 0);
    assert!(matches!(ack.frame, RelayFrame::Ack));

    let stale = RelayEnvelope {
        protocol_version: PROTOCOL_VERSION,
        engine_id: "engine-handshake".to_owned(),
        connection_epoch,
        sequence: 2,
        acknowledgement: ack.sequence,
        resume_cursor: Some(0),
        fence_generation: ack.fence_generation - 1,
        frame: RelayFrame::Ack,
    };
    send_envelope(&mut socket, &stale).await;
    wait_for_socket_close(&mut socket).await;
    wait_for_engine_state(&relay.state, false).await;

    relay.stop().await;
}

#[tokio::test]
async fn relay_process_health_is_ready_before_the_first_engine_connects() {
    let relay = RelayHarness::start().await;
    let backend_health = MobileBackend::health(relay.state.as_ref())
        .await
        .expect("read relay backend health");
    assert!(!backend_health.ready);

    let response = reqwest::get(format!("http://{}/relay-healthz", relay.address))
        .await
        .expect("request relay process health");
    assert_eq!(response.status(), reqwest::StatusCode::OK);
    let bytes = response
        .bytes()
        .await
        .expect("read relay process health body");
    let payload: Value = serde_json::from_slice(&bytes).expect("decode relay process health");
    assert_eq!(payload["ok"], true);
    assert_eq!(payload["ready"], true);
    assert_eq!(payload["engineReady"], false);
    assert_eq!(payload["details"]["engine"]["connected"], false);

    relay.stop().await;
}

#[tokio::test]
async fn websocket_rejects_an_unauthorized_engine() {
    let relay = RelayHarness::start().await;
    let mut request = format!("{}?engineId=unauthorized", relay.websocket_url())
        .into_client_request()
        .expect("build websocket request");
    request.headers_mut().insert(
        AUTHORIZATION,
        "Bearer definitely-the-wrong-token-0123456789"
            .parse()
            .expect("parse authorization header"),
    );

    match connect_async(request).await {
        Err(WebSocketError::Http(response)) => {
            assert_eq!(response.status(), axum::http::StatusCode::UNAUTHORIZED);
        }
        Err(error) => panic!("expected HTTP 401, received {error}"),
        Ok(_) => panic!("unauthorized websocket unexpectedly connected"),
    }

    relay.stop().await;
}

#[tokio::test]
async fn bridge_replays_events_and_delivers_commands_created_while_offline() {
    let relay = RelayHarness::start().await;
    let source = Arc::new(FakeBridgeSource::new("engine-reconnect"));
    source.append_event(fake_event(1, "before-first-connect"));

    let (first_cancellation, first_bridge) = start_bridge(source.clone(), &relay);
    wait_for_engine_state(&relay.state, true).await;
    wait_until("first event cursor acknowledgement", || {
        source.relay_cursor.load(Ordering::Acquire) == 1
    })
    .await;
    assert_eq!(relay_source_cursor(&relay, &source.engine_id).await, 1);
    assert!(
        relay
            .state
            .store()
            .replay_events(
                EventCursor {
                    after_global_sequence: 0,
                },
                100,
            )
            .await
            .expect("replay relay events")
            .iter()
            .any(|event| event.payload == json!({"marker": "before-first-connect"}))
    );

    stop_bridge(first_cancellation, first_bridge).await;
    wait_for_engine_state(&relay.state, false).await;

    let accepted = relay
        .state
        .accept_mobile_command(CommandRequest {
            command_id: Some("offline-command".to_owned()),
            idempotency_key: "offline-command-key".to_owned(),
            session_id: None,
            command: CommandKind::Interrupt,
            requested_at: now_ms(),
            trace_id: Some("offline-reconnect-test".to_owned()),
        })
        .await
        .expect("accept offline command");
    assert!(accepted.inserted);
    source.append_event(fake_event(2, "before-reconnect"));

    let (second_cancellation, second_bridge) = start_bridge(source.clone(), &relay);
    wait_for_engine_state(&relay.state, true).await;
    wait_until("offline command delivery", || {
        source
            .delivered_command_ids()
            .iter()
            .any(|command_id| command_id == "offline-command")
    })
    .await;
    wait_until("second event cursor acknowledgement", || {
        source.relay_cursor.load(Ordering::Acquire) == 2
    })
    .await;
    assert_eq!(relay_source_cursor(&relay, &source.engine_id).await, 2);
    assert!(
        source
            .cursor_commits
            .lock()
            .expect("cursor commit lock poisoned")
            .contains(&2)
    );

    stop_bridge(second_cancellation, second_bridge).await;
    wait_for_engine_state(&relay.state, false).await;
    relay.stop().await;
}

#[tokio::test]
async fn engine_ack_advances_relay_command_to_engine_durable() {
    let relay = RelayHarness::start().await;
    relay
        .state
        .accept_mobile_command(CommandRequest {
            command_id: Some("acknowledged-command".to_owned()),
            idempotency_key: "acknowledged-command-key".to_owned(),
            session_id: None,
            command: CommandKind::Interrupt,
            requested_at: now_ms(),
            trace_id: None,
        })
        .await
        .expect("accept command before bridge connection");
    let source = Arc::new(FakeBridgeSource::new("engine-command-ack"));
    let (cancellation, bridge) = start_bridge(source.clone(), &relay);
    wait_until("command delivery before acknowledgement", || {
        source
            .delivered_command_ids()
            .iter()
            .any(|command_id| command_id == "acknowledged-command")
    })
    .await;
    wait_for_command_state(&relay, "acknowledged-command", CommandState::EngineDurable).await;

    stop_bridge(cancellation, bridge).await;
    relay.stop().await;
}

#[tokio::test]
async fn engine_command_state_events_materialize_the_relay_command_row() {
    let relay = RelayHarness::start().await;
    relay
        .state
        .accept_mobile_command(CommandRequest {
            command_id: Some("materialized-command".to_owned()),
            idempotency_key: "materialized-command-key".to_owned(),
            session_id: None,
            command: CommandKind::Interrupt,
            requested_at: now_ms(),
            trace_id: None,
        })
        .await
        .expect("accept materialized command");
    let source = Arc::new(FakeBridgeSource::new("engine-command-materialization"));
    let (cancellation, bridge) = start_bridge(source.clone(), &relay);
    wait_for_command_state(&relay, "materialized-command", CommandState::EngineDurable).await;

    source.append_event(fake_command_state_event(
        1,
        "materialized-command",
        CommandState::SentToChild,
    ));
    wait_for_command_state(&relay, "materialized-command", CommandState::SentToChild).await;
    source.append_event(fake_command_state_event(
        2,
        "materialized-command",
        CommandState::Completed,
    ));
    wait_for_command_state(&relay, "materialized-command", CommandState::Completed).await;

    stop_bridge(cancellation, bridge).await;
    relay.stop().await;
}

#[tokio::test]
async fn periodic_replay_recovers_a_durable_command_event_without_a_broadcast_wake() {
    let relay = RelayHarness::start().await;
    relay
        .state
        .accept_mobile_command(CommandRequest {
            command_id: Some("missed-wake-command".to_owned()),
            idempotency_key: "missed-wake-command-key".to_owned(),
            session_id: None,
            command: CommandKind::Interrupt,
            requested_at: now_ms(),
            trace_id: None,
        })
        .await
        .expect("accept missed-wake command");
    let source = Arc::new(FakeBridgeSource::new("engine-missed-wake"));
    let (cancellation, bridge) = start_bridge(source.clone(), &relay);
    wait_for_command_state(&relay, "missed-wake-command", CommandState::EngineDurable).await;
    sleep(Duration::from_millis(20)).await;

    tokio::time::pause();
    source.persist_event_without_wake(fake_command_state_event(
        1,
        "missed-wake-command",
        CommandState::Completed,
    ));
    tokio::time::advance(Duration::from_secs(10)).await;
    for _ in 0..100 {
        let command = relay
            .state
            .store()
            .get_command("missed-wake-command")
            .await
            .expect("load missed-wake command")
            .expect("missed-wake command exists");
        if command.state == CommandState::Completed {
            break;
        }
        tokio::task::yield_now().await;
    }
    tokio::time::resume();

    let command = relay
        .state
        .store()
        .get_command("missed-wake-command")
        .await
        .expect("reload missed-wake command")
        .expect("missed-wake command remains");
    assert_eq!(command.state, CommandState::Completed);
    wait_until("missed-wake event cursor acknowledgement", || {
        source.relay_cursor.load(Ordering::Acquire) == 1
    })
    .await;

    stop_bridge(cancellation, bridge).await;
    relay.stop().await;
}

#[tokio::test]
async fn engine_command_progress_survives_cross_host_clock_skew() {
    let relay = RelayHarness::start().await;
    let receipt_updated_at = now_ms() + 1_000;
    relay
        .state
        .accept_mobile_command(CommandRequest {
            command_id: Some("clock-skew-command".to_owned()),
            idempotency_key: "clock-skew-command-key".to_owned(),
            session_id: None,
            command: CommandKind::Interrupt,
            requested_at: receipt_updated_at,
            trace_id: None,
        })
        .await
        .expect("accept clock-skew command");
    let source = Arc::new(FakeBridgeSource::new("engine-clock-skew"));
    let (cancellation, bridge) = start_bridge(source.clone(), &relay);
    wait_for_command_state(&relay, "clock-skew-command", CommandState::EngineDurable).await;

    source.append_event(fake_command_state_event_at(
        1,
        "clock-skew-command",
        CommandState::Completed,
        receipt_updated_at - 1,
    ));
    wait_for_command_state(&relay, "clock-skew-command", CommandState::Completed).await;
    let alias = relay
        .state
        .store()
        .get_command_alias("clock-skew-command")
        .await
        .expect("load clock-skew alias")
        .expect("clock-skew alias exists");
    assert_eq!(alias.engine_state, CommandState::Completed);
    assert_eq!(alias.engine_updated_at, receipt_updated_at - 1);

    source.append_event(fake_command_state_event_at(
        2,
        "clock-skew-command",
        CommandState::Failed,
        receipt_updated_at + 1,
    ));
    wait_until("conflicting terminal observation consumption", || {
        source.relay_cursor.load(Ordering::Acquire) == 2
    })
    .await;
    let command = relay
        .state
        .store()
        .get_command("clock-skew-command")
        .await
        .expect("load clock-skew command")
        .expect("clock-skew command exists");
    let alias = relay
        .state
        .store()
        .get_command_alias("clock-skew-command")
        .await
        .expect("reload clock-skew alias")
        .expect("clock-skew alias remains");
    assert_eq!(command.state, CommandState::Completed);
    assert_eq!(alias.engine_state, CommandState::Completed);
    assert_eq!(alias.engine_updated_at, receipt_updated_at - 1);

    stop_bridge(cancellation, bridge).await;
    relay.stop().await;
}

#[tokio::test]
async fn runtime_status_session_summaries_materialize_but_raw_notifications_remain_event_only() {
    let relay = RelayHarness::start().await;
    let source = Arc::new(FakeBridgeSource::new("engine-runtime-status"));
    let updated_at = now_ms();
    let mut working = SessionSummary::new(
        "runtime-session",
        "fermin-code",
        "Runtime session",
        updated_at,
    );
    working.activity_status = ActivityStatus::Working;
    working.runtime_status = Some("WORKING".to_owned());
    source.append_event(fake_runtime_status_event(1, &working));

    let (cancellation, bridge) = start_bridge(source.clone(), &relay);
    wait_until("working runtime status materialization", || {
        source.relay_cursor.load(Ordering::Acquire) == 1
    })
    .await;
    let materialized_working = relay
        .state
        .store()
        .get_session("runtime-session")
        .await
        .expect("load working runtime session")
        .expect("working runtime session materialized");
    assert_eq!(
        materialized_working.session.activity_status,
        ActivityStatus::Working
    );
    assert_eq!(
        materialized_working.session.runtime_status.as_deref(),
        Some("WORKING")
    );

    let mut waiting = working;
    waiting.activity_status = ActivityStatus::Ready;
    waiting.runtime_status = Some("WAITING".to_owned());
    waiting.updated_at = updated_at + 1;
    source.append_event(fake_runtime_status_event(2, &waiting));
    wait_until("waiting runtime status materialization", || {
        source.relay_cursor.load(Ordering::Acquire) == 2
    })
    .await;
    let materialized_waiting = relay
        .state
        .store()
        .get_session("runtime-session")
        .await
        .expect("load waiting runtime session")
        .expect("waiting runtime session remains materialized");
    assert_eq!(
        materialized_waiting.session.activity_status,
        ActivityStatus::Ready
    );
    assert_eq!(
        materialized_waiting.session.runtime_status.as_deref(),
        Some("WAITING")
    );
    assert!(materialized_waiting.revision > materialized_working.revision);

    let raw_payload = json!({
        "method": "thread/status/changed",
        "threadId": "runtime-thread",
        "params": {
            "threadId": "runtime-thread",
            "status": {"type": "active"},
        },
    });
    source.append_event(DurableEvent {
        event_id: "raw-runtime-status-3".to_owned(),
        global_sequence: 3,
        session_sequence: None,
        session_id: Some("runtime-session".to_owned()),
        command_id: None,
        process_epoch: Some(7),
        kind: EventKind::RuntimeStatus,
        payload: raw_payload.clone(),
        created_at: updated_at + 2,
    });
    wait_until("raw runtime status persistence", || {
        source.relay_cursor.load(Ordering::Acquire) == 3
    })
    .await;
    let after_raw_notification = relay
        .state
        .store()
        .get_session("runtime-session")
        .await
        .expect("load session after raw runtime notification")
        .expect("runtime session remains materialized");
    assert_eq!(after_raw_notification, materialized_waiting);
    assert!(
        relay
            .state
            .store()
            .replay_events(EventCursor::default(), 1_000)
            .await
            .expect("replay runtime status events")
            .iter()
            .any(|event| event.kind == EventKind::RuntimeStatus && event.payload == raw_payload),
        "raw AppServer runtime status must remain available as an event"
    );

    stop_bridge(cancellation, bridge).await;
    relay.stop().await;
}

#[tokio::test]
async fn canonical_command_receipt_survives_reconnect_and_materializes_original_id() {
    let relay = RelayHarness::start().await;
    relay
        .state
        .accept_mobile_command(CommandRequest {
            command_id: Some("relay-original-command".to_owned()),
            idempotency_key: "shared-idempotency-key".to_owned(),
            session_id: None,
            command: CommandKind::Interrupt,
            requested_at: now_ms(),
            trace_id: None,
        })
        .await
        .expect("accept relay command");

    let source = Arc::new(FakeBridgeSource::new("engine-command-alias"));
    let canonical_updated_at = now_ms();
    source.seed_existing_command(CommandRecord {
        command_id: "engine-canonical-command".to_owned(),
        idempotency_key: "shared-idempotency-key".to_owned(),
        session_id: None,
        command: CommandKind::Interrupt,
        state: CommandState::EngineDurable,
        requested_at: canonical_updated_at - 10,
        accepted_at: canonical_updated_at - 10,
        updated_at: canonical_updated_at,
        trace_id: None,
        lease_generation: Some(1),
        error: None,
    });

    let (first_cancellation, first_bridge) = start_bridge(source.clone(), &relay);
    wait_for_command_state(
        &relay,
        "relay-original-command",
        CommandState::EngineDurable,
    )
    .await;
    let alias = relay
        .state
        .store()
        .get_command_alias("relay-original-command")
        .await
        .expect("load durable command alias")
        .expect("command alias exists");
    assert_eq!(alias.engine_command_id, "engine-canonical-command");
    assert_eq!(alias.idempotency_key, "shared-idempotency-key");

    stop_bridge(first_cancellation, first_bridge).await;
    wait_for_engine_state(&relay.state, false).await;
    source.append_event(fake_command_state_event(
        1,
        "engine-canonical-command",
        CommandState::Completed,
    ));

    let (second_cancellation, second_bridge) = start_bridge(source.clone(), &relay);
    wait_for_command_state(&relay, "relay-original-command", CommandState::Completed).await;
    assert!(
        relay
            .state
            .store()
            .get_command("engine-canonical-command")
            .await
            .expect("check canonical relay row")
            .is_none(),
        "the relay must materialize the original command instead of inventing a canonical row"
    );

    stop_bridge(second_cancellation, second_bridge).await;
    relay.stop().await;
}

#[tokio::test]
async fn mobile_backend_preserves_target_routing_and_prompt_variant() {
    let relay = RelayHarness::start().await;
    let mut parent = SessionSummary::new("parent-session", "project", "Parent", now_ms());
    parent.window_id = "parent-window".to_owned();
    relay
        .state
        .store()
        .upsert_session(parent, None)
        .await
        .expect("seed parent session");

    relay
        .state
        .set_prompt_improver_preference(PromptImproverVariant::Motivational)
        .await
        .expect("set relay prompt preference");
    let message = relay
        .state
        .submit_command(
            Some("parent-window".to_owned()),
            CommandRequest {
                command_id: Some("routed-message".to_owned()),
                idempotency_key: "routed-message-key".to_owned(),
                session_id: Some("stale-mobile-session".to_owned()),
                command: CommandKind::SendMessage {
                    content: "Improve this".to_owned(),
                    client_message_id: "mobile-message".to_owned(),
                    attachments: Vec::new(),
                    service_tier: None,
                },
                requested_at: now_ms(),
                trace_id: Some("upstream-trace".to_owned()),
            },
        )
        .await
        .expect("accept routed message");
    assert_eq!(
        message.command.session_id.as_deref(),
        Some("parent-session")
    );
    let message_trace = message
        .command
        .trace_id
        .as_deref()
        .expect("message trace metadata");
    assert!(message_trace.starts_with("fermin-prompt-variant:"));
    assert!(message_trace.contains("motivational"));
    assert!(message_trace.contains("upstream-trace"));

    let subagent = relay
        .state
        .submit_command(
            Some("parent-window".to_owned()),
            CommandRequest {
                command_id: Some("routed-subagent".to_owned()),
                idempotency_key: "routed-subagent-key".to_owned(),
                session_id: Some("child-session".to_owned()),
                command: CommandKind::CreateSubagent {
                    prompt: "Inspect the worker".to_owned(),
                    display_name: Some("Worker".to_owned()),
                    parent_notification_prompt: None,
                },
                requested_at: now_ms(),
                trace_id: Some("subagent-upstream".to_owned()),
            },
        )
        .await
        .expect("accept routed subagent");
    assert_eq!(
        subagent.command.session_id.as_deref(),
        Some("parent-session")
    );
    let subagent_trace = subagent
        .command
        .trace_id
        .as_deref()
        .expect("subagent routing metadata");
    assert!(subagent_trace.starts_with("fermin-subagent-routing:"));
    assert!(subagent_trace.contains("child-session"));
    assert!(subagent_trace.contains("subagent-upstream"));

    relay.stop().await;
}

#[tokio::test]
async fn offline_command_backlog_drains_past_the_first_batch() {
    let relay = RelayHarness::start().await;
    for index in 0..129 {
        relay
            .state
            .accept_mobile_command(CommandRequest {
                command_id: Some(format!("backlog-command-{index:03}")),
                idempotency_key: format!("backlog-key-{index:03}"),
                session_id: None,
                command: CommandKind::Interrupt,
                requested_at: now_ms() + index,
                trace_id: None,
            })
            .await
            .expect("accept backlog command");
    }

    let source = Arc::new(FakeBridgeSource::new("engine-command-backlog"));
    let (cancellation, bridge) = start_bridge(source.clone(), &relay);
    wait_until("complete command backlog", || {
        source.delivered_command_ids().len() == 129
    })
    .await;
    assert_eq!(source.delivered_command_ids().len(), 129);

    stop_bridge(cancellation, bridge).await;
    relay.stop().await;
}

#[tokio::test]
async fn clean_reconnect_advances_the_fence_generation() {
    let relay = RelayHarness::start().await;
    let (mut first_socket, first_ack) = connect_engine(&relay, "engine-fence", 101).await;
    first_socket
        .close(None)
        .await
        .expect("close first websocket");
    wait_for_engine_state(&relay.state, false).await;

    let (mut second_socket, second_ack) = connect_engine(&relay, "engine-fence", 102).await;
    assert!(
        second_ack.fence_generation > first_ack.fence_generation,
        "fence generations must be monotonic across clean reconnects"
    );
    second_socket
        .close(None)
        .await
        .expect("close second websocket");
    relay.stop().await;
}

#[tokio::test]
async fn replacement_connection_supersedes_an_unreleased_same_engine_lease() {
    let relay = RelayHarness::start().await;
    let (mut first_socket, first_ack) = connect_engine(&relay, "engine-takeover", 201).await;

    let (mut replacement_socket, replacement_ack) = timeout(
        Duration::from_secs(1),
        connect_engine(&relay, "engine-takeover", 202),
    )
    .await
    .expect("same logical engine reconnect must not wait for the old lease TTL");
    assert!(replacement_ack.fence_generation > first_ack.fence_generation);

    let stale = RelayEnvelope {
        protocol_version: PROTOCOL_VERSION,
        engine_id: "engine-takeover".to_owned(),
        connection_epoch: 201,
        sequence: 2,
        acknowledgement: first_ack.sequence,
        resume_cursor: Some(0),
        fence_generation: first_ack.fence_generation,
        frame: RelayFrame::Ack,
    };
    send_envelope(&mut first_socket, &stale).await;
    wait_for_socket_close(&mut first_socket).await;
    wait_for_engine_state(&relay.state, true).await;

    replacement_socket
        .close(None)
        .await
        .expect("close replacement websocket");
    relay.stop().await;
}

#[tokio::test]
async fn event_created_between_replay_and_subscription_is_not_stranded() {
    let relay = RelayHarness::start().await;
    let source = Arc::new(FakeBridgeSource::new("engine-subscription-race"));
    *source
        .inject_after_empty_replay
        .lock()
        .expect("replay injection lock poisoned") =
        Some(fake_event(1, "between-replay-and-subscribe"));

    let (cancellation, bridge) = start_bridge(source.clone(), &relay);
    wait_for_engine_state(&relay.state, true).await;
    wait_until("event injected during the subscription race", || {
        source
            .events
            .lock()
            .expect("event lock poisoned")
            .iter()
            .any(|event| event.global_sequence == 1)
    })
    .await;
    wait_until("cursor acknowledgement for raced event", || {
        source.relay_cursor.load(Ordering::Acquire) == 1
    })
    .await;

    stop_bridge(cancellation, bridge).await;
    relay.stop().await;
}

#[tokio::test]
async fn authoritative_snapshot_reconciles_sessions_and_preserves_message_revisions() {
    let relay = RelayHarness::start().await;
    let snapshot_generated_at = now_ms();

    relay
        .state
        .store()
        .upsert_session(
            SessionSummary::new(
                "stale-session",
                "project",
                "Stale",
                snapshot_generated_at - 10,
            ),
            None,
        )
        .await
        .expect("seed stale relay session");

    let mut retained_session = SessionSummary::new(
        "retained-session",
        "project",
        "Authoritative",
        snapshot_generated_at,
    );
    let existing_message = MobileMessage::assistant(
        "existing-message",
        "newer relay content",
        snapshot_generated_at - 5,
    );
    relay
        .state
        .store()
        .upsert_session(retained_session.clone(), None)
        .await
        .expect("seed retained relay session");
    relay
        .state
        .store()
        .upsert_message(
            MessageMutation {
                session_id: retained_session.session_id.clone(),
                message: existing_message.clone(),
                revision: 7,
                updated_at: snapshot_generated_at - 5,
                final_: true,
            },
            None,
        )
        .await
        .expect("seed newer relay message revision");

    let snapshot_existing = MobileMessage::assistant(
        "existing-message",
        "older snapshot content",
        snapshot_generated_at - 20,
    );
    let snapshot_missing =
        MobileMessage::assistant("missing-message", "snapshot content", snapshot_generated_at);
    retained_session.messages = vec![snapshot_existing, snapshot_missing.clone()];
    retained_session.message_count = 2;

    let source = Arc::new(FakeBridgeSource::new("engine-authoritative-snapshot"));
    source.replace_snapshot(AuthoritativeSnapshot {
        schema_version: MOBILE_SCHEMA_VERSION,
        global_sequence: 0,
        generated_at: snapshot_generated_at,
        sessions: vec![retained_session],
        models: Vec::new(),
    });

    let (cancellation, bridge) = start_bridge(source.clone(), &relay);
    wait_for_engine_state(&relay.state, true).await;
    wait_until_snapshot_event(&relay).await;

    assert!(
        relay
            .state
            .store()
            .get_session("stale-session")
            .await
            .expect("load stale session")
            .is_none(),
        "snapshot must delete relay sessions absent from the authoritative source"
    );

    let messages = relay
        .state
        .store()
        .list_messages("retained-session")
        .await
        .expect("load reconciled messages");
    let preserved = messages
        .iter()
        .find(|stored| stored.message.id == "existing-message")
        .expect("existing message remains present");
    assert_eq!(preserved.revision, 7);
    assert_eq!(preserved.message.content, "newer relay content");
    let inserted = messages
        .iter()
        .find(|stored| stored.message.id == "missing-message")
        .expect("snapshot inserts missing message");
    assert_eq!(inserted.revision, 1);
    assert_eq!(inserted.message.content, "snapshot content");

    let mobile_snapshot = MobileBackend::snapshot(relay.state.as_ref())
        .await
        .expect("read lightweight mobile snapshot");
    assert!(mobile_snapshot.sessions[0].messages.is_empty());
    assert_eq!(mobile_snapshot.sessions[0].message_count, 2);
    let bridge_snapshot = relay
        .state
        .snapshot()
        .await
        .expect("read full bridge snapshot");
    assert_eq!(bridge_snapshot.sessions[0].messages.len(), 2);

    source.append_event(DurableEvent {
        event_id: "missing-message-revision-2".to_owned(),
        global_sequence: 1,
        session_sequence: Some(1),
        session_id: Some("retained-session".to_owned()),
        command_id: None,
        process_epoch: Some(7),
        kind: EventKind::MessagePatch,
        payload: serde_json::to_value(MessagePatch {
            window_id: "retained-session".to_owned(),
            message: MobileMessage::assistant(
                "missing-message",
                "patched content",
                snapshot_generated_at + 1,
            ),
            revision: 2,
            updated_at: snapshot_generated_at + 1,
            final_: true,
        })
        .expect("serialize message patch"),
        created_at: snapshot_generated_at + 1,
    });
    wait_until("message patch revision 2", || {
        source.relay_cursor.load(Ordering::Acquire) == 1
    })
    .await;
    let patched = relay
        .state
        .store()
        .list_messages("retained-session")
        .await
        .expect("load patched messages")
        .into_iter()
        .find(|stored| stored.message.id == "missing-message")
        .expect("patched message remains present");
    assert_eq!(patched.revision, 2);
    assert_eq!(patched.message.content, "patched content");

    let snapshot_event = relay
        .state
        .store()
        .replay_events(EventCursor::default(), 1_000)
        .await
        .expect("replay relay events")
        .into_iter()
        .find(|event| event.kind == EventKind::Snapshot)
        .expect("mobile snapshot event exists");
    let items = snapshot_event
        .payload
        .get("items")
        .and_then(Value::as_array)
        .expect("snapshot event exposes mobile items array");
    assert_eq!(items.len(), 1);
    assert_eq!(
        items[0].get("sessionId").and_then(Value::as_str),
        Some("retained-session")
    );
    assert!(
        items[0]
            .get("messages")
            .and_then(Value::as_array)
            .is_none_or(Vec::is_empty)
    );

    stop_bridge(cancellation, bridge).await;
    relay.stop().await;
}

#[tokio::test]
async fn relay_purges_unmanaged_legacy_index_without_importing_legacy_events() {
    let relay = RelayHarness::start().await;
    let now = now_ms();
    let mut legacy_active =
        SessionSummary::new("legacy-active", "project", "Legacy active", now - 20);
    legacy_active.managed_by_fermin = false;
    legacy_active.runtime_status = Some("WAITING".to_owned());
    let mut legacy_archived =
        SessionSummary::new("legacy-archived", "project", "Legacy archived", now - 10);
    legacy_archived.managed_by_fermin = false;
    legacy_archived.runtime_status = Some("ARCHIVED".to_owned());
    for session in [legacy_active.clone(), legacy_archived] {
        relay
            .state
            .store()
            .upsert_session(session, None)
            .await
            .expect("seed unmanaged legacy relay session");
    }
    relay
        .state
        .store()
        .append_event(
            NewEvent {
                event_id: Some("pre-cutover-legacy-session".to_owned()),
                session_id: Some(legacy_active.session_id.clone()),
                command_id: None,
                process_epoch: Some(1),
                kind: EventKind::SessionUpserted,
                payload: serde_json::to_value(&legacy_active)
                    .expect("serialize pre-cutover legacy session"),
                created_at: now - 1,
            },
            None,
        )
        .await
        .expect("seed pre-cutover legacy event");

    let managed = SessionSummary::new("fermin-owned", "project", "Fermín owned", now);
    let source = Arc::new(FakeBridgeSource::new("engine-managed-contract"));
    source.replace_snapshot(AuthoritativeSnapshot {
        schema_version: MOBILE_SCHEMA_VERSION,
        global_sequence: 0,
        generated_at: now,
        sessions: vec![legacy_active.clone(), managed.clone()],
        models: Vec::new(),
    });

    let (cancellation, bridge) = start_bridge(source.clone(), &relay);
    wait_for_engine_state(&relay.state, true).await;
    wait_until_snapshot_event(&relay).await;

    let stored = relay
        .state
        .store()
        .list_sessions()
        .await
        .expect("list reconciled relay sessions");
    assert_eq!(stored.len(), 1);
    assert_eq!(stored[0].session.session_id, managed.session_id);
    let mobile = MobileBackend::snapshot(relay.state.as_ref())
        .await
        .expect("read managed mobile snapshot");
    assert_eq!(mobile.sessions.len(), 1);
    assert_eq!(mobile.sessions[0].session_id, managed.session_id);
    let history = MobileBackend::session_history(
        relay.state.as_ref(),
        history_query("", SessionHistorySort::Recent),
    )
    .await
    .expect("read managed history");
    assert_eq!(history_ids(&history), vec!["fermin-owned"]);

    source.append_event(DurableEvent {
        event_id: "legacy-session-upsert".to_owned(),
        global_sequence: 1,
        session_sequence: Some(1),
        session_id: Some(legacy_active.session_id.clone()),
        command_id: None,
        process_epoch: Some(7),
        kind: EventKind::SessionUpserted,
        payload: serde_json::to_value(&legacy_active).expect("serialize legacy session"),
        created_at: now + 1,
    });
    source.append_event(DurableEvent {
        event_id: "legacy-message-patch".to_owned(),
        global_sequence: 2,
        session_sequence: Some(2),
        session_id: Some(legacy_active.session_id.clone()),
        command_id: None,
        process_epoch: Some(7),
        kind: EventKind::MessagePatch,
        payload: serde_json::to_value(MessagePatch {
            window_id: legacy_active.session_id.clone(),
            message: MobileMessage::assistant("legacy-message", "must stay hidden", now + 2),
            revision: 1,
            updated_at: now + 2,
            final_: true,
        })
        .expect("serialize legacy message patch"),
        created_at: now + 2,
    });
    wait_until("unmanaged legacy events acknowledged", || {
        source.relay_cursor.load(Ordering::Acquire) == 2
    })
    .await;
    assert!(
        relay
            .state
            .store()
            .get_session(legacy_active.session_id.clone())
            .await
            .expect("read legacy session after ignored event")
            .is_none()
    );
    assert!(
        relay
            .state
            .store()
            .list_messages(legacy_active.session_id)
            .await
            .expect("read legacy messages after ignored event")
            .is_empty()
    );
    let replay = MobileBackend::replay_events(
        relay.state.as_ref(),
        ReplayCursor {
            last_event_id: None,
            after_global_sequence: Some(0),
        },
        100,
    )
    .await
    .expect("replay after ownership cutover");
    assert!(replay.is_empty());

    stop_bridge(cancellation, bridge).await;
    relay.stop().await;
}

#[tokio::test]
async fn connected_idle_heartbeat_refreshes_snapshot_without_advancing_cursor() {
    let relay = RelayHarness::start().await;
    let connection_epoch = 211;
    let engine_id = "engine-idle-freshness";
    let authority_generated_at = now_ms() - 600_000;
    let (mut socket, ack) = connect_engine(&relay, engine_id, connection_epoch).await;

    let snapshot = RelayEnvelope {
        protocol_version: PROTOCOL_VERSION,
        engine_id: engine_id.to_owned(),
        connection_epoch,
        sequence: 2,
        acknowledgement: ack.sequence,
        resume_cursor: Some(0),
        fence_generation: ack.fence_generation,
        frame: RelayFrame::Snapshot {
            snapshot: AuthoritativeSnapshot {
                schema_version: MOBILE_SCHEMA_VERSION,
                global_sequence: 0,
                generated_at: authority_generated_at,
                sessions: Vec::new(),
                models: Vec::new(),
            },
        },
    };
    send_envelope(&mut socket, &snapshot).await;
    wait_until_snapshot_event(&relay).await;
    let durable_cursor = RelayState::snapshot(relay.state.as_ref())
        .await
        .expect("read snapshot before heartbeat")
        .global_sequence;

    let signal_lower_bound = now_ms();
    let heartbeat = RelayEnvelope {
        protocol_version: PROTOCOL_VERSION,
        engine_id: engine_id.to_owned(),
        connection_epoch,
        sequence: 3,
        acknowledgement: ack.sequence,
        resume_cursor: Some(0),
        fence_generation: ack.fence_generation,
        frame: RelayFrame::Ping {
            sent_at: signal_lower_bound,
        },
    };
    send_envelope(&mut socket, &heartbeat).await;
    wait_for_engine_sequence(&relay.state, 3).await;

    let health = relay.state.active_engine_health().await;
    let heartbeat_at = health["lastHeartbeatAt"]
        .as_u64()
        .expect("health exposes engine heartbeat time");
    assert!(heartbeat_at >= signal_lower_bound as u64);
    assert!(heartbeat_at <= now_ms() as u64);

    let first = RelayState::snapshot(relay.state.as_ref())
        .await
        .expect("read heartbeat-refreshed snapshot");
    sleep(Duration::from_millis(75)).await;
    let second = RelayState::snapshot(relay.state.as_ref())
        .await
        .expect("read idle connected snapshot again");
    assert_eq!(first.generated_at, heartbeat_at as i64);
    assert_eq!(second.generated_at, first.generated_at);
    assert_eq!(first.global_sequence, durable_cursor);
    assert_eq!(second.global_sequence, durable_cursor);

    socket.close(None).await.expect("close idle engine socket");
    wait_for_engine_state(&relay.state, false).await;
    relay.stop().await;
}

#[tokio::test]
async fn offline_snapshot_freshness_does_not_advance_on_read_or_store_reopen() {
    let relay = RelayHarness::start().await;
    let authoritative_generated_at = now_ms() - 600_000;
    let mut authoritative_session = SessionSummary::new(
        "freshness-session",
        "project",
        "Durable authority",
        authoritative_generated_at,
    );
    authoritative_session.updated_at = authoritative_generated_at;
    let source = Arc::new(FakeBridgeSource::new("engine-freshness-watermark"));
    source.replace_snapshot(AuthoritativeSnapshot {
        schema_version: MOBILE_SCHEMA_VERSION,
        global_sequence: 17,
        generated_at: authoritative_generated_at,
        sessions: vec![authoritative_session],
        models: Vec::new(),
    });

    let (cancellation, bridge) = start_bridge(source, &relay);
    wait_until_snapshot_event(&relay).await;
    let connected = RelayState::snapshot(relay.state.as_ref())
        .await
        .expect("read connected relay snapshot");
    assert!(connected.generated_at > authoritative_generated_at);
    assert!(connected.global_sequence > 0);
    assert_eq!(connected.sessions.len(), 1);
    let snapshot_event_cursor = relay
        .state
        .store()
        .replay_events(EventCursor::default(), 1_000)
        .await
        .expect("read durable relay events")
        .into_iter()
        .filter(|event| event.kind == EventKind::Snapshot)
        .map(|event| event.global_sequence)
        .max()
        .expect("authoritative snapshot event exists");
    assert_eq!(connected.global_sequence, snapshot_event_cursor);

    stop_bridge(cancellation, bridge).await;
    wait_for_engine_state(&relay.state, false).await;
    let queued = relay
        .state
        .accept_mobile_command(CommandRequest {
            command_id: Some("offline-freshness-command".to_owned()),
            idempotency_key: "offline-freshness-command-key".to_owned(),
            session_id: None,
            command: CommandKind::Interrupt,
            requested_at: now_ms(),
            trace_id: None,
        })
        .await
        .expect("queue command while engine is offline");
    assert!(queued.inserted);
    assert_eq!(queued.command.state, CommandState::Accepted);
    sleep(Duration::from_millis(75)).await;
    let first_offline = RelayState::snapshot(relay.state.as_ref())
        .await
        .expect("read first offline snapshot");
    sleep(Duration::from_millis(75)).await;
    let second_offline = RelayState::snapshot(relay.state.as_ref())
        .await
        .expect("read second offline snapshot");
    assert_eq!(first_offline.generated_at, authoritative_generated_at);
    assert_eq!(second_offline.generated_at, first_offline.generated_at);
    assert_eq!(
        second_offline.global_sequence,
        first_offline.global_sequence
    );

    let reopened = RelayState::open(relay.relay_config())
        .await
        .expect("reopen relay store");
    let after_reopen = RelayState::snapshot(&reopened)
        .await
        .expect("read reopened relay snapshot");
    assert_eq!(after_reopen.generated_at, authoritative_generated_at);
    assert_eq!(after_reopen.global_sequence, connected.global_sequence);
    assert_eq!(after_reopen.sessions.len(), 1);

    relay.stop().await;
}

#[tokio::test]
async fn session_history_honors_relevance_name_and_recent_with_total_ordering() {
    let relay = RelayHarness::start().await;
    let mut sessions = vec![
        SessionSummary::new("a-preview", "project", "Alpha", 400),
        SessionSummary::new("e-alpha", "project", "Alpha", 400),
        SessionSummary::new("b-recent", "project", "beta", 500),
        SessionSummary::new("c-exact", "project", "Target", 100),
        SessionSummary::new("d-prefix", "project", "Target Notes", 300),
    ];
    sessions[0].last_message_preview = Some("contains target in preview".to_owned());
    for session in sessions {
        relay
            .state
            .store()
            .upsert_session(session, None)
            .await
            .expect("seed history session");
    }

    let relevance = MobileBackend::session_history(
        relay.state.as_ref(),
        history_query("target", SessionHistorySort::Relevance),
    )
    .await
    .expect("sort history by relevance");
    assert_eq!(
        history_ids(&relevance),
        vec!["c-exact", "d-prefix", "a-preview"]
    );
    assert_eq!(relevance.items[0].matched_in.as_deref(), Some("name"));
    assert_eq!(relevance.items[2].matched_in.as_deref(), Some("preview"));
    assert!(relevance.items[0].score > relevance.items[1].score);

    let name = MobileBackend::session_history(
        relay.state.as_ref(),
        history_query("", SessionHistorySort::Name),
    )
    .await
    .expect("sort history by name");
    assert_eq!(
        history_ids(&name),
        vec!["a-preview", "e-alpha", "b-recent", "c-exact", "d-prefix"]
    );

    let recent = MobileBackend::session_history(
        relay.state.as_ref(),
        history_query("", SessionHistorySort::Recent),
    )
    .await
    .expect("sort history by recency");
    assert_eq!(
        history_ids(&recent),
        vec!["b-recent", "a-preview", "e-alpha", "d-prefix", "c-exact"]
    );

    relay.stop().await;
}

#[tokio::test]
async fn relay_attachments_use_opaque_private_tokens_and_engine_auth() {
    let relay = RelayHarness::start().await;
    relay
        .state
        .store()
        .upsert_session(
            SessionSummary::new("attachment-session", "project", "Attachments", now_ms()),
            None,
        )
        .await
        .expect("seed attachment session");
    let image = Bytes::from_static(&[0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a]);
    let attachment = MobileBackend::upload_attachment(
        relay.state.as_ref(),
        "attachment-session".to_owned(),
        AttachmentUpload {
            file_name: "private image.png".to_owned(),
            mime_type: "image/png".to_owned(),
            bytes: image.clone(),
        },
    )
    .await
    .expect("store relay attachment");
    let opaque_path = attachment.path.expect("relay attachment path");
    let token = opaque_path
        .strip_prefix("relay://")
        .expect("opaque relay attachment token");
    assert!(!token.contains('/'));
    assert!(token.ends_with(".png"));

    let client = reqwest::Client::new();
    let url = format!("http://{}/v1/engine/attachments/{token}", relay.address);
    let unauthorized = client
        .get(&url)
        .send()
        .await
        .expect("request unauthenticated attachment");
    assert_eq!(unauthorized.status(), reqwest::StatusCode::UNAUTHORIZED);
    let response = client
        .get(&url)
        .bearer_auth(ENGINE_TOKEN)
        .send()
        .await
        .expect("request authenticated attachment");
    assert_eq!(response.status(), reqwest::StatusCode::OK);
    assert_eq!(
        response
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|value| value.to_str().ok()),
        Some("image/png")
    );
    assert_eq!(response.bytes().await.expect("read attachment"), image);

    let stored_path = relay
        ._temporary_directory
        .path()
        .join("attachments")
        .join(token);
    #[cfg(unix)]
    {
        assert_eq!(
            tokio::fs::metadata(stored_path.parent().unwrap())
                .await
                .expect("attachment directory metadata")
                .permissions()
                .mode()
                & 0o777,
            0o700
        );
        assert_eq!(
            tokio::fs::metadata(&stored_path)
                .await
                .expect("attachment file metadata")
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }
    let mobile_copy = MobileBackend::attachment_content(relay.state.as_ref(), opaque_path)
        .await
        .expect("read attachment through mobile backend");
    assert_eq!(mobile_copy.mime_type, "image/png");
    assert_eq!(mobile_copy.bytes, image);

    relay.stop().await;
}

#[tokio::test]
async fn reconnect_preserves_archived_history_and_resume_targets_same_session() {
    let relay = RelayHarness::start().await;
    let now = now_ms();
    let mut archived =
        SessionSummary::new("archived-session", "project", "Archived conversation", now);
    archived.runtime_status = Some("ARCHIVED".to_owned());
    archived.project_path = Some("/tmp/project".to_owned());
    relay
        .state
        .store()
        .upsert_session(archived.clone(), None)
        .await
        .expect("seed archived relay session");
    relay
        .state
        .store()
        .upsert_message(
            MessageMutation {
                session_id: archived.session_id.clone(),
                message: MobileMessage::assistant("archived-message", "preserved", now),
                revision: 3,
                updated_at: now,
                final_: true,
            },
            None,
        )
        .await
        .expect("seed archived message");

    let source = Arc::new(FakeBridgeSource::new("engine-archived-history"));
    let (cancellation, bridge) = start_bridge(source.clone(), &relay);
    wait_for_engine_state(&relay.state, true).await;
    wait_until_snapshot_event(&relay).await;

    assert!(
        relay
            .state
            .store()
            .get_session("archived-session")
            .await
            .expect("read archived session after snapshot")
            .is_some(),
        "an active-only engine snapshot must not erase archived relay history"
    );
    assert!(
        MobileBackend::snapshot(relay.state.as_ref())
            .await
            .expect("read active snapshot")
            .sessions
            .is_empty()
    );
    assert!(
        MobileBackend::session(relay.state.as_ref(), "archived-session".to_owned())
            .await
            .expect("read active session")
            .is_none()
    );
    let history = MobileBackend::session_history(
        relay.state.as_ref(),
        SessionHistoryQuery {
            query: String::new(),
            project_path: None,
            state: SessionHistoryState::Archived,
            from: None,
            to: None,
            sort: SessionHistorySort::Recent,
            offset: 0,
            limit: 20,
            refresh: false,
        },
    )
    .await
    .expect("read archived history");
    assert_eq!(history.items.len(), 1);
    assert_eq!(history.items[0].session_id, "archived-session");
    assert_eq!(
        history.items[0].archived_id.as_deref(),
        Some("archived-session")
    );
    assert_eq!(
        relay
            .state
            .store()
            .list_messages("archived-session")
            .await
            .expect("read archived messages")[0]
            .revision,
        3
    );

    let resumed = MobileBackend::resume_history(
        relay.state.as_ref(),
        "archived-session".to_owned(),
        "resume-archived-session".to_owned(),
    )
    .await
    .expect("resume archived session");
    assert_eq!(resumed.session_id, "archived-session");
    wait_until("resume command delivered", || {
        source
            .commands
            .lock()
            .expect("command lock poisoned")
            .iter()
            .any(|command| command.idempotency_key == "resume-archived-session")
    })
    .await;
    let command = source
        .commands
        .lock()
        .expect("command lock poisoned")
        .iter()
        .find(|command| command.idempotency_key == "resume-archived-session")
        .cloned()
        .expect("resume command");
    assert_eq!(command.session_id.as_deref(), Some("archived-session"));
    assert!(matches!(
        command.command,
        CommandKind::SetMinimized { minimized: false }
    ));
    assert!(
        command
            .trace_id
            .as_deref()
            .is_some_and(|trace| trace.starts_with("fermin:resume-history:"))
    );

    stop_bridge(cancellation, bridge).await;
    relay.stop().await;
}

#[tokio::test]
async fn relay_query_engine_round_trips_json_through_the_bridge() {
    let relay = RelayHarness::start().await;
    let source = Arc::new(FakeBridgeSource::new("engine-query-success"));
    let (cancellation, bridge) = start_bridge(source.clone(), &relay);
    wait_for_engine_state(&relay.state, true).await;

    let params = json!({
        "path": "/tmp/example.md",
        "options": {"includeMetadata": true},
    });
    let result = relay
        .state
        .query_engine("test.echo", params.clone())
        .await
        .expect("read-only engine query succeeds");
    assert_eq!(result, params);
    assert_eq!(
        source
            .queries
            .lock()
            .expect("query lock poisoned")
            .as_slice(),
        &[("test.echo".to_owned(), params)]
    );

    stop_bridge(cancellation, bridge).await;
    relay.stop().await;
}

#[tokio::test]
async fn relay_query_engine_surfaces_sanitized_bridge_errors() {
    let relay = RelayHarness::start().await;
    let source = Arc::new(FakeBridgeSource::new("engine-query-error"));
    let (cancellation, bridge) = start_bridge(source, &relay);
    wait_for_engine_state(&relay.state, true).await;

    let error = relay
        .state
        .query_engine("test.failure", Value::Null)
        .await
        .expect_err("bridge query failure reaches relay caller");
    let message = error.to_string();
    assert!(message.contains("query_failed"));
    assert!(message.contains("engine query failed"));
    assert!(!message.contains("synthetic"));

    stop_bridge(cancellation, bridge).await;
    relay.stop().await;
}

#[tokio::test]
async fn relay_query_engine_fails_pending_request_when_engine_disconnects() {
    let relay = RelayHarness::start().await;
    let (mut socket, _) = connect_engine(&relay, "engine-query-disconnect", 303).await;
    let state = relay.state.clone();
    let query =
        tokio::spawn(async move { state.query_engine("test.echo", json!({"wait": true})).await });

    let request = receive_envelope(&mut socket).await;
    assert!(matches!(
        request.frame,
        RelayFrame::QueryRequest {
            ref method,
            ref params,
            ..
        } if method == "test.echo" && params == &json!({"wait": true})
    ));
    socket.close(None).await.expect("close engine during query");

    let error = timeout(TEST_TIMEOUT, query)
        .await
        .expect("pending query disconnect timeout")
        .expect("pending query task panicked")
        .expect_err("pending query must fail on disconnect");
    assert!(error.to_string().contains("engine_disconnected"));
    wait_for_engine_state(&relay.state, false).await;

    relay.stop().await;
}

#[tokio::test]
async fn relay_query_engine_rejects_invalid_method_and_oversized_params() {
    let relay = RelayHarness::start().await;

    let invalid_method = relay
        .state
        .query_engine("test method", Value::Null)
        .await
        .expect_err("query method with whitespace must be rejected");
    assert!(invalid_method.to_string().contains("invalid read-only"));

    let oversized = relay
        .state
        .query_engine(
            "test.echo",
            json!({"content": "x".repeat(2 * 1024 * 1024 + 1)}),
        )
        .await
        .expect_err("oversized query params must be rejected");
    assert!(oversized.to_string().contains("transport limit"));

    relay.stop().await;
}

#[tokio::test]
async fn bridge_disconnect_aborts_and_drains_in_flight_query_tasks() {
    let relay = RelayHarness::start().await;
    let source = Arc::new(FakeBridgeSource::new("engine-query-task-cleanup"));
    let (cancellation, bridge) = start_bridge(source.clone(), &relay);
    wait_for_engine_state(&relay.state, true).await;

    let state = relay.state.clone();
    let query = tokio::spawn(async move {
        state
            .query_engine("test.pending", json!({"wait": true}))
            .await
    });
    wait_until("in-flight engine query handler", || {
        source.active_queries.load(Ordering::Acquire) == 1
    })
    .await;

    stop_bridge(cancellation, bridge).await;
    assert_eq!(source.active_queries.load(Ordering::Acquire), 0);
    let error = timeout(TEST_TIMEOUT, query)
        .await
        .expect("pending query cleanup timeout")
        .expect("pending query task panicked")
        .expect_err("pending query must fail when bridge disconnects");
    assert!(error.to_string().contains("engine_disconnected"));

    relay.stop().await;
}

fn start_bridge(
    source: Arc<FakeBridgeSource>,
    relay: &RelayHarness,
) -> (CancellationToken, JoinHandle<anyhow::Result<()>>) {
    let cancellation = CancellationToken::new();
    let bridge_cancellation = cancellation.clone();
    let config = relay.bridge_config();
    let bridge =
        tokio::spawn(async move { run_outbound_bridge(source, config, bridge_cancellation).await });
    (cancellation, bridge)
}

async fn stop_bridge(cancellation: CancellationToken, bridge: JoinHandle<anyhow::Result<()>>) {
    cancellation.cancel();
    timeout(TEST_TIMEOUT, bridge)
        .await
        .expect("bridge shutdown timeout")
        .expect("bridge task panicked")
        .expect("bridge returned an error");
}

async fn connect_engine(
    relay: &RelayHarness,
    engine_id: &str,
    connection_epoch: u64,
) -> (ClientSocket, RelayEnvelope) {
    let mut request = format!("{}?engineId={engine_id}", relay.websocket_url())
        .into_client_request()
        .expect("build websocket request");
    request.headers_mut().insert(
        AUTHORIZATION,
        format!("Bearer {ENGINE_TOKEN}")
            .parse()
            .expect("parse authorization header"),
    );
    let (mut socket, response) = connect_async(request)
        .await
        .expect("connect authenticated engine websocket");
    assert_eq!(
        response.status(),
        axum::http::StatusCode::SWITCHING_PROTOCOLS
    );

    let hello = RelayEnvelope {
        protocol_version: PROTOCOL_VERSION,
        engine_id: engine_id.to_owned(),
        connection_epoch,
        sequence: 1,
        acknowledgement: 0,
        resume_cursor: Some(0),
        fence_generation: 0,
        frame: RelayFrame::Hello {
            app_server_version: "fake-app-server/1".to_owned(),
            capability_hash: "fake-capabilities".to_owned(),
            process_epoch: 1,
        },
    };
    send_envelope(&mut socket, &hello).await;
    let ack = receive_envelope(&mut socket).await;
    (socket, ack)
}

async fn send_envelope(socket: &mut ClientSocket, envelope: &RelayEnvelope) {
    socket
        .send(Message::Text(
            serde_json::to_string(envelope)
                .expect("serialize relay envelope")
                .into(),
        ))
        .await
        .expect("send relay envelope");
}

async fn receive_envelope(socket: &mut ClientSocket) -> RelayEnvelope {
    let message = timeout(TEST_TIMEOUT, socket.next())
        .await
        .expect("relay envelope timeout")
        .expect("relay websocket closed")
        .expect("receive relay websocket message");
    let Message::Text(text) = message else {
        panic!("expected relay text envelope, received {message:?}");
    };
    serde_json::from_str(text.as_str()).expect("decode relay envelope")
}

async fn wait_for_socket_close(socket: &mut ClientSocket) {
    let deadline = Instant::now() + TEST_TIMEOUT;
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        assert!(!remaining.is_zero(), "relay did not close stale connection");
        match timeout(remaining, socket.next())
            .await
            .expect("stale connection close timeout")
        {
            None | Some(Ok(Message::Close(_))) | Some(Err(_)) => return,
            Some(Ok(_)) => continue,
        }
    }
}

async fn wait_for_engine_state(state: &RelayState, expected: bool) {
    let deadline = Instant::now() + TEST_TIMEOUT;
    loop {
        let connected = state
            .active_engine_health()
            .await
            .get("connected")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        if connected == expected {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "engine connection state did not become {expected}"
        );
        sleep(Duration::from_millis(20)).await;
    }
}

async fn wait_for_engine_sequence(state: &RelayState, expected: u64) {
    let deadline = Instant::now() + TEST_TIMEOUT;
    loop {
        let sequence = state
            .active_engine_health()
            .await
            .get("lastEngineSequence")
            .and_then(Value::as_u64)
            .unwrap_or(0);
        if sequence >= expected {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "engine sequence did not reach {expected}"
        );
        sleep(Duration::from_millis(20)).await;
    }
}

async fn wait_until(description: &str, mut condition: impl FnMut() -> bool) {
    let deadline = Instant::now() + TEST_TIMEOUT;
    while !condition() {
        assert!(
            Instant::now() < deadline,
            "timed out waiting for {description}"
        );
        sleep(Duration::from_millis(20)).await;
    }
}

async fn wait_until_snapshot_event(relay: &RelayHarness) {
    let deadline = Instant::now() + TEST_TIMEOUT;
    loop {
        let has_snapshot = relay
            .state
            .store()
            .replay_events(EventCursor::default(), 1_000)
            .await
            .expect("replay relay events while waiting for snapshot")
            .iter()
            .any(|event| event.kind == EventKind::Snapshot);
        if has_snapshot {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "timed out waiting for authoritative snapshot event"
        );
        sleep(Duration::from_millis(20)).await;
    }
}

async fn relay_source_cursor(relay: &RelayHarness, engine_id: &str) -> u64 {
    relay
        .state
        .store()
        .get_cursor(format!("source:{engine_id}"))
        .await
        .expect("load relay source cursor")
        .expect("relay source cursor is missing")
        .global_sequence
}

async fn wait_for_command_state(relay: &RelayHarness, command_id: &str, expected: CommandState) {
    let deadline = Instant::now() + TEST_TIMEOUT;
    loop {
        let command = relay
            .state
            .store()
            .get_command(command_id)
            .await
            .expect("load relay command")
            .expect("relay command exists");
        if command.state == expected {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "command {command_id} did not reach {expected:?}; current state is {:?}",
            command.state
        );
        sleep(Duration::from_millis(20)).await;
    }
}

fn fake_event(global_sequence: u64, marker: &str) -> DurableEvent {
    DurableEvent {
        event_id: format!("fake-event-{global_sequence}"),
        global_sequence,
        session_sequence: None,
        session_id: None,
        command_id: None,
        process_epoch: Some(7),
        kind: EventKind::TurnCompleted,
        payload: json!({"marker": marker}),
        created_at: now_ms(),
    }
}

fn fake_command_state_event(
    global_sequence: u64,
    command_id: &str,
    state: CommandState,
) -> DurableEvent {
    fake_command_state_event_at(global_sequence, command_id, state, now_ms())
}

fn fake_command_state_event_at(
    global_sequence: u64,
    command_id: &str,
    state: CommandState,
    created_at: i64,
) -> DurableEvent {
    DurableEvent {
        event_id: format!("command-state-{global_sequence}"),
        global_sequence,
        session_sequence: None,
        session_id: None,
        command_id: Some(command_id.to_owned()),
        process_epoch: Some(7),
        kind: EventKind::CommandStateChanged,
        payload: json!({
            "commandId": command_id,
            "state": state,
            "error": null,
        }),
        created_at,
    }
}

fn fake_runtime_status_event(global_sequence: u64, session: &SessionSummary) -> DurableEvent {
    DurableEvent {
        event_id: format!("runtime-status-{global_sequence}"),
        global_sequence,
        session_sequence: None,
        session_id: Some(session.session_id.clone()),
        command_id: None,
        process_epoch: Some(7),
        kind: EventKind::RuntimeStatus,
        payload: serde_json::to_value(session).expect("serialize runtime session summary"),
        created_at: session.updated_at,
    }
}

fn history_query(query: &str, sort: SessionHistorySort) -> SessionHistoryQuery {
    SessionHistoryQuery {
        query: query.to_owned(),
        project_path: None,
        state: SessionHistoryState::All,
        from: None,
        to: None,
        sort,
        offset: 0,
        limit: 100,
        refresh: false,
    }
}

fn history_ids(page: &SessionHistoryPage) -> Vec<&str> {
    page.items
        .iter()
        .map(|item| item.session_id.as_str())
        .collect()
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock before Unix epoch")
        .as_millis()
        .try_into()
        .expect("timestamp fits i64")
}
