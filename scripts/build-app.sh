#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
cd "$project_root"

configuration="${1:-debug}"
case "$configuration" in
  debug|release) ;;
  *) print -u2 "usage: $0 [debug|release]"; exit 64 ;;
esac

signing_identity="${KEYESTRO_CODE_SIGN_IDENTITY:--}"
build_profile="${KEYESTRO_BUILD_PROFILE:-auto}"
case "$build_profile" in
  auto)
    if [[ "$signing_identity" == "Developer ID Application:"* ]]; then
      build_profile="production"
    else
      build_profile="local"
    fi
    ;;
  local|production) ;;
  *) print -u2 "KEYESTRO_BUILD_PROFILE must be auto, local, or production."; exit 64 ;;
esac

if [[ "$build_profile" == "production" ]]; then
  if [[ "$signing_identity" == "-" ]]; then
    print -u2 "A stable code-signing identity is required for a production build."
    exit 64
  fi
  default_bundle_identifier="com.keyestro.launcher"
  runtime_storage_mode="keychain"
  code_signature_kind="production"
else
  default_bundle_identifier="com.keyestro.launcher.local"
  runtime_storage_mode="ephemeral"
  if [[ "$signing_identity" == "-" ]]; then
    code_signature_kind="adhoc"
  else
    code_signature_kind="stable-local"
  fi
fi
bundle_identifier="${KEYESTRO_BUNDLE_ID:-$default_bundle_identifier}"

swift build \
  -c "$configuration" \
  --product Keyestro \
  --disable-keychain \
  --disable-netrc \
  --disable-sandbox

binary_path="$(swift build -c "$configuration" --show-bin-path)"
output_root="$project_root/build"
app_path="$output_root/Keyestro.app"
staging_path="$output_root/.Keyestro.app.$$.staging"
contents_path="$staging_path/Contents"

mkdir -p "$output_root"
rm -rf "$staging_path"
trap 'rm -rf "$staging_path"' EXIT
mkdir -p "$contents_path/MacOS" "$contents_path/Resources" "$contents_path/Frameworks"
cp "$binary_path/Keyestro" "$contents_path/MacOS/Keyestro"
cp "$project_root/Info.plist" "$contents_path/Info.plist"

plist="$contents_path/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_identifier" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${KEYESTRO_MARKETING_VERSION:-0.1.0}" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${KEYESTRO_BUILD_NUMBER:-1}" "$plist"
/usr/libexec/PlistBuddy -c "Set :KeyestroRuntimeStorageMode $runtime_storage_mode" "$plist"
/usr/libexec/PlistBuddy -c "Set :KeyestroCodeSignatureKind $code_signature_kind" "$plist"
if [[ -n "${KEYESTRO_APPCAST_URL:-}" && -n "${KEYESTRO_EDDSA_PUBLIC_KEY:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $KEYESTRO_APPCAST_URL" "$plist"
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $KEYESTRO_EDDSA_PUBLIC_KEY" "$plist"
fi

resource_bundle="$binary_path/Keyestro_KeyestroApp.bundle"
if [[ -d "$resource_bundle" ]]; then
  ditto "$resource_bundle" "$contents_path/Resources/Keyestro_KeyestroApp.bundle"
fi

string_catalog="$project_root/Sources/KeyestroApp/Resources/Localizable.xcstrings"
if [[ -f "$string_catalog" ]]; then
  xcrun xcstringstool compile "$string_catalog" --output-directory "$contents_path/Resources"
  packaged_resource_bundle="$contents_path/Resources/Keyestro_KeyestroApp.bundle"
  if [[ -d "$packaged_resource_bundle" ]]; then
    xcrun xcstringstool compile "$string_catalog" --output-directory "$packaged_resource_bundle"
  fi
fi

framework="$contents_path/Frameworks/Sparkle.framework"
if [[ -d "$binary_path/Sparkle.framework" ]]; then
  ditto "$binary_path/Sparkle.framework" "$framework"
fi

signing_args=(--force --sign "$signing_identity")
if [[ "$signing_identity" == "-" ]]; then
  signing_args+=(--timestamp=none)
elif [[ "$build_profile" == "production" ]]; then
  signing_args+=(--options runtime --timestamp)
else
  # Local permission testing needs a stable certificate identity, but never a
  # release timestamp or access to the production storage profile.
  signing_args+=(--options runtime --timestamp=none)
fi

sparkle_version="$framework/Versions/Current"
if [[ -d "$framework" ]]; then
  codesign $signing_args "$sparkle_version/Autoupdate"
  codesign $signing_args "$sparkle_version/XPCServices/Downloader.xpc"
  codesign $signing_args "$sparkle_version/XPCServices/Installer.xpc"
  codesign $signing_args "$sparkle_version/Updater.app"
  codesign $signing_args "$framework"
fi
codesign $signing_args --entitlements "$project_root/Keyestro.entitlements" "$staging_path"
codesign --verify --deep --strict --verbose=2 "$staging_path"
plutil -lint "$plist" >/dev/null

rm -rf "$app_path"
mv "$staging_path" "$app_path"
trap - EXIT
print "$app_path"
