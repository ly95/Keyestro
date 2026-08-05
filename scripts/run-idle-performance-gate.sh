#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
cd "$project_root"

duration="${KEYESTRO_IDLE_BENCHMARK_DURATION:-600}"
if ! [[ "$duration" =~ '^[0-9]+([.][0-9]+)?$' ]]; then
  print -u2 "KEYESTRO_IDLE_BENCHMARK_DURATION must be a number between 1 and 3600."
  exit 64
fi

output="${1:-$project_root/build/performance/idle-benchmarks.json}"
if [[ "${KEYESTRO_IDLE_BENCHMARK_SKIP_BUILD:-0}" != "1" ]]; then
  scripts/build-app.sh release >/dev/null
fi

python3 scripts/run-idle-performance-gate.py \
  --app "$project_root/build/Keyestro.app" \
  --duration "$duration" \
  --output "$output" \
  --require-thresholds
