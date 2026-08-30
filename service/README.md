# Rust service

This crate builds three commands:

- `fermin-relay` accepts client commands, stores durable state, streams SSE
  updates, and connects to the engine.
- `fermin-engine` runs beside Codex, supervises Codex App Server, and bridges
  it to the relay.
- `ferminctl` checks the local Codex installation without exposing unrestricted
  diagnostics.

## Test it

```bash
cargo fmt --check
cargo test --locked
```

## Configure it

Start with:

- `config/relay.example.toml`
- `config/engine.example.toml`

The real local filenames are ignored by Git.

Secret fields contain **absolute paths to token files**, never token values.
The loader rejects:

- relative token paths;
- token files with permissive modes;
- non-loopback listeners;
- relative workspace roots; and
- a non-loopback engine-to-relay URL without TLS.

The relay and engine use separate SQLite databases in WAL mode. That design is
for the current single-user deployment. Do not treat it as a multi-tenant,
horizontally scaled storage design.

Follow [Self-hosting](../docs/SELF_HOSTING.md) for the complete local run.
