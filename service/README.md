# Fermín service

This Rust crate builds three binaries:

- `fermin-relay`: durable client API, SSE stream, and engine rendezvous.
- `fermin-engine`: local Codex App Server supervisor and relay bridge.
- `ferminctl`: bounded diagnostics for the local Codex installation.

## Verify

```bash
cargo fmt --check
cargo test
```

## Configuration

Start from `config/relay.example.toml` and `config/engine.example.toml`. Secret
fields are **file paths**, never inline credentials. The loader requires
absolute token paths, private regular files, loopback listeners, absolute
workspace roots, and TLS for a non-loopback engine-to-relay URL.

The relay and engine keep separate SQLite databases. SQLite WAL is appropriate
for this single-host implementation; it is not presented as the storage layer
for a future horizontally scaled multi-tenant service.

See the root [self-hosting guide](../docs/SELF_HOSTING.md) for an end-to-end
development run.
