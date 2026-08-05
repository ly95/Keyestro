#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
app_path="${1:-$project_root/build/Keyestro.app}"
executable="$app_path/Contents/MacOS/Keyestro"

if [[ ! -x "$executable" ]]; then
  print -u2 "Packaged Keyestro executable is unavailable: $executable"
  exit 66
fi

output_file="$(mktemp)"
error_file="$(mktemp)"
cleanup() {
  rm -f "$output_file" "$error_file"
}
trap cleanup EXIT

run_smoke() {
  local mode="$1"
  local expected="$2"
  "$executable" "$mode" >"$output_file" 2>"$error_file" &
  local smoke_pid=$!
  (
    sleep 10
    kill -TERM "$smoke_pid" 2>/dev/null || true
  ) &
  local watchdog_pid=$!

  local smoke_status=0
  wait "$smoke_pid" || smoke_status=$?
  kill -TERM "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true

  if [[ $smoke_status -ne 0 ]]; then
    print -u2 "Packaged app smoke test failed or timed out in $mode (status $smoke_status)."
    sed -n '1,80p' "$error_file" >&2
    exit 1
  fi
  grep -Fxq "$expected" "$output_file"
}

run_smoke --smoke-test "Keyestro packaged-app smoke test passed"
run_smoke --ui-smoke-test "Keyestro packaged UI smoke test passed"
print "Keyestro packaged-app smoke tests passed"
