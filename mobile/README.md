# Fermín Code Mobile

This is the native SwiftUI iOS client for a Fermín relay. The product is
Fermín Code. The Xcode project and scheme still use the older internal name
`KyCode`.

## Generate the project

```bash
xcodegen generate
open KyCode.xcodeproj
```

Before signing, set your own values in `project.yml` or Xcode:

- bundle identifiers;
- `FERMIN_CODE_APP_GROUP`;
- `FERMIN_CODE_PRIMARY_RELAY_URL`;
- `FERMIN_CODE_SECONDARY_RELAY_URL`; and
- Apple development team.

The repository contains no signing team, certificate, provisioning profile,
or production relay URL. Use HTTPS for remote relays. Local network access is
only for discovery and testing on a network you control.

## Provider keys are optional, not part of core chat

Core chat uses the Codex login on the engine Mac. It does not need an OpenAI or
other model-provider key inside the iOS bundle.

Optional voice, narration, and share features can read
`Resources/App/Secrets.plist`. To test one of them:

1. Copy `Secrets.example.plist` to the ignored `Secrets.plist` filename.
2. Replace only the placeholders required by that feature.
3. Never commit the resulting file.

An iOS app cannot safely hide a shared long-lived service secret. Do not ship
provider credentials in a public build; put that exchange behind a backend you
control.
