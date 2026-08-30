# Security model

Fermín Code can ultimately cause a trusted Mac to read and change files or run
commands through Codex. Treat the relay as a control plane, not as an ordinary
chat server.

## Implemented controls

- Relay and engine listeners are restricted to loopback by configuration
  validation.
- Public access is expected to terminate TLS at a reverse proxy or outbound
  tunnel.
- Client and engine bearer tokens are separate.
- Secret values are loaded from absolute, private regular files; the service
  rejects permissive Unix file modes.
- Client tokens are stored in Apple Keychain.
- Workspace roots are an explicit engine allow-list.
- Request, JSONL, frame, replay, preview, and attachment sizes are bounded.
- Commands have idempotency keys and durable states.
- Engine leases and fencing prevent an older connection generation from
  retaining authority.
- Protected responses disable shared caching.
- Codex App Server stays local to the controlled Mac.

## Deployment obligations

An operator must still:

- place HTTPS/WSS in front of every non-loopback connection;
- generate independent random tokens with at least 32 characters;
- keep token files at mode `0600` and out of logs, TOML, shell history, and
  source control;
- choose the narrowest possible workspace roots;
- configure Codex sandbox and approval behavior appropriate to the host;
- protect and update the host OS, Codex CLI, tunnel, and reverse proxy; and
- decide how long relay databases and attachments are retained.

Do not put a bearer token in a URL. Do not expose the engine listener or Codex
App Server directly to the public internet.

## Not yet a public multi-tenant security boundary

`v0.1` is a single-user, self-hosted implementation. It does not yet provide:

- accounts, OAuth/OIDC, or device pairing;
- short-lived device credentials and rotation workflows;
- tenant isolation or per-object authorization across accounts;
- a hosted audit log and administrative revocation surface;
- end-to-end encrypted message payloads;
- signed/notarized binary distribution and automatic updates; or
- a safe default authority profile for non-technical users.

Those are product requirements before offering a shared hosted relay.

## Sleep and offline execution

Queued work may execute when a host reconnects. A future public product needs
expiry and confirmation policies so a sensitive command cannot unexpectedly
run days later. A powered-off or network-isolated Mac remains unavailable;
wake-on-network is not a universal guarantee.

## Reporting a vulnerability

Do not open a public issue for a vulnerability or suspected exposed secret.
Follow [SECURITY.md](../SECURITY.md) and use GitHub private vulnerability
reporting.
