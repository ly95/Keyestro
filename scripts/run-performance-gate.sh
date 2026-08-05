#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
cd "$project_root"

iterations="${KEYESTRO_BENCHMARK_ITERATIONS:-30}"
case "$iterations" in
  <1-9>|<1-9><0-9>|100) ;;
  *) print -u2 "KEYESTRO_BENCHMARK_ITERATIONS must be between 1 and 100."; exit 64 ;;
esac

output="${1:-$project_root/build/performance/core-benchmarks.json}"
mkdir -p "${output:h}"

swift run \
  -c release \
  --disable-keychain \
  --disable-netrc \
  --disable-sandbox \
  keyestro-benchmark \
  --iterations "$iterations" \
  --output "$output" \
  --require-thresholds

print "$output"
