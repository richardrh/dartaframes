sealed class PolarsException implements Exception {
  const PolarsException(this.message);
  final String message;
  String get category;

  @override
  String toString() => '$runtimeType($category): $message';

  static PolarsException fromJson(Map<String, Object?> json) {
    final category = json['category'] as String? ?? 'internal';
    final message = json['message'] as String? ?? 'Native protocol error';
    return switch (category) {
      'invalidRequest' => InvalidRequestException(message),
      'unsupported' => UnsupportedPolarsException(message),
      'compute' || 'executionError' => ComputeException(message),
      'io' || 'ioError' => PolarsIoException(message),
      'cancelled' => QueryCancelledException(message),
      'staleHandle' || 'invalidHandle' => StaleHandleException(message),
      'protocolMismatch' ||
      'protocolError' => ProtocolMismatchException(message),
      _ => InternalPolarsException(message, nativeCategory: category),
    };
  }
}

final class InvalidRequestException extends PolarsException {
  const InvalidRequestException(super.message);
  @override
  String get category => 'invalidRequest';
}

final class UnsupportedPolarsException extends PolarsException {
  const UnsupportedPolarsException(super.message);
  @override
  String get category => 'unsupported';
}

final class ComputeException extends PolarsException {
  const ComputeException(super.message);
  @override
  String get category => 'executionError';
}

final class PolarsIoException extends PolarsException {
  const PolarsIoException(super.message);
  @override
  String get category => 'ioError';
}

final class QueryCancelledException extends PolarsException {
  const QueryCancelledException(super.message);
  @override
  String get category => 'cancelled';
}

final class StaleHandleException extends PolarsException {
  const StaleHandleException(super.message);
  @override
  String get category => 'invalidHandle';
}

final class ProtocolMismatchException extends PolarsException {
  const ProtocolMismatchException(super.message);
  @override
  String get category => 'protocolError';
}

final class InternalPolarsException extends PolarsException {
  const InternalPolarsException(
    super.message, {
    this.nativeCategory = 'internal',
  });
  final String nativeCategory;
  @override
  String get category => nativeCategory;
}
