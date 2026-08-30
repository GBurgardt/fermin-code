# Self-hosting

This is the shortest supported developer setup. It runs the relay and engine
manually on one Mac.

It does **not** install background services, create a public hostname, or
configure Apple signing.

## 1. Check the host

Install Rust 1.92 or newer and a compatible Codex CLI. Log in to Codex on the
Mac that will run the engine.

```bash
command -v codex
codex --version
```

Build Fermín and run its Codex check:

```bash
(cd service && cargo build --release)
(cd service && cargo run --bin ferminctl -- doctor --codex "$(command -v codex)")
```

Do not continue until `ferminctl doctor` succeeds.

## 2. Create three tokens

Use a different token for each boundary:

- clients → relay;
- engine → relay; and
- local engine API.

This command creates private files from the start:

```bash
umask 077
mkdir -p "$HOME/Library/Application Support/FerminCode/secrets"
openssl rand -hex 32 > "$HOME/Library/Application Support/FerminCode/secrets/client-token"
openssl rand -hex 32 > "$HOME/Library/Application Support/FerminCode/secrets/engine-token"
openssl rand -hex 32 > "$HOME/Library/Application Support/FerminCode/secrets/local-api-token"
chmod 600 "$HOME/Library/Application Support/FerminCode/secrets/"*-token
```

Configuration files contain token **paths**, not token values. Do not paste a
token into TOML, logs, shell history, or Git.

## 3. Start the relay

1. Copy `service/config/relay.example.toml` to the ignored file
   `service/config/relay.toml`.
2. Replace `USERNAME`.
3. Point the client and engine token fields at the files from step 2.
4. Start the process:

```bash
service/target/release/fermin-relay \
  --config service/config/relay.toml
```

The relay listens on loopback port 8840. Check it:

```bash
curl --fail http://127.0.0.1:8840/healthz
```

## 4. Start the engine

Copy `service/config/engine.example.toml` to the ignored file
`service/config/engine.toml`. Then set:

- `codexPath` to the absolute result of `command -v codex`;
- `workspaceRoots` to only the directories a remote Codex session may use;
- `authTokenFile` to the local API token;
- `relay.tokenFile` to the engine token; and
- `relay.url` to `ws://127.0.0.1:8840/v1/engine/connect` for this same-Mac
  setup.

Start it:

```bash
service/target/release/fermin-engine \
  --config service/config/engine.toml
```

Call `/healthz` again. It should report a ready, attached engine.

## 5. Connect Desktop

Run the client against the local relay:

```bash
cd desktop
FERMIN_CODE_PRIMARY_RELAY_URL=http://127.0.0.1:8840 swift run FerminCode
```

Open Settings and save the client token. For an Xcode app build, set
`FERMIN_CODE_PRIMARY_RELAY_URL` in `desktop/project.yml` or in the generated
target's build settings.

## 6. Connect Mobile

Set your values in `mobile/project.yml`:

- `FERMIN_CODE_PRIMARY_RELAY_URL`;
- `FERMIN_CODE_SECONDARY_RELAY_URL` if you have a second host; and
- `FERMIN_CODE_APP_GROUP` if you use the share extension.

Generate the project:

```bash
cd mobile
xcodegen generate
open KyCode.xcodeproj
```

Choose your own development team and bundle identifiers in Xcode. Core chat
uses the Codex login on the engine Mac; it does not need a model-provider key
inside the iOS app. `Secrets.example.plist` only documents optional voice and
share settings.

## 7. Reach the relay remotely

Keep the relay bound to `127.0.0.1`. Put one of these in front of it:

- an outbound TLS tunnel;
- a private WireGuard or Tailscale network; or
- a reverse proxy that you configure and protect.

The edge must preserve SSE streaming and WebSocket upgrades for
`/v1/engine/connect`. Use your own hostname, keep client and engine tokens
separate, and test both HTTPS and WSS.

Do not bind Fermín directly to `0.0.0.0` as a shortcut. This repository does
not automate ingress.
