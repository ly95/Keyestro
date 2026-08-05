#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
cd "$project_root"

zsh -n scripts/*.sh
plutil -lint Info.plist Keyestro.entitlements >/dev/null
python3 -m json.tool Sources/KeyestroApp/Resources/Localizable.xcstrings >/dev/null
python3 scripts/merge-localizations.py --check
scripts/check-localizations.sh
python3 scripts/test-release-evidence-validator.py
python3 scripts/generate-sbom.py --check
xcrun xcstringstool compile Sources/KeyestroApp/Resources/Localizable.xcstrings --output-directory "$(mktemp -d)" >/dev/null
swift format lint --strict --recursive Sources Tests Package.swift
swift package --disable-keychain --disable-netrc describe >/dev/null
swift package --disable-keychain --disable-netrc resolve
swift build --disable-keychain --disable-netrc --disable-sandbox -Xswiftc -warnings-as-errors
swift build -c release --disable-keychain --disable-netrc --disable-sandbox
# System-framework and hostile-child-process tests deliberately exercise shared
# process, Vision, pasteboard, and AppKit resources. Running every case at once
# can starve Vision and leave fixtures alive if the test runner is interrupted.
swift test --disable-keychain --disable-netrc --disable-sandbox --no-parallel -Xswiftc -warnings-as-errors
scripts/test-extension-examples.sh
scripts/build-app.sh release >/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' build/Keyestro.app/Contents/Info.plist)" == "com.keyestro.launcher.local" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :KeyestroRuntimeStorageMode' build/Keyestro.app/Contents/Info.plist)" == "ephemeral" ]]
codesign --verify --deep --strict --verbose=2 build/Keyestro.app
scripts/smoke-packaged-app.sh build/Keyestro.app

print "Keyestro checks passed"
