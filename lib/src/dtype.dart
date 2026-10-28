import 'value.dart';

/// A level of support that the binding offers for a [DType].
enum DTypeCapability {
  /// The type can be described and round-tripped as a schema descriptor.
  descriptor,

  /// Values of the type can be created as literals or scalars.
  literal,

  /// Columns of the type can be imported from Arrow data.
  import,

  /// Columns of the type can be exported to Arrow data.
  export,

  /// Expressions and Series can be cast to the type.
  cast,

  /// Compute kernels are expected to accept the type.
  kernels,
}

/// The set of [DTypeCapability] levels supported for a data type.
///
/// These are static Dart-side declarations. Compare them with
/// `Polars.nativeCapabilitiesSync` when exact native support matters.
final class DTypeCapabilities {
  /// Creates a capability set with each level given explicitly.
  const DTypeCapabilities({
    required this.descriptor,
    required this.literal,
    required this.import,
    required this.export,
    required this.cast,
    required this.kernels,
  });

  /// Creates a capability set that supports every level.
  const DTypeCapabilities.full()
    : this(
        descriptor: true,
        literal: true,
        import: true,
        export: true,
        cast: true,
        kernels: true,
      );

  /// Whether the type can be used as a schema descriptor.
  final bool descriptor;

  /// Whether literal values of the type can be created.
  final bool literal;

  /// Whether Arrow data of the type can be imported.
  final bool import;

  /// Whether data of the type can be exported to Arrow.
  final bool export;

  /// Whether values can be cast to the type.
  final bool cast;

  /// Whether compute kernels accept the type.
  final bool kernels;

  /// Returns whether [capability] is supported by this set.
  bool supports(DTypeCapability capability) => switch (capability) {
    DTypeCapability.descriptor => descriptor,
    DTypeCapability.literal => literal,
    DTypeCapability.import => import,
    DTypeCapability.export => export,
    DTypeCapability.cast => cast,
    DTypeCapability.kernels => kernels,
  };
}

/// A Polars data type descriptor.
///
/// Descriptors are immutable values compared by their JSON form. Having a
/// descriptor does not imply that values or kernels are available; check
/// [capabilities] first.
sealed class DType {
  /// Base constructor for subclasses.
  const DType();

  /// The protocol name of this type, such as `int64` or `list`.
  String get kind;

  /// Encodes this descriptor in the native protocol JSON form.
  Map<String, Object?> toJson();

  /// The operations that this binding supports for this type.
  DTypeCapabilities get capabilities => const DTypeCapabilities.full();

  /// Decodes a descriptor from its protocol JSON form.
  ///
  /// Throws a [FormatException] when the `kind` is not recognized.
  static DType fromJson(Map<String, Object?> json) {
    final kind = json['kind'];
    final simple = _simple[kind];
    if (simple != null) return simple;
    return switch (kind) {
      'decimal' => DecimalType(
        precision: json['precision'] as int,
        scale: json['scale'] as int,
      ),
      'datetime' => DateTimeType(
        TimeUnit.fromJson(json['unit'] as String),
        timeZone: json['timeZone'] as String?,
      ),
      'duration' => DurationType(TimeUnit.fromJson(json['unit'] as String)),
      'array' => ArrayType(
        fromJson((json['inner'] as Map).cast()),
        json['width'] as int,
      ),
      'list' => ListType(fromJson((json['inner'] as Map).cast())),
      'object' => ObjectType(json['label'] as String),
      'unknown' => UnknownType.fromJson(json),
      'categorical' => CategoricalType(
        name: json['name'] as String,
        namespace: json['namespace'] as String,
        hash: _parseUnsigned64(json['hash'], 'hash'),
        physical: CategoricalPhysical.fromJson(json['physical'] as String),
      ),
      'enum' => EnumType((json['categories'] as List).cast<String>()),
      'struct' => StructType(
        (json['fields'] as List).map((field) {
          final map = (field as Map).cast<String, Object?>();
          return Field(
            map['name'] as String,
            fromJson((map['dtype'] as Map).cast<String, Object?>()),
          );
        }),
      ),
      'extension' => ExtensionType(
        json['name'] as String,
        fromJson((json['storage'] as Map).cast<String, Object?>()),
        metadata: json['metadata'] as String?,
      ),
      _ => throw FormatException('Unknown Polars datatype kind: $kind'),
    };
  }

  static const Map<Object?, DType> _simple = {
    'null': NullType(),
    'boolean': BooleanType(),
    'uint8': UInt8Type(),
    'uint16': UInt16Type(),
    'uint32': UInt32Type(),
    'uint64': UInt64Type(),
    'uint128': UInt128Type(),
    'int8': Int8Type(),
    'int16': Int16Type(),
    'int32': Int32Type(),
    'int64': Int64Type(),
    'int128': Int128Type(),
    'float16': Float16Type(),
    'float32': Float32Type(),
    'float64': Float64Type(),
    'string': StringType(),
    'binary': BinaryType(),
    'binaryOffset': BinaryOffsetType(),
    'date': DateType(),
    'time': TimeType(),
  };

  @override
  bool operator ==(Object other) =>
      other is DType && jsonEquals(toJson(), other.toJson());
  @override
  int get hashCode => jsonHash(toJson());
  @override
  String toString() => canonicalJson(toJson());
}

abstract base class _SimpleType extends DType {
  const _SimpleType();
  @override
  Map<String, Object?> toJson() => {'kind': kind};
}

/// The Polars `Null` type, whose values are all null.
final class NullType extends _SimpleType {
  /// Creates the null type descriptor.
  const NullType();
  @override
  String get kind => 'null';
}

/// The Polars `Boolean` type.
final class BooleanType extends _SimpleType {
  /// Creates the boolean type descriptor.
  const BooleanType();
  @override
  String get kind => 'boolean';
}

/// The Polars `UInt8` type: unsigned 8-bit integers.
final class UInt8Type extends _SimpleType {
  /// Creates the unsigned 8-bit integer type descriptor.
  const UInt8Type();
  @override
  String get kind => 'uint8';
}

/// The Polars `UInt16` type: unsigned 16-bit integers.
final class UInt16Type extends _SimpleType {
  /// Creates the unsigned 16-bit integer type descriptor.
  const UInt16Type();
  @override
  String get kind => 'uint16';
}

/// The Polars `UInt32` type: unsigned 32-bit integers.
final class UInt32Type extends _SimpleType {
  /// Creates the unsigned 32-bit integer type descriptor.
  const UInt32Type();
  @override
  String get kind => 'uint32';
}

/// The Polars `UInt64` type: unsigned 64-bit integers.
final class UInt64Type extends _SimpleType {
  /// Creates the unsigned 64-bit integer type descriptor.
  const UInt64Type();
  @override
  String get kind => 'uint64';
}

/// The Polars `UInt128` type: unsigned 128-bit integers.
final class UInt128Type extends _SimpleType {
  /// Creates the unsigned 128-bit integer type descriptor.
  const UInt128Type();
  @override
  String get kind => 'uint128';
}

/// The Polars `Int8` type: signed 8-bit integers.
final class Int8Type extends _SimpleType {
  /// Creates the signed 8-bit integer type descriptor.
  const Int8Type();
  @override
  String get kind => 'int8';
}

/// The Polars `Int16` type: signed 16-bit integers.
final class Int16Type extends _SimpleType {
  /// Creates the signed 16-bit integer type descriptor.
  const Int16Type();
  @override
  String get kind => 'int16';
}

/// The Polars `Int32` type: signed 32-bit integers.
final class Int32Type extends _SimpleType {
  /// Creates the signed 32-bit integer type descriptor.
  const Int32Type();
  @override
  String get kind => 'int32';
}

/// The Polars `Int64` type: signed 64-bit integers.
final class Int64Type extends _SimpleType {
  /// Creates the signed 64-bit integer type descriptor.
  const Int64Type();
  @override
  String get kind => 'int64';
}

/// The Polars `Int128` type: signed 128-bit integers.
final class Int128Type extends _SimpleType {
  /// Creates the signed 128-bit integer type descriptor.
  const Int128Type();
  @override
  String get kind => 'int128';
}

/// The Polars `Float16` type: IEEE 754 half-precision floats.
final class Float16Type extends _SimpleType {
  /// Creates the 16-bit float type descriptor.
  const Float16Type();
  @override
  String get kind => 'float16';
}

/// The Polars `Float32` type: IEEE 754 single-precision floats.
final class Float32Type extends _SimpleType {
  /// Creates the 32-bit float type descriptor.
  const Float32Type();
  @override
  String get kind => 'float32';
}

/// The Polars `Float64` type: IEEE 754 double-precision floats.
final class Float64Type extends _SimpleType {
  /// Creates the 64-bit float type descriptor.
  const Float64Type();
  @override
  String get kind => 'float64';
}

/// The Polars `String` type: UTF-8 text.
final class StringType extends _SimpleType {
  /// Creates the string type descriptor.
  const StringType();
  @override
  String get kind => 'string';
}

/// The Polars `Binary` type: arbitrary byte sequences.
final class BinaryType extends _SimpleType {
  /// Creates the binary type descriptor.
  const BinaryType();
  @override
  String get kind => 'binary';
}

/// The Polars `BinaryOffset` type: offset-based binary storage.
final class BinaryOffsetType extends _SimpleType {
  /// Creates the binary-offset type descriptor.
  const BinaryOffsetType();
  @override
  String get kind => 'binaryOffset';
}

/// The Polars `Date` type: calendar dates without a time of day.
final class DateType extends _SimpleType {
  /// Creates the date type descriptor.
  const DateType();
  @override
  String get kind => 'date';
}

/// The Polars `Time` type: a time of day without a date.
final class TimeType extends _SimpleType {
  /// Creates the time type descriptor.
  const TimeType();
  @override
  String get kind => 'time';
}

/// The Polars `Object` type for opaque values. Descriptor-only.
final class ObjectType extends DType {
  /// Creates an object type descriptor with a [label].
  const ObjectType(this.label);

  /// Label identifying the opaque object type.
  final String label;
  @override
  String get kind => 'object';
  @override
  Map<String, Object?> toJson() => {'kind': kind, 'label': label};
  @override
  DTypeCapabilities get capabilities => const DTypeCapabilities(
    descriptor: true,
    literal: false,
    import: false,
    export: false,
    cast: false,
    kernels: false,
  );
}

/// The flavour of a not-yet-resolved [UnknownType].
enum UnknownKind {
  /// Any type may result.
  any,

  /// A float literal whose final width is not yet known.
  float,

  /// A string literal whose final type is not yet known.
  string,

  /// An integer literal whose final width is not yet known.
  integer,
}

/// A placeholder type that Polars has not yet resolved. Descriptor-only.
final class UnknownType extends DType {
  const UnknownType._(this.unknownKind, this.value);

  /// Creates an unknown type that may resolve to any type.
  const UnknownType.any() : this._(UnknownKind.any, null);

  /// Creates an unknown float type.
  const UnknownType.float() : this._(UnknownKind.float, null);

  /// Creates an unknown string type.
  const UnknownType.string() : this._(UnknownKind.string, null);

  /// Creates an unknown integer type carrying the literal [value].
  ///
  /// Throws an [ArgumentError] when [value] does not fit in signed 128 bits.
  factory UnknownType.integer(BigInt value) {
    _requireSigned128(value, 'value');
    return UnknownType._(UnknownKind.integer, value);
  }

  /// Decodes an unknown type from its protocol JSON form.
  factory UnknownType.fromJson(Map<String, Object?> json) {
    final kind = UnknownKind.values.firstWhere(
      (kind) => kind.name == json['unknownKind'],
      orElse: () => throw FormatException(
        'Unknown Polars unknownKind: ${json['unknownKind']}',
      ),
    );
    final rawValue = json['value'];
    if (kind == UnknownKind.integer) {
      if (rawValue is! String) {
        throw const FormatException('Integer unknown requires a decimal value');
      }
      final value = BigInt.tryParse(rawValue);
      if (value == null || value.toString() != rawValue) {
        throw const FormatException(
          'Unknown integer value must be canonical decimal',
        );
      }
      try {
        return UnknownType.integer(value);
      } on ArgumentError catch (error) {
        throw FormatException('Unknown integer is outside i128: $error');
      }
    }
    if (rawValue != null || json.containsKey('value')) {
      throw FormatException('${kind.name} unknown must not have a value');
    }
    return switch (kind) {
      UnknownKind.any => const UnknownType.any(),
      UnknownKind.float => const UnknownType.float(),
      UnknownKind.string => const UnknownType.string(),
      UnknownKind.integer => throw StateError('handled above'),
    };
  }

  /// Which kind of unresolved type this is.
  final UnknownKind unknownKind;

  /// The integer literal for [UnknownKind.integer], otherwise `null`.
  final BigInt? value;
  @override
  String get kind => 'unknown';
  @override
  Map<String, Object?> toJson() => {
    'kind': kind,
    'unknownKind': unknownKind.name,
    if (value != null) 'value': value.toString(),
  };
  @override
  DTypeCapabilities get capabilities => const DTypeCapabilities(
    descriptor: true,
    literal: false,
    import: false,
    export: false,
    cast: false,
    kernels: false,
  );
}

/// The resolution of temporal types such as [DateTimeType].
enum TimeUnit {
  /// Millisecond resolution.
  milliseconds('milliseconds'),

  /// Microsecond resolution.
  microseconds('microseconds'),

  /// Nanosecond resolution.
  nanoseconds('nanoseconds');

  const TimeUnit(this.json);

  /// The protocol name of this unit.
  final String json;

  /// Returns the unit whose protocol name is [value].
  static TimeUnit fromJson(String value) =>
      values.firstWhere((unit) => unit.json == value);
}

/// The Polars `Decimal` type: fixed-point numbers.
final class DecimalType extends DType {
  /// Creates a decimal type with [precision] total digits (1 to 38) and
  /// [scale] fractional digits (0 to [precision]).
  ///
  /// Throws a [RangeError] when either value is out of range.
  DecimalType({required this.precision, required this.scale}) {
    if (precision < 1 || precision > 38) {
      throw RangeError.range(precision, 1, 38, 'precision');
    }
    if (scale < 0 || scale > precision) {
      throw RangeError.range(scale, 0, precision, 'scale');
    }
  }

  /// Total number of significant digits.
  final int precision;

  /// Number of digits after the decimal point.
  final int scale;
  @override
  String get kind => 'decimal';
  @override
  Map<String, Object?> toJson() => {
    'kind': kind,
    'precision': precision,
    'scale': scale,
  };
}

/// The Polars `Datetime` type: a timestamp at a given [unit].
final class DateTimeType extends DType {
  /// Creates a datetime type with [unit] resolution and optional [timeZone].
  const DateTimeType(this.unit, {this.timeZone});

  /// The timestamp resolution.
  final TimeUnit unit;

  /// The time zone name, or `null` for naive datetimes.
  final String? timeZone;
  @override
  String get kind => 'datetime';
  @override
  Map<String, Object?> toJson() => {
    'kind': kind,
    'unit': unit.json,
    if (timeZone != null) 'timeZone': timeZone,
  };
}

/// The Polars `Duration` type: an elapsed time at a given [unit].
final class DurationType extends DType {
  /// Creates a duration type with [unit] resolution.
  const DurationType(this.unit);

  /// The duration resolution.
  final TimeUnit unit;
  @override
  String get kind => 'duration';
  @override
  Map<String, Object?> toJson() => {'kind': kind, 'unit': unit.json};
}

/// The Polars `Array` type: fixed-width lists of [inner] values.
///
/// Supports descriptors and casts only.
final class ArrayType extends DType {
  /// Creates an array type of [width] elements of type [inner].
  ///
  /// [width] must be positive. It is checked when the type is encoded.
  const ArrayType(this.inner, this.width);

  /// The element type.
  final DType inner;

  /// The number of elements in every array value.
  final int width;
  @override
  String get kind => 'array';
  @override
  Map<String, Object?> toJson() {
    if (width <= 0) throw RangeError.value(width, 'width', 'must be positive');
    return {'kind': kind, 'inner': inner.toJson(), 'width': width};
  }

  @override
  DTypeCapabilities get capabilities => _descriptorAndCastOnly;
}

/// The Polars `List` type: variable-length lists of [inner] values.
///
/// Supports descriptors and casts only.
final class ListType extends DType {
  /// Creates a list type with elements of type [inner].
  const ListType(this.inner);

  /// The element type.
  final DType inner;
  @override
  String get kind => 'list';
  @override
  Map<String, Object?> toJson() => {'kind': kind, 'inner': inner.toJson()};
  @override
  DTypeCapabilities get capabilities => _descriptorAndCastOnly;
}

/// The physical integer width used to store categorical codes.
enum CategoricalPhysical {
  /// 8-bit category codes.
  uint8('uint8'),

  /// 16-bit category codes.
  uint16('uint16'),

  /// 32-bit category codes.
  uint32('uint32');

  const CategoricalPhysical(this.json);

  /// The protocol name of this width.
  final String json;

  /// Returns the width whose protocol name is [value].
  ///
  /// Throws a [FormatException] for unknown names.
  static CategoricalPhysical fromJson(String value) => values.firstWhere(
    (physical) => physical.json == value,
    orElse: () => throw FormatException('Unknown categorical physical: $value'),
  );
}

/// The Polars `Categorical` type. Descriptor-only.
final class CategoricalType extends DType {
  /// Creates a categorical type descriptor.
  ///
  /// Throws an [ArgumentError] when [hash] does not fit in unsigned 64 bits.
  CategoricalType({
    required this.name,
    required this.namespace,
    required BigInt hash,
    required this.physical,
  }) : hash = hash {
    _requireUnsigned64(hash, 'hash');
  }

  /// The name of the category mapping.
  final String name;

  /// The namespace of the category mapping.
  final String namespace;

  /// The unsigned 64-bit hash identifying the category mapping.
  final BigInt hash;

  /// The integer width used to store category codes.
  final CategoricalPhysical physical;
  @override
  String get kind => 'categorical';
  @override
  Map<String, Object?> toJson() => {
    'kind': kind,
    'name': name,
    'namespace': namespace,
    'hash': hash.toString(),
    'physical': physical.json,
  };
  @override
  DTypeCapabilities get capabilities => _descriptorOnly;
}

/// The Polars `Enum` type: a fixed, ordered set of string categories.
///
/// Descriptor-only.
final class EnumType extends DType {
  /// Creates an enum type from unique [categories].
  ///
  /// Throws an [ArgumentError] when categories repeat.
  EnumType(Iterable<String> categories)
    : categories = List.unmodifiable(categories) {
    if (this.categories.toSet().length != this.categories.length) {
      throw ArgumentError.value(categories, 'categories', 'must be unique');
    }
  }

  /// The allowed categories, in order.
  final List<String> categories;
  @override
  String get kind => 'enum';
  @override
  Map<String, Object?> toJson() => {'kind': kind, 'categories': categories};
  @override
  DTypeCapabilities get capabilities => _descriptorOnly;
}

/// A named, typed member of a [StructType].
final class Field {
  /// Creates a field called [name] with type [dtype].
  const Field(this.name, this.dtype);

  /// The field name.
  final String name;

  /// The field type.
  final DType dtype;

  /// Encodes this field in the native protocol JSON form.
  Map<String, Object?> toJson() => {'name': name, 'dtype': dtype.toJson()};
  @override
  bool operator ==(Object other) =>
      other is Field && name == other.name && dtype == other.dtype;
  @override
  int get hashCode => Object.hash(name, dtype);
}

/// The Polars `Struct` type: a record of named [fields]. Descriptor-only.
final class StructType extends DType {
  /// Creates a struct type from [fields] with unique names.
  ///
  /// Throws an [ArgumentError] when field names repeat.
  StructType(Iterable<Field> fields) : fields = List.unmodifiable(fields) {
    if (this.fields.map((field) => field.name).toSet().length !=
        this.fields.length) {
      throw ArgumentError.value(fields, 'fields', 'names must be unique');
    }
  }

  /// The struct members, in order.
  final List<Field> fields;
  @override
  String get kind => 'struct';
  @override
  Map<String, Object?> toJson() => {
    'kind': kind,
    'fields': fields.map((field) => field.toJson()).toList(),
  };
  @override
  DTypeCapabilities get capabilities => _descriptorOnly;
}

/// A Polars extension type layered over a [storage] type. Descriptor-only.
final class ExtensionType extends DType {
  /// Creates an extension type called [name] stored as [storage].
  const ExtensionType(this.name, this.storage, {this.metadata});

  /// The extension type name.
  final String name;

  /// The underlying storage type.
  final DType storage;

  /// Optional serialized extension metadata.
  final String? metadata;
  @override
  String get kind => 'extension';
  @override
  DTypeCapabilities get capabilities => const DTypeCapabilities(
    descriptor: true,
    literal: false,
    import: false,
    export: false,
    cast: false,
    kernels: false,
  );
  @override
  Map<String, Object?> toJson() => {
    'kind': kind,
    'name': name,
    'storage': storage.toJson(),
    if (metadata != null) 'metadata': metadata,
  };
}

/// The 20 parameterless data types, from [NullType] through [TimeType].
const List<DType> simpleDTypes = [
  NullType(),
  BooleanType(),
  UInt8Type(),
  UInt16Type(),
  UInt32Type(),
  UInt64Type(),
  UInt128Type(),
  Int8Type(),
  Int16Type(),
  Int32Type(),
  Int64Type(),
  Int128Type(),
  Float16Type(),
  Float32Type(),
  Float64Type(),
  StringType(),
  BinaryType(),
  BinaryOffsetType(),
  DateType(),
  TimeType(),
];

const DTypeCapabilities _descriptorAndCastOnly = DTypeCapabilities(
  descriptor: true,
  literal: false,
  import: false,
  export: false,
  cast: true,
  kernels: false,
);

const DTypeCapabilities _descriptorOnly = DTypeCapabilities(
  descriptor: true,
  literal: false,
  import: false,
  export: false,
  cast: false,
  kernels: false,
);

/// One representative for each of the 31 descriptors advertised by protocol
/// v2. Parameterized representatives are illustrative; inspect
/// [DType.capabilities] before attempting copied import/export or literals.
final List<DType> allDTypes = List.unmodifiable([
  ...simpleDTypes.take(20),
  DecimalType(precision: 38, scale: 0),
  const DateTimeType(TimeUnit.microseconds),
  const DurationType(TimeUnit.microseconds),
  ArrayType(const NullType(), 1),
  const ListType(NullType()),
  const ObjectType('object'),
  CategoricalType(
    name: 'category',
    namespace: '',
    hash: BigInt.zero,
    physical: CategoricalPhysical.uint32,
  ),
  EnumType(const []),
  StructType(const []),
  const ExtensionType('extension', NullType()),
  const UnknownType.any(),
]);

BigInt _parseUnsigned64(Object? raw, String name) {
  if (raw is! String) throw FormatException('$name must be a decimal string');
  final value = BigInt.tryParse(raw);
  if (value == null || value.toString() != raw) {
    throw FormatException('$name must be canonical decimal');
  }
  try {
    _requireUnsigned64(value, name);
  } on ArgumentError catch (error) {
    throw FormatException('$name is outside u64: $error');
  }
  return value;
}

void _requireSigned128(BigInt value, String name) {
  final minimum = -(BigInt.one << 127);
  final maximum = (BigInt.one << 127) - BigInt.one;
  if (value < minimum || value > maximum) {
    throw ArgumentError.value(value, name, 'must fit signed 128-bit');
  }
}

void _requireUnsigned64(BigInt value, String name) {
  final maximum = (BigInt.one << 64) - BigInt.one;
  if (value < BigInt.zero || value > maximum) {
    throw ArgumentError.value(value, name, 'must fit unsigned 64-bit');
  }
}
