#!/usr/bin/env python3
"""Python Polars side of the I/O comparison. Emits one JSON report on stdout."""
from __future__ import annotations

import argparse
import base64
import gc
import json
import os
import platform
import re
import struct
import subprocess
import sys
import time
from datetime import date, datetime, time as daytime, timedelta
from decimal import Decimal
from pathlib import Path
from typing import Any

try:
    import polars as pl
except ImportError as exc:
    raise SystemExit(
        "Python Polars is required. Run: python -m pip install -r "
        f"{Path(__file__).with_name('requirements.txt')}"
    ) from exc


def current_rss() -> int:
    """Current resident bytes (not resource.getrusage's high-water mark)."""
    try:
        value = subprocess.check_output(
            ["ps", "-o", "rss=", "-p", str(os.getpid())], text=True
        ).strip()
        return int(value) * 1024
    except (OSError, subprocess.SubprocessError, ValueError):
        return -1


def scan(path: Path, fmt: str) -> "pl.LazyFrame":
    if fmt == "csv":
        return pl.scan_csv(path, try_parse_dates=True)
    return pl.scan_parquet(path)


def dtype_json(dtype: Any) -> dict[str, Any]:
    simple = {
        pl.Null: "null", pl.Boolean: "boolean", pl.Int8: "int8", pl.Int16: "int16",
        pl.Int32: "int32", pl.Int64: "int64", pl.UInt8: "uint8", pl.UInt16: "uint16",
        pl.UInt32: "uint32", pl.UInt64: "uint64", pl.Float32: "float32",
        pl.Float64: "float64", pl.String: "string", pl.Binary: "binary", pl.Date: "date",
        pl.Time: "time",
    }
    # CSV may infer a signed Int128 for a column containing both negative
    # values and uint64-range values. These are binding-supported extensions.
    for name, kind in (("Int128", "int128"), ("UInt128", "uint128")):
        if (candidate := getattr(pl, name, None)) is not None:
            simple[candidate] = kind
    if dtype in simple:
        result: dict[str, Any] = {"kind": simple[dtype]}
        if dtype == pl.Date:
            result["unit"] = "days"
        elif dtype == pl.Time:
            result["unit"] = "nanoseconds"
        return result
    text = str(dtype)
    if text.startswith("Datetime"):
        unit = re.search(r"time_unit=['\"](\w+)['\"]", text)
        zone = re.search(r"time_zone=['\"]([^'\"]+)['\"]", text)
        result = {"kind": "datetime", "unit": _unit_name(unit.group(1) if unit else "us")}
        if zone:
            result["timeZone"] = zone.group(1)
        return result
    if text.startswith("Duration"):
        unit = re.search(r"time_unit=['\"](\w+)['\"]", text)
        return {"kind": "duration", "unit": _unit_name(unit.group(1) if unit else "us")}
    if text.startswith("Decimal"):
        numbers = [int(x) for x in re.findall(r"\d+", text)]
        if len(numbers) < 2:
            raise TypeError(f"Cannot determine Decimal precision/scale from {dtype!r}")
        return {"kind": "decimal", "precision": numbers[0], "scale": numbers[1]}
    raise TypeError(f"Accuracy canonicalization does not support Polars dtype {dtype!r}")


def _unit_name(unit: str) -> str:
    return {"s": "seconds", "ms": "milliseconds", "us": "microseconds", "ns": "nanoseconds"}[unit]


def _temporal_counter(value: Any, descriptor: dict[str, Any]) -> int:
    kind = descriptor["kind"]
    if kind == "date":
        return (value - date(1970, 1, 1)).days
    if kind == "time":
        assert isinstance(value, daytime)
        micros = ((value.hour * 60 + value.minute) * 60 + value.second) * 1_000_000 + value.microsecond
        return micros * 1000
    if kind == "duration":
        assert isinstance(value, timedelta)
        micros = (value.days * 86400 + value.seconds) * 1_000_000 + value.microseconds
    else:
        assert isinstance(value, datetime)
        # Fixtures are naive; timezone-aware values are normalized without a
        # floating-point timestamp if this harness is extended later.
        epoch = datetime(1970, 1, 1, tzinfo=value.tzinfo)
        delta = value - epoch
        micros = (delta.days * 86400 + delta.seconds) * 1_000_000 + delta.microseconds
    unit = descriptor["unit"]
    return {"seconds": micros // 1_000_000, "milliseconds": micros // 1000,
            "microseconds": micros, "nanoseconds": micros * 1000}[unit]


def canonical_value(value: Any, descriptor: dict[str, Any]) -> Any:
    kind = descriptor["kind"]
    if kind == "boolean" or kind == "string":
        return value
    if kind.startswith("int") or kind.startswith("uint"):
        return str(value)
    if kind in ("float32", "float64"):
        fmt, width = (">f", 8) if kind == "float32" else (">d", 16)
        bits = int.from_bytes(struct.pack(fmt, value), "big")
        return {"floatBits": f"{bits:0{width}x}"}
    if kind == "binary":
        return {"base64": base64.b64encode(value).decode("ascii")}
    if kind == "decimal":
        assert isinstance(value, Decimal)
        sign, digits, exponent = value.as_tuple()
        coefficient = int("".join(str(digit) for digit in digits) or "0")
        shift = exponent + descriptor["scale"]
        if shift >= 0:
            unscaled = coefficient * (10**shift)
        else:
            divisor = 10 ** (-shift)
            if coefficient % divisor:
                raise ValueError(f"Decimal {value} exceeds declared scale")
            unscaled = coefficient // divisor
        if sign:
            unscaled = -unscaled
        return {"unscaled": str(unscaled)}
    if kind in ("date", "datetime", "duration", "time"):
        return str(_temporal_counter(value, descriptor))
    raise TypeError(f"Unsupported canonical kind {kind}")


def canonical_batch(frame: "pl.DataFrame", extracted: dict[str, list[Any]]) -> dict[str, Any]:
    fields, columns = [], []
    for name, dtype in frame.schema.items():
        descriptor = dtype_json(dtype)
        values = extracted[name]
        validity = [value is not None for value in values]
        encoded = [None if value is None else canonical_value(value, descriptor) for value in values]
        fields.append({"name": name, "dtype": descriptor, "nullable": True})
        columns.append({"name": name, "dtype": descriptor, "validity": validity, "values": encoded})
    return {"schema": {"fields": fields}, "length": frame.height, "columns": columns}


def benchmark(args: argparse.Namespace) -> dict[str, Any]:
    baseline = current_rss()
    timings, live, after = [], [], []
    for index in range(args.warmups + args.iterations):
        started = time.monotonic_ns()
        lazy = scan(args.input, args.format)
        frame = lazy.collect()
        elapsed = time.monotonic_ns() - started
        rss_live = current_rss()
        del frame, lazy
        gc.collect()
        rss_after = current_rss()
        if index >= args.warmups:
            timings.append(elapsed)
            live.append(rss_live)
            after.append(rss_after)
    return _base(args) | {"mode": "benchmark", "baseline_rss_bytes": baseline,
                          "scan_collect_ns": timings, "frame_live_rss_bytes": live,
                          "after_close_rss_bytes": after}


def accuracy(args: argparse.Namespace) -> dict[str, Any]:
    baseline = current_rss()
    started = time.monotonic_ns()
    lazy = scan(args.input, args.format)
    frame = lazy.collect()
    scan_ns = time.monotonic_ns() - started
    live = current_rss()
    started = time.monotonic_ns()
    extracted = frame.to_dict(as_series=False)
    extraction_ns = time.monotonic_ns() - started
    started = time.monotonic_ns()
    batch = canonical_batch(frame, extracted)
    canonical = json.dumps(batch, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")
    canonical_ns = time.monotonic_ns() - started
    started = time.monotonic_ns()
    args.canonical.write_bytes(canonical)
    write_ns = time.monotonic_ns() - started
    del extracted, batch, frame, lazy
    gc.collect()
    return _base(args) | {"mode": "accuracy", "baseline_rss_bytes": baseline,
        "frame_live_rss_bytes": live, "after_close_rss_bytes": current_rss(),
        "scan_collect_ns": scan_ns, "extraction_ns": extraction_ns,
        "canonical_encode_ns": canonical_ns, "canonical_write_ns": write_ns,
        "canonical_bytes": len(canonical), "canonical_path": str(args.canonical)}


def _base(args: argparse.Namespace) -> dict[str, Any]:
    return {"implementation": "python-polars", "format": args.format,
            "input": str(args.input), "polars_version": pl.__version__,
            "python_version": platform.python_version(), "pid": os.getpid()}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("benchmark", "accuracy"))
    parser.add_argument("--format", required=True, choices=("csv", "parquet"))
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--canonical", type=Path)
    parser.add_argument("--warmups", type=int, default=1)
    parser.add_argument("--iterations", type=int, default=5)
    args = parser.parse_args()
    if args.mode == "accuracy" and args.canonical is None:
        parser.error("accuracy mode requires --canonical")
    report = benchmark(args) if args.mode == "benchmark" else accuracy(args)
    print(json.dumps(report, separators=(",", ":"), sort_keys=True))


if __name__ == "__main__":
    main()
