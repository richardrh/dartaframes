import 'dart:async';

import 'package:dartaframes/polars.dart';
import 'package:test/test.dart';

final class ExcelInvoker implements ProtocolInvoker {
  final requests = <Map<String, Object?>>[];
  final released = <int>[];
  Completer<void>? gate;
  int nextHandle = 1;

  Map<String, Object?> _respond(Map<String, Object?> request) {
    requests.add(Map<String, Object?>.unmodifiable(request));
    return {'ok': true, 'handle': '${nextHandle++}'};
  }

  @override
  Map<String, Object?> invokeSync(Map<String, Object?> request) =>
      _respond(request);

  @override
  Future<Map<String, Object?>> invoke(Map<String, Object?> request) async {
    final pending = gate;
    if (pending != null) await pending.future;
    return _respond(request);
  }

  @override
  void releaseHandle(int handle) => released.add(handle);

  @override
  Object? attachHandleFinalizer(Object owner, int handle) => null;

  @override
  bool detachHandleFinalizer(Object? token) => false;
}

void main() {
  test('Excel APIs emit eager closed protocol fields', () async {
    final fake = ExcelInvoker();
    final polars = Polars.fromClient(ProtocolClient(fake));
    final frame = polars.readExcelSync(
      'input.xlsx',
      options: const ExcelReadOptions(
        worksheet: 'Data',
        hasHeader: false,
        columnNames: ['id', 'name'],
        inferSchemaLength: null,
      ),
    );
    frame.writeExcelSync(
      'output.xlsx',
      options: const ExcelWriteOptions(
        worksheet: 'Export',
        includeHeader: false,
        dateFormat: 'dd/mm/yyyy',
        datetimeFormat: 'dd/mm/yyyy hh:mm:ss',
      ),
    );
    final second = await polars.readExcel('second.xlsx');
    await second.writeExcel('second-output.xlsx');

    expect(fake.requests[0], {
      'protocol': 2,
      'command': 'frameReadExcel',
      'path': 'input.xlsx',
      'worksheet': 'Data',
      'hasHeader': false,
      'columnNames': ['id', 'name'],
      'inferSchemaLength': null,
    });
    expect(fake.requests[1], {
      'protocol': 2,
      'command': 'frameWriteExcel',
      'frame': '1',
      'path': 'output.xlsx',
      'worksheet': 'Export',
      'includeHeader': false,
      'dateFormat': 'dd/mm/yyyy',
      'datetimeFormat': 'dd/mm/yyyy hh:mm:ss',
    });
    expect(fake.requests[2], {
      'protocol': 2,
      'command': 'frameReadExcel',
      'path': 'second.xlsx',
      'hasHeader': true,
      'inferSchemaLength': 100,
    });
    expect(fake.requests[3], containsPair('command', 'frameWriteExcel'));
    expect(fake.requests[3], containsPair('frame', '3'));

    frame.close();
    second.close();
  });

  test('invalid Excel options fail before transport', () {
    final fake = ExcelInvoker();
    final polars = Polars.fromClient(ProtocolClient(fake));

    expect(
      () => polars.readExcelSync(
        'input.xlsx',
        options: const ExcelReadOptions(columnNames: ['x', 'x']),
      ),
      throwsArgumentError,
    );
    expect(
      () => polars.readExcelSync(
        'input.xlsx',
        options: const ExcelReadOptions(worksheet: ''),
      ),
      throwsArgumentError,
    );
    expect(
      () => polars.readExcelSync('https://example/x.xlsx'),
      throwsArgumentError,
    );
    expect(fake.requests, isEmpty);
  });

  test(
    'async Excel write lease defers close until invocation finishes',
    () async {
      final fake = ExcelInvoker();
      final polars = Polars.fromClient(ProtocolClient(fake));
      final frame = polars.readExcelSync('input.xlsx');
      fake.gate = Completer<void>();

      final write = frame.writeExcel('output.xlsx');
      frame.close();
      expect(fake.released, isEmpty);

      fake.gate!.complete();
      await write;
      expect(fake.released, [1]);
      expect(fake.requests.last['command'], 'frameWriteExcel');
      expect(fake.requests.last['frame'], '1');
    },
  );
}
