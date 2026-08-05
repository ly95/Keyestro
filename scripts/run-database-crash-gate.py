#!/usr/bin/env python3
"""SIGKILL a busy packaged writer and verify committed SQLite data on restart."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    executable = args.app / "Contents" / "MacOS" / "Keyestro"
    if not executable.is_file() or not os.access(executable, os.X_OK):
        parser.error(f"packaged executable is unavailable: {executable}")

    with tempfile.TemporaryDirectory(prefix="keyestro-database-crash-") as temporary:
        root = Path(temporary) / "owned-data"
        ready = Path(temporary) / "writer-ready.json"
        readback = Path(temporary) / "readback.json"
        writer = subprocess.Popen(
            [str(executable), "--database-crash-writer", "--root", str(root), "--ready-file", str(ready)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        deadline = time.monotonic() + 120
        while not ready.is_file():
            if writer.poll() is not None:
                stdout, stderr = writer.communicate(timeout=5)
                print((stderr or stdout)[-4_000:], file=sys.stderr)
                return 1
            if time.monotonic() >= deadline:
                writer.kill()
                writer.wait(timeout=5)
                print("Database crash writer readiness timed out", file=sys.stderr)
                return 1
            time.sleep(0.05)
        marker = json.loads(ready.read_text(encoding="utf-8"))
        if marker.get("schemaVersion") != 1 or marker.get("processIdentifier") != writer.pid:
            writer.kill()
            writer.wait(timeout=5)
            print("Database crash writer emitted an invalid marker", file=sys.stderr)
            return 1
        time.sleep(0.05)
        writer.send_signal(signal.SIGKILL)
        writer.wait(timeout=10)
        writer_stdout, writer_stderr = writer.communicate(timeout=5)
        killed_as_expected = writer.returncode == -signal.SIGKILL

        completed = subprocess.run(
            [
                str(executable),
                "--database-crash-readback",
                "--root",
                str(root),
                "--minimum-count",
                str(marker["committedItemCount"]),
                "--output",
                str(readback),
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=60,
        )
        if completed.returncode != 0 or not readback.is_file():
            print((completed.stderr or completed.stdout)[-4_000:], file=sys.stderr)
            return 1
        report = json.loads(readback.read_text(encoding="utf-8"))
        report.update(
            {
                "generatedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
                "artifact": str(args.app.resolve()),
                "artifactExecutableSHA256": sha256(executable),
                "writerSignal": "SIGKILL",
                "writerExitCode": writer.returncode,
                "writerKilledAsExpected": killed_as_expected,
                "writerOutputWasEmpty": not bool(writer_stdout or writer_stderr),
            }
        )
        report["passed"] = bool(report.get("passed")) and killed_as_expected
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(
            f"Database SIGKILL readback: integrity={report['integrityCheckPassed']} "
            f"committed={report['committedItemCount']} {'PASS' if report['passed'] else 'FAIL'}"
        )
        print(args.output)
        return 0 if report["passed"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
