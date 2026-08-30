# Architecture

## Short version

Fermín Code makes a Mac that already runs Codex reachable from trusted remote
clients.

- Codex reasons and executes.
- Fermín carries commands and session state reliably.
- The controlled Mac keeps Codex App Server local.

This is not remote desktop. The clients send structured commands and receive
structured events; they do not stream the Mac's screen.

## Data path

```text
Client ──HTTPS──▶ Relay ──outbound WebSocket──▶ Engine ──stdio──▶ Codex App Server
   ▲                 │                              │
   └──────SSE────────┴──── durable SQLite state ───┘
```

## What each component does

### Engine

The engine runs on the Mac controlled by Fermín. It:

- starts and monitors Codex App Server;
- talks to App Server through JSONL on standard input/output;
- checks the Codex version, schema, models, and required capabilities at
  startup;
- rejects project paths outside the configured `workspaceRoots`;
- converts Fermín commands into Codex thread and turn calls;
- stores sessions, commands, events, cursors, epochs, and leases in SQLite
  WAL;
- exposes only sessions managed by Fermín;
- processes sessions separately, so one slow session does not block the rest;
  and
- never exposes Codex App Server to the public network.

### Relay

The relay connects clients to engines. It:

- authenticates client HTTP requests;
- saves each command before returning an accepted response;
- uses idempotency keys to collapse repeated submissions;
- stores commands, snapshots, events, aliases, and cursors in SQLite;
- sends ordered live updates over Server-Sent Events (SSE);
- resumes SSE from a cursor or `Last-Event-ID`;
- tracks engine heartbeats and leases;
- blocks stale engine generations from writing state; and
- holds queued work while an engine is temporarily offline.

The engine connects **out** to the relay through WebSocket. The controlled Mac
does not need a public inbound engine port.

### Desktop and Mobile

The Apple apps are relay clients. They do not run Codex themselves. They use:

- REST for reads and durable commands;
- SSE for live updates;
- saved cursors for reconnect;
- bounded polling when SSE is unavailable; and
- Keychain for client tokens.

Both apps support two host profiles plus an aggregate view. The UI calls them
Primary, Secondary, and All. The protocol still contains the older values
`personal`, `puky`, and `all` for compatibility.

## What “durable” means here

WebSocket only moves frames. Fermín adds the state needed to recover:

- protocol version;
- engine identity;
- connection epoch;
- ordered sequence numbers;
- acknowledgements;
- resume cursor; and
- fencing generation.

Fermín does not promise exactly-once execution. There is one unavoidable edge
case: Codex may receive a command and the engine may crash before it records
the result. Fermín marks that command `unknown` and reconciles the session. It
does not repeat the command blindly.

## Reusable code and private deployment details

| Included in this repository | Specific to the original private setup |
|---|---|
| Engine beside Codex | One always-on Mac used as the central server |
| Outbound engine connection | A private Cloudflare account and domain |
| REST commands and SSE events | Route names chosen for two personal Macs |
| Replay, idempotency, leases, and fencing | Personal launchd and PM2 services |
| Local SQLite databases | Personal filesystem paths |
| Workspace allow-list | A preconfigured Codex login |
| Keychain token storage | Production tokens copied by the owner |
| Offline queue and reconnect | A Mac configured not to sleep |

Compatibility aliases `/fermin-code`, `/fermin-code-puky`, and `/sync-hub`
remain in the router. A new deployment can use the unprefixed API and choose
its own external paths.

## Codex boundary

Fermín does not implement a model runtime or a second tool system. The engine
uses the local App Server API. Codex authentication stays on the host. See the
official [Codex App Server documentation](https://learn.chatgpt.com/docs/app-server)
for App Server concepts.

## Automation and MCP

The repository does not include a public Automation API or an infrastructure
MCP integration.

They solve different problems if added by a deployment:

- **Automation API:** another app asks Fermín to create work and supplies
  structured context.
- **Local MCP server:** Codex is already working and needs fresh, narrowly
  scoped data or actions from the host.
- **Relay:** routes, stores, resumes, and authenticates remote work.

The relay is not an MCP server. No future integration is promised by this
document.
