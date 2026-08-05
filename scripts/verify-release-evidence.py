#!/usr/bin/env python3
"""Validate that release-gate reports are complete and belong to one app artifact."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
from typing import Any


REQUIRED_CORE_RESULTS = {"PERF-004", "PERF-005", "PERF-009", "PERF-010"}
REQUIRED_UI_RESULTS = {"PERF-001", "PERF-002", "PERF-003", "PERF-005", "PERF-006"}
REQUIRED_IDLE_RESULTS = {"PERF-007", "PERF-008"}
REQUIRED_EXTENSION_SCENARIOS = {
    "crash-loop-circuit-breaker",
    "hung-search-process-group",
    "oversized-invalid-json-duplicate-ids",
    "managed-path-escape",
    "infinite-log-stream",
    "ignored-cancel-process-group",
    "ignored-shutdown-deadline",
    "user-visible-recovery",
}
REQUIRED_UI_WALKTHROUGH_CHECKS = {
    "onboarding",
    "launcher-accessibility-tree",
    "real-application-query",
    "application-action-layer",
    "settings-navigation",
    "permission-disclosure",
    "privacy-disclosure",
    "about-metadata",
    "normal-termination-cleanup",
}
LOCAL_BUNDLE_IDENTIFIER = "com.keyestro.launcher.local"
RUNTIME_STORAGE_KEY = "KeyestroRuntimeStorageMode"


def executable_sha256(executable: Path) -> str:
    digest = hashlib.sha256()
    with executable.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_report(path: Path, errors: list[str]) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        errors.append(f"missing report: {path}")
        return {}
    except (OSError, json.JSONDecodeError) as error:
        errors.append(f"invalid report {path}: {error}")
        return {}
    if not isinstance(value, dict):
        errors.append(f"report root must be an object: {path}")
        return {}
    if value.get("schemaVersion") != 1:
        errors.append(f"unsupported report schema: {path}")
    return value


def read_app_info(app: Path, errors: list[str]) -> dict[str, Any]:
    path = app / "Contents" / "Info.plist"
    try:
        with path.open("rb") as source:
            value = plistlib.load(source)
    except FileNotFoundError:
        errors.append(f"missing app metadata: {path}")
        return {}
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        errors.append(f"invalid app metadata {path}: {error}")
        return {}
    if not isinstance(value, dict):
        errors.append(f"app metadata root must be a dictionary: {path}")
        return {}
    return value


def require(condition: bool, message: str, errors: list[str]) -> None:
    if not condition:
        errors.append(message)


def integer_at_least(value: object, minimum: int) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= minimum


def result_map(report: dict[str, Any]) -> dict[str, dict[str, Any]]:
    output: dict[str, dict[str, Any]] = {}
    results = report.get("results")
    if not isinstance(results, list):
        return output
    for value in results:
        if not isinstance(value, dict):
            continue
        identifier = value.get("requirementID")
        if isinstance(identifier, str):
            output[identifier] = value
    return output


def validate_result_set(
    name: str,
    report: dict[str, Any],
    required_ids: set[str],
    minimum_samples: int,
    errors: list[str],
) -> None:
    results = result_map(report)
    require(required_ids <= results.keys(), f"{name} is missing required results", errors)
    for identifier in sorted(required_ids):
        value = results.get(identifier, {})
        require(value.get("passed") is True, f"{name} {identifier} did not pass", errors)
        if minimum_samples:
            count = value.get("sampleCount")
            require(
                isinstance(count, int) and count >= minimum_samples,
                f"{name} {identifier} has fewer than {minimum_samples} samples",
                errors,
            )


def validate_artifact_hash(
    name: str,
    report: dict[str, Any],
    expected_hash: str,
    errors: list[str],
) -> None:
    require(
        report.get("artifactExecutableSHA256") == expected_hash,
        f"{name} does not describe the current app executable",
        errors,
    )


def validate_release_environment(name: str, report: dict[str, Any], errors: list[str]) -> None:
    environment = report.get("environment")
    require(
        isinstance(environment, dict) and environment.get("buildConfiguration") == "release",
        f"{name} was not captured from a Release configuration",
        errors,
    )


def validate_production_signature(app: Path, errors: list[str]) -> None:
    verification = subprocess.run(
        ["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)],
        check=False,
        capture_output=True,
        text=True,
        timeout=30,
    )
    require(verification.returncode == 0, "production app code-signature verification failed", errors)
    description = subprocess.run(
        ["/usr/bin/codesign", "-d", "--verbose=4", str(app)],
        check=False,
        capture_output=True,
        text=True,
        timeout=30,
    )
    details = description.stderr
    require(description.returncode == 0, "production app signature could not be described", errors)
    require("Signature=adhoc" not in details, "production app is ad-hoc signed", errors)
    require("Authority=Developer ID Application:" in details, "production app lacks Developer ID Application authority", errors)
    require("flags=" in details and "runtime" in details, "production app lacks Hardened Runtime", errors)
    require("\nTimestamp=" in details, "production app lacks a secure signing timestamp", errors)


def main() -> int:
    project_root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, default=project_root / "build" / "Keyestro.app")
    parser.add_argument("--evidence-root", type=Path, default=project_root / "build")
    parser.add_argument("--include-soak", action="store_true")
    parser.add_argument("--include-ui-walkthrough", action="store_true")
    parser.add_argument("--require-production-signature", action="store_true")
    args = parser.parse_args()

    app = args.app.resolve()
    executable = app / "Contents" / "MacOS" / "Keyestro"
    if not executable.is_file() or not os.access(executable, os.X_OK):
        print(f"release evidence error: packaged executable is unavailable: {executable}", file=sys.stderr)
        return 2
    expected_hash = executable_sha256(executable)
    errors: list[str] = []
    root = args.evidence_root.resolve()
    app_info = read_app_info(app, errors)

    if args.require_production_signature:
        bundle_identifier = app_info.get("CFBundleIdentifier")
        require(
            isinstance(bundle_identifier, str)
            and bool(bundle_identifier)
            and bundle_identifier != LOCAL_BUNDLE_IDENTIFIER,
            "production app must not use the isolated local bundle identifier",
            errors,
        )
        require(
            app_info.get(RUNTIME_STORAGE_KEY) == "keychain",
            "production app must use the persistent Keychain runtime storage mode",
            errors,
        )
    else:
        require(
            app_info.get("CFBundleIdentifier") == LOCAL_BUNDLE_IDENTIFIER,
            "local app must use the isolated local bundle identifier",
            errors,
        )
        require(
            app_info.get(RUNTIME_STORAGE_KEY) == "ephemeral",
            "local app must use the ephemeral runtime storage mode",
            errors,
        )

    core = read_report(root / "performance" / "core-benchmarks.json", errors)
    require(integer_at_least(core.get("iterations"), 30), "core benchmark has fewer than 30 iterations", errors)
    validate_result_set("core benchmark", core, REQUIRED_CORE_RESULTS, 30, errors)
    validate_release_environment("core benchmark", core, errors)

    ui = read_report(root / "performance" / "ui-benchmarks.json", errors)
    require(ui.get("passed") is True, "packaged UI benchmark did not pass", errors)
    require(integer_at_least(ui.get("iterations"), 30), "packaged UI benchmark has fewer than 30 iterations", errors)
    require(ui.get("releaseEligible") is True, "packaged UI benchmark is not release eligible", errors)
    validate_result_set("packaged UI benchmark", ui, REQUIRED_UI_RESULTS, 30, errors)
    validate_artifact_hash("packaged UI benchmark", ui, expected_hash, errors)
    validate_release_environment("packaged UI benchmark", ui, errors)

    idle = read_report(root / "performance" / "idle-benchmarks.json", errors)
    require(idle.get("passed") is True, "idle benchmark did not pass", errors)
    require(idle.get("releaseEligible") is True, "idle benchmark is not release eligible", errors)
    measured_idle = idle.get("measurement", {}).get("measuredDurationSeconds") if isinstance(idle.get("measurement"), dict) else None
    require(isinstance(measured_idle, (int, float)) and measured_idle >= 600, "idle benchmark measured less than 600 seconds", errors)
    validate_result_set("idle benchmark", idle, REQUIRED_IDLE_RESULTS, 0, errors)
    validate_artifact_hash("idle benchmark", idle, expected_hash, errors)
    validate_release_environment("idle benchmark", idle, errors)

    lifecycle = read_report(root / "reliability" / "lifecycle-soak.json", errors)
    require(lifecycle.get("passed") is True, "lifecycle soak did not pass", errors)
    require(lifecycle.get("releaseEligible") is True, "lifecycle soak is not release eligible", errors)
    require(lifecycle.get("iterations") == 10_000, "lifecycle soak did not run exactly 10,000 cycles", errors)
    validate_artifact_hash("lifecycle soak", lifecycle, expected_hash, errors)

    database = read_report(root / "reliability" / "database-crash.json", errors)
    require(database.get("passed") is True, "database crash gate did not pass", errors)
    require(database.get("integrityCheckPassed") is True, "database integrity check did not pass", errors)
    require(database.get("writerKilledAsExpected") is True, "database writer was not killed as expected", errors)
    committed = database.get("committedItemCount")
    minimum = database.get("minimumExpectedItemCount")
    require(
        isinstance(committed, int) and isinstance(minimum, int) and committed >= minimum,
        "database crash gate did not read back enough committed rows",
        errors,
    )
    validate_artifact_hash("database crash gate", database, expected_hash, errors)

    extensions = read_report(root / "security" / "extension-faults.json", errors)
    require(extensions.get("passed") is True, "hostile-extension gate did not pass", errors)
    require(extensions.get("configuration") == "release", "hostile-extension gate was not run in Release", errors)
    require(extensions.get("hostProcessCrashes") == 0, "hostile-extension gate recorded a host crash", errors)
    scenarios = {
        value.get("scenario")
        for value in extensions.get("results", [])
        if isinstance(value, dict) and value.get("passed") is True
    }
    require(
        REQUIRED_EXTENSION_SCENARIOS <= scenarios,
        "hostile-extension gate is missing a required passing scenario",
        errors,
    )

    if args.include_soak:
        soak = read_report(root / "reliability" / "clipboard-query-soak.json", errors)
        require(soak.get("passed") is True, "clipboard/query soak did not pass", errors)
        require(soak.get("releaseEligible") is True, "clipboard/query soak is not release eligible", errors)
        measured_soak = soak.get("measurement", {}).get("measuredDurationSeconds") if isinstance(soak.get("measurement"), dict) else None
        require(isinstance(measured_soak, (int, float)) and measured_soak >= 28_800, "clipboard/query soak measured less than 28,800 seconds", errors)
        validate_artifact_hash("clipboard/query soak", soak, expected_hash, errors)
        validate_release_environment("clipboard/query soak", soak, errors)

    if args.include_ui_walkthrough:
        walkthrough = read_report(root / "ui-walkthrough.json", errors)
        require(walkthrough.get("passed") is True, "UI walkthrough did not pass", errors)
        validate_artifact_hash("UI walkthrough", walkthrough, expected_hash, errors)
        validate_release_environment("UI walkthrough", walkthrough, errors)
        walkthrough_checks = {
            value.get("id")
            for value in walkthrough.get("checks", [])
            if isinstance(value, dict) and value.get("passed") is True
        }
        require(
            REQUIRED_UI_WALKTHROUGH_CHECKS <= walkthrough_checks,
            "UI walkthrough is missing a required passing check",
            errors,
        )

    if args.require_production_signature:
        validate_production_signature(app, errors)
        for name, report in (
            ("packaged UI benchmark", ui),
            ("idle benchmark", idle),
            ("lifecycle soak", lifecycle),
        ):
            require(report.get("adHocSigned") is False, f"{name} was captured from an ad-hoc app", errors)
        if args.include_soak:
            require(soak.get("adHocSigned") is False, "clipboard/query soak was captured from an ad-hoc app", errors)

    if errors:
        for error in errors:
            print(f"release evidence error: {error}", file=sys.stderr)
        return 2
    signature = "production" if args.require_production_signature else "local"
    soak_state = "with 8-hour soak" if args.include_soak else "without 8-hour soak"
    walkthrough_state = "with UI walkthrough" if args.include_ui_walkthrough else "without UI walkthrough"
    print(
        f"Automated release evidence bundle PASS "
        f"({signature}, {soak_state}, {walkthrough_state}, executable SHA-256 {expected_hash})."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
