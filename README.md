# DartAframes

[![CI](https://github.com/richardrh/dartaframes/actions/workflows/ci.yml/badge.svg)](https://github.com/richardrh/dartaframes/actions/workflows/ci.yml)
[![Codecov](https://codecov.io/gh/richardrh/dartaframes/graph/badge.svg)](https://codecov.io/gh/richardrh/dartaframes)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](https://github.com/richardrh/dartaframes/blob/master/LICENSE)

`dartaframes` is a Dart binding to [Polars](https://pola.rs/), backed by Rust
Polars. It provides lazy queries, eager frames and Series, Arrow interchange,
and bounded batch streaming through native handles.

This is a **pre-release with partial Polars 0.55.2 coverage**. See the
[coverage audit](https://github.com/richardrh/dartaframes/blob/master/doc/content/docs/api-coverage.md)
before assuming a Rust or Python Polars API is available.

## Current availability

The package and native binaries are not published yet. This dependency is for a
future pub release:

```yaml
dependencies:
  dartaframes: 0.1.0-dev.1
```

For now, clone the repository, [build the native library with
mise](https://github.com/richardrh/dartaframes/blob/master/doc/content/docs/build-from-source.md),
and open it with `Polars.open(path)`. After the first release, the package will
download and verify the matching prebuilt binary automatically and applications
will use `Polars.native()` without Rust or `mise`.

## Example: print a CSV head

```dart
import 'package:dartaframes/polars.dart';

void main() {
  final polars = Polars.open('/path/to/libdartaframes_polars_ffi.dylib');
  final scan = polars.scanCsv('example/series_arrow_people.csv');
  try {
    final limited = scan.head(3);
    try {
      final frame = limited.collectSync();
      try {
        print(const OwnedBatchJsonCodec().encode(frame.exportSync()));
      } finally {
        frame.close();
      }
    } finally {
      limited.close();
    }
  } finally {
    scan.close();
  }
}
```

Use the actual `.dylib`, `.so`, or `.dll` path. See
[Getting started](https://github.com/richardrh/dartaframes/blob/master/doc/content/docs/getting-started.md)
for ownership guidance and [API reference instructions](https://github.com/richardrh/dartaframes/blob/master/doc/content/docs/api-reference.md)
for callable APIs.

## Public entrypoints

```dart
import 'package:dartaframes/polars.dart'; // Runtime, query, and re-exported Arrow API.
import 'package:dartaframes/arrow.dart';  // Focused owned Arrow value API.
```

Most applications need only `polars.dart`.

## Supported native targets

| OS | Architectures |
| --- | --- |
| macOS | `arm64`, `x64` |
| Linux GNU | `arm64`, `x64` |
| Windows MSVC | `x64` |

Android, iOS, other native targets, and the web are not supported. Distribution
details and its fail-closed verification contract are in
[Native binaries](https://github.com/richardrh/dartaframes/blob/master/doc/content/docs/native-distribution.md).

## Ownership

`Expr`, `LazyFrame`, `DataFrame`, `Series`, query jobs, and batch streams own
native handles. Derived values are independent, but values from different
`Polars` runtimes cannot be mixed. Call the idempotent `close()` promptly;
finalizers are a fallback. Close each streamed batch and the stream itself.

## Development

Requirements: Dart 3.13 or later and the pinned Rust toolchain.

```sh
dart pub get --enforce-lockfile
dart format --output=none --set-exit-if-changed .
dart analyze --fatal-infos
dart test --coverage=coverage
dart test tool/crap_gate_test.dart
python3 -m unittest discover -s tool -p 'test_native_*.py'
cargo test --locked --workspace
```

See [Contributing](https://github.com/richardrh/dartaframes/blob/master/CONTRIBUTING.md),
the [documentation index](https://github.com/richardrh/dartaframes/blob/master/doc/content/docs/_index.md),
and [documentation build instructions](https://github.com/richardrh/dartaframes/blob/master/doc/README.md).
Maintainers should use the documented
[release process](https://github.com/richardrh/dartaframes/blob/master/doc/content/docs/releasing.md)
and [CRAP quality gate](https://github.com/richardrh/dartaframes/blob/master/doc/content/docs/crap-quality-gate.md).

## Security and license

Report vulnerabilities privately through
[GitHub Security Advisories](https://github.com/richardrh/dartaframes/security/advisories/new),
not a public issue. See [SECURITY.md](https://github.com/richardrh/dartaframes/blob/master/SECURITY.md).

Licensed under the [Apache License 2.0](https://github.com/richardrh/dartaframes/blob/master/LICENSE).
