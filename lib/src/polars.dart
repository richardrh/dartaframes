import 'dart:convert';
import 'dart:ffi';

import 'package:dartaframes_polars/dartaframes_arrow.dart'
    show ArrowArray, ArrowField, ArrowSchema, OwnedBatchJsonCodec, RecordBatch;

import 'dtype.dart';
import 'arrow_c.dart';
import 'errors.dart';
import 'native.dart';
import 'native_asset_invoker.dart';
import 'protocol.dart';
import 'scalar.dart';

part 'handle.dart';
part 'expression_options.dart';
part 'query_options.dart';
part 'io_options.dart';
part 'expression.dart';
part 'expression_string.dart';
part 'expression_temporal.dart';
part 'expression_nested.dart';
part 'expression_binary_categorical.dart';
part 'expression_name_meta.dart';
part 'selectors.dart';
part 'plan.dart';
part 'batch_stream.dart';
part 'dataframe.dart';
part 'series.dart';
part 'dataframe_eager.dart';
part 'io_extended.dart';
part 'sql.dart';

/// An explicit native Polars runtime. Every resource created through this
/// object belongs exclusively to this runtime, even when two runtimes were
/// constructed from the same [ProtocolClient].
final class Polars {
  Polars.fromClient(this._client);

  /// Uses the native library supplied by this package's native-assets hook.
  ///
  /// During source development this fails at native asset resolution if the
  /// reviewed release metadata has not yet been activated. Use [open] or
  /// [process] for an explicitly managed development library.
  factory Polars.native() => Polars.fromClient(NativeAssetProtocolClient());

  factory Polars.open(String path) =>
      Polars.fromClient(NativeProtocolClient.open(path));
  factory Polars.process() => Polars.fromClient(NativeProtocolClient.process());

  final ProtocolClient _client;

  /// Creates selectors owned by this runtime.
  SelectorFactory get selectors => SelectorFactory._(this);

  /// Creates an empty SQL context owned by this runtime.
  SqlContext sqlContext() =>
      _adoptSqlContext(_client.invokeSync('sqlContextNew'));

  NativeHelloCapabilities nativeCapabilitiesSync() =>
      _client.nativeCapabilitiesSync();
  Future<NativeHelloCapabilities> nativeCapabilities() =>
      _client.nativeCapabilities();

  RuntimeDiagnostics runtimeDiagnosticsSync() =>
      RuntimeDiagnostics.fromResponse(_client.invokeSync('runtimeDiagnostics'));
  Future<RuntimeDiagnostics> runtimeDiagnostics() async =>
      RuntimeDiagnostics.fromResponse(
        await _client.invoke('runtimeDiagnostics'),
      );

  Expr col(String name) {
    _validateName(name, 'name');
    return _adoptExpr(_client.invokeSync('exprColumn', {'name': name}));
  }

  Expr lit(Object? value, [DType? dtype]) {
    final scalar = _scalar(value, dtype);
    return _adoptExpr(
      _client.invokeSync('exprLiteral', {'scalar': scalar.toJson()}),
    );
  }

  Expr len() => _adoptExpr(_client.invokeSync('exprLen'));
  When when(Expr predicate) {
    _requireExpr(predicate);
    return When._(this, predicate);
  }

  LazyFrame scanCsv(
    String path, {
    bool hasHeader = true,
    String separator = ',',
    int? skipRows,
    int? nRows,
    bool tryParseDates = false,
  }) {
    _validatePath(path);
    _validateSeparator(separator);
    _validateUnsigned(skipRows, 'skipRows');
    _validateUnsigned(nRows, 'nRows');
    return _adoptLazy(
      _client.invokeSync('lazyScanCsv', {
        'path': path,
        'hasHeader': hasHeader,
        'separator': separator,
        if (skipRows != null) 'skipRows': skipRows,
        if (nRows != null) 'nRows': nRows,
        'tryParseDates': tryParseDates,
      }),
    );
  }

  LazyFrame scanParquet(String path, {int? nRows, bool parallel = true}) {
    _validatePath(path);
    _validateUnsigned(nRows, 'nRows');
    return _adoptLazy(
      _client.invokeSync('lazyScanParquet', {
        'path': path,
        if (nRows != null) 'nRows': nRows,
        'parallel': parallel,
      }),
    );
  }

  LazyFrame concat(
    Iterable<LazyFrame> frames, {
    String how = 'vertical',
    bool rechunk = false,
  }) {
    final values = List<LazyFrame>.unmodifiable(frames);
    if (values.isEmpty) {
      throw ArgumentError.value(frames, 'frames', 'must not be empty');
    }
    const modes = {
      'vertical',
      'verticalRelaxed',
      'diagonal',
      'diagonalRelaxed',
      'horizontal',
    };
    if (!modes.contains(how)) {
      throw ArgumentError.value(how, 'how', 'unsupported concat mode');
    }
    if (how == 'horizontal' && rechunk) {
      throw ArgumentError.value(
        rechunk,
        'rechunk',
        'is not supported by horizontal concat',
      );
    }
    for (final frame in values) {
      _requireLazy(frame);
    }
    final leases = _leaseAll(values.map((value) => value._owner));
    try {
      return _adoptLazy(
        _client.invokeSync('lazyConcat', {
          'inputs': leases.map((lease) => lease.handle.toString()).toList(),
          'how': how,
          'rechunk': rechunk,
        }),
      );
    } finally {
      _releaseAll(leases);
    }
  }

  DataFrame fromRecordBatchSync(
    RecordBatch batch, [
    RecordBatchCodec codec = const RecordBatchCodec(),
  ]) => _adoptFrame(
    _client.invokeSync('frameImport', {'batch': codec.encode(batch)}),
  );

  Future<DataFrame> fromRecordBatch(
    RecordBatch batch, [
    RecordBatchCodec codec = const RecordBatchCodec(),
  ]) async => _adoptFrame(
    await _client.invoke('frameImport', {'batch': codec.encode(batch)}),
  );

  Series fromArrowArraySync(
    String name,
    ArrowArray array, [
    RecordBatchCodec codec = const RecordBatchCodec(),
  ]) {
    _validateName(name, 'name');
    final batch = RecordBatch(ArrowSchema([ArrowField(name, array.type)]), [
      array,
    ]);
    final encoded = codec.encode(batch);
    return _adoptSeries(
      _client.invokeSync('seriesImport', {
        'column': (encoded['columns'] as List).single,
      }),
    );
  }

  Future<Series> fromArrowArray(
    String name,
    ArrowArray array, [
    RecordBatchCodec codec = const RecordBatchCodec(),
  ]) async {
    _validateName(name, 'name');
    final batch = RecordBatch(ArrowSchema([ArrowField(name, array.type)]), [
      array,
    ]);
    final encoded = codec.encode(batch);
    return _adoptSeries(
      await _client.invoke('seriesImport', {
        'column': (encoded['columns'] as List).single,
      }),
    );
  }

  ArrowCBridge get _arrowC {
    final invoker = _client.invoker;
    if (invoker is! ArrowCBridge) {
      throw UnsupportedError(
        'This protocol transport does not provide Arrow C interchange',
      );
    }
    return invoker as ArrowCBridge;
  }

  /// Allocates empty owned C Data structs for an external Arrow producer.
  ArrowCData allocateArrowCData() => _arrowC.allocateData();

  /// Allocates an empty owned C Stream struct for an external producer.
  ArrowCStream allocateArrowCStream() => _arrowC.allocateStream();

  DataFrame fromArrowCData(ArrowCData data) =>
      _adoptFrame({'handle': _arrowC.importFrame(data)});

  Series seriesFromArrowCData(ArrowCData data) =>
      _adoptSeries({'handle': _arrowC.importSeries(data)});

  DataFrame fromArrowCStream(
    ArrowCStream stream, {
    required int maxBatches,
    required int maxRows,
  }) {
    _validatePositive(maxBatches, 'maxBatches');
    _validatePositive(maxRows, 'maxRows');
    return _adoptFrame({
      'handle': _arrowC.importFrameStream(stream, maxBatches, maxRows),
    });
  }

  Scalar _scalar(Object? value, DType? dtype) {
    if (value is Scalar) {
      if (dtype != null && dtype != value.dtype) {
        throw ArgumentError('dtype conflicts with Scalar.dtype');
      }
      return value;
    }
    if (value == null) {
      if (dtype == null)
        throw ArgumentError('A null literal requires a dtype.');
      return Scalar.nullValue(dtype);
    }
    if (dtype != null) return Scalar.typed(dtype, value);
    return switch (value) {
      bool value => Scalar.boolean(value),
      int value => Scalar.int64(value),
      double value => Scalar.float64(value),
      String value => Scalar.string(value),
      List<int> value => Scalar.binary(value),
      _ => throw ArgumentError.value(
        value,
        'value',
        'cannot infer literal dtype',
      ),
    };
  }

  void _same(Polars other) {
    if (!identical(this, other)) {
      throw ArgumentError(
        'Native resources belong to different Polars runtimes',
      );
    }
  }

  void _requireExpr(Expr value) {
    _same(value._runtime);
    value._owner.ensureUsable('Expr');
  }

  void _requireLazy(LazyFrame value) {
    _same(value._runtime);
    value._owner.ensureUsable('LazyFrame');
  }

  void _requireFrame(DataFrame value) {
    _same(value._runtime);
    value._owner.ensureUsable('DataFrame');
  }

  void _requireSelector(Selector value) {
    _same(value._runtime);
    value._owner.ensureUsable('Selector');
  }

  void _requireDTypeSelector(DTypeSelector value) {
    _same(value._runtime);
    value._owner.ensureUsable('DTypeSelector');
  }

  void _requireSeries(Series value) {
    _same(value._runtime);
    value._owner.ensureUsable('Series');
  }

  Expr _adoptExpr(Map<String, Object?> response) =>
      Expr._(this, _responseHandle(response));
  LazyFrame _adoptLazy(Map<String, Object?> response) =>
      LazyFrame._(this, _responseHandle(response));
  DataFrame _adoptFrame(Map<String, Object?> response) =>
      DataFrame._(this, _responseHandle(response));
  Series _adoptSeries(Map<String, Object?> response) =>
      Series._(this, _responseHandle(response));
  CancellableQuery _adoptJob(Map<String, Object?> response) =>
      CancellableQuery._(this, _responseHandle(response));
  BatchStream _adoptBatchStream(Map<String, Object?> response) =>
      BatchStream._(this, _responseHandle(response));
  ProfileResult _adoptProfile(Map<String, Object?> response) {
    final resultHandle = _optionalResponseHandle(response, 'resultHandle');
    final timingsHandle = _optionalResponseHandle(response, 'timingsHandle');
    if (resultHandle == null ||
        timingsHandle == null ||
        resultHandle == timingsHandle) {
      for (final handle in {resultHandle, timingsHandle}.nonNulls) {
        try {
          _client.invoker.releaseHandle(handle);
        } catch (_) {}
      }
      if (resultHandle == timingsHandle && resultHandle != null) {
        throw const FormatException('Native profile handles must be distinct');
      }
      throw const FormatException(
        'Native profile response handles are invalid',
      );
    }
    late final DataFrame result;
    try {
      result = DataFrame._(this, resultHandle);
    } catch (_) {
      try {
        _client.invoker.releaseHandle(timingsHandle);
      } catch (_) {}
      rethrow;
    }
    try {
      return ProfileResult._(result, DataFrame._(this, timingsHandle));
    } catch (_) {
      result.close();
      rethrow;
    }
  }

  Selector _adoptSelector(Map<String, Object?> response) =>
      Selector._(this, _responseHandle(response));
  DTypeSelector _adoptDTypeSelector(Map<String, Object?> response) =>
      DTypeSelector._(this, _responseHandle(response));
  SqlContext _adoptSqlContext(Map<String, Object?> response) =>
      SqlContext._(this, _responseHandle(response));
}

int _responseHandle(Map<String, Object?> response) {
  return _namedResponseHandle(response, 'handle');
}

int _namedResponseHandle(Map<String, Object?> response, String field) {
  final handle = _optionalResponseHandle(response, field);
  if (handle == null) {
    throw FormatException('Native response $field is invalid');
  }
  return handle;
}

int? _optionalResponseHandle(Map<String, Object?> response, String field) {
  final value = response[field];
  final handle = switch (value) {
    int value => value,
    String value => int.tryParse(value),
    _ => null,
  };
  return handle != null && handle > 0 ? handle : null;
}

void _validateName(String value, String argument) {
  if (value.isEmpty)
    throw ArgumentError.value(value, argument, 'must not be empty');
}

void _validatePath(String value) => _validateName(value, 'path');
void _validateLocalPath(String value) {
  _validatePath(value);
  if (value.contains('://')) {
    throw ArgumentError.value(
      value,
      'path',
      'only local filesystem paths are supported',
    );
  }
}

void _validateSeparator(String value) {
  if (utf8.encode(value).length != 1) {
    throw ArgumentError.value(value, 'separator', 'must be one byte');
  }
}

void _validateUnsigned(int? value, String name) {
  if (value != null && value < 0)
    throw RangeError.value(value, name, 'must be unsigned');
}

void _validatePositive(int? value, String name) {
  if (value != null && value <= 0)
    throw RangeError.value(value, name, 'must be positive');
}
