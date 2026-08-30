# DartAframes

[![CI](https://github.com/richardrh/dartframes/actions/workflows/ci.yml/badge.svg)](https://github.com/richardrh/dartframes/actions/workflows/ci.yml)
[![Codecov](https://codecov.io/gh/richardrh/dartframes/graph/badge.svg)](https://codecov.io/gh/richardrh/dartframes)
[![pub package](https://img.shields.io/pub/v/dartaframes_polars?label=pub)](https://pub.dev/packages/dartaframes_polars)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

`dartaframes_polars` is a Dart binding to [Polars](https://pola.rs/), backed by
Rust Polars. Dart operations act on direct native handles rather than building
a second query representation. Lazy queries therefore remain in Polars until
they are collected.

The package supports Arrow C Data and C Stream interchange, plus bounded,
pull-based batch streaming with native backpressure. It is currently a
**pre-release with a partial API**: useful query, expression, eager, I/O, SQL,
and selector surfaces exist, but this is not complete Polars parity or a
complete Arrow implementation.

## Installation

The first pub release has not been published. Once it is available, an
application will need only this package:

```yaml
dependencies:
  dartaframes_polars: 0.1.0-dev.1
```

The intended installed-package entry point is pathless:

```dart
final polars = Polars.native();
```

Native auto-download is deliberately **not active yet**. It will remain off
until the first GitHub native release, its checksums, and byte sizes have been
reviewed and promoted into the package. For current source development, clone
this repository, build the Rust library, and use `Polars.open(path)` instead.
There is no unverified download or automatic source-build fallback.

## Example: print a CSV head

This shortened version of [`example/series_arrow_head.dart`](example/series_arrow_head.dart)
collects three rows and writes the owned Arrow batch representation to stdout:

```dart
import 'dart:convert';
import 'dart:io';

import 'package:dartaframes_polars/dartaframes_polars.dart';

void main() {
  final polars = Polars.native();
  final scan = polars.scanCsv('people.csv');
  try {
    final limited = scan.head(3);
    try {
      final head = limited.collectSync();
      try {
        final batch = head.exportSync();
        stdout.writeln(jsonEncode(const OwnedBatchJsonCodec().toJson(batch)));
      } finally {
        head.close();
      }
    } finally {
      limited.close();
    }
  } finally {
    scan.close();
  }
}
```

Run the complete example after a local build on macOS:

```sh
cargo build --package dartaframes_polars_ffi
dart run example/series_arrow_head.dart \
  --library "$PWD/target/debug/libdartaframes_polars_ffi.dylib"
```

Use the corresponding `.so` path on Linux or `.dll` path on Windows.

## Native targets and distribution

Reviewed native releases are designed for:

| OS | Architectures |
| --- | --- |
| macOS | Apple silicon (`arm64`), Intel (`x64`) |
| Linux GNU | `arm64`, `x64` |
| Windows MSVC | `x64` |

Android, iOS, other targets, and the web are not supported. Dart's web runtime
cannot load this native library.

After native release metadata is activated, the native-assets hook will check
its shared cache on the first build/run. It verifies cached files by pinned
size and SHA-256; otherwise it downloads the target-specific raw library over
HTTPS from the canonical GitHub Release, restricts redirects and response size,
verifies it, and installs it atomically. A missing network and missing verified
cache entry fail closed. See [native distribution](doc/native-distribution.md).

## Status

- Rust uses Polars 0.55.2 behind ABI/protocol version 2.
- Lazy plans execute in native Polars; `collectSync()` blocks, while `collect()`
  uses the native collection-job path.
- Arrow C Data/C Stream and bounded `BatchStream` APIs are available for their
  documented supported data.
- The API is intentionally partial. Check the [API coverage audit](API_COVERAGE.md)
  rather than assuming a Python or Rust Polars method is bound.
- The native-release CI matrix is where the locked Rust workspace is compiled
  and tested and native Dart integration tests run; every matrix job must pass
  before release. The regular quality workflow runs Dart tests and its
  coverage/complexity gate.
- There is no web implementation.

The Codecov badge reports repository coverage only when coverage upload is
enabled for the canonical repository; the checked-in quality workflow always
produces LCOV as a workflow artifact.

## Architecture and ownership

| Component | Purpose |
| --- | --- |
| `lib/dartaframes_polars.dart` | Explicit `Polars` runtime, expressions, frames, queries, jobs, streaming, and FFI API |
| `lib/dartaframes_arrow.dart` | Pure-Dart Arrow value/schema types and copied-batch codec |
| `native/polars_ffi/` | Rust `cdylib` implementing the native protocol over Polars |
| `protocol/` | Protocol and capability reference |

Every `Expr`, `LazyFrame`, `DataFrame`, `Series`, query job, and batch stream
owns a native handle. Derived values are independent, but values from different
`Polars` runtimes cannot be mixed. Call the idempotent `close()` method as soon
as ownership ends; finalizers are only a fallback. Close each batch returned by
a `BatchStream` separately, and close or cancel the stream itself.

## Development

Requirements: Dart 3.13 or later and the pinned Rust toolchain.

```sh
dart pub get --enforce-lockfile
dart format --output=none --set-exit-if-changed .
dart analyze --fatal-infos
dart test --coverage=coverage
dart test tool/crap_gate_test.dart
dart run coverage:format_coverage --lcov --in=coverage --out=coverage/lcov.info \
  --packages=.dart_tool/package_config.json --report-on=lib
dart run tool/crap_gate.dart --threshold=30 --baseline=tool/crap_baseline.json
python3 -m unittest discover -s tool -p 'test_native_*.py'
cargo fmt --all -- --check
dart pub publish --dry-run
cargo test --locked --workspace
cargo build --locked --package dartaframes_polars_ffi
```

For a focused native integration run on macOS:

```sh
DARTAFRAMES_NATIVE_LIBRARY="$PWD/target/debug/libdartaframes_polars_ffi.dylib" \
  dart test test/native_integration_test.dart test/io_relational_native_test.dart
```

Benchmarks live under `benchmark/`; examples under `example/`; documentation
under `doc/`. Start with the [documentation index](doc/README.md) and
[`CONTRIBUTING.md`](CONTRIBUTING.md).

## Releases and security

Releases build and test all supported native targets, verify a complete asset
set, review and promote checksums into Dart source, and only then publish the
package. The workflow does not publish to pub automatically. See the
[release process](doc/releasing.md) and [changelog](CHANGELOG.md).

Report vulnerabilities privately through
[GitHub Security Advisories](https://github.com/richardrh/dartframes/security/advisories/new),
not a public issue. See [`SECURITY.md`](SECURITY.md).

## License

Licensed under the [Apache License 2.0](LICENSE).
