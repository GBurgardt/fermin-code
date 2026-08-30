# Contributing

Thank you for helping make Fermín Code useful beyond its original one-person
deployment.

## Before opening a change

Use an issue for a behavior change or architectural proposal. Small bug fixes,
tests, and documentation corrections may go directly to a pull request.
Security reports must follow [SECURITY.md](SECURITY.md), not a public issue.

Keep changes inside the product boundary:

- `service/` owns durability, routing, relay/engine transport, and Codex App
  Server adaptation.
- `desktop/` and `mobile/` are native relay clients.
- Codex remains the harness; do not recreate its tools or model runtime in the
  relay.

Do not commit real domains, tokens, certificates, provisioning profiles,
signing teams, personal paths, SQLite state, or generated Xcode projects.

## Verification

Run the checks for every component you touch:

```bash
(cd service && cargo fmt --check && cargo test --locked)
(cd desktop && swift test)
(cd mobile && xcodegen generate)
```

Mobile behavior changes should also receive an unsigned simulator build or
test run in Xcode. UI changes should include before/after evidence without
private conversation content.

## Pull requests

Explain:

1. the user or protocol problem;
2. why the chosen component owns it;
3. compatibility and security impact;
4. tests and manual verification; and
5. any migration or rollback requirement.

Keep commits reviewable and avoid unrelated generated churn. By contributing,
you agree that your contribution is licensed under the repository's MIT
License.
