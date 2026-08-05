#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
cd "$project_root"

iterations="${KEYESTRO_UI_BENCHMARK_ITERATIONS:-30}"
case "$iterations" in
  <1-9>|<1-9><0-9>|100) ;;
  *) print -u2 "KEYESTRO_UI_BENCHMARK_ITERATIONS must be between 1 and 100."; exit 64 ;;
esac

output="${1:-$project_root/build/performance/ui-benchmarks.json}"
if [[ "${KEYESTRO_UI_BENCHMARK_SKIP_BUILD:-0}" != "1" ]]; then
  scripts/build-app.sh release >/dev/null
fi

python3 scripts/run-ui-performance-gate.py \
  --app "$project_root/build/Keyestro.app" \
  --iterations "$iterations" \
  --output "$output" \
  --require-thresholds
