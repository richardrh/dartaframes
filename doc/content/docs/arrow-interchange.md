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

## Scope

The current Arrow port covers the owned value model needed for Polars import,
export, JSON transport, and C interface interoperability. It does **not** claim
to implement the complete Apache Arrow project, including every nested type,
IPC feature, filesystem, dataset, or compute kernel.

Keeping that boundary explicit avoids suggesting compatibility that has not yet
been implemented or tested. The [API coverage audit](/docs/api-coverage/) lists
the exact supported datatypes and interchange paths.

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
