/// Base class for failures reported by the native Polars runtime.
///
/// Native errors are classified by [category] into one of the sealed
/// subclasses, so callers can `switch` exhaustively over failure kinds.
sealed class PolarsException implements Exception {
  /// Creates an exception carrying a human-readable [message].
  const PolarsException(this.message);

  /// Human-readable description of the failure.
  final String message;

  /// Stable protocol category name for this failure kind.
  String get category;

  @override
  String toString() => '$runtimeType($category): $message';

  /// Decodes a native protocol error object into the matching subclass.
  ///
  /// Reads the `category` and `message` fields. Unknown categories become an
  /// [InternalPolarsException] that preserves the native category name.
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

/// The native runtime rejected a request as malformed or invalid.
final class InvalidRequestException extends PolarsException {
  /// Creates an invalid-request exception with [message].
  const InvalidRequestException(super.message);
  @override
  String get category => 'invalidRequest';
}

/// The requested operation or data type is not supported by this binding.
final class UnsupportedPolarsException extends PolarsException {
  /// Creates an unsupported-operation exception with [message].
  const UnsupportedPolarsException(super.message);
  @override
  String get category => 'unsupported';
}

/// Polars failed while executing a query or computation.
final class ComputeException extends PolarsException {
  /// Creates a compute exception with [message].
  const ComputeException(super.message);
  @override
  String get category => 'executionError';
}

/// Reading or writing a file or stream failed in the native runtime.
final class PolarsIoException extends PolarsException {
  /// Creates an I/O exception with [message].
  const PolarsIoException(super.message);
  @override
  String get category => 'ioError';
}

/// A running query was cancelled before it produced a result.
final class QueryCancelledException extends PolarsException {
  /// Creates a cancellation exception with [message].
  const QueryCancelledException(super.message);
  @override
  String get category => 'cancelled';
}

/// A native handle was used after it was closed or was otherwise invalid.
final class StaleHandleException extends PolarsException {
  /// Creates a stale-handle exception with [message].
  const StaleHandleException(super.message);
  @override
  String get category => 'invalidHandle';
}

/// The Dart package and native library disagree on the wire protocol.
///
/// Usually indicates a native library built for a different package version.
final class ProtocolMismatchException extends PolarsException {
  /// Creates a protocol-mismatch exception with [message].
  const ProtocolMismatchException(super.message);
  @override
  String get category => 'protocolError';
}

/// An unexpected internal failure, or an unrecognized native error category.
final class InternalPolarsException extends PolarsException {
  /// Creates an internal exception with [message] and the original
  /// [nativeCategory] reported by the runtime.
  const InternalPolarsException(
    super.message, {
    this.nativeCategory = 'internal',
  });

  /// The category string reported by the native runtime.
  final String nativeCategory;
  @override
  String get category => nativeCategory;
}
