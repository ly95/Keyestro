#!/usr/bin/env python3
"""Measure RSS growth during the packaged eight-hour clipboard/query soak."""

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
import statistics
import subprocess
import sys
import tempfile
import time


RELEASE_DURATION_SECONDS = 8 * 60 * 60
MAXIMUM_GROWTH_PERCENT = 20.0


def executable_sha256(executable: Path) -> str:
    digest = hashlib.sha256()
    with executable.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def snapshot_rss(process_identifier: int) -> int:
    completed = subprocess.run(
        ["/bin/ps", "-p", str(process_identifier), "-o", "rss="],
        check=False,
        capture_output=True,
        text=True,
        timeout=5,
    )
    if completed.returncode != 0 or not completed.stdout.strip().isdigit():
        raise RuntimeError("packaged app exited before the soak completed")
    return int(completed.stdout.strip()) * 1024


def is_ad_hoc_signed(app: Path) -> bool:
    completed = subprocess.run(
        ["/usr/bin/codesign", "-d", "--verbose=4", str(app)],
        check=False,
        capture_output=True,
        text=True,
        timeout=10,
    )
    return "Signature=adhoc" in completed.stderr


def stop_process(process: subprocess.Popen[str]) -> None:
    if process.poll() is None:
        process.send_signal(signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
    process.communicate(timeout=5)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--duration", type=float, default=RELEASE_DURATION_SECONDS)
    parser.add_argument("--sample-interval", type=float, default=30.0)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--require-thresholds", action="store_true")
    args = parser.parse_args()
    if not 1 <= args.duration <= RELEASE_DURATION_SECONDS:
        parser.error("--duration must be between 1 and 28800 seconds")
    if not 0.25 <= args.sample_interval <= 300:
        parser.error("--sample-interval must be between 0.25 and 300 seconds")
    executable = args.app / "Contents" / "MacOS" / "Keyestro"
    if not executable.is_file() or not os.access(executable, os.X_OK):
        parser.error(f"packaged executable is unavailable: {executable}")

    process: subprocess.Popen[str] | None = None
    with tempfile.TemporaryDirectory(prefix="keyestro-clipboard-query-soak-") as temporary:
        ready_file = Path(temporary) / "ready.json"
        process = subprocess.Popen(
            [
                str(executable),
                "--clipboard-query-soak-test",
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
            deadline = time.monotonic() + 120
            while not ready_file.is_file():
                if process.poll() is not None:
                    stdout, stderr = process.communicate(timeout=5)
                    print((stderr or stdout)[-4_000:], file=sys.stderr)
                    return 1
                if time.monotonic() >= deadline:
                    print("Packaged soak readiness timed out", file=sys.stderr)
                    return 1
                time.sleep(0.1)
            marker = json.loads(ready_file.read_text(encoding="utf-8"))
            if (
                marker.get("schemaVersion") != 1
                or marker.get("processIdentifier") != process.pid
                or marker.get("clipboardEnabled") is not True
                or marker.get("clipboardItemCount") != 1_000
            ):
                print("Packaged soak emitted an invalid readiness marker", file=sys.stderr)
                return 1

            started_at = time.monotonic()
            samples = [{"elapsedSeconds": 0.0, "residentBytes": snapshot_rss(process.pid)}]
            while True:
                elapsed = time.monotonic() - started_at
                if elapsed >= args.duration:
                    break
                time.sleep(min(args.sample_interval, args.duration - elapsed))
                samples.append(
                    {
                        "elapsedSeconds": time.monotonic() - started_at,
                        "residentBytes": snapshot_rss(process.pid),
                    }
                )
            measured_duration = float(samples[-1]["elapsedSeconds"])
            baseline_rss = int(samples[0]["residentBytes"])
            tail = [int(sample["residentBytes"]) for sample in samples[-min(5, len(samples)) :]]
            final_rss = int(statistics.median(tail))
            maximum_rss = max(int(sample["residentBytes"]) for sample in samples)
            growth_percent = (final_rss - baseline_rss) / baseline_rss * 100
            passed = growth_percent <= MAXIMUM_GROWTH_PERCENT
            report = {
                "schemaVersion": 1,
                "generatedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
                "requirement": "reliability.clipboard-query-soak",
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
                    "requestedDurationSeconds": args.duration,
                    "measuredDurationSeconds": measured_duration,
                    "sampleIntervalSeconds": args.sample_interval,
                    "sampleCount": len(samples),
                    "clipboardItemCountAtBaseline": 1_000,
                    "queryIntervalSeconds": 1,
                    "baselineResidentBytes": baseline_rss,
                    "finalResidentBytes": final_rss,
                    "maximumResidentBytes": maximum_rss,
                    "rssGrowthPercent": growth_percent,
                    "maximumGrowthPercent": MAXIMUM_GROWTH_PERCENT,
                },
                "releaseEligible": measured_duration >= RELEASE_DURATION_SECONDS,
                "passed": passed,
            }
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            print(
                f"Clipboard/query soak: {measured_duration:.1f}s, RSS "
                f"{baseline_rss / (1024 * 1024):.2f} -> {final_rss / (1024 * 1024):.2f} MiB "
                f"({growth_percent:+.2f}%) {'PASS' if passed else 'FAIL'}"
            )
            if not report["releaseEligible"]:
                print("Short smoke only: release evidence requires an eight-hour measurement.")
            print(args.output)
            if args.require_thresholds and (not passed or not report["releaseEligible"]):
                return 2
            return 0
        finally:
            if process is not None:
                stop_process(process)


if __name__ == "__main__":
    raise SystemExit(main())
