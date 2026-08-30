part of 'polars.dart';

extension EagerDataFrameOperations on DataFrame {
  DataFrame _frameInput(
    String command, [
    Map<String, Object?> fields = const {},
  ]) {
    final lease = _owner.lease('DataFrame');
    try {
      return _runtime._adoptFrame(
        _runtime._client.invokeSync(command, {
          'frame': lease.handle.toString(),
          ...fields,
        }),
      );
    } finally {
      lease.end();
    }
  }

  DataFrame _frameExpressions(
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
      return _runtime._adoptFrame(
        _runtime._client.invokeSync(command, {
          'frame': leases.first.handle.toString(),
          field: leases.skip(1).map((x) => x.handle.toString()).toList(),
          ...fields,
        }),
      );
    } finally {
      _releaseAll(leases);
    }
  }

  Series column(String name) {
    _validateName(name, 'name');
    final lease = _owner.lease('DataFrame');
    try {
      return _runtime._adoptSeries(
        _runtime._client.invokeSync('frameColumn', {
          'frame': lease.handle.toString(),
          'name': name,
        }),
      );
    } finally {
      lease.end();
    }
  }

  DataFrame selectColumns(Iterable<String> columns) => _frameInput(
    'frameSelectColumns',
    {'columns': _validatedNames(columns, 'columns')},
  );

  DataFrame select(Iterable<Expr> expressions) =>
      _frameExpressions('frameSelect', 'expressions', expressions);

  DataFrame filter(Expr predicate) {
    _runtime._requireExpr(predicate);
    final leases = _leaseAll([_owner, predicate._owner]);
    try {
      return _runtime._adoptFrame(
        _runtime._client.invokeSync('frameFilter', {
          'frame': leases[0].handle.toString(),
          'predicate': leases[1].handle.toString(),
        }),
      );
    } finally {
      _releaseAll(leases);
    }
  }

  DataFrame filterMask(Series mask) {
    _runtime._requireSeries(mask);
    final leases = _leaseAll([_owner, mask._owner]);
    try {
      return _runtime._adoptFrame(
        _runtime._client.invokeSync('frameFilterMask', {
          'frame': leases[0].handle.toString(),
          'mask': leases[1].handle.toString(),
        }),
      );
    } finally {
      _releaseAll(leases);
    }
  }

  DataFrame withColumns(Iterable<Expr> expressions) =>
      _frameExpressions('frameWithColumns', 'expressions', expressions);

  DataFrame sort(
    Iterable<Expr> by, {
    Object descending = false,
    Object nullsLast = false,
    bool maintainOrder = false,
  }) {
    final values = List<Expr>.unmodifiable(by);
    return _frameExpressions(
      'frameSort',
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

  DataFrame slice(int offset, int length) {
    if (offset < -0x8000000000000000 || offset > 0x7fffffffffffffff) {
      throw RangeError.value(offset, 'offset', 'must fit signed 64-bit');
    }
    if (length < 0 || length > 0xffffffff) {
      throw RangeError.range(length, 0, 0xffffffff, 'length');
    }
    return _frameInput('frameSlice', {'offset': offset, 'length': length});
  }

  DataFrame head([int length = 5]) => slice(0, length);
  DataFrame tail([int length = 5]) => slice(-length, length);
  DataFrame reverse() => _frameInput('frameReverse');

  DataFrame drop(Iterable<String> columns, {bool strict = true}) => _frameInput(
    'frameDrop',
    {'columns': _validatedNames(columns, 'columns'), 'strict': strict},
  );

  DataFrame rename(Map<String, String> mapping, {bool strict = true}) {
    if (mapping.isEmpty) {
      throw ArgumentError.value(mapping, 'mapping', 'must not be empty');
    }
    for (final entry in mapping.entries) {
      _validateName(entry.key, 'mapping key');
      _validateName(entry.value, 'mapping value');
    }
    return _frameInput('frameRename', {
      'existing': mapping.keys.toList(growable: false),
      'new': mapping.values.toList(growable: false),
      'strict': strict,
    });
  }
}
