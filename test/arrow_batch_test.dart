import 'package:dartaframes_polars/dartaframes_polars.dart';
import 'package:test/test.dart';

void main() {
  test('scalar literals reuse exact Arrow value wrappers', () {
    final scalar = Scalar.fromArrow(
      const Int128Type(),
      ArrowIntegerValue('170141183460469231731687303715884105727'),
    );
    expect(scalar.toJson()['value'], '170141183460469231731687303715884105727');
    expect(
      Scalar.fromArrow(
        const Float64Type(),
        ArrowFloatingValue(64, BigInt.parse('7ff8000000000001', radix: 16)),
      ).toJson()['floatBits'],
      '7ff8000000000001',
    );
  });

  test('owned RecordBatch encodes for import and decodes native export', () {
    final batch = RecordBatch(
      ArrowSchema([ArrowField('a', ArrowIntegerType(64))]),
      [
        ArrowArray(ArrowIntegerType(64), [ArrowIntegerValue(7), null]),
      ],
    );
    const codec = RecordBatchCodec();
    final encoded = codec.encode(batch);
    expect(encoded['length'], 2);
    expect(((encoded['columns'] as List).single as Map)['values'], ['7', null]);

    final decoded = codec.decode({
      'columns': [
        {
          'name': 'a',
          'dtype': {'kind': 'int64'},
          'values': ['7', null],
        },
      ],
    });
    expect(
      (decoded.columns.single.values.first as ArrowIntegerValue).value,
      BigInt.from(7),
    );
    expect(decoded.columns.single.values.last, isNull);
  });

  test('unknown Arrow extensions degrade to storage at Polars boundary', () {
    final type = ArrowExtensionType('vendor.id', ArrowIntegerType(64));
    final batch = RecordBatch(ArrowSchema([ArrowField('id', type)]), [
      ArrowArray(type, [ArrowExtensionValue(ArrowIntegerValue(12))]),
    ]);
    final column =
        (const RecordBatchCodec().encode(batch)['columns'] as List).single
            as Map;
    expect(column['dtype'], {'kind': 'int64'});
    expect(column['values'], ['12']);
  });

  test('extension storage values receive temporal unit conversion', () {
    final storage = ArrowTimestampType(ArrowTimeUnit.second);
    final type = ArrowExtensionType('vendor.seconds', storage);
    final batch = RecordBatch(ArrowSchema([ArrowField('time', type)]), [
      ArrowArray(type, [ArrowExtensionValue(ArrowTemporalValue(-2))]),
    ]);
    final column =
        (const RecordBatchCodec().encode(batch)['columns'] as List).single
            as Map;
    expect(column['dtype'], {'kind': 'datetime', 'unit': 'milliseconds'});
    expect(column['values'], ['-2000']);
  });

  test('temporal copied columns convert units without semantic loss', () {
    final date64 = ArrowDateType(ArrowDateUnit.millisecond);
    final timeSeconds = ArrowTimeType(ArrowTimeUnit.second);
    final timestampSeconds = ArrowTimestampType(ArrowTimeUnit.second);
    final durationSeconds = ArrowDurationType(ArrowTimeUnit.second);
    final batch = RecordBatch(
      ArrowSchema([
        ArrowField('date64', date64),
        ArrowField('time', timeSeconds),
        ArrowField('timestamp', timestampSeconds),
        ArrowField('duration', durationSeconds),
      ]),
      [
        ArrowArray(date64, [ArrowTemporalValue(86400000)]),
        ArrowArray(timeSeconds, [ArrowTemporalValue(2)]),
        ArrowArray(timestampSeconds, [ArrowTemporalValue(-3)]),
        ArrowArray(durationSeconds, [ArrowTemporalValue(4)]),
      ],
    );
    final columns = const RecordBatchCodec().encode(batch)['columns'] as List;
    expect(columns[0]['dtype'], {'kind': 'datetime', 'unit': 'milliseconds'});
    expect(columns[0]['values'], ['86400000']);
    expect(columns[1]['dtype'], {'kind': 'time'});
    expect(columns[1]['values'], ['2000000000']);
    expect(columns[2]['dtype'], {'kind': 'datetime', 'unit': 'milliseconds'});
    expect(columns[2]['values'], ['-3000']);
    expect(columns[3]['values'], ['4000']);
  });

  test(
    'native Time exports decode as Arrow nanoseconds and overflow fails',
    () {
      final decoded = const RecordBatchCodec().decode({
        'columns': [
          {
            'name': 'time',
            'dtype': {'kind': 'time'},
            'values': [
              {'value': '42'},
            ],
          },
        ],
      });
      expect(
        decoded.schema.fields.single.type,
        ArrowTimeType(ArrowTimeUnit.nanosecond),
      );
      final seconds = ArrowTimestampType(ArrowTimeUnit.second);
      final overflowing = RecordBatch(
        ArrowSchema([ArrowField('time', seconds)]),
        [
          ArrowArray(seconds, [
            ArrowTemporalValue((BigInt.one << 63) - BigInt.one),
          ]),
        ],
      );
      expect(
        () => const RecordBatchCodec().encode(overflowing),
        throwsRangeError,
      );
    },
  );

  test('native date, naive datetime, and nested struct dtypes decode', () {
    final decoded = const RecordBatchCodec().decode({
      'length': 0,
      'columns': [
        {
          'name': 'date',
          'dtype': {'kind': 'date'},
          'values': const [],
        },
        {
          'name': 'when',
          'dtype': {
            'kind': 'datetime',
            'unit': 'microseconds',
            'timeZone': null,
          },
          'values': const [],
        },
        {
          'name': 'nested',
          'dtype': {
            'kind': 'struct',
            'fields': [
              {
                'name': 'dates',
                'dtype': {
                  'kind': 'list',
                  'inner': {'kind': 'date'},
                },
              },
            ],
          },
          'values': const [],
        },
      ],
    });
    expect(decoded.schema.fields[0].type, const ArrowDateType());
    expect(
      decoded.schema.fields[1].type,
      const ArrowTimestampType(ArrowTimeUnit.microsecond),
    );
    final struct = decoded.schema.fields[2].type as ArrowStructType;
    final list = struct.fields.single.type as ArrowListType;
    expect(list.field.type, const ArrowDateType());
  });

  test('zero-column batch length survives copied encoding and decoding', () {
    final batch = RecordBatch(ArrowSchema(const []), const [], rowCount: 7);
    const codec = RecordBatchCodec();
    expect(codec.encode(batch), {'length': 7, 'columns': const []});
    expect(codec.decode({'length': 7, 'columns': const []}).length, 7);
  });
}
