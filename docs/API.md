# API surface

The Rust source is the protocol authority. This document is a map for readers,
not a frozen compatibility promise for `v0.1`.

## Client authentication

All `/api/mobile/*` routes require:

```http
Authorization: Bearer <client-token>
```

Protected responses use private, no-store cache policy. `/healthz` is public
and intentionally contains bounded operational metadata.

## Client routes

| Method and path | Purpose |
|---|---|
| `GET /healthz` | Relay and engine readiness |
| `GET /api/mobile/sessions` | Managed session summaries |
| `POST /api/mobile/sessions` | Create a session |
| `GET /api/mobile/sessions/{id}` | Session detail |
| `POST /api/mobile/sessions/{id}/message` | Submit a durable message command |
| `POST /api/mobile/sessions/{id}/steer` | Steer an active turn |
| `POST /api/mobile/sessions/{id}/interrupt` | Interrupt current work |
| `POST /api/mobile/sessions/{id}/archive` | Non-destructive archive |
| `DELETE /api/mobile/sessions/{id}/permanent` | Explicit permanent deletion |
| `PUT /api/mobile/sessions/{id}/pinned` | Synchronize pinned state |
| `POST /api/mobile/sessions/{id}/rename` | Rename a session |
| `POST /api/mobile/sessions/{id}/minimize` | Hide a session |
| `POST /api/mobile/sessions/{id}/restore` | Restore a hidden session |
| `GET /api/mobile/sessions/{id}/models` | Available model catalog |
| `POST /api/mobile/sessions/{id}/model-settings` | Update model settings |
| `POST /api/mobile/sessions/{id}/run-mode` | Update run mode |
| `POST /api/mobile/sessions/{id}/features` | Update Fermín feature flags |
| `POST /api/mobile/sessions/{id}/attachments` | Upload a bounded attachment |
| `GET /api/mobile/commands/{id}` | Durable command state |
| `GET /api/mobile/projects` | Authorized workspace projects |
| `POST /api/mobile/file-preview` | Bounded file preview |
| `GET /api/mobile/attachments/content` | Bounded attachment content |
| `GET /api/mobile/session-history` | Search archived/history sessions |
| `POST /api/mobile/session-history/resume` | Resume a history item |
| `GET /api/mobile/session-recovery` | Find recoverable sessions |
| `POST /api/mobile/session-recovery/recover` | Recover a session |
| `GET /api/mobile/stream` | SSE event stream |

Additional narrow endpoints for subagents, prompt transformation, and prompt
preferences are defined beside these routes in `service/src/api.rs`.

## Streaming and replay

`GET /api/mobile/stream` emits Server-Sent Events with monotonically ordered
relay sequence identifiers. A client can resume with a query cursor or the
standard `Last-Event-ID` header. If retained history cannot satisfy a cursor,
the client must refresh an authoritative snapshot instead of assuming no
change occurred.

## Durable commands

A successful command acceptance describes durability and includes a command
identifier. Typical states are:

```text
accepted → leased → engineDurable → sentToChild → completed
                                               └→ failed/cancelled/unknown
```

Clients should reuse an idempotency key when retrying the same user intent and
must not equate HTTP delivery with Codex completion.

## Engine connection

The engine authenticates separately and connects to:

```text
GET /v1/engine/connect
```

using WebSocket. Attachment retrieval for the engine uses short-lived opaque
tokens. Engine and client credentials are deliberately distinct.

## Compatibility aliases

For the original two-host installation, the router also exposes the same
surface below `/fermin-code`, `/fermin-code-puky`, and `/sync-hub`. These are
legacy deployment aliases, not a recommendation to encode machine names into a
new public edge.
