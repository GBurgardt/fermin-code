# Fermín Code

**Operate Codex on your own Mac from an iPhone or another Mac.**

Fermín Code is an open-source remote control layer for Codex. Codex remains the
agent harness: it reasons, owns threads and turns, uses tools, and changes the
workspace. Fermín adds the missing remote-product layer: host routing, durable
commands, reconnect and replay, multi-device clients, and continuity when a
client changes networks or disappears.

![Fermín Code Desktop showing remote sessions](docs/images/en/desktop/desktop-main.png)

<p align="center">
  <img src="docs/images/en/mobile/mobile-many-sessions.png" width="260" alt="Fermín Code Mobile managing many live sessions">
  &nbsp;&nbsp;
  <img src="docs/images/en/mobile/mobile-conversation.png" width="260" alt="Fermín Code Mobile conversation">
</p>

## What is open here

| Component | Role | Status |
|---|---|---|
| `service/` | Rust relay and per-Mac engine | Working single-user implementation |
| `desktop/` | Native macOS relay client | Working source build |
| `mobile/` | Native iOS relay client | Working source build, iOS 17+ |

This is a source-first `v0.1` release, not a hosted service and not a turnkey
consumer installer. The protocol and clients are real and used daily; setup is
still intended for developers comfortable with macOS, TLS ingress, and local
configuration.

## The boundary that matters

```text
Fermín Mobile / Desktop
          │  HTTPS commands + SSE events
          ▼
      Fermín Relay
          │  authenticated outbound WebSocket
          ▼
      Fermín Engine
          │  JSONL over stdio
          ▼
    Codex App Server
          │
          ▼
  files, commands and projects on your Mac
```

Fermín does **not** replace Codex, proxy model-provider credentials, or expose
Codex App Server directly to the internet. The engine keeps App Server local
and gives remote clients a smaller, durable protocol. See
[Architecture](docs/ARCHITECTURE.md) for the complete division of
responsibilities.

## Why the relay exists

A raw network connection is not enough for a useful remote agent experience.
Fermín persists a command before acknowledging it, uses idempotency keys,
delivers an ordered event stream with resumable cursors, fences stale engine
connections, and can hold work while a Mac reconnects. Desktop and Mobile can
therefore move between foreground, background, Wi-Fi, and cellular without
becoming the source of truth.

## Quick development path

Prerequisites:

- macOS with Xcode Command Line Tools; full Xcode for the iOS client
- Rust 1.92 or newer
- a compatible, locally authenticated Codex CLI
- XcodeGen for generated Apple projects

Build and test the service:

```bash
cd service
cargo test
cargo build --release
```

Build the Desktop client:

```bash
cd desktop
swift test
swift run FerminCode
```

Generate the iOS project:

```bash
cd mobile
xcodegen generate
open KyCode.xcodeproj
```

The example endpoints are intentionally non-operational. Set your own relay
URLs with `FERMIN_CODE_PRIMARY_RELAY_URL` and
`FERMIN_CODE_SECONDARY_RELAY_URL` for Desktop, or change the corresponding
build settings in `mobile/project.yml`. Tokens are entered in the clients and
stored in Keychain; they never belong in source control.

For an end-to-end local deployment, follow [Self-hosting](docs/SELF_HOSTING.md).

## Current assumptions and limits

- The relay is single-user and currently expects one active engine generation
  per relay instance.
- The relay binds to loopback by design. Remote access requires a TLS reverse
  proxy or outbound tunnel that you operate.
- The two built-in client profiles originated as two personal Macs. Their
  internal identifiers (`personal` and `puky`) remain for protocol
  compatibility, while the public UI calls them Primary and Secondary.
- A sleeping, powered-off, or disconnected Mac cannot execute work. Commands
  may queue, but availability is not manufactured by the relay.
- Signing teams, bundle identifiers, domains, tokens, absolute paths, launchd,
  PM2, and Cloudflare configuration from the original deployment are not
  included.
- Multi-tenancy, account pairing, hosted relay operation, automatic updates,
  notarized binaries, and end-to-end encryption are roadmap work.

These limits are deliberate and documented rather than hidden behind a larger
product claim. See [Roadmap](docs/ROADMAP.md).

## Documentation

- [Architecture and protocol](docs/ARCHITECTURE.md)
- [Self-hosting](docs/SELF_HOSTING.md)
- [API surface](docs/API.md)
- [Security model](docs/SECURITY_MODEL.md)
- [Roadmap](docs/ROADMAP.md)
- [Launch plan and copy](docs/LAUNCH.md)
- [Screenshot provenance](docs/images/README.md)
- [Contributing](CONTRIBUTING.md)
- [Security reports](SECURITY.md)

## License

Fermín Code is available under the [MIT License](LICENSE).

Codex is a separate OpenAI product and is subject to its own terms. This
project is not an official OpenAI product.
