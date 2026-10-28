import 'package:dartaframes_polars/arrow.dart';
import 'package:test/test.dart';

void main() {
  test(
    'IPC public objects expose stable schema, bytes, limits and snapshots',
    () {
      final type = ArrowIntegerType(32);
      final schema = ArrowSchema([ArrowField('n', type)]);
      final batch = RecordBatch(schema, [
        ArrowArray(type, [ArrowIntegerValue(7)]),
      ]);
      final source = [batch];
      final table = ArrowTable(schema, source);
      final streamWriter = ArrowIpcStreamWriter(
        schema: schema,
        batches: source,
      );
      final fileWriter = ArrowIpcFileWriter(schema: schema, batches: source);
      source.clear();
      expect(table.schema, same(schema));
      expect(table.batches, [batch]);
      expect(table.rowCount, 1);
      expect(streamWriter.schema, same(schema));
      expect(fileWriter.schema, same(schema));
      expect(() => table.batches.clear(), throwsUnsupportedError);
      expect(() => streamWriter.batches.clear(), throwsUnsupportedError);
      expect(() => fileWriter.batches.clear(), throwsUnsupportedError);
      const limits = ArrowIpcLimits(maxRows: 1);
      final stream = streamWriter.write();
      final file = fileWriter.write();
      final streamReader = ArrowIpcStreamReader(stream, limits: limits);
      final fileReader = ArrowIpcFileReader(file, limits: limits);
      expect(streamReader.bytes, same(stream));
      expect(fileReader.bytes, same(file));
      expect(streamReader.limits, same(limits));
      expect(fileReader.limits, same(limits));
      expect(streamReader.readTable().rowCount, 1);
      expect(fileReader.readTable().rowCount, 1);
    },
  );

  test('every public IPC limit retains its configured value', () {
    const limits = ArrowIpcLimits(
      maxDepth: 1,
      maxFields: 2,
      maxRows: 3,
      maxValues: 4,
      maxBuffers: 5,
      maxMessageBytes: 6,
      maxDictionaries: 7,
      maxBatches: 8,
    );
    expect(
      [
        limits.maxDepth,
        limits.maxFields,
        limits.maxRows,
        limits.maxValues,
        limits.maxBuffers,
        limits.maxMessageBytes,
        limits.maxDictionaries,
        limits.maxBatches,
      ],
      [1, 2, 3, 4, 5, 6, 7, 8],
    );
  });

  test('maxBuffers rejects excess buffers in both public readers', () {
    final type = ArrowIntegerType(32);
    final schema = ArrowSchema([ArrowField('n', type)]);
    final batches = [
      RecordBatch(schema, [
        ArrowArray(type, [ArrowIntegerValue(7)]),
      ]),
    ];
    final stream = ArrowIpcStreamWriter(
      schema: schema,
      batches: batches,
    ).write();
    final file = ArrowIpcFileWriter(schema: schema, batches: batches).write();
    expect(
      () => ArrowIpcStreamReader(
        stream,
        limits: const ArrowIpcLimits(maxBuffers: 1),
      ).readTable(),
      throwsFormatException,
    );
    expect(
      () => ArrowIpcFileReader(
        file,
        limits: const ArrowIpcLimits(maxBuffers: 1),
      ).readTable(),
      throwsFormatException,
    );
    expect(
      ArrowIpcStreamReader(
        stream,
        limits: const ArrowIpcLimits(maxBuffers: 2),
      ).readTable().rowCount,
      1,
    );
    expect(
      ArrowIpcFileReader(
        file,
        limits: const ArrowIpcLimits(maxBuffers: 2),
      ).readTable().rowCount,
      1,
    );
  });

  test(
    'map and union public metadata and selectors preserve immutable inputs',
    () {
      final key = ArrowField('key', const ArrowUtf8Type(), nullable: false);
      final value = ArrowField('value', ArrowIntegerType(32));
      final metadata = {'source': 'producer'};
      final map = ArrowMapType(
        key,
        value,
        keysSorted: true,
        entriesName: 'pairs',
        entriesMetadata: metadata,
      );
      metadata.clear();
      expect(map.keyField, same(key));
      expect(map.valueField, same(value));
      expect(map.keysSorted, isTrue);
      expect(map.allowDuplicateNames, isFalse);
      expect(map.entriesName, 'pairs');
      expect(map.entriesField.name, 'pairs');
      expect(map.entriesField.nullable, isFalse);
      expect(map.entriesField.metadata, {'source': 'producer'});
      expect(() => map.entriesMetadata.clear(), throwsUnsupportedError);
      final fields = [key, value];
      final ids = [3, 9];
      final union = ArrowUnionType(
        fields,
        mode: ArrowUnionMode.dense,
        typeIds: ids,
      );
      fields.clear();
      ids.clear();
      expect(union.mode, ArrowUnionMode.dense);
      expect(union.typeIds, [3, 9]);
      expect(union.fieldForTypeId(3), same(key));
      expect(union.fieldForTypeId(9), same(value));
      expect(union.fieldForTypeId(8), isNull);
      expect(() => union.fields.clear(), throwsUnsupportedError);
      expect(() => union.typeIds.clear(), throwsUnsupportedError);
      for (final type in <ArrowDataType>[
        map,
        union,
        ArrowFixedSizeBinaryType(0),
        ArrowDecimalType(76, -2, bitWidth: 256),
        const ArrowIntervalType(ArrowIntervalUnit.monthDayNano),
      ]) {
        final copy = ArrowDataType.fromJson(type.toJson());
        expect(copy, type);
        expect(copy.hashCode, type.hashCode);
      }
    },
  );

  test('new value equality and hash outputs agree with exposed components', () {
    const entry = ArrowMapEntry(ArrowStringValue('k'), null);
    const sameEntry = ArrowMapEntry(ArrowStringValue('k'), null);
    final inputs = [entry];
    final map = ArrowMapValue(inputs);
    inputs.clear();
    expect(entry.key, const ArrowStringValue('k'));
    expect(entry.value, isNull);
    expect(map.entries, [entry]);
    expect(() => map.entries.clear(), throwsUnsupportedError);
    const union = ArrowUnionValue(9, null);
    expect(union.typeId, 9);
    expect(union.value, isNull);
    final yearMonth = ArrowIntervalValue.yearMonth(-2);
    final dayTime = ArrowIntervalValue.dayTime(3, -4);
    final nano = ArrowIntervalValue.monthDayNano(1, -2, -3);
    expect(
      [
        yearMonth.unit,
        yearMonth.months,
        yearMonth.days,
        yearMonth.milliseconds,
        yearMonth.nanoseconds,
      ],
      [ArrowIntervalUnit.yearMonth, -2, 0, 0, BigInt.zero],
    );
    expect(
      [
        dayTime.unit,
        dayTime.months,
        dayTime.days,
        dayTime.milliseconds,
        dayTime.nanoseconds,
      ],
      [ArrowIntervalUnit.dayTime, 0, 3, -4, BigInt.zero],
    );
    expect(
      [nano.unit, nano.months, nano.days, nano.milliseconds, nano.nanoseconds],
      [ArrowIntervalUnit.monthDayNano, 1, -2, 0, BigInt.from(-3)],
    );
    for (final (a, b) in <(Object, Object)>[
      (entry, sameEntry),
      (map, ArrowMapValue([sameEntry])),
      (union, const ArrowUnionValue(9, null)),
      (yearMonth, ArrowIntervalValue.yearMonth(-2)),
      (dayTime, ArrowIntervalValue.dayTime(3, -4)),
      (nano, ArrowIntervalValue.monthDayNano(1, -2, -3)),
    ]) {
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect({a, b}, hasLength(1));
    }
  });

  test(
    'nestedDictionaryTypes exposes preorder without mutable shared state',
    () {
      final first = ArrowDictionaryType(
        ArrowIntegerType(8),
        const ArrowUtf8Type(),
      );
      final second = ArrowDictionaryType(
        ArrowIntegerType(16),
        ArrowIntegerType(32),
      );
      final root = ArrowStructType([
        ArrowField('first', first),
        ArrowField('list', ArrowListType(ArrowField('second', second))),
      ]);
      final order = nestedDictionaryTypes(root);
      expect(order, [first, second]);
      order.clear();
      expect(nestedDictionaryTypes(root), [first, second]);
      expect(nestedDictionaryTypes(first), isEmpty);
    },
  );
}
