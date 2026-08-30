import 'package:dartaframes_polars/dartaframes_polars.dart';
import 'package:test/test.dart';

final class _BatchInvoker implements ProtocolInvoker {
  final requests = <Map<String, Object?>>[];
  final released = <int>[];
  final polls = <Map<String, Object?>>[];
  int nextHandle = 1;

  @override
  Map<String, Object?> invokeSync(Map<String, Object?> request) {
    requests.add(Map<String, Object?>.unmodifiable(request));
    return switch (request['command']) {
      'batchStreamPoll' => polls.removeAt(0),
      'batchStreamCancel' => {'ok': true, 'state': 'cancelled'},
      'frameInfo' => {'ok': true, 'height': 2, 'width': 1, 'schema': const []},
      _ => {'ok': true, 'handle': '${nextHandle++}'},
    };
  }

  @override
  Future<Map<String, Object?>> invoke(Map<String, Object?> request) async =>
      invokeSync(request);

  @override
  void releaseHandle(int handle) => released.add(handle);

  @override
  Object? attachHandleFinalizer(Object owner, int handle) => null;

  @override
  bool detachHandleFinalizer(Object? token) => false;
}

void main() {
  test('bounded stream protocol returns independently owned frame handles', () {
    final fake = _BatchInvoker()
      ..polls.addAll([
        {'ok': true, 'state': 'pending'},
        {'ok': true, 'state': 'batch', 'kind': 'frame', 'handle': '3'},
        {'ok': true, 'state': 'complete'},
      ]);
    final lazy = Polars.fromClient(ProtocolClient(fake)).scanCsv('input.csv');
    final stream = lazy.batchStreamSync(
      batchRows: 128,
      capacity: 3,
      engine: ExecutionEngine.streaming,
    );
    expect(fake.requests.last, {
      'protocol': 2,
      'command': 'lazyBatchStream',
      'input': '1',
      'batchRows': 128,
      'capacity': 3,
      'engine': 'streaming',
    });

    expect(stream.pollSync().state, BatchStreamState.pending);
    final batch = stream.pollSync();
    expect(batch.state, BatchStreamState.batch);
    expect(batch.frame, isNotNull);
    expect(stream.pollSync().terminal, isTrue);
    stream.close();
    expect(fake.released, contains(2));

    // The batch owns handle 3, not a borrow from the stream.
    expect(batch.frame!.shapeSync(), (2, 1));
    batch.frame!.close();
    lazy.close();
    expect(fake.released, containsAll([1, 2, 3]));
    expect(
      fake.requests.where(
        (request) => request['command'] == 'batchStreamCancel',
      ),
      isEmpty,
    );
  });

  test('close cancels once and malformed poll rolls back returned handle', () {
    final fake = _BatchInvoker()
      ..polls.add({'ok': true, 'state': 'pending', 'handle': '99'});
    final lazy = Polars.fromClient(ProtocolClient(fake)).scanCsv('input.csv');
    final stream = lazy.batchStreamSync();
    expect(stream.pollSync, throwsFormatException);
    expect(fake.released, contains(99));

    stream.close();
    stream.close();
    expect(
      fake.requests
          .where((request) => request['command'] == 'batchStreamCancel')
          .length,
      1,
    );
    expect(fake.released.where((handle) => handle == 2).length, 1);
    lazy.close();
  });

  test('batch stream limits reject before protocol invocation', () {
    final fake = _BatchInvoker();
    final lazy = Polars.fromClient(ProtocolClient(fake)).scanCsv('input.csv');
    final before = fake.requests.length;
    expect(() => lazy.batchStreamSync(batchRows: 0), throwsRangeError);
    expect(() => lazy.batchStreamSync(capacity: 65), throwsRangeError);
    expect(fake.requests.length, before);
    lazy.close();
  });
}
