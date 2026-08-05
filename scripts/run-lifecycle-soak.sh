#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
cd "$project_root"

iterations="${KEYESTRO_LIFECYCLE_ITERATIONS:-10000}"
case "$iterations" in
  <1-9>|<1-9><0-9>|<1-9><0-9><0-9>|<1-9><0-9><0-9><0-9>|10000) ;;
  *) print -u2 "KEYESTRO_LIFECYCLE_ITERATIONS must be between 1 and 10000."; exit 64 ;;
esac

output="${1:-$project_root/build/reliability/lifecycle-soak.json}"
if [[ "${KEYESTRO_LIFECYCLE_SKIP_BUILD:-0}" != "1" ]]; then
  scripts/build-app.sh release >/dev/null
fi

"$project_root/build/Keyestro.app/Contents/MacOS/Keyestro" \
  --lifecycle-soak-test \
  --iterations "$iterations" \
  --output "$output"

python3 - "$output" <<'PY'
import hashlib
import json
import pathlib
import subprocess
import sys

path = pathlib.Path(sys.argv[1])
report = json.loads(path.read_text(encoding="utf-8"))
app = pathlib.Path.cwd() / "build" / "Keyestro.app"
executable = app / "Contents" / "MacOS" / "Keyestro"
digest = hashlib.sha256()
with executable.open("rb") as source:
    for chunk in iter(lambda: source.read(1024 * 1024), b""):
        digest.update(chunk)
signature = subprocess.run(
    ["/usr/bin/codesign", "-d", "--verbose=4", str(app)],
    check=False,
    capture_output=True,
    text=True,
    timeout=10,
)
report["artifact"] = str(app.resolve())
report["artifactExecutableSHA256"] = digest.hexdigest()
report["adHocSigned"] = "Signature=adhoc" in signature.stderr
path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
if report.get("schemaVersion") != 1 or report.get("passed") is not True:
    raise SystemExit("Lifecycle soak report failed")
print(
    f"Lifecycle soak: {report['iterations']} cycles in {report['elapsedSeconds']:.2f}s, "
    f"windows initial/baseline/max/final={report['initialWindowCount']}/"
    f"{report.get('baselineWindowCount', report['initialWindowCount'])}/"
    f"{report['maximumWindowCount']}/{report['finalWindowCount']} PASS"
)
if not report.get("releaseEligible"):
    print("Short smoke only: release evidence requires exactly 10,000 cycles.")
    raise SystemExit(2)
print(path)
PY
