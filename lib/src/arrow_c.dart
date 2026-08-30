import 'dart:ffi';

/// ABI-exact Arrow C Data Interface array structure.
final class CArrowArray extends Struct {
  @Int64()
  external int length;
  @Int64()
  external int nullCount;
  @Int64()
  external int offset;
  @Int64()
  external int nBuffers;
  @Int64()
  external int nChildren;
  external Pointer<Pointer<Void>> buffers;
  external Pointer<Pointer<CArrowArray>> children;
  external Pointer<CArrowArray> dictionary;
  external Pointer<NativeFunction<Void Function(Pointer<CArrowArray>)>> release;
  external Pointer<Void> privateData;
}

/// ABI-exact Arrow C Data Interface schema structure.
final class CArrowSchema extends Struct {
  external Pointer<Char> format;
  external Pointer<Char> name;
  external Pointer<Char> metadata;
  @Int64()
  external int flags;
  @Int64()
  external int nChildren;
  external Pointer<Pointer<CArrowSchema>> children;
  external Pointer<CArrowSchema> dictionary;
  external Pointer<NativeFunction<Void Function(Pointer<CArrowSchema>)>>
  release;
  external Pointer<Void> privateData;
}

/// ABI-exact Arrow C Stream Interface structure.
final class CArrowArrayStream extends Struct {
  external Pointer<
    NativeFunction<
      Int32 Function(Pointer<CArrowArrayStream>, Pointer<CArrowSchema>)
    >
  >
  getSchema;
  external Pointer<
    NativeFunction<
      Int32 Function(Pointer<CArrowArrayStream>, Pointer<CArrowArray>)
    >
  >
  getNext;
  external Pointer<
    NativeFunction<Pointer<Char> Function(Pointer<CArrowArrayStream>)>
  >
  getLastError;
  external Pointer<NativeFunction<Void Function(Pointer<CArrowArrayStream>)>>
  release;
  external Pointer<Void> privateData;
}

abstract interface class ArrowCBridge {
  ArrowCData allocateData();
  ArrowCStream allocateStream();
  ArrowCData exportFrame(int handle);
  ArrowCData exportSeries(int handle);
  ArrowCStream exportFrameStream(int handle, int maxRows);
  int importFrame(ArrowCData data);
  int importSeries(ArrowCData data);
  int importFrameStream(ArrowCStream stream, int maxBatches, int maxRows);
  Object attachArray(Finalizable owner, Pointer<CArrowArray> pointer);
  Object attachSchema(Finalizable owner, Pointer<CArrowSchema> pointer);
  Object attachStream(Finalizable owner, Pointer<CArrowArrayStream> pointer);
  void deleteArray(Object? attachment, Pointer<CArrowArray> pointer);
  void deleteSchema(Object? attachment, Pointer<CArrowSchema> pointer);
  void deleteStream(Object? attachment, Pointer<CArrowArrayStream> pointer);
}

/// Owns heap-allocated Arrow C Data structs and their release callbacks.
/// [close] and the native finalizers release each live callback exactly once.
final class ArrowCData implements Finalizable {
  /// Internal transport constructor; applications obtain instances from Polars.
  ArrowCData.owned(this._bridge, this.array, this.schema) {
    Object? arrayAttachment;
    try {
      arrayAttachment = _bridge.attachArray(this, array);
      _arrayAttachment = arrayAttachment;
      _schemaAttachment = _bridge.attachSchema(this, schema);
    } catch (_) {
      _bridge.deleteSchema(null, schema);
      _bridge.deleteArray(arrayAttachment, array);
      rethrow;
    }
  }

  final ArrowCBridge _bridge;
  final Pointer<CArrowArray> array;
  final Pointer<CArrowSchema> schema;
  late final Object _arrayAttachment;
  late final Object _schemaAttachment;
  bool _closed = false;
  bool _consumed = false;

  bool get isClosed => _closed;
  bool get isConsumed => _consumed;

  /// Marks the C structs moved into a consumer. For transport implementations.
  void markConsumed() {
    if (_closed || _consumed) throw StateError('Arrow C Data is not available');
    _consumed = true;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _bridge.deleteSchema(_schemaAttachment, schema);
    _bridge.deleteArray(_arrayAttachment, array);
  }
}

/// Owns a heap-allocated Arrow C Stream and its release callback.
final class ArrowCStream implements Finalizable {
  /// Internal transport constructor; applications obtain instances from Polars.
  ArrowCStream.owned(this._bridge, this.pointer) {
    try {
      _attachment = _bridge.attachStream(this, pointer);
    } catch (_) {
      _bridge.deleteStream(null, pointer);
      rethrow;
    }
  }

  final ArrowCBridge _bridge;
  final Pointer<CArrowArrayStream> pointer;
  late final Object _attachment;
  bool _closed = false;
  bool _consumed = false;

  bool get isClosed => _closed;
  bool get isConsumed => _consumed;

  /// Marks the stream moved into a consumer. For transport implementations.
  void markConsumed() {
    if (_closed || _consumed)
      throw StateError('Arrow C Stream is not available');
    _consumed = true;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _bridge.deleteStream(_attachment, pointer);
  }
}
