# Keyestro

Keyestro is a native, local-first command launcher for macOS. Press `⌥ Space` to find and run apps, files, calculations, quick links, scripts, clipboard entries, windows, and trusted extensions without leaving the keyboard.

The project is under active development. macOS 14 or later and Apple Silicon
are the v1 release baseline.

## Build

Install the current stable Xcode, then run:

```bash
swift test --disable-keychain --disable-netrc
./scripts/check.sh
./scripts/build-app.sh debug
open build/Keyestro.app
```

`scripts/check.sh` is the repository acceptance check: it lints formatting,
validates localization and the dependency allowlist, builds Debug and Release,
runs the unit/contract suite and extension examples, and verifies the assembled
app's nested code signatures.

Ordinary ad-hoc development packages use the isolated bundle identifier
`com.keyestro.launcher.local`. Their database and credential material are
ephemeral, so rebuilding or UI testing cannot read the production app's
Keychain items or Application Support data. A Developer ID Application build
uses the configured production bundle identifier and macOS Keychain. Signing,
website, and update-feed values are centralized in `Config/Project.xcconfig`;
production values are intentionally not committed.

macOS privacy grants are bound to the app's code-signing identity. An ad-hoc
identity changes whenever the executable is rebuilt, so Accessibility and
Screen Recording grants cannot survive normal development rebuilds. Use a
stable local signature when testing those permissions:

Quit any running Keyestro copy first, then explicitly select a certificate
belonging to the intended developer or organization:

```bash
KEYESTRO_LOCAL_CODE_SIGN_IDENTITY='Apple Development: Your Name (TEAMID)' \
  ./scripts/build-local-signed-app.sh debug
open build/Keyestro.app
```

The helper deliberately never selects the first available certificate because
that identity may belong to an unrelated organization. It keeps the local
bundle identifier and ephemeral storage profile. The first signing may require
Keychain approval. When switching from an older ad-hoc copy, remove the stale
Keyestro entries from the relevant Privacy & Security panes and grant
the newly built copy once; subsequent builds made with the same certificate
retain the grant.

## Architecture

- AppKit owns the launcher panel, focus, global hotkey, system integration, and permission boundaries.
- SwiftUI renders launcher content and settings.
- `KeyestroDomain` contains Foundation-only models and deterministic search logic.
- `KeyestroCore` contains providers, services, persistence, action execution, and extension supervision.
- Extensions execute out of process through bounded JSON-RPC framing.

See [architecture](docs/architecture/overview.md), [security policy](SECURITY.md), and [privacy policy](PRIVACY.md).
A successful development check is not, by itself, a v1 release claim. Release
candidates must also complete the public verification process documented in
[the release checklist](docs/release-verification.md).

Extension authors can use the [Extension SDK](docs/extension-sdk/README.md). Maintainers should follow the [release runbook](docs/releasing.md) and preserve a completed [release verification sheet](docs/release-verification.md) for every candidate.

## Contributing

Contributions use the Developer Certificate of Origin. See [CONTRIBUTING.md](CONTRIBUTING.md) and include a `Signed-off-by` trailer in commits.

## License

Apache License 2.0. See [LICENSE](LICENSE).
