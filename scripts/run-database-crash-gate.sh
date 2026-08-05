#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
cd "$project_root"
output="${1:-$project_root/build/reliability/database-crash.json}"

if [[ "${KEYESTRO_DATABASE_CRASH_SKIP_BUILD:-0}" != "1" ]]; then
  scripts/build-app.sh release >/dev/null
fi
python3 scripts/run-database-crash-gate.py \
  --app "$project_root/build/Keyestro.app" \
  --output "$output"
