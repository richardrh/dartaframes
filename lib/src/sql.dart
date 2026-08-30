part of 'polars.dart';

/// A mutable native Polars SQL catalog.
final class SqlContext {
  SqlContext._(this._runtime, int handle)
    : _owner = _HandleOwner(_runtime, handle) {
    _owner.attach();
  }

  final Polars _runtime;
  final _HandleOwner _owner;
  bool get isClosed => _owner.isClosed;
  void close() => _owner.close();

  /// Registers a [LazyFrame] or [DataFrame]. Native registration clones its
  /// lazy plan, so the source can be closed immediately after this returns.
  void register(String name, Object input) {
    _validateName(name, 'name');
    if (input is LazyFrame) {
      _runtime._requireLazy(input);
    } else if (input is DataFrame) {
      _runtime._requireFrame(input);
    } else {
      throw ArgumentError.value(
        input,
        'input',
        'must be a LazyFrame or DataFrame',
      );
    }
    final temporary = input is DataFrame ? input.lazy() : null;
    final frame = input is LazyFrame ? input : temporary!;
    try {
      final leases = _leaseAll([_owner, frame._owner]);
      try {
        _runtime._client.invokeSync('sqlContextRegister', {
          'context': leases[0].handle.toString(),
          'name': name,
          'input': leases[1].handle.toString(),
        });
      } finally {
        _releaseAll(leases);
      }
    } finally {
      temporary?.close();
    }
  }

  /// Registers all entries atomically with respect to Dart-side validation.
  void registerAll(Map<String, Object> tables) {
    for (final entry in tables.entries) {
      _validateName(entry.key, 'table name');
      final value = entry.value;
      if (value is LazyFrame) {
        _runtime._requireLazy(value);
      } else if (value is DataFrame) {
        _runtime._requireFrame(value);
      } else {
        throw ArgumentError.value(
          value,
          'tables',
          'values must be LazyFrame or DataFrame',
        );
      }
    }
    if (tables.length > 10000) {
      throw ArgumentError.value(
        tables,
        'tables',
        'must contain at most 10000 entries',
      );
    }

    final temporary = <LazyFrame>[];
    try {
      final frames = <MapEntry<String, LazyFrame>>[];
      for (final entry in tables.entries) {
        final value = entry.value;
        final lazy = value is LazyFrame ? value : (value as DataFrame).lazy();
        if (value is DataFrame) temporary.add(lazy);
        frames.add(MapEntry(entry.key, lazy));
      }
      final leases = _leaseAll([
        _owner,
        ...frames.map((entry) => entry.value._owner),
      ]);
      try {
        _runtime._client.invokeSync('sqlContextRegisterAll', {
          'context': leases.first.handle.toString(),
          'tables': [
            for (var index = 0; index < frames.length; index++)
              {
                'name': frames[index].key,
                'input': leases[index + 1].handle.toString(),
              },
          ],
        });
      } finally {
        _releaseAll(leases);
      }
    } finally {
      for (final frame in temporary.reversed) frame.close();
    }
  }

  void unregister(Iterable<String> names) {
    final values = _selectorNames(names, 'names');
    final lease = _owner.lease('SqlContext');
    try {
      _runtime._client.invokeSync('sqlContextUnregister', {
        'context': lease.handle.toString(),
        'names': values,
      });
    } finally {
      lease.end();
    }
  }

  List<String> tablesSync() {
    final lease = _owner.lease('SqlContext');
    try {
      return List<String>.unmodifiable(
        (_runtime._client.invokeSync('sqlContextTables', {
                  'context': lease.handle.toString(),
                })['tables']
                as List)
            .cast<String>(),
      );
    } finally {
      lease.end();
    }
  }

  Future<List<String>> tables() async {
    final lease = _owner.lease('SqlContext');
    try {
      final response = await _runtime._client.invoke('sqlContextTables', {
        'context': lease.handle.toString(),
      });
      return List<String>.unmodifiable((response['tables'] as List).cast());
    } finally {
      lease.end();
    }
  }

  /// Parses [query] and returns its lazy plan.
  LazyFrame execute(String query) {
    _validateName(query, 'query');
    final lease = _owner.lease('SqlContext');
    try {
      return _runtime._adoptLazy(
        _runtime._client.invokeSync('sqlContextExecute', {
          'context': lease.handle.toString(),
          'query': query,
        }),
      );
    } finally {
      lease.end();
    }
  }

  LazyFrame executeSync(String query) => execute(query);
}
