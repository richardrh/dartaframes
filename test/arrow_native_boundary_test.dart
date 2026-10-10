import 'package:dartaframes_polars/polars.dart';
import 'package:test/test.dart';

void main() {
  test('native bridge rejects standalone nested dictionary sidecars', () {
    final dictionary = ArrowArray(const ArrowUtf8Type(), [
      const ArrowStringValue('one'),
    ]);
    final type = ArrowListType(
      ArrowField(
        'item',
        ArrowDictionaryType(ArrowIntegerType(8), const ArrowUtf8Type()),
      ),
    );
    final array = ArrowArray(type, [], nestedDictionaries: [dictionary]);
    final batch = RecordBatch(ArrowSchema([ArrowField('value', type)]), [
      array,
    ]);
    expect(
      () => const RecordBatchCodec().encode(batch),
      throwsUnsupportedError,
    );
  });
  test('standalone Arrow types do not silently broaden native protocol', () {
    final additions = <ArrowDataType>[
      ArrowFixedSizeBinaryType(4),
      const ArrowUtf8Type(ArrowOffsetWidth.view),
      const ArrowBinaryType(ArrowOffsetWidth.view),
      ArrowListType(
        ArrowField('item', ArrowIntegerType(32)),
        offsetWidth: ArrowOffsetWidth.large,
      ),
      ArrowListType(ArrowField('item', ArrowIntegerType(32)), view: true),
      ArrowDecimalType(9, 2, bitWidth: 32),
      ArrowDecimalType(18, 2, bitWidth: 64),
      ArrowDecimalType(76, 2, bitWidth: 256),
      ArrowDecimalType(10, -2),
      ArrowDecimalType(3, 4),
      ArrowListType(ArrowField('item', ArrowFixedSizeBinaryType(4))),
      ArrowStructType([ArrowField('nested', ArrowFixedSizeBinaryType(4))]),
      ArrowExtensionType('example.fixed', ArrowFixedSizeBinaryType(4)),
    ];
    for (final type in additions) {
      final batch = RecordBatch(ArrowSchema([ArrowField('value', type)]), [
        ArrowArray(type, const []),
      ]);
      expect(
        () => const RecordBatchCodec().encode(batch),
        throwsUnsupportedError,
        reason: type.toString(),
      );
    }
  });

  test('native bridge rejects unnamed and duplicate standard columns', () {
    for (final names in [
      <String>[''],
      <String>['x', 'x'],
    ]) {
      final batch = RecordBatch(
        ArrowSchema([
          for (final name in names)
            ArrowField(name, const ArrowUtf8Type(), allowEmptyName: true),
        ], allowDuplicateNames: true),
        [for (final _ in names) ArrowArray(const ArrowUtf8Type(), [])],
      );
      expect(
        () => const RecordBatchCodec().encode(batch),
        throwsUnsupportedError,
      );
    }
  });

  test('legacy decimal copied-batch shape remains unchanged', () {
    final type = ArrowDecimalType(10, 2);
    final batch = RecordBatch(ArrowSchema([ArrowField('price', type)]), [
      ArrowArray(type, [ArrowDecimalValue(1234)]),
    ]);
    final encoded = const RecordBatchCodec().encode(batch);
    final column = (encoded['columns'] as List).single as Map;
    expect(column['dtype'], {'kind': 'decimal', 'precision': 10, 'scale': 2});
  });
}
