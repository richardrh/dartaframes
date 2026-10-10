part of 'ipc.dart';

// Standard Arrow physical layouts. Children recurse through the common codec.
void _writeExtendedValues(
  _BodyWriter w,
  ArrowDataType type,
  List<ArrowValue?> values,
) {
  switch (type) {
    case ArrowFixedSizeBinaryType(:final byteWidth):
      w.nodeWithValidity(values);
      final bytes = Uint8List(values.length * byteWidth);
      for (var i = 0; i < values.length; i++) {
        final v = values[i] as ArrowBinaryValue?;
        if (v != null) {
          bytes.setRange(i * byteWidth, (i + 1) * byteWidth, v.bytes);
        }
      }
      w.buffer(bytes);
    case ArrowUtf8Type() || ArrowBinaryType():
      _writeBinaryViews(w, type, values);
    case ArrowListType():
      _writeListViews(w, type, values);
    case ArrowMapType():
      _writeMap(w, type, values);
    case ArrowUnionType():
      _writeUnion(w, type, values);
    case ArrowIntervalType():
      _writeInterval(w, type, values);
    case ArrowRunEndEncodedType():
      _writeRunEnds(w, type, values);
    default:
      throw UnsupportedError('No standard Arrow IPC layout for $type');
  }
}

List<ArrowValue?> _readExtendedValues(_BodyReader r, ArrowDataType type) =>
    switch (type) {
      ArrowFixedSizeBinaryType(:final byteWidth) => _readExtendedFixed(
        r,
        byteWidth,
        (b) => ArrowBinaryValue(b),
      ),
      ArrowUtf8Type() || ArrowBinaryType() => _readBinaryViews(r, type),
      ArrowListType() => _readListViews(r, type),
      ArrowMapType() => _readMap(r, type),
      ArrowUnionType() => _readUnion(r, type),
      ArrowIntervalType() => _readExtendedFixed(
        r,
        _intervalWidth(type.unit),
        (b) => _intervalValue(type.unit, b),
      ),
      ArrowRunEndEncodedType() => _readRunEnds(r, type),
      _ => throw UnsupportedError('No standard Arrow IPC layout for $type'),
    };

List<ArrowValue?> _readExtendedFixed(
  _BodyReader r,
  int width,
  ArrowValue Function(Uint8List) make,
) {
  final n = _checkedNode(r);
  final valid = r.validity(n, r.buffer());
  final bytes = r.buffer();
  _requireBytes(bytes, n.length * width);
  return List.generate(
    n.length,
    (i) => valid[i]
        ? make(Uint8List.sublistView(bytes, i * width, (i + 1) * width))
        : null,
  );
}

void _requireBytes(Uint8List bytes, int length) {
  if (bytes.length < length) {
    throw const FormatException('Arrow values buffer is too short');
  }
}

void _writeBinaryViews(
  _BodyWriter w,
  ArrowDataType type,
  List<ArrowValue?> values,
) {
  final views = Uint8List(values.length * 16);
  final data = ByteData.sublistView(views);
  final payload = BytesBuilder(copy: false);
  for (var i = 0; i < values.length; i++) {
    final value = values[i];
    if (value == null) continue;
    final bytes = type is ArrowUtf8Type
        ? utf8.encode((value as ArrowStringValue).value)
        : (value as ArrowBinaryValue).bytes;
    final offset = i * 16;
    data.setInt32(offset, bytes.length, Endian.little);
    if (bytes.length <= 12) {
      views.setRange(offset + 4, offset + 4 + bytes.length, bytes);
    } else {
      views.setRange(offset + 4, offset + 8, bytes);
      data.setInt32(offset + 12, payload.length, Endian.little);
      payload.add(bytes);
    }
  }
  w.nodeWithValidity(values);
  w.buffer(views);
  w.variadicCount(payload.isEmpty ? 0 : 1);
  if (payload.isNotEmpty) w.buffer(payload.takeBytes());
}

List<ArrowValue?> _readBinaryViews(_BodyReader r, ArrowDataType type) {
  final n = _checkedNode(r);
  final valid = r.validity(n, r.buffer());
  final views = r.buffer();
  _requireBytes(views, n.length * 16);
  final count = r.variadicCount();
  if (count < 0 || count > r.limits.maxBuffers) {
    throw const FormatException('Invalid variadic buffer count');
  }
  final payloads = [for (var i = 0; i < count; i++) r.buffer()];
  return List.generate(n.length, (i) {
    if (!valid[i]) return null;
    final bytes = _binaryViewBytes(views, i * 16, payloads);
    return type is ArrowUtf8Type
        ? ArrowStringValue(_utf8(bytes))
        : ArrowBinaryValue(bytes);
  });
}

Uint8List _binaryViewBytes(
  Uint8List views,
  int offset,
  List<Uint8List> payloads,
) {
  final data = ByteData.sublistView(views);
  final length = data.getInt32(offset, Endian.little);
  if (length < 0) throw const FormatException('Negative binary view length');
  if (length <= 12) {
    return Uint8List.sublistView(views, offset + 4, offset + 4 + length);
  }
  final index = data.getInt32(offset + 8, Endian.little);
  final start = data.getInt32(offset + 12, Endian.little);
  if (index < 0 || index >= payloads.length) {
    throw const FormatException('Invalid binary view buffer index');
  }
  final payload = payloads[index];
  if (start < 0 || start > payload.length - length) {
    throw const FormatException('Binary view exceeds data buffer');
  }
  for (var j = 0; j < 4; j++) {
    if (views[offset + 4 + j] != payload[start + j]) {
      throw const FormatException('Binary view prefix mismatch');
    }
  }
  return Uint8List.sublistView(payload, start, start + length);
}

void _writeListViews(
  _BodyWriter w,
  ArrowListType type,
  List<ArrowValue?> values,
) {
  final offsets = <int>[];
  final sizes = <int>[];
  final children = <ArrowValue?>[];
  for (final value in values) {
    offsets.add(children.length);
    final items = (value as ArrowListValue?)?.values ?? const <ArrowValue?>[];
    sizes.add(items.length);
    children.addAll(items);
  }
  w.nodeWithValidity(values);
  w.buffer(_offsets(offsets, type.offsetWidth));
  w.buffer(_offsets(sizes, type.offsetWidth));
  _writeValues(w, type.field.type, children);
}

// View offsets and union offsets are not monotonic.
List<int> _readUnorderedOffsets(
  Uint8List bytes,
  int length,
  ArrowOffsetWidth width,
) {
  final size = width == ArrowOffsetWidth.large ? 8 : 4;
  _requireBytes(bytes, length * size);
  final data = ByteData.sublistView(bytes);
  return List.generate(
    length,
    (i) => size == 4
        ? data.getInt32(i * size, Endian.little)
        : _getInt64(data, i * size),
  );
}

List<ArrowValue?> _readListViews(_BodyReader r, ArrowListType type) {
  final n = _checkedNode(r);
  final valid = r.validity(n, r.buffer());
  final offsets = _readUnorderedOffsets(r.buffer(), n.length, type.offsetWidth);
  final sizes = _readUnorderedOffsets(r.buffer(), n.length, type.offsetWidth);
  final children = _readValues(r, type.field.type);
  return List.generate(n.length, (i) {
    if (!valid[i]) return null;
    final start = offsets[i];
    final size = sizes[i];
    if (start < 0 || size < 0 || start > children.length - size) {
      throw const FormatException('List view exceeds child array');
    }
    r.budget.charge(size);
    return ArrowListValue(children.sublist(start, start + size));
  });
}

void _writeMap(_BodyWriter w, ArrowMapType type, List<ArrowValue?> values) {
  _writeList(
    w,
    [
      for (final value in values)
        value == null
            ? null
            : ArrowListValue([
                for (final entry in (value as ArrowMapValue).entries)
                  ArrowStructValue([
                    ArrowStructEntry(type.keyField.name, entry.key),
                    ArrowStructEntry(type.valueField.name, entry.value),
                  ]),
              ]),
    ],
    type.entriesField,
    ArrowOffsetWidth.normal,
  );
}

List<ArrowValue?> _readMap(_BodyReader r, ArrowMapType type) {
  final rows = _readList(r, type.entriesField, ArrowOffsetWidth.normal);
  return [
    for (final row in rows)
      row == null
          ? null
          : ArrowMapValue([
              for (final entry in (row as ArrowListValue).values)
                _mapEntry(entry),
            ]),
  ];
}

ArrowMapEntry _mapEntry(ArrowValue? entry) {
  if (entry is! ArrowStructValue || entry.fields[0].value == null) {
    throw const FormatException('Map entries and keys must not be null');
  }
  return ArrowMapEntry(entry.fields[0].value!, entry.fields[1].value);
}

void _writeUnion(_BodyWriter w, ArrowUnionType type, List<ArrowValue?> values) {
  final dense = type.mode == ArrowUnionMode.dense;
  final children = [for (final _ in type.fields) <ArrowValue?>[]];
  final ids = Uint8List(values.length);
  final offsets = <int>[];
  for (var i = 0; i < values.length; i++) {
    final value = values[i] as ArrowUnionValue?;
    if (type.fields.isEmpty) {
      throw ArgumentError('Nonempty union needs a child');
    }
    final id = value?.typeId ?? type.typeIds.first;
    final child = type.typeIds.indexOf(id);
    if (child < 0) throw ArgumentError('Unknown union type id $id');
    ids[i] = id;
    offsets.add(children[child].length);
    if (dense) {
      children[child].add(value?.value);
    } else {
      for (var c = 0; c < children.length; c++) {
        children[c].add(c == child ? value?.value : null);
      }
    }
  }
  w.node(values.length, 0);
  w.buffer(ids);
  if (dense) w.buffer(_offsets(offsets, ArrowOffsetWidth.normal));
  for (var c = 0; c < children.length; c++) {
    _writeValues(w, type.fields[c].type, children[c]);
  }
}

List<ArrowValue?> _readUnion(_BodyReader r, ArrowUnionType type) {
  final n = _checkedNode(r);
  if (n.nullCount != 0) {
    throw const FormatException('Union cannot have a top-level null count');
  }
  final ids = r.buffer();
  _requireBytes(ids, n.length);
  final offsets = type.mode == ArrowUnionMode.dense
      ? _readUnorderedOffsets(r.buffer(), n.length, ArrowOffsetWidth.normal)
      : List.generate(n.length, (i) => i);
  final children = [
    for (final field in type.fields) _readValues(r, field.type),
  ];
  if (type.mode == ArrowUnionMode.sparse &&
      children.any((c) => c.length != n.length)) {
    throw const FormatException('Sparse union child length mismatch');
  }
  return List.generate(n.length, (i) {
    final child = type.typeIds.indexOf(ids[i]);
    if (child < 0) throw const FormatException('Unknown union type id');
    final offset = offsets[i];
    if (offset < 0 || offset >= children[child].length) {
      throw const FormatException('Union offset exceeds child array');
    }
    return ArrowUnionValue(ids[i], children[child][offset]);
  });
}

int _intervalWidth(ArrowIntervalUnit unit) => switch (unit) {
  ArrowIntervalUnit.yearMonth => 4,
  ArrowIntervalUnit.dayTime => 8,
  ArrowIntervalUnit.monthDayNano => 16,
};

void _writeInterval(
  _BodyWriter w,
  ArrowIntervalType type,
  List<ArrowValue?> values,
) {
  final width = _intervalWidth(type.unit);
  final bytes = Uint8List(values.length * width);
  final data = ByteData.sublistView(bytes);
  for (var i = 0; i < values.length; i++) {
    final value = values[i] as ArrowIntervalValue?;
    if (value == null) continue;
    final offset = i * width;
    data.setInt32(
      offset,
      type.unit == ArrowIntervalUnit.dayTime ? value.days : value.months,
      Endian.little,
    );
    if (width >= 8) {
      data.setInt32(
        offset + 4,
        type.unit == ArrowIntervalUnit.dayTime
            ? value.milliseconds
            : value.days,
        Endian.little,
      );
    }
    if (width == 16) _putInteger(bytes, offset + 8, 8, value.nanoseconds);
  }
  w.nodeWithValidity(values);
  w.buffer(bytes);
}

ArrowIntervalValue _intervalValue(ArrowIntervalUnit unit, Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final first = data.getInt32(0, Endian.little);
  return switch (unit) {
    ArrowIntervalUnit.yearMonth => ArrowIntervalValue.yearMonth(first),
    ArrowIntervalUnit.dayTime => ArrowIntervalValue.dayTime(
      first,
      data.getInt32(4, Endian.little),
    ),
    ArrowIntervalUnit.monthDayNano => ArrowIntervalValue.monthDayNano(
      first,
      data.getInt32(4, Endian.little),
      _getInteger(bytes, 8, 8, true),
    ),
  };
}

void _writeRunEnds(
  _BodyWriter w,
  ArrowRunEndEncodedType type,
  List<ArrowValue?> values,
) {
  final ends = <ArrowValue?>[];
  final runs = <ArrowValue?>[];
  for (var i = 0; i < values.length; i++) {
    if (i + 1 == values.length || values[i] != values[i + 1]) {
      ends.add(ArrowIntegerValue(i + 1));
      runs.add(values[i]);
    }
  }
  final endType = type.runEndsField.type as ArrowIntegerType;
  if (BigInt.from(values.length) > endType.maximum) {
    throw ArgumentError('Run end exceeds declared integer width');
  }
  w.node(values.length, 0);
  _writeValues(w, endType, ends);
  _writeValues(w, type.valuesField.type, runs);
}

List<ArrowValue?> _readRunEnds(_BodyReader r, ArrowRunEndEncodedType type) {
  // Charge the logical length before reading children or allocating expansion.
  final n = _checkedNode(r);
  if (n.nullCount != 0) {
    throw const FormatException(
      'Run-end encoded parent null count must be zero',
    );
  }
  final ends = _readValues(r, type.runEndsField.type);
  final values = _readValues(r, type.valuesField.type);
  if (ends.length != values.length) {
    throw const FormatException('Run ends and values lengths differ');
  }
  final result = <ArrowValue?>[];
  var previous = 0;
  for (var i = 0; i < ends.length; i++) {
    final end = ends[i];
    if (end is! ArrowIntegerValue ||
        end.value <= BigInt.from(previous) ||
        end.value > BigInt.from(n.length)) {
      throw const FormatException(
        'Run ends must increase within logical length',
      );
    }
    final next = end.value.toInt();
    result.addAll(List<ArrowValue?>.filled(next - previous, values[i]));
    previous = next;
  }
  if (previous != n.length) {
    throw const FormatException('Run ends do not cover logical length');
  }
  return result;
}
