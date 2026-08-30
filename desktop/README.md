# Fermín Code Desktop

This is the native SwiftUI macOS client for a Fermín relay.

It does:

- call the relay through REST;
- receive live updates through SSE;
- store client tokens in Keychain; and
- combine two optional host profiles in one view.

It does **not** start Codex, run the Fermín engine, or expose a local HTTP
server.

## Test and run

```bash
swift test
FERMIN_CODE_PRIMARY_RELAY_URL=http://127.0.0.1:8840 swift run FerminCode
```

Plain HTTP is valid only for loopback development. Use HTTPS for a remote
relay.

## Generate the Xcode app

```bash
xcodegen generate
open FerminCodeDesktop.xcodeproj
```

Set these values for your deployment:

- `FERMIN_CODE_PRIMARY_RELAY_URL`
- `FERMIN_CODE_SECONDARY_RELAY_URL`

Environment variables with the same names override the Info.plist values in
development and tests.

The committed project points to `relay.example.com`, which is intentionally
non-operational. Select your own Apple signing team. The repository contains
no production endpoint, team ID, or credential.
