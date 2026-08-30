import 'package:dartaframes/polars.dart';
import 'package:test/test.dart';

final class IoInvoker implements ProtocolInvoker {
  final requests = <Map<String, Object?>>[];
  final released = <int>[];
  int nextHandle = 1;

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
  test('local scanners use closed typed option fields and direct handles', () {
    final fake = IoInvoker();
    final polars = Polars.fromClient(ProtocolClient(fake));
    final ipc = polars.scanFeather(
      'input.feather',
      options: const IpcScanOptions(
        nRows: 4,
        cache: true,
        recordBatchStatistics: true,
      ),
    );
    final ndjson = polars.scanNdjson(
      'input.ndjson',
      options: const NdjsonScanOptions(
        inferSchemaLength: 25,
        ignoreErrors: true,
        lowMemory: true,
      ),
    );

    expect(fake.requests[0], {
      'protocol': 2,
      'command': 'lazyScanIpc',
      'path': 'input.feather',
      'nRows': 4,
      'cache': true,
      'rechunk': false,
      'recordBatchStatistics': true,
    });
    expect(fake.requests[1], containsPair('command', 'lazyScanNdjson'));
    expect(fake.requests[1], containsPair('inferSchemaLength', 25));
    expect(fake.requests[1], containsPair('ignoreErrors', true));
    ipc.close();
    ndjson.close();
  });

  test('eager local reads and writes retain direct frame handles', () async {
    final fake = IoInvoker();
    final polars = Polars.fromClient(ProtocolClient(fake));
    final json = polars.readJsonSync(
      'rows.json',
      options: const JsonReadOptions(batchSize: 64, rechunk: false),
    );
    json.writeIpcSync(
      'rows.ipc',
      options: const IpcWriteOptions(
        compression: IpcCompression.lz4,
        recordBatchSize: 32,
        parallel: false,
      ),
    );
    await json.writeIpcStream(
      'rows.stream',
      options: const IpcStreamWriteOptions(compression: IpcCompression.zstd),
    );
    json.writeJsonSync('copy.json');
    json.writeNdjsonSync('copy.ndjson');

    expect(fake.requests[1], containsPair('frame', '1'));
    expect(fake.requests[1], containsPair('compression', 'lz4'));
    expect(fake.requests[2], containsPair('command', 'frameWriteIpcStream'));
    expect(fake.requests[2], containsPair('frame', '1'));
    expect(fake.requests.map((x) => x['command']), [
      'frameReadJson',
      'frameWriteIpc',
      'frameWriteIpcStream',
      'frameWriteJson',
      'frameWriteNdjson',
    ]);
    json.close();
  });

  test('lazy writes are native sinks and never collect a frame', () async {
    final fake = IoInvoker();
    final polars = Polars.fromClient(ProtocolClient(fake));
    final frame = polars.fromRecordBatchSync(
      RecordBatch(ArrowSchema([ArrowField('x', ArrowIntegerType(32))]), [
        ArrowArray(ArrowIntegerType(32), [ArrowIntegerValue(1)]),
      ]),
    );
    final lazy = frame.lazy();
    frame.close();

    lazy.sinkIpcSync(
      'output.ipc',
      ipc: const IpcWriteOptions(compression: IpcCompression.zstd),
      options: const LazySinkOptions(maintainOrder: false),
    );
    lazy.sinkNdjsonSync('output.ndjson');
    await lazy.writeCsv('output.csv', separator: ';');
    await lazy.writeParquet('output.parquet', compression: 'snappy');

    final commands = fake.requests.map((x) => x['command']).toList();
    expect(commands, containsAll(['lazySinkIpc', 'lazySinkNdjson']));
    expect(commands, isNot(contains('lazyCollect')));
    expect(fake.requests[2], containsPair('input', '2'));
    expect(fake.requests[2], containsPair('maintainOrder', false));
    lazy.close();
  });

  test('invalid local options fail before transport', () {
    final fake = IoInvoker();
    final polars = Polars.fromClient(ProtocolClient(fake));
    expect(
      () => polars.scanIpc('x', options: IpcScanOptions(nRows: -1)),
      throwsA(anyOf(isA<RangeError>(), isA<AssertionError>())),
    );
    expect(() => polars.scanNdjson(''), throwsArgumentError);
    expect(() => polars.scanIpc('s3://bucket/x.ipc'), throwsArgumentError);
    expect(fake.requests, isEmpty);
  });

  test('stream reads and async local writers preserve every option', () async {
    final fake = IoInvoker();
    final polars = Polars.fromClient(ProtocolClient(fake));
    final frame = await polars.readIpcStream(
      'input.stream',
      options: const IpcStreamReadOptions(
        nRows: 7,
        columns: ['a', 'b'],
        rechunk: false,
      ),
    );
    await frame.writeFeather(
      'output.feather',
      options: const IpcWriteOptions(
        compression: IpcCompression.zstd,
        recordBatchSize: 128,
        parallel: false,
        recordBatchStatistics: true,
      ),
    );
    await frame.writeJson('output.json');
    await frame.writeNdjson('output.ndjson');

    expect(fake.requests[0], {
      'protocol': 2,
      'command': 'frameReadIpcStream',
      'path': 'input.stream',
      'nRows': 7,
      'columns': ['a', 'b'],
      'rechunk': false,
    });
    expect(fake.requests[1], containsPair('command', 'frameWriteIpc'));
    expect(fake.requests[1], containsPair('recordBatchSize', 128));
    expect(fake.requests[1], containsPair('parallel', false));
    expect(fake.requests[1], containsPair('recordBatchStatistics', true));
    expect(fake.requests.map((request) => request['command']), [
      'frameReadIpcStream',
      'frameWriteIpc',
      'frameWriteJson',
      'frameWriteNdjson',
    ]);
    frame.close();
  });

  test('stream option validation happens before transport', () {
    final fake = IoInvoker();
    final polars = Polars.fromClient(ProtocolClient(fake));
    expect(
      () => polars.readIpcStreamSync(
        'input.stream',
        options: const IpcStreamReadOptions(columns: ['']),
      ),
      throwsArgumentError,
    );
    expect(
      () => polars.readJsonSync(
        'input.json',
        options: JsonReadOptions(batchSize: 0),
      ),
      throwsA(anyOf(isA<RangeError>(), isA<AssertionError>())),
    );
    expect(fake.requests, isEmpty);
  });
}
