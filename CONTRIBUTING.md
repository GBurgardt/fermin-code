# Contributing

## Choose the right place

- Open an issue before a behavior change or architecture change.
- A small bug fix, test fix, or documentation correction can go directly to a
  pull request.
- Report a vulnerability through [SECURITY.md](SECURITY.md), never through a
  public issue.

Keep the product boundary intact:

- `service/` owns durability, routing, relay/engine transport, and the Codex
  App Server adapter.
- `desktop/` and `mobile/` are relay clients.
- Codex is the harness. Do not rebuild its model runtime or tool system inside
  the relay.

## Keep private data out

Do not commit:

- real domains or production endpoints;
- tokens or `.env` files;
- certificates, provisioning profiles, or signing teams;
- personal paths or session content;
- SQLite state or logs; or
- generated Xcode projects.

Use neutral fixtures such as `relay.example.com`, `/Users/example/projects`,
and non-personal demo text.

## Verify the component you changed

```bash
(cd service && cargo fmt --check && cargo test --locked)
(cd desktop && swift test)
(cd mobile && xcodegen generate)
```

For Mobile behavior, also build or test an unsigned simulator target in Xcode.
For UI work, attach before-and-after evidence that contains no real
conversation data.

## Write a useful pull request

State five things:

1. What problem exists?
2. Why does this component own the fix?
3. Does the change affect compatibility or security?
4. What tests and manual checks passed?
5. Does an operator need a migration or rollback step?

Keep the diff focused. Do not include unrelated generated files. Contributions
use the repository's MIT License.
