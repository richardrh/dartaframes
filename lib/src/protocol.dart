import 'dart:async';

import 'errors.dart';

const int protocolVersion = 2;

/// Injectable transport. Test transports can implement this without loading FFI.
abstract interface class ProtocolInvoker {
  /// Invokes a short protocol command synchronously. For an FFI transport this
  /// runs on the calling isolate.
  Map<String, Object?> invokeSync(Map<String, Object?> request);

  /// Convenience Future API for short commands. Implementations may still call
  /// FFI on the current isolate; this is not an asynchronous execution claim.
  Future<Map<String, Object?>> invoke(Map<String, Object?> request) async =>
      invokeSync(request);

  /// Releases an owned protocol handle (`df_handle_release` for native FFI).
  void releaseHandle(int handle);

  /// Attaches a native finalizer, if this transport provides one. Native FFI
  /// uses a token from `df_handle_token_new`.
  Object? attachHandleFinalizer(Object owner, int handle) => null;

  /// Detaches and disposes a finalizer token. Returns true when disposing the
  /// token also released the native handle (through
  /// `df_handle_token_release` for native FFI).
  bool detachHandleFinalizer(Object? token) => false;
}

class ProtocolClient {
  ProtocolClient([ProtocolInvoker? invoker]) : _invoker = invoker;
  final ProtocolInvoker? _invoker;
  ProtocolInvoker get invoker => _invoker ?? (this as ProtocolInvoker);

  Map<String, Object?> invokeSync(
    String command, [
    Map<String, Object?> arguments = const {},
  ]) {
    final response = invoker.invokeSync({
      'protocol': protocolVersion,
      'command': command,
      ...arguments,
    });
    return _unwrap(response);
  }

  Future<Map<String, Object?>> invoke(
    String command, [
    Map<String, Object?> arguments = const {},
  ]) async {
    final response = await invoker.invoke({
      'protocol': protocolVersion,
      'command': command,
      ...arguments,
    });
    return _unwrap(response);
  }

  Map<String, Object?> _unwrap(Map<String, Object?> response) {
    if (response['ok'] == true) return response;
    final error = response['error'];
    if (error is Map) {
      throw PolarsException.fromJson(error.cast<String, Object?>());
    }
    throw const InternalPolarsException('Malformed native error response');
  }

  Map<String, Object?> helloSync() => invokeSync('hello');
  Future<Map<String, Object?>> hello() => invoke('hello');

  /// Returns capabilities reported by this particular native library.
  /// These are intentionally separate from Dart's static datatype capability
  /// declarations.
  NativeHelloCapabilities nativeCapabilitiesSync() =>
      NativeHelloCapabilities.fromHello(helloSync());
  Future<NativeHelloCapabilities> nativeCapabilities() async =>
      NativeHelloCapabilities.fromHello(await hello());
}

/// An immutable view of the native `hello` capability payload. No support is
/// inferred from Dart descriptor classes: absent native fields remain absent.
final class NativeHelloCapabilities {
  NativeHelloCapabilities.fromHello(Map<String, Object?> hello)
    : abi = hello['abi'] as int?,
      protocol = hello['protocol'] as int?,
      polars = hello['polars'] as String?,
      datatypes = List<Object?>.unmodifiable(
        (hello['datatypes'] as List? ?? const []).map(_freezeHelloValue),
      ),
      datatypeCapabilities = List<Object?>.unmodifiable(
        (hello['datatypeCapabilities'] as List? ?? const []).map(
          _freezeHelloValue,
        ),
      ),
      resources = List<String>.unmodifiable(
        (hello['resources'] as List? ?? const []).cast<String>(),
      ),
      interchange = _freezeStringMap(hello['interchange'], 'interchange'),
      commands = _freezeStringMap(hello['commands'], 'commands'),
      operations = _freezeOperations(hello['operations']),
      raw = Map<String, Object?>.unmodifiable({
        for (final entry in hello.entries)
          entry.key: _freezeHelloValue(entry.value),
      });

  final int? abi;
  final int? protocol;
  final String? polars;
  final List<Object?> datatypes;
  final List<Object?> datatypeCapabilities;
  final List<String> resources;
  final Map<String, Object?> interchange;
  final Map<String, Object?> commands;
  final Map<String, Object?> operations;
  final Map<String, Object?> raw;
}

/// A read-only snapshot of the native runtime's owned handle registry.
final class RuntimeDiagnostics {
  RuntimeDiagnostics.fromResponse(Map<String, Object?> response)
    : activeHandles = response['activeHandles'] as int,
      slotCapacity = response['slotCapacity'] as int,
      reusableSlots = response['reusableSlots'] as int,
      handlesByKind = Map<String, int>.unmodifiable(
        (response['handlesByKind'] as Map).cast<String, int>(),
      );

  final int activeHandles;
  final int slotCapacity;
  final int reusableSlots;
  final Map<String, int> handlesByKind;
}

Map<String, Object?> _freezeStringMap(Object? value, String field) {
  if (value == null) return const {};
  if (value is! Map) {
    throw FormatException('Native hello $field must be an object');
  }
  return Map<String, Object?>.unmodifiable({
    for (final entry in value.entries)
      entry.key as String: _freezeHelloValue(entry.value),
  });
}

Map<String, Object?> _freezeOperations(Object? value) {
  if (value == null) return const {};
  if (value is! Map) {
    throw const FormatException('Native hello operations must be an object');
  }
  return Map<String, Object?>.unmodifiable({
    for (final entry in value.entries)
      entry.key as String: _freezeHelloValue(entry.value),
  });
}

Object? _freezeHelloValue(Object? value) => switch (value) {
  Map value => Map.unmodifiable({
    for (final entry in value.entries)
      entry.key: _freezeHelloValue(entry.value),
  }),
  List value => List.unmodifiable(value.map(_freezeHelloValue)),
  _ => value,
};

enum JobState {
  queued,
  running,
  cancelling,
  complete,
  cancelled,
  failed,
  taken,
}

final class JobStatus {
  const JobStatus(this.state, {this.message, this.error});
  final JobState state;
  final String? message;
  final PolarsException? error;
  bool get terminal =>
      state == JobState.complete ||
      state == JobState.cancelled ||
      state == JobState.failed ||
      state == JobState.taken;

  factory JobStatus.fromResponse(Map<String, Object?> response) {
    final rawState = response['state'];
    final state = JobState.values.firstWhere(
      (value) => value.name == rawState,
      orElse: () =>
          throw FormatException('Unknown native job state: $rawState'),
    );
    final rawError = response['error'];
    final error = rawError is Map
        ? PolarsException.fromJson(rawError.cast<String, Object?>())
        : null;
    return JobStatus(
      state,
      message: response['message'] as String? ?? error?.message,
      error: error,
    );
  }
}
