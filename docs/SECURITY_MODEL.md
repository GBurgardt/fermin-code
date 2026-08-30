# Security model

## Start with the real risk

Fermín can ask Codex to read files, change a workspace, and run commands on an
authorized Mac. Treat the relay like an administrative control plane, not like
a normal chat server.

If you do not trust a device, network edge, or token holder with that level of
access, do not connect it.

## Controls already implemented

- Relay and engine listeners must bind to loopback.
- Remote traffic is designed to enter through a separate TLS edge or outbound
  tunnel.
- Clients and engines use different bearer tokens.
- The service reads secrets from absolute private files and rejects permissive
  Unix file modes.
- Apple clients keep their tokens in Keychain.
- `workspaceRoots` limits which directories the engine accepts.
- Requests, JSONL lines, WebSocket frames, replay pages, previews, and
  attachments have size limits.
- Idempotency keys prevent duplicate durable commands during retries.
- Engine leases and fencing block an older connection from keeping authority.
- Protected responses disable shared caching.
- Codex App Server stays local to the controlled Mac.

## What the operator must secure

The repository cannot make deployment choices for you. The operator must:

1. Put HTTPS and WSS in front of every non-loopback connection.
2. Generate separate random tokens of at least 32 characters.
3. Keep token files at mode `0600` and out of logs, TOML, shell history, and
   source control.
4. Give the engine the smallest useful `workspaceRoots` list.
5. Choose Codex sandbox and approval settings that match the host's risk.
6. Update and protect macOS, Codex, the tunnel, and the reverse proxy.
7. Set a retention policy for relay databases and attachments.

Never put a bearer token in a URL. Never expose the engine listener or Codex
App Server directly to the public internet.

## Security features not included

This release is single-user and self-hosted. It does not include:

- user accounts or OAuth/OIDC;
- device pairing;
- short-lived device credentials or a rotation UI;
- tenant isolation and per-object authorization across accounts;
- a hosted audit and device-revocation console;
- end-to-end encryption for message payloads;
- signed or notarized binary distribution;
- automatic updates; or
- a safe default authority profile for non-technical users.

Do not use the current relay as a shared multi-tenant service.

## Queued work can run later

If the host is offline, a saved command can run when it reconnects. This
release does not provide a general user-facing expiry and reconfirmation policy
for delayed commands. Only queue work that is still safe to execute later.

A sleeping, powered-off, or network-isolated Mac remains unavailable. Network
wake features are not a guarantee.

## Report a vulnerability privately

Do not put exploit details or a suspected secret in a public issue. Follow
[SECURITY.md](../SECURITY.md) and use GitHub private vulnerability reporting.
