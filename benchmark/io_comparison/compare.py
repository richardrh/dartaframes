#!/usr/bin/env python3
"""Generate fixtures, run both readers, and produce machine/human reports."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import platform
import statistics
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def percentile(values: list[int], fraction: float) -> float:
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return float(ordered[lower])
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def timing_summary(values: list[int], size: int) -> dict[str, float]:
    result = {
        "min_ns": float(min(values)),
        "p25_ns": percentile(values, 0.25),
        "median_ns": float(statistics.median(values)),
        "p75_ns": percentile(values, 0.75),
        "p95_ns": percentile(values, 0.95),
    }
    result["mb_per_second"] = size / (result["median_ns"] / 1e9) / 1_000_000
    return result


def _ps_rss(pid: int) -> int | None:
    try:
        text = subprocess.check_output(
            ["ps", "-o", "rss=", "-p", str(pid)],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
        return int(text) * 1024 if text else None
    except (OSError, subprocess.SubprocessError, ValueError):
        return None


def run_polled(command: list[str]) -> tuple[dict[str, Any], dict[str, Any]]:
    process = subprocess.Popen(
        command, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
    samples: list[int] = []
    done = threading.Event()

    def poll() -> None:
        while not done.is_set():
            value = _ps_rss(process.pid)
            if value is not None:
                samples.append(value)
            done.wait(0.01)
        value = _ps_rss(process.pid)
        if value is not None:
            samples.append(value)

    thread = threading.Thread(target=poll, daemon=True)
    thread.start()
    stdout, stderr = process.communicate()
    done.set()
    thread.join()
    if process.returncode:
        raise SystemExit(
            f"Command failed ({process.returncode}): {' '.join(command)}\n"
            f"stdout:\n{stdout}\nstderr:\n{stderr}"
        )
    try:
        report = json.loads(stdout.strip().splitlines()[-1])
    except (IndexError, json.JSONDecodeError) as exc:
        raise SystemExit(f"Runner did not emit valid JSON: {' '.join(command)}\n{stdout}\n{stderr}") from exc
    polling = {
        "controller_peak_rss_bytes": max(samples) if samples else None,
        "controller_rss_samples": len(samples),
        "poll_interval_ms": 10,
    }
    report.update(polling)
    return report, {"command": command, "stderr": stderr}


def first_mismatch(left: Any, right: Any, path: str = "$") -> str | None:
    if type(left) is not type(right):
        return f"{path}: type {type(left).__name__} != {type(right).__name__}"
    if isinstance(left, dict):
        if left.keys() != right.keys():
            return f"{path}: keys {sorted(left)} != {sorted(right)}"
        for key in left:
            mismatch = first_mismatch(left[key], right[key], f"{path}.{key}")
            if mismatch:
                return mismatch
        return None
    if isinstance(left, list):
        if len(left) != len(right):
            return f"{path}: length {len(left)} != {len(right)}"
        for index, (a, b) in enumerate(zip(left, right)):
            mismatch = first_mismatch(a, b, f"{path}[{index}]")
            if mismatch:
                return mismatch
        return None
    return None if left == right else f"{path}: {left!r} != {right!r}"


def memory_summary(report: dict[str, Any]) -> dict[str, Any]:
    baseline = report["baseline_rss_bytes"]
    live_values = report["frame_live_rss_bytes"]
    if not isinstance(live_values, list):
        live_values = [live_values]
    after_values = report["after_close_rss_bytes"]
    if not isinstance(after_values, list):
        after_values = [after_values]
    peak = report.get("controller_peak_rss_bytes")
    return {
        "baseline_bytes": baseline,
        "max_frame_live_bytes": max(live_values),
        "max_frame_live_delta_bytes": max(live_values) - baseline,
        "max_after_close_bytes": max(after_values),
        "controller_peak_bytes": peak,
        "controller_peak_delta_from_internal_baseline_bytes": None if peak is None else peak - baseline,
    }


def command_version(command: list[str]) -> str | None:
    try:
        result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True, timeout=10)
        return (result.stdout + result.stderr).strip().splitlines()[0]
    except (OSError, subprocess.SubprocessError, IndexError):
        return None


def write_markdown(report: dict[str, Any], path: Path) -> None:
    lines = [
        "# Python Polars vs dartaframes I/O comparison",
        "",
        f"Generated: `{report['generated_at']}`  ",
        f"Host: `{report['environment']['platform']}`",
        "",
        "## Benchmark",
        "",
        "| format | implementation | median ms | min ms | p95 ms | MB/s | live Δ MiB | peak Δ MiB |",
        "|---|---|---:|---:|---:|---:|---:|---:|",
    ]
    for fmt in ("csv", "parquet"):
        for impl in ("python", "dart"):
            item = report["benchmark"][fmt][impl]
            timing, memory = item["summary"], item["memory"]
            peak_delta = memory["controller_peak_delta_from_internal_baseline_bytes"]
            lines.append(
                f"| {fmt} | {impl} | {timing['median_ns']/1e6:.3f} | "
                f"{timing['min_ns']/1e6:.3f} | {timing['p95_ns']/1e6:.3f} | "
                f"{timing['mb_per_second']:.1f} | {memory['max_frame_live_delta_bytes']/2**20:.1f} | "
                f"{'n/a' if peak_delta is None else f'{peak_delta/2**20:.1f}'} |"
            )
    lines += ["", "## Accuracy", ""]
    for fmt in ("csv", "parquet"):
        item = report["accuracy"][fmt]
        lines.append(
            f"- **{fmt}:** {'PASS' if item['byte_equal'] else 'FAIL'}; "
            f"Python `{item['python_sha256']}`, Dart `{item['dart_sha256']}`"
            + (f"; {item['first_mismatch']}" if item["first_mismatch"] else "")
        )
    lines += [
        "",
        "> Timings include lazy scan construction and collect only. Canonical extraction/export/encoding is excluded.",
        "> RSS is process RSS; controller peak is sampled every 10 ms. OS page cache is not controlled.",
        "",
    ]
    path.write_text("\n".join(lines), encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--native-library", required=True, type=Path)
    parser.add_argument("--python", default=sys.executable)
    parser.add_argument("--rows", type=int, default=200_000)
    parser.add_argument("--warmups", type=int, default=1)
    parser.add_argument("--iterations", type=int, default=5)
    parser.add_argument("--dart-mode", choices=("aot", "jit"), default="aot")
    parser.add_argument("--skip-generate", action="store_true")
    args = parser.parse_args()
    if args.rows < 1 or args.warmups < 0 or args.iterations < 1:
        parser.error("rows/iterations must be positive and warmups non-negative")
    native = args.native_library.resolve()
    if not native.is_file():
        parser.error(f"native library does not exist: {native}")
    fixtures, results, build = HERE / "fixtures", HERE / "results", HERE / "build"
    results.mkdir(parents=True, exist_ok=True)
    if not args.skip_generate:
        subprocess.run(
            [args.python, str(HERE / "generate_fixtures.py"), "--rows", str(args.rows)],
            cwd=ROOT,
            check=True,
        )
    manifest_path = fixtures / "manifest.json"
    if not manifest_path.is_file():
        parser.error("fixtures are absent; omit --skip-generate")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    for name, expected in manifest.get("files", {}).items():
        fixture = fixtures / name
        if not fixture.is_file():
            parser.error(f"manifest fixture is absent: {fixture}")
        actual_hash = sha256(fixture)
        if fixture.stat().st_size != expected["bytes"] or actual_hash != expected["sha256"]:
            parser.error(f"fixture differs from manifest: {fixture}; regenerate it")

    if args.dart_mode == "aot":
        build.mkdir(parents=True, exist_ok=True)
        dart_executable = build / "dart_runner"
        subprocess.run(
            ["dart", "compile", "exe", str(HERE / "dart_runner.dart"), "-o", str(dart_executable)],
            cwd=ROOT,
            check=True,
        )
        dart_prefix = [str(dart_executable)]
    else:
        dart_prefix = ["dart", "run", str(HERE / "dart_runner.dart")]

    python_prefix = [args.python, str(HERE / "python_runner.py")]
    benchmark: dict[str, Any] = {}
    accuracy: dict[str, Any] = {}
    command_records = []
    for fmt in ("csv", "parquet"):
        benchmark[fmt] = {}
        source = fixtures / f"benchmark.{fmt}"
        common = ["benchmark", "--format", fmt, "--input", str(source),
                  "--warmups", str(args.warmups), "--iterations", str(args.iterations)]
        for impl, command in (
            ("python", python_prefix + common),
            ("dart", dart_prefix + common + ["--native-library", str(native)]),
        ):
            item, command_record = run_polled(command)
            item["summary"] = timing_summary(item["scan_collect_ns"], source.stat().st_size)
            item["memory"] = memory_summary(item)
            benchmark[fmt][impl] = item
            command_records.append(command_record)

        accuracy[fmt] = {}
        canonical_paths = {
            "python": results / f"accuracy_{fmt}_python.json",
            "dart": results / f"accuracy_{fmt}_dart.json",
        }
        source = fixtures / f"accuracy.{fmt}"
        reports = {}
        for impl, prefix in (("python", python_prefix), ("dart", dart_prefix)):
            command = prefix + ["accuracy", "--format", fmt, "--input", str(source),
                                "--canonical", str(canonical_paths[impl])]
            if impl == "dart":
                command += ["--native-library", str(native)]
            item, command_record = run_polled(command)
            item["memory"] = memory_summary(item)
            reports[impl] = item
            command_records.append(command_record)
        py_bytes = canonical_paths["python"].read_bytes()
        dart_bytes = canonical_paths["dart"].read_bytes()
        mismatch = None
        if py_bytes != dart_bytes:
            try:
                mismatch = first_mismatch(json.loads(py_bytes), json.loads(dart_bytes))
            except json.JSONDecodeError:
                offset = next((i for i, pair in enumerate(zip(py_bytes, dart_bytes)) if pair[0] != pair[1]), min(len(py_bytes), len(dart_bytes)))
                mismatch = f"byte offset {offset}"
        accuracy[fmt] = {
            "byte_equal": py_bytes == dart_bytes,
            "python_sha256": sha256(canonical_paths["python"]),
            "dart_sha256": sha256(canonical_paths["dart"]),
            "first_mismatch": mismatch,
            "python": reports["python"],
            "dart": reports["dart"],
        }

    report = {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "methodology": {"timed_scope": "lazy scan creation + collect", "rss": "current process RSS internally; external ps peak at 10 ms", "page_cache_controlled": False},
        "arguments": {"rows": args.rows, "warmups": args.warmups, "iterations": args.iterations, "dart_mode": args.dart_mode, "native_library": str(native)},
        "environment": {"platform": platform.platform(), "machine": platform.machine(), "python": command_version([args.python, "--version"]), "dart": command_version(["dart", "--version"]), "cpu_count": os.cpu_count()},
        "manifest": manifest,
        "benchmark": benchmark,
        "accuracy": accuracy,
        "commands": command_records,
    }
    latest_json = results / "latest.json"
    latest_json.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    write_markdown(report, results / "latest.md")
    failed = [fmt for fmt, item in accuracy.items() if not item["byte_equal"]]
    print(f"Wrote {latest_json} and {results / 'latest.md'}")
    if failed:
        raise SystemExit(f"Canonical accuracy mismatch: {', '.join(failed)}")


if __name__ == "__main__":
    main()
