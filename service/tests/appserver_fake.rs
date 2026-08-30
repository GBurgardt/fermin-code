use std::path::{Path, PathBuf};
use std::time::Duration;

use fermin_code::appserver::{AppServerClient, AppServerConfig, AppServerError, AppServerEvent};
use nix::sys::signal::kill;
use nix::unistd::Pid;
use serde_json::{Value, json};
use tempfile::TempDir;
use tokio::sync::broadcast;
use tokio::time;

const FIXTURE_TIMEOUT: Duration = Duration::from_secs(10);

fn fixture_config(scenario: &str) -> AppServerConfig {
    let fixture =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/fake_app_server.py");
    let mut config = AppServerConfig::new("python3")
        .arg(fixture.into_os_string())
        .arg(scenario);
    config.request_timeout = FIXTURE_TIMEOUT;
    config.initialize_timeout = FIXTURE_TIMEOUT;
    config.shutdown_timeout = Duration::from_millis(150);
    config.max_line_bytes = 1024;
    config.writer_capacity = 4;
    config.event_capacity = 16;
    config
}

async fn recv_matching(
    receiver: &mut broadcast::Receiver<AppServerEvent>,
    predicate: impl Fn(&AppServerEvent) -> bool,
) -> AppServerEvent {
    time::timeout(FIXTURE_TIMEOUT, async {
        loop {
            match receiver.recv().await {
                Ok(event) if predicate(&event) => return event,
                Ok(_) | Err(broadcast::error::RecvError::Lagged(_)) => continue,
                Err(broadcast::error::RecvError::Closed) => panic!("event stream closed"),
            }
        }
    })
    .await
    .expect("matching event timed out")
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn handles_split_reads_multiple_lines_and_arbitrary_json() {
    let client = AppServerClient::spawn(fixture_config("framing"))
        .await
        .unwrap();
    let echoed = json!({
        "nested": [true, null, 17, {"unicode": "Fermín"}],
        "largeInteger": 9_007_199_254_740_991_i64
    });
    assert_eq!(
        client
            .request("fixture/echo", echoed.clone())
            .await
            .unwrap(),
        echoed
    );

    let mut events = client.subscribe();
    assert_eq!(
        client
            .request("fixture/framing", Value::Null)
            .await
            .unwrap(),
        json!({"framed": true})
    );
    let first = recv_matching(&mut events, |event| {
        matches!(event, AppServerEvent::Notification { method, .. } if method == "fixture/first")
    })
    .await;
    let second = recv_matching(&mut events, |event| {
        matches!(event, AppServerEvent::Notification { method, .. } if method == "fixture/second")
    })
    .await;
    assert!(first.epoch() > 0);
    assert_eq!(first.epoch(), second.epoch());
    client.shutdown().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn broadcasts_server_requests_and_writes_correlated_responses() {
    let client = AppServerClient::spawn(fixture_config("server-request"))
        .await
        .unwrap();
    let mut events = client.subscribe();
    client
        .request("fixture/server-request", json!({}))
        .await
        .unwrap();
    let request = recv_matching(&mut events, |event| {
        matches!(event, AppServerEvent::ServerRequest { method, .. } if method == "item/commandExecution/requestApproval")
    })
    .await;
    let AppServerEvent::ServerRequest { id, params, .. } = request else {
        unreachable!();
    };
    assert_eq!(id, json!("permission-1"));
    assert_eq!(params, json!({"command": "echo safe"}));
    client
        .respond(id, json!({"decision": "accept"}))
        .await
        .unwrap();
    let acknowledgement = recv_matching(&mut events, |event| {
        matches!(event, AppServerEvent::Notification { method, .. } if method == "fixture/server-response")
    })
    .await;
    let AppServerEvent::Notification { params, .. } = acknowledgement else {
        unreachable!();
    };
    assert_eq!(params, json!({"received": {"decision": "accept"}}));
    client.shutdown().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn types_retryable_app_server_overload() {
    let client = AppServerClient::spawn(fixture_config("overload"))
        .await
        .unwrap();
    let error = client
        .request("fixture/overload", Value::Null)
        .await
        .unwrap_err();
    assert!(error.is_overloaded());
    assert!(matches!(
        error,
        AppServerError::Overloaded { data: Some(data), .. }
            if data == json!({"retryable": true})
    ));
    client.shutdown().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn rejects_malformed_jsonl_and_fails_pending_request() {
    let client = AppServerClient::spawn(fixture_config("malformed"))
        .await
        .unwrap();
    let error = client
        .request("fixture/malformed", Value::Null)
        .await
        .unwrap_err();
    assert!(matches!(error, AppServerError::MalformedLine { .. }));
    assert!(!client.is_running());
    assert!(client.shutdown().await.is_err());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn rejects_lines_over_the_strict_limit() {
    let mut config = fixture_config("oversized");
    // Keep the artificial ceiling above the valid initialize handshake, which
    // includes the notification opt-out list, while remaining far below the
    // fixture's deliberately oversized 4 KiB response.
    config.max_line_bytes = 512;
    let client = AppServerClient::spawn(config).await.unwrap();
    let error = client
        .request("fixture/oversized", Value::Null)
        .await
        .unwrap_err();
    assert!(matches!(
        error,
        AppServerError::LineTooLong { max: 512, .. }
    ));
    assert!(client.shutdown().await.is_err());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn treats_stdout_eof_as_terminal_and_unblocks_requests() {
    let client = AppServerClient::spawn(fixture_config("eof")).await.unwrap();
    let error = client
        .request("fixture/eof", Value::Null)
        .await
        .unwrap_err();
    assert!(matches!(
        error,
        AppServerError::Eof { .. } | AppServerError::ProcessExited { .. }
    ));
    assert!(client.shutdown().await.is_err());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn probes_models_without_starting_a_real_turn() {
    let client = AppServerClient::spawn(fixture_config("models"))
        .await
        .unwrap();
    let probe = client.probe_models().await.unwrap();
    assert_eq!(probe.epoch, client.epoch());
    assert_eq!(probe.models.len(), 1);
    assert_eq!(probe.models[0]["id"], "gpt-5.6-luna");
    client.shutdown().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn shutdown_kills_the_entire_process_group_and_awaits_tasks() {
    let temp_dir = TempDir::new().unwrap();
    let pid_file = temp_dir.path().join("grandchild.pid");
    let config = fixture_config("cleanup").arg(pid_file.clone().into_os_string());
    let client = AppServerClient::spawn(config).await.unwrap();
    let descendant_pid = wait_for_pid(&pid_file).await;
    assert!(process_exists(descendant_pid));

    client.shutdown().await.unwrap();

    let deadline = time::Instant::now() + Duration::from_secs(3);
    while process_exists(descendant_pid) && time::Instant::now() < deadline {
        time::sleep(Duration::from_millis(25)).await;
    }
    assert!(
        !process_exists(descendant_pid),
        "descendant process {descendant_pid} survived shutdown"
    );
}

async fn wait_for_pid(path: &Path) -> i32 {
    time::timeout(FIXTURE_TIMEOUT, async {
        loop {
            if let Ok(raw) = tokio::fs::read_to_string(path).await
                && let Ok(pid) = raw.parse()
            {
                return pid;
            }
            time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("fixture descendant did not write its pid")
}

fn process_exists(pid: i32) -> bool {
    kill(Pid::from_raw(pid), None).is_ok()
}
