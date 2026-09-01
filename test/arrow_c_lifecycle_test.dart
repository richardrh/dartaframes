import 'dart:ffi';

import 'package:dartaframes/src/arrow_c.dart';
import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

final class _Bridge implements ArrowCBridge {
  final deleted = <String>[];
  int attaches = 0;
  int? failAttach;

  Object _attach() {
    attaches++;
    if (attaches == failAttach) throw StateError('attach failed');
    return Object();
  }

  @override
  Object attachArray(Finalizable owner, Pointer<CArrowArray> pointer) =>
      _attach();
  @override
  Object attachSchema(Finalizable owner, Pointer<CArrowSchema> pointer) =>
      _attach();
  @override
  Object attachStream(Finalizable owner, Pointer<CArrowArrayStream> pointer) =>
      _attach();

  @override
  void deleteArray(Object? attachment, Pointer<CArrowArray> pointer) {
    deleted.add('array');
    calloc.free(pointer);
  }

  @override
  void deleteSchema(Object? attachment, Pointer<CArrowSchema> pointer) {
    deleted.add('schema');
    calloc.free(pointer);
  }

  @override
  void deleteStream(Object? attachment, Pointer<CArrowArrayStream> pointer) {
    deleted.add('stream');
    calloc.free(pointer);
  }

  @override
  ArrowCData allocateData() =>
      ArrowCData.owned(this, calloc<CArrowArray>(), calloc<CArrowSchema>());
  @override
  ArrowCStream allocateStream() =>
      ArrowCStream.owned(this, calloc<CArrowArrayStream>());
  @override
  ArrowCData exportFrame(int handle) => throw UnimplementedError();
  @override
  ArrowCStream exportFrameStream(int handle, int maxRows) =>
      throw UnimplementedError();
  @override
  ArrowCData exportSeries(int handle) => throw UnimplementedError();
  @override
  int importFrame(ArrowCData data) => throw UnimplementedError();
  @override
  int importFrameStream(ArrowCStream stream, int maxBatches, int maxRows) =>
      throw UnimplementedError();
  @override
  int importSeries(ArrowCData data) => throw UnimplementedError();
}

void main() {
  test('explicit close and consumed state are idempotent and exactly once', () {
    final bridge = _Bridge();
    final data = bridge.allocateData();
    data.markConsumed();
    expect(data.isConsumed, isTrue);
    expect(data.markConsumed, throwsStateError);
    data.close();
    data.close();
    expect(bridge.deleted, ['schema', 'array']);

    final stream = bridge.allocateStream();
    stream.markConsumed();
    stream.close();
    stream.close();
    expect(bridge.deleted, ['schema', 'array', 'stream']);
  });

  test('partial finalizer attachment failure frees every top-level struct', () {
    final dataBridge = _Bridge()..failAttach = 2;
    expect(dataBridge.allocateData, throwsStateError);
    expect(dataBridge.deleted, containsAllInOrder(['schema', 'array']));

    final streamBridge = _Bridge()..failAttach = 1;
    expect(streamBridge.allocateStream, throwsStateError);
    expect(streamBridge.deleted, ['stream']);
  });
}
