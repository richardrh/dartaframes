import 'dart:typed_data';

import 'package:dartaframes_polars/arrow.dart';
import 'package:test/test.dart';

ArrowArray _col(ArrowDataType type, List<ArrowValue?> values) =>
    ArrowArray(type, values);

ArrowIntegerValue _i(int v) => ArrowIntegerValue(v);
ArrowTemporalValue _t(int v) => ArrowTemporalValue(v);

(ArrowSchema, List<RecordBatch>) _sample() {
  final listType = ArrowListType(ArrowField('item', ArrowIntegerType(32)));
  final largeList = ArrowListType(
    ArrowField('item', const ArrowUtf8Type()),
    offsetWidth: ArrowOffsetWidth.large,
  );
  final fixedList = ArrowFixedSizeListType(
    ArrowField('item', ArrowFloatingType(64)),
    2,
  );
  final struct = ArrowStructType([
    ArrowField('a', ArrowIntegerType(16, signed: false)),
    ArrowField('b', const ArrowBooleanType()),
  ]);
  final dict = ArrowDictionaryType(ArrowIntegerType(8), const ArrowUtf8Type());
  final ext = ArrowExtensionType(
    'my.uuid',
    const ArrowBinaryType(),
    metadata: 'v1',
  );
  final columns = <(String, ArrowDataType, List<ArrowValue?>)>[
    ('i8', ArrowIntegerType(8), [_i(-128), null, _i(127)]),
    ('i64', ArrowIntegerType(64), [_i(-(1 << 62)), _i(0), null]),
    (
      'u64',
      ArrowIntegerType(64, signed: false),
      [ArrowIntegerValue(BigInt.parse('18446744073709551615')), null, _i(1)],
    ),
    (
      'f32',
      ArrowFloatingType(32),
      [
        ArrowFloatingValue.float32(1.5),
        ArrowFloatingValue(32, 0x7fc00001),
        null,
      ],
    ),
    (
      'f16',
      ArrowFloatingType(16),
      [ArrowFloatingValue.float16(0x3c00), null, null],
    ),
    (
      'dec',
      ArrowDecimalType(38, 2),
      [
        ArrowDecimalValue(BigInt.parse('-12345678901234567890123')),
        null,
        ArrowDecimalValue(1),
      ],
    ),
    (
      'bool',
      const ArrowBooleanType(),
      [const ArrowBooleanValue(true), null, const ArrowBooleanValue(false)],
    ),
    ('null', const ArrowNullType(), [null, null, null]),
    (
      's',
      const ArrowUtf8Type(),
      [const ArrowStringValue('héllo'), null, const ArrowStringValue('')],
    ),
    (
      'ls',
      const ArrowUtf8Type(ArrowOffsetWidth.large),
      [const ArrowStringValue('x'), null, null],
    ),
    (
      'bin',
      const ArrowBinaryType(),
      [
        ArrowBinaryValue([0, 255]),
        null,
        ArrowBinaryValue([]),
      ],
    ),
    ('d32', const ArrowDateType(), [_t(-1), _t(19000), null]),
    (
      'd64',
      const ArrowDateType(ArrowDateUnit.millisecond),
      [_t(1), null, null],
    ),
    (
      't32',
      const ArrowTimeType(ArrowTimeUnit.millisecond),
      [_t(1000), null, null],
    ),
    (
      't64',
      const ArrowTimeType(ArrowTimeUnit.nanosecond),
      [_t(86399999999999), null, null],
    ),
    (
      'ts',
      const ArrowTimestampType(ArrowTimeUnit.microsecond, timeZone: 'UTC'),
      [_t(-5), null, _t(5)],
    ),
    (
      'dur',
      const ArrowDurationType(ArrowTimeUnit.second),
      [_t(42), null, null],
    ),
    (
      'list',
      listType,
      [
        ArrowListValue([_i(1), null]),
        null,
        ArrowListValue([]),
      ],
    ),
    (
      'llist',
      largeList,
      [
        ArrowListValue([const ArrowStringValue('a')]),
        null,
        null,
      ],
    ),
    (
      'fl',
      fixedList,
      [
        ArrowListValue([
          ArrowFloatingValue.float64(1),
          ArrowFloatingValue.float64(-0.0),
        ]),
        null,
        null,
      ],
    ),
    (
      'st',
      struct,
      [
        ArrowStructValue([
          ArrowStructEntry('a', _i(65535)),
          const ArrowStructEntry('b', null),
        ]),
        null,
        ArrowStructValue([
          const ArrowStructEntry('a', null),
          const ArrowStructEntry('b', ArrowBooleanValue(true)),
        ]),
      ],
    ),
    (
      'ext',
      ext,
      [
        ArrowExtensionValue(ArrowBinaryValue([1, 2, 3])),
        null,
        null,
      ],
    ),
  ];
  final dictionary = _col(const ArrowUtf8Type(), [
    const ArrowStringValue('red'),
    const ArrowStringValue('blue'),
  ]);
  final schema = ArrowSchema(
    [
      for (final (name, type, _) in columns) ArrowField(name, type),
      ArrowField('dict', dict),
    ],
    metadata: {'origin': 'test'},
  );
  final batch = RecordBatch(schema, [
    for (final (_, type, values) in columns) _col(type, values),
    ArrowArray(dict, [
      ArrowDictionaryIndexValue(1),
      null,
      ArrowDictionaryIndexValue(0),
    ], dictionary: dictionary),
  ]);
  return (schema, [batch, batch]);
}

void _expectSameTable(
  ArrowTable table,
  ArrowSchema schema,
  List<RecordBatch> batches,
) {
  expect(table.schema, schema);
  expect(table.batches, hasLength(batches.length));
  expect(table.rowCount, batches.fold(0, (s, b) => s + b.rowCount));
  for (var b = 0; b < batches.length; b++) {
    for (var c = 0; c < schema.fields.length; c++) {
      final actual = table.batches[b].columns[c];
      final expected = batches[b].columns[c];
      expect(actual.values, expected.values, reason: schema.fields[c].name);
      expect(actual.dictionary?.values, expected.dictionary?.values);
    }
  }
}

int _indexOf(Uint8List haystack, Uint8List needle) {
  outer:
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

void main() {
  group('Arrow IPC round trip', () {
    test('stream preserves all core types', () {
      final (schema, batches) = _sample();
      final bytes = ArrowIpcStreamWriter(
        schema: schema,
        batches: batches,
      ).write();
      expect(bytes.length % 8, 0);
      _expectSameTable(
        ArrowIpcStreamReader(bytes).readTable(),
        schema,
        batches,
      );
    });

    test('file preserves all core types and carries ARROW1 magic', () {
      final (schema, batches) = _sample();
      final bytes = ArrowIpcFileWriter(
        schema: schema,
        batches: batches,
      ).write();
      expect(String.fromCharCodes(bytes.sublist(0, 6)), 'ARROW1');
      expect(String.fromCharCodes(bytes.sublist(bytes.length - 6)), 'ARROW1');
      _expectSameTable(ArrowIpcFileReader(bytes).readTable(), schema, batches);
    });

    test('empty table and zero-row batch', () {
      final schema = ArrowSchema([ArrowField('s', const ArrowUtf8Type())]);
      final empty = ArrowIpcStreamWriter(
        schema: schema,
        batches: const [],
      ).write();
      final table = ArrowIpcStreamReader(empty).readTable();
      expect(table.schema, schema);
      expect(table.rowCount, 0);
      final zero = RecordBatch(schema, [_col(const ArrowUtf8Type(), const [])]);
      final file = ArrowIpcFileWriter(schema: schema, batches: [zero]).write();
      expect(ArrowIpcFileReader(file).readTable().batches.single.rowCount, 0);
    });

    test('stream emits dictionary replacement between batches', () {
      final type = ArrowDictionaryType(
        ArrowIntegerType(32),
        const ArrowUtf8Type(),
      );
      final schema = ArrowSchema([ArrowField('d', type)]);
      RecordBatch batch(String word) => RecordBatch(schema, [
        ArrowArray(type, [
          ArrowDictionaryIndexValue(0),
        ], dictionary: _col(const ArrowUtf8Type(), [ArrowStringValue(word)])),
      ]);
      final batches = [batch('a'), batch('b')];
      final bytes = ArrowIpcStreamWriter(
        schema: schema,
        batches: batches,
      ).write();
      final table = ArrowIpcStreamReader(bytes).readTable();
      expect(
        table.batches[1].columns.single.dictionary!.values.single,
        const ArrowStringValue('b'),
      );
      expect(
        () => ArrowIpcFileWriter(schema: schema, batches: batches).write(),
        throwsUnsupportedError,
      );
    });
  });

  group('Arrow IPC rejects', () {
    test('nonstandard 128-bit integers', () {
      for (final signed in [true, false]) {
        final type = ArrowIntegerType(128, signed: signed);
        final schema = ArrowSchema([ArrowField('x', type)]);
        final batch = RecordBatch(schema, [
          _col(type, [_i(1)]),
        ]);
        expect(
          () => ArrowIpcStreamWriter(schema: schema, batches: [batch]).write(),
          throwsUnsupportedError,
        );
      }
    });

    test('nested dictionaries on write', () {
      final dict = ArrowDictionaryType(
        ArrowIntegerType(8),
        const ArrowUtf8Type(),
      );
      final type = ArrowListType(ArrowField('item', dict));
      final schema = ArrowSchema([ArrowField('x', type)]);
      expect(
        () => ArrowIpcStreamWriter(schema: schema, batches: const []).write(),
        throwsUnsupportedError,
      );
    });

    test('ArrowTable with mismatched batch schema', () {
      final (schema, batches) = _sample();
      final other = ArrowSchema([ArrowField('z', const ArrowNullType())]);
      expect(() => ArrowTable(other, batches), throwsArgumentError);
      expect(
        () => ArrowTable(schema, batches).batches.clear(),
        throwsUnsupportedError,
      );
    });
  });

  group('Arrow IPC malformed input', () {
    late Uint8List stream;
    late Uint8List file;
    setUp(() {
      final (schema, batches) = _sample();
      stream = ArrowIpcStreamWriter(schema: schema, batches: batches).write();
      file = ArrowIpcFileWriter(schema: schema, batches: batches).write();
    });

    final rejected = anyOf(throwsFormatException, throwsUnsupportedError);

    test('empty and garbage input', () {
      expect(
        () => ArrowIpcStreamReader(Uint8List(0)).readTable(),
        throwsFormatException,
      );
      expect(
        () => ArrowIpcFileReader(Uint8List(3)).readTable(),
        throwsFormatException,
      );
      expect(
        () => ArrowIpcStreamReader(
          Uint8List.fromList([255, 255, 255, 255, 255, 255, 255, 127]),
        ).readTable(),
        throwsFormatException,
      );
    });

    test('every truncation of a stream fails cleanly', () {
      for (var n = 1; n < stream.length - 8; n += 7) {
        final cut = Uint8List.sublistView(stream, 0, n);
        expect(
          () => ArrowIpcStreamReader(cut).readTable(),
          rejected,
          reason: 'length $n',
        );
      }
    });

    test('every truncation of a file fails cleanly', () {
      for (var n = 0; n < file.length; n += 11) {
        final cut = Uint8List.sublistView(file, 0, n);
        expect(
          () => ArrowIpcFileReader(cut).readTable(),
          rejected,
          reason: 'length $n',
        );
      }
    });

    test('byte corruption never escapes as an uncaught crash', () {
      for (var i = 0; i < stream.length; i += 3) {
        final copy = Uint8List.fromList(stream);
        copy[i] ^= 0xa5;
        try {
          ArrowIpcStreamReader(copy).readTable();
        } on FormatException {
          // expected
        } on UnsupportedError {
          // expected
        }
      }
    });

    test(
      'Null batch claiming a billion rows is rejected without allocating',
      () {
        final schema = ArrowSchema([ArrowField('n', const ArrowNullType())]);
        final batch = RecordBatch(schema, [
          _col(const ArrowNullType(), [null]),
        ]);
        final bytes = ArrowIpcStreamWriter(
          schema: schema,
          batches: [batch],
        ).write();
        // FieldNode struct {length: 1, null_count: 1}, patched to 2^30 rows.
        final node = Uint8List(16)
          ..[0] = 1
          ..[8] = 1;
        final at = _indexOf(bytes, node);
        expect(at, greaterThan(0));
        final evil = Uint8List.fromList(bytes);
        ByteData.sublistView(evil)
          ..setUint32(at, 1 << 30, Endian.little)
          ..setUint32(at + 8, 1 << 30, Endian.little);
        expect(
          () => ArrowIpcStreamReader(evil).readTable(),
          throwsFormatException,
        );
        expect(
          () => ArrowIpcStreamReader(
            evil,
            limits: const ArrowIpcLimits(maxRows: 1 << 40),
          ).readTable(),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('maxValues'),
            ),
          ),
        );
      },
    );

    test('limits bound depth and batches', () {
      expect(
        () => ArrowIpcStreamReader(
          stream,
          limits: const ArrowIpcLimits(maxBatches: 1),
        ).readTable(),
        throwsFormatException,
      );
      expect(
        () => ArrowIpcStreamReader(
          stream,
          limits: const ArrowIpcLimits(maxDepth: 1),
        ).readTable(),
        throwsFormatException,
      );
      expect(
        () => ArrowIpcStreamReader(
          stream,
          limits: const ArrowIpcLimits(maxRows: 2),
        ).readTable(),
        throwsFormatException,
      );
    });
  });
}
