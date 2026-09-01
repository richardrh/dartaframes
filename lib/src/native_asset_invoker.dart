import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'arrow_c.dart';
import 'errors.dart';
import 'native_asset_bindings.dart';
import 'protocol.dart';

final class _NativeAssetFinalizerAttachment {
  const _NativeAssetFinalizerAttachment(this.detach, this.pointer);

  final Object detach;
  final Pointer<Void> pointer;
}

/// A protocol client resolved through the package's bundled native code asset.
///
/// Normally constructed by `Polars.native()`. Existing path/process clients
/// remain available as expert and development hooks.
final class NativeAssetProtocolClient extends ProtocolClient {
  NativeAssetProtocolClient() : super(_NativeAssetInvoker());
}

final class _NativeAssetInvoker implements ProtocolInvoker, ArrowCBridge {
  static const int _maximumBufferLength = 64 * 1024 * 1024;

  _NativeAssetInvoker() {
    late final int version;
    try {
      version = nativeAssetAbiVersion();
    } catch (error) {
      throw StateError(
        'Polars.native() could not resolve the dartaframes native '
        'asset. Reviewed release metadata may not be activated for this '
        'target; use Polars.open(path) for a development library. '
        'Resolver error: $error',
      );
    }
    if (version != 2) {
      throw ProtocolMismatchException(
        'Expected ABI 2, native asset reports $version',
      );
    }
    _tokenReleasePointer =
        Native.addressOf<NativeFunction<NativeAssetTokenRelease>>(
          nativeAssetHandleTokenRelease,
        );
    _finalizer = NativeFinalizer(_tokenReleasePointer);
    _arrayDeletePointer =
        Native.addressOf<NativeFunction<NativeAssetArrowArrayDelete>>(
          nativeAssetArrowArrayDelete,
        );
    _schemaDeletePointer =
        Native.addressOf<NativeFunction<NativeAssetArrowSchemaDelete>>(
          nativeAssetArrowSchemaDelete,
        );
    _streamDeletePointer =
        Native.addressOf<NativeFunction<NativeAssetArrowStreamDelete>>(
          nativeAssetArrowStreamDelete,
        );
    _arrayFinalizer = NativeFinalizer(_arrayDeletePointer.cast());
    _schemaFinalizer = NativeFinalizer(_schemaDeletePointer.cast());
    _streamFinalizer = NativeFinalizer(_streamDeletePointer.cast());
  }

  late final Pointer<NativeFunction<NativeAssetTokenRelease>>
  _tokenReleasePointer;
  late final NativeFinalizer _finalizer;
  late final Pointer<NativeFunction<NativeAssetArrowArrayDelete>>
  _arrayDeletePointer;
  late final Pointer<NativeFunction<NativeAssetArrowSchemaDelete>>
  _schemaDeletePointer;
  late final Pointer<NativeFunction<NativeAssetArrowStreamDelete>>
  _streamDeletePointer;
  late final NativeFinalizer _arrayFinalizer;
  late final NativeFinalizer _schemaFinalizer;
  late final NativeFinalizer _streamFinalizer;

  Map<String, Object?> invokeSync(Map<String, Object?> request) {
    final bytes = utf8.encode(jsonEncode(request));
    if (bytes.length > _maximumBufferLength) {
      throw const InvalidRequestException('Request exceeds 64 MiB');
    }
    final requestPointer = calloc<Uint8>(bytes.length);
    final output = calloc<NativeAssetBuffer>();
    try {
      requestPointer.asTypedList(bytes.length).setAll(0, bytes);
      final callStatus = nativeAssetInvoke(
        requestPointer,
        bytes.length,
        output,
      );
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
      if (output.ref.data != nullptr) nativeAssetBufferFree(output);
      calloc.free(output);
      calloc.free(requestPointer);
    }
  }

  Future<Map<String, Object?>> invoke(Map<String, Object?> request) async =>
      invokeSync(request);

  void releaseHandle(int handle) {
    final status = nativeAssetHandleRelease(handle);
    if (status != 0) {
      throw StaleHandleException(
        'df_handle_release failed with status $status',
      );
    }
  }

  Object? attachHandleFinalizer(Object owner, int handle) {
    final token = nativeAssetHandleTokenNew(handle);
    if (token == nullptr) {
      throw const InternalPolarsException('df_handle_token_new returned null');
    }
    final detach = Object();
    if (owner is! Finalizable) {
      nativeAssetHandleTokenRelease(token);
      throw ArgumentError.value(owner, 'owner', 'must implement Finalizable');
    }
    try {
      _finalizer.attach(owner, token, detach: detach, externalSize: 64);
    } catch (_) {
      nativeAssetHandleTokenRelease(token);
      rethrow;
    }
    return _NativeAssetFinalizerAttachment(detach, token);
  }

  bool detachHandleFinalizer(Object? token) {
    if (token is! _NativeAssetFinalizerAttachment) return false;
    _finalizer.detach(token.detach);
    nativeAssetHandleTokenRelease(token.pointer);
    return true;
  }

  Never _arrowFailure(
    String operation,
    int status,
  ) => throw InternalPolarsException(
    '$operation failed with native status $status; only the advertised flat Arrow tranche is supported',
  );

  @override
  ArrowCData allocateData() {
    final array = nativeAssetArrowArrayNew();
    final schema = nativeAssetArrowSchemaNew();
    if (array == nullptr || schema == nullptr) {
      if (array != nullptr) nativeAssetArrowArrayDelete(array);
      if (schema != nullptr) nativeAssetArrowSchemaDelete(schema);
      throw const InternalPolarsException(
        'Could not allocate Arrow C Data structs',
      );
    }
    return ArrowCData.owned(this, array, schema);
  }

  @override
  ArrowCStream allocateStream() {
    final stream = nativeAssetArrowStreamNew();
    if (stream == nullptr) {
      throw const InternalPolarsException('Could not allocate Arrow C Stream');
    }
    return ArrowCStream.owned(this, stream);
  }

  ArrowCData _exportData(
    int handle,
    int Function(int, Pointer<CArrowArray>, Pointer<CArrowSchema>) function,
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

  @override
  ArrowCData exportFrame(int handle) =>
      _exportData(handle, nativeAssetFrameExportArrow, 'df_frame_export_arrow');

  @override
  ArrowCData exportSeries(int handle) => _exportData(
    handle,
    nativeAssetSeriesExportArrow,
    'df_series_export_arrow',
  );

  int _importData(
    ArrowCData data,
    int Function(Pointer<CArrowArray>, Pointer<CArrowSchema>, Pointer<Uint64>)
    function,
    String operation,
  ) {
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

  @override
  int importFrame(ArrowCData data) =>
      _importData(data, nativeAssetFrameImportArrow, 'df_frame_import_arrow');

  @override
  int importSeries(ArrowCData data) =>
      _importData(data, nativeAssetSeriesImportArrow, 'df_series_import_arrow');

  @override
  ArrowCStream exportFrameStream(int handle, int maxRows) {
    final stream = allocateStream();
    final status = nativeAssetFrameExportArrowStream(
      handle,
      maxRows,
      stream.pointer,
    );
    if (status != 0) {
      stream.close();
      _arrowFailure('df_frame_export_arrow_stream', status);
    }
    return stream;
  }

  @override
  int importFrameStream(ArrowCStream stream, int maxBatches, int maxRows) {
    final output = calloc<Uint64>();
    try {
      stream.markConsumed();
      final status = nativeAssetFrameImportArrowStream(
        stream.pointer,
        maxBatches,
        maxRows,
        output,
      );
      if (status != 0) {
        _arrowFailure('df_frame_import_arrow_stream', status);
      }
      if (output.value <= 0) {
        _arrowFailure('df_frame_import_arrow_stream', 1);
      }
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

  @override
  Object attachArray(Finalizable owner, Pointer<CArrowArray> pointer) =>
      _attachArrow(owner, pointer.cast(), _arrayFinalizer);

  @override
  Object attachSchema(Finalizable owner, Pointer<CArrowSchema> pointer) =>
      _attachArrow(owner, pointer.cast(), _schemaFinalizer);

  @override
  Object attachStream(Finalizable owner, Pointer<CArrowArrayStream> pointer) =>
      _attachArrow(owner, pointer.cast(), _streamFinalizer);

  @override
  void deleteArray(Object? attachment, Pointer<CArrowArray> pointer) {
    if (attachment != null) _arrayFinalizer.detach(attachment);
    nativeAssetArrowArrayDelete(pointer);
  }

  @override
  void deleteSchema(Object? attachment, Pointer<CArrowSchema> pointer) {
    if (attachment != null) _schemaFinalizer.detach(attachment);
    nativeAssetArrowSchemaDelete(pointer);
  }

  @override
  void deleteStream(Object? attachment, Pointer<CArrowArrayStream> pointer) {
    if (attachment != null) _streamFinalizer.detach(attachment);
    nativeAssetArrowStreamDelete(pointer);
  }
}
