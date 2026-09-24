import 'package:dartaframes_polars/polars.dart';
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

  test('writer validation and legacy overrides happen before transport', () {
    final fake = IoInvoker();
    final polars = Polars.fromClient(ProtocolClient(fake));
    final frame = polars.fromRecordBatchSync(
      RecordBatch(ArrowSchema([ArrowField('x', ArrowIntegerType(32))]), [
        ArrowArray(ArrowIntegerType(32), [ArrowIntegerValue(1)]),
      ]),
    );
    final baseline = fake.requests.length;
    expect(
      () => frame.writeCsvSync(
        'x.csv',
        options: const CsvWriteOptions(decimalComma: true),
      ),
      throwsArgumentError,
    );
    expect(
      () => frame.writeParquetSync('x.parquet', compression: 'invalid'),
      throwsArgumentError,
    );
    expect(fake.requests, hasLength(baseline));

    frame.writeCsvSync(
      'x.csv',
      includeHeader: false,
      separator: '|',
      options: const CsvWriteOptions(separator: ';'),
    );
    expect(fake.requests.last, containsPair('includeHeader', false));
    expect(fake.requests.last, containsPair('separator', '|'));
    frame.close();
  });
}
