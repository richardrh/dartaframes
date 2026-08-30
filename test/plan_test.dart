import 'package:dartaframes/polars.dart';
import 'package:test/test.dart';

final class ImmediateInvoker implements ProtocolInvoker {
  final requests = <Map<String, Object?>>[];
  final released = <int>[];
  int nextHandle = 1;
  bool failAttach = false;

  @override
  Map<String, Object?> invokeSync(Map<String, Object?> request) {
    requests.add(Map.unmodifiable(request));
    return switch (request['command']) {
      'hello' => {'ok': true, 'abi': 1, 'protocol': 2, 'polars': 'test'},
      'lazySchema' => {
        'ok': true,
        'schema': [
          {
            'name': 'x',
            'dtype': {'kind': 'int64'},
          },
        ],
      },
      'lazyExplain' => {'ok': true, 'explanation': 'SCAN'},
      'frameInfo' => {
        'ok': true,
        'height': 2,
        'width': 1,
        'schema': [
          {
            'name': 'x',
            'dtype': {'kind': 'int64'},
          },
        ],
      },
      _ => {'ok': true, 'handle': '${nextHandle++}'},
    };
  }

  @override
  Future<Map<String, Object?>> invoke(Map<String, Object?> request) async =>
      invokeSync(request);
  @override
  void releaseHandle(int handle) => released.add(handle);
  @override
  Object? attachHandleFinalizer(Object owner, int handle) {
    if (failAttach) throw StateError('attach failed');
    return null;
  }

  @override
  bool detachHandleFinalizer(Object? token) => false;
}

void main() {
  test('expressions issue immediate protocol 2 commands and can branch', () {
    final fake = ImmediateInvoker();
    final polars = Polars.fromClient(ProtocolClient(fake));
    final input = polars.col('x');
    final alias = input.alias('a');
    final cast = input.cast(const Float64Type(), strict: false);
    final branch = input.gt(3);

    expect(fake.requests.map((x) => x['command']), [
      'exprColumn',
      'exprAlias',
      'exprCast',
      'exprLiteral',
      'exprBinary',
    ]);
    expect(fake.requests.every((x) => x['protocol'] == 2), isTrue);
    expect(fake.requests[1], {
      'protocol': 2,
      'command': 'exprAlias',
      'input': '1',
      'name': 'a',
    });
    expect(fake.requests[2]['strict'], false);
    expect(fake.requests[4]['left'], '1');
    expect(fake.requests[4]['right'], '4');
    expect(fake.requests[4]['op'], 'gt');
    expect(fake.released, [4], reason: 'temporary literal is deterministic');

    // The source remains reusable after all branches.
    final again = input.isNull;
    expect(fake.requests.last['input'], '1');
    for (final value in [again, branch, cast, alias, input]) value.close();
  });

  test('all expression operation IDs and options map exactly', () {
    final fake = ImmediateInvoker();
    final p = Polars.fromClient(ProtocolClient(fake));
    final x = p.col('x');
    final y = p.col('y');

    final unary = <String, Expr Function()>{
      'not': () => x.not,
      'negate': () => x.neg,
      'isNull': () => x.isNull,
      'isNotNull': () => x.isNotNull,
      'isNan': () => x.isNaN,
      'isNotNan': () => x.isNotNaN,
    };
    for (final entry in unary.entries) {
      entry.value().close();
      expect(fake.requests.last['op'], entry.key);
    }
    final binary = <String, Expr Function()>{
      'eq': () => x.eq(y),
      'eqValidity': () => x.eqValidity(y),
      'notEq': () => x.notEq(y),
      'notEqValidity': () => x.notEqValidity(y),
      'lt': () => x.lt(y),
      'ltEq': () => x.ltEq(y),
      'gt': () => x.gt(y),
      'gtEq': () => x.gtEq(y),
      'add': () => x + y,
      'subtract': () => x - y,
      'multiply': () => x * y,
      'trueDivide': () => x / y,
      'floorDivide': () => x ~/ y,
      'modulo': () => x % y,
      'bitAnd': () => x & y,
      'bitOr': () => x | y,
      'bitXor': () => x ^ y,
      'logicalAnd': () => x.logicalAnd(y),
      'logicalOr': () => x.logicalOr(y),
    };
    for (final entry in binary.entries) {
      entry.value().close();
      expect(fake.requests.last['op'], entry.key);
    }
    final aggregates = <String, Expr Function()>{
      'count': () => x.count,
      'nullCount': () => x.nullCount,
      'sum': () => x.sum,
      'mean': () => x.mean,
      'min': () => x.min,
      'max': () => x.max,
      'first': () => x.first,
      'last': () => x.last,
      'median': () => x.median,
      'nUnique': () => x.nUnique,
      'product': () => x.product,
    };
    for (final entry in aggregates.entries) {
      entry.value().close();
      expect(fake.requests.last['op'], entry.key);
    }
    x.std(ddof: 2).close();
    expect(fake.requests.last, containsPair('ddof', 2));
    x.variance(ddof: 0).close();
    x.quantile(.25, interpolation: 'midpoint').close();
    expect(fake.requests.last, containsPair('interpolation', 'midpoint'));

    final functions = <String, Expr Function()>{
      'fillNull': () => x.fillNull(y),
      'abs': x.abs,
      'floor': x.floor,
      'ceil': x.ceil,
      'clip': () => x.clip(y, y),
      'clipMin': () => x.clipMin(y),
      'clipMax': () => x.clipMax(y),
      'fillNan': () => x.fillNaN(y),
      'isFinite': () => x.isFinite,
      'isInfinite': () => x.isInfinite,
      'coalesce': () => x.coalesce([y]),
      'isIn': () => x.isIn(y, nullsEqual: true),
      'lowercase': x.lowercase,
      'uppercase': x.uppercase,
      'stringContains': () => x.stringContains(y),
      'stringStartsWith': () => x.stringStartsWith(y),
      'stringEndsWith': () => x.stringEndsWith(y),
      'stringReplace': () => x.stringReplace(y, y, replaceAll: true),
      'stripChars': x.stripChars,
      'shift': () => x.shift(y),
      'cumSum': x.cumulativeSum,
      'cumMin': x.cumulativeMin,
      'cumMax': x.cumulativeMax,
    };
    for (final entry in functions.entries) {
      entry.value().close();
      expect(fake.requests.last['name'], entry.key);
    }
    x.round(decimals: 3, mode: RoundMode.halfAwayFromZero).close();
    expect(fake.requests.last, containsPair('mode', 'halfAwayFromZero'));
    x.over([y]).close();
    expect(fake.requests.last['command'], 'exprOver');
    p.when(x).then(y).otherwise(0).close();
    expect(fake.requests.last['command'], 'exprTernary');
    p.len().close();
    expect(fake.requests.last['command'], 'exprLen');
    x.close();
    y.close();
  });

  test('lazy commands use direct handles and exact native field names', () {
    final fake = ImmediateInvoker();
    final p = Polars.fromClient(ProtocolClient(fake));
    final x = p.col('x');
    final source = p.scanCsv(
      'a.csv',
      hasHeader: false,
      separator: ';',
      skipRows: 2,
      nRows: 4,
      tryParseDates: true,
    );
    final selected = source.select([x]);
    final filtered = source.filter(x);
    source.withColumns([x]).close();
    source
        .sort([x], descending: true, nullsLast: [true], maintainOrder: true)
        .close();
    source.slice(-2, 2).close();
    source.groupBy([x], maintainOrder: true).agg([x.sum]).close();
    source.distinct(subset: ['x'], keep: 'last', maintainOrder: true).close();
    source.dropNulls(subset: ['x']).close();
    source.drop(['x'], strict: false).close();
    source.rename({'x': 'y'}, strict: false).close();
    source.explode(['x']).close();
    source.unnest(['x']).close();
    final parquet = p.scanParquet('a.parquet', nRows: 3, parallel: false);
    source
        .join(
          parquet,
          leftOn: [x],
          rightOn: [x],
          how: 'left',
          suffix: '_r',
          coalesce: true,
        )
        .close();
    p.concat([source, parquet], how: 'verticalRelaxed', rechunk: true).close();

    expect(fake.requests.where((r) => r['command'] == 'lazyFilter').single, {
      'protocol': 2,
      'command': 'lazyFilter',
      'input': '2',
      'predicate': '1',
    });
    final explode = fake.requests
        .where((r) => r['command'] == 'lazyExplode')
        .single;
    expect(explode['columns'], ['x']);
    expect(explode['emptyAsNull'], true);
    expect(
      fake.requests.where((r) => r['command'] == 'lazyConcat').single['inputs'],
      ['2', '16'],
    );
    expect(source.schemaSync().single.name, 'x');
    expect(source.explainSync(optimized: false), 'SCAN');
    expect(fake.requests.last['optimized'], false);

    filtered.close();
    selected.close();
    parquet.close();
    source.close();
    x.close();
  });

  test(
    'cross-runtime rejection precedes transport and adoption failure releases',
    () {
      final fake = ImmediateInvoker();
      final client = ProtocolClient(fake);
      final a = Polars.fromClient(client);
      final b = Polars.fromClient(client);
      final left = a.col('x');
      final right = b.col('x');
      final count = fake.requests.length;
      expect(() => left + right, throwsArgumentError);
      expect(fake.requests, hasLength(count));

      fake.failAttach = true;
      expect(() => a.col('bad'), throwsStateError);
      expect(fake.released, contains(3));
      left.close();
      right.close();
    },
  );

  test('frame commands use frame fields and lazy sources are independent', () {
    final fake = ImmediateInvoker();
    final p = Polars.fromClient(ProtocolClient(fake));
    final batch = RecordBatch(
      ArrowSchema([ArrowField('x', ArrowIntegerType(64))]),
      [
        ArrowArray(ArrowIntegerType(64), [ArrowIntegerValue(1)]),
      ],
    );
    final frame = p.fromRecordBatchSync(batch);
    expect(fake.requests.single['command'], 'frameImport');
    expect(fake.requests.single['batch'], isA<Map>());
    final lazy = frame.lazy();
    expect(fake.requests.last, {
      'protocol': 2,
      'command': 'frameLazy',
      'frame': '1',
    });
    frame.close();
    final output = lazy.collectSync();
    expect(fake.requests.last['input'], '2');
    expect(output.shapeSync(), (2, 1));
    expect(fake.requests.last['frame'], '3');
    output.writeCsvSync('x.csv', includeHeader: false, separator: ';');
    expect(fake.requests.last, containsPair('command', 'frameWriteCsv'));
    expect(fake.requests.last, containsPair('frame', '3'));
    output.writeParquetSync('x.parquet', compression: 'snappy');
    expect(fake.requests.last, containsPair('command', 'frameWriteParquet'));
    output.close();
    lazy.close();
  });

  test('returned resource adoption failures release native handles', () async {
    final fake = ImmediateInvoker();
    final p = Polars.fromClient(ProtocolClient(fake));
    fake.failAttach = true;
    expect(() => p.scanCsv('x'), throwsStateError);
    expect(fake.released, [1]);

    fake.failAttach = false;
    final lazy = p.scanCsv('x');
    fake.failAttach = true;
    await expectLater(lazy.submit(), throwsStateError);
    expect(fake.released, contains(3));
    lazy.close();
  });

  test('validation fails before transport', () {
    final fake = ImmediateInvoker();
    final p = Polars.fromClient(ProtocolClient(fake));
    expect(() => p.col(''), throwsArgumentError);
    expect(() => p.scanCsv('x', separator: '::'), throwsArgumentError);
    expect(() => p.scanCsv('x', separator: 'é'), throwsArgumentError);
    expect(() => p.lit(null), throwsArgumentError);
    expect(fake.requests, isEmpty);
  });
}
