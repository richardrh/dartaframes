import 'dart:typed_data';

import 'package:dartaframes_polars/arrow.dart';
import 'package:test/test.dart';

Uint8List _stream(ArrowDataType type, List<ArrowValue?> values) {
  final schema = ArrowSchema([ArrowField('value', type)]);
  return ArrowIpcStreamWriter(
    schema: schema,
    batches: [
      RecordBatch(schema, [ArrowArray(type, values)]),
    ],
  ).write();
}

void _roundtrip(ArrowDataType type, List<ArrowValue?> values) {
  final table = ArrowIpcStreamReader(_stream(type, values)).readTable();
  expect(table.batches.single.columns.single.values, values);
  final bytes = ArrowIpcFileWriter(
    schema: table.schema,
    batches: table.batches,
  ).write();
  expect(
    ArrowIpcFileReader(bytes).readTable().batches.single.columns.single.values,
    values,
  );
}

void main() {
  test('binary view inline boundary and external data', () {
    for (final size in [0, 1, 12, 13, 100]) {
      _roundtrip(const ArrowBinaryType(ArrowOffsetWidth.view), [
        ArrowBinaryValue(List.generate(size, (i) => i % 256)),
        null,
      ]);
      _roundtrip(const ArrowUtf8Type(ArrowOffsetWidth.view), [
        ArrowStringValue('é' * size),
        null,
      ]);
    }
  });
  test('fixed binary including zero width', () {
    for (final width in [0, 1, 16]) {
      _roundtrip(ArrowFixedSizeBinaryType(width), [
        ArrowBinaryValue(List.filled(width, 255)),
        null,
      ]);
    }
  });
  test('both list view widths preserve null and empty rows', () {
    for (final width in [ArrowOffsetWidth.normal, ArrowOffsetWidth.large]) {
      _roundtrip(
        ArrowListType(
          ArrowField('item', ArrowIntegerType(32)),
          offsetWidth: width,
          view: true,
        ),
        [
          ArrowListValue([ArrowIntegerValue(7), null]),
          null,
          ArrowListValue([]),
        ],
      );
    }
  });
  test('map keeps duplicate ordered keys and nullable values', () {
    _roundtrip(
      ArrowMapType(
        ArrowField('key', const ArrowUtf8Type(), nullable: false),
        ArrowField('value', ArrowIntegerType(32)),
      ),
      [
        ArrowMapValue([
          ArrowMapEntry(const ArrowStringValue('a'), ArrowIntegerValue(1)),
          const ArrowMapEntry(ArrowStringValue('a'), null),
        ]),
        null,
        ArrowMapValue([]),
      ],
    );
  });
  test('union arbitrary tags preserve selected nulls and float bits', () {
    for (final mode in ArrowUnionMode.values) {
      _roundtrip(
        ArrowUnionType(
          [
            ArrowField('f', ArrowFloatingType(64)),
            ArrowField('s', const ArrowUtf8Type()),
          ],
          mode: mode,
          typeIds: [5, 97],
        ),
        [
          ArrowUnionValue(
            5,
            ArrowFloatingValue(64, BigInt.parse('7ff8000000000001', radix: 16)),
          ),
          const ArrowUnionValue(97, null),
          const ArrowUnionValue(97, ArrowStringValue('hello')),
        ],
      );
    }
  });
  test('all interval units preserve signed components', () {
    final values = [
      ArrowIntervalValue.yearMonth(-2147483648),
      ArrowIntervalValue.dayTime(-7, 2147483647),
      ArrowIntervalValue.monthDayNano(
        -1,
        2,
        BigInt.parse('-9223372036854775808'),
      ),
    ];
    for (final value in values) {
      _roundtrip(ArrowIntervalType(value.unit), [value, null]);
    }
  });
  test('run end widths preserve repeated values and null runs', () {
    for (final width in [16, 32, 64]) {
      final type = ArrowRunEndEncodedType(
        ArrowField('run_ends', ArrowIntegerType(width), nullable: false),
        ArrowField('values', ArrowIntegerType(32)),
      );
      _roundtrip(type, [
        ArrowIntegerValue(7),
        ArrowIntegerValue(7),
        null,
        null,
        ArrowIntegerValue(-1),
      ]);
      _roundtrip(type, []);
    }
  });
  test('REE logical expansion is budget checked before allocation', () {
    final type = ArrowRunEndEncodedType(
      ArrowField('run_ends', ArrowIntegerType(32), nullable: false),
      ArrowField('values', ArrowIntegerType(32)),
    );
    final bytes = _stream(type, List.filled(1000, ArrowIntegerValue(1)));
    expect(
      () => ArrowIpcStreamReader(
        bytes,
        limits: const ArrowIpcLimits(maxValues: 10),
      ).readTable(),
      throwsFormatException,
    );
  });
}
