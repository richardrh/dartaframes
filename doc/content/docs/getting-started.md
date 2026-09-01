---
title: Getting started
weight: 1
---

`dartaframes` gives Dart applications native Polars queries and an owned Apache
Arrow data model. Queries stay lazy until `collectSync()` or `collect()` runs
them.

The package and native binaries are **not published yet**. Follow
[Build from source](/docs/build-from-source/) and use `Polars.open(path)` today.
Verified releases will use `Polars.native()` without a local Rust toolchain.

## Scan CSV

Use the full path to the local `.dylib`, `.so`, or `.dll`:

```dart
import 'package:dartaframes/polars.dart';

void main() {
  final polars = Polars.open('/path/to/libdartaframes_polars_ffi.dylib');

  final frame = polars.scanCsv('people.csv').head(5).collectSync();
  print(const OwnedBatchJsonCodec().encode(frame.exportSync()));
}
```

`scanCsv` supports headers, separators, row limits, skipped rows, and date
parsing. Because it creates a `LazyFrame`, later filters and projections can be
pushed into the scan by Polars.

```dart
final adults = polars
    .scanCsv('people.csv', tryParseDates: true)
    .filter(polars.col('age').gt(polars.lit(17)))
    .select([polars.col('name'), polars.col('age')])
    .collectSync();
```

## Scan Parquet

Parquet uses the same lazy query API:

```dart
final totals = polars
    .scanParquet('sales.parquet')
    .filter(polars.col('year').eq(polars.lit(2026)))
    .select([polars.col('region'), polars.col('revenue')])
    .collectSync();
```

Use `nRows` for a bounded scan and `parallel: false` when a workload requires a
serial Parquet reader.

## Arrow results

`exportSync()` copies a frame into a pure Dart `RecordBatch` containing typed
Arrow arrays, fields, and values. It needs no native handle and no `close()`.

For native interoperability, frames and series also support the standard Arrow
C Data Interface, and frames support the Arrow C Stream Interface. See
[Arrow interoperability](/docs/arrow-interchange/).

## Resource lifetime

Examples omit explicit cleanup because native-backed values have finalizers.
This keeps ordinary scripts and application code readable.

Call the idempotent `close()` method when deterministic release matters, such as
inside long-running services, large loops, benchmarks, or stream consumers:

```dart
final query = polars.scanParquet('events.parquet');
final frame = query.collectSync();

// Use frame...

frame.close();
query.close();
```

Derived `Expr`, `LazyFrame`, `DataFrame`, and `Series` values own independent
native handles. Values from different `Polars` runtimes cannot be mixed. Close
every streamed batch and the stream itself when using bounded batch streaming.

Next: [Build from source](/docs/build-from-source/) ·
[Arrow interoperability](/docs/arrow-interchange/) · [API reference](/api/) ·
[API coverage](/docs/api-coverage/)
