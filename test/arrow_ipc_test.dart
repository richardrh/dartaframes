import 'dart:typed_data';

import 'package:dartaframes_polars/arrow.dart';
import 'package:test/test.dart';

ArrowArray _col(ArrowDataType type, List<ArrowValue?> values) =>
    ArrowArray(type, values);

ArrowIntegerValue _i(int v) => ArrowIntegerValue(v);
ArrowTemporalValue _t(int v) => ArrowTemporalValue(v);

// Minimal metadata addressing for mutations of public-writer output.
int _slot(ByteData data, int table, int field) {
  final vt = table - data.getInt32(table, Endian.little);
  final entry = vt + 4 + field * 2;
  if (entry >= vt + data.getUint16(vt, Endian.little)) return 0;
  final offset = data.getUint16(entry, Endian.little);
  return offset == 0 ? 0 : table + offset;
}

int _ref(ByteData data, int at) => at + data.getUint32(at, Endian.little);

int _i64(ByteData data, int at) =>
    data.getInt32(at + 4, Endian.little) * 4294967296 +
    data.getUint32(at, Endian.little);

void _putI64(ByteData data, int at, int value) {
  final low = value % 4294967296;
  data.setUint32(at, low, Endian.little);
  data.setInt32(at + 4, (value - low) ~/ 4294967296, Endian.little);
}

List<({int start, int end, int header, int kind})> _messages(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final result = <({int start, int end, int header, int kind})>[];
  var start = 0;
  while (start < bytes.length - 8) {
    final length = data.getInt32(start + 4, Endian.little);
    if (length == 0) break;
    final message = _ref(data, start + 8);
    final bodySlot = _slot(data, message, 3);
    final bodyLength = bodySlot == 0 ? 0 : _i64(data, bodySlot);
    final end = start + 8 + length + bodyLength;
    result.add((
      start: start,
      end: end,
      header: _ref(data, _slot(data, message, 2)),
      kind: data.getUint8(_slot(data, message, 1)),
    ));
    start = end;
  }
  return result;
}

List<int> _schemaDictionaryIdSlots(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final result = <int>[];
  void fields(int vectorSlot) {
    if (vectorSlot == 0) return;
    final vector = _ref(data, vectorSlot);
    final length = data.getUint32(vector, Endian.little);
    for (var i = 0; i < length; i++) {
      final field = _ref(data, vector + 4 + i * 4);
      final dictionary = _slot(data, field, 4);
      if (dictionary != 0) {
        result.add(_slot(data, _ref(data, dictionary), 0));
      }
      fields(_slot(data, field, 5));
    }
  }

  fields(_slot(data, _messages(bytes).first.header, 1));
  return result;
}

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
    (
      'i64',
      ArrowIntegerType(64),
      [ArrowIntegerValue(-(BigInt.one << 62)), _i(0), null],
    ),
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
  group('Arrow IPC dictionary protocol', () {
    final dict = ArrowDictionaryType(
      ArrowIntegerType(8),
      const ArrowUtf8Type(),
    );
    ArrowArray words(String word) =>
        _col(const ArrowUtf8Type(), [ArrowStringValue(word)]);
    final ext = ArrowExtensionType('example.dictionary', dict, metadata: 'v1');

    test('append-only dictionaries emit deltas with bounded merged size', () {
      final schema = ArrowSchema([ArrowField('d', dict)]);
      RecordBatch batch(List<String> values) => RecordBatch(schema, [
        ArrowArray(
          dict,
          [ArrowDictionaryIndexValue(values.length - 1)],
          dictionary: _col(
            const ArrowUtf8Type(),
            values.map(ArrowStringValue.new).toList(),
          ),
        ),
      ]);
      final batches = [
        batch(['a']),
        batch(['a', 'b']),
      ];
      final bytes = ArrowIpcStreamWriter(
        schema: schema,
        batches: batches,
      ).write();
      final data = ByteData.sublistView(bytes);
      final dictionaryMessages = _messages(bytes)
          .where((m) => m.kind == 2)
          .toList();
      expect(dictionaryMessages.length, 2);
      expect(bytes[_slot(data, dictionaryMessages.last.header, 2)], 1);
      final table = ArrowIpcStreamReader(bytes).readTable();
      expect(table.batches.first.columns.single.dictionary!.length, 1);
      expect(table.batches.last.columns.single.dictionary!.length, 2);
      expect(
        () => ArrowIpcStreamReader(
          bytes,
          limits: const ArrowIpcLimits(maxRows: 1),
        ).readTable(),
        throwsFormatException,
      );
      final file = ArrowIpcFileWriter(schema: schema, batches: batches).write();
      expect(
        ArrowIpcFileReader(file)
            .readTable()
            .batches
            .last
            .columns
            .single
            .dictionary!
            .values,
        batches.last.columns.single.dictionary!.values,
      );
    });

    test('out-of-range dictionary indices are rejected by public reader', () {
      final schema = ArrowSchema([ArrowField('d', dict)]);
      final bytes = ArrowIpcStreamWriter(
        schema: schema,
        batches: [
          RecordBatch(schema, [
            ArrowArray(dict, [
              ArrowDictionaryIndexValue(0),
            ], dictionary: words('red')),
          ]),
        ],
      ).write();
      final data = ByteData.sublistView(bytes);
      final batch = _messages(bytes).last;
      final buffers = _ref(data, _slot(data, batch.header, 2));
      final indicesOffset = _i64(data, buffers + 4 + 16);
      final body =
          batch.start + 8 + data.getInt32(batch.start + 4, Endian.little);
      bytes[body + indicesOffset] = 127;
      expect(
        () => ArrowIpcStreamReader(bytes).readTable(),
        throwsFormatException,
      );
    });

    test('extension dictionary root and struct child preserve sidecars', () {
      final struct = ArrowStructType([ArrowField('child', ext)]);
      final dictionary = words('red');
      final index = ArrowExtensionValue(ArrowDictionaryIndexValue(0));
      final columns = [
        ArrowArray(ext, [index, null], dictionary: dictionary),
        ArrowArray(
          struct,
          [
            ArrowStructValue([ArrowStructEntry('child', index)]),
            null,
          ],
          nestedDictionaries: [dictionary],
        ),
      ];
      final schema = ArrowSchema([
        ArrowField('root', ext),
        ArrowField('nested', struct),
      ]);
      final batches = [RecordBatch(schema, columns)];
      for (final table in [
        ArrowIpcStreamReader(
          ArrowIpcStreamWriter(schema: schema, batches: batches).write(),
        ).readTable(),
        ArrowIpcFileReader(
          ArrowIpcFileWriter(schema: schema, batches: batches).write(),
        ).readTable(),
      ]) {
        expect(table.schema, schema);
        final actual = table.batches.single.columns;
        expect(actual[0].values, columns[0].values);
        expect(actual[1].values, columns[1].values);
        expect(actual[0].dictionary!.values, dictionary.values);
        expect(actual[1].nestedDictionaries.single.values, dictionary.values);
      }
    });

    test(
      'dictionary of list dictionary follows inner replacement snapshots',
      () {
        final list = ArrowListType(ArrowField('item', dict));
        final outer = ArrowDictionaryType(ArrowIntegerType(16), list);
        final schema = ArrowSchema([ArrowField('outer', outer)]);
        RecordBatch batch(String word) {
          final inner = words(word);
          final values = ArrowArray(
            list,
            [
              ArrowListValue([ArrowDictionaryIndexValue(0)]),
            ],
            nestedDictionaries: [inner],
          );
          return RecordBatch(schema, [
            ArrowArray(
              outer,
              [ArrowDictionaryIndexValue(0)],
              dictionary: values,
              nestedDictionaries: [inner],
            ),
          ]);
        }

        final input = [batch('old'), batch('new')];
        final bytes = ArrowIpcStreamWriter(
          schema: schema,
          batches: input,
        ).write();
        final table = ArrowIpcStreamReader(bytes).readTable();
        for (var i = 0; i < 2; i++) {
          final column = table.batches[i].columns.single;
          expect(
            column.dictionary!.nestedDictionaries.single.values,
            input[i].columns.single.nestedDictionaries.single.values,
          );
          expect(
            column.nestedDictionaries.single.values,
            input[i].columns.single.nestedDictionaries.single.values,
          );
        }
        final file = ArrowIpcFileWriter(
          schema: schema,
          batches: [input.first],
        ).write();
        expect(
          ArrowIpcFileReader(file)
              .readTable()
              .batches
              .single
              .columns
              .single
              .dictionary!
              .nestedDictionaries
              .single
              .values,
          words('old').values,
        );
      },
    );

    Uint8List twoFields({bool incompatible = false}) {
      final second = incompatible
          ? ArrowDictionaryType(ArrowIntegerType(16), ArrowIntegerType(32))
          : ArrowDictionaryType(ArrowIntegerType(16), const ArrowUtf8Type());
      final schema = ArrowSchema([
        ArrowField('a', dict),
        ArrowField('b', second),
      ]);
      return ArrowIpcStreamWriter(
        schema: schema,
        batches: [
          RecordBatch(schema, [
            ArrowArray(dict, [
              ArrowDictionaryIndexValue(0),
            ], dictionary: words('red')),
            ArrowArray(
              second,
              [ArrowDictionaryIndexValue(0)],
              dictionary: incompatible
                  ? _col(ArrowIntegerType(32), [_i(9)])
                  : words('red'),
            ),
          ]),
        ],
      ).write();
    }

    test('compatible fields share a negative dictionary wire id', () {
      final bytes = twoFields();
      final data = ByteData.sublistView(bytes);
      for (final at in _schemaDictionaryIdSlots(bytes)) {
        _putI64(data, at, -7);
      }
      final messages = _messages(bytes);
      final dictionaries = messages.where((m) => m.kind == 2).toList();
      _putI64(data, _slot(data, dictionaries.first.header, 0), -7);
      final dropped = dictionaries.last;
      final shared = Uint8List.fromList([
        ...bytes.sublist(0, dropped.start),
        ...bytes.sublist(dropped.end),
      ]);
      final columns = ArrowIpcStreamReader(shared)
          .readTable()
          .batches
          .single
          .columns;
      expect(columns[0].dictionary!.values, words('red').values);
      expect(columns[1].dictionary!.values, words('red').values);
    });

    test('incompatible shared dictionary types rejected', () {
      final bytes = twoFields(incompatible: true);
      final data = ByteData.sublistView(bytes);
      for (final at in _schemaDictionaryIdSlots(bytes)) {
        _putI64(data, at, -1);
      }
      expect(
        () => ArrowIpcStreamReader(bytes).readTable(),
        throwsFormatException,
      );
    });

    test('unknown ids, missing dictionaries and base-less deltas rejected', () {
      final original = twoFields();
      final dictionaries = _messages(original)
          .where((m) => m.kind == 2)
          .toList();
      final first = dictionaries.first;
      final unknown = Uint8List.fromList(original);
      final data = ByteData.sublistView(unknown);
      _putI64(data, _slot(data, first.header, 0), 999);
      expect(
        () => ArrowIpcStreamReader(unknown).readTable(),
        throwsFormatException,
      );
      final delta = Uint8List.fromList(original);
      delta[_slot(ByteData.sublistView(delta), first.header, 2)] = 1;
      expect(
        () => ArrowIpcStreamReader(delta).readTable(),
        throwsFormatException,
      );
      final missing = Uint8List.fromList([
        ...original.sublist(0, first.start),
        ...original.sublist(first.end),
      ]);
      expect(
        () => ArrowIpcStreamReader(missing).readTable(),
        throwsFormatException,
      );
    });

    test('dictionary count, value and body limits are enforced', () {
      final bytes = twoFields();
      for (final limits in [
        const ArrowIpcLimits(maxDictionaries: 1),
        const ArrowIpcLimits(maxValues: 1),
        const ArrowIpcLimits(maxMessageBytes: 1),
      ]) {
        expect(
          () => ArrowIpcStreamReader(bytes, limits: limits).readTable(),
          throwsFormatException,
        );
      }
      final schema = ArrowSchema([ArrowField('large', const ArrowUtf8Type())]);
      final batches = [
        RecordBatch(schema, [
          _col(const ArrowUtf8Type(), [ArrowStringValue('x' * 4096)]),
        ]),
      ];
      final large = ArrowIpcStreamWriter(
        schema: schema,
        batches: batches,
      ).write();
      expect(
        () => ArrowIpcStreamReader(
          large,
          limits: const ArrowIpcLimits(maxMessageBytes: 1024),
        ).readTable(),
        throwsFormatException,
      );
      final file = ArrowIpcFileWriter(schema: schema, batches: batches).write();
      expect(
        () => ArrowIpcFileReader(
          file,
          limits: const ArrowIpcLimits(maxMessageBytes: 1024),
        ).readTable(),
        throwsFormatException,
      );
    });
  });
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

    test('nested dictionaries roundtrip through file and stream', () {
      final dict = ArrowDictionaryType(
        ArrowIntegerType(8),
        const ArrowUtf8Type(),
      );
      final type = ArrowListType(ArrowField('item', dict));
      final schema = ArrowSchema([ArrowField('x', type)]);
      final dictionary = _col(const ArrowUtf8Type(), [
        const ArrowStringValue('red'),
        const ArrowStringValue('blue'),
      ]);
      final column = ArrowArray(
        type,
        [
          ArrowListValue([
            ArrowDictionaryIndexValue(1),
            null,
            ArrowDictionaryIndexValue(0),
          ]),
          null,
          ArrowListValue([]),
        ],
        nestedDictionaries: [dictionary],
      );
      final batches = [
        RecordBatch(schema, [column]),
      ];
      for (final table in [
        ArrowIpcStreamReader(
          ArrowIpcStreamWriter(schema: schema, batches: batches).write(),
        ).readTable(),
        ArrowIpcFileReader(
          ArrowIpcFileWriter(schema: schema, batches: batches).write(),
        ).readTable(),
      ]) {
        expect(table.schema, schema);
        expect(table.batches.single.columns.single.values, column.values);
        expect(
          table.batches.single.columns.single.nestedDictionaries.single.values,
          dictionary.values,
        );
      }
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
      for (var n = 0; n < file.length; n++) {
        final cut = Uint8List.sublistView(file, 0, n);
        expect(
          () => ArrowIpcFileReader(cut).readTable(),
          rejected,
          reason: 'length $n',
        );
      }
    });

    test('file block lengths and footer boundaries cannot be forged', () {
      final data = ByteData.sublistView(file);
      final footerStart =
          file.length - 10 - data.getInt32(file.length - 10, Endian.little);
      final footer = _ref(data, footerStart);
      final vector = _ref(data, _slot(data, footer, 3));
      final block = vector + 4;
      for (final delta in [-8, 8]) {
        final copy = Uint8List.fromList(file);
        final mutable = ByteData.sublistView(copy);
        mutable.setInt32(
          block + 8,
          data.getInt32(block + 8, Endian.little) + delta,
          Endian.little,
        );
        expect(
          () => ArrowIpcFileReader(copy).readTable(),
          throwsFormatException,
        );
      }
      final outside = Uint8List.fromList(file);
      _putI64(ByteData.sublistView(outside), block, footerStart);
      expect(
        () => ArrowIpcFileReader(outside).readTable(),
        throwsFormatException,
      );
      final wrongKind = Uint8List.fromList(file);
      final dictionaryVector = _ref(data, _slot(data, footer, 2));
      wrongKind.setRange(block, block + 24, file, dictionaryVector + 4);
      expect(
        () => ArrowIpcFileReader(wrongKind).readTable(),
        throwsFormatException,
      );
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
            limits: const ArrowIpcLimits(maxRows: 1099511627776),
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
