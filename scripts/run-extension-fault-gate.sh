#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
cd "$project_root"
output="${1:-$project_root/build/security/extension-faults.json}"

python3 scripts/run-extension-fault-gate.py \
  --project-root "$project_root" \
  --output "$output"
