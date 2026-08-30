import json
import os
import signal
import subprocess
import sys
import time


SCENARIO = sys.argv[1]


def write_json(value):
    payload = json.dumps(value, separators=(",", ":")).encode("utf-8") + b"\n"
    sys.stdout.buffer.write(payload)
    sys.stdout.buffer.flush()


def write_split(payload):
    midpoint = max(1, len(payload) // 2)
    sys.stdout.buffer.write(payload[:midpoint])
    sys.stdout.buffer.flush()
    time.sleep(0.01)
    sys.stdout.buffer.write(payload[midpoint:])
    sys.stdout.buffer.flush()


if SCENARIO == "cleanup":
    pid_file = sys.argv[2]
    child_code = """
import os
import signal
import sys
import time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.write(str(os.getpid()))
    handle.flush()
while True:
    time.sleep(1)
"""
    subprocess.Popen([sys.executable, "-c", child_code, pid_file])


handshake_complete = False
for raw_line in sys.stdin.buffer:
    message = json.loads(raw_line)
    method = message.get("method")
    request_id = message.get("id")

    if method == "initialize":
        payload = json.dumps(
            {"id": request_id, "result": {"serverInfo": {"name": "fake"}}},
            separators=(",", ":"),
        ).encode("utf-8") + b"\n"
        write_split(payload)
        continue

    if method == "initialized":
        handshake_complete = True
        continue

    if not handshake_complete:
        if request_id is not None:
            write_json(
                {
                    "id": request_id,
                    "error": {"code": -32002, "message": "initialized notification missing"},
                }
            )
        continue

    if method == "fixture/echo":
        write_json({"id": request_id, "result": message.get("params")})
        continue

    if method == "fixture/framing":
        response = json.dumps(
            {"id": request_id, "result": {"framed": True}}, separators=(",", ":")
        )
        first = json.dumps(
            {"method": "fixture/first", "params": {"order": 1}},
            separators=(",", ":"),
        )
        second = json.dumps(
            {"method": "fixture/second", "params": {"order": 2}},
            separators=(",", ":"),
        )
        write_split((response + "\n" + first + "\n" + second + "\n").encode("utf-8"))
        continue

    if method == "fixture/server-request":
        write_json({"id": request_id, "result": {"sent": True}})
        write_json(
            {
                "id": "permission-1",
                "method": "item/commandExecution/requestApproval",
                "params": {"command": "echo safe"},
            }
        )
        continue

    if request_id == "permission-1" and "result" in message:
        write_json(
            {
                "method": "fixture/server-response",
                "params": {"received": message["result"]},
            }
        )
        continue

    if method == "fixture/overload":
        write_json(
            {
                "id": request_id,
                "error": {
                    "code": -32001,
                    "message": "bounded queue full",
                    "data": {"retryable": True},
                },
            }
        )
        continue

    if method == "fixture/malformed":
        sys.stdout.buffer.write(b'{"id":broken\n')
        sys.stdout.buffer.flush()
        time.sleep(5)
        continue

    if method == "fixture/oversized":
        sys.stdout.buffer.write(
            b'{"method":"fixture/huge","params":"' + (b"x" * 4096) + b'"}\n'
        )
        sys.stdout.buffer.flush()
        time.sleep(5)
        continue

    if method == "fixture/eof":
        os.close(sys.stdout.fileno())
        time.sleep(5)
        continue

    if method == "model/list":
        write_json(
            {
                "id": request_id,
                "result": {
                    "data": [
                        {
                            "id": "gpt-5.6-luna",
                            "supportedReasoningEfforts": [{"reasoningEffort": "high"}],
                        }
                    ]
                },
            }
        )
        continue

    if request_id is not None:
        write_json(
            {
                "id": request_id,
                "error": {"code": -32601, "message": "unknown fake method"},
            }
        )
