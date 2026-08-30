import 'dart:io';
import 'dart:typed_data';

import 'package:dartaframes_polars/dartaframes_polars.dart';
import 'package:test/test.dart';

void main() {
  final libraryPath = Platform.environment['DARTAFRAMES_NATIVE_LIBRARY'];
  final skipNative = libraryPath == null
      ? 'Set DARTAFRAMES_NATIVE_LIBRARY to the built native library'
      : false;

  late Polars polars;

  setUpAll(() {
    if (libraryPath != null) polars = Polars.open(libraryPath);
  });

  Expr col(String name) => polars.col(name);

  test('handshake reports the pinned engine and complete descriptors', () {
    final hello = polars.nativeCapabilitiesSync();
    expect(hello.abi, 2);
    expect(hello.protocol, 2);
    expect(hello.polars, '0.55.2');
    expect(hello.datatypes, hasLength(31));
    expect(hello.datatypeCapabilities, hasLength(31));
    expect(hello.resources, [
      'expr',
      'selector',
      'dtypeSelector',
      'lazyFrame',
      'frame',
      'series',
      'job',
      'sqlContext',
      'batchStream',
    ]);
    expect(
      hello.commands.values.cast<List<Object?>>().fold<int>(
        0,
        (count, commands) => count + commands.length,
      ),
      112,
    );
    expect(hello.commands['expression'], contains('exprLen'));
    expect(
      (hello.operations['aggregate'] as List<Object?>),
      isNot(contains('len')),
    );
    expect((hello.datatypeCapabilities[27] as Map)['cast'], isTrue);
    expect(hello.interchange['arrowCDataVersion'], 1);
    expect(hello.interchange['unknownNullCount'], isFalse);
    expect(hello.operations['asyncJobEngines'], ['auto']);
    expect(hello.operations['maxActiveJobs'], 64);
  }, skip: skipNative);

  test('selectors and SQL execute native lazy plans end to end', () {
    final batch = RecordBatch(
      ArrowSchema([
        ArrowField('label', const ArrowUtf8Type()),
        ArrowField('value', ArrowIntegerType(32)),
      ]),
      [
        ArrowArray(const ArrowUtf8Type(), [
          const ArrowStringValue('a'),
          const ArrowStringValue('b'),
        ]),
        ArrowArray(ArrowIntegerType(32), [
          ArrowIntegerValue(1),
          ArrowIntegerValue(2),
        ]),
      ],
    );
    final frame = polars.fromRecordBatchSync(batch);
    final source = frame.lazy();
    final numericTypes = polars.selectors.numericDTypes();
    final numeric = numericTypes.asSelector();
    final projected = source.selectSelectors([numeric]);
    final selected = projected.collectSync();
    expect(selected.schemaSync().map((field) => field.name), ['value']);
    expect(numericTypes.matches(const Int32Type()), isTrue);

    final sql = polars.sqlContext();
    sql.register('source', source);
    expect(sql.tablesSync(), contains('source'));
    final queried = sql.execute('SELECT value FROM source WHERE value > 1');
    final result = queried.collectSync();
    expect(result.shapeSync(), (1, 1));

    result.close();
    queried.close();
    sql.close();
    selected.close();
    projected.close();
    numeric.close();
    numericTypes.close();
    source.close();
    frame.close();
  }, skip: skipNative);

  test('owned batch executes relational, aggregation, and joins', () {
    final batch = RecordBatch(
      ArrowSchema([
        ArrowField('group', const ArrowUtf8Type()),
        ArrowField('value', ArrowIntegerType(32)),
      ]),
      [
        ArrowArray(const ArrowUtf8Type(), const [
          ArrowStringValue('a'),
          ArrowStringValue('a'),
          ArrowStringValue('b'),
          null,
        ]),
        ArrowArray(ArrowIntegerType(32), [
          ArrowIntegerValue(1),
          ArrowIntegerValue(2),
          ArrowIntegerValue(3),
          ArrowIntegerValue(4),
        ]),
      ],
    );
    final source = polars.fromRecordBatchSync(batch);
    addTearDown(source.close);

    final transformed = source
        .lazy()
        .filter(col('value').gt(1))
        .withColumns([(col('value') * 2).alias('doubled')])
        .select([col('group'), col('value'), col('doubled')])
        .sort([col('value')], descending: true)
        .collectSync();
    addTearDown(transformed.close);
    final transformedBatch = transformed.exportSync();
    expect(transformedBatch.length, 3);
    expect(
      (transformedBatch.columns[1].values.first as ArrowIntegerValue).value,
      BigInt.from(4),
    );

    final grouped = source
        .lazy()
        .groupBy([col('group')])
        .agg([col('value').sum.alias('total')])
        .sort([col('group')])
        .collectSync();
    addTearDown(grouped.close);
    expect(grouped.shapeSync().$1, 3);

    final joined = source
        .lazy()
        .join(source.lazy(), leftOn: [col('value')], rightOn: [col('value')])
        .collectSync();
    addTearDown(joined.close);
    expect(joined.shapeSync().$1, 4);
  }, skip: skipNative);

  test('native division and nonblocking collection agree', () async {
    final batch = RecordBatch(
      ArrowSchema([ArrowField('value', ArrowIntegerType(32))]),
      [
        ArrowArray(ArrowIntegerType(32), [
          ArrowIntegerValue(3),
          ArrowIntegerValue(4),
        ]),
      ],
    );
    final source = polars.fromRecordBatchSync(batch);
    addTearDown(source.close);
    final plan = source.lazy().select([(col('value') / 2).alias('half')]);

    final sync = plan.collectSync();
    addTearDown(sync.close);
    final async = await plan.collect();
    addTearDown(async.close);

    final syncBatch = sync.exportSync();
    final asyncBatch = await async.export();
    expect(syncBatch.schema, asyncBatch.schema);
    expect(syncBatch.columns.first.values, asyncBatch.columns.first.values);
    final first = syncBatch.columns.first.values.first as ArrowFloatingValue;
    expect(first, ArrowFloatingValue.float64(1.5));
  }, skip: skipNative);

  test(
    'eager Series and DataFrame handles execute and branch independently',
    () {
      final type = ArrowIntegerType(32);
      final source = polars.fromRecordBatchSync(
        RecordBatch(ArrowSchema([ArrowField('value', type)]), [
          ArrowArray(type, [
            ArrowIntegerValue(1),
            ArrowIntegerValue(2),
            null,
            ArrowIntegerValue(4),
          ]),
        ]),
      );
      final values = source.column('value');
      final incremented = values + 1;
      final mask = incremented.gt(2);
      final filtered = incremented.filter(mask);
      final valueExpr = col('value');
      final selected = source
          .filter(valueExpr.isNotNull)
          .withColumns([(valueExpr * 2).alias('doubled')])
          .selectColumns(['value', 'doubled'])
          .reverse();

      addTearDown(source.close);
      addTearDown(values.close);
      addTearDown(incremented.close);
      addTearDown(mask.close);
      addTearDown(filtered.close);
      addTearDown(valueExpr.close);
      addTearDown(selected.close);

      source.close();
      values.close();
      expect(_integers(filtered.exportSync()), [3, 5]);
      expect(filtered.sum().toJson(), {
        'dtype': {'kind': 'int64'},
        'value': '8',
      });
      expect(filtered.count(), 2);
      expect(_integers(selected.exportSync().columns[1]), [8, 4, 2]);
    },
    skip: skipNative,
  );

  test(
    'date, naive datetime, NaN, source lifetime, and zero width interop',
    () {
      final date = const ArrowDateType();
      final timestamp = const ArrowTimestampType(ArrowTimeUnit.microsecond);
      final floating = ArrowFloatingType(64);
      final source = polars.fromRecordBatchSync(
        RecordBatch(
          ArrowSchema([
            ArrowField('date', date),
            ArrowField('when', timestamp),
            ArrowField('value', floating),
          ]),
          [
            ArrowArray(date, [ArrowTemporalValue(1)]),
            ArrowArray(timestamp, [ArrowTemporalValue(2)]),
            ArrowArray(floating, [ArrowFloatingValue.float64(double.nan)]),
          ],
        ),
      );
      final plan = source.lazy().select([
        col('date'),
        col('when'),
        col('value').isNaN.alias('nan'),
      ]);
      final output = plan.collectSync();
      addTearDown(output.close);
      addTearDown(source.close);
      final exported = output.exportSync();
      expect(exported.schema.fields[0].type, date);
      expect(exported.schema.fields[1].type, timestamp);
      expect(
        (exported.columns[2].values.single as ArrowBooleanValue).value,
        isTrue,
      );

      source.close();
      final afterSourceClose = plan.collectSync();
      addTearDown(afterSourceClose.close);
      expect(afterSourceClose.shapeSync().$1, 1);

      final empty = polars.fromRecordBatchSync(
        RecordBatch(ArrowSchema(const []), const [], rowCount: 5),
      );
      addTearDown(empty.close);
      expect(empty.shapeSync(), (5, 0));
      expect(empty.exportSync().length, 5);
    },
    skip: skipNative,
  );

  test('cleaning, strings, windows, and schema transforms execute', () {
    final int32 = ArrowIntegerType(32);
    final string = const ArrowUtf8Type();
    final source = polars.fromRecordBatchSync(
      RecordBatch(
        ArrowSchema([
          ArrowField('group', string),
          ArrowField('value', int32),
          ArrowField('fallback', int32),
          ArrowField('members', int32),
          ArrowField('text', string),
        ]),
        [
          ArrowArray(string, const [
            ArrowStringValue('a'),
            ArrowStringValue('a'),
            ArrowStringValue('b'),
          ]),
          ArrowArray(int32, [ArrowIntegerValue(1), null, ArrowIntegerValue(3)]),
          ArrowArray(int32, [
            ArrowIntegerValue(9),
            ArrowIntegerValue(2),
            ArrowIntegerValue(3),
          ]),
          ArrowArray(int32, [
            ArrowIntegerValue(1),
            ArrowIntegerValue(2),
            ArrowIntegerValue(8),
          ]),
          ArrowArray(string, const [
            ArrowStringValue(' Ab.c '),
            ArrowStringValue('abc'),
            null,
          ]),
        ],
      ),
    );
    addTearDown(source.close);

    final result = source.lazy().select([
      col('value').fillNull(0).alias('filled'),
      col('value').coalesce([col('fallback')]).alias('coalesced'),
      col('value').isIn(col('members')).alias('member'),
      col('text').stripChars().lowercase().alias('clean'),
      col('text').stringContains('.', literal: true).alias('has_dot'),
      col('value').sum.over([col('group')]).alias('group_sum'),
      col('value').shift(1).alias('shifted'),
      col('value').cumulativeSum().alias('cumulative'),
    ]).collectSync();
    addTearDown(result.close);
    final batch = result.exportSync();
    expect(_integers(batch.columns[0]), [1, 0, 3]);
    expect(_integers(batch.columns[1]), [1, 2, 3]);
    expect(_booleans(batch.columns[2]), [true, null, false]);
    expect(_strings(batch.columns[3]), ['ab.c', 'abc', null]);
    expect(_booleans(batch.columns[4]), [true, false, null]);
    expect(_integers(batch.columns[5]), [1, 1, 3]);
    expect(_integers(batch.columns[6]), [null, 1, null]);
    expect(_integers(batch.columns[7]), [1, null, 4]);

    final reshaped = source
        .lazy()
        .dropNulls(subset: ['value'])
        .drop(['fallback', 'members'])
        .rename({'text': 'label'})
        .select([col('group'), col('value'), col('label')])
        .collectSync();
    addTearDown(reshaped.close);
    expect(reshaped.shapeSync(), (2, 3));
    expect(reshaped.schemaSync().map((field) => field.name), [
      'group',
      'value',
      'label',
    ]);
  }, skip: skipNative);

  test('CSV, Parquet, distinct, concat, and join options execute', () {
    final int32 = ArrowIntegerType(32);
    final source = polars.fromRecordBatchSync(
      RecordBatch(
        ArrowSchema([ArrowField('key', int32), ArrowField('value', int32)]),
        [
          ArrowArray(int32, [
            ArrowIntegerValue(1),
            ArrowIntegerValue(1),
            ArrowIntegerValue(2),
          ]),
          ArrowArray(int32, [
            ArrowIntegerValue(10),
            ArrowIntegerValue(20),
            ArrowIntegerValue(30),
          ]),
        ],
      ),
    );
    addTearDown(source.close);

    final distinct = source
        .lazy()
        .distinct(subset: ['key'], keep: 'last', maintainOrder: true)
        .sort([col('key')])
        .collectSync();
    addTearDown(distinct.close);
    expect(_integers(distinct.exportSync().columns[1]), [20, 30]);

    final concatenated = polars
        .concat(
          [source.lazy(), source.lazy()],
          how: 'verticalRelaxed',
          rechunk: true,
        )
        .collectSync();
    addTearDown(concatenated.close);
    expect(concatenated.shapeSync(), (6, 2));

    final joined = source
        .lazy()
        .join(
          distinct.lazy(),
          leftOn: [col('key')],
          rightOn: [col('key')],
          suffix: '_lookup',
          coalesce: true,
        )
        .collectSync();
    addTearDown(joined.close);
    expect(joined.schemaSync().map((field) => field.name), [
      'key',
      'value',
      'value_lookup',
    ]);

    final directory = Directory.systemTemp.createTempSync('dartaframes-e2e-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final csvPath = '${directory.path}/frame.csv';
    final parquetPath = '${directory.path}/frame.parquet';
    source.writeCsvSync(csvPath, separator: ';');
    source.writeParquetSync(parquetPath, compression: 'snappy');

    final csv = polars.scanCsv(csvPath, separator: ';').collectSync();
    addTearDown(csv.close);
    expect(csv.shapeSync(), (3, 2));

    final parquet = polars.scanParquet(parquetPath).collectSync();
    addTearDown(parquet.close);
    expect(_integers(parquet.exportSync().columns[1]), [10, 20, 30]);
  }, skip: skipNative);

  test('numeric functions preserve null, NaN, and infinity semantics', () {
    final type = ArrowFloatingType(64);
    final source = polars.fromRecordBatchSync(
      RecordBatch(ArrowSchema([ArrowField('x', type)]), [
        ArrowArray(type, [
          ArrowFloatingValue(64, BigInt.parse('c004000000000000', radix: 16)),
          ArrowFloatingValue.float64(2.5),
          ArrowFloatingValue.float64(double.nan),
          ArrowFloatingValue.float64(double.infinity),
          ArrowFloatingValue(64, BigInt.parse('fff0000000000000', radix: 16)),
          null,
        ]),
      ]),
    );
    addTearDown(source.close);
    final expressions = <Expr>[
      col('x').abs().alias('abs'),
      col('x').floor().alias('floor'),
      col('x').ceil().alias('ceil'),
      col('x').round(mode: RoundMode.halfToEven).alias('even'),
      col('x').round(mode: RoundMode.halfAwayFromZero).alias('away'),
      col('x').round(mode: RoundMode.toZero).alias('zero'),
      col('x').clip(-1.0, 1.0).alias('clip'),
      col('x').fillNaN(7.0).alias('filled'),
      col('x').isFinite.alias('finite'),
      col('x').isInfinite.alias('infinite'),
      col('x').isNull.alias('null'),
      col('x').isNaN.alias('nan'),
    ];
    addTearDown(() {
      for (final expression in expressions) {
        expression.close();
      }
    });
    final plan = source.lazy().select(expressions);
    addTearDown(plan.close);
    final output = plan.collectSync();
    addTearDown(output.close);
    final batch = output.exportSync();
    expect(_doubles(batch.columns[0]).take(2), [2.5, 2.5]);
    expect(_doubles(batch.columns[1]).take(2), [-3.0, 2.0]);
    expect(_doubles(batch.columns[2]).take(2), [-2.0, 3.0]);
    expect(_doubles(batch.columns[3]).take(2), [-2.0, 2.0]);
    expect(_doubles(batch.columns[4]).take(2), [-3.0, 3.0]);
    expect(_doubles(batch.columns[5]).take(2), [-2.0, 2.0]);
    expect(_doubles(batch.columns[6]).take(2), [-1.0, 1.0]);
    expect(_doubles(batch.columns[7])[2], 7.0);
    expect(_doubles(batch.columns[7])[5], isNull);
    expect(_booleans(batch.columns[8]), [
      true,
      true,
      false,
      false,
      false,
      null,
    ]);
    expect(_booleans(batch.columns[9]), [
      false,
      false,
      false,
      true,
      true,
      null,
    ]);
    expect(_booleans(batch.columns[10]), [
      false,
      false,
      false,
      false,
      false,
      true,
    ]);
    expect(_booleans(batch.columns[11]), [
      false,
      false,
      true,
      false,
      false,
      null,
    ]);
  }, skip: skipNative);

  test('strict casts and every quantile interpolation execute natively', () {
    final strings = const ArrowUtf8Type();
    final source = polars.fromRecordBatchSync(
      RecordBatch(ArrowSchema([ArrowField('text', strings)]), [
        ArrowArray(strings, const [
          ArrowStringValue('1'),
          ArrowStringValue('bad'),
          null,
        ]),
      ]),
    );
    addTearDown(source.close);
    final strict = source.lazy().select([col('text').cast(const Int32Type())]);
    addTearDown(strict.close);
    expect(strict.collectSync, throwsA(isA<PolarsException>()));
    final relaxed = source.lazy().select([
      col('text').cast(const Int32Type(), strict: false),
    ]).collectSync();
    addTearDown(relaxed.close);
    expect(_integers(relaxed.exportSync().columns.single), [1, null, null]);

    final numberType = ArrowFloatingType(64);
    final numbers = polars.fromRecordBatchSync(
      RecordBatch(ArrowSchema([ArrowField('x', numberType)]), [
        ArrowArray(
          numberType,
          [
            0.0,
            10.0,
            20.0,
            30.0,
          ].map<ArrowValue?>(ArrowFloatingValue.float64).toList(),
        ),
      ]),
    );
    addTearDown(numbers.close);
    final methods = ['nearest', 'lower', 'higher', 'midpoint', 'linear'];
    final expressions = methods
        .map(
          (method) =>
              col('x').quantile(0.25, interpolation: method).alias(method),
        )
        .toList();
    addTearDown(() => expressions.forEach((expression) => expression.close()));
    final quantiles = numbers.lazy().select(expressions).collectSync();
    addTearDown(quantiles.close);
    expect(
      quantiles.exportSync().columns.map((column) => _doubles(column).single),
      [10.0, 0.0, 10.0, 5.0, 7.5],
    );
  }, skip: skipNative);

  test('submit wait take owns independent native resources', () async {
    final type = ArrowIntegerType(32);
    final source = polars.fromRecordBatchSync(
      RecordBatch(ArrowSchema([ArrowField('x', type)]), [
        ArrowArray(type, [ArrowIntegerValue(1), ArrowIntegerValue(2)]),
      ]),
    );
    final expression = col('x').sum.alias('sum');
    final plan = source.lazy().select([expression]);
    final pending = plan.submit();
    source.close();
    expression.close();
    plan.close();
    final job = await pending;
    final status = await job.wait(pollInterval: Duration.zero);
    expect(status.state, JobState.complete);
    final output = await job.take();
    addTearDown(output.close);
    expect(job.isClosed, isTrue);
    expect(_integers((await output.export()).columns.single), [3]);
  }, skip: skipNative);

  test('failed atomic write preserves an existing destination', () {
    final directory = Directory.systemTemp.createTempSync(
      'dartaframes-atomic-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}/output.parquet';
    File(path).writeAsStringSync('preserve-me');
    final source = polars.fromRecordBatchSync(
      RecordBatch(ArrowSchema([ArrowField('x', ArrowIntegerType(32))]), [
        ArrowArray(ArrowIntegerType(32), [ArrowIntegerValue(1)]),
      ]),
    );
    addTearDown(source.close);
    expect(
      () => source.writeParquetSync(path, compression: 'invalid'),
      throwsA(isA<PolarsException>()),
    );
    expect(File(path).readAsStringSync(), 'preserve-me');
  }, skip: skipNative);
}

List<int?> _integers(ArrowArray array) => array.values
    .map(
      (value) =>
          value == null ? null : (value as ArrowIntegerValue).value.toInt(),
    )
    .toList(growable: false);

List<bool?> _booleans(ArrowArray array) => array.values
    .map((value) => value == null ? null : (value as ArrowBooleanValue).value)
    .toList(growable: false);

List<String?> _strings(ArrowArray array) => array.values
    .map((value) => value == null ? null : (value as ArrowStringValue).value)
    .toList(growable: false);

List<double?> _doubles(ArrowArray array) => array.values
    .map((value) {
      if (value == null) return null;
      final floating = value as ArrowFloatingValue;
      final bytes = ByteData(8)
        ..setUint32(0, (floating.bits >> 32).toInt())
        ..setUint32(4, (floating.bits & BigInt.from(0xffffffff)).toInt());
      return bytes.getFloat64(0);
    })
    .toList(growable: false);
