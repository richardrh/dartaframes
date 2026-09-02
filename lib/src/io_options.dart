part of 'polars.dart';

enum IpcCompression { none, lz4, zstd }

enum CsvQuoteStyle { necessary, always, nonNumeric, never }

/// Options for eagerly reading one worksheet from an `.xlsx` workbook.
///
/// When [worksheet] is null, the first worksheet is read. [columnNames]
/// replaces inferred/header names; a header row is still consumed when
/// [hasHeader] is true. The default inference boundary examines 100 data rows.
/// Set [inferSchemaLength] to null to infer from every data row.
final class ExcelReadOptions {
  const ExcelReadOptions({
    this.worksheet,
    this.hasHeader = true,
    this.columnNames,
    this.inferSchemaLength = 100,
  }) : assert(inferSchemaLength == null || inferSchemaLength > 0);

  final String? worksheet;
  final bool hasHeader;
  final List<String>? columnNames;
  final int? inferSchemaLength;

  Map<String, Object?> _toJson() => {
    if (worksheet != null) 'worksheet': worksheet,
    'hasHeader': hasHeader,
    if (columnNames != null) 'columnNames': columnNames,
    'inferSchemaLength': inferSchemaLength,
  };
}

/// Options for writing a new one-worksheet `.xlsx` workbook.
///
/// Existing output is replaced only after the complete workbook has been
/// written successfully to a temporary file in the destination directory.
final class ExcelWriteOptions {
  const ExcelWriteOptions({
    this.worksheet = 'Sheet1',
    this.includeHeader = true,
    this.dateFormat = 'yyyy-mm-dd',
    this.datetimeFormat = 'yyyy-mm-dd hh:mm:ss.000',
  });

  final String worksheet;
  final bool includeHeader;
  final String dateFormat;
  final String datetimeFormat;

  Map<String, Object?> _toJson() => {
    'worksheet': worksheet,
    'includeHeader': includeHeader,
    'dateFormat': dateFormat,
    'datetimeFormat': datetimeFormat,
  };
}

enum ParquetCompression {
  uncompressed,
  snappy,
  gzip,
  brotli,
  zstd,
  lz4Raw;

  String get wireName => switch (this) {
    ParquetCompression.lz4Raw => 'lz4raw',
    _ => name,
  };
}

final class CsvWriteOptions {
  const CsvWriteOptions({
    this.includeHeader = true,
    this.separator = ',',
    this.includeBom = false,
    this.batchSize = 1024,
    this.dateFormat,
    this.timeFormat,
    this.datetimeFormat,
    this.floatScientific,
    this.floatPrecision,
    this.decimalComma = false,
    this.quoteChar = '"',
    this.nullValue = '',
    this.lineTerminator = '\n',
    this.quoteStyle = CsvQuoteStyle.necessary,
    this.nThreads,
  }) : assert(batchSize > 0),
       assert(floatPrecision == null || floatPrecision >= 0),
       assert(nThreads == null || nThreads > 0);

  final bool includeHeader;
  final String separator;
  final bool includeBom;
  final int batchSize;
  final String? dateFormat;
  final String? timeFormat;
  final String? datetimeFormat;
  final bool? floatScientific;
  final int? floatPrecision;
  final bool decimalComma;
  final String quoteChar;
  final String nullValue;
  final String lineTerminator;
  final CsvQuoteStyle quoteStyle;

  /// Eager writer thread count. Lazy sinks use Polars' streaming executor.
  final int? nThreads;

  Map<String, Object?> _toJson({bool eager = true}) => {
    'includeHeader': includeHeader,
    'separator': separator,
    'includeBom': includeBom,
    'batchSize': batchSize,
    if (dateFormat != null) 'dateFormat': dateFormat,
    if (timeFormat != null) 'timeFormat': timeFormat,
    if (datetimeFormat != null) 'datetimeFormat': datetimeFormat,
    if (floatScientific != null) 'floatScientific': floatScientific,
    if (floatPrecision != null) 'floatPrecision': floatPrecision,
    'decimalComma': decimalComma,
    'quoteChar': quoteChar,
    'nullValue': nullValue,
    'lineTerminator': lineTerminator,
    'quoteStyle': quoteStyle.name,
    if (eager && nThreads != null) 'nThreads': nThreads,
  };
}

final class ParquetStatisticsOptions {
  const ParquetStatisticsOptions({
    this.minValue = true,
    this.maxValue = true,
    this.distinctCount = false,
    this.nullCount = true,
    this.binaryTruncateLength,
  }) : assert(binaryTruncateLength == null || binaryTruncateLength >= 0);

  final bool minValue;
  final bool maxValue;
  final bool distinctCount;
  final bool nullCount;
  final int? binaryTruncateLength;

  Map<String, Object?> _toJson() => {
    'statisticsMin': minValue,
    'statisticsMax': maxValue,
    'statisticsDistinctCount': distinctCount,
    'statisticsNullCount': nullCount,
    if (binaryTruncateLength != null)
      'statisticsBinaryTruncateLength': binaryTruncateLength,
  };
}

final class ParquetWriteOptions {
  const ParquetWriteOptions({
    this.compression = ParquetCompression.zstd,
    this.rowGroupSize,
    this.dataPageSize,
    this.statistics = const ParquetStatisticsOptions(),
    this.parallel = true,
  }) : assert(rowGroupSize == null || rowGroupSize > 0),
       assert(dataPageSize == null || dataPageSize > 0);

  final ParquetCompression compression;
  final int? rowGroupSize;
  final int? dataPageSize;
  final ParquetStatisticsOptions statistics;

  /// Controls eager column serialization. Lazy sinks execute in parallel via
  /// Polars' streaming engine and do not expose a per-sink parallel toggle.
  final bool parallel;

  Map<String, Object?> _toJson({bool eager = true}) => {
    'compression': compression.wireName,
    if (rowGroupSize != null) 'rowGroupSize': rowGroupSize,
    if (dataPageSize != null) 'dataPageSize': dataPageSize,
    ...statistics._toJson(),
    if (eager) 'parallel': parallel,
  };
}

Map<String, Object?> _csvWriteOptions(
  CsvWriteOptions options, {
  bool? includeHeader,
  String? separator,
  bool eager = true,
}) {
  final effectiveSeparator = separator ?? options.separator;
  _validateSeparator(effectiveSeparator);
  if (options.quoteChar.codeUnits.length != 1 ||
      options.quoteChar.codeUnitAt(0) > 0x7f) {
    throw ArgumentError.value(
      options.quoteChar,
      'options.quoteChar',
      'must be exactly one ASCII byte',
    );
  }
  _validatePositive(options.batchSize, 'options.batchSize');
  _validateUnsigned(options.floatPrecision, 'options.floatPrecision');
  if (eager) _validatePositive(options.nThreads, 'options.nThreads');
  if (options.lineTerminator.isEmpty) {
    throw ArgumentError.value(
      options.lineTerminator,
      'options.lineTerminator',
      'must not be empty',
    );
  }
  if (options.decimalComma && effectiveSeparator == ',') {
    throw ArgumentError(
      'options.separator must not be a comma when decimalComma is true',
    );
  }
  return {
    ...options._toJson(eager: eager),
    'includeHeader': includeHeader ?? options.includeHeader,
    'separator': effectiveSeparator,
  };
}

const _parquetCompressions = {
  'none',
  'uncompressed',
  'snappy',
  'gzip',
  'brotli',
  'zstd',
  'lz4',
  'lz4raw',
};

Map<String, Object?> _parquetWriteOptions(
  ParquetWriteOptions options, {
  String? compression,
  bool eager = true,
}) {
  final effectiveCompression = compression ?? options.compression.wireName;
  if (!_parquetCompressions.contains(effectiveCompression)) {
    throw ArgumentError.value(
      effectiveCompression,
      'compression',
      'unsupported Parquet compression',
    );
  }
  _validatePositive(options.rowGroupSize, 'options.rowGroupSize');
  _validatePositive(options.dataPageSize, 'options.dataPageSize');
  _validateUnsigned(
    options.statistics.binaryTruncateLength,
    'options.statistics.binaryTruncateLength',
  );
  return {
    ...options._toJson(eager: eager),
    'compression': effectiveCompression,
  };
}

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
