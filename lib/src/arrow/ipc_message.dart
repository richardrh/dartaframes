part of 'ipc.dart';

// Encapsulated messages (Message.fbs), the stream framing and the file
// footer (File.fbs).

const int _metadataV5 = 4; // MetadataVersion.V5
const int _headerSchema = 1;
const int _headerDictionaryBatch = 2;
const int _headerRecordBatch = 3;
final Uint8List _fileMagic = Uint8List.fromList(ascii.encode('ARROW1'));
final Uint8List _fileMagicPadded = Uint8List.fromList([..._fileMagic, 0, 0]);

Uint8List _int32Bytes(int value) =>
    Uint8List(4)..buffer.asByteData().setInt32(0, value, Endian.little);

final class _Message {
  const _Message(this.headerType, this.header, this.body);
  final int headerType;
  final _FbTableView header;
  final Uint8List body;
}

/// A file Block (File.fbs struct): offset, metaDataLength, bodyLength.
final class _Block {
  const _Block(this.offset, this.metadataLength, this.bodyLength);
  final int offset;
  final int metadataLength;
  final int bodyLength;
}

// ------------------------------------------------------------ decoding ----

_Message _parseMessage(Uint8List metadata, Uint8List body) {
  final message = _FbReader(ByteData.sublistView(metadata)).root();
  final version = message.i16(0, 0);
  if (version != _metadataV5) {
    throw FormatException(
      'Unsupported IPC metadata version $version (need V5)',
    );
  }
  final headerType = message.u8(1, 0);
  final header = message.table(2);
  if (header == null) throw const FormatException('IPC message has no header');
  final bodyLength = message.i64(3, 0);
  if (bodyLength < 0 || bodyLength > body.length) {
    throw FormatException(
      'IPC body length $bodyLength exceeds available bytes',
    );
  }
  return _Message(
    headerType,
    header,
    Uint8List.sublistView(body, 0, bodyLength),
  );
}

/// Walks encapsulated messages: `0xFFFFFFFF`, int32 length, metadata, body.
final class _MessageCursor {
  _MessageCursor(this.bytes, this.position, this.limits);
  final Uint8List bytes;
  int position;
  final ArrowIpcLimits limits;
  late final ByteData _data = ByteData.sublistView(bytes);

  int _int32() {
    if (position > bytes.length - 4) {
      throw const FormatException('Truncated IPC message prefix');
    }
    final value = _data.getInt32(position, Endian.little);
    position += 4;
    return value;
  }

  /// Returns the next message, or null at end-of-stream / end of input.
  _Message? next() {
    if (position == bytes.length) return null;
    var length = _int32();
    // Pre-0.15 streams omit the continuation token.
    if (length == -1) length = _int32();
    if (length == 0) return null;
    _checkLength(length);
    final metadata = Uint8List.sublistView(bytes, position, position + length);
    position += length;
    final message = _parseMessage(
      metadata,
      Uint8List.sublistView(bytes, position),
    );
    position += message.body.length;
    return message;
  }

  void _checkLength(int length) {
    if (length < 0 ||
        length > limits.maxMessageBytes ||
        length > bytes.length - position) {
      throw FormatException('Invalid IPC metadata length $length');
    }
  }
}

_FbTableView _readFooter(Uint8List bytes) {
  const trailer = 10; // int32 footer length + 'ARROW1'
  if (bytes.length < 8 + trailer ||
      !_hasMagic(bytes, 0) ||
      !_hasMagic(bytes, bytes.length - 6)) {
    throw const FormatException('Not an Arrow IPC file (missing ARROW1 magic)');
  }
  final data = ByteData.sublistView(bytes);
  final length = data.getInt32(bytes.length - trailer, Endian.little);
  final start = bytes.length - trailer - length;
  if (length <= 0 || start < 8) {
    throw FormatException('Invalid IPC file footer length $length');
  }
  final footer = _FbReader(
    ByteData.sublistView(bytes, start, bytes.length - trailer),
  ).root();
  final version = footer.i16(0, 0);
  if (version != _metadataV5) {
    throw FormatException('Unsupported IPC file version $version (need V5)');
  }
  return footer;
}

bool _hasMagic(Uint8List bytes, int at) {
  for (var i = 0; i < _fileMagic.length; i++) {
    if (bytes[at + i] != _fileMagic[i]) return false;
  }
  return true;
}

List<_Block> _blocks(_FbTableView footer, int slot, int max) {
  final structs = footer.structs(slot, 24);
  if (structs.count > max) {
    throw FormatException(
      'IPC file has ${structs.count} blocks; limit is $max',
    );
  }
  return [
    for (var i = 0; i < structs.count; i++)
      _Block(structs.i64(i, 0), structs.i32(i, 8), structs.i64(i, 16)),
  ];
}

_Message _readBlock(Uint8List bytes, _Block block, ArrowIpcLimits limits) {
  final end = block.offset + block.metadataLength + block.bodyLength;
  if (block.offset < 8 ||
      block.metadataLength < 8 ||
      block.bodyLength < 0 ||
      end > bytes.length) {
    throw const FormatException('IPC file block lies outside the file');
  }
  final cursor = _MessageCursor(
    Uint8List.sublistView(bytes, 0, end),
    block.offset,
    limits,
  );
  final message = cursor.next();
  if (message == null) throw const FormatException('Empty IPC file block');
  return message;
}

/// Accumulates dictionaries and record batches while reading.
final class _ReadState {
  _ReadState(_IpcSchema ipc, this.limits) : schema = ipc.schema {
    _bindDictionaryIds(ipc);
  }

  final ArrowSchema schema;
  final ArrowIpcLimits limits;
  final Map<int, int> _fieldForId = {};
  final Map<int, ArrowArray> _dictionaries = {};
  final List<RecordBatch> _batches = [];
  late final _ValueBudget _budget = _ValueBudget(limits.maxValues);
  int _dictionaryCount = 0;

  void _bindDictionaryIds(_IpcSchema ipc) {
    final fields = [
      for (var i = 0; i < schema.fields.length; i++)
        if (schema.fields[i].type is ArrowDictionaryType) i,
    ];
    if (fields.length != ipc.dictionaryIds.length) {
      throw UnsupportedError(
        'Nested dictionary-encoded fields are unsupported',
      );
    }
    for (var k = 0; k < fields.length; k++) {
      if (_fieldForId.containsKey(ipc.dictionaryIds[k])) {
        throw const FormatException('Duplicate dictionary id in schema');
      }
      _fieldForId[ipc.dictionaryIds[k]] = fields[k];
    }
  }

  void accept(_Message message, {required bool allowReplacement}) {
    switch (message.headerType) {
      case _headerDictionaryBatch:
        _acceptDictionary(message, allowReplacement);
      case _headerRecordBatch:
        _acceptBatch(message);
      case _headerSchema:
        throw const FormatException('Unexpected second Schema message');
      default:
        throw UnsupportedError(
          'Unsupported IPC message type ${message.headerType}',
        );
    }
  }

  void _acceptDictionary(_Message message, bool allowReplacement) {
    if (++_dictionaryCount > limits.maxDictionaries) {
      throw const FormatException('Too many dictionary batches');
    }
    final id = message.header.i64(0, 0);
    final field = _fieldForId[id];
    if (field == null) throw FormatException('Unknown dictionary id $id');
    final valueType =
        (schema.fields[field].type as ArrowDictionaryType).valueType;
    final data = message.header.table(1);
    if (data == null) {
      throw const FormatException('DictionaryBatch has no data');
    }
    final values = _decodeColumns(
      data,
      message.body,
      [valueType],
      limits,
      _budget,
    ).single;
    final isDelta = message.header.boolean(2, false);
    _storeDictionary(id, valueType, values, isDelta, allowReplacement);
  }

  void _storeDictionary(
    int id,
    ArrowDataType type,
    List<ArrowValue?> values,
    bool isDelta,
    bool allowReplacement,
  ) {
    final existing = _dictionaries[id];
    if (existing != null && !isDelta && !allowReplacement) {
      throw const FormatException('IPC files may not replace dictionaries');
    }
    final merged = isDelta && existing != null
        ? [...existing.values, ...values]
        : values;
    _dictionaries[id] = ArrowArray(type, merged);
  }

  void _acceptBatch(_Message message) {
    if (_batches.length >= limits.maxBatches) {
      throw const FormatException('Too many record batches');
    }
    final types = [for (final f in schema.fields) f.type];
    final columns = _decodeColumns(
      message.header,
      message.body,
      types,
      limits,
      _budget,
    );
    final rows = message.header.i64(0, 0);
    _batches.add(
      RecordBatch(schema, [
        for (var i = 0; i < columns.length; i++) _column(i, columns[i]),
      ], rowCount: rows),
    );
  }

  ArrowArray _column(int index, List<ArrowValue?> values) {
    final type = schema.fields[index].type;
    if (type is! ArrowDictionaryType) return ArrowArray(type, values);
    final id = _fieldForId.entries.firstWhere((e) => e.value == index).key;
    final dictionary = _dictionaries[id];
    if (dictionary == null) {
      throw FormatException('Record batch references missing dictionary $id');
    }
    return ArrowArray(type, values, dictionary: dictionary);
  }

  ArrowTable table() => ArrowTable(schema, _batches);
}

/// Decodes a RecordBatch table body into one value list per type.
List<List<ArrowValue?>> _decodeColumns(
  _FbTableView batch,
  Uint8List body,
  List<ArrowDataType> types,
  ArrowIpcLimits limits,
  _ValueBudget budget,
) {
  if (batch.table(3) != null) {
    throw UnsupportedError('Compressed IPC bodies are not supported');
  }
  final reader = _BodyReader(
    body,
    _nodes(batch.structs(1, 16), limits),
    _buffers(batch.structs(2, 16), limits),
    limits,
    budget,
    variadicCounts: _variadicCounts(batch, limits),
  );
  final length = batch.i64(0, 0);
  if (length < 0 || length > limits.maxRows) {
    throw FormatException('Batch length $length exceeds limits');
  }
  final columns = [for (final type in types) _readValues(reader, type)];
  reader.finish();
  for (final column in columns) {
    if (column.length != length) {
      throw FormatException(
        'Column length ${column.length} != batch length $length',
      );
    }
  }
  return columns;
}

List<_IpcNode> _nodes(_FbStructs structs, ArrowIpcLimits limits) {
  if (structs.count > limits.maxBuffers) {
    throw const FormatException('Too many field nodes');
  }
  return [
    for (var i = 0; i < structs.count; i++)
      _IpcNode(structs.i64(i, 0), structs.i64(i, 8)),
  ];
}

List<_IpcBufferRef> _buffers(_FbStructs structs, ArrowIpcLimits limits) {
  if (structs.count > limits.maxBuffers) {
    throw const FormatException('Too many buffers');
  }
  return [
    for (var i = 0; i < structs.count; i++)
      _IpcBufferRef(structs.i64(i, 0), structs.i64(i, 8)),
  ];
}

List<int> _variadicCounts(_FbTableView batch, ArrowIpcLimits limits) {
  final structs = batch.structs(4, 8);
  if (structs.count > limits.maxBuffers) {
    throw const FormatException('Too many variadic buffer counts');
  }
  return [for (var i = 0; i < structs.count; i++) structs.i64(i, 0)];
}

// ------------------------------------------------------------ encoding ----

final class _MessageSink {
  final BytesBuilder _out = BytesBuilder(copy: false);
  int get length => _out.length;
  void raw(Uint8List bytes) => _out.add(bytes);
  Uint8List takeBytes() => _out.takeBytes();

  /// Writes one encapsulated message and returns its file [_Block].
  _Block message(int headerType, _FbTableObject header, Uint8List body) {
    final metadata = _FbWriter.encode(
      _FbTableObject({
        0: _fbI16(_metadataV5),
        1: _fbU8(headerType),
        2: _FbRef(header),
        3: _fbI64(body.length),
      }),
    );
    final padded = _alignUp(metadata.length, 8);
    final offset = length;
    raw(_int32Bytes(-1));
    raw(_int32Bytes(padded));
    raw(metadata);
    raw(Uint8List(padded - metadata.length));
    raw(body);
    return _Block(offset, 8 + padded, body.length);
  }

  void endOfStream() {
    raw(_int32Bytes(-1));
    raw(_int32Bytes(0));
  }
}

/// Writes schema (stream only), dictionaries and batches. Returns the
/// (dictionary, record batch) blocks for a file footer.
(List<_Block>, List<_Block>) _writeMessages(
  _MessageSink out,
  ArrowTable table, {
  required bool file,
}) {
  final schema = _encodeSchema(table.schema);
  out.message(_headerSchema, schema, Uint8List(0));
  final dictionaryFields = [
    for (var i = 0; i < table.schema.fields.length; i++)
      if (table.schema.fields[i].type is ArrowDictionaryType) i,
  ];
  final total = table.schema.fields.fold(
    0,
    (sum, f) => sum + _countDictionaries(f.type),
  );
  if (total != dictionaryFields.length) {
    throw UnsupportedError(
      'Only top-level dictionary-encoded fields can be written to IPC',
    );
  }
  final dictionaryBlocks = <_Block>[];
  final batchBlocks = <_Block>[];
  final written = <int, ArrowArray>{};
  for (final batch in table.batches) {
    for (var id = 0; id < dictionaryFields.length; id++) {
      final dictionary = batch.columns[dictionaryFields[id]].dictionary!;
      final previous = written[id];
      if (previous != null && _sameValues(previous, dictionary)) continue;
      if (previous != null && file) {
        throw UnsupportedError(
          'IPC files cannot replace a dictionary between batches',
        );
      }
      written[id] = dictionary;
      dictionaryBlocks.add(_writeDictionary(out, id, dictionary));
    }
    batchBlocks.add(_writeBatch(out, batch));
  }
  return (dictionaryBlocks, batchBlocks);
}

int _countDictionaries(ArrowDataType type) =>
    (_dictionaryType(type) != null ? 1 : 0) +
    _childFields(type).fold(0, (sum, f) => sum + _countDictionaries(f.type));

bool _sameValues(ArrowArray a, ArrowArray b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a.values[i] != b.values[i]) return false;
  }
  return true;
}

(_FbTableObject, Uint8List) _encodeBody(
  int length,
  List<(ArrowDataType, List<ArrowValue?>)> columns,
) {
  final w = _BodyWriter();
  for (final (type, values) in columns) {
    _writeValues(w, type, values);
  }
  final body = w.takeBytes();
  return (_recordBatchTable(length, w), body);
}

_FbTableObject _recordBatchTable(int length, _BodyWriter w) {
  final nodes = ByteData(16 * w.nodes.length);
  for (var i = 0; i < w.nodes.length; i++) {
    _setInt64(nodes, i * 16, w.nodes[i].length);
    _setInt64(nodes, i * 16 + 8, w.nodes[i].nullCount);
  }
  final buffers = ByteData(16 * w.buffers.length);
  for (var i = 0; i < w.buffers.length; i++) {
    _setInt64(buffers, i * 16, w.buffers[i].offset);
    _setInt64(buffers, i * 16 + 8, w.buffers[i].length);
  }
  return _FbTableObject({
    0: _fbI64(length),
    1: _fbStructs(nodes.buffer.asUint8List(), w.nodes.length),
    2: _fbStructs(buffers.buffer.asUint8List(), w.buffers.length),
    if (w.variadicCounts.isNotEmpty)
      4: _fbStructs(_int64s(w.variadicCounts), w.variadicCounts.length),
  });
}

Uint8List _int64s(List<int> values) {
  final data = ByteData(8 * values.length);
  for (var i = 0; i < values.length; i++) {
    _setInt64(data, i * 8, values[i]);
  }
  return data.buffer.asUint8List();
}

_Block _writeDictionary(_MessageSink out, int id, ArrowArray dictionary) {
  final (batch, body) = _encodeBody(dictionary.length, [
    (dictionary.type, dictionary.values),
  ]);
  return out.message(
    _headerDictionaryBatch,
    _FbTableObject({0: _fbI64(id), 1: _FbRef(batch), 2: _fbBool(false)}),
    body,
  );
}

_Block _writeBatch(_MessageSink out, RecordBatch batch) {
  final (header, body) = _encodeBody(batch.rowCount, [
    for (final column in batch.columns) (column.type, column.values),
  ]);
  return out.message(_headerRecordBatch, header, body);
}

_FbTableObject _footerTable(
  ArrowSchema schema,
  (List<_Block>, List<_Block>) blocks,
) => _FbTableObject({
  0: _fbI16(_metadataV5),
  1: _FbRef(_encodeSchema(schema)),
  2: _fbStructs(_blockBytes(blocks.$1), blocks.$1.length),
  3: _fbStructs(_blockBytes(blocks.$2), blocks.$2.length),
});

Uint8List _blockBytes(List<_Block> blocks) {
  final data = ByteData(24 * blocks.length);
  for (var i = 0; i < blocks.length; i++) {
    _setInt64(data, i * 24, blocks[i].offset);
    data.setInt32(i * 24 + 8, blocks[i].metadataLength, Endian.little);
    _setInt64(data, i * 24 + 16, blocks[i].bodyLength);
  }
  return data.buffer.asUint8List();
}
