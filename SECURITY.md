# Security policy

## Supported versions

Fermín Code is currently an early source release. Security fixes are made on
the latest `main` branch and latest tagged release only.

## Report privately

Please use [GitHub private vulnerability reporting](https://github.com/GBurgardt/fermin-code/security/advisories/new).
Do not open a public issue, discussion, or pull request containing exploit
details, production endpoints, tokens, personal data, or suspected secrets.

Include the affected component and commit, impact, reproduction conditions,
and any safe proof of concept. Redact credentials and user content.

The project will acknowledge a valid report, investigate it, coordinate a fix,
and publish an advisory when users have a practical mitigation. No guaranteed
response-time SLA is offered for this volunteer `v0.1` project.

## Scope reminder

The current release is a single-user, self-hosted implementation. A deployment
operator is responsible for TLS ingress, host security, Codex sandbox and
approval settings, workspace allow-lists, credential handling, retention, and
updates. See [the security model](docs/SECURITY_MODEL.md).
