// Interoperability tests against independent PyArrow-generated fixtures.
//
// Fixtures and expectations live in test/fixtures/arrow_ipc and are produced
// by tool/arrow_interop.py with official PyArrow (see that script for the
// canonical JSON value encoding mirrored by `_encode` below). These tests run
// in ordinary CI without Python: they decode every committed fixture through
// the public readers and compare schema, metadata, batch boundaries, null
// counts, dictionary layout and canonical values (raw float bits, unscaled
// decimals, raw temporal counters) with the PyArrow expectations, and then
// check that the public writers re-encode the same content.
//
// The Dart -> PyArrow direction needs PyArrow and is exercised by
//   dart run tool/arrow_interop.dart --out DIR
//   python tool/arrow_interop.py verify --output DIR
//
// Gaps are explicit: every fixture listed in [_knownGaps] must still fail
// with the recorded error type. A gap that starts passing fails the test so
// the list is kept honest, and any failure outside the list fails as usual.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartaframes_polars/arrow.dart';
import 'package:test/test.dart';

const _root = 'test/fixtures/arrow_ipc';

/// Fixture keys (`family/name`) the Dart codec does not support yet, mapped to
/// the error type it is expected to raise. Keep in sync with lib/arrow.dart
/// documentation of unsupported families.
const Map<String, Type> _knownGaps = {
  // Arrow metadata values are arbitrary bytes; the Dart model stores
  // Map<String, String> and deliberately refuses lossy decoding.
  'extension/binary_metadata': FormatException,
};

void main() {
  final manifest = jsonDecode(
    File('$_root/manifest.json').readAsStringSync(),
  ) as Map<String, Object?>;
  final entries = (manifest['fixtures']! as List).cast<Map<String, Object?>>();

  test('manifest lists fixtures and known gaps refer to real fixtures', () {
    final keys = {for (final e in entries) '${e['family']}/${e['name']}'};
    expect(keys, isNotEmpty);
    for (final gap in _knownGaps.keys) {
      expect(keys, contains(gap), reason: 'stale known gap $gap');
    }
  });

  for (final entry in entries) {
    final key = '${entry['family']}/${entry['name']}';
    final expectation = jsonDecode(
      File('$_root/${entry['expectation']}').readAsStringSync(),
    ) as Map<String, Object?>;
    final files = (expectation['files']! as Map).cast<String, String>();
    group(key, () {
      for (final MapEntry(key: format, value: fileName) in files.entries) {
        final bytes = File('$_root/${entry['family']}/$fileName')
            .readAsBytesSync();
        final gap = _knownGaps[key];
        if (gap != null) {
          test('$format: known gap still raises $gap', () {
            Object? error;
            ArrowTable? table;
            try {
              table = _read(format, bytes);
            } catch (e) {
              error = e;
            }
            if (table != null) {
              final problems = _compare(expectation, table);
              fail(
                'Known gap $key now decodes '
                '(${problems.isEmpty ? 'and matches PyArrow' : 'but differs: ${problems.join('; ')}'}). '
                'Remove it from _knownGaps and verify with tool/arrow_interop.py.',
              );
            }
            expect(
              error.runtimeType.toString(),
              startsWith(gap.toString()),
              reason: 'unexpected error for known gap: $error',
            );
          });
          continue;
        }
        test('$format: PyArrow -> Dart matches expectation', () {
          final table = _read(format, bytes);
          final problems = _compare(expectation, table);
          expect(problems, isEmpty, reason: problems.join('\n'));
        });
        test('$format: Dart writer re-encodes identical content', () {
          final table = _read(format, bytes);
          final written = format == 'file'
              ? ArrowIpcFileWriter(
                  schema: table.schema,
                  batches: table.batches,
                ).write()
              : ArrowIpcStreamWriter(
                  schema: table.schema,
                  batches: table.batches,
                ).write();
          final reread = _read(format, written);
          final problems = _compare(expectation, reread, dictionaries: false);
          expect(problems, isEmpty, reason: problems.join('\n'));
        });
      }
    });
  }
}

ArrowTable _read(String format, Uint8List bytes) => format == 'file'
    ? ArrowIpcFileReader(bytes).readTable()
    : ArrowIpcStreamReader(bytes).readTable();

/// Compares a decoded table with a PyArrow expectation. When [dictionaries]
/// is false the physical per-batch dictionary layout is ignored (writers may
/// legitimately re-emit dictionaries differently, e.g. without deltas).
List<String> _compare(
  Map<String, Object?> expectation,
  ArrowTable table, {
  bool dictionaries = true,
}) {
  final got = _summarize(table);
  final want = <String, Object?>{
    for (final k in ['schema', 'num_rows', 'batch_row_counts', 'columns'])
      // Deep copy: the expectation map is shared between tests.
      k: jsonDecode(jsonEncode(expectation[k])),
  };
  if (!dictionaries) {
    for (final cols in [want['columns'], got['columns']]) {
      for (final c in (cols! as List).cast<Map>()) {
        c.remove('dictionary');
      }
    }
  }
  final problems = <String>[];
  _diff('', want, got, problems);
  return problems;
}

Map<String, Object?> _summarize(ArrowTable table) {
  final schema = table.schema;
  final columns = <Object?>[];
  for (var i = 0; i < schema.fields.length; i++) {
    final field = schema.fields[i];
    final chunks = [for (final b in table.batches) b.columns[i]];
    final values = <Object?>[];
    var nullCount = 0;
    for (final chunk in chunks) {
      values.addAll(_encodeArray(chunk));
      nullCount += _nullCount(chunk);
    }
    columns.add({
      'name': field.name,
      'null_count': nullCount,
      'values': values,
      if (_storage(field.type) is ArrowDictionaryType)
        'dictionary': [
          for (final chunk in chunks)
            {
              'indices': [
                for (final v in chunk.values)
                  v == null
                      ? null
                      : _int(
                          (_storageValue(v) as ArrowDictionaryIndexValue).index,
                          ((_storage(
                                    field.type,
                                  ) as ArrowDictionaryType).indexType
                                  as ArrowIntegerType)
                              .bitWidth,
                        ),
              ],
              'values': _encodeArray(chunk.dictionary!),
            },
        ],
    });
  }
  return {
    'schema': {
      'fields': [for (final f in schema.fields) _describeField(f)],
      if (schema.metadata.isNotEmpty) 'metadata': schema.metadata,
    },
    'num_rows': table.rowCount,
    'batch_row_counts': [for (final b in table.batches) b.rowCount],
    'columns': columns,
  };
}

ArrowDataType _storage(ArrowDataType t) =>
    t is ArrowExtensionType ? _storage(t.storageType) : t;

int _nullCount(ArrowArray array) {
  final t = _storage(array.type);
  // PyArrow reports no top-level nulls for unions and run-end encoded arrays.
  if (t is ArrowUnionType || t is ArrowRunEndEncodedType) return 0;
  return array.validity.where((v) => !v).length;
}

List<Object?> _encodeArray(ArrowArray array) => [
  for (final value in array.values)
    _encode(array.type, value, [
      if (array.dictionary != null) array.dictionary!,
      ...array.nestedDictionaries,
    ]),
];

ArrowValue _storageValue(ArrowValue value) =>
    value is ArrowExtensionValue ? _storageValue(value.storage) : value;

List<ArrowArray> _childDictionaries(
  List<ArrowField> fields,
  int index,
  List<ArrowArray> dictionaries,
) {
  int count(ArrowDataType type) =>
      nestedDictionaryTypes(type).length +
      (_storage(type) is ArrowDictionaryType ? 1 : 0);
  final offset = fields.take(index).fold<int>(0, (n, f) => n + count(f.type));
  return dictionaries.sublist(offset, offset + count(fields[index].type));
}

const _unitNames = {
  ArrowTimeUnit.second: 's',
  ArrowTimeUnit.millisecond: 'ms',
  ArrowTimeUnit.microsecond: 'us',
  ArrowTimeUnit.nanosecond: 'ns',
};

Object? _int(BigInt v, int bitWidth) =>
    bitWidth >= 64 ? v.toString() : v.toInt();

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Object? _encode(
  ArrowDataType type,
  ArrowValue? value, [
  List<ArrowArray> dictionaries = const [],
]) {
  if (value == null) return null;
  switch (type) {
    case ArrowExtensionType(:final storageType):
      final storage = value is ArrowExtensionValue ? value.storage : value;
      return _encode(storageType, storage, dictionaries);
    case ArrowBooleanType():
      return (value as ArrowBooleanValue).value;
    case ArrowIntegerType(:final bitWidth):
      return _int((value as ArrowIntegerValue).value, bitWidth);
    case ArrowFloatingType():
      return '0x${(value as ArrowFloatingValue).hexadecimalBits}';
    case ArrowDecimalType():
      return (value as ArrowDecimalValue).unscaled.toString();
    case ArrowUtf8Type():
      return (value as ArrowStringValue).value;
    case ArrowBinaryType() || ArrowFixedSizeBinaryType():
      return _hex((value as ArrowBinaryValue).bytes);
    case ArrowDateType(:final unit):
      return _int(
        (value as ArrowTemporalValue).value,
        unit == ArrowDateUnit.day ? 32 : 64,
      );
    case ArrowTimeType(:final unit):
      final narrow =
          unit == ArrowTimeUnit.second || unit == ArrowTimeUnit.millisecond;
      return _int((value as ArrowTemporalValue).value, narrow ? 32 : 64);
    case ArrowTimestampType() || ArrowDurationType():
      return (value as ArrowTemporalValue).value.toString();
    case ArrowIntervalType():
      final v = value as ArrowIntervalValue;
      return [v.months, v.days, v.nanoseconds.toString()];
    case ArrowListType(:final field) || ArrowFixedSizeListType(:final field):
      return [
        for (final item in (value as ArrowListValue).values)
          _encode(field.type, item, dictionaries),
      ];
    case ArrowStructType(:final fields):
      final v = value as ArrowStructValue;
      return {
        for (var i = 0; i < fields.length; i++)
          fields[i].name: _encode(
            fields[i].type,
            v.fields[i].value,
            _childDictionaries(fields, i, dictionaries),
          ),
      };
    case ArrowMapType(:final keyField, :final valueField):
      return [
        for (final e in (value as ArrowMapValue).entries)
          [
            _encode(
              keyField.type,
              e.key,
              _childDictionaries([keyField, valueField], 0, dictionaries),
            ),
            _encode(
              valueField.type,
              e.value,
              _childDictionaries([keyField, valueField], 1, dictionaries),
            ),
          ],
      ];
    case ArrowUnionType():
      final v = value as ArrowUnionValue;
      return {
        'type_code': v.typeId,
        'value': _encode(
          type.fieldForTypeId(v.typeId)!.type,
          v.value,
          _childDictionaries(
            type.fields,
            type.typeIds.indexOf(v.typeId),
            dictionaries,
          ),
        ),
      };
    case ArrowRunEndEncodedType(:final valuesField):
      return _encode(valuesField.type, value, dictionaries);
    case ArrowDictionaryType():
      return _encodeArray(
        dictionaries.first,
      )[(value as ArrowDictionaryIndexValue).index.toInt()];
    case ArrowNullType():
      throw StateError('unexpected value for $type');
  }
}

Map<String, Object?> _describeField(ArrowField f) {
  final metadata = <String, String>{...f.metadata};
  var type = f.type;
  if (type is ArrowExtensionType) {
    metadata['ARROW:extension:name'] = type.name;
    if (type.metadata != null) {
      metadata['ARROW:extension:metadata'] = type.metadata!;
    }
    type = type.storageType;
  }
  return {
    'name': f.name,
    'nullable': f.nullable,
    'type': _describeType(type),
    if (metadata.isNotEmpty) 'metadata': metadata,
  };
}

String _layout(String base, ArrowOffsetWidth w) => switch (w) {
  ArrowOffsetWidth.normal => base,
  ArrowOffsetWidth.large => 'large_$base',
  ArrowOffsetWidth.view => '${base}_view',
};

Map<String, Object?> _describeType(ArrowDataType t) => switch (t) {
  ArrowNullType() => {'id': 'null'},
  ArrowBooleanType() => {'id': 'bool'},
  ArrowIntegerType(:final bitWidth, :final signed) => {
    'id': '${signed ? 'int' : 'uint'}$bitWidth',
  },
  ArrowFloatingType(:final bitWidth) => {'id': 'float$bitWidth'},
  ArrowDecimalType(:final bitWidth, :final precision, :final scale) => {
    'id': 'decimal$bitWidth',
    'precision': precision,
    'scale': scale,
  },
  ArrowUtf8Type(:final offsetWidth) => {'id': _layout('utf8', offsetWidth)},
  ArrowBinaryType(:final offsetWidth) => {'id': _layout('binary', offsetWidth)},
  ArrowFixedSizeBinaryType(:final byteWidth) => {
    'id': 'fixed_size_binary',
    'byte_width': byteWidth,
  },
  ArrowDateType(:final unit) => {
    'id': unit == ArrowDateUnit.day ? 'date32' : 'date64',
  },
  ArrowTimeType(:final unit) => {
    'id': unit == ArrowTimeUnit.second || unit == ArrowTimeUnit.millisecond
        ? 'time32'
        : 'time64',
    'unit': _unitNames[unit],
  },
  ArrowTimestampType(:final unit, :final timeZone) => {
    'id': 'timestamp',
    'unit': _unitNames[unit],
    'timezone': timeZone,
  },
  ArrowDurationType(:final unit) => {
    'id': 'duration',
    'unit': _unitNames[unit],
  },
  ArrowIntervalType(:final unit) => {
    'id': switch (unit) {
      ArrowIntervalUnit.monthDayNano => 'interval_month_day_nano',
      ArrowIntervalUnit.yearMonth => 'interval_year_month',
      ArrowIntervalUnit.dayTime => 'interval_day_time',
    },
  },
  ArrowListType(:final field, :final offsetWidth, :final view) => {
    'id':
        '${offsetWidth == ArrowOffsetWidth.large ? 'large_' : ''}'
        'list${view ? '_view' : ''}',
    'children': [_describeField(field)],
  },
  ArrowFixedSizeListType(:final field, :final size) => {
    'id': 'fixed_size_list',
    'list_size': size,
    'children': [_describeField(field)],
  },
  ArrowStructType(:final fields) => {
    'id': 'struct',
    'children': [for (final f in fields) _describeField(f)],
  },
  ArrowDictionaryType(:final indexType, :final valueType, :final ordered) => {
    'id': 'dictionary',
    'index': _describeType(indexType),
    'value': _describeType(valueType),
    'ordered': ordered,
  },
  ArrowMapType(
    :final keyField,
    :final valueField,
    :final keysSorted,
    :final entriesName,
    :final entriesMetadata,
  ) =>
    {
      'id': 'map',
      'keys_sorted': keysSorted,
      'children': [
        {
          'name': entriesName,
          'nullable': false,
          'type': {
            'id': 'struct',
            'children': [_describeField(keyField), _describeField(valueField)],
          },
          if (entriesMetadata.isNotEmpty) 'metadata': entriesMetadata,
        },
      ],
    },
  ArrowUnionType(:final mode, :final typeIds, :final fields) => {
    'id': '${mode.name}_union',
    'type_codes': typeIds,
    'children': [for (final f in fields) _describeField(f)],
  },
  ArrowRunEndEncodedType(:final runEndsField, :final valuesField) => {
    'id': 'run_end_encoded',
    'children': [_describeField(runEndsField), _describeField(valuesField)],
  },
  ArrowExtensionType() => throw StateError('nested extension $t'),
};

void _diff(String path, Object? want, Object? got, List<String> out) {
  if (out.length >= 20) return;
  if (want is Map && got is Map) {
    for (final k in {...want.keys, ...got.keys}) {
      if (!want.containsKey(k)) {
        out.add('$path.$k: unexpected ${_short(got[k])}');
      } else if (!got.containsKey(k)) {
        out.add('$path.$k: missing (expected ${_short(want[k])})');
      } else {
        _diff('$path.$k', want[k], got[k], out);
      }
    }
  } else if (want is List && got is List) {
    if (want.length != got.length) {
      out.add('$path: length ${got.length} != expected ${want.length}');
    }
    for (var i = 0; i < want.length && i < got.length; i++) {
      _diff('$path[$i]', want[i], got[i], out);
    }
  } else if (want != got) {
    out.add('$path: got ${_short(got)} expected ${_short(want)}');
  }
}

String _short(Object? v) {
  final s = jsonEncode(v);
  return s.length > 120 ? '${s.substring(0, 120)}...' : s;
}
