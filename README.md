# DartAframes

[![CI](https://github.com/richardrh/dartaframes/actions/workflows/ci.yml/badge.svg)](https://github.com/richardrh/dartaframes/actions/workflows/ci.yml)
[![Codecov](https://codecov.io/gh/richardrh/dartaframes/graph/badge.svg)](https://codecov.io/gh/richardrh/dartaframes)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](https://github.com/richardrh/dartaframes/blob/master/LICENSE)

Native [Polars](https://pola.rs/) and Apache Arrow data for Dart.

`dartaframes` runs lazy Polars queries through a Rust native library and brings
the results back through a Dart-native Arrow data model. It includes:

- lazy CSV and Parquet scans with projection and predicate pushdown;
- eager `DataFrame` and `Series` operations;
- owned Arrow arrays, schemas, values, and record batches implemented in Dart;
- zero-copy-compatible Arrow C Data and C Stream interchange; and
- bounded record-batch streaming.

This is a **pre-release with partial Polars 0.55.2 coverage**. The Arrow layer is
also intentionally scoped: it is a Dart port of the Arrow columnar data model
and interchange interfaces used by this package, not a port of the complete
Apache Arrow compute ecosystem. See [API coverage](https://github.com/richardrh/dartaframes/blob/master/doc/content/docs/api-coverage.md)
for the current surface.

## Quick start

The package and native binaries are not published yet. Clone the repository,
[build the native library with mise](https://github.com/richardrh/dartaframes/blob/master/doc/content/docs/build-from-source.md), and
pass its path to `Polars.open`.

```dart
import 'package:dartaframes/polars.dart';

void main() {
  final polars = Polars.open('/path/to/libdartaframes_polars_ffi.dylib');

  final people = polars.scanCsv('people.csv').head(3).collectSync();
  print(const OwnedBatchJsonCodec().encode(people.exportSync()));
}
```

The same lazy API works with Parquet:

```dart
final sales = polars
    .scanParquet('sales.parquet')
    .select([polars.col('region'), polars.col('revenue')])
    .collectSync();
```

After the first release, verified prebuilt binaries will make the usual setup:

```dart
final polars = Polars.native();
```

See [Getting started](https://github.com/richardrh/dartaframes/blob/master/doc/content/docs/getting-started.md) for query examples and
[Build from source](https://github.com/richardrh/dartaframes/blob/master/doc/content/docs/build-from-source.md) for the current setup.

## Arrow for Dart

The repository contains an owned, strongly typed Arrow representation written
in Dart. Polars frames and series can be copied into `RecordBatch` and
`ArrowArray` values, or exchanged with compatible native libraries through the
standard Arrow C Data and C Stream interfaces.

```dart
import 'package:dartaframes/arrow.dart';
```

Use this focused entrypoint when only the Dart Arrow value model is needed.
`package:dartaframes/polars.dart` re-exports it for Polars applications. Read
[Arrow interoperability](https://github.com/richardrh/dartaframes/blob/master/doc/content/docs/arrow-interchange.md) for scope,
ownership, and examples.

```dart
import 'package:dartaframes/arrow.dart'; // Pure Dart, no native library.
```

Use Polars independently for native file scans and computation:

```dart
import 'package:dartaframes/polars.dart';

final polars = Polars.open('/path/to/libdartaframes_polars_ffi.dylib');
final frame = polars.scanParquet('sales.parquet').collectSync();
```

Bridge the two APIs with `frame.exportSync()` and
`polars.fromRecordBatchSync(batch)`.

## Write files and use SQLite

CSV and Parquet writers accept typed options on eager frames and lazy sinks:

```dart
frame.writeCsvSync(
  'output.csv',
  options: const CsvWriteOptions(separator: ';'),
);
frame.writeParquetSync(
  'output.parquet',
  options: const ParquetWriteOptions(compression: ParquetCompression.zstd),
);
```

SQLite is local, parameterized, native, and does not require Python:

```dart
final database = polars.openSqlite('data/app.db');
database.executeSync(
  'INSERT INTO people(name) VALUES (?1)',
  parameters: ['Ada'],
);
final people = database.querySync('SELECT * FROM people');
database.writeFrameSync(people, 'people_copy');
```

`DatabaseConnection` and returned `DataFrame` objects are owned handles. Call
`close()` when deterministic release matters.

## Resource lifetime

Native-backed objects have finalizers, so normal application code can stay
idiomatic and does not need nested `try`/`finally` blocks. `close()` remains
available and idempotent when deterministic release matters, especially in
servers, loops, benchmarks, and batch-stream consumers.

```dart
final query = polars.scanCsv('events.csv');
final frame = query.collectSync();

// Use frame...

frame.close();
query.close();
```

Derived native values own independent handles. Values from different `Polars`
runtimes cannot be mixed. Pure Dart Arrow values such as `RecordBatch` do not
need to be closed.

## Public entrypoints

```dart
import 'package:dartaframes/polars.dart'; // Polars plus the Arrow value API.
import 'package:dartaframes/arrow.dart';  // Arrow values without Polars APIs.
```

Most applications need only `polars.dart`.

## Supported native targets

| OS | Architectures |
| --- | --- |
| macOS | `arm64`, `x64` |
| Linux GNU | `arm64`, `x64` |
| Windows MSVC | `x64` |

Android, iOS, other native targets, and the web are not supported. See
[Native binaries](https://github.com/richardrh/dartaframes/blob/master/doc/content/docs/native-distribution.md) for distribution and
verification details.

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

See [Contributing](https://github.com/richardrh/dartaframes/blob/master/CONTRIBUTING.md), the [documentation index](https://github.com/richardrh/dartaframes/blob/master/doc/content/docs/_index.md),
and the [release process](https://github.com/richardrh/dartaframes/blob/master/doc/content/docs/releasing.md).

## Security and license

Report vulnerabilities privately through
[GitHub Security Advisories](https://github.com/richardrh/dartaframes/security/advisories/new),
not a public issue. See [SECURITY.md](https://github.com/richardrh/dartaframes/blob/master/SECURITY.md).

Licensed under the [Apache License 2.0](https://github.com/richardrh/dartaframes/blob/master/LICENSE).
