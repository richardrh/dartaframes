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
  final scan = polars.scanCsv(csvPath);
  try {
    final limited = scan.head(3);
    try {
      final head = limited.collectSync();
      try {
        stdout.writeln('DataFrame head:');
        _printFrame(head);

        final ages = head.column('age');
        try {
          final doubledAges = ages * 2;
          try {
            final firstTwoAges = doubledAges.head(2);
            try {
              final seriesHead = firstTwoAges.toFrame();
              try {
                stdout.writeln('\nSeries head:');
                _printFrame(seriesHead);
              } finally {
                seriesHead.close();
              }
            } finally {
              firstTwoAges.close();
            }
          } finally {
            doubledAges.close();
          }
        } finally {
          ages.close();
        }

        final arrow = head.exportArrowC();
        late final DataFrame arrowRoundTrip;
        try {
          arrowRoundTrip = polars.fromArrowCData(arrow);
        } finally {
          // Import consumes the payload. Closing deletes the empty C structs.
          arrow.close();
        }
        try {
          final arrowHead = arrowRoundTrip.head(2);
          try {
            stdout.writeln('\nArrow C round-trip head:');
            _printFrame(arrowHead);
          } finally {
            arrowHead.close();
          }
        } finally {
          arrowRoundTrip.close();
        }
      } finally {
        head.close();
      }
    } finally {
      limited.close();
    }
  } finally {
    scan.close();
  }
}
