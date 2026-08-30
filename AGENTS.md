# Agent guidance

This repository is the public Fermín Code monorepo. It contains exactly three
active product surfaces: `service/` (relay and engine), `desktop/` (native
macOS client), and `mobile/` (native iOS client).

Keep the architectural boundary explicit: Codex App Server is the local agent
harness; Fermín is the durable remote access and client layer. Do not add model
provider secrets, user tokens, signing identities, production domains, private
hostnames, or absolute personal paths.

Before changing a component, run its local verification:

- Service: `cargo fmt --check && cargo test`
- Desktop: `swift test`
- Mobile: `xcodegen generate` and an unsigned simulator build

The internal `puky` identifier is retained only for compatibility with the
current two-host protocol. Public documentation and new UI text should use
Primary and Secondary unless discussing that migration explicitly.

Keep source files authoritative. Generated Xcode projects, build directories,
SQLite state, local TOML configuration, certificates, profiles, and
`Secrets.plist` must remain untracked.
