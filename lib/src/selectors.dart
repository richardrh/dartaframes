part of 'polars.dart';

/// The time-zone set used by a datetime datatype selector.
enum TimeZoneSelectorMode {
  any('any'),
  anySet('anySet'),
  unset('unset'),
  anyOf('anyOf'),
  unsetOrAnyOf('unsetOrAnyOf');

  const TimeZoneSelectorMode(this.wireName);
  final String wireName;
}

/// A schema-dependent column selector.
final class Selector {
  Selector._(this._runtime, int handle)
    : _owner = _HandleOwner(_runtime, handle) {
    _owner.attach();
  }

  final Polars _runtime;
  final _HandleOwner _owner;
  bool get isClosed => _owner.isClosed;
  void close() => _owner.close();

  Selector _binary(String operation, Selector other) {
    _runtime._requireSelector(other);
    final leases = _leaseAll([_owner, other._owner]);
    try {
      return _runtime._adoptSelector(
        _runtime._client.invokeSync('selectorBinary', {
          'left': leases[0].handle.toString(),
          'right': leases[1].handle.toString(),
          'op': operation,
        }),
      );
    } finally {
      _releaseAll(leases);
    }
  }

  Selector operator |(Selector other) => _binary('union', other);
  Selector operator &(Selector other) => _binary('intersection', other);
  Selector operator ^(Selector other) => _binary('symmetricDifference', other);
  Selector operator -(Selector other) => _binary('difference', other);

  /// Returns the complement of this selector.
  Selector operator ~() {
    final lease = _owner.lease('Selector');
    try {
      return _runtime._adoptSelector(
        _runtime._client.invokeSync('selectorNot', {
          'input': lease.handle.toString(),
        }),
      );
    } finally {
      lease.end();
    }
  }

  /// Converts this selector to a projection expression.
  Expr asExpr() {
    final lease = _owner.lease('Selector');
    try {
      return _runtime._adoptExpr(
        _runtime._client.invokeSync('selectorAsExpr', {
          'input': lease.handle.toString(),
        }),
      );
    } finally {
      lease.end();
    }
  }
}

/// A composable predicate over Polars datatypes.
final class DTypeSelector {
  DTypeSelector._(this._runtime, int handle)
    : _owner = _HandleOwner(_runtime, handle) {
    _owner.attach();
  }

  final Polars _runtime;
  final _HandleOwner _owner;
  bool get isClosed => _owner.isClosed;
  void close() => _owner.close();

  DTypeSelector _binary(String operation, DTypeSelector other) {
    _runtime._requireDTypeSelector(other);
    final leases = _leaseAll([_owner, other._owner]);
    try {
      return _runtime._adoptDTypeSelector(
        _runtime._client.invokeSync('dtypeSelectorBinary', {
          'left': leases[0].handle.toString(),
          'right': leases[1].handle.toString(),
          'op': operation,
        }),
      );
    } finally {
      _releaseAll(leases);
    }
  }

  DTypeSelector operator |(DTypeSelector other) => _binary('union', other);
  DTypeSelector operator &(DTypeSelector other) =>
      _binary('intersection', other);
  DTypeSelector operator ^(DTypeSelector other) =>
      _binary('symmetricDifference', other);
  DTypeSelector operator -(DTypeSelector other) => _binary('difference', other);

  DTypeSelector operator ~() {
    final lease = _owner.lease('DTypeSelector');
    try {
      return _runtime._adoptDTypeSelector(
        _runtime._client.invokeSync('dtypeSelectorNot', {
          'input': lease.handle.toString(),
        }),
      );
    } finally {
      lease.end();
    }
  }

  Selector asSelector() {
    final lease = _owner.lease('DTypeSelector');
    try {
      return _runtime._adoptSelector(
        _runtime._client.invokeSync('dtypeSelectorAsSelector', {
          'input': lease.handle.toString(),
        }),
      );
    } finally {
      lease.end();
    }
  }

  bool matches(DType dtype) {
    final lease = _owner.lease('DTypeSelector');
    try {
      return _runtime._client.invokeSync('dtypeSelectorMatches', {
            'input': lease.handle.toString(),
            'dtype': dtype.toJson(),
          })['matches']
          as bool;
    } finally {
      lease.end();
    }
  }
}

/// Runtime-bound constructors for selectors and datatype selectors.
final class SelectorFactory {
  const SelectorFactory._(this._runtime);
  final Polars _runtime;

  Selector _selector(
    String command, [
    Map<String, Object?> fields = const {},
  ]) => _runtime._adoptSelector(_runtime._client.invokeSync(command, fields));

  DTypeSelector _dtype(String kind, [Map<String, Object?> fields = const {}]) =>
      _runtime._adoptDTypeSelector(
        _runtime._client.invokeSync('dtypeSelectorCreate', {
          'kind': kind,
          ...fields,
        }),
      );

  Selector all() => _selector('selectorAll');
  Selector empty() => _selector('selectorEmpty');

  Selector byName(
    Iterable<String> names, {
    bool strict = true,
    bool expandPatterns = false,
  }) {
    final values = _selectorNames(names, 'names');
    return _selector('selectorByName', {
      'names': values,
      'strict': strict,
      'expandPatterns': expandPatterns,
    });
  }

  Selector byIndex(Iterable<int> indices, {bool strict = true}) {
    final values = List<int>.unmodifiable(indices);
    if (values.isEmpty || values.length > 10000) {
      throw ArgumentError.value(
        indices,
        'indices',
        'must contain 1 to 10000 values',
      );
    }
    for (final value in values) {
      if (value < -0x8000000000000000 || value > 0x7fffffffffffffff) {
        throw RangeError.value(value, 'indices', 'must fit signed 64-bit');
      }
    }
    return _selector('selectorByIndex', {'indices': values, 'strict': strict});
  }

  Selector matches(String pattern) {
    _validateName(pattern, 'pattern');
    return _selector('selectorMatches', {'pattern': pattern});
  }

  Selector byDType(DTypeSelector selector) {
    _runtime._requireDTypeSelector(selector);
    return selector.asSelector();
  }

  /// Selects columns whose datatype is one of [dtypes].
  Selector dtypes(Iterable<DType> dtypes) => anyOf(dtypes)._intoSelector();

  DTypeSelector dtypeAll() => _dtype('all');
  DTypeSelector dtypeEmpty() => _dtype('empty');
  DTypeSelector anyOf(Iterable<DType> dtypes) {
    final values = List<DType>.unmodifiable(dtypes);
    if (values.isEmpty || values.length > 10000) {
      throw ArgumentError.value(
        dtypes,
        'dtypes',
        'must contain 1 to 10000 values',
      );
    }
    return _dtype('anyOf', {
      'dtypes': values.map((value) => value.toJson()).toList(growable: false),
    });
  }

  DTypeSelector integerDTypes() => _dtype('integer');
  DTypeSelector unsignedIntegerDTypes() => _dtype('unsignedInteger');
  DTypeSelector signedIntegerDTypes() => _dtype('signedInteger');
  DTypeSelector floatingDTypes() => _dtype('floating');
  DTypeSelector enumDTypes() => _dtype('enum');
  DTypeSelector categoricalDTypes() => _dtype('categorical');
  DTypeSelector nestedDTypes() => _dtype('nested');
  DTypeSelector structDTypes() => _dtype('struct');
  DTypeSelector decimalDTypes() => _dtype('decimal');
  DTypeSelector numericDTypes() => _dtype('numeric');
  DTypeSelector temporalDTypes() => _dtype('temporal');
  DTypeSelector objectDTypes() => _dtype('object');

  DTypeSelector listDTypes({DTypeSelector? inner}) =>
      _nestedDType('list', inner);

  DTypeSelector arrayDTypes({DTypeSelector? inner, int? width}) {
    if (width != null && width <= 0) {
      throw RangeError.value(width, 'width', 'must be positive');
    }
    return _nestedDType('array', inner, {if (width != null) 'width': width});
  }

  DTypeSelector _nestedDType(
    String kind,
    DTypeSelector? inner, [
    Map<String, Object?> fields = const {},
  ]) {
    if (inner != null) _runtime._requireDTypeSelector(inner);
    final lease = inner?._owner.lease('DTypeSelector');
    try {
      return _dtype(kind, {
        if (lease != null) 'inner': lease.handle.toString(),
        ...fields,
      });
    } finally {
      lease?.end();
    }
  }

  DTypeSelector datetimeDTypes({
    Iterable<TimeUnit> units = TimeUnit.values,
    TimeZoneSelectorMode timeZoneMode = TimeZoneSelectorMode.any,
    Iterable<String> timeZones = const [],
  }) {
    final unitValues = List<TimeUnit>.unmodifiable(units);
    if (unitValues.isEmpty) {
      throw ArgumentError.value(units, 'units', 'must not be empty');
    }
    final zones = List<String>.unmodifiable(timeZones);
    final needsZones =
        timeZoneMode == TimeZoneSelectorMode.anyOf ||
        timeZoneMode == TimeZoneSelectorMode.unsetOrAnyOf;
    if (needsZones != zones.isNotEmpty || zones.any((zone) => zone.isEmpty)) {
      throw ArgumentError.value(
        timeZones,
        'timeZones',
        'must be non-empty exactly for anyOf/unsetOrAnyOf',
      );
    }
    return _dtype('datetime', {
      'units': unitValues.map((unit) => unit.json).toList(growable: false),
      'timeZoneMode': timeZoneMode.wireName,
      'timeZones': zones,
    });
  }

  DTypeSelector durationDTypes({Iterable<TimeUnit> units = TimeUnit.values}) {
    final values = List<TimeUnit>.unmodifiable(units);
    if (values.isEmpty) {
      throw ArgumentError.value(units, 'units', 'must not be empty');
    }
    return _dtype('duration', {
      'units': values.map((unit) => unit.json).toList(growable: false),
    });
  }

  Selector integer() => integerDTypes()._intoSelector();
  Selector unsignedInteger() => unsignedIntegerDTypes()._intoSelector();
  Selector signedInteger() => signedIntegerDTypes()._intoSelector();
  Selector floating() => floatingDTypes()._intoSelector();
  Selector categorical() => categoricalDTypes()._intoSelector();
  Selector enumeration() => enumDTypes()._intoSelector();
  Selector nested() => nestedDTypes()._intoSelector();
  Selector structs() => structDTypes()._intoSelector();
  Selector decimals() => decimalDTypes()._intoSelector();
  Selector numeric() => numericDTypes()._intoSelector();
  Selector temporal() => temporalDTypes()._intoSelector();
  Selector objects() => objectDTypes()._intoSelector();
}

extension on DTypeSelector {
  Selector _intoSelector() {
    try {
      return asSelector();
    } finally {
      close();
    }
  }
}

List<String> _selectorNames(Iterable<String> names, String argument) {
  final values = List<String>.unmodifiable(names);
  if (values.isEmpty ||
      values.length > 10000 ||
      values.any((value) => value.isEmpty)) {
    throw ArgumentError.value(
      names,
      argument,
      'must contain 1 to 10000 non-empty values',
    );
  }
  return values;
}
