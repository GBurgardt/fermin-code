# Fermín Code

**Run Codex on your Mac. Control it from an iPhone or another Mac.**

Fermín Code is the remote layer between your devices and Codex. Codex still
does the reasoning, tool use, and workspace changes. Fermín moves commands and
session updates between devices, keeps them durable, and reconnects after a
network interruption.

![Fermín Code Desktop showing remote sessions](docs/images/en/desktop/desktop-main.png)

<p align="center">
  <img src="docs/images/en/mobile/mobile-many-sessions.png" width="260" alt="Fermín Code Mobile showing several active sessions">
  &nbsp;&nbsp;
  <img src="docs/images/en/mobile/mobile-conversation.png" width="260" alt="Fermín Code Mobile showing a conversation">
</p>

## What you get

| Folder | What it contains |
|---|---|
| `service/` | The Rust relay, the Mac engine, and a diagnostic CLI |
| `desktop/` | The native macOS client |
| `mobile/` | The native iOS client for iOS 17 or newer |

All three are working source builds. This repository does **not** provide a
hosted relay or a one-click consumer installer. The current setup is for
developers who can configure macOS, Codex, TLS ingress, and private tokens.

## How it works

```text
Fermín Mobile / Desktop
          │  HTTPS commands + SSE updates
          ▼
      Fermín Relay
          │  outbound authenticated WebSocket
          ▼
      Fermín Engine
          │  JSONL over standard input/output
          ▼
    Codex App Server
          │
          ▼
  files and projects on your Mac
```

The important split is simple:

- **Codex is the agent harness.** It owns sessions, turns, tools, approvals,
  sandboxing, and execution.
- **Fermín is the remote control layer.** It owns routing, durable commands,
  reconnect, replay, and the Desktop and Mobile clients.

Fermín does not expose Codex App Server directly to the internet. Read
[Architecture](docs/ARCHITECTURE.md) for the exact boundary.

## Why the relay matters

A normal HTTP request can disappear when a phone changes networks or an app
goes into the background. Fermín avoids that failure mode:

1. The relay saves a command before it says the command was accepted.
2. Repeated requests use an idempotency key, so a retry does not create the
   same command twice.
3. Clients resume ordered updates from a saved cursor.
4. An old engine connection cannot overwrite a newer one.
5. Work can remain queued while the Mac is temporarily offline.

## Run the source locally

You need:

- macOS with Xcode Command Line Tools;
- full Xcode for Mobile;
- Rust 1.92 or newer;
- XcodeGen; and
- a compatible Codex CLI that is already authenticated on the host Mac.

Test and build the Rust service:

```bash
cd service
cargo test --locked
cargo build --release
```

Test and run Desktop:

```bash
cd desktop
swift test
swift run FerminCode
```

Generate the Mobile project:

```bash
cd mobile
xcodegen generate
open KyCode.xcodeproj
```

The committed relay URLs use `relay.example.com` and do not work. Replace them
with your own endpoints. Desktop reads
`FERMIN_CODE_PRIMARY_RELAY_URL` and
`FERMIN_CODE_SECONDARY_RELAY_URL`; Mobile reads the matching settings in
`mobile/project.yml`.

Enter client tokens in the apps. The apps store them in Keychain. Never commit
tokens to this repository.

For the complete local setup, follow [Self-hosting](docs/SELF_HOSTING.md).

## Current limits

- One relay instance is designed for one user and one active engine
  generation.
- The relay only binds to loopback. You must provide a TLS reverse proxy,
  private network, or outbound tunnel for remote access.
- The built-in profiles are called Primary and Secondary in the UI. The older
  internal values `personal` and `puky` remain in the protocol for
  compatibility.
- A sleeping, powered-off, or disconnected Mac cannot execute work. The relay
  can queue a command; it cannot make the Mac available.
- The original deployment's domains, tokens, signing data, paths, launchd,
  PM2, and Cloudflare files are private and are not included.
- This repository does not include accounts, multi-tenant isolation, device
  pairing, automatic updates, notarized binaries, a hosted relay, or
  end-to-end encryption.

These are current facts, not a promised release plan.

## Documentation

- [Architecture](docs/ARCHITECTURE.md)
- [Self-hosting](docs/SELF_HOSTING.md)
- [API](docs/API.md)
- [Security model](docs/SECURITY_MODEL.md)
- [Communication notes](docs/LAUNCH.md)
- [Image provenance](docs/images/README.md)
- [Contributing](CONTRIBUTING.md)
- [Private security reports](SECURITY.md)

## License

Fermín Code uses the [MIT License](LICENSE).

Codex is a separate OpenAI product. Fermín Code is not an official OpenAI
product.
