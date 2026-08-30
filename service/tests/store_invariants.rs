use std::path::PathBuf;
use std::sync::Arc;

use fermin_code::protocol::{
    AuthoritativeSnapshot, CommandKind, CommandRequest, CommandState, CommandTransition,
    ConsumerCursor, EventCursor, EventKind, LeaseRequest, Message, MessageMutation, MessagePatch,
    ModelCatalog, ModelInfo, NewEvent, NewOutboxEntry, ReasoningEffortOption, RelayFrame, RunMode,
    SessionSummary,
};
use fermin_code::store::{Store, StoreConfig, StoreError};
use serde_json::json;
use tempfile::TempDir;
use tokio::sync::Barrier;
use tokio::task::JoinSet;

fn database_path(directory: &TempDir) -> PathBuf {
    directory.path().join("fermin.sqlite3")
}

fn send_command(key: &str, content: &str, requested_at: i64) -> CommandRequest {
    CommandRequest {
        command_id: None,
        idempotency_key: key.to_owned(),
        session_id: Some("session-a".to_owned()),
        command: CommandKind::SendMessage {
            content: content.to_owned(),
            client_message_id: format!("message-{key}"),
            attachments: Vec::new(),
            service_tier: None,
        },
        requested_at,
        trace_id: Some(format!("trace-{key}")),
    }
}

fn event(event_id: &str, session_id: Option<&str>, ordinal: u64) -> NewEvent {
    NewEvent {
        event_id: Some(event_id.to_owned()),
        session_id: session_id.map(str::to_owned),
        command_id: None,
        process_epoch: Some(7),
        kind: EventKind::ItemUpdated,
        payload: json!({ "ordinal": ordinal }),
        created_at: 1_000 + ordinal as i64,
    }
}

fn luna_model() -> ModelInfo {
    ModelInfo {
        id: "gpt-5.6-luna".to_owned(),
        model: "gpt-5.6-luna".to_owned(),
        model_provider: Some("openai".to_owned()),
        display_name: "GPT-5.6 Luna".to_owned(),
        default_reasoning_effort: "high".to_owned(),
        supported_reasoning_efforts: vec![ReasoningEffortOption {
            reasoning_effort: "high".to_owned(),
            description: Some("Deep reasoning".to_owned()),
        }],
        hidden: false,
        is_default: true,
    }
}

#[test]
fn exact_mobile_and_relay_wire_json_is_camel_case() {
    assert_eq!(
        serde_json::to_value(RunMode::Default).unwrap(),
        json!("normal")
    );
    assert_eq!(
        serde_json::from_value::<RunMode>(json!("normal")).unwrap(),
        RunMode::Default
    );

    let patch = MessagePatch {
        window_id: "session-a".to_owned(),
        message: Message::assistant("assistant-1", "done", 123),
        revision: 4,
        updated_at: 124,
        final_: true,
    };
    assert_eq!(
        serde_json::to_value(patch).unwrap(),
        json!({
            "windowId": "session-a",
            "message": {
                "id": "assistant-1",
                "role": "assistant",
                "content": "done",
                "timestamp": 123
            },
            "revision": 4,
            "updatedAt": 124,
            "final": true
        })
    );

    let command = CommandKind::SendMessage {
        content: "ship it".to_owned(),
        client_message_id: "client-1".to_owned(),
        attachments: Vec::new(),
        service_tier: None,
    };
    assert_eq!(
        serde_json::to_value(command).unwrap(),
        json!({
            "type": "sendMessage",
            "data": {
                "content": "ship it",
                "clientMessageId": "client-1"
            }
        })
    );

    assert_eq!(
        serde_json::to_value(RelayFrame::Hello {
            app_server_version: "0.147.0".to_owned(),
            capability_hash: "abc".to_owned(),
            process_epoch: 8,
        })
        .unwrap(),
        json!({
            "type": "hello",
            "data": {
                "appServerVersion": "0.147.0",
                "capabilityHash": "abc",
                "processEpoch": 8
            }
        })
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn command_acceptance_is_idempotent_and_detects_key_reuse() {
    let directory = TempDir::new().unwrap();
    let store = Store::open(database_path(&directory)).await.unwrap();
    assert!(store.metadata().sqlite_version.as_str() >= "3.51.3");
    assert_eq!(store.metadata().journal_mode.to_ascii_lowercase(), "wal");
    assert_eq!(store.metadata().synchronous, "FULL");

    let first = store
        .accept_command(send_command("same-key", "first payload", 10))
        .await
        .unwrap();
    let duplicate = store
        .accept_command(send_command("same-key", "first payload", 20))
        .await
        .unwrap();
    assert!(first.inserted);
    assert!(!duplicate.inserted);
    assert_eq!(duplicate.command.command_id, first.command.command_id);
    assert_eq!(duplicate.command.requested_at, 10);

    let mut preference_retry = send_command("same-key", "first payload", 25);
    preference_retry.trace_id = Some(
        "fermin-prompt-variant:{\"variant\":\"motivational\",\"upstreamTraceId\":\"trace-same-key\"}"
            .to_owned(),
    );
    let preference_retry = store.accept_command(preference_retry).await.unwrap();
    assert!(!preference_retry.inserted);
    assert_eq!(
        preference_retry.command.command_id,
        first.command.command_id
    );

    let conflict = store
        .accept_command(send_command("same-key", "different payload", 30))
        .await
        .unwrap_err();
    assert!(matches!(
        conflict,
        StoreError::IdempotencyConflict { key } if key == "same-key"
    ));
    let mut different_routing = send_command("same-key", "first payload", 40);
    different_routing.trace_id = Some("different-routing".to_owned());
    let trace_conflict = store.accept_command(different_routing).await.unwrap_err();
    assert!(matches!(
        trace_conflict,
        StoreError::IdempotencyConflict { key } if key == "same-key"
    ));
    assert_eq!(store.pending_commands(10).await.unwrap().len(), 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn concurrent_events_have_gap_free_global_and_session_replay_after_restart() {
    let directory = TempDir::new().unwrap();
    let path = database_path(&directory).to_path_buf();
    let store = Store::open(&path).await.unwrap();
    let mut tasks = JoinSet::new();
    for ordinal in 0..96_u64 {
        let store = store.clone();
        tasks.spawn(async move {
            store
                .append_event(
                    event(&format!("event-{ordinal}"), Some("session-a"), ordinal),
                    None,
                )
                .await
                .unwrap()
        });
    }
    while tasks.join_next().await.is_some() {}

    let replay = store
        .replay_events(
            EventCursor {
                after_global_sequence: 0,
            },
            200,
        )
        .await
        .unwrap();
    assert_eq!(replay.len(), 96);
    assert_eq!(
        replay
            .iter()
            .map(|event| event.global_sequence)
            .collect::<Vec<_>>(),
        (1..=96).collect::<Vec<_>>()
    );
    assert_eq!(
        replay
            .iter()
            .map(|event| event.session_sequence.unwrap())
            .collect::<Vec<_>>(),
        (1..=96).collect::<Vec<_>>()
    );
    assert_eq!(
        store
            .replay_events(
                EventCursor {
                    after_global_sequence: 90,
                },
                100,
            )
            .await
            .unwrap()
            .len(),
        6
    );
    store.checkpoint().await.unwrap();
    drop(store);
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;

    let reopened = Store::open(&path).await.unwrap();
    let session_replay = reopened
        .replay_session_events("session-a", 0, 200)
        .await
        .unwrap();
    assert_eq!(session_replay.len(), 96);
    assert_eq!(session_replay.last().unwrap().global_sequence, 96);
}

#[tokio::test]
async fn command_state_and_event_are_one_transaction_on_conflict() {
    let directory = TempDir::new().unwrap();
    let store = Store::open(database_path(&directory)).await.unwrap();
    let first_event = store
        .append_event(event("fixed-event", Some("session-a"), 1), None)
        .await
        .unwrap();
    assert_eq!(first_event.global_sequence, 1);
    let command = store
        .accept_command(send_command("atomic", "payload", 10))
        .await
        .unwrap()
        .command;

    let failed = store
        .transition_command(
            CommandTransition {
                command_id: command.command_id.clone(),
                expected_state: Some(CommandState::Accepted),
                new_state: CommandState::Leased,
                updated_at: 20,
                error: None,
                event: Some(event("fixed-event", Some("session-a"), 999)),
            },
            None,
        )
        .await
        .unwrap_err();
    assert!(matches!(failed, StoreError::EventConflict { .. }));
    assert_eq!(
        store
            .get_command(&command.command_id)
            .await
            .unwrap()
            .unwrap()
            .state,
        CommandState::Accepted
    );

    let succeeded = store
        .transition_command(
            CommandTransition {
                command_id: command.command_id.clone(),
                expected_state: Some(CommandState::Accepted),
                new_state: CommandState::Leased,
                updated_at: 21,
                error: None,
                event: Some(event("leased-event", Some("session-a"), 2)),
            },
            None,
        )
        .await
        .unwrap();
    assert_eq!(succeeded.command.state, CommandState::Leased);
    assert_eq!(succeeded.event.unwrap().global_sequence, 2);
    assert_eq!(
        store
            .replay_events(
                EventCursor {
                    after_global_sequence: 0,
                },
                10,
            )
            .await
            .unwrap()
            .iter()
            .map(|event| event.global_sequence)
            .collect::<Vec<_>>(),
        vec![1, 2]
    );
}

#[tokio::test]
async fn session_and_message_updates_are_atomic_with_replay_events() {
    let directory = TempDir::new().unwrap();
    let store = Store::open(database_path(&directory)).await.unwrap();
    store
        .append_event(event("fixed-event", Some("session-a"), 1), None)
        .await
        .unwrap();

    let original = SessionSummary::new("session-a", "fermin", "Original", 10);
    store.upsert_session(original.clone(), None).await.unwrap();
    let mut renamed = original.clone();
    renamed.display_name = "Renamed".to_owned();
    renamed.updated_at = 20;
    let session_conflict = store
        .upsert_session_with_event(renamed.clone(), event("fixed-event", None, 999), None)
        .await
        .unwrap_err();
    assert!(matches!(session_conflict, StoreError::EventConflict { .. }));
    let after_conflict = store.get_session("session-a").await.unwrap().unwrap();
    assert_eq!(after_conflict.revision, 1);
    assert_eq!(after_conflict.session.display_name, "Original");

    let mut message_only_difference = original.clone();
    message_only_difference.messages = vec![Message::assistant("ignored", "body", 21)];
    let unchanged = store
        .upsert_session_with_event(
            message_only_difference,
            event("must-not-append", None, 2),
            None,
        )
        .await
        .unwrap();
    assert_eq!(unchanged.stored.revision, 1);
    assert!(unchanged.event.is_none());

    let renamed = store
        .upsert_session_with_event(renamed, event("session-renamed", None, 3), None)
        .await
        .unwrap();
    assert_eq!(renamed.stored.revision, 2);
    assert_eq!(
        renamed.event.unwrap().session_id.as_deref(),
        Some("session-a")
    );

    store
        .upsert_message(
            MessageMutation {
                session_id: "session-a".to_owned(),
                message: Message::assistant("assistant-1", "complete", 30),
                revision: 2,
                updated_at: 30,
                final_: true,
            },
            None,
        )
        .await
        .unwrap();
    let stale = store
        .upsert_message_with_event(
            MessageMutation {
                session_id: "session-a".to_owned(),
                message: Message::assistant("assistant-1", "prefix", 29),
                revision: 1,
                updated_at: 29,
                final_: false,
            },
            event("stale-message-event", None, 4),
            None,
        )
        .await
        .unwrap();
    assert!(!stale.stored.applied);
    assert!(stale.event.is_none());

    let message_conflict = store
        .upsert_message_with_event(
            MessageMutation {
                session_id: "session-a".to_owned(),
                message: Message::assistant("assistant-1", "replacement", 40),
                revision: 3,
                updated_at: 40,
                final_: true,
            },
            event("fixed-event", None, 5),
            None,
        )
        .await
        .unwrap_err();
    assert!(matches!(message_conflict, StoreError::EventConflict { .. }));
    let messages = store.list_messages("session-a").await.unwrap();
    assert_eq!(messages[0].revision, 2);
    assert_eq!(messages[0].message.content, "complete");

    let applied = store
        .upsert_message_with_event(
            MessageMutation {
                session_id: "session-a".to_owned(),
                message: Message::assistant("assistant-1", "replacement", 40),
                revision: 3,
                updated_at: 40,
                final_: true,
            },
            event("message-replaced", None, 6),
            None,
        )
        .await
        .unwrap();
    assert!(applied.stored.applied);
    assert_eq!(
        applied.event.unwrap().session_id.as_deref(),
        Some("session-a")
    );

    let replay = store
        .replay_events(EventCursor::default(), 20)
        .await
        .unwrap();
    assert_eq!(
        replay
            .iter()
            .map(|event| event.event_id.as_str())
            .collect::<Vec<_>>(),
        vec!["fixed-event", "session-renamed", "message-replaced"]
    );
}

#[tokio::test]
async fn late_message_updates_preserve_original_transcript_order() {
    let directory = TempDir::new().unwrap();
    let store = Store::open(database_path(&directory)).await.unwrap();
    store
        .upsert_session(
            SessionSummary::new("ordered-session", "fermin", "Ordered", 10),
            None,
        )
        .await
        .unwrap();

    let older = Message::user("older-message", "original prompt", 100);
    store
        .upsert_message(
            MessageMutation {
                session_id: "ordered-session".to_owned(),
                message: older.clone(),
                revision: 1,
                updated_at: 100,
                final_: true,
            },
            None,
        )
        .await
        .unwrap();
    store
        .upsert_message(
            MessageMutation {
                session_id: "ordered-session".to_owned(),
                message: Message::assistant("newer-message", "current reply", 200),
                revision: 1,
                updated_at: 200,
                final_: true,
            },
            None,
        )
        .await
        .unwrap();

    let mut improved = older;
    improved.improved_prompt = Some("improved original prompt".to_owned());
    improved.transform_status = Some("done".to_owned());
    store
        .upsert_message(
            MessageMutation {
                session_id: "ordered-session".to_owned(),
                message: improved,
                revision: 2,
                updated_at: 300,
                final_: true,
            },
            None,
        )
        .await
        .unwrap();

    let messages = store.list_messages("ordered-session").await.unwrap();
    assert_eq!(
        messages
            .iter()
            .map(|stored| stored.message.id.as_str())
            .collect::<Vec<_>>(),
        vec!["older-message", "newer-message"]
    );
    assert_eq!(
        messages[0].message.improved_prompt.as_deref(),
        Some("improved original prompt")
    );
    assert_eq!(messages[0].updated_at, 300);
}

#[tokio::test]
async fn a_new_lease_generation_fences_every_stale_writer() {
    let directory = TempDir::new().unwrap();
    let store = Store::open(database_path(&directory)).await.unwrap();
    let first = store
        .acquire_lease(LeaseRequest {
            lease_key: "engine:personal-mac".to_owned(),
            holder_id: "personal-mac".to_owned(),
            now: 1_000,
            ttl_millis: 60_000,
            previous_generation: None,
        })
        .await
        .unwrap();
    let second = store
        .acquire_lease(LeaseRequest {
            lease_key: "engine:personal-mac".to_owned(),
            holder_id: "personal-mac".to_owned(),
            now: 1_001,
            ttl_millis: 60_000,
            previous_generation: None,
        })
        .await
        .unwrap();
    assert_eq!(first.generation, 1);
    assert_eq!(second.generation, 2);

    let stale = store
        .append_event(
            event("stale", Some("session-a"), 1),
            Some(first.fencing_token(1_002)),
        )
        .await
        .unwrap_err();
    assert!(matches!(
        stale,
        StoreError::StaleFence { generation: 1, .. }
    ));
    let stale_session = store
        .upsert_session(
            SessionSummary::new("stale-session", "fermin", "stale", 1_002),
            Some(first.fencing_token(1_002)),
        )
        .await
        .unwrap_err();
    assert!(matches!(
        stale_session,
        StoreError::StaleFence { generation: 1, .. }
    ));
    assert!(store.get_session("stale-session").await.unwrap().is_none());
    let stale_command = store
        .accept_command_fenced(
            send_command("stale-command", "must not be accepted", 1_002),
            Some(first.fencing_token(1_002)),
        )
        .await
        .unwrap_err();
    assert!(matches!(
        stale_command,
        StoreError::StaleFence { generation: 1, .. }
    ));
    assert!(store.pending_commands(10).await.unwrap().is_empty());

    let fresh_command = store
        .accept_command_fenced(
            send_command("fresh-command", "accepted", 1_002),
            Some(second.fencing_token(1_002)),
        )
        .await
        .unwrap();
    assert_eq!(fresh_command.command.lease_generation, Some(2));

    let fresh = store
        .append_event(
            event("fresh", Some("session-a"), 2),
            Some(second.fencing_token(1_002)),
        )
        .await
        .unwrap();
    assert_eq!(fresh.global_sequence, 1);

    let held = store
        .acquire_lease(LeaseRequest {
            lease_key: "engine:personal-mac".to_owned(),
            holder_id: "impostor".to_owned(),
            now: 1_003,
            ttl_millis: 60_000,
            previous_generation: None,
        })
        .await
        .unwrap_err();
    assert!(matches!(held, StoreError::LeaseHeld { .. }));
}

#[tokio::test]
async fn sessions_messages_models_snapshots_cursors_and_outbox_are_durable() {
    let directory = TempDir::new().unwrap();
    let store = Store::open(database_path(&directory)).await.unwrap();
    let mut session = SessionSummary::new("session-a", "fermin", "Fermín", 100);
    session.model = Some("gpt-5.6-luna".to_owned());
    session.reasoning_effort = Some("high".to_owned());
    let stored = store.upsert_session(session.clone(), None).await.unwrap();
    assert_eq!(stored.revision, 1);
    assert_eq!(
        store
            .upsert_session(session.clone(), None)
            .await
            .unwrap()
            .revision,
        1
    );
    session.display_name = "Fermín renamed".to_owned();
    session.updated_at = 101;
    assert_eq!(
        store.upsert_session(session, None).await.unwrap().revision,
        2
    );

    let latest_message = MessageMutation {
        session_id: "session-a".to_owned(),
        message: Message::assistant("assistant-1", "complete response", 120),
        revision: 2,
        updated_at: 120,
        final_: true,
    };
    assert!(
        store
            .upsert_message(latest_message, None)
            .await
            .unwrap()
            .applied
    );
    let stale_message = MessageMutation {
        session_id: "session-a".to_owned(),
        message: Message::assistant("assistant-1", "prefix", 110),
        revision: 1,
        updated_at: 110,
        final_: false,
    };
    let rejected = store.upsert_message(stale_message, None).await.unwrap();
    assert!(!rejected.applied);
    assert_eq!(rejected.message.content, "complete response");

    let mut unsupported = luna_model();
    unsupported.id = "unsupported-4".to_owned();
    unsupported.model = "unsupported-4".to_owned();
    unsupported.model_provider = Some("unsupported".to_owned());
    let catalog = store
        .replace_models(
            ModelCatalog {
                observed_at: 130,
                app_server_version: Some("0.147.0".to_owned()),
                capability_hash: Some("capability".to_owned()),
                models: vec![unsupported, luna_model()],
            },
            None,
        )
        .await
        .unwrap();
    assert_eq!(catalog.models.len(), 1);
    assert_eq!(catalog.models[0].model, "gpt-5.6-luna");

    let snapshot = AuthoritativeSnapshot {
        schema_version: 1,
        global_sequence: 0,
        generated_at: 140,
        sessions: store
            .list_sessions()
            .await
            .unwrap()
            .into_iter()
            .map(|item| item.session)
            .collect(),
        models: catalog.models,
    };
    assert_eq!(
        store
            .put_snapshot("mobile", snapshot, None)
            .await
            .unwrap()
            .version,
        1
    );
    assert_eq!(
        store
            .get_snapshot("mobile")
            .await
            .unwrap()
            .unwrap()
            .snapshot
            .sessions[0]
            .display_name,
        "Fermín renamed"
    );

    let forward = store
        .commit_cursor(ConsumerCursor {
            consumer_id: "iphone".to_owned(),
            global_sequence: 9,
            updated_at: 150,
        })
        .await
        .unwrap();
    let backward = store
        .commit_cursor(ConsumerCursor {
            consumer_id: "iphone".to_owned(),
            global_sequence: 3,
            updated_at: 151,
        })
        .await
        .unwrap();
    assert_eq!(forward.global_sequence, 9);
    assert_eq!(backward.global_sequence, 9);

    for ordinal in 0..3 {
        let entry = store
            .enqueue_outbox(
                NewOutboxEntry {
                    peer_id: "puky".to_owned(),
                    frame: RelayFrame::Ping {
                        sent_at: 200 + ordinal,
                    },
                    created_at: 200 + ordinal,
                },
                None,
            )
            .await
            .unwrap();
        assert_eq!(entry.sequence, ordinal as u64 + 1);
    }
    assert_eq!(store.replay_outbox("puky", 0, 10).await.unwrap().len(), 3);
    assert_eq!(store.ack_outbox("puky", 2, None).await.unwrap(), 2);
    let remaining = store.replay_outbox("puky", 0, 10).await.unwrap();
    assert_eq!(remaining.len(), 1);
    assert_eq!(remaining[0].sequence, 3);
}

#[tokio::test]
async fn state_snapshot_pairs_session_state_with_its_durable_event_cursor() {
    let directory = TempDir::new().unwrap();
    let store = Store::open(database_path(&directory)).await.unwrap();

    for ordinal in 1..=32_u64 {
        let session_id = format!("snapshot-race-{ordinal}");
        let barrier = Arc::new(Barrier::new(3));
        let mutation_store = store.clone();
        let mutation_barrier = barrier.clone();
        let mutation_session_id = session_id.clone();
        let mutation = tokio::spawn(async move {
            mutation_barrier.wait().await;
            let session = SessionSummary::new(
                mutation_session_id.clone(),
                "fermin",
                format!("Race {ordinal}"),
                ordinal as i64,
            );
            mutation_store
                .upsert_session_with_event(
                    session.clone(),
                    NewEvent {
                        event_id: Some(format!("snapshot-race-event-{ordinal}")),
                        session_id: Some(mutation_session_id),
                        command_id: None,
                        process_epoch: Some(7),
                        kind: EventKind::SessionUpserted,
                        payload: serde_json::to_value(session).unwrap(),
                        created_at: ordinal as i64,
                    },
                    None,
                )
                .await
                .unwrap()
        });
        let snapshot_store = store.clone();
        let snapshot_barrier = barrier.clone();
        let snapshot = tokio::spawn(async move {
            snapshot_barrier.wait().await;
            snapshot_store.state_snapshot(false, None).await.unwrap()
        });
        barrier.wait().await;
        let mutation = mutation.await.unwrap();
        let snapshot = snapshot.await.unwrap();
        let event = mutation.event.unwrap();
        let contains_session = snapshot
            .sessions
            .iter()
            .any(|stored| stored.session.session_id == session_id);
        assert_eq!(
            contains_session,
            snapshot.global_sequence >= event.global_sequence,
            "snapshot state and cursor diverged at iteration {ordinal}"
        );
    }
}

#[tokio::test]
async fn lightweight_state_snapshot_never_hydrates_transcripts() {
    let directory = TempDir::new().unwrap();
    let store = Store::open(database_path(&directory)).await.unwrap();
    let mut session = SessionSummary::new("session-light", "fermin", "Lightweight", 10);
    session.messages = vec![Message::assistant("embedded", "must not persist", 10)];
    store.upsert_session(session, None).await.unwrap();
    store
        .upsert_message(
            MessageMutation {
                session_id: "session-light".to_owned(),
                message: Message::assistant("durable", "full transcript", 11),
                revision: 1,
                updated_at: 11,
                final_: true,
            },
            None,
        )
        .await
        .unwrap();

    let lightweight = store.state_snapshot(false, None).await.unwrap();
    assert!(lightweight.sessions[0].session.messages.is_empty());
    let full = store.state_snapshot(true, None).await.unwrap();
    assert_eq!(full.sessions[0].session.messages.len(), 1);
    assert_eq!(full.sessions[0].session.messages[0].id, "durable");
}

#[tokio::test]
async fn oversized_requests_are_rejected_before_entering_the_actor() {
    let directory = TempDir::new().unwrap();
    let mut config = StoreConfig::new(database_path(&directory));
    config.queue_byte_capacity = 512;
    config.max_request_bytes = 256;
    let store = Store::open_with_config(config).await.unwrap();
    let error = store
        .accept_command(send_command("oversized", &"x".repeat(1_024), 10))
        .await
        .unwrap_err();
    assert!(matches!(error, StoreError::RequestTooLarge { .. }));
}
