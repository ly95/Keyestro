#!/usr/bin/env python3
"""Verify native Swift coverage without treating an unsupported 0/0 branch metric as success.

LLVM's Swift frontend emits line, function, and region mappings, but currently
does not emit the branch records that `llvm-cov` exposes for Clang. This tool
therefore adds deterministic source-level statement and control-flow outcome
metrics from the Swift parser AST and correlates them with LLVM execution
segments. The branch metric intentionally covers statement-level `if`, `guard`,
`switch`, and loop outcomes; it does not claim MC/DC or short-circuit operand
coverage.
"""

from __future__ import annotations

import argparse
from bisect import bisect_right
from dataclasses import asdict, dataclass
import json
from pathlib import Path
import subprocess
import sys
from typing import Any, Iterable


PRODUCTION_GLOBS = (
    "Sources/**/*.swift",
    "Examples/Extensions/SwiftExample/**/*.swift",
)

REQUIRED_METRICS = ("lines", "statements", "functions", "branches")

NON_EXECUTABLE_STATEMENTS = {"brace_stmt", "case_stmt", "then_stmt"}


@dataclass
class Metric:
    covered: int = 0
    total: int = 0

    @property
    def percent(self) -> float:
        return 100.0 if self.total == 0 else 100.0 * self.covered / self.total

    def add(self, other: "Metric") -> None:
        self.covered += other.covered
        self.total += other.total


@dataclass
class FileCoverage:
    path: str
    lines: Metric
    functions: Metric
    regions: Metric
    statements: Metric
    branches: Metric
    uncovered_statements: list[str]
    uncovered_branches: list[str]
    has_llvm_mapping: bool
    parse_error: str | None = None


class SegmentCoverage:
    def __init__(self, source: bytes, segments: list[list[Any]]) -> None:
        self._line_starts = [0]
        for index, value in enumerate(source):
            if value == 0x0A:
                self._line_starts.append(index + 1)
        self._segments = sorted(segments, key=lambda value: (int(value[0]), int(value[1])))
        self._positions = [(int(value[0]), int(value[1])) for value in self._segments]

    def position(self, one_based_utf8_offset: int) -> tuple[int, int]:
        offset = max(0, one_based_utf8_offset - 1)
        line_index = max(0, bisect_right(self._line_starts, offset) - 1)
        return line_index + 1, offset - self._line_starts[line_index] + 1

    def count(self, one_based_utf8_offset: int) -> int:
        position = self.position(one_based_utf8_offset)
        index = bisect_right(self._positions, position) - 1
        if index < 0:
            return 0
        segment = self._segments[index]
        return int(segment[2]) if bool(segment[3]) else 0


def walk(node: Any) -> Iterable[dict[str, Any]]:
    if isinstance(node, dict):
        yield node
        for value in node.values():
            yield from walk(value)
    elif isinstance(node, list):
        for value in node:
            yield from walk(value)


def node_range(node: dict[str, Any]) -> tuple[int, int] | None:
    value = node.get("range")
    if not isinstance(value, dict):
        return None
    start = value.get("start")
    end = value.get("end")
    if not isinstance(start, int) or not isinstance(end, int):
        return None
    return start, end


def body_entry(node: dict[str, Any]) -> int | None:
    location = node_range(node)
    if location is None:
        return None
    return location[0] + 1 if node.get("_kind") in {"brace_stmt", "then_stmt"} else location[0]


def statement_metric(ast: dict[str, Any], coverage: SegmentCoverage) -> tuple[Metric, list[str]]:
    locations: set[tuple[str, int, int]] = set()
    for node in walk(ast):
        kind = node.get("_kind")
        location = node_range(node)
        if not isinstance(kind, str) or location is None:
            continue
        is_statement = kind.endswith("_stmt") and kind not in NON_EXECUTABLE_STATEMENTS
        is_top_level_expression = kind == "top_level_code_decl"
        if is_statement or is_top_level_expression:
            locations.add((kind, location[0], location[1]))
    metric = Metric(
        covered=sum(coverage.count(start) > 0 for _, start, _ in locations),
        total=len(locations),
    )
    uncovered = [
        f"{kind}@{coverage.position(start)[0]}:{coverage.position(start)[1]}"
        for kind, start, _ in sorted(locations, key=lambda value: (value[1], value[0]))
        if coverage.count(start) == 0
    ]
    return metric, uncovered


def branch_metric(ast: dict[str, Any], coverage: SegmentCoverage) -> tuple[Metric, list[str]]:
    outcomes: dict[tuple[str, int, int], int] = {}

    def add(kind: str, offset: int, discriminator: int, count: int | None = None) -> None:
        key = (kind, offset, discriminator)
        outcomes[key] = max(outcomes.get(key, 0), coverage.count(offset) if count is None else count)

    for node in walk(ast):
        kind = node.get("_kind")
        location = node_range(node)
        if not isinstance(kind, str) or location is None:
            continue
        if kind == "if_stmt":
            then_node = node.get("then_stmt", {})
            else_node = node.get("else_stmt", {})
            then_offset = body_entry(then_node)
            else_offset = body_entry(else_node)
            if then_offset is not None:
                entry_count = coverage.count(location[0])
                then_count = coverage.count(then_offset)
                add(kind, then_offset, 0, then_count)
                if else_offset is not None:
                    add(kind, else_offset, 1)
                else:
                    add(kind, location[0], 1, max(0, entry_count - then_count))
        elif kind == "guard_stmt":
            body_offset = body_entry(node.get("body", {}))
            if body_offset is not None:
                entry_count = coverage.count(location[0])
                failure_count = coverage.count(body_offset)
                add(kind, body_offset, 0, failure_count)
                add(kind, location[0], 1, max(0, entry_count - failure_count))
        elif kind == "switch_stmt":
            for index, case in enumerate(node.get("cases", [])):
                body_range = node_range(case.get("body", {})) if isinstance(case, dict) else None
                if body_range is not None:
                    add(kind, body_range[0], index)
        elif kind in {"for_each_stmt", "while_stmt", "repeat_while_stmt"}:
            body_offset = body_entry(node.get("body", {}))
            if body_offset is not None:
                entry_count = coverage.count(location[0])
                body_count = coverage.count(body_offset)
                add(kind, body_offset, 0, body_count)
                add(kind, location[0], 1, entry_count)
        elif kind == "do_catch_stmt":
            # A completed `do` body and every typed/default catch are distinct
            # control-flow outcomes in the source-level metric.
            entry_count = coverage.count(location[0])
            caught_count = 0
            for index, catch in enumerate(node.get("catches", []), start=1):
                catch_offset = body_entry(catch.get("body", {})) if isinstance(catch, dict) else None
                if catch_offset is not None:
                    count = coverage.count(catch_offset)
                    caught_count += count
                    add(kind, catch_offset, index, count)
            add(kind, location[0], 0, max(0, entry_count - caught_count))

    metric = Metric(
        covered=sum(count > 0 for count in outcomes.values()),
        total=len(outcomes),
    )
    uncovered = [
        f"{kind}[{discriminator}]@{coverage.position(offset)[0]}:{coverage.position(offset)[1]}"
        for (kind, offset, discriminator), count in sorted(
            outcomes.items(), key=lambda value: (value[0][1], value[0][0], value[0][2])
        )
        if count == 0
    ]
    return metric, uncovered


def parser_ast(swiftc: str, source: Path) -> tuple[dict[str, Any] | None, str | None]:
    last_error = "Swift parser produced no JSON"
    for _ in range(3):
        completed = subprocess.run(
            [swiftc, "-frontend", "-dump-parse", "-dump-ast-format", "json", str(source)],
            check=False,
            capture_output=True,
            text=True,
            timeout=30,
        )
        try:
            return json.loads(completed.stdout), None
        except json.JSONDecodeError as error:
            diagnostic = completed.stderr.strip().splitlines()
            last_error = diagnostic[-1] if diagnostic else str(error)
    return None, last_error


def production_sources(root: Path) -> list[Path]:
    files: set[Path] = set()
    for pattern in PRODUCTION_GLOBS:
        files.update(path for path in root.glob(pattern) if path.is_file())
    return sorted(files)


def llvm_files(document: dict[str, Any], root: Path) -> dict[Path, dict[str, Any]]:
    output: dict[Path, dict[str, Any]] = {}
    for data in document.get("data", []):
        for value in data.get("files", []):
            filename = value.get("filename")
            if not isinstance(filename, str):
                continue
            path = Path(filename)
            if not path.is_absolute():
                path = root / path
            try:
                resolved = path.resolve().relative_to(root)
            except ValueError:
                continue
            if resolved.parts and resolved.parts[0] in {"Sources", "Examples"}:
                output[resolved] = value
    return output


def llvm_metric(value: dict[str, Any] | None, name: str) -> Metric:
    if value is None:
        return Metric()
    summary = value.get("summary", {}).get(name, {})
    return Metric(covered=int(summary.get("covered", 0)), total=int(summary.get("count", 0)))


def analyze(root: Path, document: dict[str, Any], swiftc: str) -> list[FileCoverage]:
    mappings = llvm_files(document, root)
    output: list[FileCoverage] = []
    for absolute in production_sources(root):
        relative = absolute.relative_to(root)
        llvm = mappings.get(relative)
        segments = llvm.get("segments", []) if llvm is not None else []
        segment_coverage = SegmentCoverage(absolute.read_bytes(), segments)
        ast, parse_error = parser_ast(swiftc, absolute)
        if ast is not None:
            statements, uncovered_statements = statement_metric(ast, segment_coverage)
            branches, uncovered_branches = branch_metric(ast, segment_coverage)
        else:
            statements, uncovered_statements = Metric(), []
            branches, uncovered_branches = Metric(), []
        output.append(
            FileCoverage(
                path=str(relative),
                lines=llvm_metric(llvm, "lines"),
                functions=llvm_metric(llvm, "functions"),
                regions=llvm_metric(llvm, "regions"),
                statements=statements,
                branches=branches,
                uncovered_statements=uncovered_statements,
                uncovered_branches=uncovered_branches,
                has_llvm_mapping=llvm is not None,
                parse_error=parse_error,
            )
        )
    return output


def totals(files: list[FileCoverage]) -> dict[str, Metric]:
    result = {name: Metric() for name in ("lines", "functions", "regions", "statements", "branches")}
    for file in files:
        for name, metric in result.items():
            metric.add(getattr(file, name))
    return result


def serialized(files: list[FileCoverage], total: dict[str, Metric]) -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "branchDefinition": "statement-level if/guard/switch/loop/do-catch outcomes; excludes MC/DC",
        "totals": {name: asdict(value) | {"percent": value.percent} for name, value in total.items()},
        "files": [
            {
                **asdict(file),
                "lines": asdict(file.lines) | {"percent": file.lines.percent},
                "functions": asdict(file.functions) | {"percent": file.functions.percent},
                "regions": asdict(file.regions) | {"percent": file.regions.percent},
                "statements": asdict(file.statements) | {"percent": file.statements.percent},
                "branches": asdict(file.branches) | {"percent": file.branches.percent},
            }
            for file in files
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--coverage-json", type=Path, required=True)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--output", type=Path)
    parser.add_argument("--require-exact", action="store_true")
    args = parser.parse_args()

    root = args.root.resolve()
    document = json.loads(args.coverage_json.read_text(encoding="utf-8"))
    swiftc = subprocess.run(
        ["xcrun", "--find", "swiftc"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    files = analyze(root, document, swiftc)
    total = totals(files)
    report = serialized(files, total)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    for name in ("lines", "statements", "functions", "branches", "regions"):
        metric = total[name]
        print(f"{name:10} {metric.covered:6}/{metric.total:<6} {metric.percent:7.2f}%")
    parse_failures = [file for file in files if file.parse_error]
    if parse_failures:
        for file in parse_failures:
            print(f"parse error: {file.path}: {file.parse_error}", file=sys.stderr)
        return 2

    if args.require_exact:
        failures = [name for name in REQUIRED_METRICS if total[name].covered != total[name].total]
        unmapped_executable = [
            file.path
            for file in files
            if not file.has_llvm_mapping and (file.statements.total > 0 or file.branches.total > 0)
        ]
        if failures or unmapped_executable:
            if failures:
                print("coverage below exact 100%: " + ", ".join(sorted(failures)), file=sys.stderr)
            if unmapped_executable:
                print("executable sources missing LLVM mappings:", file=sys.stderr)
                for path in unmapped_executable:
                    print(f"  {path}", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
