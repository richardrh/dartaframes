part of 'polars.dart';

enum DatabaseIfExists { fail, replace, append }

/// An owned connection to a local database.
///
/// Phase 1 supports SQLite. Close the connection when it is no longer needed.
final class DatabaseConnection {
  DatabaseConnection._(this._runtime, int handle)
    : _owner = _HandleOwner(_runtime, handle) {
    _owner.attach();
  }

  final Polars _runtime;
  final _HandleOwner _owner;

  bool get isClosed => _owner.isClosed;
  void close() => _owner.close();

  DataFrame querySync(String sql, {Iterable<Object?> parameters = const []}) {
    _validateSql(sql);
    final lease = _owner.lease('DatabaseConnection');
    try {
      return _runtime._adoptFrame(
        _runtime._client.invokeSync('databaseConnectionQuery', {
          'connection': lease.handle.toString(),
          'sql': sql,
          'parameters': _encodeParameters(parameters),
        }),
      );
    } finally {
      lease.end();
    }
  }

  Future<DataFrame> query(
    String sql, {
    Iterable<Object?> parameters = const [],
  }) async {
    _validateSql(sql);
    final lease = _owner.lease('DatabaseConnection');
    try {
      return _runtime._adoptFrame(
        await _runtime._client.invoke('databaseConnectionQuery', {
          'connection': lease.handle.toString(),
          'sql': sql,
          'parameters': _encodeParameters(parameters),
        }),
      );
    } finally {
      lease.end();
    }
  }

  int executeSync(String sql, {Iterable<Object?> parameters = const []}) {
    _validateSql(sql);
    final lease = _owner.lease('DatabaseConnection');
    try {
      final response = _runtime._client.invokeSync(
        'databaseConnectionExecute',
        {
          'connection': lease.handle.toString(),
          'sql': sql,
          'parameters': _encodeParameters(parameters),
        },
      );
      return response['rowsAffected'] as int;
    } finally {
      lease.end();
    }
  }

  Future<int> execute(
    String sql, {
    Iterable<Object?> parameters = const [],
  }) async {
    _validateSql(sql);
    final lease = _owner.lease('DatabaseConnection');
    try {
      final response = await _runtime._client.invoke(
        'databaseConnectionExecute',
        {
          'connection': lease.handle.toString(),
          'sql': sql,
          'parameters': _encodeParameters(parameters),
        },
      );
      return response['rowsAffected'] as int;
    } finally {
      lease.end();
    }
  }

  int writeFrameSync(
    DataFrame frame,
    String table, {
    DatabaseIfExists ifExists = DatabaseIfExists.fail,
  }) {
    _runtime._requireFrame(frame);
    _validateName(table, 'table');
    final leases = _leaseAll([_owner, frame._owner]);
    try {
      final response = _runtime._client.invokeSync(
        'databaseConnectionWriteFrame',
        {
          'connection': leases[0].handle.toString(),
          'frame': leases[1].handle.toString(),
          'table': table,
          'ifExists': ifExists.name,
        },
      );
      return response['rowsWritten'] as int;
    } finally {
      _releaseAll(leases);
    }
  }

  Future<int> writeFrame(
    DataFrame frame,
    String table, {
    DatabaseIfExists ifExists = DatabaseIfExists.fail,
  }) async {
    _runtime._requireFrame(frame);
    _validateName(table, 'table');
    final leases = _leaseAll([_owner, frame._owner]);
    try {
      final response = await _runtime._client.invoke(
        'databaseConnectionWriteFrame',
        {
          'connection': leases[0].handle.toString(),
          'frame': leases[1].handle.toString(),
          'table': table,
          'ifExists': ifExists.name,
        },
      );
      return response['rowsWritten'] as int;
    } finally {
      _releaseAll(leases);
    }
  }

  List<Map<String, Object?>> _encodeParameters(Iterable<Object?> parameters) {
    final values = List<Object?>.unmodifiable(parameters);
    if (values.length > 10000) {
      throw ArgumentError.value(
        parameters,
        'parameters',
        'must have at most 10000 values',
      );
    }
    return values
        .map(
          (value) => value == null
              ? <String, Object?>{
                  'dtype': const {'kind': 'null'},
                  'value': null,
                }
              : _runtime._scalar(value, null).toJson(),
        )
        .toList(growable: false);
  }
}

void _validateSql(String sql) {
  if (sql.isEmpty || sql.contains('\u0000')) {
    throw ArgumentError.value(
      sql,
      'sql',
      'must be non-empty and contain no NUL',
    );
  }
}
