#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
cd "$project_root"

configuration="${1:-debug}"
case "$configuration" in
  debug|release) ;;
  *) print -u2 "usage: $0 [debug|release]"; exit 64 ;;
esac

requested_identity="${KEYESTRO_LOCAL_CODE_SIGN_IDENTITY:-}"
if [[ -z "$requested_identity" || "$requested_identity" == "-" ]]; then
  print -u2 "KEYESTRO_LOCAL_CODE_SIGN_IDENTITY must explicitly name the correct signing identity."
  print -u2 "The script will not select an arbitrary certificate that may belong to another organization."
  print -u2 "List valid identities with: security find-identity -v -p codesigning"
  exit 69
fi

identity_line="$(security find-identity -v -p codesigning 2>/dev/null | awk -v requested="$requested_identity" '
  /^[[:space:]]*[0-9]+\)/ {
    fingerprint = $2
    description = $0
    sub(/^[^"]*"/, "", description)
    sub(/".*$/, "", description)
    if (fingerprint == requested || description == requested) {
      print
      exit
    }
  }
')"
if [[ -z "$identity_line" ]]; then
  print -u2 "The requested signing identity is not valid or is not available: $requested_identity"
  exit 69
fi

signing_identity="$(print -r -- "$identity_line" | awk '{ print $2 }')"
identity_description="$(print -r -- "$identity_line" | sed -E 's/^[^"]*"([^"]+)".*$/\1/')"
case "$identity_description" in
  "Apple Development:"*|"Mac Developer:"*) ;;
  *)
    print -u2 "Refusing non-development identity: $identity_description"
    print -u2 "Install and explicitly select an Apple Development certificate for the intended team."
    exit 69
    ;;
esac
print -u2 "Signing isolated local build with explicitly selected identity: $identity_description"

if pgrep -x Keyestro >/dev/null 2>&1; then
  print -u2 "Quit the running Keyestro app before replacing its signed bundle."
  exit 70
fi

print -u2 "macOS may ask for access to the certificate's private key."
KEYESTRO_BUILD_PROFILE=local \
KEYESTRO_CODE_SIGN_IDENTITY="$signing_identity" \
  "$project_root/scripts/build-app.sh" "$configuration"
