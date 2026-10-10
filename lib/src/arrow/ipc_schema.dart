part of 'ipc.dart';

_FbTableObject _encodeSchema(ArrowSchema schema) =>
    _schemaTable(_ipcSchema(schema));

_IpcSchema _decodeSchema(_FbTableView table, ArrowIpcLimits limits) {
  late final _SchemaDescriptor decoded;
  try {
    decoded = _readSchema(table, limits);
  } on ArgumentError catch (error) {
    throw FormatException('Invalid IPC schema: $error');
  }
  final ids = <int>[];
  void visit(_IpcField field) {
    if (field.dictionaryId != null) ids.add(field.dictionaryId!);
    for (final child in field.children) {
      visit(child);
    }
  }

  for (final field in decoded.fields) {
    visit(field);
  }
  return _IpcSchema(decoded.schema, ids);
}

// Arrow Schema.fbs field slots and union IDs, not a private wire format.
final class _IpcField {
  const _IpcField(this.field, this.children, {this.dictionaryId});
  final ArrowField field;
  final List<_IpcField> children;
  final int? dictionaryId;
}

final class _SchemaDescriptor {
  const _SchemaDescriptor(this.schema, this.fields);
  final ArrowSchema schema;
  final List<_IpcField> fields;
}

ArrowDataType _storageType(ArrowDataType type) {
  var depth = 0;
  while (type is ArrowExtensionType || type is ArrowDictionaryType) {
    if (++depth > 64) {
      throw UnsupportedError('IPC wrapper nesting exceeds 64');
    }
    type = switch (type) {
      ArrowExtensionType(:final storageType) => storageType,
      ArrowDictionaryType(:final valueType) => valueType,
      _ => type,
    };
  }
  return type;
}

ArrowDictionaryType? _dictionaryType(ArrowDataType type) {
  var depth = 0;
  while (type is ArrowExtensionType) {
    if (++depth > 64) {
      throw UnsupportedError('IPC wrapper nesting exceeds 64');
    }
    type = type.storageType;
  }
  return type is ArrowDictionaryType ? type : null;
}

List<ArrowField> _childFields(ArrowDataType input) {
  final type = _storageType(input);
  return switch (type) {
    ArrowListType(:final field) => [field],
    ArrowFixedSizeListType(:final field) => [field],
    ArrowStructType(:final fields) => fields,
    ArrowMapType() => [type.entriesField],
    ArrowUnionType(:final fields) => fields,
    ArrowRunEndEncodedType(:final runEndsField, :final valuesField) => [
      runEndsField,
      valuesField,
    ],
    _ => const [],
  };
}

_SchemaDescriptor _ipcSchema(ArrowSchema schema) {
  var nextId = 0;
  _IpcField field(ArrowField value, int depth) {
    if (depth > 64) throw ArgumentError('IPC schema nesting exceeds 64');
    final dictionary = _dictionaryType(value.type);
    final id = dictionary == null ? null : nextId++;
    if (dictionary != null && _dictionaryType(dictionary.valueType) != null) {
      throw UnsupportedError(
        'Dictionary-of-dictionary IPC fields are unsupported',
      );
    }
    return _IpcField(value, [
      for (final child in _childFields(value.type)) field(child, depth + 1),
    ], dictionaryId: id);
  }

  return _SchemaDescriptor(schema, [
    for (final value in schema.fields) field(value, 0),
  ]);
}

_FbSlot _metadataTable(Map<String, String> metadata) => _fbVector([
  for (final entry in metadata.entries)
    _FbTableObject({0: _fbString(entry.key), 1: _fbString(entry.value)}),
]);

_FbTableObject _schemaTable(_SchemaDescriptor schema) => _FbTableObject({
  0: _fbI16(0),
  1: _fbVector([for (final field in schema.fields) _fieldTable(field)]),
  if (schema.schema.metadata.isNotEmpty)
    2: _metadataTable(schema.schema.metadata),
});

_FbTableObject _fieldTable(_IpcField descriptor) {
  final field = descriptor.field;
  final metadata = Map<String, String>.of(field.metadata);
  if (metadata.containsKey('ARROW:extension:name') ||
      metadata.containsKey('ARROW:extension:metadata')) {
    throw ArgumentError(
      'Use ArrowExtensionType instead of reserved extension metadata keys',
    );
  }
  _validateIpcWrappers(field.type);
  var type = field.type;
  if (type is ArrowExtensionType) {
    metadata['ARROW:extension:name'] = type.name;
    if (type.metadata != null) {
      metadata['ARROW:extension:metadata'] = type.metadata!;
    }
  }
  final dictionary = _dictionaryType(type);
  type = _storageType(type);
  final (id, table) = _typeTable(type);
  return _FbTableObject({
    0: _fbString(field.name),
    1: _fbBool(field.nullable),
    2: _fbU8(id),
    3: _FbRef(table),
    if (dictionary != null)
      4: _fbTable({
        0: _fbI64(descriptor.dictionaryId!),
        1: _FbRef(_integerTable(dictionary.indexType as ArrowIntegerType)),
        2: _fbBool(dictionary.ordered),
      }),
    if (descriptor.children.isNotEmpty)
      5: _fbVector([
        for (final child in descriptor.children) _fieldTable(child),
      ]),
    if (metadata.isNotEmpty) 6: _metadataTable(metadata),
  });
}

void _validateIpcWrappers(ArrowDataType type) {
  // One field has only one extension annotation. A dictionary of extension
  // values cannot preserve its wrapper order in that representation.
  if (type is ArrowExtensionType) {
    if (type.storageType is ArrowExtensionType) {
      throw UnsupportedError('IPC cannot preserve stacked extension types');
    }
    _validateIpcWrappers(type.storageType);
  } else if (type is ArrowDictionaryType &&
      type.valueType is ArrowExtensionType) {
    throw UnsupportedError(
      'Use extension-over-dictionary for standard Arrow IPC',
    );
  }
}

_FbTableObject _integerTable(ArrowIntegerType type) {
  if (type.bitWidth > 64) {
    throw UnsupportedError(
      'int128/uint128 are binding extensions, not Arrow IPC integer types',
    );
  }
  return _FbTableObject({0: _fbI32(type.bitWidth), 1: _fbBool(type.signed)});
}

(int, _FbTableObject) _typeTable(ArrowDataType type) {
  const empty = _FbTableObject({});
  return switch (type) {
    ArrowNullType() => (1, empty),
    ArrowIntegerType() => (2, _integerTable(type)),
    ArrowFloatingType(:final bitWidth) => (
      3,
      _FbTableObject({
        0: _fbI16([16, 32, 64].indexOf(bitWidth)),
      }),
    ),
    ArrowBinaryType(:final offsetWidth) => (
      switch (offsetWidth) {
        ArrowOffsetWidth.normal => 4,
        ArrowOffsetWidth.large => 19,
        ArrowOffsetWidth.view => 23,
      },
      empty,
    ),
    ArrowUtf8Type(:final offsetWidth) => (
      switch (offsetWidth) {
        ArrowOffsetWidth.normal => 5,
        ArrowOffsetWidth.large => 20,
        ArrowOffsetWidth.view => 24,
      },
      empty,
    ),
    ArrowBooleanType() => (6, empty),
    ArrowDecimalType(:final precision, :final scale, :final bitWidth) => (
      7,
      _FbTableObject({
        0: _fbI32(precision),
        1: _fbI32(scale),
        2: _fbI32(bitWidth),
      }),
    ),
    _ => _nestedTypeTable(type),
  };
}

(int, _FbTableObject) _nestedTypeTable(ArrowDataType type) {
  const empty = _FbTableObject({});
  return switch (type) {
    ArrowDateType(:final unit) => (8, _FbTableObject({0: _fbI16(unit.index)})),
    ArrowTimeType(:final unit) => (
      9,
      _FbTableObject({
        0: _fbI16(unit.index),
        1: _fbI32(unit.index < 2 ? 32 : 64),
      }),
    ),
    ArrowTimestampType(:final unit, :final timeZone) => (
      10,
      _FbTableObject({
        0: _fbI16(unit.index),
        if (timeZone != null) 1: _fbString(timeZone),
      }),
    ),
    ArrowIntervalType(:final unit) => (
      11,
      _FbTableObject({0: _fbI16(unit.index)}),
    ),
    ArrowListType(:final offsetWidth, :final view) => (
      view
          ? (offsetWidth == ArrowOffsetWidth.large ? 26 : 25)
          : (offsetWidth == ArrowOffsetWidth.large ? 21 : 12),
      empty,
    ),
    ArrowStructType() => (13, empty),
    ArrowUnionType(:final mode, :final typeIds) => (
      14,
      _FbTableObject({0: _fbI16(mode.index), 1: _intVector(typeIds)}),
    ),
    ArrowFixedSizeBinaryType(:final byteWidth) => (
      15,
      _FbTableObject({0: _fbI32(byteWidth)}),
    ),
    ArrowFixedSizeListType(:final size) => (
      16,
      _FbTableObject({0: _fbI32(size)}),
    ),
    ArrowMapType(:final keysSorted) => (
      17,
      _FbTableObject({0: _fbBool(keysSorted)}),
    ),
    ArrowDurationType(:final unit) => (
      18,
      _FbTableObject({0: _fbI16(unit.index)}),
    ),
    ArrowRunEndEncodedType() => (22, empty),
    _ => throw UnsupportedError('Unsupported Arrow IPC datatype $type'),
  };
}

_FbSlot _intVector(List<int> values) {
  final bytes = Uint8List(4 * values.length);
  final data = ByteData.sublistView(bytes);
  for (var i = 0; i < values.length; i++) {
    data.setInt32(4 * i, values[i], Endian.little);
  }
  return _fbStructs(bytes, values.length);
}

Map<String, String> _readMetadata(_FbTableView table, int slot) {
  final result = <String, String>{};
  for (final item in table.tables(slot)) {
    final key = item.string(0);
    if (key == null || result.containsKey(key)) {
      throw const FormatException('Invalid or duplicate IPC metadata key');
    }
    result[key] = item.string(1) ?? '';
  }
  return result;
}

_SchemaDescriptor _readSchema(_FbTableView table, ArrowIpcLimits limits) {
  if (table.i16(0, 0) != 0) {
    throw UnsupportedError('Big-endian Arrow IPC is unsupported');
  }
  var count = 0;
  final dictionaries = <int, ArrowDictionaryType>{};
  _IpcField field(_FbTableView table, int depth) {
    if (depth > limits.maxDepth || ++count > limits.maxFields) {
      throw const FormatException(
        'IPC schema nesting or field count limit exceeded',
      );
    }
    final children = [
      for (final child in table.tables(5)) field(child, depth + 1),
    ];
    final payload = table.table(3);
    if (payload == null) throw const FormatException('Missing IPC field type');
    var type = _readType(table.u8(2, 0), payload, [
      for (final child in children) child.field,
    ]);
    final dictionary = table.table(4);
    int? dictionaryId;
    if (dictionary != null) {
      dictionaryId = dictionary.i64(0, 0);
      if (dictionary.i16(3, 0) != 0) {
        throw const FormatException('Invalid IPC dictionary encoding');
      }
      final index = dictionary.table(1);
      final dtype = ArrowDictionaryType(
        index == null ? ArrowIntegerType(32) : _readInteger(index),
        type,
        ordered: dictionary.boolean(2, false),
      );
      final existing = dictionaries[dictionaryId];
      if (existing != null && existing.valueType != dtype.valueType) {
        throw const FormatException('Conflicting shared IPC dictionary types');
      }
      dictionaries[dictionaryId] = dtype;
      type = dtype;
    }
    final metadata = _readMetadata(table, 6);
    final extension = metadata.remove('ARROW:extension:name');
    if (extension != null) {
      type = ArrowExtensionType(
        extension,
        type,
        metadata: metadata.remove('ARROW:extension:metadata'),
      );
    }
    return _IpcField(
      ArrowField(
        table.string(0) ?? '',
        type,
        nullable: table.boolean(1, false),
        allowEmptyName: true,
        metadata: metadata,
      ),
      children,
      dictionaryId: dictionaryId,
    );
  }

  final fields = [for (final item in table.tables(1)) field(item, 0)];
  return _SchemaDescriptor(
    ArrowSchema(
      [for (final item in fields) item.field],
      allowDuplicateNames: true,
      metadata: _readMetadata(table, 2),
    ),
    fields,
  );
}

ArrowIntegerType _readInteger(_FbTableView table) {
  final width = table.i32(0, 0);
  if (![8, 16, 32, 64].contains(width)) {
    throw FormatException('Invalid standard integer width $width');
  }
  return ArrowIntegerType(width, signed: table.boolean(1, false));
}

T _enumValue<T>(List<T> values, int index, String name) {
  if (index < 0 || index >= values.length) {
    throw FormatException('Unknown IPC $name enum $index');
  }
  return values[index];
}

ArrowDataType _readType(int id, _FbTableView table, List<ArrowField> children) {
  if (![12, 13, 14, 16, 17, 21, 22, 25, 26].contains(id) &&
      children.isNotEmpty) {
    throw const FormatException('Primitive IPC field cannot have children');
  }
  return switch (id) {
    1 => const ArrowNullType(),
    2 => _readInteger(table),
    3 => ArrowFloatingType(
      _enumValue([16, 32, 64], table.i16(0, 0), 'precision'),
    ),
    4 => const ArrowBinaryType(),
    5 => const ArrowUtf8Type(),
    6 => const ArrowBooleanType(),
    7 => ArrowDecimalType(
      table.i32(0, 0),
      table.i32(1, 0),
      bitWidth: table.i32(2, 128),
    ),
    8 => ArrowDateType(
      _enumValue(ArrowDateUnit.values, table.i16(0, 1), 'date unit'),
    ),
    9 => _readTime(table),
    10 => ArrowTimestampType(
      _enumValue(ArrowTimeUnit.values, table.i16(0, 0), 'timestamp unit'),
      timeZone: table.string(1),
    ),
    11 => ArrowIntervalType(
      _enumValue(ArrowIntervalUnit.values, table.i16(0, 0), 'interval unit'),
    ),
    18 => ArrowDurationType(
      _enumValue(ArrowTimeUnit.values, table.i16(0, 1), 'duration unit'),
    ),
    19 => const ArrowBinaryType(ArrowOffsetWidth.large),
    20 => const ArrowUtf8Type(ArrowOffsetWidth.large),
    23 => const ArrowBinaryType(ArrowOffsetWidth.view),
    24 => const ArrowUtf8Type(ArrowOffsetWidth.view),
    _ => _readNestedType(id, table, children),
  };
}

ArrowDataType _readTime(_FbTableView table) {
  final unit = _enumValue(ArrowTimeUnit.values, table.i16(0, 1), 'time unit');
  if (table.i32(1, 32) != (unit.index < 2 ? 32 : 64)) {
    throw const FormatException('Time unit and bit width disagree');
  }
  return ArrowTimeType(unit);
}

ArrowDataType _readNestedType(
  int id,
  _FbTableView table,
  List<ArrowField> children,
) {
  ArrowField single() {
    if (children.length != 1) {
      throw const FormatException('IPC list/map needs one child');
    }
    return children.single;
  }

  switch (id) {
    case 12:
      return ArrowListType(single());
    case 13:
      return ArrowStructType(children, allowDuplicateNames: true);
    case 14:
      final ids = table.structs(1, 4);
      final typeIds = ids.count == 0
          ? List.generate(children.length, (i) => i)
          : [for (var i = 0; i < ids.count; i++) ids.i32(i, 0)];
      return ArrowUnionType(
        children,
        typeIds: typeIds,
        mode: _enumValue(ArrowUnionMode.values, table.i16(0, 0), 'union mode'),
      );
    case 15:
      return ArrowFixedSizeBinaryType(table.i32(0, 0));
    case 16:
      return ArrowFixedSizeListType(single(), table.i32(0, 0));
    case 17:
      final entries = single();
      final struct = entries.type;
      if (entries.nullable ||
          struct is! ArrowStructType ||
          struct.fields.length != 2) {
        throw const FormatException('Invalid IPC map entry layout');
      }
      return ArrowMapType(
        struct.fields[0],
        struct.fields[1],
        keysSorted: table.boolean(0, false),
        entriesName: entries.name,
        entriesMetadata: entries.metadata,
        allowDuplicateNames: true,
      );
    case 21:
      return ArrowListType(single(), offsetWidth: ArrowOffsetWidth.large);
    case 22:
      if (children.length != 2) {
        throw const FormatException(
          'Run-end encoded IPC requires two children',
        );
      }
      return ArrowRunEndEncodedType(children[0], children[1]);
    case 25:
      return ArrowListType(single(), view: true);
    case 26:
      return ArrowListType(
        single(),
        offsetWidth: ArrowOffsetWidth.large,
        view: true,
      );
    default:
      throw UnsupportedError('Unknown Arrow IPC type ID $id');
  }
}
