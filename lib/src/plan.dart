part of 'polars.dart';

final class LazyFrame {
  LazyFrame._(this._runtime, int handle)
    : _owner = _HandleOwner(_runtime, handle) {
    _owner.attach();
  }
  final Polars _runtime;
  final _HandleOwner _owner;
  bool get isClosed => _owner.isClosed;
  void close() => _owner.close();

  LazyFrame _inputCommand(
    String command, [
    Map<String, Object?> fields = const {},
  ]) {
    final lease = _owner.lease('LazyFrame');
    try {
      return _runtime._adoptLazy(
        _runtime._client.invokeSync(command, {
          'input': lease.handle.toString(),
          ...fields,
        }),
      );
    } finally {
      lease.end();
    }
  }

  LazyFrame _expressionsCommand(
    String command,
    String field,
    Iterable<Expr> expressions, {
    Map<String, Object?> fields = const {},
    bool allowEmpty = true,
  }) {
    final values = List<Expr>.unmodifiable(expressions);
    if (!allowEmpty && values.isEmpty) {
      throw ArgumentError.value(expressions, field, 'must not be empty');
    }
    for (final value in values) _runtime._requireExpr(value);
    final leases = _leaseAll([_owner, ...values.map((value) => value._owner)]);
    try {
      return _runtime._adoptLazy(
        _runtime._client.invokeSync(command, {
          'input': leases.first.handle.toString(),
          field: leases.skip(1).map((x) => x.handle.toString()).toList(),
          ...fields,
        }),
      );
    } finally {
      _releaseAll(leases);
    }
  }

  LazyFrame select(Iterable<Expr> expressions) =>
      _expressionsCommand('lazySelect', 'expressions', expressions);

  /// Projection accepting both [Expr] and [Selector] inputs.
  LazyFrame selectInputs(Iterable<Object> expressions) =>
      _projectionInputs('lazySelectInputs', expressions);

  LazyFrame selectSelectors(Iterable<Selector> selectors) =>
      selectInputs(selectors);
  LazyFrame filter(Expr predicate) {
    _runtime._requireExpr(predicate);
    final leases = _leaseAll([_owner, predicate._owner]);
    try {
      return _runtime._adoptLazy(
        _runtime._client.invokeSync('lazyFilter', {
          'input': leases[0].handle.toString(),
          'predicate': leases[1].handle.toString(),
        }),
      );
    } finally {
      _releaseAll(leases);
    }
  }

  LazyFrame withColumns(Iterable<Expr> expressions) =>
      _expressionsCommand('lazyWithColumns', 'expressions', expressions);

  /// `withColumns` counterpart accepting both [Expr] and [Selector] inputs.
  LazyFrame withColumnsInputs(Iterable<Object> expressions) =>
      _projectionInputs('lazyWithColumnsInputs', expressions);

  LazyFrame withColumnSelectors(Iterable<Selector> selectors) =>
      withColumnsInputs(selectors);

  LazyFrame _projectionInputs(String command, Iterable<Object> expressions) {
    final values = List<Object>.unmodifiable(expressions);
    final owners = <_HandleOwner>[];
    for (final value in values) {
      if (value is Expr) {
        _runtime._requireExpr(value);
        owners.add(value._owner);
      } else if (value is Selector) {
        _runtime._requireSelector(value);
        owners.add(value._owner);
      } else {
        throw ArgumentError.value(
          value,
          'expressions',
          'must contain only Expr or Selector values',
        );
      }
    }
    final leases = _leaseAll([_owner, ...owners]);
    try {
      return _runtime._adoptLazy(
        _runtime._client.invokeSync(command, {
          'input': leases.first.handle.toString(),
          'expressions': leases
              .skip(1)
              .map((lease) => lease.handle.toString())
              .toList(growable: false),
        }),
      );
    } finally {
      _releaseAll(leases);
    }
  }

  LazyFrame sort(
    Iterable<Expr> by, {
    Object descending = false,
    Object nullsLast = false,
    bool maintainOrder = false,
  }) {
    final values = List<Expr>.unmodifiable(by);
    return _expressionsCommand(
      'lazySort',
      'by',
      values,
      allowEmpty: false,
      fields: {
        'descending': _broadcast(descending, values.length, 'descending'),
        'nullsLast': _broadcast(nullsLast, values.length, 'nullsLast'),
        'maintainOrder': maintainOrder,
      },
    );
  }

  LazyFrame slice(int offset, int length) {
    if (offset < -0x8000000000000000 || offset > 0x7fffffffffffffff) {
      throw RangeError.value(offset, 'offset', 'must fit signed 64-bit');
    }
    if (length < 0 || length > 0xffffffff) {
      throw RangeError.range(length, 0, 0xffffffff, 'length');
    }
    return _inputCommand('lazySlice', {'offset': offset, 'length': length});
  }

  LazyFrame head([int length = 5]) => slice(0, length);
  LazyFrame tail([int length = 5]) => slice(-length, length);

  LazyGroupBy groupBy(Iterable<Expr> keys, {bool maintainOrder = false}) {
    final values = List<Expr>.unmodifiable(keys);
    for (final value in values) _runtime._requireExpr(value);
    return LazyGroupBy._(this, values, maintainOrder);
  }

  LazyDynamicGroupBy groupByDynamic(
    Expr indexColumn, {
    Iterable<Expr> groupBy = const [],
    required DynamicGroupByOptions options,
  }) {
    _runtime._requireExpr(indexColumn);
    final keys = List<Expr>.unmodifiable(groupBy);
    for (final key in keys) _runtime._requireExpr(key);
    return LazyDynamicGroupBy._(this, indexColumn, keys, options);
  }

  LazyRollingGroupBy groupByRolling(
    Expr indexColumn, {
    Iterable<Expr> groupBy = const [],
    required RollingGroupByOptions options,
  }) {
    _runtime._requireExpr(indexColumn);
    final keys = List<Expr>.unmodifiable(groupBy);
    for (final key in keys) _runtime._requireExpr(key);
    return LazyRollingGroupBy._(this, indexColumn, keys, options);
  }

  LazyFrame join(
    LazyFrame other, {
    required Iterable<Expr> leftOn,
    required Iterable<Expr> rightOn,
    String how = 'inner',
    String suffix = '_right',
    bool coalesce = false,
  }) {
    _runtime._requireLazy(other);
    final left = List<Expr>.unmodifiable(leftOn);
    final right = List<Expr>.unmodifiable(rightOn);
    for (final value in [...left, ...right]) _runtime._requireExpr(value);
    const modes = {
      'inner',
      'left',
      'right',
      'full',
      'outer',
      'semi',
      'anti',
      'cross',
    };
    if (!modes.contains(how))
      throw ArgumentError.value(how, 'how', 'unsupported join mode');
    if (how == 'cross' && (left.isNotEmpty || right.isNotEmpty)) {
      throw ArgumentError('Cross joins must not specify keys');
    }
    if (how != 'cross' && (left.isEmpty || left.length != right.length)) {
      throw ArgumentError(
        'leftOn and rightOn must have equal, non-zero lengths',
      );
    }
    if (coalesce && {'semi', 'anti', 'cross'}.contains(how)) {
      throw ArgumentError.value(
        coalesce,
        'coalesce',
        'is invalid for $how joins',
      );
    }
    final resources = <_HandleOwner>[
      _owner,
      other._owner,
      ...left.map((x) => x._owner),
      ...right.map((x) => x._owner),
    ];
    final leases = _leaseAll(resources);
    try {
      final keyStart = 2;
      final rightStart = keyStart + left.length;
      return _runtime._adoptLazy(
        _runtime._client.invokeSync('lazyJoin', {
          'left': leases[0].handle.toString(),
          'right': leases[1].handle.toString(),
          'leftOn': leases
              .sublist(keyStart, rightStart)
              .map((x) => x.handle.toString())
              .toList(),
          'rightOn': leases
              .sublist(rightStart)
              .map((x) => x.handle.toString())
              .toList(),
          'how': how,
          'suffix': suffix,
          'coalesce': coalesce,
        }),
      );
    } finally {
      _releaseAll(leases);
    }
  }

  /// Typed counterpart to [join]. The legacy string-based API remains intact.
  LazyFrame joinWithOptions(
    LazyFrame other, {
    required Iterable<Expr> leftOn,
    required Iterable<Expr> rightOn,
    JoinOptions options = const JoinOptions(),
  }) {
    final fields = options._toJson();
    return _joinCommand(other, leftOn, rightOn, fields);
  }

  LazyFrame _joinCommand(
    LazyFrame other,
    Iterable<Expr> leftOn,
    Iterable<Expr> rightOn,
    Map<String, Object?> fields,
  ) {
    _runtime._requireLazy(other);
    final left = List<Expr>.unmodifiable(leftOn);
    final right = List<Expr>.unmodifiable(rightOn);
    for (final value in [...left, ...right]) _runtime._requireExpr(value);
    final how = fields['how'] as String;
    if (how == 'cross' && (left.isNotEmpty || right.isNotEmpty)) {
      throw ArgumentError('Cross joins must not specify keys');
    }
    if (how != 'cross' && (left.isEmpty || left.length != right.length)) {
      throw ArgumentError(
        'leftOn and rightOn must have equal, non-zero lengths',
      );
    }
    final coalesce = fields['coalesce'];
    if (coalesce == true && {'semi', 'anti', 'cross'}.contains(how)) {
      throw ArgumentError.value(
        coalesce,
        'coalesce',
        'is invalid for $how joins',
      );
    }
    if (fields['validation'] != null &&
        fields['validation'] != 'manyToMany' &&
        !{'inner', 'left', 'full', 'outer'}.contains(how)) {
      throw ArgumentError('join validation is unsupported for $how joins');
    }
    final leases = _leaseAll([
      _owner,
      other._owner,
      ...left.map((x) => x._owner),
      ...right.map((x) => x._owner),
    ]);
    try {
      final rightStart = 2 + left.length;
      return _runtime._adoptLazy(
        _runtime._client.invokeSync('lazyJoin', {
          'left': leases[0].handle.toString(),
          'right': leases[1].handle.toString(),
          'leftOn': leases
              .sublist(2, rightStart)
              .map((x) => x.handle.toString())
              .toList(),
          'rightOn': leases
              .sublist(rightStart)
              .map((x) => x.handle.toString())
              .toList(),
          ...fields,
        }),
      );
    } finally {
      _releaseAll(leases);
    }
  }

  LazyFrame joinAsOf(
    LazyFrame other, {
    required Expr leftOn,
    required Expr rightOn,
    AsOfJoinOptions options = const AsOfJoinOptions(),
  }) {
    _runtime._requireLazy(other);
    _runtime._requireExpr(leftOn);
    _runtime._requireExpr(rightOn);
    final fields = options._toJson();
    final leases = _leaseAll([
      _owner,
      other._owner,
      leftOn._owner,
      rightOn._owner,
    ]);
    try {
      return _runtime._adoptLazy(
        _runtime._client.invokeSync('lazyJoinAsOf', {
          'left': leases[0].handle.toString(),
          'right': leases[1].handle.toString(),
          'leftOn': leases[2].handle.toString(),
          'rightOn': leases[3].handle.toString(),
          ...fields,
        }),
      );
    } finally {
      _releaseAll(leases);
    }
  }

  LazyFrame joinWhere(
    LazyFrame other,
    Iterable<Expr> predicates, {
    JoinWhereOptions options = const JoinWhereOptions(),
  }) {
    _runtime._requireLazy(other);
    final values = List<Expr>.unmodifiable(predicates);
    if (values.isEmpty) {
      throw ArgumentError.value(predicates, 'predicates', 'must not be empty');
    }
    for (final value in values) _runtime._requireExpr(value);
    final fields = options._toJson();
    final leases = _leaseAll([
      _owner,
      other._owner,
      ...values.map((x) => x._owner),
    ]);
    try {
      return _runtime._adoptLazy(
        _runtime._client.invokeSync('lazyJoinWhere', {
          'left': leases[0].handle.toString(),
          'right': leases[1].handle.toString(),
          'predicates': leases.skip(2).map((x) => x.handle.toString()).toList(),
          ...fields,
        }),
      );
    } finally {
      _releaseAll(leases);
    }
  }

  LazyFrame distinct({
    Iterable<String>? subset,
    String keep = 'first',
    bool maintainOrder = false,
  }) {
    if (!{'first', 'last', 'any', 'none'}.contains(keep)) {
      throw ArgumentError.value(keep, 'keep', 'unsupported keep mode');
    }
    final names = subset == null ? null : _validatedNames(subset, 'subset');
    return _inputCommand('lazyDistinct', {
      if (names != null) 'subset': names,
      'keep': keep,
      'maintainOrder': maintainOrder,
    });
  }

  LazyFrame dropNulls({Iterable<String>? subset}) => _inputCommand(
    'lazyDropNulls',
    {if (subset != null) 'subset': _validatedNames(subset, 'subset')},
  );
  LazyFrame drop(Iterable<String> columns, {bool strict = true}) =>
      _inputCommand('lazyDrop', {
        'columns': _validatedNames(columns, 'columns'),
        'strict': strict,
      });
  LazyFrame rename(Map<String, String> mapping, {bool strict = true}) {
    if (mapping.isEmpty)
      throw ArgumentError.value(mapping, 'mapping', 'must not be empty');
    for (final entry in mapping.entries) {
      _validateName(entry.key, 'mapping key');
      _validateName(entry.value, 'mapping value');
    }
    return _inputCommand('lazyRename', {
      'existing': mapping.keys.toList(growable: false),
      'new': mapping.values.toList(growable: false),
      'strict': strict,
    });
  }

  LazyFrame explode(Iterable<String> columns) => _inputCommand('lazyExplode', {
    'columns': _validatedNames(columns, 'columns'),
    'emptyAsNull': true,
    'keepNulls': true,
  });
  LazyFrame unnest(Iterable<String> columns) => _inputCommand('lazyUnnest', {
    'columns': _validatedNames(columns, 'columns'),
  });

  LazyFrame unpivot({
    Iterable<String>? on,
    Iterable<String> index = const [],
    String? variableName,
    String? valueName,
  }) {
    final onNames = on == null ? null : _validatedNames(on, 'on');
    final indexNames = List<String>.unmodifiable(index);
    if (indexNames.any((name) => name.isEmpty)) {
      throw ArgumentError.value(index, 'index', 'must contain non-empty names');
    }
    if (variableName != null) _validateName(variableName, 'variableName');
    if (valueName != null) _validateName(valueName, 'valueName');
    return _inputCommand('lazyUnpivot', {
      if (onNames != null) 'on': onNames,
      'index': indexNames,
      if (variableName != null) 'variableName': variableName,
      if (valueName != null) 'valueName': valueName,
    });
  }

  List<Field> schemaSync() {
    final lease = _owner.lease('LazyFrame');
    try {
      return _schema(
        _runtime._client.invokeSync('lazySchema', {
          'input': lease.handle.toString(),
        })['schema'],
      );
    } finally {
      lease.end();
    }
  }

  Future<List<Field>> schema() async {
    final lease = _owner.lease('LazyFrame');
    try {
      final response = await _runtime._client.invoke('lazySchema', {
        'input': lease.handle.toString(),
      });
      return _schema(response['schema']);
    } finally {
      lease.end();
    }
  }

  String explainSync({
    bool optimized = true,
    ExplainFormat format = ExplainFormat.plain,
  }) {
    final lease = _owner.lease('LazyFrame');
    try {
      return _runtime._client.invokeSync('lazyExplain', {
            'input': lease.handle.toString(),
            'optimized': optimized,
            'format': format.wireName,
          })['explanation']
          as String;
    } finally {
      lease.end();
    }
  }

  Future<String> explain({
    bool optimized = true,
    ExplainFormat format = ExplainFormat.plain,
  }) async {
    final lease = _owner.lease('LazyFrame');
    try {
      final response = await _runtime._client.invoke('lazyExplain', {
        'input': lease.handle.toString(),
        'optimized': optimized,
        'format': format.wireName,
      });
      return response['explanation'] as String;
    } finally {
      lease.end();
    }
  }

  DataFrame collectSync({ExecutionOptions options = const ExecutionOptions()}) {
    final lease = _owner.lease('LazyFrame');
    try {
      return _runtime._adoptFrame(
        _runtime._client.invokeSync('lazyCollect', {
          'input': lease.handle.toString(),
          ...options._toJson(),
        }),
      );
    } finally {
      lease.end();
    }
  }

  Future<CancellableQuery> submit({
    ExecutionOptions options = const ExecutionOptions(),
  }) async {
    if (options.engine != ExecutionEngine.auto) {
      throw UnsupportedError(
        'Asynchronous jobs require ExecutionEngine.auto so cancellation remains cooperative',
      );
    }
    final lease = _owner.lease('LazyFrame');
    try {
      return _runtime._adoptJob(
        await _runtime._client.invoke('lazySubmit', {
          'input': lease.handle.toString(),
          ...options._toJson(),
        }),
      );
    } finally {
      lease.end();
    }
  }

  Future<DataFrame> collect({
    ExecutionOptions options = const ExecutionOptions(),
  }) async {
    final job = await submit(options: options);
    try {
      await job.wait();
      return await job.take();
    } finally {
      job.close();
    }
  }

  /// Starts bounded pull-based batch production on a native worker.
  ///
  /// At most [capacity] frames wait in the native channel. The worker never
  /// invokes Dart callbacks; consumers explicitly call [BatchStream.poll].
  BatchStream batchStreamSync({
    int batchRows = 65536,
    int capacity = 2,
    ExecutionEngine engine = ExecutionEngine.auto,
  }) {
    _validateBatchStreamLimits(batchRows, capacity);
    final lease = _owner.lease('LazyFrame');
    try {
      return _runtime._adoptBatchStream(
        _runtime._client.invokeSync('lazyBatchStream', {
          'input': lease.handle.toString(),
          'batchRows': batchRows,
          'capacity': capacity,
          'engine': engine.wireName,
        }),
      );
    } finally {
      lease.end();
    }
  }

  /// Asynchronous transport variant of [batchStreamSync].
  Future<BatchStream> batchStream({
    int batchRows = 65536,
    int capacity = 2,
    ExecutionEngine engine = ExecutionEngine.auto,
  }) async {
    _validateBatchStreamLimits(batchRows, capacity);
    final lease = _owner.lease('LazyFrame');
    try {
      return _runtime._adoptBatchStream(
        await _runtime._client.invoke('lazyBatchStream', {
          'input': lease.handle.toString(),
          'batchRows': batchRows,
          'capacity': capacity,
          'engine': engine.wireName,
        }),
      );
    } finally {
      lease.end();
    }
  }

  /// Runs Polars' in-memory profiler and returns both frames as one result.
  ProfileResult profileSync({
    OptimizerOptions optimizer = const OptimizerOptions(),
  }) {
    final lease = _owner.lease('LazyFrame');
    try {
      return _runtime._adoptProfile(
        _runtime._client.invokeSync('lazyProfile', {
          'input': lease.handle.toString(),
          ...optimizer._toJson(),
        }),
      );
    } finally {
      lease.end();
    }
  }

  void writeCsvSync(
    String path, {
    bool includeHeader = true,
    String separator = ',',
  }) {
    sinkCsvSync(path, includeHeader: includeHeader, separator: separator);
  }

  /// Compatibility Future wrapper around the native lazy sink. Depending on
  /// the transport, native execution may still occur on the calling isolate.
  Future<void> writeCsv(
    String path, {
    bool includeHeader = true,
    String separator = ',',
  }) async {
    writeCsvSync(path, includeHeader: includeHeader, separator: separator);
  }

  void writeParquetSync(String path, {String compression = 'zstd'}) {
    sinkParquetSync(path, compression: compression);
  }

  /// Compatibility Future wrapper around the native lazy sink. Depending on
  /// the transport, native execution may still occur on the calling isolate.
  Future<void> writeParquet(String path, {String compression = 'zstd'}) async =>
      writeParquetSync(path, compression: compression);
}

/// The materialized query result and Polars node timings (microseconds).
final class ProfileResult {
  const ProfileResult._(this.result, this.timings);

  final DataFrame result;
  final DataFrame timings;

  void close() {
    result.close();
    timings.close();
  }
}

final class LazyGroupBy {
  const LazyGroupBy._(this._frame, this._keys, this._maintainOrder);
  final LazyFrame _frame;
  final List<Expr> _keys;
  final bool _maintainOrder;
  LazyFrame agg(Iterable<Expr> aggregations) {
    final values = List<Expr>.unmodifiable(aggregations);
    for (final value in [..._keys, ...values])
      _frame._runtime._requireExpr(value);
    final leases = _leaseAll([
      _frame._owner,
      ..._keys.map((x) => x._owner),
      ...values.map((x) => x._owner),
    ]);
    try {
      final split = 1 + _keys.length;
      return _frame._runtime._adoptLazy(
        _frame._runtime._client.invokeSync('lazyGroupBy', {
          'input': leases.first.handle.toString(),
          'keys': leases
              .sublist(1, split)
              .map((x) => x.handle.toString())
              .toList(),
          'aggregations': leases
              .sublist(split)
              .map((x) => x.handle.toString())
              .toList(),
          'maintainOrder': _maintainOrder,
        }),
      );
    } finally {
      _releaseAll(leases);
    }
  }
}

final class LazyDynamicGroupBy {
  const LazyDynamicGroupBy._(
    this._frame,
    this._indexColumn,
    this._keys,
    this._options,
  );

  final LazyFrame _frame;
  final Expr _indexColumn;
  final List<Expr> _keys;
  final DynamicGroupByOptions _options;

  LazyFrame agg(Iterable<Expr> aggregations) => _temporalGroupAgg(
    _frame,
    'lazyGroupByDynamic',
    _indexColumn,
    _keys,
    aggregations,
    _options._toJson(),
  );
}

final class LazyRollingGroupBy {
  const LazyRollingGroupBy._(
    this._frame,
    this._indexColumn,
    this._keys,
    this._options,
  );

  final LazyFrame _frame;
  final Expr _indexColumn;
  final List<Expr> _keys;
  final RollingGroupByOptions _options;

  LazyFrame agg(Iterable<Expr> aggregations) => _temporalGroupAgg(
    _frame,
    'lazyGroupByRolling',
    _indexColumn,
    _keys,
    aggregations,
    _options._toJson(),
  );
}

LazyFrame _temporalGroupAgg(
  LazyFrame frame,
  String command,
  Expr indexColumn,
  List<Expr> keys,
  Iterable<Expr> aggregations,
  Map<String, Object?> options,
) {
  frame._runtime._requireExpr(indexColumn);
  final values = List<Expr>.unmodifiable(aggregations);
  for (final value in [...keys, ...values]) {
    frame._runtime._requireExpr(value);
  }
  final leases = _leaseAll([
    frame._owner,
    indexColumn._owner,
    ...keys.map((x) => x._owner),
    ...values.map((x) => x._owner),
  ]);
  try {
    final aggregationStart = 2 + keys.length;
    return frame._runtime._adoptLazy(
      frame._runtime._client.invokeSync(command, {
        'input': leases[0].handle.toString(),
        'indexColumn': leases[1].handle.toString(),
        'groupBy': leases
            .sublist(2, aggregationStart)
            .map((x) => x.handle.toString())
            .toList(),
        'aggregations': leases
            .skip(aggregationStart)
            .map((x) => x.handle.toString())
            .toList(),
        ...options,
      }),
    );
  } finally {
    _releaseAll(leases);
  }
}

final class CancellableQuery {
  CancellableQuery._(this._runtime, int handle)
    : _owner = _HandleOwner(_runtime, handle) {
    _owner.attach();
  }
  final Polars _runtime;
  final _HandleOwner _owner;
  bool _busy = false;
  bool get isClosed => _owner.isClosed;
  void close() => _owner.close();

  _HandleLease _begin() {
    if (_busy) throw StateError('Another query job operation is in progress');
    final lease = _owner.lease('Query job');
    _busy = true;
    return lease;
  }

  void _end(_HandleLease lease) {
    _busy = false;
    lease.end();
  }

  Future<JobStatus> _pollRaw(int handle) async => JobStatus.fromResponse(
    await _runtime._client.invoke('jobPoll', {'job': handle.toString()}),
  );
  Future<JobStatus> poll() async {
    final lease = _begin();
    try {
      final status = await _pollRaw(lease.handle);
      if (status.state == JobState.failed ||
          status.state == JobState.cancelled ||
          status.state == JobState.taken) {
        _owner.close();
      }
      return status;
    } catch (_) {
      _owner.close();
      rethrow;
    } finally {
      _end(lease);
    }
  }

  Future<JobStatus> wait({
    Duration pollInterval = const Duration(milliseconds: 10),
  }) async {
    if (pollInterval.isNegative) {
      throw ArgumentError.value(
        pollInterval,
        'pollInterval',
        'must be nonnegative',
      );
    }
    final lease = _begin();
    try {
      while (true) {
        if (_owner.closeRequested) {
          throw const StaleHandleException('Query job was abandoned');
        }
        final status = await _pollRaw(lease.handle);
        if (status.state == JobState.failed) {
          _owner.close();
          throw status.error ??
              ComputeException(status.message ?? 'Native query job failed');
        }
        if (status.state == JobState.cancelled) {
          _owner.close();
          throw status.error ??
              QueryCancelledException(
                status.message ?? 'Native query job was cancelled',
              );
        }
        if (status.terminal) return status;
        await Future<void>.delayed(pollInterval);
      }
    } catch (_) {
      _owner.close();
      rethrow;
    } finally {
      _end(lease);
    }
  }

  Future<void> cancel() async {
    final lease = _begin();
    try {
      await _runtime._client.invoke('jobCancel', {
        'job': lease.handle.toString(),
      });
    } finally {
      _owner.close();
      _end(lease);
    }
  }

  Future<DataFrame> take() async {
    final lease = _begin();
    var release = true;
    try {
      final response = await _runtime._client.invoke('jobTake', {
        'job': lease.handle.toString(),
      });
      if (response['ready'] != true) {
        release = false;
        throw StateError('Job result is not ready');
      }
      return _runtime._adoptFrame(response);
    } finally {
      if (release) _owner.close();
      _end(lease);
    }
  }
}

typedef CollectJob = CancellableQuery;

List<bool> _broadcast(Object value, int length, String name) {
  if (value is bool) return List<bool>.filled(length, value, growable: false);
  if (value is Iterable<bool>) {
    final values = List<bool>.unmodifiable(value);
    if (values.length == length) return values;
  }
  throw ArgumentError.value(
    value,
    name,
    'must be bool or match expression count',
  );
}

List<String> _validatedNames(Iterable<String> values, String name) {
  final result = List<String>.unmodifiable(values);
  if (result.isEmpty || result.any((value) => value.isEmpty)) {
    throw ArgumentError.value(values, name, 'must contain non-empty names');
  }
  return result;
}

List<Field> _schema(Object? raw) {
  if (raw is! List)
    throw const FormatException('Native schema must be an array');
  return List<Field>.unmodifiable(
    raw.map((value) {
      final field = (value as Map).cast<String, Object?>();
      return Field(
        field['name'] as String,
        DType.fromJson((field['dtype'] as Map).cast<String, Object?>()),
      );
    }),
  );
}
