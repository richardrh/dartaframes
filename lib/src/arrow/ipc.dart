/// Apache Arrow IPC (columnar format version V5) stream and file codecs.
///
/// Implements the encapsulated message format, the streaming format and the
/// random-access file format described at
/// https://arrow.apache.org/docs/format/Columnar.html#serialization-and-interprocess-communication-ipc
/// with metadata from `Schema.fbs`, `Message.fbs` and `File.fbs`. The
/// FlatBuffers metadata is produced and parsed by a small in-tree
/// implementation, so no runtime dependency is required.
///
/// Scope and deliberate limits:
/// * Little-endian only. Big-endian producers are rejected.
/// * Compressed bodies (LZ4_FRAME/ZSTD) are read when the platform helper
///   supports the codec; writers always emit uncompressed bodies.
/// * Dictionary-encoded fields are supported at the top level of a schema
///   (the logical model attaches one dictionary per [ArrowArray]). Nested
///   dictionaries are rejected explicitly.
/// * `int128`/`uint128` are DartAframes binding extensions with no standard
///   encoding and are rejected rather than mis-encoded.
/// * Readers are bounded by [ArrowIpcLimits]; malformed input raises
///   [FormatException] rather than reading out of bounds.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'array.dart';
import 'ipc_compression_vm.dart'
    if (dart.library.js_interop) 'ipc_compression_web.dart'
    as ipc_compression;
import 'batch.dart';
import 'schema.dart';
import 'type.dart';
import 'value.dart';

part 'ipc_body.dart';
part 'ipc_body_extended.dart';
part 'ipc_compression.dart';
part 'ipc_flatbuffers.dart';
part 'ipc_message.dart';
part 'ipc_schema.dart';

/// Resource limits applied while decoding untrusted IPC input.
///
/// Defaults are conservative; trusted callers handling larger data should
/// pass raised limits explicitly.
final class ArrowIpcLimits {
  const ArrowIpcLimits({
    this.maxDepth = 64,
    this.maxFields = 10000,
    this.maxRows = 1 << 20,
    this.maxValues = 4 << 20,
    this.maxBuffers = 1 << 16,
    this.maxMessageBytes = 64 << 20,
    this.maxDictionaries = 1024,
    this.maxBatches = 1 << 20,
  });

  /// Maximum type nesting depth.
  final int maxDepth;

  /// Maximum number of fields (including nested children) in a schema.
  final int maxFields;

  /// Maximum length of any single array node.
  final int maxRows;

  /// Maximum total of all field node lengths decoded for one table. Every
  /// decoded slot materialises a Dart object, so this bounds memory even for
  /// layouts (such as Null) whose wire size is independent of length.
  final int maxValues;

  /// Maximum number of field nodes or buffers in one message.
  final int maxBuffers;

  /// Maximum size of a message's metadata or body.
  final int maxMessageBytes;

  /// Maximum number of dictionary batches.
  final int maxDictionaries;

  /// Maximum number of record batches.
  final int maxBatches;
}

/// An immutable schema plus its record batches.
final class ArrowTable {
  ArrowTable(this.schema, List<RecordBatch> batches)
    : batches = List.unmodifiable(batches) {
    for (var i = 0; i < batches.length; i++) {
      if (batches[i].schema != schema) {
        throw ArgumentError('Batch $i schema does not match table schema');
      }
    }
  }

  final ArrowSchema schema;
  final List<RecordBatch> batches;

  /// Total rows across all batches.
  int get rowCount => batches.fold(0, (sum, b) => sum + b.rowCount);
}

/// Decoded schema plus dictionary ids of top-level dictionary fields in
/// depth-first pre-order, as produced by `_decodeSchema`.
final class _IpcSchema {
  const _IpcSchema(this.schema, this.dictionaryIds);
  final ArrowSchema schema;
  final List<int> dictionaryIds;
}

/// Reads an Arrow IPC stream (a sequence of encapsulated messages).
final class ArrowIpcStreamReader {
  ArrowIpcStreamReader(this.bytes, {this.limits = const ArrowIpcLimits()});
  final Uint8List bytes;
  final ArrowIpcLimits limits;

  ArrowTable readTable() => _guard(() {
    final messages = _MessageCursor(bytes, 0, limits);
    final first = messages.next();
    if (first == null || first.headerType != _headerSchema) {
      throw const FormatException(
        'IPC stream must begin with a Schema message',
      );
    }
    final state = _ReadState(_decodeSchema(first.header, limits), limits);
    for (var m = messages.next(); m != null; m = messages.next()) {
      state.accept(m, allowReplacement: true);
    }
    return state.table();
  });
}

/// Reads an Arrow IPC random-access file (`ARROW1` magic plus footer).
final class ArrowIpcFileReader {
  ArrowIpcFileReader(this.bytes, {this.limits = const ArrowIpcLimits()});
  final Uint8List bytes;
  final ArrowIpcLimits limits;

  ArrowTable readTable() => _guard(() {
    final footer = _readFooter(bytes);
    final schemaTable = footer.table(1);
    if (schemaTable == null) {
      throw const FormatException('IPC file footer has no schema');
    }
    final state = _ReadState(_decodeSchema(schemaTable, limits), limits);
    for (final block in _blocks(footer, 2, limits.maxDictionaries)) {
      state.accept(_readBlock(bytes, block, limits), allowReplacement: false);
    }
    for (final block in _blocks(footer, 3, limits.maxBatches)) {
      state.accept(_readBlock(bytes, block, limits), allowReplacement: false);
    }
    return state.table();
  });
}

/// Writes an Arrow IPC stream terminated by the end-of-stream marker.
final class ArrowIpcStreamWriter {
  ArrowIpcStreamWriter({
    required this.schema,
    required List<RecordBatch> batches,
  }) : batches = List.unmodifiable(batches);
  final ArrowSchema schema;
  final List<RecordBatch> batches;

  Uint8List write() {
    final out = _MessageSink();
    _writeMessages(out, ArrowTable(schema, batches), file: false);
    out.endOfStream();
    return out.takeBytes();
  }
}

/// Writes an Arrow IPC random-access file.
final class ArrowIpcFileWriter {
  ArrowIpcFileWriter({required this.schema, required List<RecordBatch> batches})
    : batches = List.unmodifiable(batches);
  final ArrowSchema schema;
  final List<RecordBatch> batches;

  Uint8List write() {
    final out = _MessageSink()..raw(_fileMagicPadded);
    final blocks = _writeMessages(out, ArrowTable(schema, batches), file: true);
    out.endOfStream();
    final footer = _FbWriter.encode(_footerTable(schema, blocks));
    out
      ..raw(footer)
      ..raw(_int32Bytes(footer.length))
      ..raw(_fileMagic);
    return out.takeBytes();
  }
}

/// Converts model validation errors raised while decoding into
/// [FormatException]s; [UnsupportedError]s propagate unchanged.
T _guard<T>(T Function() body) {
  try {
    return body();
  } on ArgumentError catch (error) {
    throw FormatException('Invalid Arrow IPC data: ${error.message}');
  } on StateError catch (error) {
    throw FormatException('Invalid Arrow IPC data: ${error.message}');
  }
}
