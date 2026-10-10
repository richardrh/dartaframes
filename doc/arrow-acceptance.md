# Standard Arrow acceptance map

This maps the Arrow-first request to observable checks, rather than inferring
success from a total test count. Paths below are relative to the repository.
Test-name fragments identify individually reported tests, including generated
fixture tests in `test/arrow_ipc_interop_test.dart`.

## Scope and observed improvement

The previous core supplied owned logical values, its own JSON codec, and the
Polars Arrow C bridge. The new public IPC APIs now read independently produced
standard Arrow bytes and emit bytes accepted by PyArrow. On the same 90-input
fixture catalogue, Meshagent 0.53.4 and this implementation both accept 88 and
reject the same two non-UTF-8 metadata inputs. All 88 outputs rewritten by this
implementation independently validate in PyArrow, including schema and values.
This is the acceptance target for standard-core feature coverage. It does not
claim identical APIs, performance, zero-copy behavior, or complete Arrow-spec
conformance.

## Requirements, changed public outputs, and observed checks

Every row below was exercised successfully. Negative outcomes are intentional
assertions, not skipped checks. The independent fixtures use PyArrow 26.0.0.
The final named-result runs passed 457 native-enabled VM tests and 171 actual
Firefox tests, with no skipped tests. The unchanged CRAP baseline passed with
zero new or regressed violations. These totals supplement, rather than replace,
the behavior-level mapping below.

| Requirement / changed public output | Concrete check | Observed result |
| --- | --- | --- |
| Standalone `arrow.dart` export works without calling Polars, including web | `dart compile js example/arrow_ipc.dart`; actual Firefox `arrow_ipc_test.dart`: `stream preserves all core types` | Normal JS compilation succeeds; browser executes the public codecs successfully. |
| `ArrowIpcStreamReader.readTable` / `ArrowIpcStreamWriter.write` produce standard stream bytes | `arrow_ipc_test.dart`: `stream preserves all core types`; every supported `.arrows` oracle input and rewritten output | Schema, batch boundaries, nulls and values agree with independent expectations; PyArrow reads rewritten streams. |
| `ArrowIpcFileReader.readTable` / `ArrowIpcFileWriter.write` produce standard file bytes | `arrow_ipc_test.dart`: `file preserves all core types and carries ARROW1 magic`; every supported `.arrow` oracle input/output | Standard magic/footer and content are preserved; PyArrow reads rewritten files. |
| `ArrowTable.schema`, `batches`, `rowCount`; reader `bytes`/`limits`; writer `schema`/`batches` | `arrow_public_contract_test.dart`: `IPC public objects expose stable schema, bytes, limits and snapshots`; `arrow_ipc_test.dart`: `ArrowTable with mismatched batch schema` | Properties expose the expected objects/row total; input-list mutation cannot change snapshots; exposed lists reject mutation; mismatched schemas reject. |
| Multiple/empty batches and zero-column positive row counts | Oracle `structure/{multi_batch,no_batches,zero_rows,zero_columns,thousand_rows}` | Exact row counts and batch boundaries match; zero columns retain three rows. |
| Primitive and floating-bit fidelity, including changed `ArrowFloatingValue.float64` | Oracle `primitive/{integers,floats,booleans,nulls}`; `arrow_extended_types_test.dart`: `float64 bits are exact for negative values`; `arrow_codec_parsing_test.dart`: `round-trips exact NaN payload and signed zero` | Integer extrema, nulls, signed zero and floating payload bits survive. VM and Firefox checks agree. |
| `ArrowOffsetWidth.view`, UTF-8/binary views, fixed binary and `byteWidth` | Oracle `binary/{strings,binaries,string_view,binary_view,fixed_size_binary,sliced_strings}`; `arrow_ipc_extended_test.dart`: `binary view inline boundary and external data`, `fixed binary including zero width` | Inline/external view data, Unicode, nulls, sliced offsets and fixed widths round-trip; zero-width fixed binary remains valid. |
| Decimal `bitWidth`, widened precision and signed scale | Oracle `decimal/{decimal32_9_2,decimal64_18_4,decimal128_38_10,decimal128_5_0,decimal256_76_20,negative_scale}`; `arrow_codec_parsing_test.dart`: `decimal256 and int bounds still round-trip at the limit` | All four standard widths preserve unscaled values and schema parameters. |
| `ArrowListType.offsetWidth` / `view`, large/fixed lists, list views | Oracle `nested/{lists,nested_lists,list_views,sliced_list}`; `arrow_ipc_extended_test.dart`: `both list view widths preserve null and empty rows` | Child values, large offsets, overlapping/out-of-order views, null/empty parents and slices retain logical content. |
| `ArrowMapType` fields, sorted flag, physical entries name/metadata and `entriesField` | Oracle `nested/maps`; `arrow_extended_types_test.dart`: `map entries metadata is preserved`; `arrow_public_contract_test.dart`: `map and union public metadata and selectors preserve immutable inputs` | Keys, nullable values, producer flags, custom entries metadata/name and non-null entries layout agree; metadata is a copied immutable map. |
| `ArrowMapEntry` / `ArrowMapValue` output order, duplicate keys, equality and hash | `arrow_ipc_extended_test.dart`: `map keeps duplicate ordered keys and nullable values`; `arrow_public_contract_test.dart`: `new value equality and hash outputs agree with exposed components` | Entry order and duplicate keys remain intact; exposed components and equality/hash/set behavior agree; entry lists reject mutation. |
| `ArrowUnionMode`, `ArrowUnionType` fields/IDs/lookup and `ArrowUnionValue` | Oracle `union/{sparse,dense}`; `arrow_ipc_extended_test.dart`: `union arbitrary tags preserve selected nulls and float bits`; public-contract metadata/selectors and value tests | Both layouts preserve tags and selected values; unknown lookup returns null; explicit IDs and immutable lists remain stable; equality/hash agree. |
| `ArrowIntervalUnit`, `ArrowIntervalType`, interval constructors and component getters | Oracle `temporal/interval_month_day_nano`; `arrow_ipc_extended_test.dart`: `all interval units preserve signed components`; public-contract value test | All three units preserve signed components; unused components are zero; getter values and equality/hash agree. |
| Date/time/timestamp/duration metadata through new IPC | Oracle `temporal/temporals` | Units, time-zone metadata and signed raw counters match independent expectations. |
| `ArrowRunEndEncodedType`, `ArrowArray.runEndEncoded`, `runEnds`, `runValues`, `expandRunEnds` | Oracle `ree/{ree16_i32,ree32_utf8,ree64_f64}`; `arrow_extended_types_test.dart`: `expands and re-derives canonical runs`; `arrow_nested_dictionary_model_test.dart`: `run-end bounds, full preflight, and values nullability` | Logical values and canonical runs agree; invalid ends, width overflow, forbidden nulls and over-limit expansion reject before allocation. |
| `ArrowArray.nestedDictionaries` and public `nestedDictionaryTypes` traversal | Oracle `dictionary/nested_dictionary`; `arrow_nested_dictionary_model_test.dart`: `nested lists require exact typed sidecars and range check indices`, `preorder offsets include dictionary descendants before siblings`; public-contract preorder test | Exact sidecar count/type/index bounds are enforced; traversal is depth-first; changing a returned traversal list cannot affect subsequent calls. |
| Root/nested/extension dictionaries, replacements, deltas and shared IDs | Oracle `dictionary/{dictionaries,shared_across_batches,replacement,delta}` and `extension/dictionary`; `arrow_ipc_test.dart`: `extension dictionary root and struct child preserve sidecars`, `dictionary of list dictionary follows inner replacement snapshots`, `compatible fields share a negative dictionary wire id` | Dictionary values and indices match; replacement snapshots remain independent; deltas, extension wrapping and compatible shared negative IDs work. |
| `RecordBatch.slice` bounds, rows, metadata, dictionary ownership | `arrow_batch_slice_test.dart`: both tests; nested-model `nested lists require exact typed sidecars and range check indices` | Row subsets are correct, zero-column counts survive, schema and dictionary identity are preserved, invalid ranges reject and exposed copied values are immutable. |
| `ArrowField.allowEmptyName`, schema/struct/map duplicate-name opt-ins and JSON | `arrow_ipc_schema_test.dart`: `standard IPC preserves unnamed and duplicate fields`, `map children may share a standard Arrow field name`; extended/model duplicate-name tests | Valid standard names survive schema and JSON paths; strict constructor defaults still reject unless opted in. |
| Extended datatype `toJson` / `ArrowDataType.fromJson`, constructor fields, equality/hash | `arrow_extended_types_test.dart`: parameterized `datatype JSON ... roundtrips`, `rejects malformed definitions`; public-contract datatype-copy equality/hash assertions | Every added family and enum variant round-trips its parameters; malformed definitions reject; equal copies have equal hashes. Legacy decimal128 JSON shape is unchanged. |
| `OwnedBatchJsonCodec` extended values and nested sidecars | `arrow_extended_types_test.dart`: `every extended type roundtrips through the batch codec`; nested-model dictionary/extension traversal and malformed-sidecar tests | Encoded and decoded values/sidecars agree; malformed sidecars reject as format errors rather than silently losing dictionary data. |
| Bounded canonical JSON numbers and exact float-bit output | `arrow_codec_parsing_test.dart`: `accepts canonical forms`, `rejects non-canonical forms`, `rejects over-long strings before parsing`, `applies to every BigInt-carrying value kind`, `requires exactly bitWidth/4 hex digits`, `encoder output is accepted by the strict decoder` | Canonical encoder output round-trips; oversized/non-canonical integers and wrong-width bit strings reject. |
| `ArrowIpcLimits.maxDepth` / `maxFields` | Schema test `schema field count and depth limits reject before materialization`; IPC `limits bound depth and batches` | Over-depth and over-field inputs reject; exact supported field threshold passes. |
| `ArrowIpcLimits.maxRows` / `maxValues` | IPC `append-only dictionaries emit deltas with bounded merged size`, `limits bound depth and batches`, billion-row Null test; extended `REE logical expansion is budget checked before allocation` | Excess rows, cumulative values, dictionary growth and REE expansion reject without materializing the declared excessive output. |
| `ArrowIpcLimits.maxBuffers` | Public-contract `maxBuffers rejects excess buffers in both public readers` | A two-buffer column rejects at limit one and succeeds at limit two, for both file and stream. |
| `ArrowIpcLimits.maxMessageBytes` / `maxDictionaries` / `maxBatches`, all limit getters | IPC `dictionary count, value and body limits are enforced`, `limits bound depth and batches`; public-contract `every public IPC limit retains its configured value` | Metadata/body/footer, dictionary and batch limits reject excessive inputs; each of the eight fields retains its configured value. |
| VM LZ4/Zstd decode and web LZ4 decode | Oracle `compression/{lz4,zstd}`; `arrow_ipc_compression_test.dart`: `public reader decodes independent PyArrow LZ4 stream`, overlap/header/size tests, `web Zstandard is explicitly unsupported` | VM decodes both independent formats; actual Firefox decodes LZ4; bad lengths/back-references reject; web Zstd rejects explicitly. |
| Decoder failure output, extension integrity and explicit unsupported cases | IPC truncation/corruption/footer tests; schema `IPC rejects wrapper compositions it cannot preserve`, `reserved extension metadata cannot change the declared field type`, int128 test; oracle `extension/binary_metadata` negative tests | Truncation and forged bounds fail cleanly; extension metadata cannot spoof/drop types; nonstandard integers and non-UTF-8 metadata are rejected, not misencoded. |
| Native `RecordBatchCodec.encode` remains narrower; legacy outputs preserved | All `arrow_native_boundary_test.dart` tests; real `example/series_arrow_head.dart`; native-enabled integration tests | Standalone-only layouts/sidecars/names reject before transport; legacy decimal JSON stays unchanged; real Polars and Arrow C roundtrip succeeds. |
| New fixture tooling and package/docs outputs | `tool/arrow_interop.py check` and `verify --self-test`; public Dart consumer plus PyArrow `verify`; `dart doc --dry-run`, publish dry-run, Hugo build; `example/arrow_ipc.dart` | Fixtures reproduce byte-for-byte; oracle self-test accepts all 90 originals; 88 supported rewritten outputs validate. Docs/site build and publish dry-run succeed; runnable example emits a two-row stream/file roundtrip. |

## Reproduce the observations

Run normal package tests with JSON reporting to retain each named result:

```sh
mkdir -p build
DARTAFRAMES_NATIVE_LIBRARY=/path/to/released/native/library \
  dart test --reporter json > build/arrow-vm-results.jsonl
```

Use an actual browser, not just compilation, for portable contract checks:

```sh
MOZ_HEADLESS=1 FIREFOX_EXECUTABLE=/path/to/firefox dart test -p firefox \
  test/arrow_public_contract_test.dart test/arrow_ipc_test.dart \
  test/arrow_ipc_extended_test.dart test/arrow_ipc_compression_test.dart
```

The full fixture matrix is in `test/fixtures/arrow_ipc/manifest.json`; the
independent oracle commands and deliberate limits are documented in
`doc/content/docs/arrow-ipc.md`. The two non-UTF-8 cases are required negative
tests. A missing supported fixture is not treated as a pass.

No repository split, package release, performance equivalence or complete
specification conformance is part of this acceptance claim. PR26 remains
stacked on PR25 until reviewed and merged.
