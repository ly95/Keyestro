# Release runbook

Keyestro releases are produced from a clean checkout and a signed Git tag. A release is not complete until the artifacts downloaded from their public URLs pass the readback checklist below.

## Protected inputs

Configure these only in the protected release environment; never commit their values:

- `KEYESTRO_CODE_SIGN_IDENTITY`: Developer ID Application identity.
- `KEYESTRO_NOTARY_PROFILE`: `notarytool` Keychain profile created with `xcrun notarytool store-credentials`.
- `KEYESTRO_SPARKLE_ED_KEY_FILE`: Sparkle Ed25519 private-key file.
- `KEYESTRO_EDDSA_PUBLIC_KEY`: matching public key embedded into the app.
- `KEYESTRO_APPCAST_URL`: HTTPS stable or beta feed URL.
- `KEYESTRO_DOWNLOAD_URL_PREFIX`: HTTPS artifact base URL used in the appcast.
- `KEYESTRO_MARKETING_VERSION` and `KEYESTRO_BUILD_NUMBER`.
- `KEYESTRO_UPDATE_CHANNEL`: `stable` or `beta`.
- `KEYESTRO_RELEASE_NOTES_FILE`: reviewed Markdown release notes.

## Local candidate gates

For an ad-hoc local candidate, build once and run the gate suite on the
documented Apple Silicon baseline. Retain every JSON report with the candidate
evidence:

```bash
scripts/build-app.sh release
scripts/run-performance-gate.sh
KEYESTRO_UI_BENCHMARK_SKIP_BUILD=1 scripts/run-ui-performance-gate.sh
KEYESTRO_IDLE_BENCHMARK_SKIP_BUILD=1 scripts/run-idle-performance-gate.sh
KEYESTRO_LIFECYCLE_SKIP_BUILD=1 scripts/run-lifecycle-soak.sh
KEYESTRO_DATABASE_CRASH_SKIP_BUILD=1 scripts/run-database-crash-gate.sh
scripts/run-extension-fault-gate.sh
KEYESTRO_SOAK_SKIP_BUILD=1 scripts/run-clipboard-query-soak.sh
python3 scripts/verify-release-evidence.py \
  --app build/Keyestro.app \
  --include-soak \
  --include-ui-walkthrough
```

Ad-hoc packages are deliberately stamped as `com.keyestro.launcher.local` with
`KeyestroRuntimeStorageMode=ephemeral`. Normal UI launches therefore use a
per-run temporary database and in-memory credentials; they never open the
production Keychain service or Application Support directory. The Developer ID
packaging path stamps `KeyestroRuntimeStorageMode=keychain` and retains the
configured production bundle identifier. Missing or unrecognized storage-mode
metadata fails closed to the isolated ephemeral profile.

The `*_SKIP_BUILD=1` settings are intentional: UI, idle, lifecycle,
database-crash, and eight-hour soak reports must all name the same executable
SHA-256 rather than silently rebuilding between gates. The core benchmark and
extension-fault report exercise separate release tools and therefore do not
carry an app-executable hash.

The cross-report validator also reads the packaged `Info.plist`. A local
candidate is rejected unless it uses `com.keyestro.launcher.local` with
`KeyestroRuntimeStorageMode=ephemeral`; a production candidate is rejected
unless it uses a non-local bundle identifier with
`KeyestroRuntimeStorageMode=keychain`. This keeps ordinary rebuilds from
silently regaining access to the production Keychain item.

After the final-artifact launcher/settings/accessibility smoke walkthrough has
been recorded as `build/ui-walkthrough.json`, pass
`--include-ui-walkthrough` so the validator also rejects an incomplete record
or one captured from a different executable hash. This scoped smoke record does
not replace the VoiceOver, visual-environment, IME, display, permission, or
clean-machine rows in the manual release matrix.

The ordinary performance workflow runs the 30-process UI gate, real Spotlight
probe, 10-minute idle measurement, 10,000-cycle lifecycle gate, database
SIGKILL/readback, and hostile-extension matrix. The exact eight-hour
clipboard/query soak runs in its dedicated self-hosted workflow. Hardware,
macOS build, thresholds, sample counts, ad-hoc/production signature state, and
artifact hash remain embedded in the applicable reports. Manual input-method,
VoiceOver, permission, display, install, and system-state matrices still belong
in the completed release verification sheet; automated reports do not replace
those checks.

## Build, notarize, and package

Run `scripts/package-release.sh` in the protected release environment. It
performs the full repository check, builds and notarizes the Developer ID
candidate App, and then runs every automated gate—including the exact eight-hour
soak—against that same executable. It rejects shortened samples, mismatched
artifact hashes, ad-hoc signatures, incomplete hostile-extension scenarios, and
dangerous release entitlements before creating the ZIP or DMG. It then notarizes
and staples the DMG, verifies ZIP and mounted-DMG readbacks, preserves the JSON
gate reports under `evidence/`, generates an SPDX 2.3 SBOM and SHA-256 manifest,
and signs the Sparkle appcast with the pinned Sparkle tool.

Packaging runs the complete repository check before signing. Candidate-specific
performance, update, manual, and public readback evidence is collected only
after the signed artifacts exist.

The script intentionally fails if its versioned output directory already exists. Use a fresh build number rather than overwriting release evidence.

## Release notes checklist

Each release note must state:

- new or changed macOS permissions;
- new network destinations or an explicit “none”;
- database/configuration migrations and downgrade behavior;
- known issues and workarounds;
- the minimum supported macOS version.

## Publish and read back

1. Publish the ZIP, DMG, SBOM, `SHA256SUMS`, release notes, signed appcast, and `evidence/` JSON reports to GitHub Releases and the HTTPS website.
2. Download every file again into a clean temporary directory.
3. Run `shasum -a 256 -c SHA256SUMS`.
4. Unzip the ZIP and run `codesign --verify --deep --strict --verbose=2`, `spctl --assess --type execute --verbose=2`, and `xcrun stapler validate` against `Keyestro.app`.
5. Run `spctl --assess --type open` and `xcrun stapler validate` against the DMG; mount it and repeat all app checks.
6. Launch on a clean minimum-version Mac and a current stable Mac, then complete `docs/release-verification.md`.
7. Generate the Homebrew Cask URL, version, and SHA-256 only from the read-back artifact. Verify a clean `brew install --cask` before publishing the Cask update.
8. Confirm stable and beta appcasts expose only their intended channels and complete the valid/tampered/wrong-key/wrong-signature/interrupted-update matrix.
9. Archive the immutable evidence records and run the final artifact verifier with every applicable evidence flag. Do not announce the release unless it passes.

Keep the signed tag, CI run URL, notary submission IDs, completed verification sheet, public download URLs, and hashes together as immutable release evidence.
