import 'package:dartaframes_polars/arrow.dart';
import 'package:test/test.dart';

void main() {
  test('batch slicing preserves dictionary identity, nulls and metadata', () {
    final type = ArrowDictionaryType(
      ArrowIntegerType(8),
      const ArrowUtf8Type(),
    );
    final dictionary = ArrowArray(const ArrowUtf8Type(), const [
      ArrowStringValue('one'),
      ArrowStringValue('two'),
    ]);
    final batch = RecordBatch(
      ArrowSchema([ArrowField('x', type)], metadata: {'owner': 'test'}),
      [
        ArrowArray(type, [
          ArrowDictionaryIndexValue(0),
          null,
          ArrowDictionaryIndexValue(1),
        ], dictionary: dictionary),
      ],
    );
    final tail = batch.slice(1);
    expect(tail.rowCount, 2);
    expect(tail.schema, same(batch.schema));
    expect(tail.columns.single.dictionary, same(dictionary));
    expect(tail.columns.single.values, [null, ArrowDictionaryIndexValue(1)]);
    expect(batch.slice(3).rowCount, 0);
    expect(batch.slice(1, 0).columns.single.values, isEmpty);
    expect(() => batch.slice(-1), throwsRangeError);
    expect(() => batch.slice(4), throwsRangeError);
    expect(() => batch.slice(1, -1), throwsRangeError);
    expect(() => batch.slice(1, 3), throwsRangeError);
    expect(() => tail.columns.single.values.add(null), throwsUnsupportedError);
  });
  test('zero-column slices retain explicit row counts', () {
    final batch = RecordBatch(ArrowSchema([]), [], rowCount: 5);
    expect(batch.slice(2, 2).rowCount, 2);
    expect(batch.slice(5).rowCount, 0);
  });
}
