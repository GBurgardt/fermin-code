# API

Use this page as a route map. The Rust code in `service/src/api.rs` is the
actual protocol definition. The `v0.1` API is not frozen.

## Authentication

Every `/api/mobile/*` request needs the client token:

```http
Authorization: Bearer <client-token>
```

Protected responses use a private `no-store` cache policy. `/healthz` is
public and returns only bounded readiness data.

The engine uses a different token. Do not reuse the client token for the
engine connection.

## Routes used by Desktop and Mobile

| Request | Result |
|---|---|
| `GET /healthz` | Relay and engine readiness |
| `GET /api/mobile/sessions` | Session summaries managed by Fermín |
| `POST /api/mobile/sessions` | New session |
| `GET /api/mobile/sessions/{id}` | Full session detail |
| `POST /api/mobile/sessions/{id}/message` | Durable user message |
| `POST /api/mobile/sessions/{id}/steer` | New instruction for the active turn |
| `POST /api/mobile/sessions/{id}/interrupt` | Stop current work |
| `POST /api/mobile/sessions/{id}/archive` | Archive without deleting history |
| `DELETE /api/mobile/sessions/{id}/permanent` | Permanent deletion |
| `PUT /api/mobile/sessions/{id}/pinned` | Set the shared pinned state |
| `POST /api/mobile/sessions/{id}/rename` | Rename a session |
| `POST /api/mobile/sessions/{id}/minimize` | Hide a session |
| `POST /api/mobile/sessions/{id}/restore` | Restore a hidden session |
| `GET /api/mobile/sessions/{id}/models` | Models available to that session |
| `POST /api/mobile/sessions/{id}/model-settings` | Change model settings |
| `POST /api/mobile/sessions/{id}/run-mode` | Change run mode |
| `POST /api/mobile/sessions/{id}/features` | Change Fermín feature flags |
| `POST /api/mobile/sessions/{id}/attachments` | Upload a size-limited attachment |
| `GET /api/mobile/commands/{id}` | Current durable command state |
| `GET /api/mobile/projects` | Allowed workspace projects |
| `POST /api/mobile/file-preview` | Size-limited file preview |
| `GET /api/mobile/attachments/content` | Size-limited attachment content |
| `GET /api/mobile/session-history` | Search previous sessions |
| `POST /api/mobile/session-history/resume` | Resume a previous session |
| `GET /api/mobile/session-recovery` | Find a recoverable session |
| `POST /api/mobile/session-recovery/recover` | Recover a selected session |
| `GET /api/mobile/stream` | Live SSE updates |

`service/src/api.rs` also defines narrow routes for subagents, prompt
transformation, and prompt preferences.

## A command response is not the final result

An accepted response means the relay saved the command. It does not mean Codex
finished it.

Typical states are:

```text
accepted → leased → engineDurable → sentToChild → completed
                                               └→ failed/cancelled/unknown
```

When retrying the same user action, send the same idempotency key. A new key
represents a new action.

## Live updates and reconnect

`GET /api/mobile/stream` sends ordered Server-Sent Events. Each event has a
relay sequence ID. A reconnecting client sends either a query cursor or
`Last-Event-ID`.

If the relay no longer has enough history for that cursor, the client must
reload the authoritative snapshot. It must not treat the missing replay as
“nothing changed.”

## Engine connection

The engine connects with WebSocket at:

```text
GET /v1/engine/connect
```

The engine authenticates separately. Attachment downloads use short-lived,
opaque tokens.

## Compatibility paths

The original two-host setup also exposes the API below `/fermin-code`,
`/fermin-code-puky`, and `/sync-hub`. They remain for compatibility. New
installations do not need to copy those names.
