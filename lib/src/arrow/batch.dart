import 'array.dart';
import 'schema.dart';

final class RecordBatch {
  RecordBatch(this.schema, List<ArrowArray> columns, {int? rowCount})
    : columns = List.unmodifiable(columns),
      rowCount = rowCount ?? (columns.isEmpty ? 0 : columns.first.length) {
    if (this.rowCount < 0) {
      throw RangeError.value(this.rowCount, 'rowCount', 'must be non-negative');
    }
    if (columns.length != schema.fields.length) {
      throw ArgumentError(
        'Column count ${columns.length} does not match schema field count ${schema.fields.length}',
      );
    }
    for (var i = 0; i < columns.length; i++) {
      final field = schema.fields[i];
      final column = columns[i];
      if (column.type != field.type) {
        throw ArgumentError(
          'Column $i (${field.name}) datatype does not match schema',
        );
      }
      if (column.length != this.rowCount) {
        throw ArgumentError(
          'Column $i (${field.name}) length ${column.length} does not match row count ${this.rowCount}',
        );
      }
      if (!field.nullable && column.validity.any((valid) => !valid)) {
        throw ArgumentError('Column $i (${field.name}) is not nullable');
      }
    }
  }
  final ArrowSchema schema;
  final List<ArrowArray> columns;
  final int rowCount;
  int get length => rowCount;
  int get columnCount => columns.length;

  /// Returns an owned copy of a row range while retaining schema metadata.
  ///
  /// Dictionaries are immutable and shared with the source. Other value lists
  /// are copied; this method does not promise zero-copy physical buffers.
  RecordBatch slice(int offset, [int? length]) {
    if (offset < 0 || offset > rowCount) {
      throw RangeError.range(offset, 0, rowCount, 'offset');
    }
    final count = length ?? rowCount - offset;
    if (count < 0 || count > rowCount - offset) {
      throw RangeError.range(count, 0, rowCount - offset, 'length');
    }
    return RecordBatch(schema, [
      for (final column in columns)
        ArrowArray(
          column.type,
          column.values.sublist(offset, offset + count),
          dictionary: column.dictionary,
          nestedDictionaries: column.nestedDictionaries,
        ),
    ], rowCount: count);
  }
}
