part of 'ipc.dart';

// Columnar body encoding for the IPC RecordBatch/DictionaryBatch bodies.
//
// Layouts follow https://arrow.apache.org/docs/format/Columnar.html. Each
// array contributes one FieldNode and the buffers its layout prescribes, in
// depth-first pre-order. Types not handled here are delegated to
// `_writeExtendedValues`/`_readExtendedValues` (ipc_body_extended.dart).

final class _IpcNode {
  const _IpcNode(this.length, this.nullCount);
  final int length;
  final int nullCount;
}

final class _IpcBufferRef {
  const _IpcBufferRef(this.offset, this.length);
  final int offset;
  final int length;
}

// ----------------------------------------------------------------- writer --

final class _BodyWriter {
  final List<_IpcNode> nodes = [];
  final List<_IpcBufferRef> buffers = [];
  final List<int> variadicCounts = [];
  final BytesBuilder _bytes = BytesBuilder(copy: false);
  int _length = 0;

  int get length => _length;
  Uint8List takeBytes() => _bytes.takeBytes();

  void node(int length, int nullCount) =>
      nodes.add(_IpcNode(length, nullCount));

  void variadicCount(int count) => variadicCounts.add(count);

  /// Appends [bytes] as the next buffer, padding the body to 8 bytes.
  void buffer(Uint8List bytes) {
    buffers.add(_IpcBufferRef(_length, bytes.length));
    _bytes.add(bytes);
    final padding = (-bytes.length) % 8;
    if (padding > 0) _bytes.add(Uint8List(padding));
    _length += bytes.length + padding;
  }

  /// Emits the node and validity bitmap (empty when there are no nulls).
  void nodeWithValidity(List<ArrowValue?> values) {
    final nulls = values.where((v) => v == null).length;
    node(values.length, nulls);
    buffer(nulls == 0 ? Uint8List(0) : _bitmap(values.map((v) => v != null)));
  }
}

Uint8List _bitmap(Iterable<bool> bits) {
  final list = bits.toList();
  final out = Uint8List((list.length + 7) ~/ 8);
  for (var i = 0; i < list.length; i++) {
    if (list[i]) out[i >> 3] |= 1 << (i & 7);
  }
  return out;
}

/// Little-endian two's complement encoding of [value] in [byteWidth] bytes.
void _putInteger(Uint8List out, int offset, int byteWidth, BigInt value) {
  var v = value.toUnsigned(byteWidth * 8);
  final mask = BigInt.from(0xff);
  for (var i = 0; i < byteWidth; i++) {
    out[offset + i] = (v & mask).toInt();
    v >>= 8;
  }
}

BigInt _getInteger(Uint8List data, int offset, int byteWidth, bool signed) {
  var v = BigInt.zero;
  for (var i = byteWidth - 1; i >= 0; i--) {
    v = (v << 8) | BigInt.from(data[offset + i]);
  }
  return signed ? v.toSigned(byteWidth * 8) : v;
}

Uint8List _fixedBuffer(
  List<ArrowValue?> values,
  int byteWidth,
  BigInt Function(ArrowValue value) raw,
) {
  final out = Uint8List(values.length * byteWidth);
  for (var i = 0; i < values.length; i++) {
    final value = values[i];
    if (value != null) _putInteger(out, i * byteWidth, byteWidth, raw(value));
  }
  return out;
}

/// Byte width and raw-integer accessor for fixed-width primitive types, or
/// null when [type] is not a fixed-width primitive handled by this file.
(int, BigInt Function(ArrowValue))? _fixedLayout(ArrowDataType type) =>
    switch (type) {
      ArrowIntegerType(:final bitWidth) when bitWidth <= 64 => (
        bitWidth ~/ 8,
        (v) => (v as ArrowIntegerValue).value,
      ),
      ArrowFloatingType(:final bitWidth) => (
        bitWidth ~/ 8,
        (v) => (v as ArrowFloatingValue).bits,
      ),
      ArrowDecimalType(bitWidth: 128) => (
        16,
        (v) => (v as ArrowDecimalValue).unscaled,
      ),
      ArrowDateType(:final unit) => (
        unit == ArrowDateUnit.day ? 4 : 8,
        _temporal,
      ),
      ArrowTimeType(:final unit) => (_timeWidth(unit), _temporal),
      ArrowTimestampType() || ArrowDurationType() => (8, _temporal),
      ArrowDictionaryType(:final indexType) => (
        (indexType as ArrowIntegerType).bitWidth ~/ 8,
        (v) => (v as ArrowDictionaryIndexValue).index,
      ),
      _ => null,
    };

BigInt _temporal(ArrowValue v) => (v as ArrowTemporalValue).value;

int _timeWidth(ArrowTimeUnit unit) =>
    unit == ArrowTimeUnit.second || unit == ArrowTimeUnit.millisecond ? 4 : 8;

void _rejectNonStandard(ArrowDataType type) {
  if (type case ArrowIntegerType(bitWidth: 128)) {
    throw UnsupportedError(
      'int128/uint128 are DartAframes binding extensions with no standard '
      'Arrow IPC encoding',
    );
  }
}

void _writeValues(_BodyWriter w, ArrowDataType type, List<ArrowValue?> values) {
  _rejectNonStandard(type);
  final fixed = _fixedLayout(type);
  if (fixed != null) {
    w.nodeWithValidity(values);
    w.buffer(_fixedBuffer(values, fixed.$1, fixed.$2));
    return;
  }
  switch (type) {
    case ArrowNullType():
      w.node(values.length, values.length);
    case ArrowBooleanType():
      w.nodeWithValidity(values);
      w.buffer(
        _bitmap(values.map((v) => (v as ArrowBooleanValue?)?.value ?? false)),
      );
    case ArrowUtf8Type(:final offsetWidth)
        when offsetWidth != ArrowOffsetWidth.view:
      _writeVarBinary(
        w,
        values,
        offsetWidth,
        (v) => utf8.encode((v as ArrowStringValue).value),
      );
    case ArrowBinaryType(:final offsetWidth)
        when offsetWidth != ArrowOffsetWidth.view:
      _writeVarBinary(
        w,
        values,
        offsetWidth,
        (v) => (v as ArrowBinaryValue).bytes,
      );
    case ArrowListType(:final field, :final offsetWidth, view: false):
      _writeList(w, values, field, offsetWidth);
    case ArrowFixedSizeListType():
      _writeFixedList(w, values, type);
    case ArrowStructType():
      _writeStruct(w, values, type);
    case ArrowExtensionType(:final storageType):
      _writeValues(w, storageType, [
        for (final v in values) (v as ArrowExtensionValue?)?.storage,
      ]);
    default:
      _writeExtendedValues(w, type, values);
  }
}

Uint8List _offsets(List<int> offsets, ArrowOffsetWidth width) {
  final size = width == ArrowOffsetWidth.large ? 8 : 4;
  final out = Uint8List(offsets.length * size);
  final data = ByteData.sublistView(out);
  for (var i = 0; i < offsets.length; i++) {
    if (size == 4) {
      if (offsets[i] > 0x7fffffff) {
        throw ArgumentError(
          'Offset ${offsets[i]} overflows int32; use a large type',
        );
      }
      data.setInt32(i * 4, offsets[i], Endian.little);
    } else {
      _setInt64(data, i * 8, offsets[i]);
    }
  }
  return out;
}

void _writeVarBinary(
  _BodyWriter w,
  List<ArrowValue?> values,
  ArrowOffsetWidth width,
  List<int> Function(ArrowValue) bytesOf,
) {
  final offsets = <int>[0];
  final data = BytesBuilder(copy: false);
  for (final value in values) {
    if (value != null) data.add(bytesOf(value));
    offsets.add(data.length);
  }
  w.nodeWithValidity(values);
  w.buffer(_offsets(offsets, width));
  w.buffer(data.takeBytes());
}

void _writeList(
  _BodyWriter w,
  List<ArrowValue?> values,
  ArrowField field,
  ArrowOffsetWidth width,
) {
  final offsets = <int>[0];
  final children = <ArrowValue?>[];
  for (final value in values) {
    if (value != null) children.addAll((value as ArrowListValue).values);
    offsets.add(children.length);
  }
  w.nodeWithValidity(values);
  w.buffer(_offsets(offsets, width));
  _writeValues(w, field.type, children);
}

void _writeFixedList(
  _BodyWriter w,
  List<ArrowValue?> values,
  ArrowFixedSizeListType type,
) {
  final children = <ArrowValue?>[
    for (final value in values)
      ...(value == null
          ? List<ArrowValue?>.filled(type.size, null)
          : (value as ArrowListValue).values),
  ];
  w.nodeWithValidity(values);
  _writeValues(w, type.field.type, children);
}

void _writeStruct(
  _BodyWriter w,
  List<ArrowValue?> values,
  ArrowStructType type,
) {
  w.nodeWithValidity(values);
  for (var f = 0; f < type.fields.length; f++) {
    _writeValues(w, type.fields[f].type, [
      for (final value in values)
        value == null ? null : (value as ArrowStructValue).fields[f].value,
    ]);
  }
}

// ----------------------------------------------------------------- reader --

/// Running total of decoded value slots, shared across one table read.
final class _ValueBudget {
  _ValueBudget(this.limit);
  final int limit;
  int used = 0;

  void charge(int count) {
    used += count;
    if (used > limit) {
      throw FormatException(
        'Decoded value count exceeds ArrowIpcLimits.maxValues ($limit)',
      );
    }
  }
}

final class _BodyReader {
  _BodyReader(
    this.body,
    this.nodes,
    this.buffers,
    this.limits,
    this.budget, {
    List<int> variadicCounts = const [],
  }) : _variadic = variadicCounts;

  final _ValueBudget budget;

  final Uint8List body;
  final List<_IpcNode> nodes;
  final List<_IpcBufferRef> buffers;
  final ArrowIpcLimits limits;
  final List<int> _variadic;
  int _node = 0;
  int _buffer = 0;
  int _variadicIndex = 0;
  int depth = 0;

  _IpcNode node() {
    if (_node >= nodes.length) {
      throw const FormatException('RecordBatch has too few field nodes');
    }
    return nodes[_node++];
  }

  Uint8List buffer() {
    if (_buffer >= buffers.length) {
      throw const FormatException('RecordBatch has too few buffers');
    }
    final ref = buffers[_buffer++];
    if (ref.offset < 0 ||
        ref.length < 0 ||
        ref.offset > body.length - ref.length) {
      throw FormatException(
        'Buffer [${ref.offset}, +${ref.length}) exceeds body of ${body.length} bytes',
      );
    }
    return Uint8List.sublistView(body, ref.offset, ref.offset + ref.length);
  }

  int variadicCount() {
    if (_variadicIndex >= _variadic.length) {
      throw const FormatException('Missing variadic buffer count');
    }
    return _variadic[_variadicIndex++];
  }

  /// Decodes a validity bitmap, cross-checking the declared null count.
  List<bool> validity(_IpcNode n, Uint8List bitmap) {
    if (bitmap.isEmpty) {
      if (n.nullCount != 0) {
        throw const FormatException(
          'Missing validity bitmap for nullable node',
        );
      }
      return List.filled(n.length, true);
    }
    final bits = _readBits(bitmap, n.length);
    final nulls = bits.where((b) => !b).length;
    if (nulls != n.nullCount) {
      throw FormatException(
        'Null count ${n.nullCount} disagrees with bitmap ($nulls)',
      );
    }
    return bits;
  }

  void finish() {
    if (_node != nodes.length || _buffer != buffers.length) {
      throw const FormatException(
        'RecordBatch has unconsumed nodes or buffers',
      );
    }
  }
}

List<bool> _readBits(Uint8List bitmap, int length) {
  if (bitmap.length < (length + 7) ~/ 8) {
    throw FormatException(
      'Bitmap of ${bitmap.length} bytes is too short for $length bits',
    );
  }
  return List.generate(length, (i) => bitmap[i >> 3] & (1 << (i & 7)) != 0);
}

_IpcNode _checkedNode(_BodyReader r) {
  final n = r.node();
  if (n.length < 0 || n.length > r.limits.maxRows) {
    throw FormatException('Field node length ${n.length} exceeds limits');
  }
  if (n.nullCount < 0 || n.nullCount > n.length) {
    throw FormatException('Invalid null count ${n.nullCount}');
  }
  r.budget.charge(n.length);
  return n;
}

List<ArrowValue?> _readValues(_BodyReader r, ArrowDataType type) {
  if (++r.depth > r.limits.maxDepth) {
    throw const FormatException('Arrow nesting exceeds maximum depth');
  }
  try {
    return _readValuesAt(r, type);
  } finally {
    r.depth--;
  }
}

List<ArrowValue?> _readValuesAt(_BodyReader r, ArrowDataType type) {
  _rejectNonStandard(type);
  final fixed = _fixedReader(type);
  if (fixed != null) {
    return _readFixed(r, fixed.$1, _signedFixed(type), fixed.$2);
  }
  return switch (type) {
    ArrowNullType() => _readNull(r),
    ArrowBooleanType() => _readBoolean(r),
    ArrowUtf8Type(:final offsetWidth)
        when offsetWidth != ArrowOffsetWidth.view =>
      _readVarBinary(r, offsetWidth, (b) => ArrowStringValue(_utf8(b))),
    ArrowBinaryType(:final offsetWidth)
        when offsetWidth != ArrowOffsetWidth.view =>
      _readVarBinary(r, offsetWidth, ArrowBinaryValue.new),
    ArrowListType(:final field, :final offsetWidth, view: false) => _readList(
      r,
      field,
      offsetWidth,
    ),
    ArrowFixedSizeListType() => _readFixedList(r, type),
    ArrowStructType() => _readStruct(r, type),
    ArrowExtensionType(:final storageType) => [
      for (final v in _readValues(r, storageType))
        v == null ? null : ArrowExtensionValue(v),
    ],
    _ => _readExtendedValues(r, type),
  };
}

String _utf8(Uint8List bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    throw const FormatException('Invalid UTF-8 in Utf8 array');
  }
}

(int, ArrowValue Function(BigInt))? _fixedReader(ArrowDataType type) {
  final layout = _fixedLayout(type);
  if (layout == null) return null;
  final ArrowValue Function(BigInt) make = switch (type) {
    ArrowIntegerType() => ArrowIntegerValue.new,
    ArrowFloatingType(:final bitWidth) => (b) => ArrowFloatingValue(
      bitWidth,
      b,
    ),
    ArrowDecimalType() => ArrowDecimalValue.new,
    ArrowDictionaryType() => ArrowDictionaryIndexValue.new,
    _ => ArrowTemporalValue.new,
  };
  return (layout.$1, make);
}

bool _signedFixed(ArrowDataType type) => switch (type) {
  ArrowIntegerType(:final signed) => signed,
  ArrowDictionaryType(:final indexType) =>
    (indexType as ArrowIntegerType).signed,
  ArrowFloatingType() => false,
  _ => true,
};

/// Reads a validity bitmap plus one fixed-width little-endian values buffer.
List<ArrowValue?> _readFixed(
  _BodyReader r,
  int byteWidth,
  bool signed,
  ArrowValue Function(BigInt) make,
) {
  final n = _checkedNode(r);
  final valid = r.validity(n, r.buffer());
  final data = r.buffer();
  if (data.length < n.length * byteWidth) {
    throw FormatException(
      'Values buffer too short for ${n.length} x $byteWidth bytes',
    );
  }
  return List.generate(
    n.length,
    (i) => valid[i]
        ? make(_getInteger(data, i * byteWidth, byteWidth, signed))
        : null,
  );
}

List<ArrowValue?> _readNull(_BodyReader r) {
  final n = _checkedNode(r);
  return List.filled(n.length, null);
}

List<ArrowValue?> _readBoolean(_BodyReader r) {
  final n = _checkedNode(r);
  final valid = r.validity(n, r.buffer());
  final bits = _readBits(r.buffer(), n.length);
  return List.generate(
    n.length,
    (i) => valid[i] ? ArrowBooleanValue(bits[i]) : null,
  );
}

List<int> _readOffsets(Uint8List buffer, int count, ArrowOffsetWidth width) {
  final size = width == ArrowOffsetWidth.large ? 8 : 4;
  if (buffer.length < count * size) {
    throw const FormatException('Offsets buffer is too short');
  }
  final data = ByteData.sublistView(buffer);
  final offsets = List.generate(
    count,
    (i) => size == 4
        ? data.getInt32(i * 4, Endian.little)
        : _getInt64(data, i * 8),
  );
  for (var i = 0; i < count; i++) {
    if (offsets[i] < 0 || (i > 0 && offsets[i] < offsets[i - 1])) {
      throw const FormatException(
        'Offsets must be non-negative and non-decreasing',
      );
    }
  }
  return offsets;
}

List<int> _nodeOffsets(_BodyReader r, _IpcNode n, ArrowOffsetWidth width) {
  final buffer = r.buffer();
  // An empty array may omit the offsets buffer entirely.
  if (n.length == 0 && buffer.isEmpty) return const [0];
  return _readOffsets(buffer, n.length + 1, width);
}

List<ArrowValue?> _readVarBinary(
  _BodyReader r,
  ArrowOffsetWidth width,
  ArrowValue Function(Uint8List) make,
) {
  final n = _checkedNode(r);
  final valid = r.validity(n, r.buffer());
  final offsets = _nodeOffsets(r, n, width);
  final data = r.buffer();
  if (offsets.last > data.length) {
    throw const FormatException('Offsets exceed the data buffer');
  }
  return List.generate(
    n.length,
    (i) => valid[i]
        ? make(Uint8List.sublistView(data, offsets[i], offsets[i + 1]))
        : null,
  );
}

List<ArrowValue?> _readList(
  _BodyReader r,
  ArrowField field,
  ArrowOffsetWidth width,
) {
  final n = _checkedNode(r);
  final valid = r.validity(n, r.buffer());
  final offsets = _nodeOffsets(r, n, width);
  final children = _readValues(r, field.type);
  if (offsets.last > children.length) {
    throw const FormatException('List offsets exceed the child length');
  }
  return List.generate(
    n.length,
    (i) => valid[i]
        ? ArrowListValue(children.sublist(offsets[i], offsets[i + 1]))
        : null,
  );
}

List<ArrowValue?> _readFixedList(_BodyReader r, ArrowFixedSizeListType type) {
  final n = _checkedNode(r);
  final valid = r.validity(n, r.buffer());
  final children = _readValues(r, type.field.type);
  if (children.length < n.length * type.size) {
    throw const FormatException('Fixed-size list child is too short');
  }
  return List.generate(
    n.length,
    (i) => valid[i]
        ? ArrowListValue(children.sublist(i * type.size, (i + 1) * type.size))
        : null,
  );
}

List<ArrowValue?> _readStruct(_BodyReader r, ArrowStructType type) {
  final n = _checkedNode(r);
  final valid = r.validity(n, r.buffer());
  final columns = [for (final f in type.fields) _readValues(r, f.type)];
  for (final column in columns) {
    if (column.length < n.length) {
      throw const FormatException('Struct child is shorter than its parent');
    }
  }
  return List.generate(
    n.length,
    (i) => valid[i]
        ? ArrowStructValue([
            for (var f = 0; f < type.fields.length; f++)
              ArrowStructEntry(type.fields[f].name, columns[f][i]),
          ])
        : null,
  );
}
