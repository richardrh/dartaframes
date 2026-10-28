import 'dart:typed_data';

import 'type.dart' show ArrowIntervalUnit;

sealed class ArrowValue {
  const ArrowValue();
}

final class ArrowBooleanValue extends ArrowValue {
  const ArrowBooleanValue(this.value);
  final bool value;
  @override
  bool operator ==(Object other) =>
      other is ArrowBooleanValue && value == other.value;
  @override
  int get hashCode => value.hashCode;
}

final class ArrowIntegerValue extends ArrowValue {
  ArrowIntegerValue(Object value) : value = _bigInt(value);
  final BigInt value;
  @override
  bool operator ==(Object other) =>
      other is ArrowIntegerValue && value == other.value;
  @override
  int get hashCode => value.hashCode;
}

/// An IEEE floating-point bit pattern. This preserves NaN payloads and signed zero.
final class ArrowFloatingValue extends ArrowValue {
  ArrowFloatingValue(this.bitWidth, Object bits) : bits = _bigInt(bits) {
    if (bitWidth != 16 && bitWidth != 32 && bitWidth != 64) {
      throw ArgumentError.value(bitWidth, 'bitWidth');
    }
    if (this.bits.isNegative || this.bits >= (BigInt.one << bitWidth)) {
      throw ArgumentError.value(bits, 'bits', 'does not fit in $bitWidth bits');
    }
  }
  factory ArrowFloatingValue.float16(int rawBits) =>
      ArrowFloatingValue(16, rawBits & 0xffff);
  factory ArrowFloatingValue.float32(double value) {
    final data = ByteData(4)..setFloat32(0, value, Endian.little);
    return ArrowFloatingValue(32, data.getUint32(0, Endian.little));
  }
  factory ArrowFloatingValue.float64(double value) {
    // Read as two uint32 halves: getInt64 is unavailable on the web.
    final data = ByteData(8)..setFloat64(0, value, Endian.little);
    final low = BigInt.from(data.getUint32(0, Endian.little));
    final high = BigInt.from(data.getUint32(4, Endian.little));
    return ArrowFloatingValue(64, (high << 32) | low);
  }
  final int bitWidth;
  final BigInt bits;
  String get hexadecimalBits =>
      bits.toRadixString(16).padLeft(bitWidth ~/ 4, '0');
  @override
  bool operator ==(Object other) =>
      other is ArrowFloatingValue &&
      bitWidth == other.bitWidth &&
      bits == other.bits;
  @override
  int get hashCode => Object.hash(bitWidth, bits);
}

final class ArrowDecimalValue extends ArrowValue {
  ArrowDecimalValue(Object unscaled) : unscaled = _bigInt(unscaled);
  final BigInt unscaled;
  @override
  bool operator ==(Object other) =>
      other is ArrowDecimalValue && unscaled == other.unscaled;
  @override
  int get hashCode => unscaled.hashCode;
}

final class ArrowStringValue extends ArrowValue {
  const ArrowStringValue(this.value);
  final String value;
  @override
  bool operator ==(Object other) =>
      other is ArrowStringValue && value == other.value;
  @override
  int get hashCode => value.hashCode;
}

final class ArrowBinaryValue extends ArrowValue {
  ArrowBinaryValue(List<int> bytes)
    : bytes = Uint8List.fromList(bytes).asUnmodifiableView();
  final Uint8List bytes;
  @override
  bool operator ==(Object other) =>
      other is ArrowBinaryValue && _listEquals(bytes, other.bytes);
  @override
  int get hashCode => Object.hashAll(bytes);
}

/// A raw date/time/timestamp/duration counter in the datatype's declared unit.
final class ArrowTemporalValue extends ArrowValue {
  ArrowTemporalValue(Object value) : value = _bigInt(value);
  final BigInt value;
  @override
  bool operator ==(Object other) =>
      other is ArrowTemporalValue && value == other.value;
  @override
  int get hashCode => value.hashCode;
}

final class ArrowListValue extends ArrowValue {
  ArrowListValue(List<ArrowValue?> values) : values = List.unmodifiable(values);
  final List<ArrowValue?> values;
  @override
  bool operator ==(Object other) =>
      other is ArrowListValue && _listEquals(values, other.values);
  @override
  int get hashCode => Object.hashAll(values);
}

final class ArrowStructEntry {
  const ArrowStructEntry(this.name, this.value);
  final String name;
  final ArrowValue? value;
  @override
  bool operator ==(Object other) =>
      other is ArrowStructEntry && name == other.name && value == other.value;
  @override
  int get hashCode => Object.hash(name, value);
}

/// Ordered struct members. Names are retained to detect field-order mistakes.
final class ArrowStructValue extends ArrowValue {
  ArrowStructValue(List<ArrowStructEntry> fields)
    : fields = List.unmodifiable(fields);
  final List<ArrowStructEntry> fields;
  @override
  bool operator ==(Object other) =>
      other is ArrowStructValue && _listEquals(fields, other.fields);
  @override
  int get hashCode => Object.hashAll(fields);
}

final class ArrowDictionaryIndexValue extends ArrowValue {
  ArrowDictionaryIndexValue(Object index) : index = _bigInt(index);
  final BigInt index;
  @override
  bool operator ==(Object other) =>
      other is ArrowDictionaryIndexValue && index == other.index;
  @override
  int get hashCode => index.hashCode;
}

final class ArrowExtensionValue extends ArrowValue {
  const ArrowExtensionValue(this.storage);
  final ArrowValue storage;
  @override
  bool operator ==(Object other) =>
      other is ArrowExtensionValue && storage == other.storage;
  @override
  int get hashCode => storage.hashCode;
}

/// One key/value pair of an [ArrowMapValue]. Keys are never null.
final class ArrowMapEntry {
  const ArrowMapEntry(this.key, this.value);
  final ArrowValue key;
  final ArrowValue? value;
  @override
  bool operator ==(Object other) =>
      other is ArrowMapEntry && key == other.key && value == other.value;
  @override
  int get hashCode => Object.hash(key, value);
}

/// An Arrow map row. Entry order is preserved and duplicate keys are retained,
/// matching the physical list-of-entries layout.
final class ArrowMapValue extends ArrowValue {
  ArrowMapValue(List<ArrowMapEntry> entries)
    : entries = List.unmodifiable(entries);
  final List<ArrowMapEntry> entries;
  @override
  bool operator ==(Object other) =>
      other is ArrowMapValue && _listEquals(entries, other.entries);
  @override
  int get hashCode => Object.hashAll(entries);
}

/// A union row tagged with its child [typeId]. A null [value] is a null in the
/// selected child (unions have no top-level validity bitmap).
final class ArrowUnionValue extends ArrowValue {
  const ArrowUnionValue(this.typeId, this.value);
  final int typeId;
  final ArrowValue? value;
  @override
  bool operator ==(Object other) =>
      other is ArrowUnionValue &&
      typeId == other.typeId &&
      value == other.value;
  @override
  int get hashCode => Object.hash(typeId, value);
}

/// An Arrow interval. Only the components relevant to [unit] are non-zero:
/// yearMonth uses [months]; dayTime uses [days] and [milliseconds];
/// monthDayNano uses [months], [days], and [nanoseconds].
final class ArrowIntervalValue extends ArrowValue {
  ArrowIntervalValue.yearMonth(this.months)
    : unit = ArrowIntervalUnit.yearMonth,
      days = 0,
      milliseconds = 0,
      nanoseconds = BigInt.zero {
    _checkInt32(months, 'months');
  }
  ArrowIntervalValue.dayTime(this.days, this.milliseconds)
    : unit = ArrowIntervalUnit.dayTime,
      months = 0,
      nanoseconds = BigInt.zero {
    _checkInt32(days, 'days');
    _checkInt32(milliseconds, 'milliseconds');
  }
  ArrowIntervalValue.monthDayNano(this.months, this.days, Object nanoseconds)
    : unit = ArrowIntervalUnit.monthDayNano,
      milliseconds = 0,
      nanoseconds = _bigInt(nanoseconds) {
    _checkInt32(months, 'months');
    _checkInt32(days, 'days');
    if (this.nanoseconds < -(BigInt.one << 63) ||
        this.nanoseconds >= BigInt.one << 63) {
      throw RangeError('nanoseconds does not fit int64');
    }
  }
  final ArrowIntervalUnit unit;
  final int months;
  final int days;
  final int milliseconds;
  final BigInt nanoseconds;
  @override
  bool operator ==(Object other) =>
      other is ArrowIntervalValue &&
      unit == other.unit &&
      months == other.months &&
      days == other.days &&
      milliseconds == other.milliseconds &&
      nanoseconds == other.nanoseconds;
  @override
  int get hashCode =>
      Object.hash(unit, months, days, milliseconds, nanoseconds);
}

void _checkInt32(int value, String name) {
  if (value < -0x80000000 || value > 0x7fffffff) {
    throw RangeError.range(value, -0x80000000, 0x7fffffff, name);
  }
}

BigInt _bigInt(Object value) {
  if (value is BigInt) return value;
  if (value is int) return BigInt.from(value);
  if (value is String) return BigInt.parse(value);
  throw ArgumentError.value(
    value,
    'value',
    'must be an int, BigInt, or integer string',
  );
}

bool _listEquals<T>(List<T> a, List<T> b) =>
    a.length == b.length &&
    List.generate(a.length, (i) => i).every((i) => a[i] == b[i]);
