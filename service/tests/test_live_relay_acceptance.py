from __future__ import annotations

import importlib.util
import json
import os
import pathlib
import sys
import tempfile
import threading
import unittest
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


SCRIPT_PATH = pathlib.Path(__file__).parents[1] / "scripts" / "live-relay-acceptance.py"
SPEC = importlib.util.spec_from_file_location("live_relay_acceptance", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
HARNESS = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = HARNESS
SPEC.loader.exec_module(HARNESS)


class SseParsingTests(unittest.TestCase):
    def test_parser_handles_comments_multiline_data_and_final_event(self) -> None:
        events = list(
            HARNESS.iter_sse_events(
                [
                    b": heartbeat\n",
                    b"id: 8\n",
                    b"event: sample\n",
                    b"data: first\n",
                    b"data: second\n",
                    b"\n",
                    b"event: tail\n",
                    b"data: {}\n",
                ]
            )
        )
        self.assertEqual(len(events), 2)
        self.assertEqual(events[0].event_id, "8")
        self.assertEqual(events[0].event, "sample")
        self.assertEqual(events[0].data, "first\nsecond")
        self.assertEqual(events[1].event, "tail")

    def test_ledger_correlates_without_retaining_model_output(self) -> None:
        secret_output = "PRIVATE-MODEL-OUTPUT-CANARY"
        ledger = HARNESS.EventLedger()
        ledger.observe(
            HARNESS.SseEvent(
                event="command_state_changed",
                event_id="10",
                data=json.dumps({"commandId": "command-1", "state": "completed"}),
            )
        )
        ledger.observe(
            HARNESS.SseEvent(
                event="message_patch",
                event_id="11",
                data=json.dumps(
                    {
                        "windowId": "window-1",
                        "message": {
                            "id": "message-1",
                            "role": "assistant",
                            "content": secret_output,
                        },
                        "revision": 1,
                        "final": True,
                    }
                ),
            )
        )
        self.assertEqual(ledger.wait_commands(["command-1"], 0.1, "test"), {"command-1": "completed"})
        self.assertEqual(ledger.response_count("window-1"), 1)
        redacted = json.dumps(ledger.redacted_snapshot())
        self.assertNotIn(secret_output, redacted)
        self.assertNotIn(secret_output, repr(vars(ledger)))


class ConfigurationTests(unittest.TestCase):
    def test_base_url_rejects_userinfo_query_and_fragment(self) -> None:
        invalid = (
            "https://token@example.test/fermin-code",
            "https://example.test/fermin-code?token=secret",
            "https://example.test/fermin-code#secret",
        )
        for value in invalid:
            with self.subTest(value=value):
                with self.assertRaises(HARNESS.AcceptanceFailure):
                    HARNESS.normalize_base_url(value)
        self.assertEqual(
            HARNESS.normalize_base_url("https://example.test/fermin-code/"),
            "https://example.test/fermin-code",
        )

    def test_phases_are_explicit_and_canonical(self) -> None:
        self.assertEqual(
            HARNESS.parse_phases("goal,smoke,reconnect"),
            ("smoke", "reconnect", "goal"),
        )
        with self.assertRaises(HARNESS.AcceptanceFailure):
            HARNESS.parse_phases("goal")
        with self.assertRaises(HARNESS.AcceptanceFailure):
            HARNESS.parse_phases("smoke,unknown")

    def test_token_file_requires_private_regular_file(self) -> None:
        token = "t" * 48
        with tempfile.TemporaryDirectory() as directory:
            token_path = pathlib.Path(directory) / "relay.token"
            token_path.write_text(token, encoding="utf-8")
            os.chmod(token_path, 0o600)
            self.assertEqual(HARNESS.read_token_file(token_path), token)
            os.chmod(token_path, 0o644)
            with self.assertRaises(HARNESS.AcceptanceFailure) as raised:
                HARNESS.read_token_file(token_path)
            self.assertEqual(raised.exception.code, "TOKEN_FILE_PERMISSIONS")


class FakeSseHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    token = "fake-token-0123456789-0123456789-abcdef"
    observations: list[tuple[str | None, int | None, str | None]] = []
    lock = threading.Lock()

    def do_GET(self) -> None:
        if self.headers.get("Authorization") != f"Bearer {self.token}":
            self.send_response(401)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        parsed = urllib.parse.urlsplit(self.path)
        if parsed.path != "/fermin-code/api/mobile/stream":
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        query = urllib.parse.parse_qs(parsed.query)
        after_values = query.get("afterGlobalSequence", [])
        after_sequence = int(after_values[0]) if after_values else None
        with self.lock:
            self.observations.append(
                (
                    self.headers.get("Last-Event-ID"),
                    after_sequence,
                    self.headers.get("User-Agent"),
                )
            )
        body = (
            'event: snapshot\n'
            'data: {"ok":true,"items":[],"cursor":7}\n\n'
            'id: 8\n'
            'event: command_state_changed\n'
            'data: {"commandId":"command-1","state":"completed"}\n\n'
            'id: 9\n'
            'event: message_patch\n'
            'data: {"windowId":"window-1","message":{"id":"assistant-1","role":"assistant","content":"PRIVATE-FAKE-OUTPUT"},"revision":1,"final":true}\n\n'
        ).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()

    def log_message(self, format: str, *args: object) -> None:
        del format, args


class FakeSseIntegrationTests(unittest.TestCase):
    def setUp(self) -> None:
        FakeSseHandler.observations = []
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), FakeSseHandler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2.0)

    def test_monitor_sends_resume_cursor_and_correlates_fake_stream(self) -> None:
        host, port = self.server.server_address
        client = HARNESS.ApiClient(
            f"http://{host}:{port}/fermin-code",
            FakeSseHandler.token,
            2.0,
        )
        monitor = HARNESS.SseMonitor(client, after_sequence=7, reconnect_delay_seconds=1.0)
        monitor.start()
        try:
            monitor.ledger.wait_connected(2.0)
            states = monitor.ledger.wait_commands(["command-1"], 2.0, "test")
            monitor.ledger.wait_responses({"window-1": 0}, 2.0, "test")
        finally:
            monitor.stop()
        self.assertEqual(states["command-1"], "completed")
        self.assertTrue(
            any(
                last_event_id == "7"
                and after_sequence == 7
                and user_agent is not None
                and user_agent.startswith("Mozilla/5.0")
                for last_event_id, after_sequence, user_agent in FakeSseHandler.observations
            )
        )
        serialized = json.dumps(monitor.ledger.redacted_snapshot())
        self.assertNotIn("PRIVATE-FAKE-OUTPUT", serialized)

    def test_monitor_stop_absorbs_the_http_close_read_race(self) -> None:
        closed = threading.Event()

        class CloseRaceResponse:
            def readline(self, _limit: int) -> bytes:
                closed.wait(2.0)
                raise AttributeError("closed HTTP chunk reader")

            def close(self) -> None:
                closed.set()

        class CloseRaceClient:
            def open_sse(self, _after_sequence: int | None) -> CloseRaceResponse:
                return CloseRaceResponse()

        captured: list[type[BaseException]] = []
        previous_hook = threading.excepthook
        threading.excepthook = lambda args: captured.append(args.exc_type)
        monitor = HARNESS.SseMonitor(CloseRaceClient())
        try:
            monitor.start()
            monitor.ledger.wait_connected(2.0)
            monitor.stop()
        finally:
            threading.excepthook = previous_hook
        self.assertFalse(monitor.is_running)
        self.assertEqual(captured, [])
        self.assertEqual(monitor.ledger.redacted_snapshot()["streamIssueCodes"], ())


if __name__ == "__main__":
    unittest.main()
