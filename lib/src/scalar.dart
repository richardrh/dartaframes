import 'dart:convert';
import 'dart:typed_data';

import 'package:dartaframes/arrow.dart';

import 'dtype.dart';
import 'value.dart';

/// An immutable, explicitly typed protocol literal.
final class Scalar {
  Scalar._(this.dtype, Map<String, Object?> payload)
    : _payload = Map.unmodifiable(payload) {
    if (!dtype.capabilities.literal) {
      throw ArgumentError.value(dtype, 'dtype', 'does not support literals');
    }
  }

  factory Scalar.nullValue(DType dtype) =>
      Scalar._(dtype, const {'value': null});
  factory Scalar.fromJson(Map<String, Object?> json) {
    final allowed = {'dtype', 'value', 'floatBits', 'base64', 'unscaled'};
    if (json.keys.any((key) => !allowed.contains(key))) {
      throw const FormatException('Scalar contains an unknown field');
    }
    final rawDtype = json['dtype'];
    if (rawDtype is! Map) {
      throw const FormatException('Scalar.dtype must be an object');
    }
    final dtype = DType.fromJson(rawDtype.cast<String, Object?>());
    final payloads = [
      'value',
      'floatBits',
      'base64',
      'unscaled',
    ].where(json.containsKey).toList(growable: false);
    if (payloads.length != 1) {
      throw const FormatException('Scalar requires exactly one value payload');
    }
    final key = payloads.single;
    final value = json[key];
    try {
      return switch (key) {
        'value' when value == null => Scalar.nullValue(dtype),
        'value' when dtype is DateType && value is String => Scalar.date(
          int.parse(value),
        ),
        'value' when dtype is TimeType && value is String => Scalar.time(
          int.parse(value),
        ),
        'value' => Scalar.typed(dtype, value),
        'floatBits' when value is String => Scalar._(dtype, {
          'floatBits': _validateFloatBits(dtype, value),
        }),
        'base64'
            when value is String &&
                (dtype is BinaryType || dtype is BinaryOffsetType) =>
          Scalar._(dtype, {'base64': base64Encode(base64Decode(value))}),
        'unscaled' when value is String && dtype is DecimalType =>
          Scalar.decimal(BigInt.parse(value), dtype),
        _ => throw const FormatException('Scalar payload does not match dtype'),
      };
    } on FormatException {
      rethrow;
    } on Object catch (error) {
      throw FormatException('Invalid scalar response: $error');
    }
  }
  factory Scalar.boolean(bool value) =>
      Scalar._(const BooleanType(), {'value': value});
  factory Scalar.integer(BigInt value, DType dtype) {
    final bounds = _integerBounds[dtype.kind];
    if (bounds == null)
      throw ArgumentError.value(dtype, 'dtype', 'not an integer');
    if (value < bounds.$1 || value > bounds.$2) {
      throw ArgumentError.value(
        value,
        'value',
        'must be between ${bounds.$1} and ${bounds.$2}',
      );
    }
    return Scalar._(dtype, {'value': value.toString()});
  }
  factory Scalar.int64(int value) =>
      Scalar.integer(BigInt.from(value), const Int64Type());
  factory Scalar.int128(BigInt value) =>
      Scalar.integer(value, const Int128Type());
  factory Scalar.uint128(BigInt value) =>
      Scalar.integer(value, const UInt128Type());
  factory Scalar.float16Bits(int bits) {
    if (bits < 0 || bits > 0xffff) {
      throw RangeError.range(bits, 0, 0xffff, 'bits');
    }
    return Scalar._(const Float16Type(), {
      'floatBits': bits.toRadixString(16).padLeft(4, '0'),
    });
  }
  factory Scalar.float32(double value) {
    final data = ByteData(4)..setFloat32(0, value, Endian.big);
    return Scalar._(const Float32Type(), {
      'floatBits': data
          .getUint32(0, Endian.big)
          .toRadixString(16)
          .padLeft(8, '0'),
    });
  }
  factory Scalar.float64(double value) {
    final data = ByteData(8)..setFloat64(0, value, Endian.big);
    return Scalar.float64Bits(data.getUint64(0, Endian.big));
  }
  factory Scalar.float64Bits(int bits) {
    final maximum = (BigInt.one << 64) - BigInt.one;
    final minimumSigned = -(BigInt.one << 63);
    var value = BigInt.from(bits);
    if (value < minimumSigned || value > maximum) {
      throw RangeError.value(bits, 'bits', 'must be a 64-bit bit pattern');
    }
    if (value.isNegative) value += BigInt.one << 64;
    return Scalar._(const Float64Type(), {
      'floatBits': value.toRadixString(16).padLeft(16, '0'),
    });
  }
  factory Scalar.string(String value) =>
      Scalar._(const StringType(), {'value': value});
  factory Scalar.binary(List<int> value, {bool offset = false}) => Scalar._(
    offset ? const BinaryOffsetType() : const BinaryType(),
    {'base64': base64Encode(Uint8List.fromList(value))},
  );
  factory Scalar.date(int daysSinceEpoch) {
    if (daysSinceEpoch < -0x80000000 || daysSinceEpoch > 0x7fffffff) {
      throw RangeError.value(
        daysSinceEpoch,
        'daysSinceEpoch',
        'must fit int32',
      );
    }
    return Scalar._(const DateType(), {'value': daysSinceEpoch.toString()});
  }
  factory Scalar.time(int nanosecondsSinceMidnight) {
    if (nanosecondsSinceMidnight < 0 ||
        nanosecondsSinceMidnight >= 86400 * 1000000000) {
      throw RangeError.value(
        nanosecondsSinceMidnight,
        'nanosecondsSinceMidnight',
        'must fall within one day',
      );
    }
    return Scalar._(const TimeType(), {
      'value': nanosecondsSinceMidnight.toString(),
    });
  }
  factory Scalar.datetime(BigInt value, DateTimeType dtype) {
    _requireInt64(value, 'value');
    return Scalar._(dtype, {'value': value.toString()});
  }
  factory Scalar.duration(BigInt value, DurationType dtype) {
    _requireInt64(value, 'value');
    return Scalar._(dtype, {'value': value.toString()});
  }
  factory Scalar.decimal(BigInt unscaled, DecimalType dtype) {
    final limit = BigInt.from(10).pow(dtype.precision);
    if (unscaled <= -limit || unscaled >= limit) {
      throw ArgumentError.value(
        unscaled,
        'unscaled',
        'must fit decimal precision ${dtype.precision}',
      );
    }
    return Scalar._(dtype, {'unscaled': unscaled.toString()});
  }
  factory Scalar.typed(DType dtype, Object? value) {
    if (value == null) return Scalar.nullValue(dtype);
    if (dtype.kind case final kind when _integerBounds.containsKey(kind)) {
      final integer = switch (value) {
        BigInt value => value,
        int value => BigInt.from(value),
        String value => BigInt.tryParse(value),
        _ => null,
      };
      if (integer == null) {
        throw ArgumentError.value(value, 'value', 'must be an integer');
      }
      return Scalar.integer(integer, dtype);
    }
    return switch (dtype) {
      BooleanType() when value is bool => Scalar.boolean(value),
      Float16Type() when value is int => Scalar.float16Bits(value),
      Float32Type() when value is double => Scalar.float32(value),
      Float64Type() when value is double => Scalar.float64(value),
      StringType() when value is String => Scalar.string(value),
      BinaryType() when value is List<int> => Scalar.binary(value),
      BinaryOffsetType() when value is List<int> => Scalar.binary(
        value,
        offset: true,
      ),
      DateType() when value is int => Scalar.date(value),
      TimeType() when value is int => Scalar.time(value),
      DateTimeType() => Scalar.datetime(_asBigInt(value), dtype),
      DurationType() => Scalar.duration(_asBigInt(value), dtype),
      DecimalType() => Scalar.decimal(_asBigInt(value), dtype),
      _ => throw ArgumentError.value(
        value,
        'value',
        'does not match ${dtype.kind}',
      ),
    };
  }

  /// Reuses supported primitive Arrow value wrappers without converting
  /// through imprecise Dart numbers. Nested, dictionary/category, and
  /// extension literals are deliberately unsupported by the native protocol.
  factory Scalar.fromArrow(DType dtype, ArrowValue? value) {
    if (value == null) return Scalar.nullValue(dtype);
    return switch (value) {
      ArrowBooleanValue(:final value) when dtype is BooleanType =>
        Scalar.boolean(value),
      ArrowIntegerValue(:final value) => Scalar.integer(value, dtype),
      ArrowFloatingValue(:final hexadecimalBits) => Scalar._(dtype, {
        'floatBits': _validateFloatBits(dtype, hexadecimalBits),
      }),
      ArrowDecimalValue(:final unscaled) => Scalar.decimal(
        unscaled,
        dtype as DecimalType,
      ),
      ArrowStringValue(:final value) when dtype is StringType => Scalar.string(
        value,
      ),
      ArrowBinaryValue(:final bytes)
          when dtype is BinaryType || dtype is BinaryOffsetType =>
        Scalar._(dtype, {'base64': base64Encode(bytes)}),
      ArrowTemporalValue(:final value) => switch (dtype) {
        DateType() => Scalar.date(_bigIntToInt(value, 32, 'date value')),
        TimeType() => Scalar.time(_bigIntToInt(value, 64, 'time value')),
        DateTimeType() => Scalar.datetime(value, dtype),
        DurationType() => Scalar.duration(value, dtype),
        _ => throw ArgumentError.value(
          dtype,
          'dtype',
          'does not match Arrow temporal value',
        ),
      },
      ArrowListValue() ||
      ArrowStructValue() ||
      ArrowDictionaryIndexValue() ||
      ArrowExtensionValue() => throw ArgumentError.value(
        value,
        'value',
        'nested, category, and extension literals are unsupported',
      ),
      _ => throw ArgumentError.value(
        dtype,
        'dtype',
        'does not match ${value.runtimeType}',
      ),
    };
  }

  final DType dtype;
  final Map<String, Object?> _payload;
  bool get isNull => _payload['value'] == null && _payload.containsKey('value');
  Map<String, Object?> toJson() =>
      Map.unmodifiable({'dtype': dtype.toJson(), ..._payload});

  @override
  bool operator ==(Object other) =>
      other is Scalar && jsonEquals(toJson(), other.toJson());
  @override
  int get hashCode => jsonHash(toJson());
  @override
  String toString() => canonicalJson(toJson());

  static final Map<String, (BigInt, BigInt)> _integerBounds = {
    for (final width in [8, 16, 32, 64, 128])
      'int$width': (
        -(BigInt.one << (width - 1)),
        (BigInt.one << (width - 1)) - BigInt.one,
      ),
    for (final width in [8, 16, 32, 64, 128])
      'uint$width': (BigInt.zero, (BigInt.one << width) - BigInt.one),
  };
}

void _requireInt64(BigInt value, String name) {
  final minimum = -(BigInt.one << 63);
  final maximum = (BigInt.one << 63) - BigInt.one;
  if (value < minimum || value > maximum) {
    throw ArgumentError.value(value, name, 'must fit signed 64-bit');
  }
}

int _bigIntToInt(BigInt value, int bits, String name) {
  final minimum = -(BigInt.one << (bits - 1));
  final maximum = (BigInt.one << (bits - 1)) - BigInt.one;
  if (value < minimum || value > maximum) {
    throw ArgumentError.value(value, name, 'must fit signed $bits-bit');
  }
  return value.toInt();
}

BigInt _asBigInt(Object value) {
  if (value is BigInt) return value;
  if (value is int) return BigInt.from(value);
  if (value is String) {
    final parsed = BigInt.tryParse(value);
    if (parsed != null) return parsed;
  }
  throw ArgumentError.value(value, 'value', 'must be an integer counter');
}

String _validateFloatBits(DType dtype, String bits) {
  final digits = switch (dtype) {
    Float16Type() => 4,
    Float32Type() => 8,
    Float64Type() => 16,
    _ => throw ArgumentError.value(dtype, 'dtype', 'not a floating datatype'),
  };
  if (bits.length != digits || !RegExp(r'^[0-9a-fA-F]+$').hasMatch(bits)) {
    throw ArgumentError.value(
      bits,
      'floatBits',
      'must contain $digits hex digits',
    );
  }
  return bits.toLowerCase();
}
