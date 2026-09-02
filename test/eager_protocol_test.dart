import 'dart:async';
import 'dart:ffi';

import 'package:dartaframes/polars.dart';
import 'package:test/test.dart';

final class EagerInvoker implements ProtocolInvoker {
  final requests = <Map<String, Object?>>[];
  final released = <int>[];
  final finalizerOwners = <Object>[];
  final responses = <Map<String, Object?>>[];
  Completer<void>? gate;
  int nextHandle = 1;
  int attachments = 0;
  int? failAttachment;

  Map<String, Object?> _respond(Map<String, Object?> request) {
    requests.add(request);
    return responses.isEmpty
        ? {'ok': true, 'handle': '${nextHandle++}'}
        : responses.removeAt(0);
  }

  @override
  Map<String, Object?> invokeSync(Map<String, Object?> request) =>
      _respond(request);

  @override
  Future<Map<String, Object?>> invoke(Map<String, Object?> request) async {
    final pending = gate;
    if (pending != null) await pending.future;
    return _respond(request);
  }

  @override
  void releaseHandle(int handle) => released.add(handle);

  @override
  Object? attachHandleFinalizer(Object owner, int handle) {
    finalizerOwners.add(owner);
    attachments++;
    if (attachments == failAttachment) throw StateError('attach failed');
    return null;
  }

  @override
  bool detachHandleFinalizer(Object? token) => false;
}

ArrowArray integers([int value = 1]) =>
    ArrowArray(ArrowIntegerType(32), [ArrowIntegerValue(value), null]);

void main() {
  test('Arrow import creates a finalizable direct Series handle', () {
    final invoker = EagerInvoker();
    final polars = Polars.fromClient(ProtocolClient(invoker));
    final series = polars.fromArrowArraySync('value', integers());

    expect(invoker.requests.single['command'], 'seriesImport');
    expect(invoker.requests.single['protocol'], 2);
    expect((invoker.requests.single['column'] as Map)['name'], 'value');
    expect(invoker.finalizerOwners.single, isA<Finalizable>());
    expect(series, isNot(isA<Finalizable>()));

    series.close();
    expect(invoker.released, [1]);
  });

  test('Series operations lease inputs and produce independent handles', () {
    final invoker = EagerInvoker();
    final polars = Polars.fromClient(ProtocolClient(invoker));
    final source = polars.fromArrowArraySync('value', integers());
    final renamed = source.rename('renamed');
    final sliced = renamed.slice(-1, 1);
    final compared = sliced.gt(0);
    source.close();
    renamed.close();
    sliced.close();

    expect(invoker.requests.map((request) => request['command']), [
      'seriesImport',
      'seriesRename',
      'seriesSlice',
      'seriesBinary',
    ]);
    expect(invoker.requests.last['scalar'], {
      'dtype': {'kind': 'int64'},
      'value': '0',
    });
    expect(invoker.released, [1, 2, 3]);
    expect(compared.isClosed, isFalse);
    compared.close();
  });

  test('Series exact aggregate response becomes a typed Scalar', () {
    final invoker = EagerInvoker()
      ..responses.addAll([
        {'ok': true, 'handle': '9'},
        {
          'ok': true,
          'scalar': {
            'dtype': {'kind': 'int128'},
            'value': '-170141183460469231731687303715884105728',
          },
        },
        {'ok': true, 'value': 1},
      ]);
    final polars = Polars.fromClient(ProtocolClient(invoker));
    final series = polars.fromArrowArraySync('value', integers());

    expect(series.sum().toJson(), {
      'dtype': {'kind': 'int128'},
      'value': '-170141183460469231731687303715884105728',
    });
    expect(series.nUnique(), 1);
    series.close();
  });

  test('remaining Series eager APIs emit closed command schemas', () {
    final invoker = EagerInvoker();
    final series = Polars.fromClient(ProtocolClient(invoker))
        .fromArrowArraySync('value', integers());

    series.cast(const Float64Type(), strict: false).close();
    series.head(2).close();
    series.tail(3).close();
    series.reverse().close();
    series
        .sort(
          descending: true,
          nullsLast: true,
          maintainOrder: true,
          multithreaded: false,
        )
        .close();
    series.dropNulls().close();
    series.unique(maintainOrder: true).close();

    expect(invoker.requests.skip(1).map((request) => request['command']), [
      'seriesCast',
      'seriesSlice',
      'seriesSlice',
      'seriesReverse',
      'seriesSort',
      'seriesDropNulls',
      'seriesUnique',
    ]);
    expect(invoker.requests[1], {
      'protocol': 2,
      'command': 'seriesCast',
      'series': '1',
      'dtype': {'kind': 'float64'},
      'strict': false,
    });
    expect(invoker.requests[3], containsPair('offset', -3));
    expect(invoker.requests[5], containsPair('multithreaded', false));
    expect(invoker.requests[7], containsPair('maintainOrder', true));
    final before = invoker.requests.length;
    expect(() => series.rename(''), throwsArgumentError);
    expect(() => series.slice(0, -1), throwsRangeError);
    expect(() => series.cast(const ObjectType('x')), throwsArgumentError);
    expect(invoker.requests, hasLength(before));
    series.close();
  });

  test('Series multi-input APIs lease and identify every direct handle', () {
    final invoker = EagerInvoker();
    final polars = Polars.fromClient(ProtocolClient(invoker));
    final values = polars.fromArrowArraySync('values', integers());
    final other = polars.fromArrowArraySync('other', integers(2));

    values.append(other).close();
    values.filter(other).close();
    values.gather(other).close();

    expect(invoker.requests.skip(2).toList(), [
      {'protocol': 2, 'command': 'seriesAppend', 'series': '1', 'other': '2'},
      {'protocol': 2, 'command': 'seriesFilter', 'series': '1', 'mask': '2'},
      {'protocol': 2, 'command': 'seriesGather', 'series': '1', 'indices': '2'},
    ]);

    other.close();
    values.close();
  });

  test('remaining DataFrame eager APIs map handles and reject bad inputs', () {
    final invoker = EagerInvoker();
    final polars = Polars.fromClient(ProtocolClient(invoker));
    final frame = polars.fromRecordBatchSync(
      RecordBatch(ArrowSchema([ArrowField('value', ArrowIntegerType(32))]), [
        integers(),
      ]),
    );
    final value = polars.col('value');

    frame.selectColumns(['value']).close();
    frame.filter(value.gt(0)).close();
    final mask = polars.fromArrowArraySync('mask', integers());
    frame.filterMask(mask).close();
    frame.withColumns([value]).close();
    frame.sort([value], descending: true, nullsLast: [true]).close();
    frame.tail(2).close();
    frame.reverse().close();
    frame.drop(['value'], strict: false).close();
    frame.rename({'value': 'renamed'}, strict: false).close();

    expect(
      invoker.requests.map((request) => request['command']),
      containsAll([
        'frameSelectColumns',
        'frameFilter',
        'frameFilterMask',
        'frameWithColumns',
        'frameSort',
        'frameSlice',
        'frameReverse',
        'frameDrop',
        'frameRename',
      ]),
    );
    final sort = invoker.requests.singleWhere(
      (request) => request['command'] == 'frameSort',
    );
    expect(sort['descending'], [true]);
    expect(sort['nullsLast'], [true]);
    final before = invoker.requests.length;
    expect(() => frame.sort(const []), throwsArgumentError);
    expect(() => frame.rename(const {}), throwsArgumentError);
    expect(() => frame.selectColumns(const []), throwsArgumentError);
    expect(invoker.requests, hasLength(before));

    mask.close();
    value.close();
    frame.close();
  });

  test('eager reshape APIs emit exact schemas and independent handles', () {
    final invoker = EagerInvoker();
    final polars = Polars.fromClient(ProtocolClient(invoker));
    final frame = polars.fromRecordBatchSync(
      RecordBatch(ArrowSchema([ArrowField('value', ArrowIntegerType(32))]), [
        integers(),
      ]),
    );

    final distinct = frame.distinct(
      subset: ['value'],
      keep: 'last',
      maintainOrder: true,
    );
    frame.dropNulls(subset: ['value']).close();
    frame.explode(['value']).close();
    frame.unnest(['value']).close();
    frame
        .unpivot(
          on: ['value'],
          index: const [],
          variableName: 'metric',
          valueName: 'reading',
        )
        .close();
    frame
        .transpose(
          includeHeader: true,
          headerName: 'source',
          columnNames: ['row0', 'row1'],
        )
        .close();

    expect(invoker.requests.skip(1).toList(), [
      {
        'protocol': 2,
        'command': 'frameDistinct',
        'frame': '1',
        'subset': ['value'],
        'keep': 'last',
        'maintainOrder': true,
      },
      {
        'protocol': 2,
        'command': 'frameDropNulls',
        'frame': '1',
        'subset': ['value'],
      },
      {
        'protocol': 2,
        'command': 'frameExplode',
        'frame': '1',
        'columns': ['value'],
        'emptyAsNull': true,
        'keepNulls': true,
      },
      {
        'protocol': 2,
        'command': 'frameUnnest',
        'frame': '1',
        'columns': ['value'],
      },
      {
        'protocol': 2,
        'command': 'frameUnpivot',
        'frame': '1',
        'on': ['value'],
        'index': <String>[],
        'variableName': 'metric',
        'valueName': 'reading',
      },
      {
        'protocol': 2,
        'command': 'frameTranspose',
        'frame': '1',
        'includeHeader': true,
        'headerName': 'source',
        'columnNames': ['row0', 'row1'],
      },
    ]);

    frame.close();
    expect(distinct.isClosed, isFalse);
    distinct.close();

    final before = invoker.requests.length;
    expect(() => frame.distinct(keep: 'bad'), throwsArgumentError);
    expect(() => frame.explode(const []), throwsArgumentError);
    expect(() => frame.unnest(['']), throwsArgumentError);
    expect(() => frame.unpivot(on: const []), throwsArgumentError);
    expect(
      () => frame.transpose(includeHeader: true, headerName: ''),
      throwsArgumentError,
    );
    expect(invoker.requests, hasLength(before));
  });

  test(
    'Series info, copied export, and toFrame use only owned handle fields',
    () {
      final invoker = EagerInvoker()
        ..responses.addAll([
          {'ok': true, 'handle': '5'},
          {
            'ok': true,
            'name': 'value',
            'dtype': {'kind': 'int64'},
            'length': 2,
            'nullCount': 1,
            'chunkCount': 1,
          },
          {
            'ok': true,
            'column': {
              'name': 'value',
              'dtype': {'kind': 'int64'},
              'values': ['7', null],
            },
          },
          {'ok': true, 'handle': '8'},
        ]);
      final polars = Polars.fromClient(ProtocolClient(invoker));
      final series = polars.fromArrowArraySync('value', integers(7));

      expect(series.infoSync(), containsPair('nullCount', 1));
      expect(
        (series.exportSync().values.first as ArrowIntegerValue).value,
        BigInt.from(7),
      );
      final frame = series.toFrame();
      expect(invoker.requests.skip(1).toList(), [
        {'protocol': 2, 'command': 'seriesInfo', 'series': '5'},
        {'protocol': 2, 'command': 'seriesExport', 'series': '5'},
        {'protocol': 2, 'command': 'seriesToFrame', 'series': '5'},
      ]);

      series.close();
      expect(frame.isClosed, isFalse);
      frame.close();
    },
  );

  test('DataFrame eager commands use direct handles and expression leases', () {
    final invoker = EagerInvoker();
    final polars = Polars.fromClient(ProtocolClient(invoker));
    final frame = polars.fromRecordBatchSync(
      RecordBatch(ArrowSchema([ArrowField('value', ArrowIntegerType(32))]), [
        integers(),
      ]),
    );
    final expression = polars.col('value');
    final selected = frame.select([expression]);
    final column = selected.column('value');
    frame.close();
    expression.close();
    selected.close();

    expect(invoker.requests.map((request) => request['command']), [
      'frameImport',
      'exprColumn',
      'frameSelect',
      'frameColumn',
    ]);
    expect(invoker.requests[2]['frame'], '1');
    expect(invoker.requests[2]['expressions'], ['2']);
    expect(column.isClosed, isFalse);
    column.close();
  });

  test(
    'cross-runtime Series and expressions are rejected before invocation',
    () {
      final firstInvoker = EagerInvoker();
      final secondInvoker = EagerInvoker();
      final first = Polars.fromClient(ProtocolClient(firstInvoker));
      final second = Polars.fromClient(ProtocolClient(secondInvoker));
      final left = first.fromArrowArraySync('left', integers());
      final right = second.fromArrowArraySync('right', integers());
      final frame = first.fromRecordBatchSync(
        RecordBatch(ArrowSchema([ArrowField('left', ArrowIntegerType(32))]), [
          integers(),
        ]),
      );
      final foreignExpression = second.col('right');

      expect(() => left + right, throwsArgumentError);
      expect(() => left.filter(right), throwsArgumentError);
      expect(() => frame.select([foreignExpression]), throwsArgumentError);
      expect(firstInvoker.requests, hasLength(2));

      left.close();
      right.close();
      frame.close();
      foreignExpression.close();
    },
  );

  test(
    'async Series export lease defers close and preserves dtype limits',
    () async {
      final invoker = EagerInvoker()
        ..responses.add({'ok': true, 'handle': '7'});
      final polars = Polars.fromClient(ProtocolClient(invoker));
      final series = polars.fromArrowArraySync('value', integers());
      invoker
        ..gate = Completer<void>()
        ..responses.add({
          'ok': false,
          'error': {
            'category': 'unsupported',
            'message': 'copied export for struct',
          },
        });

      final pending = series.export();
      series.close();
      expect(invoker.released, isEmpty);
      invoker.gate!.complete();
      await expectLater(pending, throwsA(isA<UnsupportedPolarsException>()));
      expect(invoker.released, [7]);
    },
  );

  test(
    'sync and async eager adoption failures release returned handles',
    () async {
      final seriesInvoker = EagerInvoker()..failAttachment = 1;
      final seriesPolars = Polars.fromClient(ProtocolClient(seriesInvoker));
      expect(
        () => seriesPolars.fromArrowArraySync('value', integers()),
        throwsStateError,
      );
      expect(seriesInvoker.released, [1]);

      final frameInvoker = EagerInvoker()..failAttachment = 1;
      final framePolars = Polars.fromClient(ProtocolClient(frameInvoker));
      await expectLater(
        framePolars.fromRecordBatch(
          RecordBatch(
            ArrowSchema([ArrowField('value', ArrowIntegerType(32))]),
            [integers()],
          ),
        ),
        throwsStateError,
      );
      expect(frameInvoker.released, [1]);
    },
  );
}
