import 'package:dartaframes_polars/arrow.dart';
import 'package:test/test.dart';

final indexType = ArrowIntegerType(8);
final dictionaryType = ArrowDictionaryType(indexType, const ArrowUtf8Type());
ArrowArray words([String word = 'a']) =>
    ArrowArray(const ArrowUtf8Type(), [ArrowStringValue(word)]);
ArrowDictionaryIndexValue index([int i = 0]) => ArrowDictionaryIndexValue(i);
RecordBatch batch(ArrowArray a) =>
    RecordBatch(ArrowSchema([ArrowField('c', a.type)]), [a]);
ArrowArray roundTrip(ArrowArray a) {
  const codec = OwnedBatchJsonCodec();
  return codec.decode(codec.encode(batch(a))).columns.single;
}

void main() {
  test('nested lists require exact typed sidecars and range check indices', () {
    final type = ArrowListType(ArrowField('item', dictionaryType));
    final values = [
      ArrowListValue([index(), null]),
    ];
    expect(() => ArrowArray(type, values), throwsArgumentError);
    expect(
      () => ArrowArray(type, values, nestedDictionaries: [words(), words()]),
      throwsArgumentError,
    );
    expect(
      () => ArrowArray(
        type,
        values,
        nestedDictionaries: [ArrowArray(indexType, [])],
      ),
      throwsArgumentError,
    );
    for (final bad in [-1, 1]) {
      expect(
        () => ArrowArray(
          type,
          [
            ArrowListValue([index(bad)]),
          ],
          nestedDictionaries: [words()],
        ),
        throwsRangeError,
      );
    }
    final a = ArrowArray(type, values, nestedDictionaries: [words()]);
    expect(roundTrip(a).values, a.values);
    expect(roundTrip(a).nestedDictionaries.single.values, words().values);
    expect(
      batch(a).slice(0, 1).columns.single.nestedDictionaries.single,
      same(a.nestedDictionaries.single),
    );
    expect(
      batch(a).slice(1, 0).columns.single.nestedDictionaries.single,
      same(a.nestedDictionaries.single),
    );
    expect(() => a.nestedDictionaries.add(words()), throwsUnsupportedError);
    expect(
      () =>
          ArrowArray(const ArrowUtf8Type(), [], nestedDictionaries: [words()]),
      throwsArgumentError,
    );
  });

  test('preorder offsets include dictionary descendants before siblings', () {
    final list = ArrowListType(ArrowField('item', dictionaryType));
    final outer = ArrowDictionaryType(indexType, list);
    final dictionary = ArrowArray(
      list,
      [
        ArrowListValue([index()]),
      ],
      nestedDictionaries: [words()],
    );
    final type = ArrowStructType([
      ArrowField('a', outer),
      ArrowField('b', dictionaryType),
    ]);
    final value = ArrowStructValue([
      ArrowStructEntry('a', index()),
      ArrowStructEntry('b', index(1)),
    ]);
    final tail = ArrowArray(const ArrowUtf8Type(), [
      const ArrowStringValue('x'),
      const ArrowStringValue('y'),
    ]);
    final a = ArrowArray(
      type,
      [value],
      nestedDictionaries: [dictionary, words(), tail],
    );
    expect(roundTrip(a).values, a.values);
    expect(
      () => ArrowArray(
        type,
        [value],
        nestedDictionaries: [dictionary, words('wrong'), tail],
      ),
      throwsArgumentError,
    );
    expect(
      () => ArrowArray(
        type,
        [value],
        nestedDictionaries: [dictionary, words(), words()],
      ),
      throwsRangeError,
    );
  });

  test(
    'dictionary of dictionary and extension dictionary preserve sidecars',
    () {
      final leaf = words();
      final inner = ArrowArray(dictionaryType, [index()], dictionary: leaf);
      final outer = ArrowDictionaryType(indexType, dictionaryType);
      final a = ArrowArray(
        outer,
        [index()],
        dictionary: inner,
        nestedDictionaries: [leaf],
      );
      expect(roundTrip(a).dictionary!.dictionary!.values, leaf.values);
      final ext = ArrowExtensionType('custom', dictionaryType);
      final e = ArrowArray(ext, [
        ArrowExtensionValue(index()),
      ], dictionary: leaf);
      expect(roundTrip(e).values, e.values);
      expect(
        () =>
            ArrowArray(ext, [ArrowExtensionValue(index(1))], dictionary: leaf),
        throwsRangeError,
      );
      expect(
        () => ArrowArray(ext, [], dictionary: ArrowArray(indexType, [])),
        throwsArgumentError,
      );
      expect(() => ArrowArray(ext, []), throwsArgumentError);
    },
  );

  test(
    'map union fixed list REE and extension traverse dictionary indices',
    () {
      final cases = <(ArrowDataType, ArrowValue Function(int))>[
        (
          ArrowFixedSizeListType(ArrowField('v', dictionaryType), 1),
          (i) => ArrowListValue([index(i)]),
        ),
        (
          ArrowMapType(
            ArrowField('k', dictionaryType, nullable: false),
            ArrowField('v', const ArrowUtf8Type()),
          ),
          (i) => ArrowMapValue([
            ArrowMapEntry(index(i), const ArrowStringValue('v')),
          ]),
        ),
        (
          ArrowUnionType(
            [
              ArrowField('x', const ArrowUtf8Type()),
              ArrowField('v', dictionaryType),
            ],
            typeIds: [2, 7],
          ),
          (i) => ArrowUnionValue(7, index(i)),
        ),
        (
          ArrowRunEndEncodedType(
            ArrowField('r', ArrowIntegerType(16), nullable: false),
            ArrowField('v', dictionaryType),
          ),
          (i) => index(i),
        ),
        (
          ArrowExtensionType(
            'list',
            ArrowListType(ArrowField('v', dictionaryType)),
          ),
          (i) => ArrowExtensionValue(ArrowListValue([index(i)])),
        ),
      ];
      for (final (type, value) in cases) {
        final a = ArrowArray(type, [value(0)], nestedDictionaries: [words()]);
        expect(roundTrip(a).values, a.values);
        expect(
          () => ArrowArray(type, [value(1)], nestedDictionaries: [words()]),
          throwsRangeError,
        );
      }
    },
  );

  test('malformed JSON sidecars fail as format errors', () {
    const codec = OwnedBatchJsonCodec();
    final a = ArrowArray(
      ArrowListType(ArrowField('v', dictionaryType)),
      [
        ArrowListValue([index()]),
      ],
      nestedDictionaries: [words()],
    );
    for (final bad in [
      null,
      {},
      [null],
      [],
      [codec.toJson(batch(words()))],
    ]) {
      final json = codec.toJson(batch(a));
      ((json['columns'] as List).single as Map)['nestedDictionaries'] = bad;
      expect(() => codec.fromJson(json), throwsFormatException);
    }
  });

  test('run-end bounds, full preflight, and values nullability', () {
    final ree = ArrowRunEndEncodedType(
      ArrowField('r', ArrowIntegerType(16), nullable: false),
      ArrowField('v', const ArrowUtf8Type(), nullable: false),
    );
    expect(
      () => ArrowArray(ree, List.filled(32768, const ArrowStringValue('a'))),
      throwsRangeError,
    );
    expect(
      () =>
          ArrowArray.runEndEncoded(ree, [32768], [const ArrowStringValue('a')]),
      throwsRangeError,
    );
    expect(() => ArrowArray(ree, [null]), throwsArgumentError);
    expect(
      () => ArrowArray(ArrowExtensionType('ree', ree), [null]),
      throwsArgumentError,
    );
    expect(
      () => ArrowArray.runEndEncoded(ree, [1], [null]),
      throwsArgumentError,
    );
    expect(
      () =>
          expandRunEnds(ree, [2], [const ArrowStringValue('a')], maxLength: 1),
      throwsRangeError,
    );
    expect(
      () => expandRunEnds(
        ree,
        [1, 1],
        [const ArrowStringValue('a'), const ArrowStringValue('a')],
      ),
      throwsArgumentError,
    );
    expect(() => expandRunEnds(ree, [1], []), throwsArgumentError);
    expect(
      ArrowArray.runEndEncoded(
        ree,
        [32767],
        [const ArrowStringValue('a')],
      ).length,
      32767,
    );
  });

  test('duplicate map child names require opt in and survive JSON', () {
    final key = ArrowField('same', const ArrowUtf8Type(), nullable: false);
    final value = ArrowField('same', const ArrowUtf8Type());
    expect(() => ArrowMapType(key, value), throwsArgumentError);
    final map = ArrowMapType(key, value, allowDuplicateNames: true);
    expect(map.entriesField.type, isA<ArrowStructType>());
    expect(
      (ArrowDataType.fromJson(map.toJson()) as ArrowMapType).entriesField.type,
      map.entriesField.type,
    );
  });
}
