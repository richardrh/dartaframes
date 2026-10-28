import 'dart:convert';
import 'dart:collection';

import 'array.dart';
import 'batch.dart';
import 'schema.dart';
import 'type.dart';
import 'value.dart';

/// JSON codec for the protocol's copied, binding-owned logical column batches.
///
/// Wide integers and temporal counters are decimal strings. Floating-point
/// values carry raw hexadecimal IEEE bits, preserving all bit patterns.
final class OwnedBatchJsonCodec {
  const OwnedBatchJsonCodec({
    this.maxNestingDepth = 64,
    this.maxCollectionSize = 100000,
    this.maxSourceLength = 16 * 1024 * 1024,
  });

  final int maxNestingDepth;
  final int maxCollectionSize;
  final int maxSourceLength;

  String encode(RecordBatch batch) => jsonEncode(toJson(batch));

  RecordBatch decode(String source) {
    if (source.length > maxSourceLength) {
      throw const FormatException('Batch JSON exceeds the source-size limit');
    }
    final value = jsonDecode(source);
    if (value is! Map) {
      throw const FormatException('Batch must be a JSON object');
    }
    return fromJson(value.cast<String, Object?>());
  }

  Map<String, Object?> toJson(RecordBatch batch) => {
    'schema': batch.schema.toJson(),
    'length': batch.length,
    'columns': [
      for (var i = 0; i < batch.columns.length; i++)
        _columnToJson(batch.schema.fields[i], batch.columns[i]),
    ],
  };

  RecordBatch fromJson(Map<String, Object?> json) {
    _checkJsonLimits(json);
    try {
      final schemaJson = json['schema'];
      final columnsJson = json['columns'];
      if (schemaJson is! Map || columnsJson is! List) {
        throw const FormatException('Batch requires schema and columns');
      }
      final declaredLength = json['length'];
      if (json.containsKey('length') && declaredLength is! int) {
        throw const FormatException('Batch length must be an integer');
      }
      if (declaredLength is int && declaredLength < 0) {
        throw const FormatException('Batch length must be non-negative');
      }
      final schema = ArrowSchema.fromJson(schemaJson.cast<String, Object?>());
      if (columnsJson.length != schema.fields.length) {
        throw const FormatException('Batch column count does not match schema');
      }
      final columns = <ArrowArray>[];
      for (var i = 0; i < columnsJson.length; i++) {
        final raw = columnsJson[i];
        if (raw is! Map) {
          throw FormatException('columns[$i] must be an object');
        }
        columns.add(
          _columnFromJson(schema.fields[i], raw.cast<String, Object?>()),
        );
      }
      return RecordBatch(schema, columns, rowCount: declaredLength as int?);
    } on FormatException {
      rethrow;
    } on ArgumentError catch (error) {
      throw FormatException('Invalid batch: $error');
    } on TypeError catch (error) {
      throw FormatException('Invalid batch shape: $error');
    }
  }

  Map<String, Object?> _columnToJson(ArrowField field, ArrowArray array) => {
    'name': field.name,
    'dtype': array.type.toJson(),
    'validity': array.validity,
    'values': array.values
        .map((value) => value == null ? null : _valueToJson(array.type, value))
        .toList(),
    if (array.dictionary case final dictionary?)
      'dictionary': _anonymousArrayToJson(dictionary),
    if (array.nestedDictionaries.isNotEmpty)
      'nestedDictionaries': array.nestedDictionaries
          .map(_anonymousArrayToJson)
          .toList(),
  };

  Map<String, Object?> _anonymousArrayToJson(ArrowArray array) => {
    'dtype': array.type.toJson(),
    'validity': array.validity,
    'values': array.values
        .map((value) => value == null ? null : _valueToJson(array.type, value))
        .toList(),
    if (array.dictionary case final dictionary?)
      'dictionary': _anonymousArrayToJson(dictionary),
    if (array.nestedDictionaries.isNotEmpty)
      'nestedDictionaries': array.nestedDictionaries
          .map(_anonymousArrayToJson)
          .toList(),
  };

  ArrowArray _columnFromJson(ArrowField field, Map<String, Object?> json) {
    if (json['name'] != field.name) {
      throw FormatException(
        'Column name ${json['name']} does not match ${field.name}',
      );
    }
    final dtype = _dtype(json);
    if (dtype != field.type) {
      throw FormatException(
        'Column ${field.name} datatype does not match schema',
      );
    }
    return _arrayFromParts(dtype, json);
  }

  ArrowArray _anonymousArrayFromJson(Map<String, Object?> json) =>
      _arrayFromParts(_dtype(json), json);

  ArrowDataType _dtype(Map<String, Object?> json) {
    final raw = json['dtype'];
    if (raw is! Map) {
      throw const FormatException('Column dtype must be an object');
    }
    return ArrowDataType.fromJson(raw.cast<String, Object?>());
  }

  ArrowArray _arrayFromParts(ArrowDataType dtype, Map<String, Object?> json) {
    final rawValues = json['values'];
    final rawValidity = json['validity'];
    if (rawValues is! List || rawValidity is! List) {
      throw const FormatException('Column values and validity must be lists');
    }
    final validity = rawValidity.map((v) {
      if (v is! bool) {
        throw const FormatException('Validity entries must be booleans');
      }
      return v;
    }).toList();
    if (validity.length != rawValues.length) {
      throw const FormatException(
        'Validity length does not match values length',
      );
    }
    final values = <ArrowValue?>[];
    for (var i = 0; i < rawValues.length; i++) {
      if (!validity[i]) {
        if (rawValues[i] != null) {
          throw FormatException('Invalid value at index $i must be null');
        }
        values.add(null);
      } else {
        if (rawValues[i] == null) {
          throw FormatException('Valid value at index $i is null');
        }
        values.add(_valueFromJson(dtype, rawValues[i]));
      }
    }
    ArrowArray? dictionary;
    final rawDictionary = json['dictionary'];
    if (rawDictionary != null) {
      if (rawDictionary is! Map) {
        throw const FormatException('dictionary must be an object');
      }
      dictionary = _anonymousArrayFromJson(
        rawDictionary.cast<String, Object?>(),
      );
    }
    return ArrowArray(
      dtype,
      values,
      validity: validity,
      dictionary: dictionary,
      nestedDictionaries: _nestedFromJson(json),
    );
  }

  List<ArrowArray> _nestedFromJson(Map<String, Object?> json) {
    if (!json.containsKey('nestedDictionaries')) return const [];
    final raw = json['nestedDictionaries'];
    if (raw is! List) {
      throw const FormatException('nestedDictionaries must be a list');
    }
    return raw.map((entry) {
      if (entry is! Map) {
        throw const FormatException('nested dictionary must be an object');
      }
      return _anonymousArrayFromJson(entry.cast<String, Object?>());
    }).toList();
  }

  void _checkJsonLimits(Object? root) {
    if (maxNestingDepth < 1 || maxCollectionSize < 1 || maxSourceLength < 1) {
      throw ArgumentError('JSON decoding limits must be positive');
    }
    var elementCount = 0;
    final active = HashSet<Object>.identity();

    void visit(Object? value, int depth) {
      if (value is! Map && value is! List) return;
      if (depth > maxNestingDepth) {
        throw const FormatException(
          'Batch JSON exceeds the nesting-depth limit',
        );
      }
      if (!active.add(value as Object)) {
        throw const FormatException('Batch JSON contains a collection cycle');
      }
      final length = value is Map ? value.length : (value as List).length;
      elementCount += length;
      if (length > maxCollectionSize || elementCount > maxCollectionSize) {
        throw const FormatException(
          'Batch JSON exceeds the collection-size limit',
        );
      }
      if (value is Map) {
        for (final entry in value.entries) {
          if (entry.key is! String) {
            throw const FormatException('JSON object keys must be strings');
          }
          visit(entry.value, depth + 1);
        }
      } else {
        for (final child in value as List) {
          visit(child, depth + 1);
        }
      }
      active.remove(value);
    }

    visit(root, 1);
  }
}

Object _valueToJson(ArrowDataType type, ArrowValue value) {
  switch (type) {
    case ArrowNullType():
      throw StateError('Null datatype cannot contain a value');
    case ArrowBooleanType():
      return (value as ArrowBooleanValue).value;
    case ArrowIntegerType():
      return (value as ArrowIntegerValue).value.toString();
    case ArrowFloatingType():
      return {'floatBits': (value as ArrowFloatingValue).hexadecimalBits};
    case ArrowDecimalType():
      return {'unscaled': (value as ArrowDecimalValue).unscaled.toString()};
    case ArrowUtf8Type():
      return (value as ArrowStringValue).value;
    case ArrowBinaryType():
      return {'base64': base64Encode((value as ArrowBinaryValue).bytes)};
    case ArrowDateType() ||
        ArrowTimestampType() ||
        ArrowDurationType() ||
        ArrowTimeType():
      return (value as ArrowTemporalValue).value.toString();
    case final ArrowListType list:
      return (value as ArrowListValue).values
          .map(
            (child) =>
                child == null ? null : _valueToJson(list.field.type, child),
          )
          .toList();
    case final ArrowFixedSizeListType list:
      return (value as ArrowListValue).values
          .map(
            (child) =>
                child == null ? null : _valueToJson(list.field.type, child),
          )
          .toList();
    case final ArrowStructType struct:
      final actual = (value as ArrowStructValue).fields;
      return [
        for (var i = 0; i < actual.length; i++)
          {
            'name': actual[i].name,
            'value': actual[i].value == null
                ? null
                : _valueToJson(struct.fields[i].type, actual[i].value!),
          },
      ];
    case ArrowDictionaryType():
      return (value as ArrowDictionaryIndexValue).index.toString();
    case ArrowFixedSizeBinaryType() ||
        ArrowMapType() ||
        ArrowUnionType() ||
        ArrowIntervalType() ||
        ArrowRunEndEncodedType():
      return _extendedValueToJson(type, value);
    case final ArrowExtensionType extension:
      return {
        'storage': _valueToJson(
          extension.storageType,
          (value as ArrowExtensionValue).storage,
        ),
      };
  }
}

ArrowValue _valueFromJson(ArrowDataType type, Object? json) {
  Map<String, Object?> object() {
    if (json is! Map) {
      throw FormatException('Value for $type must be an object');
    }
    return json.cast<String, Object?>();
  }

  switch (type) {
    case ArrowNullType():
      throw const FormatException('Null datatype cannot contain a valid value');
    case ArrowBooleanType():
      if (json is! bool) {
        throw const FormatException('Boolean value must be a boolean');
      }
      return ArrowBooleanValue(json);
    case ArrowIntegerType():
      return ArrowIntegerValue(_canonicalInteger(json, 'Integer value'));
    case final ArrowFloatingType floating:
      final bits = object()['floatBits'];
      if (bits is! String) {
        throw const FormatException('floatBits must be a string');
      }
      return ArrowFloatingValue(
        floating.bitWidth,
        _floatBits(bits, floating.bitWidth),
      );
    case ArrowDecimalType():
      return ArrowDecimalValue(
        _canonicalInteger(object()['unscaled'], 'Decimal unscaled value'),
      );
    case ArrowUtf8Type():
      if (json is! String) {
        throw const FormatException('String value must be a string');
      }
      return ArrowStringValue(json);
    case ArrowBinaryType():
      final encoded = object()['base64'];
      if (encoded is! String) {
        throw const FormatException('base64 must be a string');
      }
      return ArrowBinaryValue(base64Decode(encoded));
    case ArrowDateType() ||
        ArrowTimestampType() ||
        ArrowDurationType() ||
        ArrowTimeType():
      return ArrowTemporalValue(_canonicalInteger(json, 'Temporal counter'));
    case final ArrowListType list:
      if (json is! List) {
        throw const FormatException('List value must be a list');
      }
      return ArrowListValue(
        json
            .map(
              (child) =>
                  child == null ? null : _valueFromJson(list.field.type, child),
            )
            .toList(),
      );
    case final ArrowFixedSizeListType list:
      if (json is! List) {
        throw const FormatException('Fixed list value must be a list');
      }
      return ArrowListValue(
        json
            .map(
              (child) =>
                  child == null ? null : _valueFromJson(list.field.type, child),
            )
            .toList(),
      );
    case final ArrowStructType struct:
      if (json is! List) {
        throw const FormatException('Struct value must be a list');
      }
      if (json.length != struct.fields.length) {
        throw const FormatException('Struct field count mismatch');
      }
      return ArrowStructValue([
        for (var i = 0; i < json.length; i++)
          () {
            final raw = json[i];
            if (raw is! Map) {
              throw const FormatException('Struct entry must be an object');
            }
            final entry = raw.cast<String, Object?>();
            final name = entry['name'];
            if (name is! String) {
              throw const FormatException('Struct entry name must be a string');
            }
            final rawValue = entry['value'];
            return ArrowStructEntry(
              name,
              rawValue == null
                  ? null
                  : _valueFromJson(struct.fields[i].type, rawValue),
            );
          }(),
      ]);
    case ArrowDictionaryType():
      return ArrowDictionaryIndexValue(
        _canonicalInteger(json, 'Dictionary index'),
      );
    case ArrowFixedSizeBinaryType() ||
        ArrowMapType() ||
        ArrowUnionType() ||
        ArrowIntervalType() ||
        ArrowRunEndEncodedType():
      return _extendedValueFromJson(type, json);
    case final ArrowExtensionType extension:
      final storage = object()['storage'];
      if (storage == null) {
        throw const FormatException('Extension storage cannot be null');
      }
      return ArrowExtensionValue(
        _valueFromJson(extension.storageType, storage),
      );
  }
}

/// Longest accepted decimal integer string: a sign plus the 78 digits of the
/// widest supported magnitude (2^256). Rejecting longer input before parsing
/// bounds BigInt.parse, whose cost grows super-linearly with length.
const int _maxIntegerStringLength = 79;

final RegExp _canonicalIntegerPattern = RegExp(r'^-?(0|[1-9][0-9]*)$');
final RegExp _hexPattern = RegExp(r'^[0-9a-fA-F]+$');

/// Parses a canonical base-10 integer string: no whitespace, plus sign,
/// leading zeros, radix prefix, or negative zero. Range checks against the
/// declared datatype happen later in validateArrowValue.
BigInt _canonicalInteger(Object? json, String what) {
  if (json is! String) {
    throw FormatException('$what must be a decimal string');
  }
  if (json.length > _maxIntegerStringLength) {
    throw FormatException('$what exceeds $_maxIntegerStringLength characters');
  }
  if (_canonicalIntegerPattern.firstMatch(json)?.end != json.length ||
      json == '-0') {
    throw FormatException('$what must be a canonical decimal integer: $json');
  }
  return BigInt.parse(json);
}

/// Parses exactly bitWidth/4 hexadecimal digits of an IEEE bit pattern.
BigInt _floatBits(String bits, int bitWidth) {
  final digits = bitWidth ~/ 4;
  if (bits.length != digits ||
      _hexPattern.firstMatch(bits)?.end != bits.length) {
    throw FormatException(
      'floatBits for float$bitWidth must be exactly $digits hexadecimal digits',
    );
  }
  return BigInt.parse(bits, radix: 16);
}

Object? _nullableToJson(ArrowDataType type, ArrowValue? value) =>
    value == null ? null : _valueToJson(type, value);

ArrowValue? _nullableFromJson(ArrowDataType type, Object? json) =>
    json == null ? null : _valueFromJson(type, json);

Object _extendedValueToJson(ArrowDataType type, ArrowValue value) {
  switch (type) {
    case ArrowFixedSizeBinaryType():
      return {'base64': base64Encode((value as ArrowBinaryValue).bytes)};
    case final ArrowMapType map:
      return [
        for (final entry in (value as ArrowMapValue).entries)
          {
            'key': _valueToJson(map.keyField.type, entry.key),
            'value': _nullableToJson(map.valueField.type, entry.value),
          },
      ];
    case final ArrowUnionType union:
      final tagged = value as ArrowUnionValue;
      return {
        'typeId': tagged.typeId,
        'value': _nullableToJson(
          union.fieldForTypeId(tagged.typeId)!.type,
          tagged.value,
        ),
      };
    case ArrowIntervalType():
      return _intervalToJson(value as ArrowIntervalValue);
    case final ArrowRunEndEncodedType ree:
      return _valueToJson(ree.valuesField.type, value);
    default:
      throw StateError('Unhandled datatype $type');
  }
}

Map<String, Object?> _intervalToJson(ArrowIntervalValue value) =>
    switch (value.unit) {
      ArrowIntervalUnit.yearMonth => {'months': value.months},
      ArrowIntervalUnit.dayTime => {
        'days': value.days,
        'milliseconds': value.milliseconds,
      },
      ArrowIntervalUnit.monthDayNano => {
        'months': value.months,
        'days': value.days,
        'nanoseconds': value.nanoseconds.toString(),
      },
    };

Map<String, Object?> _jsonObject(Object? json, String what) {
  if (json is! Map) throw FormatException('$what must be an object');
  return json.cast<String, Object?>();
}

int _jsonInt(Map<String, Object?> json, String name) {
  final value = json[name];
  if (value is! int) throw FormatException('$name must be an integer');
  return value;
}

ArrowValue _extendedValueFromJson(ArrowDataType type, Object? json) {
  switch (type) {
    case ArrowFixedSizeBinaryType():
      final encoded = _jsonObject(json, 'Binary value')['base64'];
      if (encoded is! String) {
        throw const FormatException('base64 must be a string');
      }
      return ArrowBinaryValue(base64Decode(encoded));
    case final ArrowMapType map:
      if (json is! List) {
        throw const FormatException('Map value must be a list');
      }
      return ArrowMapValue([
        for (final raw in json)
          () {
            final entry = _jsonObject(raw, 'Map entry');
            final key = entry['key'];
            if (key == null) {
              throw const FormatException('Map keys cannot be null');
            }
            return ArrowMapEntry(
              _valueFromJson(map.keyField.type, key),
              _nullableFromJson(map.valueField.type, entry['value']),
            );
          }(),
      ]);
    case final ArrowUnionType union:
      final tagged = _jsonObject(json, 'Union value');
      final typeId = _jsonInt(tagged, 'typeId');
      final field = union.fieldForTypeId(typeId);
      if (field == null) {
        throw FormatException('Undeclared union type id $typeId');
      }
      return ArrowUnionValue(
        typeId,
        _nullableFromJson(field.type, tagged['value']),
      );
    case final ArrowIntervalType interval:
      return _intervalFromJson(interval.unit, _jsonObject(json, 'Interval'));
    case final ArrowRunEndEncodedType ree:
      return _valueFromJson(ree.valuesField.type, json);
    default:
      throw StateError('Unhandled datatype $type');
  }
}

ArrowIntervalValue _intervalFromJson(
  ArrowIntervalUnit unit,
  Map<String, Object?> json,
) {
  switch (unit) {
    case ArrowIntervalUnit.yearMonth:
      return ArrowIntervalValue.yearMonth(_jsonInt(json, 'months'));
    case ArrowIntervalUnit.dayTime:
      return ArrowIntervalValue.dayTime(
        _jsonInt(json, 'days'),
        _jsonInt(json, 'milliseconds'),
      );
    case ArrowIntervalUnit.monthDayNano:
      return ArrowIntervalValue.monthDayNano(
        _jsonInt(json, 'months'),
        _jsonInt(json, 'days'),
        _canonicalInteger(json['nanoseconds'], 'nanoseconds'),
      );
  }
}
