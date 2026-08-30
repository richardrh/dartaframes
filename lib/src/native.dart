import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'errors.dart';
import 'arrow_c.dart';
import 'protocol.dart';

final class _DfBuffer extends Struct {
  external Pointer<Uint8> data;
  @Uint64()
  external int length;
  @Int32()
  external int status;
}

typedef _AbiNative = Uint32 Function();
typedef _AbiDart = int Function();
typedef _InvokeNative = Int32 Function(
  Pointer<Uint8>,
  Uint64,
  Pointer<_DfBuffer>,
);
typedef _InvokeDart = int Function(Pointer<Uint8>, int, Pointer<_DfBuffer>);
typedef _BufferFreeNative = Void Function(Pointer<_DfBuffer>);
typedef _BufferFreeDart = void Function(Pointer<_DfBuffer>);
typedef _ReleaseNative = Int32 Function(Uint64);
typedef _ReleaseDart = int Function(int);
typedef _TokenNewNative = Pointer<Void> Function(Uint64);
typedef _TokenNewDart = Pointer<Void> Function(int);
typedef _TokenReleaseNative = Void Function(Pointer<Void>);
typedef _TokenReleaseDart = void Function(Pointer<Void>);
typedef _ArrowArrayNewNative = Pointer<CArrowArray> Function();
typedef _ArrowSchemaNewNative = Pointer<CArrowSchema> Function();
typedef _ArrowStreamNewNative = Pointer<CArrowArrayStream> Function();
typedef _ArrowArrayDeleteNative = Void Function(Pointer<CArrowArray>);
typedef _ArrowSchemaDeleteNative = Void Function(Pointer<CArrowSchema>);
typedef _ArrowStreamDeleteNative = Void Function(Pointer<CArrowArrayStream>);
typedef _ExportDataNative = Int32 Function(
  Uint64,
  Pointer<CArrowArray>,
  Pointer<CArrowSchema>,
);
typedef _ExportDataDart = int Function(
  int,
  Pointer<CArrowArray>,
  Pointer<CArrowSchema>,
);
typedef _ImportDataNative = Int32 Function(
  Pointer<CArrowArray>,
  Pointer<CArrowSchema>,
  Pointer<Uint64>,
);
typedef _ImportDataDart = int Function(
  Pointer<CArrowArray>,
  Pointer<CArrowSchema>,
  Pointer<Uint64>,
);
typedef _ExportStreamNative = Int32 Function(
  Uint64,
  Uint64,
  Pointer<CArrowArrayStream>,
);
typedef _ExportStreamDart = int Function(int, int, Pointer<CArrowArrayStream>);
typedef _ImportStreamNative = Int32 Function(
  Pointer<CArrowArrayStream>,
  Uint64,
  Uint64,
  Pointer<Uint64>,
);
typedef _ImportStreamDart = int Function(
  Pointer<CArrowArrayStream>,
  int,
  int,
  Pointer<Uint64>,
);

final class _FinalizerAttachment {
  const _FinalizerAttachment(this.detach, this.pointer);
  final Object detach;
  final Pointer<Void> pointer;
}

/// Protocol client backed by the stable `df_abi_version`, `df_invoke`,
/// `df_buffer_free`, `df_handle_release`, `df_handle_token_new`, and
/// `df_handle_token_release` C ABI symbols.
final class NativeProtocolClient extends ProtocolClient {
  NativeProtocolClient.open(String path)
    : this.fromLibrary(DynamicLibrary.open(path));

  NativeProtocolClient.fromLibrary(this.library)
    : super(_NativeInvoker(library));

  factory NativeProtocolClient.process() =>
      NativeProtocolClient.fromLibrary(DynamicLibrary.process());

  /// Strongly held for the complete client/finalizer lifetime.
  final DynamicLibrary library;
}

/// Handwritten FFI transport. Kept separate to avoid command/transport method
/// name collisions on [ProtocolClient].
final class _NativeInvoker implements ProtocolInvoker, ArrowCBridge {
  static const int _maximumBufferLength = 64 * 1024 * 1024;
  _NativeInvoker(this.library)
    : _abi = library.lookupFunction<_AbiNative, _AbiDart>('df_abi_version'),
      _invoke = library.lookupFunction<_InvokeNative, _InvokeDart>('df_invoke'),
      _bufferFree = library.lookupFunction<_BufferFreeNative, _BufferFreeDart>(
        'df_buffer_free',
      ),
      _release = library.lookupFunction<_ReleaseNative, _ReleaseDart>(
        'df_handle_release',
      ),
      _tokenNew = library.lookupFunction<_TokenNewNative, _TokenNewDart>(
        'df_handle_token_new',
      ),
      _tokenReleasePointer = library
          .lookup<NativeFunction<_TokenReleaseNative>>(
            'df_handle_token_release',
          ),
      _arrayNew = library
          .lookupFunction<_ArrowArrayNewNative, _ArrowArrayNewNative>(
            'df_arrow_array_new',
          ),
      _schemaNew = library
          .lookupFunction<_ArrowSchemaNewNative, _ArrowSchemaNewNative>(
            'df_arrow_schema_new',
          ),
      _streamNew = library
          .lookupFunction<_ArrowStreamNewNative, _ArrowStreamNewNative>(
            'df_arrow_stream_new',
          ),
      _arrayDeletePointer = library
          .lookup<NativeFunction<_ArrowArrayDeleteNative>>(
            'df_arrow_array_delete',
          ),
      _schemaDeletePointer = library
          .lookup<NativeFunction<_ArrowSchemaDeleteNative>>(
            'df_arrow_schema_delete',
          ),
      _streamDeletePointer = library
          .lookup<NativeFunction<_ArrowStreamDeleteNative>>(
            'df_arrow_stream_delete',
          ),
      _frameExportArrow = library
          .lookupFunction<_ExportDataNative, _ExportDataDart>(
            'df_frame_export_arrow',
          ),
      _seriesExportArrow = library
          .lookupFunction<_ExportDataNative, _ExportDataDart>(
            'df_series_export_arrow',
          ),
      _frameImportArrow = library
          .lookupFunction<_ImportDataNative, _ImportDataDart>(
            'df_frame_import_arrow',
          ),
      _seriesImportArrow = library
          .lookupFunction<_ImportDataNative, _ImportDataDart>(
            'df_series_import_arrow',
          ),
      _frameExportStream = library
          .lookupFunction<_ExportStreamNative, _ExportStreamDart>(
            'df_frame_export_arrow_stream',
          ),
      _frameImportStream = library
          .lookupFunction<_ImportStreamNative, _ImportStreamDart>(
            'df_frame_import_arrow_stream',
          ) {
    final version = _abi();
    if (version != 2) {
      throw ProtocolMismatchException(
        'Expected ABI 2, native library reports $version',
      );
    }
    _finalizer = NativeFinalizer(_tokenReleasePointer);
    _tokenRelease = _tokenReleasePointer.asFunction<_TokenReleaseDart>();
    _arrayFinalizer = NativeFinalizer(_arrayDeletePointer.cast());
    _schemaFinalizer = NativeFinalizer(_schemaDeletePointer.cast());
    _streamFinalizer = NativeFinalizer(_streamDeletePointer.cast());
    _arrayDelete = _arrayDeletePointer
        .asFunction<void Function(Pointer<CArrowArray>)>();
    _schemaDelete = _schemaDeletePointer
        .asFunction<void Function(Pointer<CArrowSchema>)>();
    _streamDelete = _streamDeletePointer
        .asFunction<void Function(Pointer<CArrowArrayStream>)>();
  }

  // Kept for the lifetime of this client so symbols and finalizer remain valid.
  final DynamicLibrary library;
  final _AbiDart _abi;
  final _InvokeDart _invoke;
  final _BufferFreeDart _bufferFree;
  final _ReleaseDart _release;
  final _TokenNewDart _tokenNew;
  final Pointer<NativeFunction<_TokenReleaseNative>> _tokenReleasePointer;
  late final NativeFinalizer _finalizer;
  late final _TokenReleaseDart _tokenRelease;
  final _ArrowArrayNewNative _arrayNew;
  final _ArrowSchemaNewNative _schemaNew;
  final _ArrowStreamNewNative _streamNew;
  final Pointer<NativeFunction<_ArrowArrayDeleteNative>> _arrayDeletePointer;
  final Pointer<NativeFunction<_ArrowSchemaDeleteNative>> _schemaDeletePointer;
  final Pointer<NativeFunction<_ArrowStreamDeleteNative>> _streamDeletePointer;
  final _ExportDataDart _frameExportArrow;
  final _ExportDataDart _seriesExportArrow;
  final _ImportDataDart _frameImportArrow;
  final _ImportDataDart _seriesImportArrow;
  final _ExportStreamDart _frameExportStream;
  final _ImportStreamDart _frameImportStream;
  late final NativeFinalizer _arrayFinalizer;
  late final NativeFinalizer _schemaFinalizer;
  late final NativeFinalizer _streamFinalizer;
  late final void Function(Pointer<CArrowArray>) _arrayDelete;
  late final void Function(Pointer<CArrowSchema>) _schemaDelete;
  late final void Function(Pointer<CArrowArrayStream>) _streamDelete;

  Map<String, Object?> invokeSync(Map<String, Object?> request) {
    final bytes = utf8.encode(jsonEncode(request));
    if (bytes.length > _maximumBufferLength) {
      throw const InvalidRequestException('Request exceeds 64 MiB');
    }
    final requestPointer = calloc<Uint8>(bytes.length);
    final output = calloc<_DfBuffer>();
    try {
      requestPointer.asTypedList(bytes.length).setAll(0, bytes);
      final callStatus = _invoke(requestPointer, bytes.length, output);
      if (callStatus < 0 || callStatus > 2 || output.ref.status != callStatus) {
        throw InternalPolarsException(
          'df_invoke status mismatch: return=$callStatus, '
          'buffer=${output.ref.status}',
        );
      }
      if (output.ref.data == nullptr) {
        throw InternalPolarsException(
          'df_invoke returned no response (status $callStatus)',
        );
      }
      if (output.ref.length <= 0 || output.ref.length > _maximumBufferLength) {
        throw InternalPolarsException(
          'df_invoke returned invalid buffer length ${output.ref.length}',
        );
      }
      final copied = Uint8List.fromList(
        output.ref.data.asTypedList(output.ref.length),
      );
      final decoded = jsonDecode(utf8.decode(copied));
      if (decoded is! Map) {
        throw const InternalPolarsException('Native response is not an object');
      }
      final response = decoded.cast<String, Object?>();
      if ((callStatus == 0) != (response['ok'] == true)) {
        throw InternalPolarsException(
          'df_invoke status $callStatus is inconsistent with response.ok',
        );
      }
      return response;
    } finally {
      if (output.ref.data != nullptr) _bufferFree(output);
      calloc.free(output);
      calloc.free(requestPointer);
    }
  }

  Future<Map<String, Object?>> invoke(Map<String, Object?> request) async =>
      invokeSync(request);

  void releaseHandle(int handle) {
    final status = _release(handle);
    if (status != 0) {
      throw StaleHandleException(
        'df_handle_release failed with status $status',
      );
    }
  }

  Object? attachHandleFinalizer(Object owner, int handle) {
    final token = _tokenNew(handle);
    if (token == nullptr) {
      throw const InternalPolarsException('df_handle_token_new returned null');
    }
    final detach = Object();
    if (owner is! Finalizable) {
      _tokenRelease(token);
      throw ArgumentError.value(owner, 'owner', 'must implement Finalizable');
    }
    try {
      _finalizer.attach(owner, token, detach: detach, externalSize: 64);
    } catch (_) {
      _tokenRelease(token);
      rethrow;
    }
    return _FinalizerAttachment(detach, token);
  }

  bool detachHandleFinalizer(Object? token) {
    if (token is! _FinalizerAttachment) return false;
    _finalizer.detach(token.detach);
    _tokenRelease(token.pointer);
    return true;
  }

  Never _arrowFailure(
    String operation,
    int status,
  ) => throw InternalPolarsException(
    '$operation failed with native status $status; only the advertised flat Arrow tranche is supported',
  );

  ArrowCData allocateData() {
    final array = _arrayNew();
    final schema = _schemaNew();
    if (array == nullptr || schema == nullptr) {
      if (array != nullptr) _arrayDelete(array);
      if (schema != nullptr) _schemaDelete(schema);
      throw const InternalPolarsException(
        'Could not allocate Arrow C Data structs',
      );
    }
    return ArrowCData.owned(this, array, schema);
  }

  ArrowCStream allocateStream() {
    final stream = _streamNew();
    if (stream == nullptr) {
      throw const InternalPolarsException('Could not allocate Arrow C Stream');
    }
    return ArrowCStream.owned(this, stream);
  }

  ArrowCData _exportData(
    int handle,
    _ExportDataDart function,
    String operation,
  ) {
    final data = allocateData();
    final status = function(handle, data.array, data.schema);
    if (status != 0) {
      data.close();
      _arrowFailure(operation, status);
    }
    return data;
  }

  ArrowCData exportFrame(int handle) =>
      _exportData(handle, _frameExportArrow, 'df_frame_export_arrow');
  ArrowCData exportSeries(int handle) =>
      _exportData(handle, _seriesExportArrow, 'df_series_export_arrow');

  int _importData(ArrowCData data, _ImportDataDart function, String operation) {
    final output = calloc<Uint64>();
    try {
      data.markConsumed();
      final status = function(data.array, data.schema, output);
      if (status != 0) _arrowFailure(operation, status);
      if (output.value <= 0) _arrowFailure(operation, 1);
      return output.value;
    } finally {
      calloc.free(output);
    }
  }

  int importFrame(ArrowCData data) =>
      _importData(data, _frameImportArrow, 'df_frame_import_arrow');
  int importSeries(ArrowCData data) =>
      _importData(data, _seriesImportArrow, 'df_series_import_arrow');

  ArrowCStream exportFrameStream(int handle, int maxRows) {
    final stream = allocateStream();
    final status = _frameExportStream(handle, maxRows, stream.pointer);
    if (status != 0) {
      stream.close();
      _arrowFailure('df_frame_export_arrow_stream', status);
    }
    return stream;
  }

  int importFrameStream(ArrowCStream stream, int maxBatches, int maxRows) {
    final output = calloc<Uint64>();
    try {
      stream.markConsumed();
      final status = _frameImportStream(
        stream.pointer,
        maxBatches,
        maxRows,
        output,
      );
      if (status != 0) _arrowFailure('df_frame_import_arrow_stream', status);
      if (output.value <= 0) _arrowFailure('df_frame_import_arrow_stream', 1);
      return output.value;
    } finally {
      calloc.free(output);
    }
  }

  Object _attachArrow(
    Finalizable owner,
    Pointer<Void> pointer,
    NativeFinalizer finalizer,
  ) {
    final detach = Object();
    finalizer.attach(owner, pointer, detach: detach, externalSize: 128);
    return detach;
  }

  Object attachArray(Finalizable owner, Pointer<CArrowArray> pointer) =>
      _attachArrow(owner, pointer.cast(), _arrayFinalizer);
  Object attachSchema(Finalizable owner, Pointer<CArrowSchema> pointer) =>
      _attachArrow(owner, pointer.cast(), _schemaFinalizer);
  Object attachStream(Finalizable owner, Pointer<CArrowArrayStream> pointer) =>
      _attachArrow(owner, pointer.cast(), _streamFinalizer);

  void deleteArray(Object? attachment, Pointer<CArrowArray> pointer) {
    if (attachment != null) _arrayFinalizer.detach(attachment);
    _arrayDelete(pointer);
  }

  void deleteSchema(Object? attachment, Pointer<CArrowSchema> pointer) {
    if (attachment != null) _schemaFinalizer.detach(attachment);
    _schemaDelete(pointer);
  }

  void deleteStream(Object? attachment, Pointer<CArrowArrayStream> pointer) {
    if (attachment != null) _streamFinalizer.detach(attachment);
    _streamDelete(pointer);
  }
}
