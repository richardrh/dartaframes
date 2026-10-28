import 'package:dartaframes_polars/arrow.dart';
import 'package:test/test.dart';

ArrowArray roundTrip(ArrowArray array) {
  const codec = OwnedBatchJsonCodec();
  final batch = RecordBatch(ArrowSchema([ArrowField('c', array.type)]), [
    array,
  ]);
  return codec.decode(codec.encode(batch)).columns.single;
}

final int32 = ArrowIntegerType(32);
final str = ArrowField('v', const ArrowUtf8Type());

void main() {
  group('datatype JSON', () {
    final types = <ArrowDataType>[
      const ArrowUtf8Type(ArrowOffsetWidth.view),
      const ArrowBinaryType(ArrowOffsetWidth.view),
      ArrowFixedSizeBinaryType(4),
      ArrowFixedSizeBinaryType(0),
      ArrowListType(str, offsetWidth: ArrowOffsetWidth.large),
      ArrowListType(str, view: true),
      ArrowListType(str, offsetWidth: ArrowOffsetWidth.large, view: true),
      ArrowDecimalType(9, 2, bitWidth: 32),
      ArrowDecimalType(18, -3, bitWidth: 64),
      ArrowDecimalType(76, 80, bitWidth: 256),
      ArrowMapType(
        ArrowField('k', const ArrowUtf8Type(), nullable: false),
        ArrowField('v', int32),
        keysSorted: true,
      ),
      ArrowUnionType(
        [ArrowField('i', int32), str],
        mode: ArrowUnionMode.dense,
        typeIds: [5, 9],
      ),
      for (final unit in ArrowIntervalUnit.values) ArrowIntervalType(unit),
      ArrowRunEndEncodedType(
        ArrowField('run_ends', ArrowIntegerType(16), nullable: false),
        str,
      ),
    ];
    for (final type in types) {
      test('$type roundtrips', () {
        expect(ArrowDataType.fromJson(type.toJson()), type);
      });
    }

    test('128-bit decimal keeps legacy JSON shape', () {
      expect(ArrowDecimalType(38, 4).toJson(), {
        'kind': 'decimal',
        'precision': 38,
        'scale': 4,
      });
      expect(
        ArrowDataType.fromJson({'kind': 'decimal', 'precision': 3, 'scale': 1}),
        ArrowDecimalType(3, 1),
      );
    });

    test('rejects malformed definitions', () {
      expect(() => ArrowDecimalType(10, 0, bitWidth: 32), throwsRangeError);
      expect(() => ArrowDecimalType(5, 0, bitWidth: 16), throwsArgumentError);
      expect(() => ArrowFixedSizeBinaryType(-1), throwsRangeError);
      expect(
        () => ArrowListType(str, offsetWidth: ArrowOffsetWidth.view),
        throwsArgumentError,
      );
      expect(
        () => ArrowMapType(ArrowField('k', int32), ArrowField('v', int32)),
        throwsArgumentError,
      );
      expect(
        () => ArrowUnionType([str, str], typeIds: [1, 1]),
        throwsArgumentError,
      );
      expect(() => ArrowUnionType([str], typeIds: [128]), throwsRangeError);
      expect(
        () => ArrowRunEndEncodedType(ArrowField('r', ArrowIntegerType(8)), str),
        throwsArgumentError,
      );
      expect(
        () => ArrowRunEndEncodedType(ArrowField('r', int32), str),
        throwsArgumentError,
      );
      expect(
        () => ArrowDataType.fromJson({
          'kind': 'union',
          'mode': 'dense',
          'typeIds': [0, 0],
          'fields': [str.toJson(), str.toJson()],
        }),
        throwsFormatException,
      );
      expect(
        () => ArrowDataType.fromJson({'kind': 'interval', 'unit': 'weeks'}),
        throwsFormatException,
      );
    });
  });

  group('values', () {
    final map = ArrowMapType(
      ArrowField('k', const ArrowUtf8Type(), nullable: false),
      ArrowField('v', int32),
    );
    final union = ArrowUnionType(
      [ArrowField('i', int32), str],
      typeIds: [3, 7],
    );

    test('every extended type roundtrips through the batch codec', () {
      final arrays = [
        ArrowArray(const ArrowUtf8Type(ArrowOffsetWidth.view), [
          const ArrowStringValue('a long string beyond twelve bytes'),
          null,
        ]),
        ArrowArray(ArrowFixedSizeBinaryType(2), [
          ArrowBinaryValue([1, 2]),
          null,
        ]),
        ArrowArray(ArrowListType(str, view: true), [
          ArrowListValue([const ArrowStringValue('x'), null]),
        ]),
        ArrowArray(ArrowDecimalType(76, -5, bitWidth: 256), [
          ArrowDecimalValue(BigInt.parse('9' * 76)),
        ]),
        ArrowArray(map, [
          ArrowMapValue([
            ArrowMapEntry(const ArrowStringValue('z'), ArrowIntegerValue(1)),
            const ArrowMapEntry(ArrowStringValue('a'), null),
            ArrowMapEntry(const ArrowStringValue('z'), ArrowIntegerValue(2)),
          ]),
          null,
        ]),
        ArrowArray(union, [
          ArrowUnionValue(3, ArrowIntegerValue(4)),
          const ArrowUnionValue(7, ArrowStringValue('s')),
          const ArrowUnionValue(7, null),
        ]),
        ArrowArray(const ArrowIntervalType(ArrowIntervalUnit.yearMonth), [
          ArrowIntervalValue.yearMonth(-14),
        ]),
        ArrowArray(const ArrowIntervalType(ArrowIntervalUnit.dayTime), [
          ArrowIntervalValue.dayTime(3, -500),
        ]),
        ArrowArray(const ArrowIntervalType(ArrowIntervalUnit.monthDayNano), [
          ArrowIntervalValue.monthDayNano(1, 2, BigInt.parse('-${'9' * 18}')),
          null,
        ]),
      ];
      for (final array in arrays) {
        final decoded = roundTrip(array);
        expect(decoded.type, array.type);
        expect(decoded.values, array.values);
      }
    });

    test('map entry order is preserved', () {
      final decoded = roundTrip(
        ArrowArray(map, [
          ArrowMapValue([
            ArrowMapEntry(const ArrowStringValue('b'), ArrowIntegerValue(1)),
            ArrowMapEntry(const ArrowStringValue('a'), ArrowIntegerValue(2)),
          ]),
        ]),
      );
      final entries = (decoded.values.single! as ArrowMapValue).entries;
      expect(entries.map((e) => (e.key as ArrowStringValue).value), ['b', 'a']);
    });

    test('rejects invalid values', () {
      expect(
        () => ArrowArray(ArrowFixedSizeBinaryType(2), [
          ArrowBinaryValue([1]),
        ]),
        throwsArgumentError,
      );
      expect(
        () => ArrowArray(ArrowDecimalType(9, 0, bitWidth: 32), [
          ArrowDecimalValue(BigInt.parse('9' * 10)),
        ]),
        throwsRangeError,
      );
      expect(
        () => ArrowArray(union, [ArrowUnionValue(0, ArrowIntegerValue(1))]),
        throwsArgumentError,
      );
      expect(() => ArrowArray(union, [null]), throwsArgumentError);
      expect(
        () => ArrowArray(const ArrowIntervalType(ArrowIntervalUnit.dayTime), [
          ArrowIntervalValue.yearMonth(1),
        ]),
        throwsArgumentError,
      );
      expect(() => ArrowIntervalValue.yearMonth(1 << 31), throwsRangeError);
    });

    test('codec rejects null map keys and undeclared union ids', () {
      const codec = OwnedBatchJsonCodec();
      final batch = RecordBatch(ArrowSchema([ArrowField('m', map)]), [
        ArrowArray(map, [
          ArrowMapValue([
            ArrowMapEntry(const ArrowStringValue('k'), ArrowIntegerValue(1)),
          ]),
        ]),
      ]);
      final json = codec.toJson(batch);
      final column = (json['columns']! as List).single as Map;
      ((column['values'] as List).single as List).single['key'] = null;
      expect(() => codec.fromJson(json), throwsFormatException);

      final ubatch = RecordBatch(ArrowSchema([ArrowField('u', union)]), [
        ArrowArray(union, [ArrowUnionValue(3, ArrowIntegerValue(1))]),
      ]);
      final ujson = codec.toJson(ubatch);
      final ucol = (ujson['columns']! as List).single as Map;
      (ucol['values'] as List).single['typeId'] = 4;
      expect(() => codec.fromJson(ujson), throwsFormatException);
    });
  });

  group('run-end encoding', () {
    final ree = ArrowRunEndEncodedType(
      ArrowField('run_ends', ArrowIntegerType(16), nullable: false),
      str,
    );

    test('expands and re-derives canonical runs', () {
      final array = ArrowArray.runEndEncoded(
        ree,
        [2, 3, 5],
        [const ArrowStringValue('a'), null, const ArrowStringValue('b')],
      );
      expect(array.length, 5);
      expect(array[1], const ArrowStringValue('a'));
      expect(array[2], isNull);
      expect(array.runEnds, [2, 3, 5]);
      expect(array.runValues, [
        const ArrowStringValue('a'),
        null,
        const ArrowStringValue('b'),
      ]);
      expect(roundTrip(array).values, array.values);
    });

    test('rejects bad run ends', () {
      final a = const ArrowStringValue('a');
      expect(
        () => ArrowArray.runEndEncoded(ree, [0], [a]),
        throwsArgumentError,
      );
      expect(
        () => ArrowArray.runEndEncoded(ree, [2, 2], [a, a]),
        throwsArgumentError,
      );
      expect(
        () => ArrowArray.runEndEncoded(ree, [40000], [a]),
        throwsRangeError,
      );
      expect(() => ArrowArray.runEndEncoded(ree, [1], []), throwsArgumentError);
      expect(
        () => ArrowArray(ArrowListType(str), []).runEnds,
        throwsStateError,
      );
    });
  });

  test('struct duplicate names are opt-in and accepted from JSON', () {
    final a = ArrowField('a', int32);
    expect(() => ArrowStructType([a, a]), throwsArgumentError);
    final dup = ArrowStructType([a, a], allowDuplicateNames: true);
    expect(ArrowDataType.fromJson(dup.toJson()), dup);
  });

  test('map entries metadata is preserved', () {
    final map = ArrowMapType(
      ArrowField('k', int32, nullable: false),
      ArrowField('v', int32),
      entriesMetadata: {'x': 'y'},
    );
    expect(map.entriesField.metadata, {'x': 'y'});
    expect(ArrowDataType.fromJson(map.toJson()), map);
    expect(
      ArrowMapType(
        ArrowField('k', int32, nullable: false),
        ArrowField('v', int32),
      ).toJson().containsKey('entriesMetadata'),
      isFalse,
    );
    expect(
      () => ArrowDataType.fromJson({
        ...map.toJson(),
        'entriesMetadata': {'x': 1},
      }),
      throwsFormatException,
    );
  });

  test('float64 bits are exact for negative values', () {
    expect(
      ArrowFloatingValue.float64(-0.0).hexadecimalBits,
      '8000000000000000',
    );
    expect(
      ArrowFloatingValue.float64(-1.5).hexadecimalBits,
      'bff8000000000000',
    );
  });
}
