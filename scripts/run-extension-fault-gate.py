#!/usr/bin/env python3
"""Run the hostile-extension matrix as isolated real-process integration tests."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


SCENARIOS = [
    ("crash-loop-circuit-breaker", "threeExtensionCrashesOpenTheCircuitWithoutAutomaticRestart"),
    ("hung-search-process-group", "hangingExtensionSearchTimesOutAndTerminatesItsProcessGroup"),
    ("oversized-invalid-json-duplicate-ids", "hostileExtensionProtocolViolationsTerminateTheProcess"),
    ("managed-path-escape", "extensionManifestRejectsPathEscape"),
    ("infinite-log-stream", "infiniteExtensionLogsAreBoundedAndTerminateTheProcess"),
    ("ignored-cancel-process-group", "cancellingExtensionSearchTerminatesAnUnresponsiveProcessGroup"),
    ("ignored-shutdown-deadline", "ignoredExtensionShutdownMeetsDeadlineAndDoesNotCountAsACrash"),
    ("user-visible-recovery", "explicitHostileExtensionFailureIsPublishedAsARecoverableProviderStatus"),
]


def stop_process_group(process: subprocess.Popen[str]) -> tuple[int, str, str]:
    if process.poll() is None:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait(timeout=5)
    stdout, stderr = process.communicate(timeout=5)
    return process.returncode, stdout, stderr


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    project_root = args.project_root.resolve()
    if not (project_root / "Package.swift").is_file():
        parser.error(f"Package.swift is unavailable under {project_root}")

    results: list[dict[str, object]] = []
    for scenario, test_filter in SCENARIOS:
        started_at = time.monotonic()
        process = subprocess.Popen(
            [
                "swift",
                "test",
                "-c",
                "release",
                "--disable-keychain",
                "--disable-netrc",
                "--disable-sandbox",
                "--filter",
                test_filter,
            ],
            cwd=project_root,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        timed_out = False
        try:
            stdout, stderr = process.communicate(timeout=120)
        except subprocess.TimeoutExpired:
            timed_out = True
            _, stdout, stderr = stop_process_group(process)
        except BaseException:
            stop_process_group(process)
            raise
        combined_output = stdout + "\n" + stderr
        passed = process.returncode == 0 and not timed_out and "passed after" in combined_output
        results.append(
            {
                "scenario": scenario,
                "testFilter": test_filter,
                "durationSeconds": time.monotonic() - started_at,
                "exitCode": process.returncode,
                "timedOut": timed_out,
                "passMarkerObserved": "passed after" in combined_output,
                "passed": passed,
            }
        )
        print(f"{scenario}: {'PASS' if passed else 'FAIL'}")
        if not passed:
            print(combined_output[-4_000:], file=sys.stderr)

    passed = all(bool(result["passed"]) for result in results)
    report = {
        "schemaVersion": 1,
        "generatedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "requirementID": "PERF-011",
        "e2eScenario": "E2E-07",
        "configuration": "release",
        "realChildProcesses": True,
        "hostProcessCrashes": 0 if passed else None,
        "results": results,
        "passed": passed,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(args.output)
    return 0 if passed else 2


if __name__ == "__main__":
    raise SystemExit(main())
