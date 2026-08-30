import 'package:dartaframes_polars/dartaframes_polars.dart';
import 'package:test/test.dart';

final class SelectorSqlInvoker implements ProtocolInvoker {
  final requests = <Map<String, Object?>>[];
  final released = <int>[];
  int next = 1;

  @override
  Map<String, Object?> invokeSync(Map<String, Object?> request) {
    requests.add(Map.unmodifiable(request));
    return switch (request['command']) {
      'dtypeSelectorMatches' => {'ok': true, 'matches': true},
      'sqlContextTables' => {
        'ok': true,
        'tables': ['source'],
      },
      'sqlContextRegister' ||
      'sqlContextRegisterAll' ||
      'sqlContextUnregister' => {'ok': true},
      _ => {'ok': true, 'handle': '${next++}'},
    };
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
    'selector factories, algebra, matching, and projection use exact wire',
    () {
      final fake = SelectorSqlInvoker();
      final p = Polars.fromClient(ProtocolClient(fake));
      final names = p.selectors.byName(['x', 'y'], strict: false);
      final numericTypes = p.selectors.numericDTypes();
      final numeric = numericTypes.asSelector();
      final selected = names & numeric;
      final source = p.scanCsv('source.csv');
      final projection = source.selectInputs([selected, p.col('z')]);

      expect(fake.requests[0], {
        'protocol': 2,
        'command': 'selectorByName',
        'names': ['x', 'y'],
        'strict': false,
        'expandPatterns': false,
      });
      expect(numericTypes.matches(const Int64Type()), isTrue);
      expect(fake.requests.last['dtype'], {'kind': 'int64'});
      final request = fake.requests.singleWhere(
        (request) => request['command'] == 'lazySelectInputs',
      );
      expect(request['expressions'], ['4', '6']);

      projection.close();
      source.close();
      selected.close();
      numeric.close();
      numericTypes.close();
      names.close();
    },
  );

  test(
    'selector and SQL resources reject cross-runtime inputs before wire',
    () {
      final fake = SelectorSqlInvoker();
      final client = ProtocolClient(fake);
      final a = Polars.fromClient(client);
      final b = Polars.fromClient(client);
      final left = a.selectors.all();
      final right = b.selectors.empty();
      final context = a.sqlContext();
      final foreign = b.scanParquet('foreign.parquet');
      final before = fake.requests.length;

      expect(() => left | right, throwsArgumentError);
      expect(() => context.register('foreign', foreign), throwsArgumentError);
      expect(fake.requests, hasLength(before));

      foreign.close();
      context.close();
      right.close();
      left.close();
    },
  );

  test(
    'SQL context owns catalog independently and returns lazy queries',
    () async {
      final fake = SelectorSqlInvoker();
      final p = Polars.fromClient(ProtocolClient(fake));
      final source = p.scanCsv('source.csv');
      final context = p.sqlContext();
      context.register('source', source);
      source.close();

      expect(context.tablesSync(), ['source']);
      expect(await context.tables(), ['source']);
      final query = context.execute('SELECT * FROM source');
      expect(fake.requests.last, {
        'protocol': 2,
        'command': 'sqlContextExecute',
        'context': '2',
        'query': 'SELECT * FROM source',
      });
      context.unregister(['source']);
      context.close();
      expect(() => context.tablesSync(), throwsA(isA<StaleHandleException>()));
      query.close();
    },
  );

  test('selector index/nested factories validate and emit exact fields', () {
    final fake = SelectorSqlInvoker();
    final selectors = Polars.fromClient(ProtocolClient(fake)).selectors;
    final indices = selectors.byIndex([-1, 2], strict: false);
    final inner = selectors.integerDTypes();
    final arrays = selectors.arrayDTypes(inner: inner, width: 4);
    final datetimes = selectors.datetimeDTypes(
      units: const [TimeUnit.nanoseconds],
      timeZoneMode: TimeZoneSelectorMode.unsetOrAnyOf,
      timeZones: const ['UTC'],
    );

    expect(fake.requests[0], {
      'protocol': 2,
      'command': 'selectorByIndex',
      'indices': [-1, 2],
      'strict': false,
    });
    expect(fake.requests[2], containsPair('inner', '2'));
    expect(fake.requests[2], containsPair('width', 4));
    expect(fake.requests[3], containsPair('timeZoneMode', 'unsetOrAnyOf'));
    expect(fake.requests[3], containsPair('timeZones', ['UTC']));
    final signedMinimum = selectors.byIndex([-0x7fffffffffffffff - 1]);
    expect(fake.requests.last['indices'], [-9223372036854775808]);
    final before = fake.requests.length;
    expect(() => selectors.byIndex(const []), throwsArgumentError);
    expect(() => selectors.anyOf(const []), throwsArgumentError);
    expect(() => selectors.arrayDTypes(width: 0), throwsRangeError);
    expect(
      () => selectors.durationDTypes(units: const []),
      throwsArgumentError,
    );
    expect(
      () => selectors.datetimeDTypes(timeZoneMode: TimeZoneSelectorMode.anyOf),
      throwsArgumentError,
    );
    expect(fake.requests, hasLength(before));
    signedMinimum.close();
    datetimes.close();
    arrays.close();
    inner.close();
    indices.close();
  });

  test(
    'registerAll validates atomically and releases temporary lazy frames',
    () {
      final fake = SelectorSqlInvoker();
      final p = Polars.fromClient(ProtocolClient(fake));
      final context = p.sqlContext();
      final lazy = p.scanCsv('lazy.csv');
      final frame = p.scanCsv('frame.csv').collectSync();
      context.registerAll({'lazy': lazy, 'frame': frame});

      final request = fake.requests.singleWhere(
        (request) => request['command'] == 'sqlContextRegisterAll',
      );
      expect(request['context'], '1');
      expect(request['tables'], [
        {'name': 'lazy', 'input': '2'},
        {'name': 'frame', 'input': '5'},
      ]);
      expect(fake.released, contains(5), reason: 'temporary frame.lazy handle');

      final before = fake.requests.length;
      expect(() => context.registerAll({'bad': Object()}), throwsArgumentError);
      expect(() => context.registerAll({'': lazy}), throwsArgumentError);
      expect(fake.requests, hasLength(before));
      frame.close();
      lazy.close();
      context.close();
    },
  );
}
