import 'package:dartaframes_polars/dartaframes_polars.dart';
import 'package:test/test.dart';

final class _Invoker implements ProtocolInvoker {
  final requests = <Map<String, Object?>>[];
  final released = <int>[];
  var nextHandle = 1;

  @override
  Map<String, Object?> invokeSync(Map<String, Object?> request) {
    requests.add(Map.unmodifiable(request));
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
  test(
    'advanced numeric functions preserve Expr handles and exact defaults',
    () {
      final fake = _Invoker();
      final p = Polars.fromClient(ProtocolClient(fake));
      final x = p.col('x');
      final y = p.col('y');

      x.pow(y).close();
      expect(fake.requests.last, {
        'protocol': 2,
        'command': 'exprFunction',
        'input': '1',
        'name': 'pow',
        'arguments': ['2'],
      });

      final unary = <String, Expr Function()>{
        'sqrt': x.sqrt,
        'cbrt': x.cbrt,
        'log1p': x.log1p,
        'exp': x.exp,
        'sin': x.sin,
        'cos': x.cos,
        'tan': x.tan,
        'cot': x.cot,
        'asin': x.asin,
        'acos': x.acos,
        'atan': x.atan,
        'sinh': x.sinh,
        'cosh': x.cosh,
        'tanh': x.tanh,
        'asinh': x.asinh,
        'acosh': x.acosh,
        'atanh': x.atanh,
        'degrees': x.degrees,
        'radians': x.radians,
      };
      for (final entry in unary.entries) {
        entry.value().close();
        expect(fake.requests.last['name'], entry.key);
        expect(fake.requests.last['arguments'], isEmpty);
      }

      x.log(10).close();
      expect(fake.requests[fake.requests.length - 2]['command'], 'exprLiteral');
      expect(fake.requests.last['name'], 'log');
      expect(
        fake.released,
        contains(23),
        reason: 'temporary literal is released',
      );
      x.atan2(y).close();
      x.rank().close();
      expect(fake.requests.last, containsPair('method', 'dense'));
      expect(fake.requests.last, containsPair('descending', false));
      x.interpolate().close();
      expect(fake.requests.last, containsPair('method', 'linear'));
      x.interpolateBy(y).close();
      x.diff(y).close();
      expect(fake.requests.last, containsPair('nullBehavior', 'ignore'));
      x.pctChange(y).close();

      x.close();
      y.close();
    },
  );

  test('advanced reductions emit operation-specific closed option shapes', () {
    final fake = _Invoker();
    final p = Polars.fromClient(ProtocolClient(fake));
    final x = p.col('x');
    final operations = <String, Expr Function()>{
      'argMin': () => x.argMin,
      'argMax': () => x.argMax,
      'approximateNUnique': () => x.approximateNUnique,
      'nanMin': () => x.nanMin,
      'nanMax': () => x.nanMax,
    };
    for (final entry in operations.entries) {
      entry.value().close();
      expect(fake.requests.last['op'], entry.key);
      expect(fake.requests.last.keys, {'protocol', 'command', 'input', 'op'});
    }
    x.mode().close();
    expect(fake.requests.last, containsPair('maintainOrder', false));
    x.skew().close();
    expect(fake.requests.last, containsPair('bias', true));
    x.kurtosis().close();
    expect(fake.requests.last, containsPair('fisher', true));
    x.any().close();
    expect(fake.requests.last, containsPair('ignoreNulls', true));
    x.all(ignoreNulls: false).close();
    expect(fake.requests.last, containsPair('ignoreNulls', false));
    x.close();
  });

  test('verified rolling and EWM signatures map all native fields', () {
    final fake = _Invoker();
    final p = Polars.fromClient(ProtocolClient(fake));
    final x = p.col('x');
    const rolling = RollingOptions(
      windowSize: 3,
      minPeriods: 2,
      weights: [0.2, 0.3, 0.5],
      center: true,
    );
    final rollingCalls = <String, Expr Function()>{
      'rollingMin': () => x.rollingMin(rolling),
      'rollingMax': () => x.rollingMax(rolling),
      'rollingMean': () => x.rollingMean(rolling),
      'rollingSum': () => x.rollingSum(rolling),
      'rollingMedian': () => x.rollingMedian(rolling),
      'rollingVariance': () => x.rollingVariance(rolling),
      'rollingStd': () => x.rollingStd(rolling),
    };
    for (final entry in rollingCalls.entries) {
      entry.value().close();
      expect(fake.requests.last['name'], entry.key);
      expect(fake.requests.last['windowSize'], 3);
      expect(fake.requests.last['weights'], [0.2, 0.3, 0.5]);
    }
    const ewm = EwmOptions(alpha: 0.25, minPeriods: 2, ignoreNulls: false);
    final ewmCalls = <String, Expr Function()>{
      'ewmMean': () => x.ewmMean(ewm),
      'ewmSum': () => x.ewmSum(ewm),
      'ewmStd': () => x.ewmStd(ewm),
      'ewmVariance': () => x.ewmVariance(ewm),
    };
    for (final entry in ewmCalls.entries) {
      entry.value().close();
      expect(fake.requests.last['name'], entry.key);
      expect(fake.requests.last['alpha'], 0.25);
      if (entry.key == 'ewmMean') {
        expect(fake.requests.last['adjust'], true);
        expect(fake.requests.last.containsKey('bias'), isFalse);
      } else if (entry.key == 'ewmSum') {
        expect(fake.requests.last.containsKey('adjust'), isFalse);
        expect(fake.requests.last.containsKey('bias'), isFalse);
      } else {
        expect(fake.requests.last['adjust'], true);
        expect(fake.requests.last['bias'], false);
      }
    }
    x.close();
  });

  test(
    'options validate before dispatch and cross-runtime Expr is rejected',
    () {
      final leftFake = _Invoker();
      final rightFake = _Invoker();
      final left = Polars.fromClient(ProtocolClient(leftFake)).col('x');
      final right = Polars.fromClient(ProtocolClient(rightFake)).col('y');
      final before = leftFake.requests.length;
      expect(
        () => left.rollingMean(const RollingOptions(windowSize: 0)),
        throwsRangeError,
      );
      expect(
        () =>
            left.rollingMean(const RollingOptions(windowSize: 2, weights: [1])),
        throwsArgumentError,
      );
      expect(() => left.ewmMean(const EwmOptions(alpha: 0)), throwsRangeError);
      expect(() => left.interpolateBy(right), throwsArgumentError);
      expect(leftFake.requests.length, before);
      left.close();
      right.close();
    },
  );
}
