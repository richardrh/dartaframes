part of 'ipc.dart';

Uint8List _decodeCompressedIpcBuffer(
  Uint8List encoded,
  int codec,
  int remainingBudget,
) {
  if (codec != 0 && codec != 1) {
    throw UnsupportedError('Unknown Arrow IPC compression codec $codec');
  }
  if (encoded.isEmpty) return encoded;
  if (encoded.length < 8) {
    throw const FormatException('Compressed IPC buffer lacks its size prefix');
  }
  final declared = _getInteger(encoded, 0, 8, true);
  final payload = Uint8List.sublistView(encoded, 8);
  if (declared == -BigInt.one) {
    if (payload.length > remainingBudget) {
      throw const FormatException('IPC decoded buffer budget exceeded');
    }
    return payload;
  }
  if (declared.isNegative || declared > BigInt.from(remainingBudget)) {
    throw const FormatException('Invalid or excessive IPC decompressed size');
  }
  final expected = declared.toInt();
  final Uint8List result;
  try {
    result = ipc_compression.decompressIpcBuffer(codec, payload, expected);
  } on UnsupportedError {
    rethrow;
  } on Exception catch (error) {
    throw FormatException('Invalid compressed IPC buffer: $error');
  } on RangeError catch (error) {
    throw FormatException('Invalid compressed IPC buffer bounds: $error');
  }
  if (result.length != expected) {
    throw const FormatException('IPC decompressed length differs from prefix');
  }
  return result;
}
