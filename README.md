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

Ad-hoc development packages use the isolated bundle identifier
`com.keyestro.launcher.local`. Their database and credential material are
ephemeral, so rebuilding or UI testing cannot read the production app's
Keychain items or Application Support data. A Developer ID Application build
uses the configured production bundle identifier and macOS Keychain. Signing,
website, and update-feed values are centralized in `Config/Project.xcconfig`;
production values are intentionally not committed.

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
