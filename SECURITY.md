# Security policy

## Supported code

Security work applies to the latest `main` branch and the latest tagged
release. Older commits are not maintained as separate supported versions.

## Send reports privately

Use [GitHub private vulnerability reporting](https://github.com/GBurgardt/fermin-code/security/advisories/new).

Do not put any of these in a public issue, discussion, or pull request:

- exploit details;
- production endpoints;
- tokens or suspected secrets;
- personal data; or
- real conversation content.

Include the affected component, commit, impact, reproduction conditions, and a
safe proof of concept when available. Redact credentials and user content.

This volunteer project has no response-time SLA. Report handling and any
advisory depend on the verified impact and the available mitigation.

## Deployment remains the operator's responsibility

This release is single-user and self-hosted. The operator owns TLS ingress,
host security, Codex sandbox and approval settings, workspace allow-lists,
credentials, retention, and updates. Read the [security model](docs/SECURITY_MODEL.md)
before exposing a relay outside loopback.
