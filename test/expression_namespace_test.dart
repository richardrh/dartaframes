import 'package:dartaframes_polars/dartaframes_polars.dart';
import 'package:test/test.dart';

final class _NamespaceInvoker implements ProtocolInvoker {
  final requests = <Map<String, Object?>>[];
  var nextHandle = 1;

  @override
  Map<String, Object?> invokeSync(Map<String, Object?> request) {
    requests.add(Map.unmodifiable(request));
    if (request['command'] == 'exprMeta') {
      return {
        'ok': true,
        'value': switch (request['op']) {
          'rootNames' => ['x'],
          'outputName' => 'x',
          _ => true,
        },
      };
    }
    return {'ok': true, 'handle': '${nextHandle++}'};
  }

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
  test('qualified namespaces emit verified names and closed options', () {
    final fake = _NamespaceInvoker();
    final p = Polars.fromClient(ProtocolClient(fake));
    final x = p.col('x');

    final calls = <Expr Function()>[
      () => x.str.lenBytes,
      () => x.str.lenChars,
      x.str.toLowercase,
      x.str.toUppercase,
      () => x.str.contains('a'),
      () => x.str.startsWith('a'),
      () => x.str.endsWith('a'),
      () => x.str.find('a'),
      () => x.str.extract('(a)'),
      () => x.str.extractAll('a'),
      () => x.str.split(','),
      () => x.str.replace('a', 'b'),
      x.str.stripChars,
      x.str.stripCharsStart,
      x.str.stripCharsEnd,
      () => x.str.stripPrefix('a'),
      () => x.str.stripSuffix('a'),
      () => x.str.slice(0, 2),
      () => x.str.head(2),
      () => x.str.tail(2),
      () => x.str.padStart(3),
      () => x.str.padEnd(3),
      () => x.str.zfill(3),
      x.str.toDate,
      x.str.toTime,
      x.str.toDatetime,
      () => x.dt.year,
      () => x.dt.isoYear,
      () => x.dt.month,
      () => x.dt.day,
      () => x.dt.ordinalDay,
      () => x.dt.weekday,
      () => x.dt.week,
      () => x.dt.quarter,
      () => x.dt.hour,
      () => x.dt.minute,
      () => x.dt.second,
      () => x.dt.millisecond,
      () => x.dt.microsecond,
      () => x.dt.nanosecond,
      () => x.dt.date,
      () => x.dt.time,
      x.dt.timestamp,
      () => x.dt.format('%Y'),
      () => x.dt.truncate('1d'),
      () => x.dt.round('1d'),
      () => x.dt.offsetBy('1d'),
      () => x.dt.convertTimeZone('UTC'),
      () => x.dt.baseUtcOffset,
      () => x.dt.dstOffset,
      () => x.list.len,
      () => x.list.first,
      () => x.list.last,
      () => x.list.sum,
      () => x.list.min,
      () => x.list.max,
      () => x.list.mean,
      () => x.list.get(0),
      () => x.list.contains(1),
      x.list.sort,
      () => x.list.slice(0, 2),
      () => x.arr.len,
      () => x.arr.sum,
      () => x.arr.min,
      () => x.arr.max,
      () => x.arr.mean,
      () => x.arr.toList,
      () => x.arr.get(0),
      () => x.arr.contains(1),
      x.arr.sort,
      x.arr.explode,
      () => x.struct.field('a'),
      () => x.struct.fieldAt(0),
      () => x.struct.renameFields(['a']),
      () => x.struct.jsonEncode,
      () => x.bin.sizeBytes,
      () => x.bin.contains(<int>[1]),
      () => x.bin.startsWith(<int>[1]),
      () => x.bin.endsWith(<int>[1]),
      () => x.bin.hexEncode,
      () => x.bin.base64Encode,
      () => x.cat.physical,
      () => x.cat.categories,
      () => x.name.keep,
      () => x.name.prefix('pre_'),
      () => x.name.suffix('_post'),
      () => x.name.toLowercase,
      () => x.name.toUppercase,
      () => x.meta.undoAliases,
    ];
    for (final call in calls) {
      call().close();
    }

    final names = fake.requests
        .where((request) => request['command'] == 'exprFunction')
        .map((request) => request['name'])
        .toSet();
    expect(
      names,
      containsAll(<String>{
        'str.toDatetime',
        'dt.convertTimeZone',
        'list.contains',
        'arr.explode',
        'struct.renameFields',
        'bin.base64Encode',
        'cat.categories',
        'name.toUppercase',
        'meta.undoAliases',
      }),
    );
    expect(
      fake.requests.firstWhere((request) => request['name'] == 'str.split'),
      containsPair('regex', false),
    );
    expect(
      fake.requests.firstWhere((request) => request['name'] == 'dt.timestamp'),
      containsPair('timeUnit', 'microseconds'),
    );
    x.close();
  });

  test(
    'exprMeta emits closed operation-specific requests and parses values',
    () {
      final fake = _NamespaceInvoker();
      final x = Polars.fromClient(ProtocolClient(fake)).col('x');

      expect(x.meta.rootNames, ['x']);
      expect(x.meta.outputName, 'x');
      expect(x.meta.isColumn, isTrue);
      expect(x.meta.isColumnSelection(), isTrue);
      expect(x.meta.isLiteral(allowAliasing: true), isTrue);
      expect(x.meta.hasMultipleOutputs, isTrue);
      expect(x.meta.isRegexProjection, isTrue);
      expect(
        fake.requests.where((request) => request['command'] == 'exprMeta'),
        hasLength(7),
      );
      expect(fake.requests.last, {
        'protocol': 2,
        'command': 'exprMeta',
        'input': '1',
        'op': 'isRegexProjection',
      });
      final literal = fake.requests.firstWhere(
        (request) => request['op'] == 'isLiteral',
      );
      expect(literal.keys, {
        'protocol',
        'command',
        'input',
        'op',
        'allowAliasing',
      });
      x.close();
    },
  );

  test('namespace validation rejects invalid values before transport', () {
    final fake = _NamespaceInvoker();
    final x = Polars.fromClient(ProtocolClient(fake)).col('x');
    final before = fake.requests.length;

    expect(() => x.str.extract('x', groupIndex: -1), throwsRangeError);
    expect(() => x.str.padStart(2, fill: ''), throwsArgumentError);
    expect(() => x.str.padEnd(2, fill: 'ab'), throwsArgumentError);
    expect(() => x.dt.format(''), throwsArgumentError);
    expect(() => x.dt.convertTimeZone(''), throwsArgumentError);
    expect(() => x.struct.field(''), throwsArgumentError);
    expect(() => x.struct.renameFields(const []), throwsArgumentError);
    expect(() => x.struct.renameFields(const ['ok', '']), throwsArgumentError);
    expect(fake.requests, hasLength(before));

    x.close();
  });
}
