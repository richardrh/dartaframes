# Changelog

## Unreleased

- Add standard Apache Arrow IPC (metadata V5) stream and file readers and
  writers for the owned logical Arrow model, verified against PyArrow 26.0.0
  fixtures in both directions. See `doc/content/docs/arrow-ipc.md` and
  `example/arrow_ipc.dart`.
- IPC readers decode LZ4_FRAME and ZSTD compressed bodies on the Dart VM and
  LZ4_FRAME on the web. Writers emit uncompressed bodies. Readers are bounded
  by `ArrowIpcLimits` and are little-endian only.
- Add maps, sparse/dense unions, intervals, fixed-size binary, large lists,
  string/binary/list views, decimal32/64/256, and run-end encoded logical types.
- Preserve nested dictionary sidecars through IPC, owned JSON, and batch slicing.
  Keep the narrower Polars copied-batch protocol explicitly guarded.
- Harden owned JSON numeric decoding with bounded canonical decimal strings and
  exact-width floating-point bit strings. Non-canonical forms now fail early.
- Add the pure Dart `libcompress` runtime dependency for IPC decompression.
- `int128`/`uint128` binding extensions are rejected by the IPC writers since
  they have no standard Arrow encoding.
- Enable Dart core lints in local analysis and CI, and add explicit control-flow
  braces without changing runtime behavior.
- Expand public API documentation for errors, runtime entry points, and data
  types.
- Add a pub.dev-discoverable example guide while preserving the existing
  runnable native/Arrow example and its paths.

## 0.1.1

- **Breaking:** removed the custom SQLite connection and XLSX reader/writer
  APIs, their native implementations, protocol commands, and dependencies.
  Polars `SqlContext` over registered frames remains supported.
- **Breaking:** removed binding-owned atomic file replacement. Polars writers
  and lazy sinks now write directly to the destination; failed writes may leave
  partial output.
- Add `readCsvSync` and `readCsv` as conveniences over Polars scan and collect.
- Delegate Series non-null counts to Polars' count expression.
- Keep the package limited to upstream Polars bindings and necessary Arrow/FFI
  conversion, ownership, and validation.
- Require newly built 0.1.1 native binaries; 0.1.0 binaries are not reused.
- Add `init-dart` release initialization with native downloads disabled until
  reviewed checksums are promoted.
- Fix draft-upload scheduling after skipped build jobs and format generated
  native metadata consistently throughout release staging.

## 0.1.0

- Initial stable release of the direct native-handle Dart binding to Rust
  Polars.
- Added lazy and eager dataframe operations, expressions, selectors, SQL, and
  local data-format I/O for the documented partial API.
- Added copied owned-batch interchange, Arrow C Data/C Stream interchange, and
  bounded pull-based batch streaming.
- Added explicit native handle ownership, collection jobs, cancellation, and
  capability discovery.
- Added typed CSV and Parquet writer controls for eager frames and lazy sinks,
  including atomic local replacement behavior.
- Added eager distinct, null dropping, explode, unnest, unpivot, and transpose
  DataFrame operations.
- Added owned local SQLite connections with parameterized query/execute and
  transactional DataFrame writes.
- Added native eager XLSX worksheet reading and writing with typed options,
  schema inference, scalar/date round trips, and atomic local replacement.
- Added checksum-pinned native-assets distribution support for the five
  supported desktop targets.

## 0.1.0-dev.1

- Initial pre-release of the direct native-handle Dart binding to Rust Polars.
- Added lazy and eager dataframe operations, expressions, selectors, SQL, and
  local data-format I/O for the documented partial API.
- Added copied owned-batch interchange, Arrow C Data/C Stream interchange, and
  bounded pull-based batch streaming.
- Added explicit native handle ownership, collection jobs, cancellation, and
  capability discovery.
- Added typed CSV and Parquet writer controls for eager frames and lazy sinks,
  including atomic local replacement behavior.
- Added eager distinct, null dropping, explode, unnest, unpivot, and transpose
  DataFrame operations.
- Added owned local SQLite connections with parameterized query/execute and
  transactional DataFrame writes.
- Added native eager XLSX worksheet reading and writing with typed options,
  schema inference, scalar/date round trips, and atomic local replacement.
- Added dormant, checksum-pinned native-assets distribution support. Automatic
  native download remains disabled until reviewed release metadata is promoted.

This version has not yet been published to pub.dev.
