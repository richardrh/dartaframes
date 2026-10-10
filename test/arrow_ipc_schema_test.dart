import 'package:dartaframes_polars/arrow.dart';
import 'package:test/test.dart';

void main() {
  test('IPC rejects wrapper compositions it cannot preserve', () {
    for (final type in <ArrowDataType>[
      ArrowExtensionType(
        'outer',
        ArrowExtensionType('inner', const ArrowUtf8Type()),
      ),
      ArrowDictionaryType(
        ArrowIntegerType(8),
        ArrowExtensionType('inner', const ArrowUtf8Type()),
      ),
    ]) {
      final schema = ArrowSchema([ArrowField('value', type)]);
      expect(
        () => ArrowIpcStreamWriter(schema: schema, batches: []).write(),
        throwsUnsupportedError,
      );
      expect(
        () => ArrowIpcFileWriter(schema: schema, batches: []).write(),
        throwsUnsupportedError,
      );
    }
  });
  test('reserved extension metadata cannot change the declared field type', () {
    for (final key in ['ARROW:extension:name', 'ARROW:extension:metadata']) {
      final schema = ArrowSchema([
        ArrowField('value', const ArrowUtf8Type(), metadata: {key: 'spoof'}),
      ]);
      expect(
        () => ArrowIpcStreamWriter(schema: schema, batches: []).write(),
        throwsArgumentError,
      );
      expect(
        () => ArrowIpcFileWriter(schema: schema, batches: []).write(),
        throwsArgumentError,
      );
    }
  });
  final child = ArrowField('item', ArrowIntegerType(32));
  final types = <ArrowDataType>[
    const ArrowNullType(),
    const ArrowBooleanType(),
    for (final width in [8, 16, 32, 64]) ...[
      ArrowIntegerType(width),
      ArrowIntegerType(width, signed: false),
    ],
    for (final width in [16, 32, 64]) ArrowFloatingType(width),
    for (final width in [32, 64, 128, 256])
      ArrowDecimalType(3, -2, bitWidth: width),
    ArrowDecimalType(3, 4),
    for (final width in ArrowOffsetWidth.values) ...[
      ArrowUtf8Type(width),
      ArrowBinaryType(width),
    ],
    ArrowFixedSizeBinaryType(0),
    ArrowFixedSizeBinaryType(12),
    for (final unit in ArrowDateUnit.values) ArrowDateType(unit),
    for (final unit in ArrowTimeUnit.values) ...[
      ArrowTimeType(unit),
      ArrowTimestampType(unit),
      ArrowTimestampType(unit, timeZone: 'Europe/London'),
      ArrowDurationType(unit),
    ],
    for (final unit in ArrowIntervalUnit.values) ArrowIntervalType(unit),
    ArrowListType(child),
    ArrowListType(child, offsetWidth: ArrowOffsetWidth.large),
    ArrowListType(child, view: true),
    ArrowListType(child, offsetWidth: ArrowOffsetWidth.large, view: true),
    ArrowFixedSizeListType(child, 3),
    ArrowStructType([child]),
    ArrowMapType(
      ArrowField('key', const ArrowUtf8Type(), nullable: false),
      child,
    ),
    for (final mode in ArrowUnionMode.values)
      ArrowUnionType(
        [child, ArrowField('text', const ArrowUtf8Type())],
        typeIds: [3, 7],
        mode: mode,
      ),
    ArrowRunEndEncodedType(
      ArrowField('run_ends', ArrowIntegerType(16), nullable: false),
      child,
    ),
    ArrowDictionaryType(
      ArrowIntegerType(16),
      const ArrowUtf8Type(),
      ordered: true,
    ),
    ArrowExtensionType(
      'example.uuid',
      ArrowFixedSizeBinaryType(16),
      metadata: 'version=1',
    ),
  ];
  for (final type in types) {
    test('IPC schema preserves $type', () {
      final schema = ArrowSchema(
        [
          ArrowField('value', type, metadata: {'source': 'test'}),
        ],
        metadata: {'table': 'example'},
      );
      final stream = ArrowIpcStreamWriter(schema: schema, batches: []).write();
      final fromStream = ArrowIpcStreamReader(stream).readTable();
      expect(fromStream.schema, schema);
      expect(fromStream.batches, isEmpty);
      final file = ArrowIpcFileWriter(schema: schema, batches: []).write();
      expect(ArrowIpcFileReader(file).readTable().schema, schema);
    });
  }
  test('standard IPC preserves unnamed and duplicate fields', () {
    final fields = [
      ArrowField('', const ArrowUtf8Type(), allowEmptyName: true),
      ArrowField('same', ArrowIntegerType(32)),
      ArrowField('same', ArrowIntegerType(64)),
    ];
    final schema = ArrowSchema(fields, allowDuplicateNames: true);
    expect(ArrowSchema.fromJson(schema.toJson()), schema);
    final bytes = ArrowIpcStreamWriter(schema: schema, batches: []).write();
    expect(ArrowIpcStreamReader(bytes).readTable().schema, schema);
    expect(() => ArrowField('', const ArrowNullType()), throwsArgumentError);
    expect(() => ArrowSchema(fields), throwsArgumentError);
  });
  test('binding-only int128 is never mislabeled as standard IPC', () {
    for (final signed in [true, false]) {
      final schema = ArrowSchema([
        ArrowField('wide', ArrowIntegerType(128, signed: signed)),
      ]);
      expect(
        () => ArrowIpcStreamWriter(schema: schema, batches: []).write(),
        throwsUnsupportedError,
      );
    }
  });
}
