part of 'polars.dart';

enum RoundMode {
  halfToEven('halfToEven'),
  halfAwayFromZero('halfAwayFromZero'),
  toZero('toZero');

  const RoundMode(this.wireName);
  final String wireName;
}

final class Expr {
  Expr._(this._runtime, int handle) : _owner = _HandleOwner(_runtime, handle) {
    _owner.attach();
  }

  final Polars _runtime;
  final _HandleOwner _owner;
  bool get isClosed => _owner.isClosed;
  void close() => _owner.close();

  /// Non-owning namespace views. Closing a view is neither necessary nor
  /// possible; operations lease this expression and return independent handles.
  ExprStringNameSpace get str => ExprStringNameSpace._(this);
  ExprDateTimeNameSpace get dt => ExprDateTimeNameSpace._(this);
  ExprListNameSpace get list => ExprListNameSpace._(this);
  ExprArrayNameSpace get arr => ExprArrayNameSpace._(this);
  ExprStructNameSpace get struct => ExprStructNameSpace._(this);
  ExprBinaryNameSpace get bin => ExprBinaryNameSpace._(this);
  ExprCategoricalNameSpace get cat => ExprCategoricalNameSpace._(this);
  ExprNameNameSpace get name => ExprNameNameSpace._(this);
  ExprMetaNameSpace get meta => ExprMetaNameSpace._(this);

  Expr alias(String name) {
    _validateName(name, 'name');
    return _inputCommand('exprAlias', {'name': name});
  }

  Expr cast(DType dtype, {bool strict = true}) {
    if (!dtype.capabilities.cast) {
      throw ArgumentError.value(dtype, 'dtype', 'does not support casts');
    }
    return _inputCommand('exprCast', {
      'dtype': dtype.toJson(),
      'strict': strict,
    });
  }

  Expr unary(String operation) {
    _validateName(operation, 'operation');
    return _inputCommand('exprUnary', {'op': operation});
  }

  Expr _inputCommand(String command, [Map<String, Object?> fields = const {}]) {
    final lease = _owner.lease('Expr');
    try {
      return _runtime._adoptExpr(
        _runtime._client.invokeSync(command, {
          'input': lease.handle.toString(),
          ...fields,
        }),
      );
    } finally {
      lease.end();
    }
  }

  Expr binary(String operation, Object other) {
    _validateName(operation, 'operation');
    return _withOperands([this, other], (handles) {
      return _runtime._adoptExpr(
        _runtime._client.invokeSync('exprBinary', {
          'left': handles[0],
          'right': handles[1],
          'op': operation,
        }),
      );
    });
  }

  Expr eq(Object other) => binary('eq', other);
  Expr eqValidity(Object other) => binary('eqValidity', other);
  Expr notEq(Object other) => binary('notEq', other);
  Expr notEqValidity(Object other) => binary('notEqValidity', other);
  Expr lt(Object other) => binary('lt', other);
  Expr ltEq(Object other) => binary('ltEq', other);
  Expr gt(Object other) => binary('gt', other);
  Expr gtEq(Object other) => binary('gtEq', other);
  Expr logicalAnd(Object other) => binary('logicalAnd', other);
  Expr logicalOr(Object other) => binary('logicalOr', other);
  Expr and(Object other) => logicalAnd(other);
  Expr or(Object other) => logicalOr(other);
  Expr get not => unary('not');
  Expr get isNull => unary('isNull');
  Expr get isNotNull => unary('isNotNull');
  Expr get isNaN => unary('isNan');
  Expr get isNotNaN => unary('isNotNan');
  Expr get neg => unary('negate');

  Expr operator +(Object other) => binary('add', other);
  Expr operator -(Object other) => binary('subtract', other);
  Expr operator *(Object other) => binary('multiply', other);
  Expr operator /(Object other) => binary('trueDivide', other);
  Expr operator ~/(Object other) => binary('floorDivide', other);
  Expr operator %(Object other) => binary('modulo', other);
  Expr operator &(Object other) => binary('bitAnd', other);
  Expr operator |(Object other) => binary('bitOr', other);
  Expr operator ^(Object other) => binary('bitXor', other);
  Expr operator -() => neg;

  Expr aggregate(
    String operation, {
    Map<String, Object?> arguments = const {},
  }) {
    _validateName(operation, 'operation');
    return _inputCommand('exprAggregate', {'op': operation, ...arguments});
  }

  Expr get count => aggregate('count');
  Expr get nullCount => aggregate('nullCount');
  Expr get sum => aggregate('sum');
  Expr get mean => aggregate('mean');
  Expr get min => aggregate('min');
  Expr get max => aggregate('max');
  Expr get first => aggregate('first');
  Expr get last => aggregate('last');
  Expr get median => aggregate('median');
  Expr get nUnique => aggregate('nUnique');
  Expr get product => aggregate('product');
  Expr get argMin => aggregate('argMin');
  Expr get argMax => aggregate('argMax');
  Expr get approximateNUnique => aggregate('approximateNUnique');
  Expr get nanMin => aggregate('nanMin');
  Expr get nanMax => aggregate('nanMax');
  Expr mode({bool maintainOrder = false}) =>
      aggregate('mode', arguments: {'maintainOrder': maintainOrder});
  Expr skew({bool bias = true}) => aggregate('skew', arguments: {'bias': bias});
  Expr kurtosis({bool fisher = true, bool bias = true}) =>
      aggregate('kurtosis', arguments: {'fisher': fisher, 'bias': bias});
  Expr any({bool ignoreNulls = true}) =>
      aggregate('any', arguments: {'ignoreNulls': ignoreNulls});
  Expr all({bool ignoreNulls = true}) =>
      aggregate('all', arguments: {'ignoreNulls': ignoreNulls});
  Expr std({int ddof = 1}) {
    _validateDdof(ddof);
    return aggregate('std', arguments: {'ddof': ddof});
  }

  Expr variance({int ddof = 1}) {
    _validateDdof(ddof);
    return aggregate('variance', arguments: {'ddof': ddof});
  }

  Expr quantile(double quantile, {String interpolation = 'linear'}) {
    if (!quantile.isFinite || quantile < 0 || quantile > 1) {
      throw RangeError.range(quantile, 0, 1, 'quantile');
    }
    const methods = {'nearest', 'lower', 'higher', 'midpoint', 'linear'};
    if (!methods.contains(interpolation)) {
      throw ArgumentError.value(
        interpolation,
        'interpolation',
        'unsupported method',
      );
    }
    return aggregate(
      'quantile',
      arguments: {'quantile': quantile, 'interpolation': interpolation},
    );
  }

  Expr function(String name, [Iterable<Expr> arguments = const []]) {
    _validateName(name, 'name');
    return _function(name, arguments: List<Expr>.unmodifiable(arguments));
  }

  Expr _function(
    String name, {
    Iterable<Object> arguments = const [],
    Map<String, Object?> options = const {},
  }) {
    final values = List<Object>.unmodifiable(arguments);
    return _withOperands([this, ...values], (handles) {
      return _runtime._adoptExpr(
        _runtime._client.invokeSync('exprFunction', {
          'input': handles.first,
          'name': name,
          'arguments': handles.skip(1).toList(growable: false),
          ...options,
        }),
      );
    });
  }

  Expr fillNull(Object value) => _function('fillNull', arguments: [value]);
  Expr abs() => _function('abs');
  Expr floor() => _function('floor');
  Expr ceil() => _function('ceil');
  Expr round({int decimals = 0, RoundMode mode = RoundMode.halfToEven}) {
    if (decimals < 0 || decimals > 0xffffffff) {
      throw RangeError.range(decimals, 0, 0xffffffff, 'decimals');
    }
    return _function(
      'round',
      options: {'decimals': decimals, 'mode': mode.wireName},
    );
  }

  Expr clip(Object minimum, Object maximum) =>
      _function('clip', arguments: [minimum, maximum]);
  Expr clipMin(Object minimum) => _function('clipMin', arguments: [minimum]);
  Expr clipMax(Object maximum) => _function('clipMax', arguments: [maximum]);
  Expr fillNaN(Object value) => _function('fillNan', arguments: [value]);
  Expr get isFinite => _function('isFinite');
  Expr get isInfinite => _function('isInfinite');
  Expr coalesce(Iterable<Object> expressions) {
    final values = List<Object>.unmodifiable(expressions);
    if (values.isEmpty) {
      throw ArgumentError.value(
        expressions,
        'expressions',
        'must not be empty',
      );
    }
    return _function('coalesce', arguments: values);
  }

  Expr isIn(Expr values, {bool nullsEqual = false}) => _function(
    'isIn',
    arguments: [values],
    options: {'nullsEqual': nullsEqual},
  );
  Expr lowercase() => _function('lowercase');
  Expr uppercase() => _function('uppercase');
  Expr stringContains(Object pattern, {bool literal = false, bool? strict}) {
    final resolvedStrict = strict ?? !literal;
    if (literal && resolvedStrict) {
      throw ArgumentError.value(
        strict,
        'strict',
        'must be false for literal matching',
      );
    }
    return _function(
      'stringContains',
      arguments: [pattern],
      options: {'literal': literal, 'strict': resolvedStrict},
    );
  }

  Expr stringStartsWith(Object prefix) =>
      _function('stringStartsWith', arguments: [prefix]);
  Expr stringEndsWith(Object suffix) =>
      _function('stringEndsWith', arguments: [suffix]);
  Expr stringReplace(
    Object pattern,
    Object replacement, {
    bool literal = false,
    bool replaceAll = false,
  }) => _function(
    'stringReplace',
    arguments: [pattern, replacement],
    options: {'literal': literal, 'replaceAll': replaceAll},
  );
  Expr stripChars([Object? characters]) => _function(
    'stripChars',
    arguments: characters == null ? const [] : [characters],
  );
  Expr shift(Object periods) => _function('shift', arguments: [periods]);
  Expr cumulativeSum({bool reverse = false}) =>
      _function('cumSum', options: {'reverse': reverse});
  Expr cumulativeMin({bool reverse = false}) =>
      _function('cumMin', options: {'reverse': reverse});
  Expr cumulativeMax({bool reverse = false}) =>
      _function('cumMax', options: {'reverse': reverse});

  Expr pow(Object exponent) => _function('pow', arguments: [exponent]);
  Expr sqrt() => _function('sqrt');
  Expr cbrt() => _function('cbrt');
  Expr log(Object base) => _function('log', arguments: [base]);
  Expr log1p() => _function('log1p');
  Expr exp() => _function('exp');
  Expr sin() => _function('sin');
  Expr cos() => _function('cos');
  Expr tan() => _function('tan');
  Expr cot() => _function('cot');
  Expr asin() => _function('asin');
  Expr acos() => _function('acos');
  Expr atan() => _function('atan');
  Expr atan2(Object x) => _function('atan2', arguments: [x]);
  Expr sinh() => _function('sinh');
  Expr cosh() => _function('cosh');
  Expr tanh() => _function('tanh');
  Expr asinh() => _function('asinh');
  Expr acosh() => _function('acosh');
  Expr atanh() => _function('atanh');
  Expr degrees() => _function('degrees');
  Expr radians() => _function('radians');
  Expr rank({RankMethod method = RankMethod.dense, bool descending = false}) =>
      _function(
        'rank',
        options: {'method': method.wireName, 'descending': descending},
      );
  Expr interpolate({InterpolationMethod method = InterpolationMethod.linear}) =>
      _function('interpolate', options: {'method': method.wireName});
  Expr interpolateBy(Object by) => _function('interpolateBy', arguments: [by]);
  Expr diff(
    Object periods, {
    DiffNullBehavior nullBehavior = DiffNullBehavior.ignore,
  }) => _function(
    'diff',
    arguments: [periods],
    options: {'nullBehavior': nullBehavior.wireName},
  );
  Expr pctChange(Object periods) =>
      _function('pctChange', arguments: [periods]);

  Expr rollingMin(RollingOptions options) =>
      _function('rollingMin', options: options._toJson());
  Expr rollingMax(RollingOptions options) =>
      _function('rollingMax', options: options._toJson());
  Expr rollingMean(RollingOptions options) =>
      _function('rollingMean', options: options._toJson());
  Expr rollingSum(RollingOptions options) =>
      _function('rollingSum', options: options._toJson());
  Expr rollingMedian(RollingOptions options) =>
      _function('rollingMedian', options: options._toJson());
  Expr rollingVariance(RollingOptions options) =>
      _function('rollingVariance', options: options._toJson());
  Expr rollingStd(RollingOptions options) =>
      _function('rollingStd', options: options._toJson());
  Expr ewmMean([EwmOptions options = const EwmOptions()]) {
    if (options.bias) {
      throw ArgumentError.value(
        options.bias,
        'options.bias',
        'ewmMean does not support bias in Polars 0.55.2',
      );
    }
    final wire = options._toJson()..remove('bias');
    return _function('ewmMean', options: wire);
  }

  Expr ewmSum([EwmOptions options = const EwmOptions()]) {
    if (!options.adjust || options.bias) {
      throw ArgumentError(
        'ewmSum does not support adjust or bias in Polars 0.55.2',
      );
    }
    final wire = options._toJson()
      ..remove('adjust')
      ..remove('bias');
    return _function('ewmSum', options: wire);
  }

  Expr ewmStd([EwmOptions options = const EwmOptions()]) =>
      _function('ewmStd', options: options._toJson());
  Expr ewmVariance([EwmOptions options = const EwmOptions()]) =>
      _function('ewmVariance', options: options._toJson());

  Expr over(
    Iterable<Expr> partitionBy, {
    Iterable<Expr> orderBy = const [],
    WindowOptions options = const WindowOptions(),
  }) {
    final partitions = List<Expr>.unmodifiable(partitionBy);
    final order = List<Expr>.unmodifiable(orderBy);
    if (partitions.isEmpty && order.isEmpty) {
      throw ArgumentError.value(
        partitionBy,
        'partitionBy',
        'partitionBy and orderBy must not both be empty',
      );
    }
    for (final value in [...partitions, ...order]) {
      _runtime._requireExpr(value);
    }
    final leases = _leaseAll([
      _owner,
      ...partitions.map((value) => value._owner),
      ...order.map((value) => value._owner),
    ]);
    try {
      final orderStart = 1 + partitions.length;
      return _runtime._adoptExpr(
        _runtime._client.invokeSync('exprOver', {
          'input': leases.first.handle.toString(),
          'partitionBy': leases
              .sublist(1, orderStart)
              .map((x) => x.handle.toString())
              .toList(),
          'orderBy': leases
              .skip(orderStart)
              .map((x) => x.handle.toString())
              .toList(),
          ...options._toJson(),
        }),
      );
    } finally {
      _releaseAll(leases);
    }
  }

  T _withOperands<T>(List<Object> values, T Function(List<String>) body) {
    // Reject cross-runtime resources before creating any temporary literals.
    for (final value in values.whereType<Expr>()) {
      _runtime._requireExpr(value);
    }
    final expressions = <Expr>[];
    final temporary = <Expr>[];
    try {
      for (final value in values) {
        if (value is Expr) {
          expressions.add(value);
        } else {
          final expression = _runtime.lit(value);
          expressions.add(expression);
          temporary.add(expression);
        }
      }
      final leases = _leaseAll(expressions.map((value) => value._owner));
      try {
        return body(
          leases.map((x) => x.handle.toString()).toList(growable: false),
        );
      } finally {
        _releaseAll(leases);
      }
    } finally {
      for (final value in temporary.reversed) value.close();
    }
  }
}

void _validateDdof(int ddof) {
  if (ddof < 0 || ddof > 255) throw RangeError.range(ddof, 0, 255, 'ddof');
}

final class When {
  const When._(this._runtime, this.predicate);
  final Polars _runtime;
  final Expr predicate;
  Then then(Object value) {
    if (value is Expr) _runtime._requireExpr(value);
    return Then._(_runtime, predicate, value);
  }
}

final class Then {
  const Then._(this._runtime, this.predicate, this.ifTrue);
  final Polars _runtime;
  final Expr predicate;
  final Object ifTrue;
  Expr otherwise(Object value) {
    // Use predicate's helper to get the same validation, temporary ownership,
    // leases, and reachability fencing as other multi-expression operations.
    return predicate._withOperands([predicate, ifTrue, value], (handles) {
      return _runtime._adoptExpr(
        _runtime._client.invokeSync('exprTernary', {
          'predicate': handles[0],
          'truthy': handles[1],
          'falsy': handles[2],
        }),
      );
    });
  }
}
