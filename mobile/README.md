# Fermín Code Mobile

Native SwiftUI iOS client for the Fermín relay. The current Xcode target and
scheme retain the historical internal name `KyCode`; the shipped product name
is Fermín Code.

## Generate and build

```bash
xcodegen generate
open KyCode.xcodeproj
```

Before signing, customize these settings in `project.yml` or Xcode:

- bundle identifiers;
- `FERMIN_CODE_APP_GROUP`;
- `FERMIN_CODE_PRIMARY_RELAY_URL`;
- `FERMIN_CODE_SECONDARY_RELAY_URL`; and
- your Apple development team.

The repository contains no development team, provisioning profile, certificate,
or production relay URL. Remote relays should use HTTPS. Local networking is
enabled for developer-controlled discovery and testing.

## Optional provider features

The core Fermín chat uses Codex authentication on the Mac running the engine;
it does not require an OpenAI or model-provider key in the app bundle.

Some optional voice, narration, and share workflows read
`Resources/App/Secrets.plist`. If you use them, copy
`Secrets.example.plist` to the ignored filename and replace only the required
placeholders. Never commit that file. An iOS bundle cannot safely conceal a
shared service secret, so production versions should exchange long-lived
provider credentials for a backend-mediated design.
