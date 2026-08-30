#!/usr/bin/env python3
"""Generate deterministic, equivalent CSV/Parquet comparison inputs."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import platform
import struct
import sys
from datetime import date, datetime, time, timedelta
from decimal import Decimal
from pathlib import Path

try:
    import polars as pl
except ImportError as exc:  # pragma: no cover - exercised on an unprepared host
    raise SystemExit(
        "Python Polars is required. Run: python -m pip install -r "
        f"{Path(__file__).with_name('requirements.txt')}"
    ) from exc

HERE = Path(__file__).resolve().parent


def _f64(bits: int) -> float:
    return struct.unpack(">d", bits.to_bytes(8, "big"))[0]


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _accuracy_csv(path: Path) -> None:
    # Deliberately restricted to types both lazy CSV readers can infer. Rich
    # physical types (f32, binary, decimal and duration/time) live in Parquet.
    frame = pl.DataFrame(
        {
            "bool_value": pl.Series([True, False, None, True, False, True], dtype=pl.Boolean),
            "i64_value": pl.Series(
                [-(2**63), 2**63 - 1, 2**53 + 1, None, -1, 0], dtype=pl.Int64
            ),
            "f64_value": pl.Series(
                [0.0, -0.0, math.inf, -math.inf, float("nan"), None], dtype=pl.Float64
            ),
            "date_value": pl.Series(
                [date(1970, 1, 1), date(1969, 12, 31), None, date(2000, 2, 29), date(2038, 1, 19), date(2024, 1, 2)],
                dtype=pl.Date,
            ),
            "datetime_value": pl.Series(
                [datetime(1970, 1, 1), datetime(1969, 12, 31, 23, 59, 59, 999999), None,
                 datetime(2000, 2, 29, 12, 34, 56, 123456), datetime(2038, 1, 19, 3, 14, 7), datetime(2024, 1, 2, 3, 4, 5, 6)],
                dtype=pl.Datetime("us"),
            ),
            "text_value": pl.Series(
                ["plain", "comma, quote \" and newline\n", "Grüße 東京 😀", "", None, " leading and trailing "],
                dtype=pl.String,
            ),
        }
    )
    frame.write_csv(path, datetime_format="%Y-%m-%dT%H:%M:%S%.6f")


def _accuracy_parquet(path: Path) -> None:
    frame = pl.DataFrame(
        {
            "null_value": pl.Series([None] * 6, dtype=pl.Null),
            "bool_value": pl.Series([True, False, None, True, False, True], dtype=pl.Boolean),
            "i64_value": pl.Series([-(2**63), 2**63 - 1, 2**53 + 1, None, -1, 0], dtype=pl.Int64),
            "u64_value": pl.Series([0, 2**63, 2**64 - 1, None, 42, 1], dtype=pl.UInt64),
            "f32_value": pl.Series([0.0, -0.0, math.inf, -math.inf, float("nan"), None], dtype=pl.Float32),
            "f64_value": pl.Series([0.0, -0.0, math.inf, -math.inf, _f64(0x7FF8000000000001), None], dtype=pl.Float64),
            "text_value": pl.Series(["plain", "comma, quote \" and newline\n", "Grüße 東京 😀", "", None, " leading and trailing "], dtype=pl.String),
            "binary_value": pl.Series([b"", b"\x00\xff", "東京".encode(), None, b"a\x00b", bytes(range(16))], dtype=pl.Binary),
            "decimal_value": pl.Series([Decimal("0.000000"), Decimal("-1.230000"), Decimal("99999999999999999999999999999999.999999"), None, Decimal("0.000001"), Decimal("-999.999999")], dtype=pl.Decimal(38, 6)),
            "date_value": pl.Series([date(1970, 1, 1), date(1969, 12, 31), None, date(2000, 2, 29), date(2038, 1, 19), date(2024, 1, 2)], dtype=pl.Date),
            "datetime_value": pl.Series([datetime(1970, 1, 1), datetime(1969, 12, 31, 23, 59, 59, 999999), None, datetime(2000, 2, 29, 12, 34, 56, 123456), datetime(2038, 1, 19, 3, 14, 7), datetime(2024, 1, 2, 3, 4, 5, 6)], dtype=pl.Datetime("us")),
            "duration_value": pl.Series([timedelta(0), timedelta(microseconds=-1), None, timedelta(days=1, microseconds=2), timedelta(seconds=3), timedelta(days=-2, seconds=1)], dtype=pl.Duration("us")),
            # Polars' Time physical representation is nanoseconds; Python time
            # inputs provide an exactly representable microsecond subset.
            "time_value": pl.Series([time(0), time(23, 59, 59, 999999), None, time(12, 34, 56, 123456), time(1, 2, 3, 4), time(6, 7, 8, 9)], dtype=pl.Time),
        }
    )
    frame.write_parquet(path, compression="zstd", statistics=True)


def _benchmark(rows: int, csv_path: Path, parquet_path: Path) -> None:
    if rows < 1:
        raise SystemExit("--rows must be positive")
    base = date(2000, 1, 1)
    frame = pl.DataFrame(
        {
            "row_id": pl.Series(range(rows), dtype=pl.Int64),
            "group": pl.Series([f"group-{(i * 17) % 101:03d}" for i in range(rows)], dtype=pl.String),
            "measurement": pl.Series([None if i % 97 == 0 else ((i * 48271) % 1000003) / 100.0 - 5000.0 for i in range(rows)], dtype=pl.Float64),
            "active": pl.Series([None if i % 211 == 0 else i % 3 == 0 for i in range(rows)], dtype=pl.Boolean),
            "event_date": pl.Series([base + timedelta(days=(i * 13) % 9000) for i in range(rows)], dtype=pl.Date),
        }
    )
    frame.write_csv(csv_path)
    frame.write_parquet(parquet_path, compression="zstd", statistics=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rows", type=int, default=200_000)
    parser.add_argument("--output-dir", type=Path, default=HERE / "fixtures")
    args = parser.parse_args()
    out = args.output_dir.resolve()
    out.mkdir(parents=True, exist_ok=True)
    _accuracy_csv(out / "accuracy.csv")
    _accuracy_parquet(out / "accuracy.parquet")
    _benchmark(args.rows, out / "benchmark.csv", out / "benchmark.parquet")
    entries = {}
    for name in ("accuracy.csv", "accuracy.parquet", "benchmark.csv", "benchmark.parquet"):
        path = out / name
        entries[name] = {
            "rows": 6 if name.startswith("accuracy") else args.rows,
            "bytes": path.stat().st_size,
            "sha256": _sha256(path),
        }
    manifest = {
        "generator": Path(__file__).name,
        "python": platform.python_version(),
        "polars": pl.__version__,
        "benchmark_rows": args.rows,
        "files": entries,
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(manifest, sort_keys=True))


if __name__ == "__main__":
    main()
