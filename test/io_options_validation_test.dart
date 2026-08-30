import 'package:dartaframes_polars/dartaframes_polars.dart';
import 'package:test/test.dart';

final class _IoOptionsInvoker implements ProtocolInvoker {
  final requests = <Map<String, Object?>>[];
  final released = <int>[];
  var nextHandle = 1;

  @override
  Map<String, Object?> invokeSync(Map<String, Object?> request) {
    requests.add(Map<String, Object?>.unmodifiable(request));
    return {'ok': true, 'handle': '${nextHandle++}'};
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
  test('non-streaming I/O options preserve nulls and explicit values', () {
    final fake = _IoOptionsInvoker();
    final polars = Polars.fromClient(ProtocolClient(fake));
    final ndjson = polars.scanNdjson(
      'rows.ndjson',
      options: const NdjsonScanOptions(
        nRows: 0,
        inferSchemaLength: null,
        ignoreErrors: true,
        lowMemory: true,
        rechunk: true,
      ),
    );
    final json = polars.readJsonSync(
      'rows.json',
      options: const JsonReadOptions(
        inferSchemaLength: null,
        batchSize: 1,
        rechunk: false,
      ),
    );
    json.writeIpcSync(
      'rows.ipc',
      options: const IpcWriteOptions(
        compression: IpcCompression.zstd,
        recordBatchSize: 1,
        parallel: false,
        recordBatchStatistics: true,
      ),
    );

    expect(fake.requests[0], {
      'protocol': 2,
      'command': 'lazyScanNdjson',
      'path': 'rows.ndjson',
      'nRows': 0,
      'inferSchemaLength': null,
      'ignoreErrors': true,
      'lowMemory': true,
      'rechunk': true,
    });
    expect(fake.requests[1], {
      'protocol': 2,
      'command': 'frameReadJson',
      'path': 'rows.json',
      'inferSchemaLength': null,
      'batchSize': 1,
      'rechunk': false,
    });
    expect(fake.requests[2], containsPair('recordBatchSize', 1));
    expect(fake.requests[2], containsPair('parallel', false));
    expect(fake.requests[2], containsPair('recordBatchStatistics', true));

    json.close();
    ndjson.close();
  });

  test('invalid non-streaming options fail before protocol invocation', () {
    final fake = _IoOptionsInvoker();
    final polars = Polars.fromClient(ProtocolClient(fake));

    expect(
      () => polars.scanNdjson(
        'rows.ndjson',
        options: NdjsonScanOptions(inferSchemaLength: 0),
      ),
      throwsA(isA<AssertionError>()),
    );
    expect(
      () => polars.readJsonSync(
        'rows.json',
        options: JsonReadOptions(inferSchemaLength: 0),
      ),
      throwsA(isA<AssertionError>()),
    );
    expect(
      () => IpcWriteOptions(recordBatchSize: 0),
      throwsA(isA<AssertionError>()),
    );
    expect(fake.requests, isEmpty);
  });
}
