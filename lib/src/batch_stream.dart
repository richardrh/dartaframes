part of 'polars.dart';

enum BatchStreamState { pending, batch, complete, cancelled }

/// One non-blocking pull result. [frame] is present exactly in [BatchStreamState.batch].
final class BatchStreamPoll {
  const BatchStreamPoll(this.state, [this.frame]);

  final BatchStreamState state;
  final DataFrame? frame;
  bool get terminal =>
      state == BatchStreamState.complete || state == BatchStreamState.cancelled;
}

/// Owns a bounded native batch stream handle.
///
/// Every batch is an independent [DataFrame] handle and remains usable after
/// this stream is cancelled or closed. Polling is non-blocking.
final class BatchStream {
  BatchStream._(this._runtime, int handle)
    : _owner = _HandleOwner(_runtime, handle) {
    _owner.attach();
  }

  final Polars _runtime;
  final _HandleOwner _owner;
  bool _terminal = false;

  bool get isClosed => _owner.isClosed;
  bool get isTerminal => _terminal;

  BatchStreamPoll pollSync() {
    final lease = _owner.lease('BatchStream');
    try {
      return _parsePoll(
        _runtime._client.invokeSync('batchStreamPoll', {
          'stream': lease.handle.toString(),
        }),
      );
    } finally {
      lease.end();
    }
  }

  Future<BatchStreamPoll> poll() async {
    final lease = _owner.lease('BatchStream');
    try {
      return _parsePoll(
        await _runtime._client.invoke('batchStreamPoll', {
          'stream': lease.handle.toString(),
        }),
      );
    } finally {
      lease.end();
    }
  }

  BatchStreamPoll _parsePoll(Map<String, Object?> response) {
    final rawState = response['state'];
    final state = BatchStreamState.values
        .where((value) => value.name == rawState)
        .firstOrNull;
    if (state == null) {
      _releaseUnexpectedFrame(response);
      throw FormatException('Unknown native batch stream state: $rawState');
    }
    if (state == BatchStreamState.batch) {
      if (response['kind'] != 'frame') {
        _releaseUnexpectedFrame(response);
        throw const FormatException('Native batch result is not a frame');
      }
      final frame = _runtime._adoptFrame(response);
      return BatchStreamPoll(state, frame);
    }
    if (response.containsKey('handle')) {
      _releaseUnexpectedFrame(response);
      throw FormatException(
        'Native $rawState batch result unexpectedly has a handle',
      );
    }
    if (state == BatchStreamState.complete ||
        state == BatchStreamState.cancelled) {
      _terminal = true;
    }
    return BatchStreamPoll(state);
  }

  void _releaseUnexpectedFrame(Map<String, Object?> response) {
    final value = response['handle'];
    final handle = switch (value) {
      int value => value,
      String value => int.tryParse(value),
      _ => null,
    };
    if (handle != null && handle > 0) {
      try {
        _runtime._client.invoker.releaseHandle(handle);
      } catch (_) {}
    }
  }

  void cancelSync() {
    if (_terminal) return;
    final lease = _owner.lease('BatchStream');
    try {
      final response = _runtime._client.invokeSync('batchStreamCancel', {
        'stream': lease.handle.toString(),
      });
      if (response['state'] != 'cancelled') {
        throw FormatException(
          'Invalid native cancellation state: ${response['state']}',
        );
      }
      _terminal = true;
    } finally {
      lease.end();
    }
  }

  Future<void> cancel() async {
    if (_terminal) return;
    final lease = _owner.lease('BatchStream');
    try {
      final response = await _runtime._client.invoke('batchStreamCancel', {
        'stream': lease.handle.toString(),
      });
      if (response['state'] != 'cancelled') {
        throw FormatException(
          'Invalid native cancellation state: ${response['state']}',
        );
      }
      _terminal = true;
    } finally {
      lease.end();
    }
  }

  /// Cancels production when necessary and releases the stream handle.
  void close() {
    if (isClosed) return;
    try {
      cancelSync();
    } finally {
      _owner.close();
    }
  }
}

void _validateBatchStreamLimits(int batchRows, int capacity) {
  if (batchRows < 1 || batchRows > 10000000) {
    throw RangeError.range(batchRows, 1, 10000000, 'batchRows');
  }
  if (capacity < 1 || capacity > 64) {
    throw RangeError.range(capacity, 1, 64, 'capacity');
  }
}
