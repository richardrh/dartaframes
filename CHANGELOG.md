# Changelog

## Unreleased

- **Breaking:** removed the custom SQLite connection and XLSX reader/writer
  APIs, their native implementations, protocol commands, and dependencies.
  Polars `SqlContext` over registered frames remains supported.
- **Breaking:** removed binding-owned atomic file replacement. Polars writers
  and lazy sinks now write directly to the destination; failed writes may leave
  partial output.
- Delegate Series non-null counts to Polars' count expression.
- Keep the package limited to upstream Polars bindings and necessary Arrow/FFI
  conversion, ownership, and validation.
- These changes require newly built native binaries; existing published
  releases and their pinned metadata have not been replaced.

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
