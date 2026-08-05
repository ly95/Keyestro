#!/usr/bin/env python3
"""Regression tests for the cross-report release evidence validator."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile


PROJECT_ROOT = Path(__file__).resolve().parent.parent
VALIDATOR = PROJECT_ROOT / "scripts" / "verify-release-evidence.py"


def write_json(path: Path, value: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value), encoding="utf-8")


def write_plist(path: Path, value: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as destination:
        plistlib.dump(value, destination)


def measured_result(requirement_id: str) -> dict[str, object]:
    return {"requirementID": requirement_id, "sampleCount": 30, "passed": True}


def create_fixture(root: Path) -> tuple[Path, Path, str]:
    app = root / "Keyestro.app"
    executable = app / "Contents" / "MacOS" / "Keyestro"
    executable.parent.mkdir(parents=True)
    executable.write_bytes(b"release-evidence-validator-fixture")
    executable.chmod(0o700)
    write_plist(
        app / "Contents" / "Info.plist",
        {
            "CFBundleIdentifier": "com.keyestro.launcher.local",
            "KeyestroRuntimeStorageMode": "ephemeral",
        },
    )
    digest = hashlib.sha256(executable.read_bytes()).hexdigest()
    evidence = root / "evidence"
    release_environment = {"buildConfiguration": "release"}

    write_json(
        evidence / "performance" / "core-benchmarks.json",
        {
            "schemaVersion": 1,
            "iterations": 30,
            "environment": release_environment,
            "results": [
                measured_result(identifier)
                for identifier in ("PERF-004", "PERF-005", "PERF-009", "PERF-010")
            ],
        },
    )
    write_json(
        evidence / "performance" / "ui-benchmarks.json",
        {
            "schemaVersion": 1,
            "iterations": 30,
            "releaseEligible": True,
            "passed": True,
            "adHocSigned": True,
            "artifactExecutableSHA256": digest,
            "environment": release_environment,
            "results": [
                measured_result(identifier)
                for identifier in ("PERF-001", "PERF-002", "PERF-003", "PERF-005", "PERF-006")
            ],
        },
    )
    write_json(
        evidence / "performance" / "idle-benchmarks.json",
        {
            "schemaVersion": 1,
            "releaseEligible": True,
            "passed": True,
            "adHocSigned": True,
            "artifactExecutableSHA256": digest,
            "environment": release_environment,
            "measurement": {"measuredDurationSeconds": 600},
            "results": [measured_result("PERF-007"), measured_result("PERF-008")],
        },
    )
    write_json(
        evidence / "reliability" / "lifecycle-soak.json",
        {
            "schemaVersion": 1,
            "iterations": 10_000,
            "releaseEligible": True,
            "passed": True,
            "adHocSigned": True,
            "artifactExecutableSHA256": digest,
        },
    )
    write_json(
        evidence / "reliability" / "database-crash.json",
        {
            "schemaVersion": 1,
            "passed": True,
            "integrityCheckPassed": True,
            "writerKilledAsExpected": True,
            "committedItemCount": 1_000,
            "minimumExpectedItemCount": 1_000,
            "artifactExecutableSHA256": digest,
        },
    )
    write_json(
        evidence / "security" / "extension-faults.json",
        {
            "schemaVersion": 1,
            "configuration": "release",
            "passed": True,
            "hostProcessCrashes": 0,
            "results": [
                {"scenario": scenario, "passed": True}
                for scenario in (
                    "crash-loop-circuit-breaker",
                    "hung-search-process-group",
                    "oversized-invalid-json-duplicate-ids",
                    "managed-path-escape",
                    "infinite-log-stream",
                    "ignored-cancel-process-group",
                    "ignored-shutdown-deadline",
                    "user-visible-recovery",
                )
            ],
        },
    )
    return app, evidence, digest


def run_validator(app: Path, evidence: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            sys.executable,
            str(VALIDATOR),
            "--app",
            str(app),
            "--evidence-root",
            str(evidence),
            *arguments,
        ],
        check=False,
        capture_output=True,
        text=True,
        timeout=10,
    )


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="keyestro-release-evidence-test-") as temporary:
        app, evidence, digest = create_fixture(Path(temporary))
        valid = run_validator(app, evidence)
        if valid.returncode != 0:
            print(valid.stderr, file=sys.stderr)
            return 1

        missing_walkthrough = run_validator(app, evidence, "--include-ui-walkthrough")
        if missing_walkthrough.returncode != 2 or "missing report" not in missing_walkthrough.stderr:
            print("validator accepted missing UI walkthrough evidence", file=sys.stderr)
            return 1

        walkthrough_path = evidence / "ui-walkthrough.json"
        walkthrough = {
            "schemaVersion": 1,
            "passed": True,
            "artifactExecutableSHA256": digest,
            "environment": {"buildConfiguration": "release"},
            "checks": [
                {"id": identifier, "passed": True}
                for identifier in (
                    "onboarding",
                    "launcher-accessibility-tree",
                    "real-application-query",
                    "application-action-layer",
                    "settings-navigation",
                    "permission-disclosure",
                    "privacy-disclosure",
                    "about-metadata",
                    "normal-termination-cleanup",
                )
            ],
        }
        write_json(walkthrough_path, walkthrough)
        valid_walkthrough = run_validator(app, evidence, "--include-ui-walkthrough")
        if valid_walkthrough.returncode != 0:
            print(valid_walkthrough.stderr, file=sys.stderr)
            return 1

        walkthrough["artifactExecutableSHA256"] = "0" * len(digest)
        write_json(walkthrough_path, walkthrough)
        stale_walkthrough = run_validator(app, evidence, "--include-ui-walkthrough")
        if stale_walkthrough.returncode != 2 or "current app executable" not in stale_walkthrough.stderr:
            print("validator accepted a stale UI walkthrough hash", file=sys.stderr)
            return 1
        walkthrough["artifactExecutableSHA256"] = digest
        write_json(walkthrough_path, walkthrough)

        ui_path = evidence / "performance" / "ui-benchmarks.json"
        ui = json.loads(ui_path.read_text(encoding="utf-8"))
        ui["iterations"] = 1
        write_json(ui_path, ui)
        short = run_validator(app, evidence)
        if short.returncode != 2 or "fewer than 30 iterations" not in short.stderr:
            print("validator accepted a shortened UI report", file=sys.stderr)
            return 1

        ui["iterations"] = 30
        write_json(ui_path, ui)
        missing_soak = run_validator(app, evidence, "--include-soak")
        if missing_soak.returncode != 2 or "missing report" not in missing_soak.stderr:
            print("validator accepted missing eight-hour evidence", file=sys.stderr)
            return 1

        database_path = evidence / "reliability" / "database-crash.json"
        database = json.loads(database_path.read_text(encoding="utf-8"))
        database["artifactExecutableSHA256"] = "0" * len(digest)
        write_json(database_path, database)
        mismatch = run_validator(app, evidence)
        if mismatch.returncode != 2 or "current app executable" not in mismatch.stderr:
            print("validator accepted a mismatched app hash", file=sys.stderr)
            return 1

        database["artifactExecutableSHA256"] = digest
        write_json(database_path, database)
        info_path = app / "Contents" / "Info.plist"
        write_plist(
            info_path,
            {
                "CFBundleIdentifier": "com.keyestro.launcher.local",
                "KeyestroRuntimeStorageMode": "keychain",
            },
        )
        persistent_local = run_validator(app, evidence)
        if persistent_local.returncode != 2 or "ephemeral runtime storage mode" not in persistent_local.stderr:
            print("validator accepted a local app configured for persistent Keychain access", file=sys.stderr)
            return 1

        write_plist(
            info_path,
            {
                "CFBundleIdentifier": "com.keyestro.launcher",
                "KeyestroRuntimeStorageMode": "ephemeral",
            },
        )
        production_identifier = run_validator(app, evidence)
        if production_identifier.returncode != 2 or "isolated local bundle identifier" not in production_identifier.stderr:
            print("validator accepted a local app with the production bundle identifier", file=sys.stderr)
            return 1

    print("Automated release evidence validator regression tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
