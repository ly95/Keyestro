#!/usr/bin/env python3
"""Launch the packaged app repeatedly and aggregate UI performance percentiles."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time


def percentile(fraction: float, values: list[float]) -> float:
    ordered = sorted(values)
    rank = max(1, math.ceil(fraction * len(ordered)))
    return ordered[min(rank - 1, len(ordered) - 1)]


def executable_sha256(executable: Path) -> str:
    digest = hashlib.sha256()
    with executable.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def is_ad_hoc_signed(app: Path) -> bool:
    completed = subprocess.run(
        ["/usr/bin/codesign", "-d", "--verbose=4", str(app)],
        check=False,
        capture_output=True,
        text=True,
        timeout=10,
    )
    return "Signature=adhoc" in completed.stderr


def stop_process(process: subprocess.Popen[str]) -> tuple[int, str, str]:
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
    stdout, stderr = process.communicate(timeout=5)
    return process.returncode, stdout, stderr


def result(
    requirement_id: str,
    identifier: str,
    samples: list[float],
    *,
    p50_threshold: float | None = None,
    p95_threshold: float | None = None,
    maximum_threshold: float | None = None,
) -> dict[str, object]:
    p50 = percentile(0.50, samples)
    p95 = percentile(0.95, samples)
    maximum = max(samples)
    passed = True
    if p50_threshold is not None:
        passed = passed and p50 <= p50_threshold
    if p95_threshold is not None:
        passed = passed and p95 <= p95_threshold
    if maximum_threshold is not None:
        passed = passed and maximum <= maximum_threshold
    return {
        "id": identifier,
        "requirementID": requirement_id,
        "sampleCount": len(samples),
        "p50Milliseconds": p50,
        "p95Milliseconds": p95,
        "maximumMilliseconds": maximum,
        "p50ThresholdMilliseconds": p50_threshold,
        "p95ThresholdMilliseconds": p95_threshold,
        "maximumThresholdMilliseconds": maximum_threshold,
        "passed": passed,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--iterations", type=int, default=30)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--require-thresholds", action="store_true")
    args = parser.parse_args()
    if not 1 <= args.iterations <= 100:
        parser.error("--iterations must be between 1 and 100")
    executable = args.app / "Contents" / "MacOS" / "Keyestro"
    if not executable.is_file() or not os.access(executable, os.X_OK):
        parser.error(f"packaged executable is unavailable: {executable}")

    cold: list[float] = []
    hot: list[float] = []
    cached: list[float] = []
    input_to_ui: list[float] = []
    main_segments: list[float] = []
    environment: dict[str, object] | None = None
    with tempfile.TemporaryDirectory(prefix="keyestro-ui-performance-") as temporary:
        temporary_root = Path(temporary)
        for iteration in range(args.iterations):
            run_output = temporary_root / f"run-{iteration:03d}.json"
            process_environment = os.environ.copy()
            process_environment["KEYESTRO_BENCHMARK_LAUNCHED_AT"] = format(time.monotonic(), ".9f")
            process = subprocess.Popen(
                [
                    str(executable),
                    "--ui-performance-test",
                    "--iterations",
                    "1",
                    "--output",
                    str(run_output),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env=process_environment,
            )
            try:
                stdout, stderr = process.communicate(timeout=15)
            except subprocess.TimeoutExpired:
                stop_process(process)
                print(f"UI performance run {iteration + 1} timed out", file=sys.stderr)
                return 1
            except BaseException:
                stop_process(process)
                raise
            if process.returncode != 0 or not run_output.is_file():
                print(f"UI performance run {iteration + 1} failed", file=sys.stderr)
                print((stderr or stdout)[:2_000], file=sys.stderr)
                return 1
            payload = json.loads(run_output.read_text(encoding="utf-8"))
            if payload.get("schemaVersion") != 1:
                print("Unsupported packaged UI performance report", file=sys.stderr)
                return 1
            environment = environment or payload["environment"]
            samples = payload["samples"]
            cold.extend(float(value) for value in samples["coldStartMilliseconds"])
            hot.extend(float(value) for value in samples["hotInvocationMilliseconds"])
            cached.extend(float(value) for value in samples["cachedFirstBatchMilliseconds"])
            input_to_ui.extend(float(value) for value in samples["inputToRenderedUIMilliseconds"])
            main_segments.extend(float(value) for value in samples["mainThreadSegmentMilliseconds"])

    results = [
        result("PERF-001", "packaged-hot-invocation", hot, p50_threshold=50, p95_threshold=100),
        result("PERF-002", "packaged-cold-start", cold, p95_threshold=400),
        result("PERF-003", "packaged-cached-first-batch", cached, p95_threshold=50),
        result("PERF-005", "packaged-input-to-rendered-ui", input_to_ui, p95_threshold=100),
        result("PERF-006", "packaged-main-thread-segment", main_segments, maximum_threshold=16),
    ]
    report = {
        "schemaVersion": 1,
        "generatedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "iterations": args.iterations,
        "environment": environment,
        "artifact": str(args.app.resolve()),
        "artifactExecutableSHA256": executable_sha256(executable),
        "adHocSigned": is_ad_hoc_signed(args.app),
        "results": results,
        "releaseEligible": args.iterations >= 30,
        "passed": all(bool(value["passed"]) for value in results),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    for value in results:
        print(
            f"{value['requirementID']} {value['id']}: "
            f"p50={value['p50Milliseconds']:.2f}ms "
            f"p95={value['p95Milliseconds']:.2f}ms "
            f"max={value['maximumMilliseconds']:.2f}ms "
            f"{'PASS' if value['passed'] else 'FAIL'}"
        )
    print(args.output)
    if not report["releaseEligible"]:
        print("Short smoke only: release evidence requires at least 30 iterations.")
    if args.require_thresholds and (not report["passed"] or not report["releaseEligible"]):
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
