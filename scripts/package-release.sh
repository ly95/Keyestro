#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
cd "$project_root"

version="${KEYESTRO_MARKETING_VERSION:-}"
build_number="${KEYESTRO_BUILD_NUMBER:-}"
signing_identity="${KEYESTRO_CODE_SIGN_IDENTITY:-}"
notary_profile="${KEYESTRO_NOTARY_PROFILE:-}"
appcast_url="${KEYESTRO_APPCAST_URL:-}"
public_key="${KEYESTRO_EDDSA_PUBLIC_KEY:-}"
private_key_file="${KEYESTRO_SPARKLE_ED_KEY_FILE:-}"
download_prefix="${KEYESTRO_DOWNLOAD_URL_PREFIX:-}"
channel="${KEYESTRO_UPDATE_CHANNEL:-stable}"
release_notes="${KEYESTRO_RELEASE_NOTES_FILE:-}"

for required_name in version build_number signing_identity notary_profile appcast_url public_key private_key_file download_prefix release_notes; do
  if [[ -z "${(P)required_name}" ]]; then
    print -u2 "Missing required release value: $required_name"
    exit 64
  fi
done
if [[ "$signing_identity" == "-" ]]; then
  print -u2 "A Developer ID Application identity is required for release packaging."
  exit 64
fi
if [[ "$signing_identity" != "Developer ID Application:"* ]]; then
  print -u2 "KEYESTRO_CODE_SIGN_IDENTITY must be a Developer ID Application identity."
  exit 64
fi
if ! [[ "$version" =~ '^[0-9]+[.][0-9]+[.][0-9]+([+-][0-9A-Za-z.-]+)?$' ]]; then
  print -u2 "KEYESTRO_MARKETING_VERSION must be a path-safe semantic version."
  exit 64
fi
if ! [[ "$build_number" =~ '^[1-9][0-9]*$' ]]; then
  print -u2 "KEYESTRO_BUILD_NUMBER must be a positive decimal integer."
  exit 64
fi
if [[ "$appcast_url" != https://* || "$appcast_url" == *[[:space:]]* ]]; then
  print -u2 "KEYESTRO_APPCAST_URL must be an HTTPS URL without whitespace."
  exit 64
fi
if [[ "$download_prefix" != https://* || "$download_prefix" == *[[:space:]]* ]]; then
  print -u2 "KEYESTRO_DOWNLOAD_URL_PREFIX must be an HTTPS URL without whitespace."
  exit 64
fi
if ! python3 - "$appcast_url" "$download_prefix" "$public_key" <<'PY'
import base64
import binascii
import sys
from urllib.parse import urlsplit

for value in sys.argv[1:3]:
    parsed = urlsplit(value)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.fragment:
        raise SystemExit(1)
try:
    decoded_key = base64.b64decode(sys.argv[3], validate=True)
except (binascii.Error, ValueError):
    raise SystemExit(1)
if len(decoded_key) != 32:
    raise SystemExit(1)
PY
then
  print -u2 "Release URLs or the Sparkle Ed25519 public key are invalid."
  exit 64
fi
if [[ "$channel" != "stable" && "$channel" != "beta" ]]; then
  print -u2 "KEYESTRO_UPDATE_CHANNEL must be stable or beta."
  exit 64
fi
if [[ ! -f "$private_key_file" || ! -f "$release_notes" ]]; then
  print -u2 "The Sparkle private-key file and release-notes file must exist."
  exit 66
fi

release_root="$project_root/build/releases/Keyestro-$version-$build_number"
if [[ -e "$release_root" ]]; then
  print -u2 "Release output already exists: $release_root"
  exit 73
fi
mkdir -p "$project_root/build/releases"
release_work="$(mktemp -d)"
mounted_dmg=""
cleanup() {
  if [[ -n "$mounted_dmg" && -d "$mounted_dmg" ]]; then
    hdiutil detach "$mounted_dmg" -quiet || true
  fi
  rm -rf "$release_work"
}
trap cleanup EXIT
mkdir -p "$release_root"
evidence_root="$release_root/evidence"
mkdir -p "$evidence_root"

submit_notarization() {
  local artifact="$1"
  local report="$2"
  xcrun notarytool submit \
    "$artifact" \
    --keychain-profile "$notary_profile" \
    --wait \
    --output-format json \
    >"$report"
  python3 - "$report" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
if payload.get("status") != "Accepted" or not payload.get("id"):
    raise SystemExit(f"Notarization was not accepted: {path}")
print(f"Notarization accepted: {payload['id']}")
PY
}

scripts/check.sh
KEYESTRO_MARKETING_VERSION="$version" \
KEYESTRO_BUILD_NUMBER="$build_number" \
KEYESTRO_CODE_SIGN_IDENTITY="$signing_identity" \
KEYESTRO_APPCAST_URL="$appcast_url" \
KEYESTRO_EDDSA_PUBLIC_KEY="$public_key" \
scripts/build-app.sh release >/dev/null

app="$project_root/build/Keyestro.app"
plist="$app/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" == "$version" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")" == "$build_number" ]]
expected_bundle_identifier="${KEYESTRO_BUNDLE_ID:-com.keyestro.launcher}"
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" != "$expected_bundle_identifier" ]]; then
  print -u2 "The packaged bundle identifier does not match the configured production identifier."
  exit 65
fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :KeyestroRuntimeStorageMode' "$plist")" != "keychain" ]]; then
  print -u2 "A release package must use the persistent macOS Keychain storage profile."
  exit 65
fi
codesign --verify --deep --strict --verbose=2 "$app"
codesign -d --verbose=4 "$app" 2>"$release_work/signature.txt"
grep -q 'flags=.*runtime' "$release_work/signature.txt"
grep -q '^Timestamp=' "$release_work/signature.txt"
codesign -d --entitlements :- "$app" >"$release_work/entitlements.plist" 2>/dev/null
if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$release_work/entitlements.plist" >/dev/null 2>&1; then
  print -u2 "Release entitlement get-task-allow must be absent."
  exit 65
fi
if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.cs.disable-library-validation' "$release_work/entitlements.plist" >/dev/null 2>&1; then
  print -u2 "Release entitlement disable-library-validation must be absent."
  exit 65
fi

submission_zip="$release_work/Keyestro-notary-submission.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$submission_zip"
submit_notarization "$submission_zip" "$evidence_root/notary-app.json"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"

# Exercise the notarized candidate itself. Every app-bound report below must
# carry the same executable SHA-256; shortened smoke settings are overridden.
scripts/smoke-packaged-app.sh "$app"
KEYESTRO_BENCHMARK_ITERATIONS=30 scripts/run-performance-gate.sh
KEYESTRO_UI_BENCHMARK_ITERATIONS=30 \
KEYESTRO_UI_BENCHMARK_SKIP_BUILD=1 \
scripts/run-ui-performance-gate.sh
KEYESTRO_IDLE_BENCHMARK_DURATION=600 \
KEYESTRO_IDLE_BENCHMARK_SKIP_BUILD=1 \
scripts/run-idle-performance-gate.sh
KEYESTRO_LIFECYCLE_ITERATIONS=10000 \
KEYESTRO_LIFECYCLE_SKIP_BUILD=1 \
scripts/run-lifecycle-soak.sh
scripts/run-extension-fault-gate.sh
KEYESTRO_DATABASE_CRASH_SKIP_BUILD=1 scripts/run-database-crash-gate.sh
KEYESTRO_SOAK_DURATION=28800 \
KEYESTRO_SOAK_SAMPLE_INTERVAL=30 \
KEYESTRO_SOAK_SKIP_BUILD=1 \
scripts/run-clipboard-query-soak.sh
python3 scripts/verify-release-evidence.py \
  --app "$app" \
  --include-soak \
  --require-production-signature

archive_name="Keyestro-$version-$build_number-macos-arm64"
zip_path="$release_root/$archive_name.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip_path"

dmg_source="$release_work/dmg-source"
mkdir -p "$dmg_source"
ditto "$app" "$dmg_source/Keyestro.app"
ln -s /Applications "$dmg_source/Applications"
dmg_path="$release_root/$archive_name.dmg"
hdiutil create -quiet -volname "Keyestro $version" -srcfolder "$dmg_source" -format UDZO "$dmg_path"
submit_notarization "$dmg_path" "$evidence_root/notary-dmg.json"
xcrun stapler staple "$dmg_path"
xcrun stapler validate "$dmg_path"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg_path"

zip_readback="$release_work/zip-readback"
mkdir -p "$zip_readback"
ditto -x -k "$zip_path" "$zip_readback"
codesign --verify --deep --strict --verbose=2 "$zip_readback/Keyestro.app"
spctl --assess --type execute --verbose=2 "$zip_readback/Keyestro.app"
xcrun stapler validate "$zip_readback/Keyestro.app"

mounted_dmg="$release_work/mounted-dmg"
mkdir -p "$mounted_dmg"
hdiutil attach "$dmg_path" -nobrowse -readonly -mountpoint "$mounted_dmg" -quiet
codesign --verify --deep --strict --verbose=2 "$mounted_dmg/Keyestro.app"
spctl --assess --type execute --verbose=2 "$mounted_dmg/Keyestro.app"
xcrun stapler validate "$mounted_dmg/Keyestro.app"
hdiutil detach "$mounted_dmg" -quiet
mounted_dmg=""

scripts/generate-sbom.py \
  --version "$version" \
  --build "$build_number" \
  --output "$release_root/$archive_name.spdx.json"
cp "$release_notes" "$release_root/$archive_name.md"

cp build/performance/core-benchmarks.json "$evidence_root/"
cp build/performance/ui-benchmarks.json "$evidence_root/"
cp build/performance/idle-benchmarks.json "$evidence_root/"
cp build/reliability/lifecycle-soak.json "$evidence_root/"
cp build/reliability/database-crash.json "$evidence_root/"
cp build/reliability/clipboard-query-soak.json "$evidence_root/"
cp build/security/extension-faults.json "$evidence_root/"

appcast_source="$release_work/appcast-source"
mkdir -p "$appcast_source"
cp "$zip_path" "$appcast_source/$archive_name.zip"
cp "$release_notes" "$appcast_source/$archive_name.md"
generate_appcast="$project_root/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
[[ -x "$generate_appcast" ]]
appcast_arguments=(
  --ed-key-file "$private_key_file"
  --download-url-prefix "$download_prefix"
  --maximum-versions 3
  --maximum-deltas 5
  -o "$appcast_source/appcast.xml"
)
if [[ "$channel" == "beta" ]]; then
  appcast_arguments+=(--channel beta)
fi
"$generate_appcast" "${appcast_arguments[@]}" "$appcast_source"
cp "$appcast_source/appcast.xml" "$release_root/appcast-$channel.xml"

(
  cd "$release_root"
  shasum -a 256 \
    "$archive_name.zip" \
    "$archive_name.dmg" \
    "$archive_name.spdx.json" \
    "$archive_name.md" \
    "appcast-$channel.xml" \
    evidence/*.json \
    >SHA256SUMS
)

print "$release_root"
