import 'package:dartaframes_polars/arrow.dart';

/// Encodes and decodes a standard Arrow IPC stream entirely in Dart.
void main() {
  final id = ArrowIntegerType(64);
  const label = ArrowUtf8Type();
  final schema = ArrowSchema([
    ArrowField('id', id, nullable: false),
    ArrowField('label', label),
  ]);
  final batch = RecordBatch(schema, [
    ArrowArray(id, [ArrowIntegerValue(1), ArrowIntegerValue(2)]),
    ArrowArray(label, const [ArrowStringValue('Ada'), null]),
  ]);

  final stream = ArrowIpcStreamWriter(schema: schema, batches: [batch]).write();
  final restored = ArrowIpcStreamReader(stream).readTable();
  final file = ArrowIpcFileWriter(
    schema: restored.schema,
    batches: restored.batches,
  ).write();
  final fromFile = ArrowIpcFileReader(file).readTable();
  print('IPC stream: ${stream.length} bytes');
  print('IPC file: ${file.length} bytes');
  print('Rows: ${fromFile.rowCount}');
  print(const OwnedBatchJsonCodec().encode(fromFile.batches.single));
}
