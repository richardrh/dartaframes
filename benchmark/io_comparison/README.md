# Python Polars vs dartaframes I/O

This is a reproducible, process-level comparison of lazy CSV and Parquet scans
over the same deterministic data. It measures scan creation plus collection,
checks copied logical values byte-for-byte, and records process RSS.

## Setup and run

From the repository root (from elsewhere, invoke the scripts with absolute
paths; they resolve repository resources independently of the current directory):

```sh
python3 -m venv benchmark/io_comparison/.venv
benchmark/io_comparison/.venv/bin/python -m pip install -r benchmark/io_comparison/requirements.txt
dart pub get
cargo build --locked --release --manifest-path native/polars_ffi/Cargo.toml

benchmark/io_comparison/.venv/bin/python benchmark/io_comparison/compare.py \
  --native-library target/release/libdartaframes_polars_ffi.dylib
```

On Linux the library suffix is `.so`; on Windows use the corresponding `.dll`.
`compare.py` defaults to a Dart AOT executable, 200,000 benchmark rows, one
warmup, and five measured iterations. Useful alternatives:

```sh
# Faster harness development (JIT is not directly comparable to AOT):
python benchmark/io_comparison/compare.py --dart-mode jit --native-library /absolute/path/to/library

# Larger run, or reuse already generated fixtures:
python benchmark/io_comparison/compare.py --rows 2000000 --warmups 2 --iterations 10 --native-library /path/to/library
python benchmark/io_comparison/compare.py --skip-generate --native-library /path/to/library
```

The other accepted options are `--python`, `--rows`, `--warmups`,
`--iterations`, and `--dart-mode {aot,jit}`. Outputs are
`results/latest.json` (full samples, versions, environment and commands) and
`results/latest.md` (summary). The harness reports the actual Python Polars and
native Polars versions; the requirement intentionally permits Polars 1.x.

Individual stages can also be inspected directly:

```sh
python benchmark/io_comparison/generate_fixtures.py --rows 200000
python benchmark/io_comparison/python_runner.py benchmark --format csv \
  --input benchmark/io_comparison/fixtures/benchmark.csv --warmups 1 --iterations 5
dart run benchmark/io_comparison/dart_runner.dart benchmark --format parquet \
  --input benchmark/io_comparison/fixtures/benchmark.parquet \
  --native-library /absolute/path/to/library --warmups 1 --iterations 5
```

## What is compared

`accuracy.csv` contains only reliably inferred flat CSV types: nullable bool,
signed 64-bit integers (including boundaries and values above 2^53), Float64
signed zero/infinities/NaN, date, microsecond
datetime, and quoted/empty/null Unicode strings. CSV has no physical schema, so
it cannot preserve UInt64, Float32, binary, decimal, duration, or time; those are tested
in `accuracy.parquet`, together with all of the preceding relevant types and a
fully-null column. `benchmark.csv` and `benchmark.parquet` contain the same
logical rows and columns. `manifest.json` records row counts, byte sizes,
SHA-256 digests, generator name, Python version and generator Polars version.

For accuracy, each implementation lazily scans and collects first. Python then
extracts columns; Dart separately times `DataFrame.exportSync`, the copied
native bridge. Canonical encoding and file writing are separately timed and are
never included in scan+collect. Both sides produce the public
`OwnedBatchJsonCodec` shape: nullable schema fields, row length, ordered columns,
validity and values. Integer/temporal counters are decimal strings, floats are
fixed-width lowercase raw IEEE bit hex, decimal is an unscaled integer string,
and binary is base64. JSON object keys are recursively sorted while arrays keep
their order. The controller requires both SHA-256 and byte-for-byte equality and
reports the first logical mismatch.

## Timing and memory methodology

Each measured iteration starts the monotonic clock **before lazy scan creation**
and stops immediately after synchronous collect. Warmups are discarded. Frames
and plans are deterministically closed on Dart; Python references are dropped
and cyclic GC requested. Reports include raw samples and min/p25/median/p75/p95;
MB/s is input-file decimal MB divided by median wall time. CSV and Parquet MB/s
therefore describe encoded bytes read, not equal units of decoded work.

Runners record current RSS before reading, while the frame is live, and after
close/drop. Dart uses `ProcessInfo.currentRss`; Python asks the standard `ps`
utility because `resource.getrusage` is a high-water mark, not current RSS. The
controller independently polls whole-process RSS through `ps` every 10 ms and
reports its observed peak. A short spike can fall between polls, allocator
retention makes after-close RSS nonzero, and startup/JIT/AOT baselines differ.

This is an honest practical benchmark, not a controlled storage experiment:

* OS page cache is **not** flushed or controlled; warmups normally make reads
  cache-hot. Run on an otherwise idle host and repeat if cold-cache behavior is
  important.
* Python Polars and the Rust/native Polars build may be different versions and
  use different compile flags, allocators, thread pools, compression libraries,
  or CPU dispatch. Their exact versions/build context must accompany results.
* AOT is the default to avoid Dart JIT compilation noise. Python interpreter
  startup and Dart process startup are outside internal scan timings but visible
  to the externally sampled process peak.
* CSV inference is sampled by each engine and is inherently less expressive
  than Parquet. The small fixture is designed to make inference unambiguous,
  but cross-version inference policy changes should be treated as a reported
  physical-type mismatch rather than hidden by coercion.
