import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:dartaframes/polars.dart';

/// Dart/dartaframes side of the I/O comparison. Prints one JSON report.
void main(List<String> arguments) {
  try {
    final args = _Arguments(arguments);
    final polars = Polars.open(args.required('native-library'));
    final capabilities = polars.nativeCapabilitiesSync();
    final base = <String, Object?>{
      'implementation': 'dartaframes',
      'format': args.required('format'),
      'input': args.required('input'),
      'dart_version': Platform.version,
      'native_polars_version': capabilities.polars,
      'native_abi': capabilities.abi,
      'native_protocol': capabilities.protocol,
      'pid': pid,
    };
    final report = switch (args.mode) {
      'benchmark' => _benchmark(polars, args, base),
      'accuracy' => _accuracy(polars, args, base),
      _ => throw FormatException('mode must be benchmark or accuracy'),
    };
    stdout.writeln(jsonEncode(_sortObjects(report)));
  } catch (error, stack) {
    stderr.writeln('dart_runner: $error');
    stderr.writeln(stack);
    exitCode = 2;
  }
}

Map<String, Object?> _benchmark(
  Polars polars,
  _Arguments args,
  Map<String, Object?> base,
) {
  final warmups = args.integer('warmups', 1);
  final iterations = args.integer('iterations', 5);
  if (warmups < 0 || iterations < 1) {
    throw const FormatException('warmups must be >= 0 and iterations > 0');
  }
  final baseline = ProcessInfo.currentRss;
  final timings = <int>[];
  final live = <int>[];
  final after = <int>[];
  for (var index = 0; index < warmups + iterations; index++) {
    final watch = Stopwatch()..start();
    final plan = _scan(polars, args);
    final frame = plan.collectSync();
    watch.stop();
    final frameLive = ProcessInfo.currentRss;
    frame.close();
    plan.close();
    final afterClose = ProcessInfo.currentRss;
    if (index >= warmups) {
      timings.add(watch.elapsedMicroseconds * 1000);
      live.add(frameLive);
      after.add(afterClose);
    }
  }
  return {
    ...base,
    'mode': 'benchmark',
    'baseline_rss_bytes': baseline,
    'scan_collect_ns': timings,
    'frame_live_rss_bytes': live,
    'after_close_rss_bytes': after,
  };
}

Map<String, Object?> _accuracy(
  Polars polars,
  _Arguments args,
  Map<String, Object?> base,
) {
  final canonicalPath = args.required('canonical');
  final baseline = ProcessInfo.currentRss;
  final scanWatch = Stopwatch()..start();
  final plan = _scan(polars, args);
  final frame = plan.collectSync();
  scanWatch.stop();
  final live = ProcessInfo.currentRss;

  // exportSync is the copied FFI/JSON bridge and is intentionally excluded
  // from scan+collect timing and reported on its own.
  final exportWatch = Stopwatch()..start();
  final batch = frame.exportSync();
  exportWatch.stop();
  final encodeWatch = Stopwatch()..start();
  final object = const OwnedBatchJsonCodec().toJson(batch);
  final canonical = utf8.encode(jsonEncode(_sortObjects(object)));
  encodeWatch.stop();
  final writeWatch = Stopwatch()..start();
  File(canonicalPath).writeAsBytesSync(canonical, flush: true);
  writeWatch.stop();
  frame.close();
  plan.close();
  return {
    ...base,
    'mode': 'accuracy',
    'baseline_rss_bytes': baseline,
    'frame_live_rss_bytes': live,
    'after_close_rss_bytes': ProcessInfo.currentRss,
    'scan_collect_ns': scanWatch.elapsedMicroseconds * 1000,
    'export_bridge_ns': exportWatch.elapsedMicroseconds * 1000,
    'canonical_encode_ns': encodeWatch.elapsedMicroseconds * 1000,
    'canonical_write_ns': writeWatch.elapsedMicroseconds * 1000,
    'canonical_bytes': canonical.length,
    'canonical_path': canonicalPath,
  };
}

LazyFrame _scan(Polars polars, _Arguments args) {
  final path = args.required('input');
  return switch (args.required('format')) {
    'csv' => polars.scanCsv(path, tryParseDates: true),
    'parquet' => polars.scanParquet(path),
    _ => throw const FormatException('format must be csv or parquet'),
  };
}

Object? _sortObjects(Object? value) {
  if (value is Map) {
    final sorted = SplayTreeMap<String, Object?>();
    for (final entry in value.entries) {
      sorted[entry.key as String] = _sortObjects(entry.value);
    }
    return sorted;
  }
  if (value is List) return value.map(_sortObjects).toList(growable: false);
  return value;
}

final class _Arguments {
  _Arguments(List<String> values) {
    if (values.isEmpty || values.first.startsWith('--')) {
      throw const FormatException(
        'first argument must be benchmark or accuracy',
      );
    }
    mode = values.first;
    for (var index = 1; index < values.length; index += 2) {
      if (!values[index].startsWith('--') || index + 1 >= values.length) {
        throw FormatException('expected --name value near ${values[index]}');
      }
      options[values[index].substring(2)] = values[index + 1];
    }
  }

  late final String mode;
  final options = <String, String>{};

  String required(String name) =>
      options[name] ?? (throw FormatException('missing --$name'));

  int integer(String name, int fallback) {
    final source = options[name];
    if (source == null) return fallback;
    return int.tryParse(source) ??
        (throw FormatException('--$name must be an integer'));
  }
}
