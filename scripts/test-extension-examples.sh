#!/bin/sh
set -eu

REPOSITORY_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$REPOSITORY_ROOT"

swift build --disable-keychain --disable-netrc --product launcher-extension-test
swift build --disable-keychain --disable-netrc --product keyestro-swift-extension-example

HARNESS="$REPOSITORY_ROOT/.build/debug/launcher-extension-test"
PYTHON_EXAMPLE="$REPOSITORY_ROOT/Examples/Extensions/PythonExample.extension"

"$HARNESS" validate "$PYTHON_EXAMPLE"
"$HARNESS" run "$PYTHON_EXAMPLE" --query repo
"$HARNESS" fuzz-framing "$PYTHON_EXAMPLE"

TEMPORARY_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/keyestro-extension-contract.XXXXXX")
trap 'rm -rf "$TEMPORARY_ROOT"' EXIT INT TERM
SWIFT_PACKAGE="$TEMPORARY_ROOT/SwiftExample.extension"
mkdir -p "$SWIFT_PACKAGE/bin"
cp "$REPOSITORY_ROOT/Examples/Extensions/SwiftExample/extension.json" "$SWIFT_PACKAGE/extension.json"
cp "$REPOSITORY_ROOT/.build/debug/keyestro-swift-extension-example" "$SWIFT_PACKAGE/bin/extension"
chmod 700 "$SWIFT_PACKAGE/bin/extension"

"$HARNESS" validate "$SWIFT_PACKAGE"
"$HARNESS" run "$SWIFT_PACKAGE" --query actor
"$HARNESS" fuzz-framing "$SWIFT_PACKAGE"
