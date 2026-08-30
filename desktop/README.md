# Fermín Code Desktop

Native SwiftUI macOS client for the Fermín relay. It does not launch Codex or
run a local HTTP server. It consumes REST and SSE, stores relay tokens in
Keychain, and aggregates the two optional host profiles on the client.

## Swift Package build

```bash
swift test
FERMIN_CODE_PRIMARY_RELAY_URL=http://127.0.0.1:8840 swift run FerminCode
```

Only loopback endpoints may use plain HTTP; remote endpoints must use HTTPS.

## Xcode app build

```bash
xcodegen generate
open FerminCodeDesktop.xcodeproj
```

Set these build settings to your deployment:

- `FERMIN_CODE_PRIMARY_RELAY_URL`
- `FERMIN_CODE_SECONDARY_RELAY_URL`

The committed values use the non-operational `relay.example.com`. Select your
own signing team in Xcode. No team identifier or production credential is
committed.

The environment variables with the same names override Info.plist values for
development and automated tests.
