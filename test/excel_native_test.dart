import 'dart:io';

import 'package:dartaframes/polars.dart';
import 'package:test/test.dart';

void main() {
  final libraryPath = Platform.environment['DARTAFRAMES_NATIVE_LIBRARY'];
  final skipNative = libraryPath == null
      ? 'Set DARTAFRAMES_NATIVE_LIBRARY to the built native library'
      : false;

  late Polars polars;
  setUpAll(() {
    if (libraryPath != null) polars = Polars.open(libraryPath);
  });

  test('XLSX public APIs round-trip supported scalar columns', () {
    final directory = Directory.systemTemp.createTempSync('dartaframes-xlsx-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}/values.xlsx';
    final integer = ArrowIntegerType(64);
    final floating = ArrowFloatingType(64);
    final string = const ArrowUtf8Type();
    final boolean = const ArrowBooleanType();
    final date = const ArrowDateType();
    final datetime = const ArrowTimestampType(ArrowTimeUnit.millisecond);
    final source = polars.fromRecordBatchSync(
      RecordBatch(
        ArrowSchema([
          ArrowField('flag', boolean),
          ArrowField('count', integer),
          ArrowField('ratio', floating),
          ArrowField('label', string),
          ArrowField('date', date),
          ArrowField('when', datetime),
        ]),
        [
          ArrowArray(boolean, const [ArrowBooleanValue(true), null]),
          ArrowArray(integer, [ArrowIntegerValue(1), ArrowIntegerValue(2)]),
          ArrowArray(floating, [
            ArrowFloatingValue.float64(1.5),
            ArrowFloatingValue.float64(2.5),
          ]),
          ArrowArray(string, const [
            ArrowStringValue('a'),
            ArrowStringValue('b'),
          ]),
          ArrowArray(date, [ArrowTemporalValue(0), ArrowTemporalValue(1)]),
          ArrowArray(datetime, [
            ArrowTemporalValue(0),
            ArrowTemporalValue(1234),
          ]),
        ],
      ),
    );
    addTearDown(source.close);

    source.writeExcelSync(
      path,
      options: const ExcelWriteOptions(worksheet: 'Values'),
    );
    expect(File(path).readAsBytesSync().take(2), [0x50, 0x4b]);

    final returned = polars.readExcelSync(
      path,
      options: const ExcelReadOptions(
        worksheet: 'Values',
        inferSchemaLength: null,
      ),
    );
    addTearDown(returned.close);
    final batch = returned.exportSync();
    expect(batch.schema.fields.map((field) => field.name), [
      'flag',
      'count',
      'ratio',
      'label',
      'date',
      'when',
    ]);
    expect(batch.schema.fields[0].type, boolean);
    expect(batch.schema.fields[1].type, integer);
    expect(batch.schema.fields[2].type, floating);
    expect(batch.schema.fields[3].type, string);
    expect(batch.schema.fields[4].type, date);
    expect(batch.schema.fields[5].type, datetime);
    expect((batch.columns[1].values[1] as ArrowIntegerValue).value, BigInt.two);
    expect((batch.columns[3].values[0] as ArrowStringValue).value, 'a');
    expect(
      (batch.columns[5].values[1] as ArrowTemporalValue).value,
      BigInt.from(1234),
    );
  }, skip: skipNative);

  test('malformed XLSX workbook reports a native error', () {
    final directory = Directory.systemTemp.createTempSync(
      'dartaframes-xlsx-bad-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}/bad.xlsx';
    File(path).writeAsStringSync('not an xlsx workbook');

    expect(() => polars.readExcelSync(path), throwsA(isA<PolarsException>()));
  }, skip: skipNative);
}
