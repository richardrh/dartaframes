import 'dart:io';

import 'package:dartaframes/polars.dart';
import 'package:test/test.dart';

void main() {
  final library = Platform.environment['DARTAFRAMES_NATIVE_LIBRARY'];
  final skipNative = library == null || library.isEmpty
      ? 'Set DARTAFRAMES_NATIVE_LIBRARY to the matrix-built library'
      : false;

  for (final format in _Format.values) {
    test(
      '${format.name} writes and scans a relational pipeline end to end',
      () => _exerciseFormat(library!, format),
      skip: skipNative,
    );
  }
}

enum _Format { csv, parquet }

void _exerciseFormat(String library, _Format format) {
  final polars = Polars.open(library);
  final directory = Directory.systemTemp.createTempSync(
    'dartaframes-${format.name}-relational-io-',
  );
  final cleanups = <void Function()>[];

  try {
    final transactions = polars.fromRecordBatchSync(_transactions());
    cleanups.add(transactions.close);
    final lookup = polars.fromRecordBatchSync(_lookup());
    cleanups.add(lookup.close);

    final transactionFile = File(
      '${directory.path}${Platform.pathSeparator}transactions.${format.name}',
    );
    final lookupFile = File(
      '${directory.path}${Platform.pathSeparator}lookup.${format.name}',
    );
    switch (format) {
      case _Format.csv:
        transactions.writeCsvSync(transactionFile.path);
        lookup.writeCsvSync(lookupFile.path);
      case _Format.parquet:
        transactions.writeParquetSync(
          transactionFile.path,
          compression: 'snappy',
        );
        lookup.writeParquetSync(lookupFile.path, compression: 'snappy');
    }

    expect(transactionFile.lengthSync(), greaterThan(0));
    expect(lookupFile.lengthSync(), greaterThan(0));
    _expectRelationalResult(
      polars,
      () => switch (format) {
        _Format.csv => polars.scanCsv(transactionFile.path),
        _Format.parquet => polars.scanParquet(transactionFile.path),
      },
      () => switch (format) {
        _Format.csv => polars.scanCsv(lookupFile.path),
        _Format.parquet => polars.scanParquet(lookupFile.path),
      },
    );
  } finally {
    try {
      _closeAll(cleanups);
    } finally {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    }
  }
}

void _expectRelationalResult(
  Polars polars,
  LazyFrame Function() scanTransactions,
  LazyFrame Function() scanLookup,
) {
  final cleanups = <void Function()>[];
  T own<T>(T value, void Function(T) close) {
    cleanups.add(() => close(value));
    return value;
  }

  try {
    final transactions = own(scanTransactions(), (value) => value.close());
    final lookup = own(scanLookup(), (value) => value.close());
    final category = own(polars.col('category'), (value) => value.close());
    final posted = own(polars.col('posted'), (value) => value.close());
    final amount = own(polars.col('amount'), (value) => value.close());
    final predicate = own(posted.eq(true), (value) => value.close());
    final amount64 = own(
      amount.cast(const Int64Type()),
      (value) => value.close(),
    );
    final sum = own(amount64.sum, (value) => value.close());
    final count = own(amount.count, (value) => value.close());
    final total = own(sum.alias('total_amount'), (value) => value.close());
    final transactionCount = own(
      count.alias('transaction_count'),
      (value) => value.close(),
    );
    final filtered = own(
      transactions.filter(predicate),
      (value) => value.close(),
    );
    final grouped = own(
      filtered.groupBy([category]).agg([total, transactionCount]),
      (value) => value.close(),
    );
    final joined = own(
      grouped.join(
        lookup,
        leftOn: [category],
        rightOn: [category],
        how: 'inner',
        coalesce: true,
      ),
      (value) => value.close(),
    );
    final sorted = own(joined.sort([category]), (value) => value.close());
    final result = own(sorted.collectSync(), (value) => value.close());

    final batch = result.exportSync();
    expect(
      batch.schema,
      ArrowSchema([
        ArrowField('category', const ArrowUtf8Type()),
        ArrowField('total_amount', ArrowIntegerType(64)),
        ArrowField('transaction_count', ArrowIntegerType(32, signed: false)),
        ArrowField('label', const ArrowUtf8Type()),
      ]),
    );
    expect(batch.length, 3);
    expect(_strings(batch.columns[0]), ['hardware', 'services', 'software']);
    expect(_integers(batch.columns[1]), [170, 200, 100]);
    expect(_integers(batch.columns[2]), [2, 1, 2]);
    expect(_strings(batch.columns[3]), ['Hardware', 'Services', 'Software']);
  } finally {
    _closeAll(cleanups);
  }
}

RecordBatch _transactions() {
  final string = const ArrowUtf8Type();
  final int32 = ArrowIntegerType(32);
  final boolean = const ArrowBooleanType();
  return RecordBatch(
    ArrowSchema([
      ArrowField('category', string),
      ArrowField('amount', int32),
      ArrowField('posted', boolean),
    ]),
    [
      ArrowArray(string, const [
        ArrowStringValue('hardware'),
        ArrowStringValue('hardware'),
        ArrowStringValue('hardware'),
        ArrowStringValue('services'),
        ArrowStringValue('services'),
        ArrowStringValue('software'),
        ArrowStringValue('software'),
        ArrowStringValue('software'),
        ArrowStringValue('unmatched'),
        ArrowStringValue('software'),
      ]),
      ArrowArray(int32, [
        ArrowIntegerValue(120),
        ArrowIntegerValue(50),
        ArrowIntegerValue(5),
        ArrowIntegerValue(200),
        ArrowIntegerValue(40),
        ArrowIntegerValue(60),
        ArrowIntegerValue(40),
        ArrowIntegerValue(25),
        ArrowIntegerValue(999),
        ArrowIntegerValue(1000),
      ]),
      ArrowArray(boolean, const [
        ArrowBooleanValue(true),
        ArrowBooleanValue(true),
        ArrowBooleanValue(false),
        ArrowBooleanValue(true),
        null,
        ArrowBooleanValue(true),
        ArrowBooleanValue(true),
        ArrowBooleanValue(false),
        ArrowBooleanValue(true),
        null,
      ]),
    ],
  );
}

RecordBatch _lookup() {
  final string = const ArrowUtf8Type();
  return RecordBatch(
    ArrowSchema([ArrowField('category', string), ArrowField('label', string)]),
    [
      ArrowArray(string, const [
        ArrowStringValue('hardware'),
        ArrowStringValue('services'),
        ArrowStringValue('software'),
      ]),
      ArrowArray(string, const [
        ArrowStringValue('Hardware'),
        ArrowStringValue('Services'),
        ArrowStringValue('Software'),
      ]),
    ],
  );
}

List<String?> _strings(ArrowArray array) => array.values
    .map((value) => value == null ? null : (value as ArrowStringValue).value)
    .toList();

List<int?> _integers(ArrowArray array) => array.values
    .map(
      (value) =>
          value == null ? null : (value as ArrowIntegerValue).value.toInt(),
    )
    .toList();

void _closeAll(List<void Function()> cleanups) {
  Object? firstError;
  StackTrace? firstStackTrace;
  for (final close in cleanups.reversed) {
    try {
      close();
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
  }
  if (firstError != null) {
    Error.throwWithStackTrace(firstError, firstStackTrace!);
  }
}
