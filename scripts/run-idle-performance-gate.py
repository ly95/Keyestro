#!/usr/bin/env python3
"""Measure idle CPU and RSS of the packaged app with clipboard monitoring enabled."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import signal
import subprocess
import sys
import tempfile
import time


CPU_THRESHOLD_PERCENT = 0.5
RSS_THRESHOLD_BYTES = 120 * 1024 * 1024
RELEASE_DURATION_SECONDS = 600.0


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


def parse_cpu_time(value: str) -> float:
    day_count = 0
    clock = value.strip()
    if "-" in clock:
        days, clock = clock.split("-", 1)
        day_count = int(days)
    parts = clock.split(":")
    if len(parts) == 3:
        hours, minutes, seconds = parts
    elif len(parts) == 2:
        hours = "0"
        minutes, seconds = parts
    else:
        raise ValueError(f"unexpected process CPU time: {value!r}")
    return day_count * 86_400 + int(hours) * 3_600 + int(minutes) * 60 + float(seconds)


def process_snapshot(process_identifier: int) -> tuple[float, int]:
    completed = subprocess.run(
        ["/bin/ps", "-p", str(process_identifier), "-o", "time=", "-o", "rss="],
        check=False,
        capture_output=True,
        text=True,
        timeout=5,
    )
    fields = completed.stdout.split()
    if completed.returncode != 0 or len(fields) != 2:
        raise RuntimeError("packaged app exited before the measurement completed")
    return parse_cpu_time(fields[0]), int(fields[1]) * 1024


def stop_process(process: subprocess.Popen[str]) -> tuple[int, str, str]:
    if process.poll() is None:
        process.send_signal(signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
    stdout, stderr = process.communicate(timeout=5)
    return process.returncode, stdout, stderr


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--duration", type=float, default=RELEASE_DURATION_SECONDS)
    parser.add_argument("--sample-interval", type=float, default=1.0)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--require-thresholds", action="store_true")
    args = parser.parse_args()
    if not 1 <= args.duration <= 3_600:
        parser.error("--duration must be between 1 and 3600 seconds")
    if not 0.25 <= args.sample_interval <= 10:
        parser.error("--sample-interval must be between 0.25 and 10 seconds")
    executable = args.app / "Contents" / "MacOS" / "Keyestro"
    if not executable.is_file() or not os.access(executable, os.X_OK):
        parser.error(f"packaged executable is unavailable: {executable}")

    process: subprocess.Popen[str] | None = None
    with tempfile.TemporaryDirectory(prefix="keyestro-idle-performance-") as temporary:
        ready_file = Path(temporary) / "ready.json"
        process = subprocess.Popen(
            [
                str(executable),
                "--idle-performance-test",
                "--duration",
                str(math.ceil(args.duration) + 15),
                "--ready-file",
                str(ready_file),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            ready_deadline = time.monotonic() + 30
            while not ready_file.is_file():
                if process.poll() is not None:
                    _, stdout, stderr = stop_process(process)
                    print("Packaged idle harness exited before readiness", file=sys.stderr)
                    print((stderr or stdout)[:2_000], file=sys.stderr)
                    return 1
                if time.monotonic() >= ready_deadline:
                    print("Packaged idle harness readiness timed out", file=sys.stderr)
                    return 1
                time.sleep(0.05)
            marker = json.loads(ready_file.read_text(encoding="utf-8"))
            if (
                marker.get("schemaVersion") != 1
                or marker.get("processIdentifier") != process.pid
                or marker.get("clipboardEnabled") is not True
                or marker.get("clipboardStoreState") != "ready"
            ):
                print("Packaged idle harness emitted an invalid readiness marker", file=sys.stderr)
                return 1

            cpu_baseline, initial_rss = process_snapshot(process.pid)
            samples: list[dict[str, float | int]] = [
                {"elapsedSeconds": 0.0, "cpuSeconds": cpu_baseline, "residentBytes": initial_rss}
            ]
            measurement_started_at = time.monotonic()
            while True:
                elapsed = time.monotonic() - measurement_started_at
                if elapsed >= args.duration:
                    break
                time.sleep(min(args.sample_interval, args.duration - elapsed))
                cpu_seconds, resident_bytes = process_snapshot(process.pid)
                samples.append(
                    {
                        "elapsedSeconds": time.monotonic() - measurement_started_at,
                        "cpuSeconds": cpu_seconds,
                        "residentBytes": resident_bytes,
                    }
                )
            measured_duration = float(samples[-1]["elapsedSeconds"])
            cpu_delta = max(0.0, float(samples[-1]["cpuSeconds"]) - cpu_baseline)
            average_cpu_percent = cpu_delta / measured_duration * 100
            rss_values = [float(sample["residentBytes"]) for sample in samples]
            maximum_rss = int(max(rss_values))
            cpu_passed = average_cpu_percent < CPU_THRESHOLD_PERCENT
            rss_passed = maximum_rss < RSS_THRESHOLD_BYTES
            release_eligible = measured_duration >= RELEASE_DURATION_SECONDS
            report = {
                "schemaVersion": 1,
                "generatedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
                "artifact": str(args.app.resolve()),
                "artifactExecutableSHA256": executable_sha256(executable),
                "adHocSigned": is_ad_hoc_signed(args.app),
                "environment": {
                    "operatingSystem": platform.platform(),
                    "architecture": platform.machine(),
                    "physicalMemoryBytes": int(os.sysconf("SC_PHYS_PAGES") * os.sysconf("SC_PAGE_SIZE")),
                    "buildConfiguration": "release",
                },
                "measurement": {
                    "clipboardEnabled": True,
                    "clipboardStoreState": "ready",
                    "requestedDurationSeconds": args.duration,
                    "measuredDurationSeconds": measured_duration,
                    "sampleIntervalSeconds": args.sample_interval,
                    "sampleCount": len(samples),
                    "cpuTimePrecisionSeconds": 0.01,
                },
                "results": [
                    {
                        "id": "packaged-core-idle-cpu",
                        "requirementID": "PERF-007",
                        "averageCPUPercent": average_cpu_percent,
                        "cpuSeconds": cpu_delta,
                        "thresholdExclusivePercent": CPU_THRESHOLD_PERCENT,
                        "passed": cpu_passed,
                    },
                    {
                        "id": "packaged-core-idle-rss",
                        "requirementID": "PERF-008",
                        "p50ResidentBytes": int(percentile(0.50, rss_values)),
                        "p95ResidentBytes": int(percentile(0.95, rss_values)),
                        "maximumResidentBytes": maximum_rss,
                        "maximumResidentMiB": maximum_rss / (1024 * 1024),
                        "thresholdExclusiveBytes": RSS_THRESHOLD_BYTES,
                        "passed": rss_passed,
                    },
                ],
                "releaseEligible": release_eligible,
                "passed": cpu_passed and rss_passed,
            }
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            print(
                f"PERF-007 packaged-core-idle-cpu: {average_cpu_percent:.3f}% "
                f"over {measured_duration:.1f}s {'PASS' if cpu_passed else 'FAIL'}"
            )
            print(
                f"PERF-008 packaged-core-idle-rss: max={maximum_rss / (1024 * 1024):.2f}MiB "
                f"{'PASS' if rss_passed else 'FAIL'}"
            )
            if not release_eligible:
                print("Short smoke only: PERF-007 requires a 600-second measurement.")
            print(args.output)
            if args.require_thresholds and (not report["passed"] or not report["releaseEligible"]):
                return 2
            return 0
        finally:
            if process is not None:
                _, stdout, stderr = stop_process(process)
                if stderr:
                    print(stderr[:2_000], file=sys.stderr)


if __name__ == "__main__":
    raise SystemExit(main())
