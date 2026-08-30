# Self-hosting

This guide describes the current developer-oriented path. It does not install
a background service, configure a domain, or provision Apple signing for you.

## 1. Install prerequisites

Install Rust 1.92+, a compatible Codex CLI, and authenticate Codex on the Mac
that will run the engine. Confirm the executable:

```bash
command -v codex
codex --version
```

Build the service:

```bash
(cd service && cargo build --release)
(cd service && cargo run --bin ferminctl -- doctor --codex "$(command -v codex)")
```

## 2. Create private credentials

Create separate client, engine, and loopback engine-API tokens. The example
below keeps new files private from creation:

```bash
umask 077
mkdir -p "$HOME/Library/Application Support/FerminCode/secrets"
openssl rand -hex 32 > "$HOME/Library/Application Support/FerminCode/secrets/client-token"
openssl rand -hex 32 > "$HOME/Library/Application Support/FerminCode/secrets/engine-token"
openssl rand -hex 32 > "$HOME/Library/Application Support/FerminCode/secrets/local-api-token"
chmod 600 "$HOME/Library/Application Support/FerminCode/secrets/"*-token
```

Never paste the values into TOML. Configuration stores paths to token files.

## 3. Configure the relay

Copy `service/config/relay.example.toml` to an ignored local file, replace
`USERNAME`, and point both token fields at the files from step 2.

Run it:

```bash
service/target/release/fermin-relay \
  --config service/config/relay.toml
```

The relay binds to `127.0.0.1:8840`. Confirm:

```bash
curl --fail http://127.0.0.1:8840/healthz
```

## 4. Configure the engine

Copy `service/config/engine.example.toml` to `service/config/engine.toml` and:

- set `codexPath` to the absolute path from `command -v codex`;
- set `workspaceRoots` to only the directories the remote agent may use;
- point `authTokenFile` at a separate local API token file;
- point `relay.tokenFile` at the engine token; and
- for same-Mac development, set the relay URL to
  `ws://127.0.0.1:8840/v1/engine/connect`.

Run it:

```bash
service/target/release/fermin-engine \
  --config service/config/engine.toml
```

`/healthz` should now report an attached, ready engine.

## 5. Connect Desktop

For a same-Mac development run:

```bash
cd desktop
FERMIN_CODE_PRIMARY_RELAY_URL=http://127.0.0.1:8840 swift run FerminCode
```

Open Settings and store the client token. For an app build, set
`FERMIN_CODE_PRIMARY_RELAY_URL` in `desktop/project.yml` or as an Xcode build
setting before generating the project with XcodeGen.

## 6. Connect Mobile

Edit the public example settings in `mobile/project.yml`:

- `FERMIN_CODE_PRIMARY_RELAY_URL`
- `FERMIN_CODE_SECONDARY_RELAY_URL`
- `FERMIN_CODE_APP_GROUP` if you use the share extension

Then:

```bash
cd mobile
xcodegen generate
open KyCode.xcodeproj
```

Choose your own Apple development team and bundle identifiers in Xcode. The
core relay chat does not require model-provider API keys in the iOS bundle;
Codex authentication remains on the engine host. `Secrets.example.plist`
contains placeholders only for optional voice and share workflows.

## 7. Add remote ingress

For access outside the host, put an authenticated TLS edge or outbound tunnel
in front of loopback port 8840. Preserve streaming responses for SSE and
WebSocket upgrades for `/v1/engine/connect`. Do not change the service to bind
directly to `0.0.0.0` as a shortcut.

Cloudflare Tunnel, a private WireGuard/Tailscale network, or a carefully
configured reverse proxy can provide that edge. Fermín does not currently
automate any of them. Use your own hostname, keep client and engine credentials
separate, and verify both HTTPS and WSS before relying on remote execution.
