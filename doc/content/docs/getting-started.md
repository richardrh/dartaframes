---
title: Getting started
weight: 1
---

`dartaframes` is a Dart binding to Rust Polars. Lazy queries run in Polars, and
the Dart API exposes native resources as owned handles.

The package and native binaries are **not published yet**. For now, follow
[Build from source](/docs/build-from-source/) and use `Polars.open(path)`.

After the first release, the package will select and verify a prebuilt binary
for macOS, Linux, or Windows. Applications will use `Polars.native()` without
installing Rust or `mise`. There is no unverified-download fallback.

## Run a CSV query

Use the full path to the local `.dylib`, `.so`, or `.dll`:

```dart
import 'package:dartaframes/polars.dart';

void main() {
  final polars = Polars.open('/path/to/libdartaframes_polars_ffi.dylib');
  final scan = polars.scanCsv('people.csv');
  try {
    final firstFive = scan.head();
    try {
      final frame = firstFive.collectSync();
      try {
        print(const OwnedBatchJsonCodec().encode(frame.exportSync()));
      } finally {
        frame.close();
      }
    } finally {
      firstFive.close();
    }
  } finally {
    scan.close();
  }
}
```

## Close native handles

Close each `LazyFrame`, `DataFrame`, and other native-backed value when done;
`close()` is idempotent. Derived values own separate handles. The copied
`RecordBatch` returned by `exportSync()` does not need to be closed.

Next: [Build from source](/docs/build-from-source/) · [API reference](/api/) ·
[API coverage](/docs/api-coverage/)
