import 'package:dartaframes/polars.dart';
import 'package:test/test.dart';

final class _FakeInvoker implements ProtocolInvoker {
  final requests = <Map<String, Object?>>[];
  final released = <int>[];
  var nextHandle = 1;

  @override
  Map<String, Object?> invokeSync(Map<String, Object?> request) {
    requests.add(Map<String, Object?>.unmodifiable(request));
    return {'ok': true, 'handle': '${nextHandle++}'};
  }

  @override
  Future<Map<String, Object?>> invoke(Map<String, Object?> request) async =>
      invokeSync(request);

  @override
  void releaseHandle(int handle) => released.add(handle);

  @override
  Object? attachHandleFinalizer(Object owner, int handle) => null;

  @override
  bool detachHandleFinalizer(Object? token) => false;
}

void main() {
  test('as-of and typed ordinary joins emit exact defaults', () {
    final fake = _FakeInvoker();
    final p = Polars.fromClient(ProtocolClient(fake));
    final key = p.col('time');
    final left = p.scanCsv('left.csv');
    final right = p.scanCsv('right.csv');

    left.joinAsOf(right, leftOn: key, rightOn: key).close();
    expect(fake.requests.last, {
      'protocol': 2,
      'command': 'lazyJoinAsOf',
      'left': '2',
      'right': '3',
      'leftOn': '1',
      'rightOn': '1',
      'strategy': 'backward',
      'allowEqual': true,
      'checkSortedness': true,
      'suffix': '_right',
      'coalesce': null,
      'allowParallel': true,
      'forceParallel': false,
    });

    left.joinWithOptions(right, leftOn: [key], rightOn: [key]).close();
    expect(fake.requests.last, {
      'protocol': 2,
      'command': 'lazyJoin',
      'left': '2',
      'right': '3',
      'leftOn': ['1'],
      'rightOn': ['1'],
      'how': 'inner',
      'suffix': '_right',
      'coalesce': null,
      'nullsEqual': false,
      'validation': 'manyToMany',
      'maintainOrder': 'none',
      'allowParallel': true,
      'forceParallel': false,
    });

    // Direct commands clone their inputs: both sources remain reusable.
    left.select([key]).close();
    right.select([key]).close();
    key.close();
    left.close();
    right.close();
  });

  test('joinWhere and temporal groups map handles and typed options', () {
    final fake = _FakeInvoker();
    final p = Polars.fromClient(ProtocolClient(fake));
    final time = p.col('time');
    final group = p.col('group');
    final predicate = time.lt(group);
    final left = p.scanCsv('left.csv');
    final right = p.scanCsv('right.csv');

    left.joinWhere(right, [predicate]).close();
    expect(fake.requests.last, {
      'protocol': 2,
      'command': 'lazyJoinWhere',
      'left': '4',
      'right': '5',
      'predicates': ['3'],
      'suffix': '_right',
      'allowParallel': true,
      'forceParallel': false,
    });

    final total = time.sum;
    left
        .groupByDynamic(
          time,
          groupBy: [group],
          options: const DynamicGroupByOptions(every: PolarsDuration('15m')),
        )
        .agg([total])
        .close();
    expect(fake.requests.last, {
      'protocol': 2,
      'command': 'lazyGroupByDynamic',
      'input': '4',
      'indexColumn': '1',
      'groupBy': ['2'],
      'aggregations': ['7'],
      'every': '15m',
      'closed': 'left',
      'label': 'left',
      'includeBoundaries': false,
      'startBy': 'windowBound',
    });

    left
        .groupByRolling(
          time,
          options: const RollingGroupByOptions(period: PolarsDuration('2h')),
        )
        .agg([total])
        .close();
    expect(fake.requests.last, containsPair('command', 'lazyGroupByRolling'));
    expect(fake.requests.last['groupBy'], isEmpty);
    expect(fake.requests.last['period'], '2h');
    expect(fake.requests.last['closed'], 'right');

    for (final value in [total, predicate, group, time]) {
      value.close();
    }
    left.close();
    right.close();
  });

  test('window order/mapping and reshape/concat requests are exact', () {
    final fake = _FakeInvoker();
    final p = Polars.fromClient(ProtocolClient(fake));
    final value = p.col('value');
    final order = p.col('time');
    value.sum
        .over(
          const [],
          orderBy: [order],
          options: const WindowOptions(
            mapping: WindowMapping.explode,
            order: WindowOrderOptions(descending: true, nullsLast: true),
          ),
        )
        .close();
    expect(fake.requests.last, {
      'protocol': 2,
      'command': 'exprOver',
      'input': '3',
      'partitionBy': <String>[],
      'orderBy': ['2'],
      'mapping': 'explode',
      'orderDescending': true,
      'orderNullsLast': true,
      'orderMaintainOrder': false,
      'orderMultithreaded': true,
    });

    final left = p.scanCsv('left.csv');
    final right = p.scanCsv('right.csv');
    p.concat([left, right], how: 'diagonalRelaxed', rechunk: true).close();
    expect(fake.requests.last['how'], 'diagonalRelaxed');
    left
        .unpivot(
          on: ['value'],
          index: ['time'],
          variableName: 'metric',
          valueName: 'reading',
        )
        .close();
    expect(fake.requests.last, containsPair('command', 'lazyUnpivot'));
    expect(fake.requests.last['on'], ['value']);
    left.close();
    right.close();
    value.close();
    order.close();
  });

  test('validation and cross-runtime leasing fail before dispatch', () {
    final fake = _FakeInvoker();
    final a = Polars.fromClient(ProtocolClient(fake));
    final b = Polars.fromClient(ProtocolClient(fake));
    final left = a.scanCsv('left.csv');
    final right = b.scanCsv('right.csv');
    final aKey = a.col('time');
    final bKey = b.col('time');
    final before = fake.requests.length;

    expect(
      () => left.joinAsOf(right, leftOn: aKey, rightOn: aKey),
      throwsArgumentError,
    );
    expect(
      () => left.joinAsOf(left, leftOn: aKey, rightOn: bKey),
      throwsArgumentError,
    );
    expect(
      () => left
          .groupByDynamic(
            aKey,
            options: const DynamicGroupByOptions(every: PolarsDuration('bad')),
          )
          .agg(const []),
      throwsArgumentError,
    );
    expect(() => left.joinWhere(left, const []), throwsArgumentError);
    expect(fake.requests.length, before);
    left.close();
    right.close();
    aKey.close();
    bKey.close();
  });
}
