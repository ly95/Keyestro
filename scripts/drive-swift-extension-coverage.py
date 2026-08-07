#!/usr/bin/env python3
"""Exercise every protocol surface of the bundled Swift extension example."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess


def frame(message: dict[str, object]) -> bytes:
    body = json.dumps(message, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    return f"Content-Length: {len(body)}\r\n\r\n".encode("ascii") + body


def run(executable: Path, payload: bytes, *, expected_output: bool) -> None:
    completed = subprocess.run(
        [str(executable)],
        input=payload,
        capture_output=True,
        check=False,
        timeout=10,
    )
    if completed.returncode != 0:
        raise RuntimeError(
            f"Swift extension exited {completed.returncode}: "
            + completed.stderr.decode("utf-8", errors="replace")[-2_000:]
        )
    if expected_output and b"Content-Length:" not in completed.stdout:
        raise RuntimeError("Swift extension did not publish framed output")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("executable", type=Path)
    args = parser.parse_args()
    executable = args.executable.resolve()
    if not executable.is_file():
        parser.error(f"executable is unavailable: {executable}")

    requests = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
        {"jsonrpc": "2.0", "method": "initialized", "params": {}},
        {"jsonrpc": "2.0", "method": "cancel", "params": {}},
        {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "search",
            "params": {"query": "", "requestId": "empty"},
        },
        {
            "jsonrpc": "2.0",
            "id": 3,
            "method": "search",
            "params": {"query": "actor", "requestId": "query"},
        },
        {"jsonrpc": "2.0", "id": 4, "method": "execute", "params": {}},
        {"jsonrpc": "2.0", "id": 5, "method": "shutdown", "params": {}},
        {"jsonrpc": "2.0", "id": 6, "method": "unknown", "params": {}},
        {"jsonrpc": "2.0", "method": "unknown-without-id"},
        {"jsonrpc": "2.0", "method": "exit"},
    ]
    run(executable, b"".join(frame(request) for request in requests), expected_output=True)

    # Each malformed or truncated stream reaches a distinct fail-closed reader path.
    for payload in (
        b"truncated header",
        b"\xff\r\n\r\n",
        b"X-Test: value\r\n\r\n",
        b"Content-Length: 5\r\n\r\n{}",
    ):
        run(executable, payload, expected_output=False)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
