part of 'polars.dart';

final class ExprBinaryNameSpace {
  const ExprBinaryNameSpace._(this._expr);
  final Expr _expr;
  Expr get sizeBytes => _expr._function('bin.sizeBytes');
  Expr contains(Object pattern) =>
      _expr._function('bin.contains', arguments: [pattern]);
  Expr startsWith(Object prefix) =>
      _expr._function('bin.startsWith', arguments: [prefix]);
  Expr endsWith(Object suffix) =>
      _expr._function('bin.endsWith', arguments: [suffix]);
  Expr get hexEncode => _expr._function('bin.hexEncode');
  Expr get base64Encode => _expr._function('bin.base64Encode');
}

final class ExprCategoricalNameSpace {
  const ExprCategoricalNameSpace._(this._expr);
  final Expr _expr;
  Expr get physical => _expr._function('cat.physical');
  Expr get categories => _expr._function('cat.categories');
}
