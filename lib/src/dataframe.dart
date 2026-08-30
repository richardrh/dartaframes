part of 'polars.dart';

/// Copied-column conversion between Arrow's owned batches and the native JSON
/// batch representation.
final class RecordBatchCodec {
  const RecordBatchCodec();
  static const OwnedBatchJsonCodec _codec = OwnedBatchJsonCodec();

  Map<String, Object?> encode(RecordBatch batch) {
    final encoded = _codec.toJson(batch);
    final columns = (encoded['columns'] as List)
        .map((raw) {
          final column = Map<String, Object?>.from(raw as Map);
          var dtype = (column['dtype'] as Map).cast<String, Object?>();
          var values = column['values'] as List;
          if (dtype['kind'] == 'extension') {
            dtype = (dtype['storageType'] as Map).cast<String, Object?>();
            values = values
                .map((value) => value is Map ? value['storage'] : value)
                .toList();
          }
          column['dtype'] = _polarsDType(dtype);
          column['values'] = _polarsValues(dtype, values);
          return column;
        })
        .toList(growable: false);
    return {'length': batch.length, 'columns': columns};
  }

  static Map<String, Object?> _polarsDType(
    Map<String, Object?> dtype,
  ) => switch (dtype['kind']) {
    'date' when dtype['unit'] == 'milliseconds' => const {
      'kind': 'datetime',
      'unit': 'milliseconds',
    },
    'date' => const {'kind': 'date'},
    'time' => const {'kind': 'time'},
    'datetime' || 'duration' when dtype['unit'] == 'seconds' => {
      ...dtype,
      'unit': 'milliseconds',
    },
    'largeBinary' => const {'kind': 'binaryOffset'},
    'largeString' => const {'kind': 'string'},
    'fixedSizeList' => {
      'kind': 'array',
      'inner': _polarsDType((((dtype['field'] as Map)['dtype']) as Map).cast()),
      'width': dtype['size'],
    },
    'list' => {
      'kind': 'list',
      'inner': _polarsDType((((dtype['field'] as Map)['dtype']) as Map).cast()),
    },
    _ => Map<String, Object?>.from(dtype),
  };

  static List<Object?> _polarsValues(Map<String, Object?> dtype, List values) {
    final multiplier = switch ((dtype['kind'], dtype['unit'])) {
      ('time', 'seconds') => 1000000000,
      ('time', 'milliseconds') => 1000000,
      ('time', 'microseconds') => 1000,
      ('time', 'nanoseconds') => 1,
      ('datetime' || 'duration', 'seconds') => 1000,
      _ => 1,
    };
    if (multiplier == 1) return List<Object?>.from(values, growable: false);
    return values
        .map((value) => _scaleTemporal(value, multiplier))
        .toList(growable: false);
  }

  static Object? _scaleTemporal(Object? value, int multiplier) {
    if (value == null) return null;
    final raw = value is Map ? value['value'] : value;
    final counter = BigInt.tryParse(raw.toString());
    if (counter == null)
      throw FormatException('Invalid temporal counter: $raw');
    final scaled = counter * BigInt.from(multiplier);
    if (scaled < -(BigInt.one << 63) ||
        scaled > (BigInt.one << 63) - BigInt.one) {
      throw RangeError(
        'Temporal counter overflows native i64 after conversion',
      );
    }
    return value is Map
        ? {...value, 'value': scaled.toString()}
        : scaled.toString();
  }

  RecordBatch decode(Map<String, Object?> batch) {
    final columns = (batch['columns'] as List)
        .map((raw) {
          final column = (raw as Map).cast<String, Object?>();
          final dtype = _arrowDType(
            (column['dtype'] as Map).cast<String, Object?>(),
          );
          final values = (column['values'] as List)
              .map((value) => _arrowValue(dtype, value))
              .toList(growable: false);
          return <String, Object?>{
            ...column,
            'dtype': dtype,
            'values': values,
            'validity': values
                .map((value) => value != null)
                .toList(growable: false),
          };
        })
        .toList(growable: false);
    final returnedLength = batch['length'];
    if (returnedLength != null && returnedLength is! int) {
      throw const FormatException('Native batch length must be an integer');
    }
    return _codec.fromJson({
      'schema': {
        'fields': [
          for (final column in columns)
            {
              'name': column['name'],
              'dtype': column['dtype'],
              'nullable': true,
            },
        ],
      },
      'length':
          returnedLength ??
          (columns.isEmpty ? 0 : (columns.first['values'] as List).length),
      'columns': columns,
    });
  }

  static Map<String, Object?> _arrowDType(Map<String, Object?> dtype) =>
      switch (dtype['kind']) {
        'binaryOffset' => const {'kind': 'largeBinary'},
        'date' => const {'kind': 'date', 'unit': 'days'},
        'datetime' => {
          'kind': 'datetime',
          'unit': dtype['unit'],
          if (dtype['timeZone'] is String) 'timeZone': dtype['timeZone'],
        },
        'time' => const {'kind': 'time', 'unit': 'nanoseconds'},
        'array' => {
          'kind': 'fixedSizeList',
          'field': {
            'name': 'item',
            'dtype': _arrowDType((dtype['inner'] as Map).cast()),
            'nullable': true,
          },
          'size': dtype['width'],
        },
        'list' => {
          'kind': 'list',
          'field': {
            'name': 'item',
            'dtype': _arrowDType((dtype['inner'] as Map).cast()),
            'nullable': true,
          },
        },
        'struct' => {
          'kind': 'struct',
          'fields': [
            for (final raw in dtype['fields'] as List)
              {
                'name': (raw as Map)['name'],
                'dtype': _arrowDType(
                  (raw['dtype'] as Map).cast<String, Object?>(),
                ),
                'nullable': true,
              },
          ],
        },
        'extension' => {
          ...dtype,
          if (dtype['storage'] != null)
            'storageType': _arrowDType((dtype['storage'] as Map).cast()),
        },
        _ => Map<String, Object?>.from(dtype),
      };

  static Object? _arrowValue(Map<String, Object?> dtype, Object? value) {
    if (value == null) return null;
    final kind = dtype['kind'] as String;
    if (kind.startsWith('int') ||
        kind.startsWith('uint') ||
        {'date', 'datetime', 'duration', 'time'}.contains(kind)) {
      return value is Map ? value['value'].toString() : value.toString();
    }
    return value;
  }
}

final class DataFrame {
  DataFrame._(this._runtime, int handle)
    : _owner = _HandleOwner(_runtime, handle) {
    _owner.attach();
  }
  final Polars _runtime;
  final _HandleOwner _owner;
  bool get isClosed => _owner.isClosed;
  void close() => _owner.close();

  LazyFrame lazy() {
    final lease = _owner.lease('DataFrame');
    try {
      return _runtime._adoptLazy(
        _runtime._client.invokeSync('frameLazy', {
          'frame': lease.handle.toString(),
        }),
      );
    } finally {
      lease.end();
    }
  }

  Map<String, Object?> infoSync() {
    final lease = _owner.lease('DataFrame');
    try {
      return _runtime._client.invokeSync('frameInfo', {
        'frame': lease.handle.toString(),
      });
    } finally {
      lease.end();
    }
  }

  Future<Map<String, Object?>> info() async {
    final lease = _owner.lease('DataFrame');
    try {
      return await _runtime._client.invoke('frameInfo', {
        'frame': lease.handle.toString(),
      });
    } finally {
      lease.end();
    }
  }

  List<Field> schemaSync() => _schema(infoSync()['schema']);
  Future<List<Field>> schema() async => _schema((await info())['schema']);
  (int height, int width) shapeSync() {
    final value = infoSync();
    return (value['height'] as int, value['width'] as int);
  }

  RecordBatch exportSync([RecordBatchCodec codec = const RecordBatchCodec()]) {
    final lease = _owner.lease('DataFrame');
    try {
      final response = _runtime._client.invokeSync('frameExport', {
        'frame': lease.handle.toString(),
      });
      return codec.decode((response['batch'] as Map).cast<String, Object?>());
    } finally {
      lease.end();
    }
  }

  Future<RecordBatch> export([
    RecordBatchCodec codec = const RecordBatchCodec(),
  ]) async {
    final lease = _owner.lease('DataFrame');
    try {
      final response = await _runtime._client.invoke('frameExport', {
        'frame': lease.handle.toString(),
      });
      return codec.decode((response['batch'] as Map).cast<String, Object?>());
    } finally {
      lease.end();
    }
  }

  /// Exports this frame as one Arrow struct array with flat child columns.
  /// The returned C payload is independent of this frame handle.
  ArrowCData exportArrowC() {
    final lease = _owner.lease('DataFrame');
    try {
      return _runtime._arrowC.exportFrame(lease.handle);
    } finally {
      lease.end();
    }
  }

  /// Exports lazily produced Arrow struct-array batches of at most [maxRows].
  ArrowCStream exportArrowCStream({int maxRows = 65536}) {
    _validatePositive(maxRows, 'maxRows');
    final lease = _owner.lease('DataFrame');
    try {
      return _runtime._arrowC.exportFrameStream(lease.handle, maxRows);
    } finally {
      lease.end();
    }
  }

  void writeCsvSync(
    String path, {
    bool includeHeader = true,
    String separator = ',',
  }) {
    _validatePath(path);
    _validateSeparator(separator);
    final lease = _owner.lease('DataFrame');
    try {
      _runtime._client.invokeSync('frameWriteCsv', {
        'frame': lease.handle.toString(),
        'path': path,
        'includeHeader': includeHeader,
        'separator': separator,
      });
    } finally {
      lease.end();
    }
  }

  Future<void> writeCsv(
    String path, {
    bool includeHeader = true,
    String separator = ',',
  }) async {
    _validatePath(path);
    _validateSeparator(separator);
    final lease = _owner.lease('DataFrame');
    try {
      await _runtime._client.invoke('frameWriteCsv', {
        'frame': lease.handle.toString(),
        'path': path,
        'includeHeader': includeHeader,
        'separator': separator,
      });
    } finally {
      lease.end();
    }
  }

  void writeParquetSync(String path, {String compression = 'zstd'}) {
    _validatePath(path);
    final lease = _owner.lease('DataFrame');
    try {
      _runtime._client.invokeSync('frameWriteParquet', {
        'frame': lease.handle.toString(),
        'path': path,
        'compression': compression,
      });
    } finally {
      lease.end();
    }
  }

  Future<void> writeParquet(String path, {String compression = 'zstd'}) async {
    _validatePath(path);
    final lease = _owner.lease('DataFrame');
    try {
      await _runtime._client.invoke('frameWriteParquet', {
        'frame': lease.handle.toString(),
        'path': path,
        'compression': compression,
      });
    } finally {
      lease.end();
    }
  }
}
