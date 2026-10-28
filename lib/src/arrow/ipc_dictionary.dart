part of 'ipc.dart';

// Mapping between IPC dictionary ids and the dictionaries attached to
// ArrowArrays. Dictionary-encoded types are numbered in depth-first
// pre-order across the schema (the same order `_encodeSchema` assigns ids):
// a dictionary type comes first, then those nested inside its value type and
// children. Extension-wrapped dictionaries are found through `_dictionaryType`.

final class _DictionarySlot {
  const _DictionarySlot(this.column, this.ordinal, this.type, this.innerCount);

  /// Top-level schema field index that contains this dictionary.
  final int column;

  /// Pre-order position within the column (0 = outermost).
  final int ordinal;
  final ArrowDictionaryType type;

  /// Number of dictionary slots nested inside this one.
  final int innerCount;
}

List<_DictionarySlot> _dictionarySlots(ArrowSchema schema) => [
  for (var c = 0; c < schema.fields.length; c++)
    ..._columnSlots(c, schema.fields[c].type),
];

List<_DictionarySlot> _columnSlots(int column, ArrowDataType root) {
  final slots = <_DictionarySlot>[];
  void visit(ArrowDataType type) {
    final dictionary = _dictionaryType(type);
    final index = slots.length;
    if (dictionary != null) {
      slots.add(_DictionarySlot(column, index, dictionary, 0));
    }
    for (final child in _childFields(type)) {
      visit(child.type);
    }
    if (dictionary != null) {
      final inner = slots.length - index - 1;
      slots[index] = _DictionarySlot(column, index, dictionary, inner);
    }
  }

  visit(root);
  return slots;
}

/// Dictionaries carried by [column] in slot pre-order.
List<ArrowArray> _columnDictionaries(ArrowArray column) {
  final expected = _columnSlots(0, column.type).length;
  final dictionaries = [?column.dictionary, ...column.nestedDictionaries];
  if (dictionaries.length != expected) {
    throw StateError('Dictionary sidecars do not match IPC schema slots');
  }
  return dictionaries;
}

/// Rebuilds an array, attaching [dictionaries] in slot pre-order.
ArrowArray _arrayWithDictionaries(
  ArrowDataType type,
  List<ArrowValue?> values,
  List<ArrowArray> dictionaries,
) {
  final outer = _dictionaryType(type) != null;
  return ArrowArray(
    type,
    values,
    dictionary: outer ? dictionaries.first : null,
    nestedDictionaries: outer ? dictionaries.sublist(1) : dictionaries,
  );
}
