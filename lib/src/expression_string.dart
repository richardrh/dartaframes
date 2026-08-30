part of 'polars.dart';

final class StringParseOptions {
  const StringParseOptions({
    this.format,
    this.strict = true,
    this.exact = true,
    this.cache = true,
  });
  final String? format;
  final bool strict;
  final bool exact;
  final bool cache;

  Map<String, Object?> _toJson() => {
    if (format != null) 'format': format,
    'strict': strict,
    'exact': exact,
    'cache': cache,
  };
}

final class ExprStringNameSpace {
  const ExprStringNameSpace._(this._expr);
  final Expr _expr;

  Expr get lenBytes => _expr._function('str.lenBytes');
  Expr get lenChars => _expr._function('str.lenChars');
  Expr toLowercase() => _expr._function('str.toLowercase');
  Expr toUppercase() => _expr._function('str.toUppercase');
  Expr contains(Object pattern, {bool literal = false, bool strict = true}) =>
      _expr._function(
        'str.contains',
        arguments: [pattern],
        options: {'literal': literal, 'strict': literal ? false : strict},
      );
  Expr startsWith(Object prefix) =>
      _expr._function('str.startsWith', arguments: [prefix]);
  Expr endsWith(Object suffix) =>
      _expr._function('str.endsWith', arguments: [suffix]);
  Expr find(Object pattern, {bool literal = false, bool strict = true}) =>
      _expr._function(
        'str.find',
        arguments: [pattern],
        options: {'literal': literal, 'strict': literal ? false : strict},
      );
  Expr extract(Object pattern, {int groupIndex = 1}) {
    if (groupIndex < 0) throw RangeError.value(groupIndex, 'groupIndex');
    return _expr._function(
      'str.extract',
      arguments: [pattern],
      options: {'groupIndex': groupIndex},
    );
  }

  Expr extractAll(Object pattern) =>
      _expr._function('str.extractAll', arguments: [pattern]);
  Expr split(
    Object by, {
    bool inclusive = false,
    bool regex = false,
    bool strict = true,
  }) => _expr._function(
    'str.split',
    arguments: [by],
    options: {'inclusive': inclusive, 'regex': regex, 'strict': strict},
  );
  Expr replace(
    Object pattern,
    Object replacement, {
    bool literal = false,
    bool replaceAll = false,
  }) => _expr._function(
    'str.replace',
    arguments: [pattern, replacement],
    options: {'literal': literal, 'replaceAll': replaceAll},
  );
  Expr stripChars([Object? characters]) => _expr._function(
    'str.stripChars',
    arguments: characters == null ? const [] : [characters],
  );
  Expr stripCharsStart([Object? characters]) => _expr._function(
    'str.stripCharsStart',
    arguments: characters == null ? const [] : [characters],
  );
  Expr stripCharsEnd([Object? characters]) => _expr._function(
    'str.stripCharsEnd',
    arguments: characters == null ? const [] : [characters],
  );
  Expr stripPrefix(Object prefix) =>
      _expr._function('str.stripPrefix', arguments: [prefix]);
  Expr stripSuffix(Object suffix) =>
      _expr._function('str.stripSuffix', arguments: [suffix]);
  Expr slice(Object offset, Object length) =>
      _expr._function('str.slice', arguments: [offset, length]);
  Expr head(Object n) => _expr._function('str.head', arguments: [n]);
  Expr tail(Object n) => _expr._function('str.tail', arguments: [n]);
  Expr padStart(Object length, {String fill = ' '}) =>
      _pad('str.padStart', length, fill);
  Expr padEnd(Object length, {String fill = ' '}) =>
      _pad('str.padEnd', length, fill);
  Expr _pad(String operation, Object length, String fill) {
    if (fill.runes.length != 1) {
      throw ArgumentError.value(fill, 'fill', 'must be one Unicode scalar');
    }
    return _expr._function(
      operation,
      arguments: [length],
      options: {'fill': fill},
    );
  }

  Expr zfill(Object length) =>
      _expr._function('str.zfill', arguments: [length]);
  Expr toDate([StringParseOptions options = const StringParseOptions()]) =>
      _expr._function('str.toDate', options: options._toJson());
  Expr toTime([StringParseOptions options = const StringParseOptions()]) =>
      _expr._function('str.toTime', options: options._toJson());
  Expr toDatetime({
    TimeUnit? timeUnit,
    String? timeZone,
    StringParseOptions options = const StringParseOptions(),
    Object ambiguous = 'raise',
  }) => _expr._function(
    'str.toDatetime',
    arguments: [ambiguous],
    options: {
      ...options._toJson(),
      if (timeUnit != null) 'timeUnit': timeUnit.json,
      if (timeZone != null) 'timeZone': timeZone,
    },
  );
}
