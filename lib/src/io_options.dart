part of 'polars.dart';

enum IpcCompression { none, lz4, zstd }

final class IpcScanOptions {
  const IpcScanOptions({
    this.nRows,
    this.cache = false,
    this.rechunk = false,
    this.recordBatchStatistics = false,
  }) : assert(nRows == null || nRows >= 0);

  final int? nRows;
  final bool cache;
  final bool rechunk;
  final bool recordBatchStatistics;

  Map<String, Object?> _toJson() => {
    if (nRows != null) 'nRows': nRows,
    'cache': cache,
    'rechunk': rechunk,
    'recordBatchStatistics': recordBatchStatistics,
  };
}

final class NdjsonScanOptions {
  const NdjsonScanOptions({
    this.nRows,
    this.inferSchemaLength = 100,
    this.ignoreErrors = false,
    this.lowMemory = false,
    this.rechunk = false,
  }) : assert(nRows == null || nRows >= 0),
       assert(inferSchemaLength == null || inferSchemaLength > 0);

  final int? nRows;
  final int? inferSchemaLength;
  final bool ignoreErrors;
  final bool lowMemory;
  final bool rechunk;

  Map<String, Object?> _toJson() => {
    if (nRows != null) 'nRows': nRows,
    'inferSchemaLength': inferSchemaLength,
    'ignoreErrors': ignoreErrors,
    'lowMemory': lowMemory,
    'rechunk': rechunk,
  };
}

final class JsonReadOptions {
  const JsonReadOptions({
    this.inferSchemaLength,
    this.batchSize = 8192,
    this.rechunk = true,
  }) : assert(inferSchemaLength == null || inferSchemaLength > 0),
       assert(batchSize > 0);

  final int? inferSchemaLength;
  final int batchSize;
  final bool rechunk;

  Map<String, Object?> _toJson() => {
    'inferSchemaLength': inferSchemaLength,
    'batchSize': batchSize,
    'rechunk': rechunk,
  };
}

final class IpcStreamReadOptions {
  const IpcStreamReadOptions({this.nRows, this.columns, this.rechunk = true})
    : assert(nRows == null || nRows >= 0);

  final int? nRows;
  final List<String>? columns;
  final bool rechunk;

  Map<String, Object?> _toJson() => {
    if (nRows != null) 'nRows': nRows,
    if (columns != null) 'columns': _validatedNames(columns!, 'columns'),
    'rechunk': rechunk,
  };
}

final class IpcWriteOptions {
  const IpcWriteOptions({
    this.compression = IpcCompression.none,
    this.recordBatchSize,
    this.parallel = true,
    this.recordBatchStatistics = false,
  }) : assert(recordBatchSize == null || recordBatchSize > 0);

  final IpcCompression compression;
  final int? recordBatchSize;
  final bool parallel;
  final bool recordBatchStatistics;

  Map<String, Object?> _toJson({bool includeParallel = true}) => {
    'compression': compression.name,
    if (recordBatchSize != null) 'recordBatchSize': recordBatchSize,
    if (includeParallel) 'parallel': parallel,
    'recordBatchStatistics': recordBatchStatistics,
  };
}

final class IpcStreamWriteOptions {
  const IpcStreamWriteOptions({this.compression = IpcCompression.none});
  final IpcCompression compression;
  Map<String, Object?> _toJson() => {'compression': compression.name};
}

final class LazySinkOptions {
  const LazySinkOptions({this.maintainOrder = true});
  final bool maintainOrder;
  Map<String, Object?> _toJson() => {'maintainOrder': maintainOrder};
}
