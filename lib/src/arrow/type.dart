import 'schema.dart';

enum ArrowTimeUnit {
  second('seconds'),
  millisecond('milliseconds'),
  microsecond('microseconds'),
  nanosecond('nanoseconds');

  const ArrowTimeUnit(this.jsonName);
  final String jsonName;

  static ArrowTimeUnit parse(String value) => values.firstWhere(
    (unit) => unit.jsonName == value || unit.name == value,
    orElse: () => throw FormatException('Unknown time unit: $value'),
  );
}

enum ArrowDateUnit { day, millisecond }

/// Physical layout family for variable-length string, binary, and list data.
///
/// [normal] uses 32-bit offsets, [large] uses 64-bit offsets, and [view]
/// selects the Arrow `Utf8View`/`BinaryView` layouts (strings and binary only).
enum ArrowOffsetWidth { normal, large, view }

/// Arrow union physical layout.
enum ArrowUnionMode { sparse, dense }

/// Arrow interval unit, as in `IntervalUnit` from Schema.fbs.
enum ArrowIntervalUnit { yearMonth, dayTime, monthDayNano }

sealed class ArrowDataType {
  const ArrowDataType();

  Map<String, Object?> toJson();

  static ArrowDataType fromJson(Map<String, Object?> json) {
    try {
      return _fromJson(json);
    } on FormatException {
      rethrow;
    } on ArgumentError catch (error) {
      throw FormatException('Invalid Arrow datatype: $error');
    } on TypeError catch (error) {
      throw FormatException('Invalid Arrow datatype shape: $error');
    }
  }

  static ArrowDataType _fromJson(Map<String, Object?> json) {
    final kind = json['kind'];
    if (kind is! String) {
      throw const FormatException('dtype.kind must be a string');
    }
    int integer(String name) {
      final value = json[name];
      if (value is! int) {
        throw FormatException('dtype.$name must be an integer');
      }
      return value;
    }

    String string(String name) {
      final value = json[name];
      if (value is! String) {
        throw FormatException('dtype.$name must be a string');
      }
      return value;
    }

    Map<String, Object?> object(String name) {
      final value = json[name];
      if (value is! Map) throw FormatException('dtype.$name must be an object');
      return _stringObjectMap(value, 'dtype.$name');
    }

    bool boolean(String name, bool defaultValue) {
      final value = json[name];
      if (value == null && !json.containsKey(name)) return defaultValue;
      if (value is! bool) {
        throw FormatException('dtype.$name must be a boolean');
      }
      return value;
    }

    String? optionalString(String name) {
      final value = json[name];
      if (value == null && !json.containsKey(name)) return null;
      if (value is! String) {
        throw FormatException('dtype.$name must be a string');
      }
      return value;
    }

    switch (kind) {
      case 'null':
        return const ArrowNullType();
      case 'boolean':
        return const ArrowBooleanType();
      case 'int8':
        return ArrowIntegerType(8);
      case 'int16':
        return ArrowIntegerType(16);
      case 'int32':
        return ArrowIntegerType(32);
      case 'int64':
        return ArrowIntegerType(64);
      case 'int128':
        return ArrowIntegerType(128);
      case 'uint8':
        return ArrowIntegerType(8, signed: false);
      case 'uint16':
        return ArrowIntegerType(16, signed: false);
      case 'uint32':
        return ArrowIntegerType(32, signed: false);
      case 'uint64':
        return ArrowIntegerType(64, signed: false);
      case 'uint128':
        return ArrowIntegerType(128, signed: false);
      case 'float16':
        return ArrowFloatingType(16);
      case 'float32':
        return ArrowFloatingType(32);
      case 'float64':
        return ArrowFloatingType(64);
      case 'decimal':
        return _decimalFromJson(json, integer);
      case 'string':
      case 'utf8':
        return const ArrowUtf8Type();
      case 'largeString':
      case 'largeUtf8':
        return const ArrowUtf8Type(ArrowOffsetWidth.large);
      case 'binary':
        return const ArrowBinaryType();
      case 'largeBinary':
        return const ArrowBinaryType(ArrowOffsetWidth.large);
      case 'date':
        return switch (string('unit')) {
          'days' => const ArrowDateType(),
          'milliseconds' => const ArrowDateType(ArrowDateUnit.millisecond),
          final unit => throw FormatException('Unknown date unit: $unit'),
        };
      case 'datetime':
      case 'timestamp':
        return ArrowTimestampType(
          ArrowTimeUnit.parse(string('unit')),
          timeZone: optionalString('timeZone'),
        );
      case 'duration':
        return ArrowDurationType(ArrowTimeUnit.parse(string('unit')));
      case 'time':
        return ArrowTimeType(ArrowTimeUnit.parse(string('unit')));
      case 'list':
        return ArrowListType(ArrowField.fromJson(object('field')));
      case 'fixedSizeList':
      case 'array':
        return ArrowFixedSizeListType(
          ArrowField.fromJson(object('field')),
          integer('size'),
        );
      case 'struct':
        final fields = json['fields'];
        if (fields is! List) {
          throw const FormatException('dtype.fields must be a list');
        }
        return ArrowStructType(
          allowDuplicateNames: true,
          fields.indexed
              .map(
                (e) => ArrowField.fromJson(
                  _stringObjectMap(e.$2, 'dtype.fields[${e.$1}]'),
                ),
              )
              .toList(),
        );
      case 'dictionary':
        return ArrowDictionaryType(
          ArrowDataType.fromJson(object('indexType')),
          ArrowDataType.fromJson(object('valueType')),
          ordered: boolean('ordered', false),
        );
      case 'extension':
        return ArrowExtensionType(
          string('name'),
          ArrowDataType.fromJson(object('storageType')),
          metadata: optionalString('metadata'),
        );
      default:
        return _extendedFromJson(kind, json, integer, string, object, boolean);
    }
  }

  static ArrowDecimalType _decimalFromJson(
    Map<String, Object?> json,
    int Function(String) integer,
  ) {
    final bitWidth = json['bitWidth'];
    if (bitWidth != null && bitWidth is! int) {
      throw const FormatException('dtype.bitWidth must be an integer');
    }
    return ArrowDecimalType(
      integer('precision'),
      integer('scale'),
      bitWidth: (bitWidth as int?) ?? 128,
    );
  }

  static ArrowDataType _extendedFromJson(
    String kind,
    Map<String, Object?> json,
    int Function(String) integer,
    String Function(String) string,
    Map<String, Object?> Function(String) object,
    bool Function(String, bool) boolean,
  ) {
    ArrowField field(String name) => ArrowField.fromJson(object(name));
    switch (kind) {
      case 'largeList':
        return ArrowListType(
          field('field'),
          offsetWidth: ArrowOffsetWidth.large,
        );
      case 'listView':
        return ArrowListType(field('field'), view: true);
      case 'largeListView':
        return ArrowListType(
          field('field'),
          offsetWidth: ArrowOffsetWidth.large,
          view: true,
        );
      case 'stringView':
      case 'utf8View':
        return const ArrowUtf8Type(ArrowOffsetWidth.view);
      case 'binaryView':
        return const ArrowBinaryType(ArrowOffsetWidth.view);
      case 'fixedSizeBinary':
        return ArrowFixedSizeBinaryType(integer('byteWidth'));
      case 'map':
        return ArrowMapType(
          field('key'),
          field('value'),
          keysSorted: boolean('keysSorted', false),
          entriesName: json.containsKey('entriesName')
              ? string('entriesName')
              : 'entries',
          entriesMetadata: _stringMap(json['entriesMetadata']),
          allowDuplicateNames: true,
        );
      case 'union':
        final fields = json['fields'];
        final ids = json['typeIds'];
        if (fields is! List) {
          throw const FormatException('dtype.fields must be a list');
        }
        if (ids is! List || ids.any((id) => id is! int)) {
          throw const FormatException('dtype.typeIds must be integers');
        }
        return ArrowUnionType(
          [
            for (final (i, f) in fields.indexed)
              ArrowField.fromJson(_stringObjectMap(f, 'dtype.fields[$i]')),
          ],
          mode: switch (string('mode')) {
            'sparse' => ArrowUnionMode.sparse,
            'dense' => ArrowUnionMode.dense,
            final mode => throw FormatException('Unknown union mode: $mode'),
          },
          typeIds: ids.cast<int>(),
        );
      case 'interval':
        final unit = string('unit');
        return ArrowIntervalType(
          ArrowIntervalUnit.values.firstWhere(
            (u) => u.name == unit,
            orElse: () => throw FormatException('Unknown interval unit: $unit'),
          ),
        );
      case 'runEndEncoded':
        return ArrowRunEndEncodedType(field('runEnds'), field('values'));
      default:
        throw FormatException('Unknown Arrow datatype kind: $kind');
    }
  }

  @override
  bool operator ==(Object other) =>
      other is ArrowDataType && _deepEquals(toJson(), other.toJson());

  @override
  int get hashCode => _deepHash(toJson());

  @override
  String toString() => toJson().toString();
}

final class ArrowNullType extends ArrowDataType {
  const ArrowNullType();
  @override
  Map<String, Object?> toJson() => const {'kind': 'null'};
}

final class ArrowBooleanType extends ArrowDataType {
  const ArrowBooleanType();
  @override
  Map<String, Object?> toJson() => const {'kind': 'boolean'};
}

final class ArrowIntegerType extends ArrowDataType {
  ArrowIntegerType(this.bitWidth, {this.signed = true}) {
    if (bitWidth != 8 &&
        bitWidth != 16 &&
        bitWidth != 32 &&
        bitWidth != 64 &&
        bitWidth != 128) {
      throw ArgumentError.value(
        bitWidth,
        'bitWidth',
        'must be 8, 16, 32, 64, or 128',
      );
    }
  }
  final int bitWidth;
  final bool signed;
  BigInt get minimum => signed ? -(BigInt.one << (bitWidth - 1)) : BigInt.zero;
  BigInt get maximum => signed
      ? (BigInt.one << (bitWidth - 1)) - BigInt.one
      : (BigInt.one << bitWidth) - BigInt.one;
  @override
  Map<String, Object?> toJson() => {'kind': '${signed ? '' : 'u'}int$bitWidth'};
}

final class ArrowFloatingType extends ArrowDataType {
  ArrowFloatingType(this.bitWidth) {
    if (bitWidth != 16 && bitWidth != 32 && bitWidth != 64) {
      throw ArgumentError.value(bitWidth, 'bitWidth', 'must be 16, 32, or 64');
    }
  }
  final int bitWidth;
  @override
  Map<String, Object?> toJson() => {'kind': 'float$bitWidth'};
}

final class ArrowDecimalType extends ArrowDataType {
  /// Creates a decimal of [bitWidth] 32, 64, 128 (default), or 256 bits.
  ///
  /// Maximum precision is 9, 18, 38, or 76 respectively. [scale] may be
  /// any signed 32-bit integer, as Arrow permits: negative scales and scales
  /// greater than [precision] are valid (value = unscaled * 10^-scale).
  /// This is a deliberate expansion over earlier releases that required
  /// `0 <= scale <= precision`. Consumers such as the Polars native boundary
  /// that do not support these scales or non-128-bit widths must reject them.
  ArrowDecimalType(this.precision, this.scale, {this.bitWidth = 128}) {
    final maxPrecision = switch (bitWidth) {
      32 => 9,
      64 => 18,
      128 => 38,
      256 => 76,
      _ => throw ArgumentError.value(
        bitWidth,
        'bitWidth',
        'must be 32, 64, 128, or 256',
      ),
    };
    if (precision < 1 || precision > maxPrecision) {
      throw RangeError.range(precision, 1, maxPrecision, 'precision');
    }
    if (scale < -0x80000000 || scale > 0x7fffffff) {
      throw RangeError.range(scale, -0x80000000, 0x7fffffff, 'scale');
    }
  }
  final int precision;
  final int scale;

  /// Storage width in bits.
  final int bitWidth;
  @override
  Map<String, Object?> toJson() => {
    'kind': 'decimal',
    'precision': precision,
    'scale': scale,
    if (bitWidth != 128) 'bitWidth': bitWidth,
  };
}

final class ArrowUtf8Type extends ArrowDataType {
  const ArrowUtf8Type([this.offsetWidth = ArrowOffsetWidth.normal]);
  final ArrowOffsetWidth offsetWidth;
  @override
  Map<String, Object?> toJson() => {
    'kind': switch (offsetWidth) {
      ArrowOffsetWidth.normal => 'string',
      ArrowOffsetWidth.large => 'largeString',
      ArrowOffsetWidth.view => 'stringView',
    },
  };
}

final class ArrowBinaryType extends ArrowDataType {
  const ArrowBinaryType([this.offsetWidth = ArrowOffsetWidth.normal]);
  final ArrowOffsetWidth offsetWidth;
  @override
  Map<String, Object?> toJson() => {
    'kind': switch (offsetWidth) {
      ArrowOffsetWidth.normal => 'binary',
      ArrowOffsetWidth.large => 'largeBinary',
      ArrowOffsetWidth.view => 'binaryView',
    },
  };
}

/// Fixed-width binary: every value has exactly [byteWidth] bytes.
final class ArrowFixedSizeBinaryType extends ArrowDataType {
  ArrowFixedSizeBinaryType(this.byteWidth) {
    if (byteWidth < 0) {
      throw RangeError.value(byteWidth, 'byteWidth', 'must be non-negative');
    }
  }
  final int byteWidth;
  @override
  Map<String, Object?> toJson() => {
    'kind': 'fixedSizeBinary',
    'byteWidth': byteWidth,
  };
}

final class ArrowDateType extends ArrowDataType {
  const ArrowDateType([this.unit = ArrowDateUnit.day]);
  final ArrowDateUnit unit;
  @override
  Map<String, Object?> toJson() => {
    'kind': 'date',
    'unit': unit == ArrowDateUnit.day ? 'days' : 'milliseconds',
  };
}

final class ArrowTimestampType extends ArrowDataType {
  const ArrowTimestampType(this.unit, {this.timeZone});
  final ArrowTimeUnit unit;
  final String? timeZone;
  @override
  Map<String, Object?> toJson() => {
    'kind': 'datetime',
    'unit': unit.jsonName,
    if (timeZone != null) 'timeZone': timeZone,
  };
}

final class ArrowDurationType extends ArrowDataType {
  const ArrowDurationType(this.unit);
  final ArrowTimeUnit unit;
  @override
  Map<String, Object?> toJson() => {'kind': 'duration', 'unit': unit.jsonName};
}

final class ArrowTimeType extends ArrowDataType {
  const ArrowTimeType(this.unit);
  final ArrowTimeUnit unit;
  @override
  Map<String, Object?> toJson() => {'kind': 'time', 'unit': unit.jsonName};
}

final class ArrowListType extends ArrowDataType {
  /// Variable-length list. [offsetWidth] selects `List` (normal) or
  /// `LargeList` (large); [view] selects the `ListView` layouts.
  ArrowListType(
    this.field, {
    this.offsetWidth = ArrowOffsetWidth.normal,
    this.view = false,
  }) {
    if (offsetWidth == ArrowOffsetWidth.view) {
      throw ArgumentError.value(
        offsetWidth,
        'offsetWidth',
        'use view: true for list views',
      );
    }
  }
  final ArrowField field;
  final ArrowOffsetWidth offsetWidth;
  final bool view;
  @override
  Map<String, Object?> toJson() => {
    'kind': switch ((offsetWidth == ArrowOffsetWidth.large, view)) {
      (false, false) => 'list',
      (true, false) => 'largeList',
      (false, true) => 'listView',
      (true, true) => 'largeListView',
    },
    'field': field.toJson(),
  };
}

final class ArrowFixedSizeListType extends ArrowDataType {
  ArrowFixedSizeListType(this.field, this.size) {
    if (size < 0) throw RangeError.value(size, 'size', 'must be non-negative');
  }
  final ArrowField field;
  final int size;
  @override
  Map<String, Object?> toJson() => {
    'kind': 'fixedSizeList',
    'field': field.toJson(),
    'size': size,
  };
}

final class ArrowStructType extends ArrowDataType {
  /// Creates a struct. Duplicate child names are rejected unless
  /// [allowDuplicateNames] is true; Arrow itself permits them, so decoders of
  /// standard data (JSON, IPC) pass true. The flag is not serialized.
  ArrowStructType(List<ArrowField> fields, {bool allowDuplicateNames = false})
    : fields = List.unmodifiable(fields) {
    if (allowDuplicateNames) return;
    final names = <String>{};
    for (final field in fields) {
      if (!names.add(field.name)) {
        throw ArgumentError('Duplicate struct field: ${field.name}');
      }
    }
  }
  final List<ArrowField> fields;
  @override
  Map<String, Object?> toJson() => {
    'kind': 'struct',
    'fields': fields.map((f) => f.toJson()).toList(),
  };
}

final class ArrowDictionaryType extends ArrowDataType {
  ArrowDictionaryType(this.indexType, this.valueType, {this.ordered = false}) {
    if (indexType is! ArrowIntegerType) {
      throw ArgumentError.value(
        indexType,
        'indexType',
        'must be an integer type',
      );
    }
  }
  final ArrowDataType indexType;
  final ArrowDataType valueType;
  final bool ordered;
  @override
  Map<String, Object?> toJson() => {
    'kind': 'dictionary',
    'indexType': indexType.toJson(),
    'valueType': valueType.toJson(),
    'ordered': ordered,
  };
}

final class ArrowExtensionType extends ArrowDataType {
  ArrowExtensionType(this.name, this.storageType, {this.metadata}) {
    if (name.isEmpty) {
      throw ArgumentError.value(name, 'name', 'must not be empty');
    }
  }
  final String name;
  final ArrowDataType storageType;
  final String? metadata;
  @override
  Map<String, Object?> toJson() => {
    'kind': 'extension',
    'name': name,
    'storageType': storageType.toJson(),
    if (metadata != null) 'metadata': metadata,
  };
}

/// Arrow `Map`: a list of non-null `entries` structs of `<key, value>`.
///
/// The key field must be non-nullable. Entry order is preserved; [keysSorted]
/// only records the producer's claim, as in Schema.fbs.
final class ArrowMapType extends ArrowDataType {
  ArrowMapType(
    this.keyField,
    this.valueField, {
    this.keysSorted = false,
    this.entriesName = 'entries',
    Map<String, String> entriesMetadata = const {},
    this.allowDuplicateNames = false,
  }) : entriesMetadata = Map.unmodifiable(entriesMetadata) {
    if (keyField.nullable) {
      throw ArgumentError.value(keyField, 'keyField', 'must be non-nullable');
    }
    if (!allowDuplicateNames && keyField.name == valueField.name) {
      throw ArgumentError('Map key and value fields need distinct names');
    }
  }
  final ArrowField keyField;
  final ArrowField valueField;
  final bool keysSorted;
  final String entriesName;

  /// Whether key and value fields may share a name (valid Arrow; readers of
  /// standard data pass true). Not serialized.
  final bool allowDuplicateNames;

  /// Metadata of the physical entries child field, preserved for fidelity.
  final Map<String, String> entriesMetadata;

  /// The physical child field: a non-null struct of key and value.
  ArrowField get entriesField => ArrowField(
    entriesName,
    ArrowStructType([
      keyField,
      valueField,
    ], allowDuplicateNames: allowDuplicateNames),
    nullable: false,
    metadata: entriesMetadata,
  );
  @override
  Map<String, Object?> toJson() => {
    'kind': 'map',
    'key': keyField.toJson(),
    'value': valueField.toJson(),
    'keysSorted': keysSorted,
    if (entriesName != 'entries') 'entriesName': entriesName,
    if (entriesMetadata.isNotEmpty) 'entriesMetadata': entriesMetadata,
  };
}

/// Arrow sparse or dense union. Each child has a type id (default its index).
final class ArrowUnionType extends ArrowDataType {
  ArrowUnionType(
    List<ArrowField> fields, {
    this.mode = ArrowUnionMode.sparse,
    List<int>? typeIds,
  }) : fields = List.unmodifiable(fields),
       typeIds = List.unmodifiable(
         typeIds ?? List.generate(fields.length, (i) => i),
       ) {
    if (this.typeIds.length != fields.length) {
      throw ArgumentError('Union typeIds length must match field count');
    }
    final seen = <int>{};
    for (final id in this.typeIds) {
      if (id < 0 || id > 127) throw RangeError.range(id, 0, 127, 'typeId');
      if (!seen.add(id)) throw ArgumentError('Duplicate union type id: $id');
    }
  }
  final List<ArrowField> fields;
  final ArrowUnionMode mode;
  final List<int> typeIds;

  /// Child field for [typeId], or null when undeclared.
  ArrowField? fieldForTypeId(int typeId) {
    final index = typeIds.indexOf(typeId);
    return index < 0 ? null : fields[index];
  }

  @override
  Map<String, Object?> toJson() => {
    'kind': 'union',
    'mode': mode.name,
    'typeIds': typeIds,
    'fields': fields.map((f) => f.toJson()).toList(),
  };
}

/// Calendar interval in the given [unit].
final class ArrowIntervalType extends ArrowDataType {
  const ArrowIntervalType(this.unit);
  final ArrowIntervalUnit unit;
  @override
  Map<String, Object?> toJson() => {'kind': 'interval', 'unit': unit.name};
}

/// Run-end encoded data. [runEndsField] must be a non-nullable int16, int32,
/// or int64 field. Arrays of this type hold logical per-row values.
final class ArrowRunEndEncodedType extends ArrowDataType {
  ArrowRunEndEncodedType(this.runEndsField, this.valuesField) {
    final type = runEndsField.type;
    if (type is! ArrowIntegerType ||
        !type.signed ||
        type.bitWidth < 16 ||
        type.bitWidth > 64 ||
        runEndsField.nullable) {
      throw ArgumentError.value(
        runEndsField,
        'runEndsField',
        'must be a non-nullable int16, int32, or int64 field',
      );
    }
  }
  final ArrowField runEndsField;
  final ArrowField valuesField;
  @override
  Map<String, Object?> toJson() => {
    'kind': 'runEndEncoded',
    'runEnds': runEndsField.toJson(),
    'values': valuesField.toJson(),
  };
}

bool _deepEquals(Object? a, Object? b) {
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every((k) => b.containsKey(k) && _deepEquals(a[k], b[k]));
  }
  if (a is List && b is List) {
    return a.length == b.length &&
        List.generate(a.length, (i) => i).every((i) => _deepEquals(a[i], b[i]));
  }
  return a == b;
}

int _deepHash(Object? value) {
  if (value is Map) {
    return Object.hashAllUnordered(
      value.entries.map((e) => Object.hash(e.key, _deepHash(e.value))),
    );
  }
  if (value is List) return Object.hashAll(value.map(_deepHash));
  return value.hashCode;
}

Map<String, Object?> _stringObjectMap(Object? value, String path) {
  if (value is! Map) throw FormatException('$path must be an object');
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      throw FormatException('$path keys must be strings');
    }
    result[entry.key as String] = entry.value;
  }
  return result;
}

Map<String, String> _stringMap(Object? value) {
  if (value == null) return const {};
  final map = _stringObjectMap(value, 'dtype.entriesMetadata');
  return {
    for (final MapEntry(:key, :value) in map.entries)
      key: value is String
          ? value
          : throw FormatException(
              'dtype.entriesMetadata.$key must be a string',
            ),
  };
}
