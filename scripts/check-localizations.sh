#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
cd "$project_root"

working_directory="$(mktemp -d)"
cleanup() {
  rm -rf "$working_directory"
}
trap cleanup EXIT

catalog="$working_directory/Localizable.xcstrings"
extracted="$working_directory/extracted"
extract_log="$working_directory/extract.log"
cp Sources/KeyestroApp/Resources/Localizable.xcstrings "$catalog"
mkdir "$extracted"

if ! rg --files -0 Sources/KeyestroApp -g '*.swift' |
  xargs -0 xcrun xcstringstool extract \
    --SwiftUI \
    --legacy-localizable-strings \
    -s text \
    -s format \
    --output-directory "$extracted" \
    >"$extract_log" 2>&1; then
  sed -n '1,160p' "$extract_log" >&2
  exit 1
fi

xcrun xcstringstool sync \
  "$catalog" \
  --stringsdata "$extracted"/*.stringsdata \
  --skip-marking-strings-stale

if ! cmp -s Sources/KeyestroApp/Resources/Localizable.xcstrings "$catalog"; then
  print -u2 "Localizable.xcstrings is out of sync with KeyestroApp sources."
  print -u2 "Extract and sync the String Catalog, then run merge-localizations.py --write."
  diff -u Sources/KeyestroApp/Resources/Localizable.xcstrings "$catalog" | sed -n '1,200p' >&2
  exit 1
fi

print "Localization source extraction verified"
