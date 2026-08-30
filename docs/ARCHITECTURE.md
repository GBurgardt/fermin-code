# Architecture

## Product thesis

Fermín Code turns a Mac that already runs Codex into a remotely operable agent
host. Codex remains responsible for reasoning, sessions, turns, tools,
approvals, sandboxing, and workspace execution. Fermín is responsible for
transporting intent and state between that host and trusted clients.

It is closer to a semantic remote-control plane than to remote desktop: clients
send commands and receive structured events instead of streaming pixels.

## Components

### Fermín Engine

The engine runs beside Codex on each controlled Mac. It:

- starts and supervises a local Codex App Server process;
- communicates with App Server through JSONL on standard input/output;
- probes the Codex version, schema, models, and capabilities at startup;
- restricts project access to configured absolute `workspaceRoots`;
- translates Fermín commands into Codex thread and turn operations;
- persists session state, commands, events, cursors, epochs, and leases in
  SQLite WAL;
- exposes only sessions managed by Fermín;
- processes sessions independently so one busy conversation does not block all
  others; and
- keeps App Server off the public network.

### Fermín Relay

The relay is the durable meeting point between clients and engines. It:

- accepts authenticated client commands over HTTP;
- persists a command before acknowledging acceptance;
- deduplicates retries through idempotency keys;
- stores commands, snapshots, events, aliases, and cursors in SQLite;
- emits ordered events over Server-Sent Events (SSE);
- resumes an event stream from a cursor or `Last-Event-ID`;
- tracks engine heartbeat and lease state;
- fences stale engine generations; and
- can retain work while an engine is temporarily disconnected.

The engine opens the WebSocket connection outbound. The relay does not need an
inbound port on the controlled Mac.

Fermín deliberately does not claim exactly-once execution. A crash after a
command reaches Codex but before its result is durably recorded can be
ambiguous. Such work is represented as `unknown` and must be reconciled rather
than blindly repeated.

### Desktop and Mobile

Both Apple clients are relay clients, not local harnesses. They use:

- REST for queries and durable commands;
- SSE for primary live updates;
- persisted cursors for reconnection;
- bounded polling as recovery when streaming is unavailable; and
- Keychain for bearer tokens.

The clients support two explicit host profiles and a client-side aggregate
view. Historical internal values are `personal`, `puky`, and `all`; public UI
language is Primary, Secondary, and All.

## Protocol paths

```text
Client ──HTTPS──▶ Relay ──outbound WebSocket──▶ Engine ──stdio──▶ Codex App Server
   ▲                 │                              │
   └──────SSE────────┴──── durable SQLite state ───┘
```

The engine-relay envelope carries a protocol version, engine identity,
connection epoch, sequence, acknowledgement, resume cursor, and fencing
generation. WebSocket supplies framing; Fermín supplies the durable semantics.

## General core versus original deployment

| Reusable core | Original private deployment, not published as configuration |
|---|---|
| Local engine beside Codex | One Mac acting as a permanent central server |
| Outbound host connection | A specific Cloudflare account and domain |
| REST commands and SSE events | Fixed route names for two named Macs |
| Replay, idempotency, leases, fencing | Personal launchd and PM2 services |
| SQLite on the local host | Personal filesystem paths |
| Workspace allow-list | Preinstalled/authenticated Codex environment |
| Client tokens in Keychain | Manually provisioned production tokens |
| Offline queue and reconnect | A machine configured never to sleep |

The repository retains legacy path aliases (`/fermin-code`,
`/fermin-code-puky`, and `/sync-hub`) for compatibility. New deployments may
use the unprefixed API surface and should choose their own public routing.

## Codex boundary

Fermín does not implement a second tool protocol or model runtime. The engine
uses the local App Server API and leaves Codex authentication on the host. For
current App Server concepts and transports, consult the official
[Codex App Server documentation](https://developers.openai.com/codex/app-server/).

## Automation and MCP

An external application that wants to create a Fermín session and attach a
snapshot should eventually use an Automation API: the application is asking
Fermín to start work.

MCP fits the opposite direction. Once Codex is already working, a local,
least-privilege MCP server can let it query fresh data or invoke a narrow host
capability. The relay itself should not be redefined as an MCP server; it owns
durability, routing, identity, and reconnection.
