part of 'polars.dart';

abstract final class _NestedNameSpace {
  static Expr unary(Expr expr, String namespace, String operation) =>
      expr._function('$namespace.$operation');
}

final class ExprListNameSpace {
  const ExprListNameSpace._(this._expr);
  final Expr _expr;
  Expr get len => _NestedNameSpace.unary(_expr, 'list', 'len');
  Expr get first => _NestedNameSpace.unary(_expr, 'list', 'first');
  Expr get last => _NestedNameSpace.unary(_expr, 'list', 'last');
  Expr get sum => _NestedNameSpace.unary(_expr, 'list', 'sum');
  Expr get min => _NestedNameSpace.unary(_expr, 'list', 'min');
  Expr get max => _NestedNameSpace.unary(_expr, 'list', 'max');
  Expr get mean => _NestedNameSpace.unary(_expr, 'list', 'mean');
  Expr get(Object index, {bool nullOnOob = false}) => _expr._function(
    'list.get',
    arguments: [index],
    options: {'nullOnOob': nullOnOob},
  );
  Expr contains(Object element, {bool nullsEqual = false}) => _expr._function(
    'list.contains',
    arguments: [element],
    options: {'nullsEqual': nullsEqual},
  );
  Expr sort({bool descending = false, bool nullsLast = false}) =>
      _expr._function(
        'list.sort',
        options: {'descending': descending, 'nullsLast': nullsLast},
      );
  Expr slice(Object offset, Object length) =>
      _expr._function('list.slice', arguments: [offset, length]);
}

final class ExprArrayNameSpace {
  const ExprArrayNameSpace._(this._expr);
  final Expr _expr;
  Expr get len => _NestedNameSpace.unary(_expr, 'arr', 'len');
  Expr get sum => _NestedNameSpace.unary(_expr, 'arr', 'sum');
  Expr get min => _NestedNameSpace.unary(_expr, 'arr', 'min');
  Expr get max => _NestedNameSpace.unary(_expr, 'arr', 'max');
  Expr get mean => _NestedNameSpace.unary(_expr, 'arr', 'mean');
  Expr get first => get(0, nullOnOob: true);
  Expr get last => get(-1, nullOnOob: true);
  Expr get toList => _NestedNameSpace.unary(_expr, 'arr', 'toList');
  Expr get(Object index, {bool nullOnOob = false}) => _expr._function(
    'arr.get',
    arguments: [index],
    options: {'nullOnOob': nullOnOob},
  );
  Expr contains(Object element, {bool nullsEqual = false}) => _expr._function(
    'arr.contains',
    arguments: [element],
    options: {'nullsEqual': nullsEqual},
  );
  Expr sort({bool descending = false, bool nullsLast = false}) =>
      _expr._function(
        'arr.sort',
        options: {'descending': descending, 'nullsLast': nullsLast},
      );
  Expr explode({bool emptyAsNull = true, bool keepNulls = true}) =>
      _expr._function(
        'arr.explode',
        options: {'emptyAsNull': emptyAsNull, 'keepNulls': keepNulls},
      );
}

final class ExprStructNameSpace {
  const ExprStructNameSpace._(this._expr);
  final Expr _expr;
  Expr field(String name) {
    _validateName(name, 'name');
    return _expr._function('struct.field', options: {'field': name});
  }

  Expr fieldAt(int index) =>
      _expr._function('struct.fieldAt', options: {'index': index});
  Expr renameFields(Iterable<String> names) {
    final values = List<String>.unmodifiable(names);
    if (values.isEmpty)
      throw ArgumentError.value(names, 'names', 'must not be empty');
    for (final value in values) _validateName(value, 'names');
    return _expr._function('struct.renameFields', options: {'fields': values});
  }

  Expr get jsonEncode => _expr._function('struct.jsonEncode');
}
