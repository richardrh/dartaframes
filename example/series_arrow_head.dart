import 'dart:convert';
import 'dart:io';

import 'package:dartaframes/polars.dart';

String _display(Object? value) {
  if (value == null) return 'null';
  if (value is Map && value.containsKey('value')) {
    return value['value'].toString();
  }
  if (value is String || value is num || value is bool) {
    return value.toString();
  }
  return jsonEncode(value);
}

void _printFrame(DataFrame frame) {
  final batch = frame.exportSync();
  final encoded = const OwnedBatchJsonCodec().toJson(batch);
  final columns = (encoded['columns'] as List).cast<Map>();

  stdout.writeln(columns.map((column) => column['name']).join('\t'));
  for (var row = 0; row < batch.length; row++) {
    stdout.writeln(
      columns
          .map((column) => _display((column['values'] as List)[row]))
          .join('\t'),
    );
  }
}

void main(List<String> arguments) {
  String? libraryPath;
  var csvPath = 'example/series_arrow_people.csv';
  if (arguments.isNotEmpty && arguments.first == '--library') {
    if (arguments.length < 2) {
      stderr.writeln('Missing path after --library');
      exitCode = 64;
      return;
    }
    libraryPath = arguments[1];
    arguments = arguments.sublist(2);
  }
  if (arguments.length > 1 ||
      (arguments.isNotEmpty && arguments.first.startsWith('--'))) {
    stderr.writeln(
      'Usage: dart run example/series_arrow_head.dart '
      '[--library <native-library>] [csv-path]',
    );
    exitCode = 64;
    return;
  }

  if (arguments.isNotEmpty) csvPath = arguments.first;
  if (libraryPath != null && !File(libraryPath).existsSync()) {
    stderr.writeln('Native ABI-2 library not found: $libraryPath');
    exitCode = 66;
    return;
  }
  if (!File(csvPath).existsSync()) {
    stderr.writeln('CSV fixture not found: $csvPath');
    exitCode = 66;
    return;
  }

  final polars = libraryPath == null
      ? Polars.native()
      : Polars.open(libraryPath);
  final head = polars.scanCsv(csvPath).head(3).collectSync();

  stdout.writeln('DataFrame head:');
  _printFrame(head);

  final seriesHead = (head.column('age') * 2).head(2).toFrame();
  stdout.writeln('\nSeries head:');
  _printFrame(seriesHead);

  final arrow = head.exportArrowC();
  final arrowRoundTrip = polars.fromArrowCData(arrow);
  // Import consumes the payload. Closing deletes the empty C structs.
  arrow.close();

  final arrowHead = arrowRoundTrip.head(2);
  stdout.writeln('\nArrow C round-trip head:');
  _printFrame(arrowHead);

  // Native-backed values have finalizers. Explicit close calls are useful in
  // long-running processes when deterministic release is desirable.
  arrowHead.close();
  arrowRoundTrip.close();
  seriesHead.close();
  head.close();
}
