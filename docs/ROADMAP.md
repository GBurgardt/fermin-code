# Roadmap

The roadmap protects the relay thesis: make a personal Mac reliably operable
through Codex without rebuilding the Codex harness.

## v0.1 — publish the real system

- [x] Open relay, engine, Desktop, and Mobile source.
- [x] Remove production endpoints, signing identities, tokens, and personal
  paths from the publication.
- [x] Document durable commands, replay, fencing, and the Codex boundary.
- [x] Provide CI for Rust, macOS, and an unsigned iOS simulator build.
- [ ] Validate self-hosting with a clean third machine and a new GitHub user.
- [ ] Replace remaining historical `puky` identifiers with a versioned profile
  migration instead of a breaking rename.

## v0.2 — installable personal host

- Signed and notarized Fermín Host app for macOS.
- `SMAppService` helper with visible consent and diagnostics.
- Guided Codex detection/authentication and workspace selection.
- Pairing code instead of manually copied long-lived tokens.
- Update, rollback, protocol compatibility, and database migration policy.
- Explicit online, sleeping, offline, queued, expired, and user-presence states.

## v0.3 — hosted relay for individuals

- Account identity and per-device credentials.
- Multi-host routing by account and host ID.
- Horizontal storage, object storage for attachments, quotas, and retention.
- Device revocation, audit history, abuse controls, and cost boundaries.
- A documented trust decision for relay-readable versus end-to-end-encrypted
  message content.

## Integrations

- Automation API for an app to create a run with structured context,
  provenance, redaction, and an idempotency key.
- Reference integration with a host-infrastructure monitor.
- Optional local read-only MCP server when Codex needs fresh metrics during a
  turn.
- Narrow, approved corrective tools later; never an unaudited public shell as
  the default integration.

## Deliberately deferred

- Teams and enterprise administration.
- A marketplace of arbitrary remote tools.
- P2P as a required transport.
- Generic remote desktop or pixel streaming.
- Promises that a powered-off laptop can always be reached.
