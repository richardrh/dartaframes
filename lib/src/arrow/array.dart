import 'type.dart';
import 'value.dart';
import 'schema.dart';

final class ArrowArray {
  ArrowArray(
    this.type,
    List<ArrowValue?> values, {
    List<bool>? validity,
    this.dictionary,
    List<ArrowArray> nestedDictionaries = const [],
  }) : nestedDictionaries = List.unmodifiable(nestedDictionaries),
       values = List.unmodifiable(values),
       validity = List.unmodifiable(validity ?? values.map((v) => v != null)) {
    if (this.validity.length != values.length) {
      throw ArgumentError(
        'Validity length ${this.validity.length} does not match value length ${values.length}',
      );
    }
    for (var i = 0; i < values.length; i++) {
      if (this.validity[i] != (values[i] != null)) {
        throw ArgumentError('Validity and value disagree at index $i');
      }
      final value = values[i];
      if (value != null) validateArrowValue(type, value, path: 'values[$i]');
    }
    if (_unwrapExtension(type) case final ArrowRunEndEncodedType ree) {
      _checkRunEndLength(ree, values.length);
      if (!ree.valuesField.nullable && this.validity.contains(false)) {
        throw ArgumentError('Run-end encoded values field is not nullable');
      }
    }
    if (_unwrapExtension(type) is ArrowUnionType &&
        this.validity.contains(false)) {
      throw ArgumentError(
        'Union arrays have no top-level nulls; use ArrowUnionValue(id, null)',
      );
    }
    _validateDictionaries(this);
  }

  /// Builds a run-end encoded array from its physical encoding.
  ///
  /// [runEnds] must be strictly increasing positive integers that fit the
  /// declared run-end width; the last run end is the logical length.
  /// [runValues] has one entry per run (null for a null run).
  factory ArrowArray.runEndEncoded(
    ArrowRunEndEncodedType type,
    List<int> runEnds,
    List<ArrowValue?> runValues,
  ) => ArrowArray(type, expandRunEnds(type, runEnds, runValues));

  final ArrowDataType type;
  final List<ArrowValue?> values;

  /// Dictionaries for every dictionary-encoded type strictly inside [type],
  /// in depth-first preorder (children of list, fixed-size list, struct, map
  /// entries, union, and run-end encoded fields, extension storage, and
  /// dictionaries nested in a dictionary's value type). This matches the IPC
  /// dictionary id assignment order. The top-level dictionary, if any, is
  /// [dictionary].
  final List<ArrowArray> nestedDictionaries;

  /// Run ends of the canonical (maximally merged) run-end encoding.
  ///
  /// Only valid for [ArrowRunEndEncodedType] arrays.
  List<int> get runEnds => _runs().$1;

  /// Run values matching [runEnds].
  List<ArrowValue?> get runValues => _runs().$2;

  (List<int>, List<ArrowValue?>) _runs() {
    if (type is! ArrowRunEndEncodedType) {
      throw StateError('Array is not run-end encoded');
    }
    final ends = <int>[];
    final runs = <ArrowValue?>[];
    for (var i = 0; i < values.length; i++) {
      if (runs.isNotEmpty && runs.last == values[i]) {
        ends[ends.length - 1] = i + 1;
      } else {
        ends.add(i + 1);
        runs.add(values[i]);
      }
    }
    return (List.unmodifiable(ends), List.unmodifiable(runs));
  }

  final List<bool> validity;

  /// Dictionary values when [type] is (an extension of) a dictionary type.
  final ArrowArray? dictionary;
  int get length => values.length;
  ArrowValue? operator [](int index) => values[index];
}

final class ArrowArrayBuilder {
  ArrowArrayBuilder(this.type, {this.dictionary});
  final ArrowDataType type;
  final ArrowArray? dictionary;
  final List<ArrowValue?> _values = [];
  bool _built = false;

  int get length => _values.length;
  void append(ArrowValue? value) {
    if (_built) throw StateError('Builder has already been built');
    if (value != null) validateArrowValue(type, value, path: 'value');
    _values.add(value);
  }

  void appendNull() => append(null);
  ArrowArray build() {
    if (_built) throw StateError('Builder has already been built');
    _built = true;
    return ArrowArray(type, _values, dictionary: dictionary);
  }
}

void validateArrowValue(
  ArrowDataType type,
  ArrowValue value, {
  String path = 'value',
}) {
  Never mismatch() =>
      throw ArgumentError('$path is ${value.runtimeType}, not valid for $type');
  switch (type) {
    case ArrowNullType():
      mismatch();
    case ArrowBooleanType():
      if (value is! ArrowBooleanValue) mismatch();
    case final ArrowIntegerType integer:
      if (value is! ArrowIntegerValue) mismatch();
      if (value.value < integer.minimum || value.value > integer.maximum) {
        throw RangeError(
          '$path integer ${value.value} is outside ${integer.minimum}..${integer.maximum}',
        );
      }
    case final ArrowFloatingType floating:
      if (value is! ArrowFloatingValue || value.bitWidth != floating.bitWidth) {
        mismatch();
      }
    case final ArrowDecimalType decimal:
      if (value is! ArrowDecimalValue) mismatch();
      final digits = value.unscaled.abs().toString().length;
      if (digits > decimal.precision) {
        throw RangeError(
          '$path unscaled decimal has $digits digits; precision is ${decimal.precision}',
        );
      }
      _checkSignedWidth(value.unscaled, decimal.bitWidth, path);
    case ArrowUtf8Type():
      if (value is! ArrowStringValue) mismatch();
    case ArrowBinaryType():
      if (value is! ArrowBinaryValue) mismatch();
    case final ArrowDateType date:
      if (value is! ArrowTemporalValue) mismatch();
      final width = date.unit == ArrowDateUnit.day ? 32 : 64;
      final minimum = -(BigInt.one << (width - 1));
      final maximum = (BigInt.one << (width - 1)) - BigInt.one;
      if (value.value < minimum || value.value > maximum) {
        throw RangeError('$path date counter does not fit int$width');
      }
    case ArrowTimestampType() || ArrowDurationType():
      if (value is! ArrowTemporalValue) mismatch();
      if (!_fitsSigned64(value.value)) {
        throw RangeError('$path temporal counter does not fit int64');
      }
    case final ArrowTimeType time:
      if (value is! ArrowTemporalValue) mismatch();
      final unitsPerSecond = switch (time.unit) {
        ArrowTimeUnit.second => BigInt.one,
        ArrowTimeUnit.millisecond => BigInt.from(1000),
        ArrowTimeUnit.microsecond => BigInt.from(1000000),
        ArrowTimeUnit.nanosecond => BigInt.from(1000000000),
      };
      final endOfDay = BigInt.from(86400) * unitsPerSecond;
      if (value.value.isNegative || value.value >= endOfDay) {
        throw RangeError('$path time counter must fall within one day');
      }
      if ((time.unit == ArrowTimeUnit.second ||
              time.unit == ArrowTimeUnit.millisecond) &&
          value.value > BigInt.from(0x7fffffff)) {
        throw RangeError('$path time counter does not fit int32');
      }
    case final ArrowListType list:
      if (value is! ArrowListValue) mismatch();
      _validateChildren(list.field, value.values, path);
    case final ArrowFixedSizeListType list:
      if (value is! ArrowListValue) mismatch();
      if (value.values.length != list.size) {
        throw ArgumentError(
          '$path has ${value.values.length} children; expected ${list.size}',
        );
      }
      _validateChildren(list.field, value.values, path);
    case final ArrowStructType struct:
      if (value is! ArrowStructValue) mismatch();
      if (value.fields.length != struct.fields.length) {
        throw ArgumentError(
          '$path has ${value.fields.length} fields; expected ${struct.fields.length}',
        );
      }
      for (var i = 0; i < struct.fields.length; i++) {
        final expected = struct.fields[i];
        final actual = value.fields[i];
        if (actual.name != expected.name) {
          throw ArgumentError(
            '$path field $i is ${actual.name}; expected ${expected.name}',
          );
        }
        if (actual.value == null) {
          if (!expected.nullable) {
            throw ArgumentError('$path.${expected.name} is not nullable');
          }
        } else {
          validateArrowValue(
            expected.type,
            actual.value!,
            path: '$path.${expected.name}',
          );
        }
      }
    case final ArrowDictionaryType dictionary:
      if (value is! ArrowDictionaryIndexValue) mismatch();
      validateArrowValue(
        dictionary.indexType,
        ArrowIntegerValue(value.index),
        path: path,
      );
    case ArrowFixedSizeBinaryType() ||
        ArrowMapType() ||
        ArrowUnionType() ||
        ArrowIntervalType() ||
        ArrowRunEndEncodedType():
      _validateExtendedValue(type, value, path, mismatch);
    case final ArrowExtensionType extension:
      if (value is! ArrowExtensionValue) mismatch();
      validateArrowValue(
        extension.storageType,
        value.storage,
        path: '$path.storage',
      );
  }
}

bool _fitsSigned64(BigInt value) =>
    value >= -(BigInt.one << 63) && value <= (BigInt.one << 63) - BigInt.one;

void _validateChildren(
  ArrowField field,
  List<ArrowValue?> values,
  String path,
) {
  for (var i = 0; i < values.length; i++) {
    final child = values[i];
    if (child == null) {
      if (!field.nullable) throw ArgumentError('$path[$i] is not nullable');
    } else {
      validateArrowValue(field.type, child, path: '$path[$i]');
    }
  }
}

/// Expands a run-end encoding to logical rows, validating run ends.
///
/// When [maxLength] is given, run ends are fully validated against it before
/// any expansion, so untrusted input cannot force a large allocation.
List<ArrowValue?> expandRunEnds(
  ArrowRunEndEncodedType type,
  List<int> runEnds,
  List<ArrowValue?> runValues, {
  int? maxLength,
}) {
  if (runEnds.length != runValues.length) {
    throw ArgumentError('runEnds and runValues lengths differ');
  }
  _checkRunEnds(type, runEnds, runValues, maxLength);
  final rows = <ArrowValue?>[];
  var previous = 0;
  for (var i = 0; i < runEnds.length; i++) {
    rows.addAll(List.filled(runEnds[i] - previous, runValues[i]));
    previous = runEnds[i];
  }
  return rows;
}

void _checkRunEndLength(ArrowRunEndEncodedType type, int length) {
  final width = (type.runEndsField.type as ArrowIntegerType).bitWidth;
  if (BigInt.from(length) > (BigInt.one << (width - 1)) - BigInt.one) {
    throw RangeError('Run-end encoded length $length does not fit int$width');
  }
}

void _checkRunEnds(
  ArrowRunEndEncodedType type,
  List<int> runEnds,
  List<ArrowValue?> runValues,
  int? maxLength,
) {
  final width = (type.runEndsField.type as ArrowIntegerType).bitWidth;
  final maximum = (BigInt.one << (width - 1)) - BigInt.one;
  var previous = 0;
  for (var i = 0; i < runEnds.length; i++) {
    final end = runEnds[i];
    if (maxLength != null && end > maxLength) {
      throw RangeError('runEnds[$i]=$end exceeds the limit $maxLength');
    }
    if (end <= previous) {
      throw ArgumentError('runEnds[$i]=$end must exceed $previous');
    }
    if (BigInt.from(end) > maximum) {
      throw RangeError('runEnds[$i]=$end does not fit int$width');
    }
    final value = runValues[i];
    if (value == null && !type.valuesField.nullable) {
      throw ArgumentError('runValues[$i] is not nullable');
    }
    previous = end;
  }
}

void _checkSignedWidth(BigInt value, int width, String path) {
  final limit = BigInt.one << (width - 1);
  if (value < -limit || value >= limit) {
    throw RangeError('$path does not fit a $width-bit signed integer');
  }
}

void _validateExtendedValue(
  ArrowDataType type,
  ArrowValue value,
  String path,
  Never Function() mismatch,
) {
  switch (type) {
    case final ArrowFixedSizeBinaryType binary:
      if (value is! ArrowBinaryValue) mismatch();
      if (value.bytes.length != binary.byteWidth) {
        throw ArgumentError(
          '$path has ${value.bytes.length} bytes; expected ${binary.byteWidth}',
        );
      }
    case final ArrowMapType map:
      if (value is! ArrowMapValue) mismatch();
      _validateMap(map, value, path);
    case final ArrowUnionType union:
      if (value is! ArrowUnionValue) mismatch();
      final field = union.fieldForTypeId(value.typeId);
      if (field == null) {
        throw ArgumentError(
          '$path has undeclared union type id ${value.typeId}',
        );
      }
      _validateChildren(field, [value.value], '$path.${field.name}');
    case final ArrowIntervalType interval:
      if (value is! ArrowIntervalValue || value.unit != interval.unit) {
        mismatch();
      }
    case final ArrowRunEndEncodedType ree:
      _validateChildren(ree.valuesField, [value], path);
    default:
      mismatch();
  }
}

void _validateMap(ArrowMapType map, ArrowMapValue value, String path) {
  for (var i = 0; i < value.entries.length; i++) {
    final entry = value.entries[i];
    validateArrowValue(map.keyField.type, entry.key, path: '$path[$i].key');
    _validateChildren(map.valueField, [entry.value], '$path[$i].value');
  }
}

ArrowDataType _unwrapExtension(ArrowDataType type) {
  while (type is ArrowExtensionType) {
    type = type.storageType;
  }
  return type;
}

ArrowValue _unwrapExtensionValue(ArrowValue value) {
  while (value is ArrowExtensionValue) {
    value = value.storage;
  }
  return value;
}

List<ArrowDataType> _childTypes(ArrowDataType type) => switch (type) {
  ArrowListType(:final field) ||
  ArrowFixedSizeListType(:final field) => [field.type],
  ArrowStructType(:final fields) ||
  ArrowUnionType(:final fields) => [for (final f in fields) f.type],
  ArrowMapType(:final keyField, :final valueField) => [
    keyField.type,
    valueField.type,
  ],
  ArrowRunEndEncodedType(:final runEndsField, :final valuesField) => [
    runEndsField.type,
    valuesField.type,
  ],
  _ => const [],
};

/// Appends the dictionary types in [type] (including itself) in preorder.
void _collectDictionaries(ArrowDataType type, List<ArrowDictionaryType> out) {
  final storage = _unwrapExtension(type);
  if (storage is ArrowDictionaryType) {
    out.add(storage);
    _collectDictionaries(storage.valueType, out);
    return;
  }
  for (final child in _childTypes(storage)) {
    _collectDictionaries(child, out);
  }
}

int _dictionarySlots(ArrowDataType type) {
  final out = <ArrowDictionaryType>[];
  _collectDictionaries(type, out);
  return out.length;
}

/// The dictionary types strictly inside [type], in [ArrowArray.nestedDictionaries] order.
List<ArrowDictionaryType> nestedDictionaryTypes(ArrowDataType type) {
  final out = <ArrowDictionaryType>[];
  final storage = _unwrapExtension(type);
  if (storage is ArrowDictionaryType) {
    _collectDictionaries(storage.valueType, out);
  } else {
    for (final child in _childTypes(storage)) {
      _collectDictionaries(child, out);
    }
  }
  return out;
}

void _validateDictionaries(ArrowArray array) {
  final storage = _unwrapExtension(array.type);
  final nestedTypes = nestedDictionaryTypes(array.type);
  final nested = array.nestedDictionaries;
  if (nested.length != nestedTypes.length) {
    throw ArgumentError(
      'Expected ${nestedTypes.length} nested dictionaries; got ${nested.length}',
    );
  }
  for (var k = 0; k < nested.length; k++) {
    if (nested[k].type != nestedTypes[k].valueType) {
      throw ArgumentError('nestedDictionaries[$k] datatype mismatch');
    }
    _checkDictionaryDescendants(nested[k], nested, k + 1);
  }
  if (storage is! ArrowDictionaryType) {
    if (array.dictionary != null) {
      throw ArgumentError('dictionary is only valid for a dictionary datatype');
    }
    for (var i = 0; i < array.length; i++) {
      final value = array.values[i];
      if (value != null) {
        _checkNestedIndices(array.type, value, -1, nested, 'values[$i]');
      }
    }
    return;
  }
  final dictionary = array.dictionary;
  if (dictionary == null) {
    throw ArgumentError('Dictionary array requires dictionary values');
  }
  if (dictionary.type != storage.valueType) {
    throw ArgumentError(
      'Dictionary value datatype does not match dictionary datatype',
    );
  }
  _checkDictionaryDescendants(dictionary, nested, 0);
  for (var i = 0; i < array.length; i++) {
    final value = array.values[i];
    if (value != null) _checkIndex(value, dictionary, 'values[$i]');
  }
}

void _checkDictionaryDescendants(
  ArrowArray dictionary,
  List<ArrowArray> nested,
  int start,
) {
  final descendants = [
    if (dictionary.dictionary case final child?) child,
    ...dictionary.nestedDictionaries,
  ];
  for (var i = 0; i < descendants.length; i++) {
    if (start + i >= nested.length ||
        !_sameDictionary(descendants[i], nested[start + i])) {
      throw ArgumentError('Inconsistent nested dictionary at ${start + i}');
    }
  }
}

bool _sameDictionary(ArrowArray a, ArrowArray b) {
  if (identical(a, b)) return true;
  if (a.type != b.type || a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a.values[i] != b.values[i]) return false;
  }
  if (a.dictionary case final child?) {
    if (b.dictionary == null || !_sameDictionary(child, b.dictionary!)) {
      return false;
    }
  } else if (b.dictionary != null) {
    return false;
  }
  if (a.nestedDictionaries.length != b.nestedDictionaries.length) return false;
  for (var i = 0; i < a.nestedDictionaries.length; i++) {
    if (!_sameDictionary(a.nestedDictionaries[i], b.nestedDictionaries[i])) {
      return false;
    }
  }
  return true;
}

void _checkIndex(ArrowValue value, ArrowArray dictionary, String path) {
  final index =
      (_unwrapExtensionValue(value) as ArrowDictionaryIndexValue).index;
  if (index.isNegative || index >= BigInt.from(dictionary.length)) {
    throw RangeError('Dictionary index $index at $path is out of bounds');
  }
}

/// Checks indices in [value] of [type]. [base] is the slot immediately
/// preceding this subtree's dictionaries; -1 marks the column root.
void _checkNestedIndices(
  ArrowDataType type,
  ArrowValue value,
  int base,
  List<ArrowArray> nested,
  String path,
) {
  final storage = _unwrapExtension(type);
  final inner = _unwrapExtensionValue(value);
  if (storage is ArrowDictionaryType) {
    _checkIndex(inner, nested[base + 1], path);
    return;
  }
  final first = base + 1;
  void child(ArrowDataType t, ArrowValue? v, int offset, String p) {
    if (v != null) _checkNestedIndices(t, v, first + offset - 1, nested, p);
  }

  switch (storage) {
    case ArrowListType(:final field) || ArrowFixedSizeListType(:final field):
      final list = inner as ArrowListValue;
      for (var i = 0; i < list.values.length; i++) {
        child(field.type, list.values[i], 0, '$path[$i]');
      }
    case final ArrowStructType struct:
      var offset = 0;
      final entries = (inner as ArrowStructValue).fields;
      for (var i = 0; i < struct.fields.length; i++) {
        child(struct.fields[i].type, entries[i].value, offset, '$path.$i');
        offset += _dictionarySlots(struct.fields[i].type);
      }
    case final ArrowMapType map:
      final keySlots = _dictionarySlots(map.keyField.type);
      for (final (i, e) in (inner as ArrowMapValue).entries.indexed) {
        child(map.keyField.type, e.key, 0, '$path[$i].key');
        child(map.valueField.type, e.value, keySlots, '$path[$i].value');
      }
    case final ArrowUnionType union:
      final tagged = inner as ArrowUnionValue;
      final j = union.typeIds.indexOf(tagged.typeId);
      var offset = 0;
      for (var k = 0; k < j; k++) {
        offset += _dictionarySlots(union.fields[k].type);
      }
      child(union.fields[j].type, tagged.value, offset, path);
    case final ArrowRunEndEncodedType ree:
      child(ree.valuesField.type, inner, 0, path);
    default:
      break;
  }
}
