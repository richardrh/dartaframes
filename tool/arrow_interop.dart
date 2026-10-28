// Dart half of the PyArrow interoperability loop.
//
// Reads every committed PyArrow fixture in test/fixtures/arrow_ipc with the
// public DartAframes Arrow IPC readers (PyArrow -> Dart), then re-encodes the
// decoded table with the public writers into an output directory mirroring
// `<family>/<name>.arrow|.arrows`. `tool/arrow_interop.py verify` then reads
// those files with PyArrow and compares them to the PyArrow expectations
// (Dart -> PyArrow), so a pass means real interoperability rather than a Dart
// self-round-trip.
//
// Usage:
//   dart run tool/arrow_interop.dart --out build/arrow_ipc_dart [--only family]
//   ~/.jcode/scratch/arrow-oracle/bin/python tool/arrow_interop.py \
//       verify --output build/arrow_ipc_dart
//
// Fixtures the Dart codec rejects (UnsupportedError/FormatException) are
// reported as UNSUPPORTED/READ-FAIL and simply not written; the Python
// verifier then lists them as MISSING. Exit code is 1 only for unexpected
// errors (anything other than an explicit UnsupportedError), or for any
// failure when `--strict` is given.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartaframes_polars/arrow.dart';

const _extensions = {'file': '.arrow', 'stream': '.arrows'};

Future<void> main(List<String> args) async {
  var out = 'build/arrow_ipc_dart';
  var fixtures = 'test/fixtures/arrow_ipc';
  var strict = false;
  final only = <String>{};
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--out':
        out = args[++i];
      case '--fixtures':
        fixtures = args[++i];
      case '--only':
        only.add(args[++i]);
      case '--strict':
        strict = true;
      case '-h' || '--help':
        stdout.writeln(
          'dart run tool/arrow_interop.dart [--out DIR] [--fixtures DIR] '
          '[--only FAMILY]... [--strict]',
        );
        return;
      default:
        stderr.writeln('unknown argument: ${args[i]}');
        exitCode = 64;
        return;
    }
  }

  final manifest = jsonDecode(
    File('$fixtures/manifest.json').readAsStringSync(),
  ) as Map<String, Object?>;
  var written = 0;
  var unsupported = 0;
  var failed = 0;
  for (final entry in (manifest['fixtures']! as List).cast<Map>()) {
    final family = entry['family'] as String;
    final name = entry['name'] as String;
    if (only.isNotEmpty && !only.contains(family)) continue;
    for (final format in (entry['formats'] as List).cast<String>()) {
      final rel = '$family/$name${_extensions[format]}';
      final input = File('$fixtures/$rel').readAsBytesSync();
      String status;
      try {
        final table = format == 'file'
            ? ArrowIpcFileReader(input).readTable()
            : ArrowIpcStreamReader(input).readTable();
        final Uint8List bytes = format == 'file'
            ? ArrowIpcFileWriter(
                schema: table.schema,
                batches: table.batches,
              ).write()
            : ArrowIpcStreamWriter(
                schema: table.schema,
                batches: table.batches,
              ).write();
        final target = File('$out/$rel');
        target.parent.createSync(recursive: true);
        target.writeAsBytesSync(bytes);
        written++;
        status =
            'WROTE      $rel (${table.rowCount} rows, '
            '${table.batches.length} batches)';
      } on UnsupportedError catch (e) {
        unsupported++;
        status = 'UNSUPPORTED $rel: ${e.message}';
      } on FormatException catch (e) {
        failed++;
        status = 'READ-FAIL  $rel: ${e.message}';
      } catch (e) {
        failed++;
        status = 'ERROR      $rel: $e';
      }
      stdout.writeln(status);
    }
  }
  stdout.writeln(
    '$written written, $unsupported unsupported, $failed failed -> $out',
  );
  if (failed > 0 || (strict && unsupported > 0)) exitCode = 1;
}
