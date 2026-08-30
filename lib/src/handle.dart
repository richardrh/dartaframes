part of 'polars.dart';

final class _HandleOwner implements Finalizable {
  _HandleOwner(this.runtime, this.handle) {
    if (handle <= 0)
      throw ArgumentError.value(handle, 'handle', 'must be positive');
  }

  final Polars runtime;
  final int handle;
  Object? _token;
  bool _attached = false;
  bool _released = false;
  bool _closeRequested = false;
  int _leases = 0;

  bool get isClosed => _closeRequested || _released;
  bool get closeRequested => _closeRequested;

  void attach() {
    try {
      _token = runtime._client.invoker.attachHandleFinalizer(this, handle);
      _attached = true;
    } catch (_) {
      try {
        runtime._client.invoker.releaseHandle(handle);
      } catch (_) {}
      _released = true;
      rethrow;
    }
  }

  void ensureUsable(String kind) {
    if (_closeRequested || _released || !_attached) {
      throw StaleHandleException('$kind is closed');
    }
  }

  _HandleLease lease(String kind) {
    ensureUsable(kind);
    _leases++;
    return _HandleLease._(this);
  }

  void close() {
    if (_closeRequested || _released) return;
    _closeRequested = true;
    if (_leases == 0) _release();
  }

  void _endLease() {
    if (_leases <= 0) throw StateError('Unbalanced native handle lease');
    _leases--;
    if (_leases == 0 && _closeRequested) _release();
  }

  void _release() {
    if (_released) return;
    _released = true;
    final released = runtime._client.invoker.detachHandleFinalizer(_token);
    _token = null;
    if (!released) runtime._client.invoker.releaseHandle(handle);
  }
}

final class _HandleLease {
  _HandleLease._(this._owner);
  final _HandleOwner _owner;
  bool _ended = false;
  int get handle => _owner.handle;
  void end() {
    if (_ended) return;
    _ended = true;
    _owner._endLease();
  }
}

List<_HandleLease> _leaseAll(Iterable<_HandleOwner> owners) {
  final leases = <_HandleLease>[];
  try {
    for (final owner in owners) {
      leases.add(owner.lease('native resource'));
    }
    return leases;
  } catch (_) {
    _releaseAll(leases);
    rethrow;
  }
}

void _releaseAll(Iterable<_HandleLease> leases) {
  for (final lease in leases) {
    lease.end();
  }
}
