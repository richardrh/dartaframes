---
title: API coverage
weight: 4
---

## At a glance

| | Coverage |
| --- | --- |
| Base | Polars Rust 0.55.2; ABI and protocol version 2 |
| Overall | **Partial** — an explicit-runtime, native-handle binding, not method-for-method Polars parity |
| Strongest areas | Lazy query composition, core expressions, joins and groups, CSV/Parquet, selectors, SQL, Arrow interchange, and bounded streaming |
| Main gaps | Broader eager operations, expression families, pivot-style reshape, configuration, cloud/remote database adapters, and host-ecosystem integrations |

The matrices below distinguish **Implemented**, **Partial**, **Missing**, and
**Host-only/out of scope** coverage. Do not assume that a Python or Rust Polars
method is available unless the public Dart API exposes it.

## Scope and method

This is a qualitative audit of the **currently exported Dart API**, not a claim
of method-for-method parity. The native crate is pinned to **Polars Rust
0.55.2**; protocol ABI is 2 and protocol version is 2. The audit was updated on
2026-08-29 from:

- `lib/polars.dart` and every exported
  implementation file;
- `protocol/capabilities.json` (including command, operation, and datatype
  capability declarations);
- `native/polars_ffi/Cargo.toml` and the native command dispatch; and
- the authoritative [Polars Rust 0.55.2 crate documentation][rust-api] and
  [0.55.2 feature list][rust-features].

The [stable Python API reference][python-api] supplies only the user-facing
category structure. Python-specific conveniences are identified as such and
are not treated as missing Rust opcodes. A Cargo feature being compiled does
not make it available to Dart: this audit marks functionality available only
when a public Dart call reaches a supported protocol command.

For an exhaustive source-generated list of public libraries, classes, members,
signatures, and documentation comments, use the
[generated API reference](/api/).

Status labels used below:

- **Implemented** — the stated category or deliberately narrow facility is
  callable through the public Dart API.
- **Partial** — a useful subset exists, with the boundary stated explicitly.
- **Missing** — part of the relevant Polars Rust/query-engine surface has no
  public Dart route.
- **Host-only/out of scope** — ecosystem or language-host integration rather
  than a missing binding opcode.

## Coverage matrices

Names shown in **Implemented** and **Partial** rows are exact public Dart names,
but compact rows may be representative rather than exhaustive. `Sync` and
Future variants are listed separately when the distinction matters.

### Runtime and top-level constructors

| Area | Status | Public Dart API and boundary |
| --- | --- | --- |
| Explicit runtime | **Implemented** | `Polars.native`, `Polars.open`, `Polars.process`, `Polars.fromClient`; capability discovery through `nativeCapabilitiesSync` and `nativeCapabilities`; diagnostic snapshots through `runtimeDiagnosticsSync` and `runtimeDiagnostics`. `Polars.native` requires promoted native release metadata. There are intentionally no runtime-free globals. |
| Expression constructors | **Partial** | `Polars.col`, `Polars.lit`, `Polars.len`, `Polars.when`; ternary completion is `When.then(...).otherwise(...)`. No ranges, repeats, folds, horizontal aggregators, struct/list constructors, or general Python-style top-level function catalog. |
| Data sources/constructors | **Partial** | `Polars.scanCsv`, `scanParquet`, `scanIpc`/`scanFeather`, `scanNdjson`, eager local `readJsonSync`/`readJson` and `readIpcStreamSync`/`readIpcStream`, copied record-batch/array import, and `openSqlite` for a local owned SQLite connection. Scans expose typed compact option sets. |
| Concatenation | **Partial** | `Polars.concat` supports `vertical`, `verticalRelaxed`, `diagonal`, `diagonalRelaxed`, and `horizontal`; vertical/diagonal modes expose `rechunk`. |
| Resource lifecycle | **Implemented** | `Expr.isClosed`/`close`, `LazyFrame.isClosed`/`close`, `DataFrame.isClosed`/`close`, `Series.isClosed`/`close`, and `CancellableQuery.isClosed`/`close`; resources cannot be mixed across `Polars` instances. |

### `LazyFrame`

| Area | Status | Public Dart API and boundary |
| --- | --- | --- |
| Projection and rows | **Partial** | `LazyFrame.select`, `filter`, `withColumns`, `sort`, `slice`, `head`, `tail`. Sort accepts one flag or per-key flags for `descending` and `nullsLast`, plus `maintainOrder`. No sequential projection, gather/sample, reverse, shift, cache, row index, fill, or schema matching. |
| Columns and nested columns | **Partial** | `LazyFrame.drop`, `rename`, `explode`, `unnest`; `explode` is fixed to `emptyAsNull: true` and `keepNulls: true`. |
| Distinct/null rows | **Partial** | `LazyFrame.distinct` (`subset`, `keep`, `maintainOrder`) and `dropNulls` (`subset`). No frame-level drop/fill-NaN or fill-null operations. |
| Grouping and joins | **Partial** | `LazyFrame.groupBy(...).agg(...)` and `LazyFrame.join`; detailed limits are in the group/join matrix below. |
| Metadata and plans | **Partial** | `schemaSync`, `schema`, `explainSync`, `explain`, and `profileSync`. Explain supports plain, tree, and logical DOT formats; selected optimizer flags are typed. There is no plan serialization or cache-control API. |
| Execution and output | **Partial** | `collectSync`, `collect`, `submit`; true synchronous native lazy sinks for CSV, Parquet, IPC/Feather, and NDJSON. Legacy lazy `writeCsv`/`writeParquet` names wrap those sinks and document that their Future does not imply off-isolate execution. |

### `DataFrame`, eager operations, and `Series`

| Area | Status | Public Dart API and boundary |
| --- | --- | --- |
| Frame lifecycle/metadata | **Implemented** | `DataFrame.isClosed`, `close`, `lazy`, `infoSync`, `info`, `schemaSync`, `schema`, `shapeSync`. |
| Frame export/output | **Partial** | Copied batch export plus eager CSV, Parquet, IPC/Feather file, IPC stream, JSON-array, and NDJSON local writers. Local replacement uses a same-directory temporary file before persistence. |
| Eager transformations | **Partial** | `DataFrame.column`, `selectColumns`, `select`, `filter`, `filterMask`, `withColumns`, `sort`, `slice`, `head`, `tail`, `reverse`, `distinct`, `dropNulls`, `explode`, `unnest`, `unpivot`, `transpose`, `drop`, and `rename` execute immediately and return independent native handles. Eager group-by, join, pivot, and row iteration remain absent. |
| `Series`/typed chunked arrays | **Partial** | `Series` has direct native lifecycle, `infoSync`/`info`, `nameSync`, `dtypeSync`, `lengthSync`, `nullCountSync`, `exportSync`/`export`, `toFrame`, `rename`, `cast`, `slice`/`head`/`tail`, `reverse`, `sort`, `filter`, `dropNulls`, `append`, `gather`, `unique`, comparisons, `+`/`-`/`*`/`/`, exact typed `sum`/`mean`/`min`/`max`/`first`/`last`, and integer `count`/`nUnique`. Namespaces and broader kernels remain absent. |

### Expressions: core and scalar operations

| Area | Status | Public Dart API and boundary |
| --- | --- | --- |
| Construction/naming/casting | **Partial** | `Polars.col`, `lit`, `len`; `Expr.alias`, `cast`. `cast` has `strict`; datatype eligibility is limited and has a static/native discrepancy noted below. |
| Public protocol escape hatches | **Partial** | `Expr.unary`, `binary`, `aggregate`, `function` are public, but native allow-lists in `capabilities.json` still apply. They do **not** imply arbitrary Polars expression support. |
| Comparison | **Implemented** | `eq`, `eqValidity`, `notEq`, `notEqValidity`, `lt`, `ltEq`, `gt`, `gtEq`. |
| Boolean | **Implemented** | `logicalAnd`, `logicalOr`, aliases `and`, `or`, and getters `not`, `isNull`, `isNotNull`. |
| Arithmetic/bitwise | **Partial** | Dart operators `+`, `-`, unary `-`, `*`, `/`, `~/`, `%`, `&`, `|`, `^`; `pow`, `sqrt`, `cbrt`, `log`, `log1p`, `exp`; `sin`, `cos`, `tan`, `cot`, `asin`, `acos`, `atan`, `atan2`, `sinh`, `cosh`, `tanh`, `asinh`, `acosh`, `atanh`, `degrees`, `radians`. No checked-arithmetic, dot-product, or sign family. |
| Ternary | **Implemented** | `Polars.when`, `When.then`, `Then.otherwise`; one condition per builder (no chained Python-style `when` branches). |
| Reductions | **Partial** | Getters `count`, `nullCount`, `sum`, `mean`, `min`, `max`, `first`, `last`, `median`, `nUnique`, `product`, `argMin`, `argMax`, `approximateNUnique`, `nanMin`, `nanMax`; methods `std`, `variance`, `quantile`, `mode`, `skew`, `kurtosis`, `any`, `all`. No covariance/correlation. |
| Null/NaN/numeric basics | **Partial** | `fillNull`, `fillNaN`, `isNaN`, `isNotNaN`, `isFinite`, `isInfinite`, `abs`, `floor`, `ceil`, `round`, `clip`, `clipMin`, `clipMax`, `coalesce`, `isIn`, `rank`, `interpolate`, `interpolateBy`. `isIn` takes an `Expr` for values; `coalesce` is an instance method whose receiver is the first candidate. No replace, uniqueness predicates/counts, bounds, histogram, or search-sorted. |
| Shift/cumulative/time-series | **Partial** | `shift`, `cumulativeSum`, `cumulativeMin`, `cumulativeMax`, `diff`, `pctChange`; fixed-window `rollingMin`, `rollingMax`, `rollingMean`, `rollingSum`, `rollingMedian`, `rollingVariance`, `rollingStd`; `ewmMean`, `ewmSum`, `ewmStd`, `ewmVariance`. Options are typed by `DiffNullBehavior`, `RollingOptions`, and `EwmOptions`. No cumulative product/count/eval or dynamic time-column rolling windows. |

### Expression namespaces

Qualified expression APIs are exposed as non-owning views on `Expr`; the older
direct string methods remain as aliases.

| Namespace/category | Status | Public Dart API and boundary |
| --- | --- | --- |
| String (`str`) | **Partial** | Length/case, search/extract/split/replace/strip/slice/head/tail/pad, and date/time parsing are mapped. Existing direct string aliases are retained. |
| Array (`arr`) | **Partial** | Length/reductions, item access/contains, sort, list conversion, and explode are mapped. |
| List (`list`) | **Partial** | Length/reductions, first/last, item access/contains, sort, and slice are mapped. |
| Struct (`struct`) | **Partial** | Field access, field rename, and JSON encode are mapped. `LazyFrame.unnest` remains a frame operation. |
| Binary (`bin`) | **Partial** | Size/search and hex/base64 encoding are mapped. |
| Categorical/enum (`cat`) | **Partial** | Physical values and categories are mapped. |
| Datetime/date/time (`dt`) | **Partial** | Calendar/time components, timestamp/format, truncate/round/offset, timezone conversion, and UTC/DST offsets are mapped. |
| Name (`name`) | **Partial** | Keep, prefix/suffix, and case transforms are mapped. |
| Metadata (`meta`) | **Partial** | Root/output names, projection/literal predicates, output expansion predicates, and alias removal are mapped through closed protocol operations. |

### Grouping, windows, joins, and reshape

| Area | Status | Public Dart API and boundary |
| --- | --- | --- |
| Ordinary lazy group-by | **Partial** | `LazyFrame.groupBy` and `LazyGroupBy.agg`, with expression keys and `maintainOrder`. Convenience group reductions, `having`, group head/tail, iteration, and map-groups are absent. |
| Dynamic/rolling groups | **Implemented** | `LazyFrame.groupByDynamic(...).agg(...)` and `groupByRolling(...).agg(...)`, with typed Polars durations, grouping keys, boundaries/labels/start controls where applicable. |
| Window expressions | **Partial** | `Expr.over(partitionBy, orderBy:, options:)` supports partition-only compatibility, ordering options, and `groupsToRows`/`explode`/`join` mapping. No explicit frame bounds. |
| Equality and Cartesian joins | **Partial** | Legacy `LazyFrame.join` retains its string mode and Boolean coalesce API. `joinWithOptions` adds typed modes, nullable join-specific coalescing, null equality, validation, order and parallel controls. |
| Advanced joins | **Implemented** | `LazyFrame.joinAsOf` with typed strategy/duration/group options and `joinWhere` for non-equi predicates. |
| Basic reshape | **Partial** | Eager and lazy `explode`, `unnest`, and `unpivot`; eager `transpose`; all vertical/diagonal/horizontal `Polars.concat` modes. |
| General reshape | **Missing** | No pivot, unstack, partition-by, dummy encoding, or merge-sorted. |

### I/O and interchange

| Area | Status | Public Dart API and boundary |
| --- | --- | --- |
| CSV | **Partial** | `Polars.scanCsv`; eager and lazy writes with typed `CsvWriteOptions` for headers/BOM, delimiters, quoting, nulls, line endings, temporal/float formatting, and batching. Legacy `includeHeader`/`separator` arguments remain supported. There is no eager CSV reader or byte/stream source. |
| Parquet | **Partial** | `Polars.scanParquet`; eager and lazy writes with typed `ParquetWriteOptions` for compression, row-group/page sizing, and statistics. Eager writes additionally expose column serialization parallelism. Legacy `compression` remains supported. No metadata API, cloud options, or partitioned dataset interface. |
| Lazy sinks | **Partial** | Native synchronous streaming sinks are exposed as `sinkCsvSync`, `sinkParquetSync`, `sinkIpcSync`/`sinkFeatherSync`, and `sinkNdjsonSync`, with compatibility wrappers without `Sync`. Format and sink options remain deliberately narrow. |
| Other native formats/sources | **Partial** | Local IPC/Feather scan/write, IPC-stream eager read/write, JSON-array eager read/write, and NDJSON scan/write are implemented. Owned local SQLite connections support parameterized query/execute and transactional DataFrame writes with fail/replace/append policies. Avro, cloud/object-store, HTTP, remote databases, and table formats remain deferred. |
| Copied owned-batch interchange | **Partial** | `RecordBatchCodec.encode`/`decode`, `Polars.fromRecordBatchSync`/`fromRecordBatch`, and `DataFrame.exportSync`/`export`. Columns are copied through JSON-compatible logical values; the practical full path is the flat supported subset through `time`. Nested/category/extension paths are not materialized. |
| Arrow standards interchange | **Partial** | `DataFrame.exportArrowC`, `Series.exportArrowC`, `Polars.fromArrowCData`, `seriesFromArrowCData`, `DataFrame.exportArrowCStream`, and bounded `Polars.fromArrowCStream` expose Arrow C Data/C Stream ownership for the supported flat tranche. IPC file/stream I/O is separate. |

### Schemas and datatypes

| Area | Status | Public Dart API and boundary |
| --- | --- | --- |
| Schema inspection | **Partial** | `Field`; `LazyFrame.schemaSync`/`schema`; `DataFrame.schemaSync`/`schema`; frame `infoSync`/`info`; `DTypeSelector.matches`. No schema mutation API. |
| Descriptor model | **Implemented** | `DType`, `DType.fromJson`, `DTypeCapabilities`, `DTypeCapability`, `simpleDTypes`, and `allDTypes`; all 31 advertised descriptor kinds are represented: `NullType`, `BooleanType`, `UInt8Type`, `UInt16Type`, `UInt32Type`, `UInt64Type`, `UInt128Type`, `Int8Type`, `Int16Type`, `Int32Type`, `Int64Type`, `Int128Type`, `Float16Type`, `Float32Type`, `Float64Type`, `DecimalType`, `StringType`, `BinaryType`, `BinaryOffsetType`, `DateType`, `DateTimeType`, `DurationType`, `TimeType`, `ArrayType`, `ListType`, `ObjectType`, `CategoricalType`, `EnumType`, `StructType`, `ExtensionType`, `UnknownType`. Descriptor presence does not imply values or kernels. |
| Flat values/literals/interchange | **Partial** | `Scalar.nullValue`, `boolean`, `integer`, `int64`, `int128`, `uint128`, `float16Bits`, `float32`, `float64`, `float64Bits`, `string`, `binary`, `date`, `time`, `datetime`, `duration`, `decimal`, `typed`, `fromArrow`. Protocol capabilities advertise all six levels (descriptor/literal/import/export/cast/kernels) for the 23 flat kinds from `null` through `time`; actual operation/type validity remains Polars-dependent. |
| Nested/special values | **Partial** | Descriptors exist for all nested/special kinds. Native namespace kernels are reported for `array`, `list`, `categorical`, `enum`, and `struct`; none of these has copied values. `object`, `extension`, and `unknown` remain descriptor-only, while `enum` additionally advertises native cast. |
| Capability consistency | **Partial** | Dart static `ArrayType`/`ListType` report descriptor+cast while native `hello` reports descriptor-only; Dart static `EnumType` reports descriptor-only while native reports descriptor+cast. Consult both `DType.capabilities` and `Polars.nativeCapabilitiesSync`/`nativeCapabilities`; this mismatch should be reconciled. |

### Selectors and SQL

| Area | Status | Public Dart API and boundary |
| --- | --- | --- |
| Selectors | **Implemented** | Runtime-owned `Selector`, `DTypeSelector`, and `SelectorFactory` expose name/index/regex/datatype construction, full set algebra, datatype matching, and conversion to projection expressions. `LazyFrame.selectInputs`/`withColumnsInputs` accept mixed expressions and selectors without changing the existing typed methods. |
| SQL | **Implemented** | Runtime-owned `SqlContext` supports `LazyFrame`/`DataFrame` registration, bulk registration, unregister, table inspection, lazy query execution, deterministic close, and native finalization. |

### Collection, background work, and streaming

| Area | Status | Public Dart API and boundary |
| --- | --- | --- |
| Blocking collection | **Implemented** | `LazyFrame.collectSync`. |
| Convenience collection | **Implemented** | `LazyFrame.collect`, implemented as `submit` → `CancellableQuery.wait` → `take`. |
| Collection jobs | **Partial** | `LazyFrame.submit`; `CancellableQuery.poll`, `wait`, `cancel`, `take`; `JobStatus`, `JobState`, and alias `CollectJob`. Cancellation is best effort, jobs are collection-only, and `queued` is recognized but not currently emitted. |
| Other Future APIs | **Partial** | Future forms of schema, explain, metadata, interchange, and writes may still execute FFI work on the current isolate; they are convenience APIs, not general native background execution. |
| Streaming and batches | **Partial** | `ExecutionEngine` selects auto/in-memory/streaming where accepted. `LazyFrame.batchStreamSync`/`batchStream` creates bounded pull-based native production; `BatchStream.poll*`, `cancel*`, and `close` manage it. Arrow C Stream import/export is bounded by rows and, on import, batches. There is no Dart callback-batch API. |
| Optimization/diagnostics | **Partial** | `OptimizerOptions` exposes selected Polars flags; explain supports plain/tree/logical DOT; `profileSync` returns result and timing frames; runtime diagnostics are snapshots. No cache controls or plan serialization. |

### Configuration, testing, and host integrations

| Area | Status | Public Dart API and boundary |
| --- | --- | --- |
| Dart configuration API | **Partial** | `ExecutionOptions` provides per-query engine and selected optimizer control. There is no global `Config` class, thread-pool setter, or formatting API. Rust Polars environment variables may affect the native process, but are not a Dart API. |
| Testing helpers | **Host-only/out of scope** | Python `polars.testing` assertion/parameterized helpers are Python testing conveniences; use Dart test libraries and compare exported values. No Dart wrapper of Rust's `polars::testing` module is provided. |
| Pandas/NumPy/JAX/Torch | **Host-only/out of scope** | These Python ecosystem conversion APIs are not missing Rust query opcodes; equivalent Dart integrations would be separate host adapters. |
| Plotting/style/notebook display | **Host-only/out of scope** | Python plotting, Styler, rich notebook display, and HTML conveniences belong to the host UI ecosystem. |
| Excel/database/table formats | **Host-only/out of scope** | No such Dart adapters exist. Python Excel and database APIs, and ecosystem table-format connectors, are host integrations rather than missing Polars Rust query opcodes. |
| GPU/Polars Cloud/distributed-service clients | **Host-only/out of scope** | No integration is promised. These require distinct engines/services and should not be inferred from core Rust API categories; this is separate from the missing native object-store I/O noted above. |

## Exact-name reporting

Every name shown in an **Implemented** or **Partial** matrix row is an exact
public Dart member name that helps establish that status; compact rows are not
an exhaustive API reference. Related missing Polars families are summarized by
category rather than expanded into hundreds of Python method names. Generic
`Expr.unary`, `binary`, `aggregate`, and `function` remain constrained by the
native capability allow-lists and therefore do not upgrade an unlisted family
to implemented.

## Priorities

1. Reconcile Dart and native datatype capability declarations, then test each
   declared literal/import/export/cast boundary.
2. Broaden lazy and eager operations only in coherent, signature-verified
   tranches with explicit option validation and lifecycle tests.
3. Add remaining reshape families such as pivot and transpose, plus explicit
   window frame bounds, without implying general Polars parity.
4. Deepen streaming, diagnostics, and I/O controls while retaining bounded
   memory, closed protocol schemas, and deterministic ownership.
5. Keep cloud, database, table-format, and host-ecosystem adapters separately
   scoped from the core native binding.

## Imports

Consumers import `package:dartaframes/polars.dart` for the
runtime/query API and the exposed `RecordBatchCodec`. `dart:convert` is only a
consumer-side tool when JSON formatting is desired (for example, formatting a
raw capability map); importing it does not provide dataframe or Arrow
interchange.

Arrow remains available as a **secondary public library in the same package**,
but the primary `polars.dart` entry point re-exports it because
public Polars signatures use its `RecordBatch`, `ArrowArray`, and `ArrowValue`
types (`fromRecordBatch*`, `fromArrowArray*`, frame/Series `export*`, and
`Scalar.fromArrow`). Most consumers therefore need only:

```dart
import 'package:dartaframes/polars.dart';
```

`RecordBatchCodec` converts by copying owned logical values; it is not Arrow C
Data/C Stream or IPC interchange.

[rust-api]: https://docs.rs/polars/0.55.2/polars/
[rust-features]: https://docs.rs/crate/polars/0.55.2/features
[python-api]: https://docs.pola.rs/api/python/stable/reference/index.html
