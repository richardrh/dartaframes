import 'dart:convert';
import 'dart:typed_data';

import 'package:dartaframes_polars/arrow.dart';
import 'package:dartaframes_polars/src/arrow/ipc_compression_web.dart' as web;
import 'package:test/test.dart';

// Generated independently with PyArrow 26, IpcWriteOptions(compression='lz4').
const _stream =
    '/////7AAAAAQAAAAAAAKAA4ABgAFAAgACgAAAAABBAAQAAAAAAAKAAwAAAAEAAgACgAAAEAAAAAEAAAAAQAAAAwAAAAIAAwABAAIAAgAAAAYAAAABAAAAAkAAABweWFycm93MjYAAAAGAAAAc291cmNlAAABAAAAFAAAABAAFAAIAAYABwAMAAAAEAAQAAAAAAABBRAAAAAcAAAABAAAAAAAAAAEAAAAdGV4dAAAAAAEAAQABAAAAP////+oAAAAFAAAAAAAAAAMABgABgAFAAgADAAMAAAAAAMEABwAAABoAAAAAAAAAAAAAAAMABwAEAAEAAgADAAMAAAAWAAAABwAAAAUAAAAAwAAAAAAAAAAAAAABAAEAAQAAAADAAAAAAAAAAAAAAAYAAAAAAAAABgAAAAAAAAAJwAAAAAAAABAAAAAAAAAACEAAAAAAAAAAAAAAAEAAAADAAAAAAAAAAEAAAAAAAAAAQAAAAAAAAAEIk0YYECCAQAAgAUAAAAAEAAAAAAAAAAEIk0YYECCEAAAgAAAAAAHAAAABwAAAAoAAAAAAAAAAAoAAAAAAAAABCJNGGBAggoAAIBHcsO8w59lQWRhAAAAAAAAAAAAAAD/////AAAAAA==';

void main() {
  test('public reader decodes independent PyArrow LZ4 stream', () {
    final table = ArrowIpcStreamReader(base64Decode(_stream)).readTable();
    expect(table.rowCount, 3);
    expect(table.schema.metadata, {'source': 'pyarrow26'});
    expect(table.batches.single.columns.single.values, [
      const ArrowStringValue('Grüße'),
      null,
      const ArrowStringValue('Ada'),
    ]);
  });

  // PyArrow compress(b'a' * 5000, codec='lz4_frame'), including overlapping
  // matches and extended match lengths. The same helper is exercised on VM
  // so ordinary coverage checks include browser-specific decoding logic.
  final repeated = base64Decode(
    'BCJNGGBAgh4AAAAfYQEA/////////////////////////4JQYWFhYWEAAAAA',
  );
  test('web decoder expands overlapping matches within the declared bound', () {
    expect(web.decompressIpcBuffer(0, repeated, 5000), List.filled(5000, 97));
    expect(
      () => web.decompressIpcBuffer(0, repeated, 4999),
      throwsFormatException,
    );
    expect(
      () => web.decompressIpcBuffer(0, repeated, 5001),
      throwsFormatException,
    );
  });
  test('every truncated frame is rejected', () {
    for (var length = 0; length < repeated.length; length++) {
      expect(
        () => web.decompressIpcBuffer(
          0,
          Uint8List.sublistView(repeated, 0, length),
          5000,
        ),
        throwsFormatException,
        reason: 'length $length',
      );
    }
  });
  test('trailing data and invalid magic are rejected', () {
    expect(
      () => web.decompressIpcBuffer(
        0,
        Uint8List.fromList([...repeated, 1]),
        5000,
      ),
      throwsFormatException,
    );
    final invalid = Uint8List.fromList(repeated)..[0] = 0;
    expect(
      () => web.decompressIpcBuffer(0, invalid, 5000),
      throwsFormatException,
    );
  });
  test('web Zstandard is explicitly unsupported', () {
    expect(
      () => web.decompressIpcBuffer(1, repeated, 5000),
      throwsUnsupportedError,
    );
  });
}
