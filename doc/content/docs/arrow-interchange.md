---
title: Arrow interoperability
weight: 2
---

`dartaframes` includes an Apache Arrow columnar data model implemented in Dart.
It is more than a serialization format: the public API contains typed schemas,
fields, arrays, scalar values, builders, and record batches.

```dart
import 'package:dartaframes/arrow.dart';
```

The primary `package:dartaframes/polars.dart` entrypoint re-exports these types,
so Polars users normally need only one import.

## Choose an entrypoint

Use the two libraries independently according to where the work should run:

| Import | Use it for | Native library required? |
| --- | --- | --- |
| `package:dartaframes/arrow.dart` | Dart-owned schemas, arrays, values, builders, codecs, and record batches | No |
| `package:dartaframes/polars.dart` | CSV/Parquet scans, expressions, DataFrames, Series, SQL, and native computation | Yes |

`polars.dart` re-exports the Arrow API because Polars imports and exports Arrow
values. Importing `arrow.dart` alone does not load Polars or require Rust.

## Scope

The current Arrow port covers the owned value model needed for Polars import,
export, JSON transport, and C interface interoperability. It does **not** claim
to implement the complete Apache Arrow project, including every nested type,
IPC feature, filesystem, dataset, or compute kernel.

Keeping that boundary explicit avoids suggesting compatibility that has not yet
been implemented or tested. The [API coverage audit](/docs/api-coverage/) lists
the exact supported datatypes and interchange paths.

## Use Arrow without Polars

This example creates a record batch entirely in Dart. It requires no native
library and none of its values need to be closed.

```dart
import 'package:dartaframes/arrow.dart';

void main() {
  final nameType = const ArrowUtf8Type();
  final ageType = ArrowIntegerType(32);

  final batch = RecordBatch(
    ArrowSchema([
      ArrowField('name', nameType),
      ArrowField('age', ageType),
    ]),
    [
      ArrowArray(nameType, const [
        ArrowStringValue('Ada'),
        ArrowStringValue('Grace'),
        ArrowStringValue('Linus'),
      ]),
      ArrowArray(ageType, [
        ArrowIntegerValue(42),
        ArrowIntegerValue(37),
        ArrowIntegerValue(55),
      ]),
    ],
  );

  print(batch.length);
  print(const OwnedBatchJsonCodec().encode(batch));
}
```

## Use Polars without constructing Arrow values

Polars can scan files and execute a query directly. Arrow types appear only if
you choose to export the result.

```dart
import 'package:dartaframes/polars.dart';

void main() {
  final polars = Polars.open('/path/to/libdartaframes_polars_ffi.dylib');

  final result = polars
      .scanParquet('sales.parquet')
      .filter(polars.col('year').eq(2026))
      .select([
        polars.col('region'),
        polars.col('revenue'),
      ])
      .collectSync();

  print(result.shapeSync());
  result.close();
}
```

Once verified native assets are published, replace `Polars.open(path)` with
`Polars.native()`.

## Copy a frame into Dart

`DataFrame.exportSync()` returns a Dart-owned `RecordBatch`:

```dart
final frame = polars.scanParquet('people.parquet').collectSync();
final batch = frame.exportSync();

print(batch.schema.fields);
print(batch.columns.first.values);
```

The batch is detached from the native frame and does not need to be closed. A
batch can be imported into the same or another `Polars` runtime:

```dart
final copiedFrame = polars.fromRecordBatchSync(batch);
```

The reverse direction starts with a pure Dart batch and imports it into Polars:

```dart
final type = ArrowIntegerType(32);
final batch = RecordBatch(
  ArrowSchema([ArrowField('value', type)]),
  [
    ArrowArray(type, [
      ArrowIntegerValue(10),
      ArrowIntegerValue(20),
      ArrowIntegerValue(30),
    ]),
  ],
);

final frame = polars.fromRecordBatchSync(batch);
final totals = frame
    .lazy()
    .select([polars.col('value').sum.alias('total')])
    .collectSync();
```

The `RecordBatch` remains a Dart-owned value. `frame` and `totals` are
native-backed Polars values and can be closed when deterministic release is
desired.

## Arrow C Data and C Stream

Use Arrow C Data for compatible native arrays and Arrow C Stream for a sequence
of record batches. These paths use the standard Arrow ABI rather than a
package-specific in-memory layout.

```dart
final frame = polars.scanParquet('people.parquet').collectSync();
final arrow = frame.exportArrowC();
final roundTrip = polars.fromArrowCData(arrow);

arrow.close();
```

Import consumes the Arrow payload. Closing the wrapper afterward releases the
remaining empty C structs. C Data and C Stream wrappers own native memory, so
close them deterministically when they are no longer needed.

## Why it currently lives here

The Arrow code currently shares one package and repository with the Polars
binding because its first consumer, compatibility surface, tests, and releases
are tightly coupled to `dartaframes`. The separate `arrow.dart` entrypoint keeps
the API boundary clean without forcing users to coordinate package versions.

It can be extracted into a separate package and repository later if it gains
independent users, its own release cadence, or adapters unrelated to Polars.
Extraction should happen only after the public datatype and ownership contracts
are stable enough to version independently.
