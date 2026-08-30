import 'value.dart';

enum DTypeCapability { descriptor, literal, import, export, cast, kernels }

final class DTypeCapabilities {
  const DTypeCapabilities({
    required this.descriptor,
    required this.literal,
    required this.import,
    required this.export,
    required this.cast,
    required this.kernels,
  });

  const DTypeCapabilities.full()
    : this(
        descriptor: true,
        literal: true,
        import: true,
        export: true,
        cast: true,
        kernels: true,
      );

  final bool descriptor;
  final bool literal;
  final bool import;
  final bool export;
  final bool cast;
  final bool kernels;

  bool supports(DTypeCapability capability) => switch (capability) {
    DTypeCapability.descriptor => descriptor,
    DTypeCapability.literal => literal,
    DTypeCapability.import => import,
    DTypeCapability.export => export,
    DTypeCapability.cast => cast,
    DTypeCapability.kernels => kernels,
  };
}

sealed class DType {
  const DType();

  String get kind;
  Map<String, Object?> toJson();
  DTypeCapabilities get capabilities => const DTypeCapabilities.full();

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

final class NullType extends _SimpleType {
  const NullType();
  @override
  String get kind => 'null';
}

final class BooleanType extends _SimpleType {
  const BooleanType();
  @override
  String get kind => 'boolean';
}

final class UInt8Type extends _SimpleType {
  const UInt8Type();
  @override
  String get kind => 'uint8';
}

final class UInt16Type extends _SimpleType {
  const UInt16Type();
  @override
  String get kind => 'uint16';
}

final class UInt32Type extends _SimpleType {
  const UInt32Type();
  @override
  String get kind => 'uint32';
}

final class UInt64Type extends _SimpleType {
  const UInt64Type();
  @override
  String get kind => 'uint64';
}

final class UInt128Type extends _SimpleType {
  const UInt128Type();
  @override
  String get kind => 'uint128';
}

final class Int8Type extends _SimpleType {
  const Int8Type();
  @override
  String get kind => 'int8';
}

final class Int16Type extends _SimpleType {
  const Int16Type();
  @override
  String get kind => 'int16';
}

final class Int32Type extends _SimpleType {
  const Int32Type();
  @override
  String get kind => 'int32';
}

final class Int64Type extends _SimpleType {
  const Int64Type();
  @override
  String get kind => 'int64';
}

final class Int128Type extends _SimpleType {
  const Int128Type();
  @override
  String get kind => 'int128';
}

final class Float16Type extends _SimpleType {
  const Float16Type();
  @override
  String get kind => 'float16';
}

final class Float32Type extends _SimpleType {
  const Float32Type();
  @override
  String get kind => 'float32';
}

final class Float64Type extends _SimpleType {
  const Float64Type();
  @override
  String get kind => 'float64';
}

final class StringType extends _SimpleType {
  const StringType();
  @override
  String get kind => 'string';
}

final class BinaryType extends _SimpleType {
  const BinaryType();
  @override
  String get kind => 'binary';
}

final class BinaryOffsetType extends _SimpleType {
  const BinaryOffsetType();
  @override
  String get kind => 'binaryOffset';
}

final class DateType extends _SimpleType {
  const DateType();
  @override
  String get kind => 'date';
}

final class TimeType extends _SimpleType {
  const TimeType();
  @override
  String get kind => 'time';
}

final class ObjectType extends DType {
  const ObjectType(this.label);
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

enum UnknownKind { any, float, string, integer }

final class UnknownType extends DType {
  const UnknownType._(this.unknownKind, this.value);
  const UnknownType.any() : this._(UnknownKind.any, null);
  const UnknownType.float() : this._(UnknownKind.float, null);
  const UnknownType.string() : this._(UnknownKind.string, null);
  factory UnknownType.integer(BigInt value) {
    _requireSigned128(value, 'value');
    return UnknownType._(UnknownKind.integer, value);
  }
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

  final UnknownKind unknownKind;
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

enum TimeUnit {
  milliseconds('milliseconds'),
  microseconds('microseconds'),
  nanoseconds('nanoseconds');

  const TimeUnit(this.json);
  final String json;
  static TimeUnit fromJson(String value) =>
      values.firstWhere((unit) => unit.json == value);
}

final class DecimalType extends DType {
  DecimalType({required this.precision, required this.scale}) {
    if (precision < 1 || precision > 38) {
      throw RangeError.range(precision, 1, 38, 'precision');
    }
    if (scale < 0 || scale > precision) {
      throw RangeError.range(scale, 0, precision, 'scale');
    }
  }
  final int precision;
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

final class DateTimeType extends DType {
  const DateTimeType(this.unit, {this.timeZone});
  final TimeUnit unit;
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

final class DurationType extends DType {
  const DurationType(this.unit);
  final TimeUnit unit;
  @override
  String get kind => 'duration';
  @override
  Map<String, Object?> toJson() => {'kind': kind, 'unit': unit.json};
}

final class ArrayType extends DType {
  const ArrayType(this.inner, this.width);
  final DType inner;
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

final class ListType extends DType {
  const ListType(this.inner);
  final DType inner;
  @override
  String get kind => 'list';
  @override
  Map<String, Object?> toJson() => {'kind': kind, 'inner': inner.toJson()};
  @override
  DTypeCapabilities get capabilities => _descriptorAndCastOnly;
}

enum CategoricalPhysical {
  uint8('uint8'),
  uint16('uint16'),
  uint32('uint32');

  const CategoricalPhysical(this.json);
  final String json;
  static CategoricalPhysical fromJson(String value) => values.firstWhere(
    (physical) => physical.json == value,
    orElse: () => throw FormatException('Unknown categorical physical: $value'),
  );
}

final class CategoricalType extends DType {
  CategoricalType({
    required this.name,
    required this.namespace,
    required BigInt hash,
    required this.physical,
  }) : hash = hash {
    _requireUnsigned64(hash, 'hash');
  }
  final String name;
  final String namespace;
  final BigInt hash;
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

final class EnumType extends DType {
  EnumType(Iterable<String> categories)
    : categories = List.unmodifiable(categories) {
    if (this.categories.toSet().length != this.categories.length) {
      throw ArgumentError.value(categories, 'categories', 'must be unique');
    }
  }
  final List<String> categories;
  @override
  String get kind => 'enum';
  @override
  Map<String, Object?> toJson() => {'kind': kind, 'categories': categories};
  @override
  DTypeCapabilities get capabilities => _descriptorOnly;
}

final class Field {
  const Field(this.name, this.dtype);
  final String name;
  final DType dtype;
  Map<String, Object?> toJson() => {'name': name, 'dtype': dtype.toJson()};
  @override
  bool operator ==(Object other) =>
      other is Field && name == other.name && dtype == other.dtype;
  @override
  int get hashCode => Object.hash(name, dtype);
}

final class StructType extends DType {
  StructType(Iterable<Field> fields) : fields = List.unmodifiable(fields) {
    if (this.fields.map((field) => field.name).toSet().length !=
        this.fields.length) {
      throw ArgumentError.value(fields, 'fields', 'names must be unique');
    }
  }
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

final class ExtensionType extends DType {
  const ExtensionType(this.name, this.storage, {this.metadata});
  final String name;
  final DType storage;
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
/// v1. Parameterized representatives are illustrative; inspect [capabilities]
/// before attempting copied import/export or literals.
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
