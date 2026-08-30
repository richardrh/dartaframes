import 'package:dartaframes/polars.dart';
import 'package:test/test.dart';

final class _LiteralInvoker implements ProtocolInvoker {
  @override
  Map<String, Object?> invokeSync(Map<String, Object?> request) => {
    'ok': true,
    'handle': '1',
  };
  @override
  Future<Map<String, Object?>> invoke(Map<String, Object?> request) async =>
      invokeSync(request);
  @override
  void releaseHandle(int handle) {}
  @override
  Object? attachHandleFinalizer(Object owner, int handle) => null;
  @override
  bool detachHandleFinalizer(Object? token) => false;
}

void main() {
  test('all 31 Polars 0.55.2 descriptors round trip structurally', () {
    final types = <DType>[
      const NullType(),
      const BooleanType(),
      const UInt8Type(),
      const UInt16Type(),
      const UInt32Type(),
      const UInt64Type(),
      const UInt128Type(),
      const Int8Type(),
      const Int16Type(),
      const Int32Type(),
      const Int64Type(),
      const Int128Type(),
      const Float16Type(),
      const Float32Type(),
      const Float64Type(),
      DecimalType(precision: 38, scale: 4),
      const StringType(),
      const BinaryType(),
      const BinaryOffsetType(),
      const DateType(),
      const DateTimeType(TimeUnit.nanoseconds, timeZone: 'UTC'),
      const DurationType(TimeUnit.microseconds),
      const TimeType(),
      const ArrayType(Int32Type(), 3),
      const ListType(StringType()),
      const ObjectType('python.object'),
      CategoricalType(
        name: 'colors',
        namespace: 'inventory',
        hash: BigInt.parse('18446744073709551615'),
        physical: CategoricalPhysical.uint16,
      ),
      EnumType(['a', 'b']),
      StructType([const Field('x', Int64Type())]),
      const ExtensionType('example.uuid', BinaryType(), metadata: '{}'),
      UnknownType.integer(-(BigInt.one << 127)),
    ];
    expect(types, hasLength(31));
    expect(types.map((type) => type.kind).toSet(), hasLength(31));
    for (final type in types) {
      final decoded = DType.fromJson(type.toJson());
      expect(decoded, type, reason: type.kind);
      expect(decoded.hashCode, type.hashCode);
    }
  });

  test('retention and inference dtype capabilities are explicit', () {
    final expression = Polars.fromClient(ProtocolClient(_LiteralInvoker()))
        .col('x');
    addTearDown(expression.close);
    for (final type in [const ObjectType('x'), const UnknownType.any()]) {
      expect(type.capabilities.descriptor, isTrue);
      expect(type.capabilities.literal, isFalse);
      expect(type.capabilities.import, isFalse);
      expect(type.capabilities.export, isFalse);
      expect(type.capabilities.cast, isFalse);
      expect(type.capabilities.kernels, isFalse);
    }
    expect(const ExtensionType('x', Int32Type()).capabilities.kernels, isFalse);
    for (final type in [
      const ListType(Int32Type()),
      const ArrayType(Int32Type(), 2),
      StructType([const Field('x', Int32Type())]),
      CategoricalType(
        name: 'x',
        namespace: 'test',
        hash: BigInt.zero,
        physical: CategoricalPhysical.uint8,
      ),
      EnumType(['x']),
      const ExtensionType('x', Int32Type()),
    ]) {
      expect(type.capabilities.literal, isFalse, reason: type.kind);
      expect(type.capabilities.import, isFalse, reason: type.kind);
      expect(type.capabilities.export, isFalse, reason: type.kind);
    }
    for (final type in [
      StructType([const Field('x', Int32Type())]),
      CategoricalType(
        name: 'x',
        namespace: 'test',
        hash: BigInt.zero,
        physical: CategoricalPhysical.uint8,
      ),
      EnumType(['x']),
      const ExtensionType('x', Int32Type()),
    ]) {
      expect(type.capabilities.cast, isFalse, reason: type.kind);
    }
    expect(allDTypes, hasLength(31));
    expect(() => expression.cast(const ObjectType('x')), throwsArgumentError);
    expect(
      () => expression.cast(
        CategoricalType(
          name: 'x',
          namespace: 'test',
          hash: BigInt.zero,
          physical: CategoricalPhysical.uint8,
        ),
      ),
      throwsArgumentError,
    );
  });

  test('wide integers and decimal precision are lossless strings', () {
    final minimum = -(BigInt.one << 127);
    expect(Scalar.int128(minimum).toJson(), {
      'dtype': {'kind': 'int128'},
      'value': minimum.toString(),
    });
    expect(
      Scalar.decimal(
        BigInt.parse('12340000'),
        DecimalType(precision: 38, scale: 4),
      ).toJson(),
      {
        'dtype': {'kind': 'decimal', 'precision': 38, 'scale': 4},
        'unscaled': '12340000',
      },
    );
    expect(
      () => Scalar.int128(-(BigInt.one << 127) - BigInt.one),
      throwsArgumentError,
    );
  });

  test('floating bits, binary, temporal and typed null are exact', () {
    expect(
      Scalar.float64Bits(0x7ff8000000000001).toJson()['floatBits'],
      '7ff8000000000001',
    );
    expect(Scalar.binary([0, 1, 2]).toJson()['base64'], 'AAEC');
    expect(
      Scalar.datetime(
        BigInt.from(42),
        const DateTimeType(TimeUnit.nanoseconds, timeZone: 'UTC'),
      ).toJson(),
      {
        'dtype': {'kind': 'datetime', 'unit': 'nanoseconds', 'timeZone': 'UTC'},
        'value': '42',
      },
    );
    expect(Scalar.nullValue(const Int32Type()).toJson(), {
      'dtype': {'kind': 'int32'},
      'value': null,
    });
    expect(() => Scalar.nullValue(const ObjectType('x')), throwsArgumentError);
    expect(() => Scalar.float16Bits(-1), throwsRangeError);
    expect(() => Scalar.float16Bits(0x10000), throwsRangeError);
    expect(
      () => Scalar.typed(const BooleanType(), BigInt.one),
      throwsArgumentError,
    );
    expect(
      Scalar.typed(const Int64Type(), BigInt.from(7)).toString(),
      contains('"value":"7"'),
    );
    expect(() => DecimalType(precision: 0, scale: 0), throwsRangeError);
    expect(() => DecimalType(precision: 4, scale: -1), throwsRangeError);
    expect(
      () => Scalar.decimal(
        BigInt.from(1000),
        DecimalType(precision: 3, scale: 0),
      ),
      throwsArgumentError,
    );
  });

  test('parameterized retention descriptors validate exact ranges', () {
    expect(const ObjectType('opaque').toJson(), {
      'kind': 'object',
      'label': 'opaque',
    });
    expect(UnknownType.integer(BigInt.from(-1)).toJson(), {
      'kind': 'unknown',
      'unknownKind': 'integer',
      'value': '-1',
    });
    expect(() => UnknownType.integer(BigInt.one << 127), throwsArgumentError);
    expect(
      () => DType.fromJson({
        'kind': 'unknown',
        'unknownKind': 'integer',
        'value': '01',
      }),
      throwsFormatException,
    );
    expect(
      () => CategoricalType(
        name: 'x',
        namespace: 'arbitrary-string-namespace',
        hash: BigInt.one << 64,
        physical: CategoricalPhysical.uint32,
      ),
      throwsArgumentError,
    );
  });
}
