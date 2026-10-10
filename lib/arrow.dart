/// Owned Arrow logical values and standard Apache Arrow IPC interchange.
///
/// This standalone core is separate from the narrower Polars copied-batch
/// protocol. Logical types include maps, unions, intervals, fixed-size binary,
/// views, large lists, and run-end encoding. `int128` and `uint128` are binding
/// extensions rather than Apache Arrow integer types.
///
/// Values are owned, copied Dart objects: there is no zero-copy buffer access
/// or memory mapping. [ArrowIpcStreamReader], [ArrowIpcStreamWriter],
/// [ArrowIpcFileReader] and [ArrowIpcFileWriter] implement the standard
/// Apache Arrow IPC stream and file formats (metadata V5, little-endian only)
/// over in-memory bytes, bounded by [ArrowIpcLimits]. Writers emit
/// uncompressed bodies. Readers decode LZ4_FRAME and ZSTD bodies on the Dart
/// VM via the pure Dart `libcompress` package, and LZ4_FRAME only on the web.
/// `int128`/`uint128` columns cannot be written to IPC.
library dartaframes_arrow;

export 'src/arrow/array.dart';
export 'src/arrow/batch.dart';
export 'src/arrow/codec.dart';
export 'src/arrow/ipc.dart';
export 'src/arrow/schema.dart';
export 'src/arrow/type.dart';
export 'src/arrow/value.dart';
