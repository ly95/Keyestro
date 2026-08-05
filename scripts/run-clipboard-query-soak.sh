#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
cd "$project_root"

duration="${KEYESTRO_SOAK_DURATION:-28800}"
sample_interval="${KEYESTRO_SOAK_SAMPLE_INTERVAL:-30}"
output="${1:-$project_root/build/reliability/clipboard-query-soak.json}"
if [[ "${KEYESTRO_SOAK_SKIP_BUILD:-0}" != "1" ]]; then
  scripts/build-app.sh release >/dev/null
fi

python3 scripts/run-clipboard-query-soak.py \
  --app "$project_root/build/Keyestro.app" \
  --duration "$duration" \
  --sample-interval "$sample_interval" \
  --output "$output" \
  --require-thresholds
