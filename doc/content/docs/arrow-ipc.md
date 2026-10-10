---
title: Arrow IPC
weight: 3
---

`package:dartaframes_polars/arrow.dart` provides owned Arrow values and standard
Apache Arrow IPC V5 file and stream codecs. The Arrow implementation is pure
Dart and does not call Polars. It remains in this package for now.

## Use the codecs

```dart
final stream = ArrowIpcStreamWriter(schema: schema, batches: [batch]).write();
final restored = ArrowIpcStreamReader(stream).readTable();
final file = ArrowIpcFileWriter(
  schema: restored.schema,
  batches: restored.batches,
).write();
final fromFile = ArrowIpcFileReader(file).readTable();
```

Run the complete repository example with `dart run example/arrow_ipc.dart`.
Readers accept a complete `Uint8List` and return an `ArrowTable` containing its
schema and record batches. Writers return complete bytes. File-system I/O is
left to the caller. This is not incremental asynchronous I/O, memory mapping,
or zero-copy access: decoding materializes owned Dart values.

## Supported standard families

The independent PyArrow fixture suite exercises both file and stream formats:

| Family | Coverage |
| --- | --- |
| Primitive | Null, boolean, signed/unsigned 8/16/32/64-bit integers, float16/32/64 with raw bit preservation |
| Binary and text | UTF-8, binary, large offsets, fixed-size binary, string/binary views |
| Decimal | Decimal32/64/128/256, including negative scales |
| Temporal | Dates, times, timestamps with time-zone metadata, durations, intervals |
| Nested | Lists, large/fixed-size lists, list views, structs, maps |
| Dictionary | Root and nested dictionaries, extension-wrapped dictionaries, stream replacement and deltas |
| Other layouts | Sparse/dense unions and run-end encoding |
| Metadata | Schema/field string metadata and extension annotations |
| Structure | Multiple/empty batches, zero rows and positive-row zero-column batches |

An `ArrowArray` owns its values. Dictionary arrays also carry a `dictionary`;
`nestedDictionaries` carries dictionaries for nested type occurrences in
schema depth-first preorder. `RecordBatch.slice` preserves these sidecars.
Run-end encoded logical values are materialized, not stored as a zero-copy
compressed view.

The standalone types are broader than the Polars copied-batch protocol.
`RecordBatchCodec` rejects unsupported types and nested dictionary sidecars
before native transport. Standard Arrow support does not imply native Polars
support for every layout.

## Compression

FlatBuffers metadata is implemented in-tree. The VM compression implementation
uses the pure Dart `libcompress` dependency.

| Platform | LZ4_FRAME read | ZSTD read | Write |
| --- | --- | --- | --- |
| Dart VM | yes | yes | uncompressed |
| Web, tested with dart2js and Firefox | yes | explicitly unsupported | uncompressed |

The web LZ4 decoder checks bounds, frame structure, back-references and declared
sizes. It consumes but does not verify frame checksums; do not treat it as an
integrity or authenticity check. External LZ4 dictionaries are unsupported.

## Deliberate limits

- Little-endian IPC only. Big-endian input is rejected.
- `ArrowIpcLimits` bounds nesting, fields, nodes, buffers, rows, messages,
  dictionaries and total materialized values. Raise limits explicitly for
  larger trusted inputs. Run-end expansion and decompression obey bounds.
- `int128` and `uint128` are binding extensions, not standard Arrow integer
  types, and cannot be written to IPC.
- Metadata uses `Map<String, String>`. Non-UTF-8 metadata is rejected rather
  than decoded lossily. Duplicate metadata keys cannot be represented.
- A field has one extension annotation. Stacked extensions and a dictionary
  whose value type is an extension are rejected on write. Use the canonical
  extension-over-dictionary form. Supply annotations through
  `ArrowExtensionType`, not reserved `ARROW:extension:*` field metadata keys.
- This is not a claim of complete Apache Arrow specification conformance.

## Independent verification

The committed fixtures come from PyArrow 26.0.0. Tests compare schema, metadata,
nulls, batch boundaries, dictionary values and physical indices, exact floating
bits, unscaled decimals, and temporal counters. Ordinary Dart CI reads these
fixtures without requiring Python.

The implementation reads and rewrites **88 of 90 IPC fixtures**, and PyArrow
reads and validates all 88 rewritten outputs. The remaining two fixtures are
the file/stream forms of deliberately rejected non-UTF-8 metadata. The same
90-fixture read probe against `meshagent_dart_arrow` 0.53.4 accepted the same 88
and rejected the same two. This establishes the tested capability target, not
identical APIs, performance, or exhaustive conformance.

To reproduce the independent oracle from the repository root:

```sh
python3 -m venv build/arrow-oracle
P=build/arrow-oracle/bin/python
$P -m pip install pyarrow==26.0.0
$P tool/arrow_interop.py check
$P tool/arrow_interop.py verify --self-test
dart run tool/arrow_interop.dart --out build/arrow_ipc_dart
$P tool/arrow_interop.py verify --output build/arrow_ipc_dart --require-all
```

The last two commands report the non-UTF-8 limitation; `--require-all` exits
nonzero for those two missing outputs. Use `--only <family>` to verify one
family strictly. The ordinary CI suite treats those inputs as explicit
negative tests and requires every other fixture to pass:

```sh
dart test test/arrow_ipc_interop_test.dart
```
