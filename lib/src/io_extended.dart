part of 'polars.dart';

extension LocalIoPolars on Polars {
  LazyFrame scanIpc(
    String path, {
    IpcScanOptions options = const IpcScanOptions(),
  }) {
    _validateLocalPath(path);
    _validateUnsigned(options.nRows, 'options.nRows');
    return _adoptLazy(
      _client.invokeSync('lazyScanIpc', {'path': path, ...options._toJson()}),
    );
  }

  LazyFrame scanFeather(
    String path, {
    IpcScanOptions options = const IpcScanOptions(),
  }) => scanIpc(path, options: options);

  LazyFrame scanNdjson(
    String path, {
    NdjsonScanOptions options = const NdjsonScanOptions(),
  }) {
    _validateLocalPath(path);
    _validateUnsigned(options.nRows, 'options.nRows');
    final inferSchemaLength = options.inferSchemaLength;
    if (inferSchemaLength != null && inferSchemaLength <= 0) {
      throw RangeError.value(
        inferSchemaLength,
        'options.inferSchemaLength',
        'must be positive',
      );
    }
    return _adoptLazy(
      _client.invokeSync('lazyScanNdjson', {
        'path': path,
        ...options._toJson(),
      }),
    );
  }

  DataFrame readJsonSync(
    String path, {
    JsonReadOptions options = const JsonReadOptions(),
  }) {
    _validateLocalPath(path);
    _validatePositive(options.inferSchemaLength, 'options.inferSchemaLength');
    _validatePositive(options.batchSize, 'options.batchSize');
    return _adoptFrame(
      _client.invokeSync('frameReadJson', {'path': path, ...options._toJson()}),
    );
  }

  Future<DataFrame> readJson(
    String path, {
    JsonReadOptions options = const JsonReadOptions(),
  }) async {
    _validateLocalPath(path);
    _validatePositive(options.inferSchemaLength, 'options.inferSchemaLength');
    _validatePositive(options.batchSize, 'options.batchSize');
    return _adoptFrame(
      await _client.invoke('frameReadJson', {
        'path': path,
        ...options._toJson(),
      }),
    );
  }

  DataFrame readIpcStreamSync(
    String path, {
    IpcStreamReadOptions options = const IpcStreamReadOptions(),
  }) {
    _validateLocalPath(path);
    _validateUnsigned(options.nRows, 'options.nRows');
    return _adoptFrame(
      _client.invokeSync('frameReadIpcStream', {
        'path': path,
        ...options._toJson(),
      }),
    );
  }

  Future<DataFrame> readIpcStream(
    String path, {
    IpcStreamReadOptions options = const IpcStreamReadOptions(),
  }) async {
    _validateLocalPath(path);
    _validateUnsigned(options.nRows, 'options.nRows');
    return _adoptFrame(
      await _client.invoke('frameReadIpcStream', {
        'path': path,
        ...options._toJson(),
      }),
    );
  }
}

extension LocalIoDataFrame on DataFrame {
  void _writeLocalSync(
    String command,
    String path,
    Map<String, Object?> options,
  ) {
    _validateLocalPath(path);
    final lease = _owner.lease('DataFrame');
    try {
      _runtime._client.invokeSync(command, {
        'frame': lease.handle.toString(),
        'path': path,
        ...options,
      });
    } finally {
      lease.end();
    }
  }

  Future<void> _writeLocal(
    String command,
    String path,
    Map<String, Object?> options,
  ) async {
    _validateLocalPath(path);
    final lease = _owner.lease('DataFrame');
    try {
      await _runtime._client.invoke(command, {
        'frame': lease.handle.toString(),
        'path': path,
        ...options,
      });
    } finally {
      lease.end();
    }
  }

  void writeIpcSync(
    String path, {
    IpcWriteOptions options = const IpcWriteOptions(),
  }) {
    _validatePositive(options.recordBatchSize, 'options.recordBatchSize');
    _writeLocalSync('frameWriteIpc', path, options._toJson());
  }

  Future<void> writeIpc(
    String path, {
    IpcWriteOptions options = const IpcWriteOptions(),
  }) {
    _validatePositive(options.recordBatchSize, 'options.recordBatchSize');
    return _writeLocal('frameWriteIpc', path, options._toJson());
  }

  void writeFeatherSync(
    String path, {
    IpcWriteOptions options = const IpcWriteOptions(),
  }) => writeIpcSync(path, options: options);

  Future<void> writeFeather(
    String path, {
    IpcWriteOptions options = const IpcWriteOptions(),
  }) => writeIpc(path, options: options);

  void writeIpcStreamSync(
    String path, {
    IpcStreamWriteOptions options = const IpcStreamWriteOptions(),
  }) => _writeLocalSync('frameWriteIpcStream', path, options._toJson());

  Future<void> writeIpcStream(
    String path, {
    IpcStreamWriteOptions options = const IpcStreamWriteOptions(),
  }) => _writeLocal('frameWriteIpcStream', path, options._toJson());

  void writeJsonSync(String path) =>
      _writeLocalSync('frameWriteJson', path, const {});
  Future<void> writeJson(String path) =>
      _writeLocal('frameWriteJson', path, const {});
  void writeNdjsonSync(String path) =>
      _writeLocalSync('frameWriteNdjson', path, const {});
  Future<void> writeNdjson(String path) =>
      _writeLocal('frameWriteNdjson', path, const {});
}

extension LocalIoLazyFrame on LazyFrame {
  void _sinkLocalSync(
    String command,
    String path,
    Map<String, Object?> options,
  ) {
    _validateLocalPath(path);
    final lease = _owner.lease('LazyFrame');
    try {
      _runtime._client.invokeSync(command, {
        'input': lease.handle.toString(),
        'path': path,
        ...options,
      });
    } finally {
      lease.end();
    }
  }

  /// Executes a native streaming CSV sink synchronously on the calling isolate.
  void sinkCsvSync(
    String path, {
    bool includeHeader = true,
    String separator = ',',
    LazySinkOptions options = const LazySinkOptions(),
  }) {
    _validateSeparator(separator);
    _sinkLocalSync('lazySinkCsv', path, {
      'includeHeader': includeHeader,
      'separator': separator,
      ...options._toJson(),
    });
  }

  void sinkCsv(
    String path, {
    bool includeHeader = true,
    String separator = ',',
    LazySinkOptions options = const LazySinkOptions(),
  }) => sinkCsvSync(
    path,
    includeHeader: includeHeader,
    separator: separator,
    options: options,
  );

  /// Executes a native streaming Parquet sink synchronously.
  void sinkParquetSync(
    String path, {
    String compression = 'zstd',
    LazySinkOptions options = const LazySinkOptions(),
  }) => _sinkLocalSync('lazySinkParquet', path, {
    'compression': compression,
    ...options._toJson(),
  });

  void sinkParquet(
    String path, {
    String compression = 'zstd',
    LazySinkOptions options = const LazySinkOptions(),
  }) => sinkParquetSync(path, compression: compression, options: options);

  /// Executes a native streaming IPC/Feather file sink synchronously.
  void sinkIpcSync(
    String path, {
    IpcWriteOptions ipc = const IpcWriteOptions(),
    LazySinkOptions options = const LazySinkOptions(),
  }) {
    _validatePositive(ipc.recordBatchSize, 'ipc.recordBatchSize');
    _sinkLocalSync('lazySinkIpc', path, {
      ...ipc._toJson(includeParallel: false),
      ...options._toJson(),
    });
  }

  void sinkIpc(
    String path, {
    IpcWriteOptions ipc = const IpcWriteOptions(),
    LazySinkOptions options = const LazySinkOptions(),
  }) => sinkIpcSync(path, ipc: ipc, options: options);

  void sinkFeatherSync(
    String path, {
    IpcWriteOptions ipc = const IpcWriteOptions(),
    LazySinkOptions options = const LazySinkOptions(),
  }) => sinkIpcSync(path, ipc: ipc, options: options);

  /// Executes a native streaming newline-delimited JSON sink synchronously.
  void sinkNdjsonSync(
    String path, {
    LazySinkOptions options = const LazySinkOptions(),
  }) => _sinkLocalSync('lazySinkNdjson', path, options._toJson());

  void sinkNdjson(
    String path, {
    LazySinkOptions options = const LazySinkOptions(),
  }) => sinkNdjsonSync(path, options: options);
}
