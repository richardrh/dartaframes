part of 'polars.dart';

final class ExprNameNameSpace {
  const ExprNameNameSpace._(this._expr);
  final Expr _expr;
  Expr get keep => _expr._function('name.keep');
  Expr prefix(String prefix) =>
      _expr._function('name.prefix', options: {'value': prefix});
  Expr suffix(String suffix) =>
      _expr._function('name.suffix', options: {'value': suffix});
  Expr get toLowercase => _expr._function('name.toLowercase');
  Expr get toUppercase => _expr._function('name.toUppercase');
}

final class ExprMetaNameSpace {
  const ExprMetaNameSpace._(this._expr);
  final Expr _expr;

  Map<String, Object?> _query(
    String operation, [
    Map<String, Object?> fields = const {},
  ]) {
    final lease = _expr._owner.lease('Expr');
    try {
      return _expr._runtime._client.invokeSync('exprMeta', {
        'input': lease.handle.toString(),
        'op': operation,
        ...fields,
      });
    } finally {
      lease.end();
    }
  }

  List<String> get rootNames {
    final value = _query('rootNames')['value'];
    if (value is! List || value.any((x) => x is! String)) {
      throw const InternalPolarsException(
        'Malformed exprMeta rootNames response',
      );
    }
    return List<String>.unmodifiable(value.cast<String>());
  }

  String get outputName {
    final value = _query('outputName')['value'];
    if (value is! String) {
      throw const InternalPolarsException(
        'Malformed exprMeta outputName response',
      );
    }
    return value;
  }

  bool _predicate(String operation, {bool? allowAliasing}) {
    final value = _query(operation, {
      if (allowAliasing != null) 'allowAliasing': allowAliasing,
    })['value'];
    if (value is! bool) {
      throw InternalPolarsException('Malformed exprMeta $operation response');
    }
    return value;
  }

  bool get isColumn => _predicate('isColumn');
  bool isColumnSelection({bool allowAliasing = false}) =>
      _predicate('isColumnSelection', allowAliasing: allowAliasing);
  bool isLiteral({bool allowAliasing = false}) =>
      _predicate('isLiteral', allowAliasing: allowAliasing);
  bool get hasMultipleOutputs => _predicate('hasMultipleOutputs');
  bool get isRegexProjection => _predicate('isRegexProjection');
  Expr get undoAliases => _expr._function('meta.undoAliases');
}
